--[[
    Cross-account gold sync via addon messages.
    Roster discovery: CHAT_MSG_CHANNEL_JOIN events (same approach as ShadowNetwork).
    Data delivery: WHISPER via C_ChatInfo.SendAddonMessage (CHANNEL distribution
    does not fire CHAT_MSG_ADDON on receiving clients in Classic Era).
    All Rights Reserved
--]]

local ADDON, Addon = ...
local MeshSync = Addon:NewModule('MeshSync')

local PREFIX            = 'DBAG'
local MSG_GOLD          = 'G'
local PUSH_DEBOUNCE_SEC = 4
local PUSH_ON_LOGIN_SEC = 15

-- In-memory roster of confirmed-online remote accounts.
-- Populated by CHAT_MSG_CHANNEL_JOIN and by receiving any WHISPER from a peer.
-- Mirrors ShadowNetwork's meshOnlineRoster approach.
local _channelRoster = {}  -- { ["Name-Realm"] = true }
local _remoteCache   = {}
local _pushTimer     = nil
local _ownedChannel  = nil  -- channel we joined ourselves (leave on settings change)
local _joinFrame     = nil  -- frame listening to CHAT_MSG_CHANNEL_JOIN/LEAVE


--[[ Helpers ]]--

local function GetToken()
    local t = Addon.sets and Addon.sets.meshToken
    return (t and t ~= '') and t or nil
end

local function SelfNameRealm()
    local name, realm = UnitFullName('player')
    if not realm or realm == '' then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName():gsub('%s+', '')
    end
    return name, realm
end

local function SelfKey()
    local name, realm = SelfNameRealm()
    return name .. '-' .. realm
end

local function NormalizeName(name)
    if not name or name == '' then return nil end
    -- Ambiguate strips server suffix added to cross-realm names in some events
    if Ambiguate then name = Ambiguate(name, 'none') end
    if not name:find('-') then
        local _, realm = SelfNameRealm()
        name = name .. '-' .. realm
    end
    return name
end

local function FindOwner(name, realm)
    for _, owner in Addon.Owners:Iterate() do
        if owner.name == name and owner.realm == realm then
            return owner
        end
    end
end

local function GetChannelName_()
    local token = GetToken()
    if not token then return nil end
    local ch = Addon.sets and Addon.sets.meshChannel
    return (ch and ch ~= '') and ch or ('DBagSync' .. token)
end

-- Ensures we're in the channel. Uses JoinPermanentChannel so the channel persists
-- across sessions and WoW servers the roster to us (needed for GetChannelRosterInfo).
local function EnsureChannel()
    local chanName = GetChannelName_()
    if not chanName then
        if _ownedChannel then LeaveChannelByName(_ownedChannel) end
        _ownedChannel = nil
        return nil
    end

    local configured = Addon.sets and Addon.sets.meshChannel ~= ''
    if not configured then
        -- We manage our own channel
        if _ownedChannel and _ownedChannel ~= chanName then
            LeaveChannelByName(_ownedChannel)
            _ownedChannel = nil
            wipe(_channelRoster)
        end
        local num = GetChannelName(chanName)
        if not num or num == 0 then
            JoinPermanentChannel(chanName)
            num = GetChannelName(chanName)
        end
        if num and num > 0 then _ownedChannel = chanName end
        return (num and num > 0) and num or nil
    else
        -- External channel (e.g. ShadowNetwork's) — already joined by that addon
        if _ownedChannel then
            LeaveChannelByName(_ownedChannel)
            _ownedChannel = nil
            wipe(_channelRoster)
        end
        local num = GetChannelName(chanName)
        return (num and num > 0) and num or nil
    end
end


--[[ Remote-owner factory (in-memory, not persisted) ]]--

function Addon.Owners:NewRemote(id, realm)
    local byRealm = _remoteCache[realm] or {}
    _remoteCache[realm] = byRealm
    local cache = byRealm[id] or {}
    byRealm[id] = cache

    if not self.registry[cache] then
        local owner = setmetatable({
            id         = id,
            realm      = realm,
            name       = id,
            remote     = true,
            meshRemote = true,
            address    = id .. '-' .. realm,
            profile    = Addon.sets and Addon.sets.global or {},
            cache      = cache,
            isguild    = false,
        }, self)

        self.twins[id] = (self.twins[id] or 0) + 1
        self.registry[cache] = owner
        tinsert(self.ordered, owner)
    end

    return self.registry[cache]
end


--[[ Send ]]--

-- Send our gold + identity to a single named target (Name-Realm format).
-- Format: "G:<token>:<Name-Realm>:<copper>:<class>:<race>:<sex>:<faction>:<level>"
function MeshSync:PushGoldTo(target)
    local token = GetToken()
    if not token then return end
    local name, realm = SelfNameRealm()
    local copper  = GetMoney()
    local class   = UnitClassBase('player') or ''
    local race    = select(2, UnitRace('player')) or ''
    local sex     = UnitSex('player') or 0
    local faction = UnitFactionGroup('player') or ''
    local level   = UnitLevel('player') or 0
    local msg = table.concat({
        MSG_GOLD, token, name .. '-' .. realm, copper, class, race, sex, faction, level
    }, ':')
    if #msg > 253 then return end
    C_ChatInfo.SendAddonMessage(PREFIX, msg, 'WHISPER', target)
end

-- Push our gold to every known-online peer in the roster.
function MeshSync:PushGold()
    local token = GetToken()
    if not token then return end
    -- Ensure we're in the channel (join if needed)
    EnsureChannel()
    local count = 0
    for target in pairs(_channelRoster) do
        self:PushGoldTo(target)
        count = count + 1
    end
    -- Roster may still be empty if both accounts were already online before we joined.
    -- Attempt a one-time API poll — GetChannelRosterInfo populates after the server
    -- sends us the channel member list (takes ~15-30s after joining).
    if count == 0 then
        self:TryPopulateRosterFromAPI()
    end
end

-- Build a mesh message from a stored local-account character's cached data.
local function BuildLocalMsg(owner, token)
    local money = owner:GetMoney()
    if not money or money <= 0 then return end
    local msg = table.concat({
        MSG_GOLD, token, owner.name .. '-' .. owner.realm, money,
        owner.class or '', owner.race or '', owner.sex or 0,
        owner.faction or '', owner.level or 0
    }, ':')
    if #msg > 253 then return end
    return msg
end

-- Send ALL of this account's characters (from stored data) to a single target,
-- staggered to stay under WoW's addon-message throttle. Used for the full-account
-- snapshot on login / first contact, so a peer's stale cache gets fully refreshed.
function MeshSync:PushAllTo(target)
    local token = GetToken()
    if not token then return end
    local i = 0
    for _, owner in Addon.Owners:Iterate() do
        if not owner.remote and not owner.isguild then
            local msg = BuildLocalMsg(owner, token)
            if msg then
                i = i + 1
                C_Timer.After(i * 0.15, function()
                    C_ChatInfo.SendAddonMessage(PREFIX, msg, 'WHISPER', target)
                end)
            end
        end
    end
end

-- Push the full account snapshot to every known-online peer.
function MeshSync:PushAll()
    local token = GetToken()
    if not token then return end
    EnsureChannel()
    local any = false
    for target in pairs(_channelRoster) do
        self:PushAllTo(target)
        any = true
    end
    if not any then
        self:TryPopulateRosterFromAPI()
    end
end

-- Try to seed _channelRoster from GetChannelRosterInfo (only works after server
-- sends us the list, which can take 15-30 seconds post-join).
function MeshSync:TryPopulateRosterFromAPI()
    local chanName = GetChannelName_()
    if not chanName then return end
    local chanNum = GetChannelName(chanName)
    if not chanNum or chanNum == 0 then return end
    local count = GetNumChannelMembers(chanNum)
    if count == 0 then return end  -- not ready yet
    local self_ = SelfKey()
    for i = 1, count do
        local memberName = GetChannelRosterInfo(chanNum, i)
        local norm = NormalizeName(memberName)
        if norm and norm ~= self_ and not _channelRoster[norm] then
            _channelRoster[norm] = true
            self:PushAllTo(norm)  -- full account snapshot on discovery
        end
    end
end

-- Register a peer as online. On FIRST contact, send them our full account snapshot
-- so their (possibly stale) cache is refreshed. Subsequent contact is a no-op, which
-- prevents an endless full-push ping-pong between the two accounts.
local function MarkPeer(norm)
    if not norm or norm == SelfKey() then return end
    if not _channelRoster[norm] then
        _channelRoster[norm] = true
        C_Timer.After(0.2, function() MeshSync:PushAllTo(norm) end)
        -- Phase 2: advertise our item/currency manifest so the peer can pull snapshots.
        if Addon.MeshInventory then
            C_Timer.After(0.4, function() Addon.MeshInventory:SendManifestTo(norm) end)
        end
    end
end

local function DebouncedPush()
    if _pushTimer then _pushTimer:Cancel() end
    _pushTimer = C_Timer.NewTimer(PUSH_DEBOUNCE_SEC, function()
        _pushTimer = nil
        MeshSync:PushGold()
    end)
end


--[[ Receive ]]--

function MeshSync:OnMessage(message, sender)
    local token = GetToken()
    if not token then return end

    -- Any message from a peer means they're online. MarkPeer adds them to the roster
    -- and, on first contact, sends our full account snapshot back (both directions get
    -- a full refresh when two accounts meet).
    if sender then
        MarkPeer(NormalizeName(sender))
    end

    -- Format: "G:<token>:<Name-Realm>:<copper>:<class>:<race>:<sex>:<faction>:<level>"
    -- Split on ':' — no field contains a colon (Name-Realm uses a dash), so this is
    -- unambiguous. Identity fields (5..9) are optional for backward compatibility.
    local f = {}
    for part in message:gmatch('[^:]+') do f[#f + 1] = part end
    if f[1] ~= MSG_GOLD or f[2] ~= token then return end

    local nameRealm = f[3]
    local copper    = tonumber(f[4])
    if not nameRealm or not copper then return end

    local name, realm = nameRealm:match('^(.-)%-(.+)$')
    if not name or not realm or name == '' or realm == '' then return end

    local selfName, selfRealm = SelfNameRealm()
    if name == selfName and realm == selfRealm then return end

    local class, race, sexStr, faction, levelStr = f[5], f[6], f[7], f[8], f[9]

    local owner = FindOwner(name, realm) or Addon.Owners:NewRemote(name, realm)
    owner.cache.money = copper
    if class   and class   ~= '' then owner.cache.class   = class   end
    if race    and race    ~= '' then owner.cache.race    = race    end
    if sexStr  and sexStr  ~= '' then owner.cache.sex     = tonumber(sexStr) end
    if faction and faction ~= '' then owner.cache.faction = faction end
    if levelStr and levelStr ~= '' then owner.cache.level = tonumber(levelStr) end
    owner.cache.ts = time()  -- last-known timestamp (persisted)
    Addon.Owners:Sort()
    -- (No reply here: MarkPeer above already sent our full snapshot on first contact.)
end


--[[ Channel roster via CHAT_MSG_CHANNEL_JOIN/LEAVE ]]--

-- Mirrors ShadowNetwork's SG:CHAT_MSG_CHANNEL_JOIN handler.
-- CHAT_MSG_CHANNEL_JOIN args (after event): msg, sender, lang, chanStr, target, flags,
--   ignored, chanNumber, chanName, ...
-- We need arg2 (sender) and arg9 (chanName).
local function OnChannelJoinLeave(_, event, ...)
    local chanName = GetChannelName_()
    if not chanName then return end

    local sender  = select(2, ...)
    local evtChan = select(9, ...)

    -- evtChan may be "ChannelName" or "ChannelNumber ChannelName" depending on client version
    if not evtChan then return end
    -- Strip leading number if present (e.g. "1 DaseekiMeshNetwork" -> "DaseekiMeshNetwork")
    evtChan = evtChan:gsub('^%d+ ', '')

    if evtChan:lower() ~= chanName:lower() then return end

    local norm = NormalizeName(sender)
    if not norm or norm == SelfKey() then return end

    if event == 'CHAT_MSG_CHANNEL_JOIN' then
        MarkPeer(norm)  -- adds to roster + sends full account snapshot on first contact
    elseif event == 'CHAT_MSG_CHANNEL_LEAVE' then
        _channelRoster[norm] = nil
    end
end

local function EnsureJoinLeaveListener()
    if _joinFrame then return end
    _joinFrame = CreateFrame('Frame')
    _joinFrame:RegisterEvent('CHAT_MSG_CHANNEL_JOIN')
    _joinFrame:RegisterEvent('CHAT_MSG_CHANNEL_LEAVE')
    _joinFrame:SetScript('OnEvent', OnChannelJoinLeave)
end


-- Expose roster for /bgn mesh status display
function MeshSync._GetRoster() return _channelRoster end


--[[ Lifecycle ]]--

-- Recreate remote owners from persisted mesh data so last-known gold shows up
-- immediately on login, before any live message arrives.
local STALE_REMOTE_SECONDS = 30 * 24 * 60 * 60  -- prune remotes not seen in 30 days
function MeshSync:RestorePersisted()
    local cutoff = time() - STALE_REMOTE_SECONDS
    for realm, byId in pairs(_remoteCache) do
        for id, cache in pairs(byId) do
            if type(cache) == 'table' then
                if cache.ts and cache.ts < cutoff then
                    byId[id] = nil  -- prune stale remote data
                elseif not FindOwner(id, realm) and (cache.money or cache.itemCounts or cache.currency) then
                    Addon.Owners:NewRemote(id, realm)
                end
            end
        end
    end
    Addon.Owners:Sort()
end

function MeshSync:OnLoad()
    if not C_ChatInfo then return end

    -- Back the remote cache with the SavedVariable so received data persists across
    -- logout / character switches on this account.
    DaseekiBagsMesh = DaseekiBagsMesh or {}
    _remoteCache = DaseekiBagsMesh
    self:RestorePersisted()

    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

    -- Listen for incoming WHISPER addon messages
    local frame = CreateFrame('Frame')
    frame:RegisterEvent('CHAT_MSG_ADDON')
    frame:SetScript('OnEvent', function(_, _, prefix, message, _, sender)
        if prefix ~= PREFIX then return end
        if message:sub(1, 2) == 'G:' then
            MeshSync:OnMessage(message, sender)          -- Phase 1 plaintext gold
        else
            MarkPeer(NormalizeName(sender))               -- Phase 2 chunked transport frame
            if Addon.MeshTransport then
                Addon.MeshTransport:OnRaw(prefix, message, sender)
            end
        end
    end)

    -- Listen for channel join/leave to maintain live roster
    EnsureJoinLeaveListener()

    self:RegisterEvent('PLAYER_MONEY')

    -- Join the channel and do a first push after a delay (gives the server time to
    -- deliver the channel member list so GetChannelRosterInfo actually returns data)
    C_Timer.After(PUSH_ON_LOGIN_SEC, function()
        EnsureChannel()
        MeshSync:PushAll()  -- full account snapshot so peers' stale caches refresh
        -- Phase 2: advertise item/currency manifest to any peers already discovered.
        if Addon.MeshInventory then
            for target in pairs(_channelRoster) do
                Addon.MeshInventory:SendManifestTo(target)
            end
        end
        -- One more attempt 20 seconds later in case roster wasn't ready yet
        C_Timer.After(20, function() MeshSync:TryPopulateRosterFromAPI() end)
    end)
end

function MeshSync:PLAYER_MONEY()
    DebouncedPush()
end
