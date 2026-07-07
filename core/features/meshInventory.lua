--[[
    Cross-account item-count + currency sync (Phase 2).
    Rides the MeshTransport chunked transport over the shared 'DBAG' mesh. Uses a
    manifest + snapshot + delta protocol so unchanged characters are never re-sent:
      - Each local character carries a monotonic `rev` (in cache.mesh.rev) that bumps
        when its aggregated item map or currency changes.
      - On first contact / login, peers trade a tiny MANIFEST (charKey -> rev).
      - A peer requests SNAPSHOTs only for characters that changed or are missing.
      - Live edits on the logged-in character broadcast only the changed items (DELTA).
    Remote data is stored on the same DaseekiBagsMesh cache Phase 1 uses, so it
    persists and surfaces in the item/currency tooltips via the owner metatable.
    All Rights Reserved
--]]

local ADDON, Addon = ...
local MeshInventory = Addon:NewModule('MeshInventory')

-- Message-type codes (payload's first byte after transport decode)
local MSG_MANIFEST = 0x40
local MSG_SNAP_REQ = 0x41
local MSG_SNAPSHOT = 0x42
local MSG_DELTA    = 0x43

local SNAP_REQ_TTL     = 30   -- seconds to dedup repeated snapshot requests
local DIRTY_DEBOUNCE   = 3    -- seconds after last change before recompute
local INITIAL_RECOMPUTE = 5   -- seconds after load to build the first item map

local _snapReqPending = {}    -- charKey -> time() of last request we sent
local _lastCurrency           -- shadow of the last-sent currency map for the current char
local _dirtyTimer


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

local function IsSelf(name, realm)
    local sn, sr = SelfNameRealm()
    return name == sn and realm == sr
end

local function FindLocalOwner(name, realm)
    for _, owner in Addon.Owners:Iterate() do
        if not owner.remote and not owner.isguild and owner.name == name and owner.realm == realm then
            return owner
        end
    end
end

-- Build a flat { [itemID] = count } for any owner from its cached bag data,
-- using the tooltip's exact parsing (Addon.AggregateBag). Defaults to the player.
local function BuildItemMap(owner)
    owner = owner or Addon.player
    local counts = {}
    for _, bag in ipairs(Addon.InventoryBags) do Addon.AggregateBag(counts, owner[bag]) end
    for _, bag in ipairs(Addon.BankBags) do Addon.AggregateBag(counts, owner[bag]) end
    Addon.AggregateBag(counts, owner.mail)
    Addon.AggregateBag(counts, owner.equip)
    Addon.AggregateBag(counts, owner.vault)
    return counts
end

-- One-time backfill: give every LOCAL character that has cached bag data (from
-- prior play) an initial item map + rev, so alts sync without needing a re-login.
local function BackfillLocal()
    for _, owner in Addon.Owners:Iterate() do
        if not owner.remote and not owner.isguild and owner ~= Addon.player then
            local cache = owner.cache
            if cache and not cache.mesh then
                local counts = BuildItemMap(owner)
                if next(counts) then
                    cache.mesh = { rev = 1, itemCounts = counts }
                end
            end
        end
    end
end

-- Keep only positive integer counts; drop zero/negative/nil so stale or removed
-- entries never persist in a stored map. Returns the same table (mutated in place).
local function SanitizeCounts(t)
    if type(t) ~= 'table' then return {} end
    for id, cnt in pairs(t) do
        if type(id) ~= 'number' or type(cnt) ~= 'number' or cnt <= 0 then
            t[id] = nil
        end
    end
    return t
end

-- Flat numeric-keyed currency copy (drops the 'tracked' array key).
local function CurrencyMap(cache)
    local m = {}
    if cache and cache.currency then
        for id, qty in pairs(cache.currency) do
            if type(id) == 'number' and qty and qty > 0 then m[id] = qty end
        end
    end
    return m
end

-- Returns a { id = newValue } diff (removed entries get 0), or nil if identical.
local function Diff(old, new)
    local d, changed = {}, false
    for id, cnt in pairs(new) do
        if old[id] ~= cnt then d[id] = cnt; changed = true end
    end
    for id in pairs(old) do
        if new[id] == nil then d[id] = 0; changed = true end
    end
    return changed and d or nil
end


--[[ Local revision tracking ]]--

-- Recompute the current character's item/currency maps; bump rev and (optionally)
-- broadcast a delta to the roster when something actually changed.
function MeshInventory:Recompute(broadcast)
    if not Addon.MeshTransport:IsAvailable() then return end
    local cache = Addon.player and Addon.player.cache
    if not cache then return end
    cache.mesh = cache.mesh or { rev = 0, itemCounts = {} }

    local newItems = BuildItemMap()
    local newCur   = CurrencyMap(cache)

    local itemDelta = Diff(cache.mesh.itemCounts, newItems)
    local curDelta  = Diff(_lastCurrency or {}, newCur)

    if not itemDelta and not curDelta and (cache.mesh.rev or 0) > 0 then
        return  -- nothing changed
    end

    cache.mesh.rev = (cache.mesh.rev or 0) + 1
    cache.mesh.itemCounts = newItems
    _lastCurrency = newCur

    if broadcast and (itemDelta or curDelta) then
        local token = GetToken()
        if not token then return end
        local name, realm = SelfNameRealm()
        local payload = {
            tk = token, key = name .. '-' .. realm, rev = cache.mesh.rev,
            ic = itemDelta or {}, cur = curDelta or {},
        }
        for target in pairs(Addon.MeshSync._GetRoster()) do
            Addon.MeshTransport:Send(MSG_DELTA, payload, target)
        end
    end
end

function MeshInventory:MarkDirty()
    if _dirtyTimer then _dirtyTimer:Cancel() end
    _dirtyTimer = C_Timer.NewTimer(DIRTY_DEBOUNCE, function()
        _dirtyTimer = nil
        MeshInventory:Recompute(true)
    end)
end


--[[ Snapshot construction ]]--

function MeshInventory:BuildSnapshot(owner)
    local mesh = owner.cache and owner.cache.mesh
    if not mesh or not mesh.itemCounts then return nil end
    return {
        tk  = GetToken(),
        key = owner.name .. '-' .. owner.realm,
        rev = mesh.rev,
        id  = { class = owner.class, race = owner.race, sex = owner.sex,
                faction = owner.faction, level = owner.level },
        ts  = time(),
        ic  = mesh.itemCounts,
        cur = CurrencyMap(owner.cache),
        trk = owner.cache.currency and owner.cache.currency.tracked or nil,
    }
end


--[[ Outgoing protocol ]]--

-- Advertise every local character that has synced item data (charKey -> rev).
function MeshInventory:SendManifestTo(target)
    if not Addon.MeshTransport:IsAvailable() or not target then return end
    local token = GetToken()
    if not token then return end
    local m = {}
    for _, owner in Addon.Owners:Iterate() do
        if not owner.remote and not owner.isguild then
            local mesh = owner.cache and owner.cache.mesh
            if mesh and mesh.rev and mesh.itemCounts then
                m[owner.name .. '-' .. owner.realm] = mesh.rev
            end
        end
    end
    if next(m) then
        Addon.MeshTransport:Send(MSG_MANIFEST, { tk = token, m = m }, target)
    end
end

function MeshInventory:RequestSnapshot(target, key)
    if _snapReqPending[key] and (GetTime() - _snapReqPending[key] < SNAP_REQ_TTL) then return end
    _snapReqPending[key] = GetTime()
    Addon.MeshTransport:Send(MSG_SNAP_REQ, { tk = GetToken(), q = { key } }, target)
end


--[[ Incoming protocol ]]--

function MeshInventory:OnReceive(msgType, tbl, sender)
    if type(tbl) ~= 'table' or tbl.tk ~= GetToken() then return end
    if msgType == MSG_MANIFEST then
        self:OnManifest(tbl, sender)
    elseif msgType == MSG_SNAP_REQ then
        self:OnSnapReq(tbl, sender)
    elseif msgType == MSG_SNAPSHOT then
        self:OnSnapshot(tbl, sender)
    elseif msgType == MSG_DELTA then
        self:OnDelta(tbl, sender)
    end
end

function MeshInventory:OnManifest(tbl, sender)
    local want = {}
    for key, rev in pairs(tbl.m or {}) do
        local name, realm = key:match('^(.-)%-(.+)$')
        if name and realm and not IsSelf(name, realm) then
            local stored = DaseekiBagsMesh and DaseekiBagsMesh[realm] and DaseekiBagsMesh[realm][name]
            local storedRev = stored and stored.rev or 0
            if (not stored or not stored.itemCounts or storedRev < rev)
               and not (_snapReqPending[key] and (GetTime() - _snapReqPending[key] < SNAP_REQ_TTL)) then
                want[#want + 1] = key
                _snapReqPending[key] = GetTime()
            end
        end
    end
    if #want > 0 then
        Addon.MeshTransport:Send(MSG_SNAP_REQ, { tk = GetToken(), q = want }, sender)
    end
end

function MeshInventory:OnSnapReq(tbl, sender)
    for _, key in ipairs(tbl.q or {}) do
        local name, realm = key:match('^(.-)%-(.+)$')
        local owner = name and realm and FindLocalOwner(name, realm)
        if owner then
            local snap = self:BuildSnapshot(owner)
            if snap then Addon.MeshTransport:Send(MSG_SNAPSHOT, snap, sender) end
        end
    end
end

function MeshInventory:OnSnapshot(tbl, sender)
    local name, realm = (tbl.key or ''):match('^(.-)%-(.+)$')
    if not name or not realm or IsSelf(name, realm) then return end

    local owner = Addon.Owners:NewRemote(name, realm)
    local c = owner.cache
    c.itemCounts = SanitizeCounts(tbl.ic or {})
    c.currency   = SanitizeCounts(tbl.cur or {})
    if tbl.trk then c.currency.tracked = tbl.trk end
    c.rev = tbl.rev
    c.ts  = tbl.ts or time()
    if tbl.id then
        c.class = tbl.id.class; c.race = tbl.id.race; c.sex = tbl.id.sex
        c.faction = tbl.id.faction; c.level = tbl.id.level
    end
    owner.counts = nil  -- invalidate any cached tooltip aggregation
    _snapReqPending[tbl.key] = nil
    Addon.Owners:Sort()
end

function MeshInventory:OnDelta(tbl, sender)
    local name, realm = (tbl.key or ''):match('^(.-)%-(.+)$')
    if not name or not realm or IsSelf(name, realm) then return end

    local stored = DaseekiBagsMesh and DaseekiBagsMesh[realm] and DaseekiBagsMesh[realm][name]
    -- No base to apply onto, or a gap in the sequence -> resync via full snapshot.
    if not stored or not stored.itemCounts or not stored.rev or tbl.rev ~= stored.rev + 1 then
        self:RequestSnapshot(sender, tbl.key)
        return
    end

    local owner = Addon.Owners:NewRemote(name, realm)
    local c = owner.cache
    c.itemCounts = c.itemCounts or {}
    for id, cnt in pairs(tbl.ic or {}) do
        c.itemCounts[id] = (type(cnt) ~= 'number' or cnt <= 0) and nil or cnt
    end
    c.currency = c.currency or {}
    for id, qty in pairs(tbl.cur or {}) do
        c.currency[id] = (type(qty) ~= 'number' or qty <= 0) and nil or qty
    end
    if tbl.trk then c.currency.tracked = tbl.trk end
    c.rev = tbl.rev
    c.ts  = time()
    owner.counts = nil
    Addon.Owners:Sort()
end


--[[ Lifecycle ]]--

function MeshInventory:OnLoad()
    if not Addon.MeshTransport or not Addon.MeshTransport:IsAvailable() then
        return  -- LibSerialize/LibDeflate missing; gold sync (Phase 1) still works
    end

    Addon.MeshTransport:SetReceiver(function(msgType, tbl, sender)
        MeshInventory:OnReceive(msgType, tbl, sender)
    end)

    -- One-time scrub of any stale zero/invalid counts left by earlier builds.
    if DaseekiBagsMesh then
        for _, byId in pairs(DaseekiBagsMesh) do
            if type(byId) == 'table' then
                for _, c in pairs(byId) do
                    if type(c) == 'table' and c.itemCounts then SanitizeCounts(c.itemCounts) end
                end
            end
        end
    end

    -- Recompute the current character's map when its inventory/currency changes.
    self:RegisterSignal('BAGS_UPDATED', 'MarkDirty')
    self:RegisterSignal('BANK_CLOSE', 'MarkDirty')
    self:RegisterSignal('VAULT_CLOSE', 'MarkDirty')
    self:RegisterEvent('CURRENCY_DISPLAY_UPDATE', 'MarkDirty')
    self:RegisterEvent('MAIL_INBOX_UPDATE', 'MarkDirty')
    self:RegisterEvent('PLAYER_EQUIPMENT_CHANGED', 'MarkDirty')

    -- Build the initial map once (after Cacher has populated the cache), no broadcast.
    -- Backfill offline alts from their existing cached bags so they sync without a
    -- re-login, then compute the current character's live map.
    C_Timer.After(INITIAL_RECOMPUTE, function()
        BackfillLocal()
        MeshInventory:Recompute(false)
    end)
end
