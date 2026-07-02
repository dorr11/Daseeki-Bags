--[[
    Chunked, rate-limited addon-message transport for the mesh (Phase 2).
    A scaled-down single-prefix version of ShadowNetwork's ShadowMesh transport:
    LibSerialize + LibDeflate encode, S/F/M/L chunk framing with a per-target
    sequence id, a token bucket to stay under WoW's ~1 msg/sec/prefix throttle,
    and per-sender reassembly with a timeout. Delivery is WHISPER (CHANNEL does
    not fire CHAT_MSG_ADDON in Classic Era). Coexists with Phase 1's plaintext
    'G:' gold messages on the same 'DBAG' prefix — see meshSync's dispatch.
    All Rights Reserved
--]]

local ADDON, Addon = ...
local MeshTransport = Addon:NewModule('MeshTransport')

local PREFIX             = 'DBAG'
local SINGLE_PAYLOAD     = 254   -- 255 - 1 marker byte
local MULTI_PAYLOAD      = 253   -- 255 - 1 marker - 1 seq byte
local DRAIN_INTERVAL     = 0.1
local REASSEMBLY_TIMEOUT = 15
local CLEANUP_INTERVAL   = 5
local BUCKET_MAX         = 8
local REFILL             = 1     -- tokens per second

-- Chunk markers (must never collide with the leading 'G' of the legacy gold msg)
local CHUNK_SINGLE = 'S'
local CHUNK_FIRST  = 'F'
local CHUNK_MIDDLE = 'M'
local CHUNK_LAST   = 'L'

local LibSerialize, LibDeflate
local _available   = false
local _receiver               -- fn(msgType, tbl, sender)
local _queue       = {}       -- FIFO of { target, data }
local _seqByTarget = {}       -- target -> next seq id
local _reassembly  = {}       -- sender -> { seqId, chunks, startedAt }
local _bucket      = { tokens = BUCKET_MAX, last = 0 }
local _drainTicker, _cleanupTicker


--[[ Encode / decode ]]--

local function Encode(msgType, tbl)
    local ok, serialized = pcall(function() return LibSerialize:Serialize(tbl) end)
    if not ok or not serialized then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized, {level = 9})
    if not compressed then return nil end
    local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed)
    if not encoded then return nil end
    return string.char(msgType) .. encoded
end

local function Decode(payload)
    if not payload or payload == '' then return nil end
    local msgType = string.byte(payload, 1)
    local body = payload:sub(2)
    local decoded = LibDeflate:DecodeForWoWAddonChannel(body)
    if not decoded then return nil end
    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil end
    local pcallOk, deserOk, tbl = pcall(LibSerialize.Deserialize, LibSerialize, decompressed)
    if not pcallOk or not deserOk then return nil end
    return msgType, tbl
end


--[[ Send (chunk + enqueue) ]]--

function MeshTransport:Send(msgType, tbl, target)
    if not _available or not target then return end
    local payload = Encode(msgType, tbl)
    if not payload then return end

    if #payload <= SINGLE_PAYLOAD then
        _queue[#_queue + 1] = { target = target, data = CHUNK_SINGLE .. payload }
    else
        local seq = (_seqByTarget[target] or 0) % 256
        _seqByTarget[target] = seq + 1
        local seqByte = string.char(seq)

        local chunks, pos, len = {}, 1, #payload
        while pos <= len do
            chunks[#chunks + 1] = payload:sub(pos, pos + MULTI_PAYLOAD - 1)
            pos = pos + MULTI_PAYLOAD
        end
        for i, c in ipairs(chunks) do
            local marker = (i == 1 and CHUNK_FIRST) or (i == #chunks and CHUNK_LAST) or CHUNK_MIDDLE
            _queue[#_queue + 1] = { target = target, data = marker .. seqByte .. c }
        end
    end

    self:StartDrain()
end

local function Refill()
    local now = GetTime()
    if _bucket.last == 0 then _bucket.last = now end
    local elapsed = now - _bucket.last
    if elapsed > 0 then
        _bucket.tokens = math.min(BUCKET_MAX, _bucket.tokens + elapsed * REFILL)
        _bucket.last = now
    end
end

local function DrainOnce()
    if #_queue == 0 then
        if _drainTicker then _drainTicker:Cancel(); _drainTicker = nil end
        return
    end
    Refill()
    if _bucket.tokens < 1 then return end

    -- FIFO keeps a target's chunks contiguous (each Send appends them together),
    -- so a multi-chunk message completes to one target before the next begins.
    local item = _queue[1]
    local ok = C_ChatInfo.SendAddonMessage(PREFIX, item.data, 'WHISPER', item.target)
    if ok == false then
        return  -- throttled; leave at head, retry next tick
    end
    _bucket.tokens = _bucket.tokens - 1
    table.remove(_queue, 1)
end

function MeshTransport:StartDrain()
    if _drainTicker then return end
    _drainTicker = C_Timer.NewTicker(DRAIN_INTERVAL, DrainOnce)
end


--[[ Receive (reassemble) ]]--

function MeshTransport:OnRaw(prefix, message, sender)
    if prefix ~= PREFIX or not _available or not message or message == '' then return end
    local marker = message:sub(1, 1)

    if marker == CHUNK_SINGLE then
        local msgType, tbl = Decode(message:sub(2))
        if msgType and _receiver then _receiver(msgType, tbl, sender) end

    elseif marker == CHUNK_FIRST then
        _reassembly[sender] = { seqId = string.byte(message, 2), chunks = { message:sub(3) }, startedAt = GetTime() }

    elseif marker == CHUNK_MIDDLE or marker == CHUNK_LAST then
        local seq = string.byte(message, 2)
        local r = _reassembly[sender]
        if not r or r.seqId ~= seq then
            _reassembly[sender] = nil  -- lost the first chunk or seq mismatch
            return
        end
        r.chunks[#r.chunks + 1] = message:sub(3)
        if marker == CHUNK_LAST then
            _reassembly[sender] = nil
            local msgType, tbl = Decode(table.concat(r.chunks))
            if msgType and _receiver then _receiver(msgType, tbl, sender) end
        end
    end
end


--[[ API / lifecycle ]]--

function MeshTransport:SetReceiver(fn) _receiver = fn end
function MeshTransport:IsAvailable() return _available end

function MeshTransport:OnLoad()
    LibSerialize = LibStub('LibSerialize', true)
    LibDeflate   = LibStub('LibDeflate', true)
    _available   = (LibSerialize and LibDeflate) and true or false
    if not _available then return end

    _cleanupTicker = C_Timer.NewTicker(CLEANUP_INTERVAL, function()
        local now = GetTime()
        for sender, r in pairs(_reassembly) do
            if now - r.startedAt > REASSEMBLY_TIMEOUT then
                _reassembly[sender] = nil
            end
        end
    end)
end
