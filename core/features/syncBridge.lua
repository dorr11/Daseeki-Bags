--[[
    Wave N5 cutover — cross-account sync via Daseeki.Sync (Nexus mesh).

    Replaces Bags' bespoke DBAG mesh (meshSync + meshTransport + meshInventory)
    with the suite-wide Daseeki.Sync v2 namespace store owned by Daseeki-Nexus:
      * We REGISTER the current character's aggregated snapshot as the "bags"
        namespace provider and MarkDirty it on the same cache-changing events
        Bags already tracks.
      * We CONSUME peers' snapshots via Daseeki.Sync.Get("bags") / onRemote and
        fold them into the existing remote-owner viewer path (Owners:NewRemote),
        so the inventory/tooltip UI is unchanged.

    Soft-guard / graceful degradation: if Daseeki.Sync v2 is absent — Nexus not
    installed, or only the older proxy present — this module stays dormant and
    the legacy DBAG modules keep working (they self-suppress only when v2 IS
    present). The `MarkDirty` capability is the v2 marker, so the cutover is safe
    regardless of the Nexus/Bags merge order.

    Own-character data (DaseekiBagsAccount) is untouched. The remote read-cache
    (DaseekiBagsMesh) is retained and now filled by onRemote instead of DBAG.

    Bagnon-derived (GPL) fork; this file is our own work.
--]]

local ADDON, Addon = ...
local SyncBridge = Addon:NewModule('SyncBridge')

local NS_KEY          = 'bags'
local PUSH_DEBOUNCE   = 3   -- coalesce rapid local edits before publishing
local INITIAL_PUBLISH = 6   -- seconds after load: publish self + reconcile peers


--[[ Suite-sync capability probe ]]--

-- v2 requires provide/Get/MarkDirty. MarkDirty is the v2-only marker (the
-- retired proxy exposed RegisterNamespace but never MarkDirty), so this is a
-- safe check no matter which repo's branch merged first.
local function SuiteSync()
    local S = _G.Daseeki and _G.Daseeki.Sync
    if S and S.RegisterNamespace and S.MarkDirty and S.Get then return S end
    return nil
end


--[[ Identity ]]--

local function SelfNameRealm()
    local name, realm = UnitFullName('player')
    if not realm or realm == '' then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName())
             or (GetRealmName and GetRealmName():gsub('%s+', '')) or ''
    end
    return name, realm
end

local function SelfKey()
    local n, r = SelfNameRealm()
    return n .. '-' .. r
end


--[[ Provider: the current character's aggregated snapshot ]]--

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

-- Build the snapshot in the SAME shape the viewer's remote-owner path consumes
-- (itemTooltips reads owner.itemCounts for meshRemote owners; playerMoney /
-- currencyTooltips read money / currency). NOT the raw DaseekiBagsAccount bag
-- layout — own-character raw data stays in DaseekiBagsAccount untouched; the
-- mesh carries this compact aggregate (KBs, chunked by Nexus).
local function BuildSelfSnapshot()
    local player = Addon.player
    local cache  = player and player.cache
    if not cache then return nil end

    local counts = {}
    for _, bag in ipairs(Addon.InventoryBags) do Addon.AggregateBag(counts, player[bag]) end
    for _, bag in ipairs(Addon.BankBags)      do Addon.AggregateBag(counts, player[bag]) end
    Addon.AggregateBag(counts, player.mail)
    Addon.AggregateBag(counts, player.equip)
    Addon.AggregateBag(counts, player.vault)

    return {
        key        = SelfKey(),
        class      = player.class,
        race       = player.race,
        sex        = player.sex,
        faction    = player.faction,
        level      = player.level,
        money      = cache.money,
        itemCounts = counts,
        currency   = CurrencyMap(cache),
        tracked    = cache.currency and cache.currency.tracked or nil,
        ts         = time(),
    }
end


--[[ Consumer: fold a peer's snapshot into the remote-owner viewer path ]]--

local function ApplyRemote(ownerKey, data)
    if type(ownerKey) ~= 'string' or type(data) ~= 'table' then return end
    local name, realm = ownerKey:match('^(.-)%-(.+)$')
    if not name or not realm or name == '' or realm == '' then return end

    local sn, sr = SelfNameRealm()
    if name == sn and realm == sr then return end   -- never overwrite ourselves

    local owner = Addon.Owners:NewRemote(name, realm)
    local c = owner.cache
    if data.itemCounts then c.itemCounts = data.itemCounts end
    if data.currency   then c.currency   = data.currency   end
    if data.tracked    then c.currency = c.currency or {}; c.currency.tracked = data.tracked end
    if data.money ~= nil then c.money = data.money end
    if data.class   then c.class   = data.class   end
    if data.race    then c.race    = data.race    end
    if data.sex     then c.sex     = data.sex     end
    if data.faction then c.faction = data.faction end
    if data.level   then c.level   = data.level   end
    c.ts = data.ts or time()
    owner.counts = nil   -- invalidate any cached tooltip aggregation
    Addon.Owners:Sort()
end


--[[ Lifecycle ]]--

function SyncBridge:OnLoad()
    local S = SuiteSync()
    if not S then
        self.active = false
        return   -- graceful degradation: legacy DBAG modules remain active
    end
    self.active = true

    S.RegisterNamespace(NS_KEY, {
        ownerKey = function() return SelfKey() end,
        provide  = function() return BuildSelfSnapshot() end,
        onRemote = function(ownerKey, data) ApplyRemote(ownerKey, data) end,
    })

    -- Publish on the same cache-changing events Bags already reacts to.
    self:RegisterSignal('BAGS_UPDATED', 'MarkDirty')
    self:RegisterSignal('BANK_CLOSE',   'MarkDirty')
    self:RegisterSignal('VAULT_CLOSE',  'MarkDirty')
    self:RegisterEvent('CURRENCY_DISPLAY_UPDATE', 'MarkDirty')
    self:RegisterEvent('MAIL_INBOX_UPDATE',       'MarkDirty')
    self:RegisterEvent('PLAYER_EQUIPMENT_CHANGED', 'MarkDirty')
    self:RegisterEvent('PLAYER_MONEY',            'MarkDirty')

    -- After the cache is populated: publish our snapshot once and reconcile the
    -- merged remote view (the login read replaces the legacy DBAG receive path).
    C_Timer.After(INITIAL_PUBLISH, function()
        local sync = SuiteSync()
        if not sync then return end
        sync.MarkDirty(NS_KEY)
        SyncBridge:ReconcileFromStore()
    end)
end

-- Debounced publish of our snapshot.
function SyncBridge:MarkDirty()
    if not self.active then return end
    if self._pushTimer then self._pushTimer:Cancel() end
    self._pushTimer = C_Timer.NewTimer(PUSH_DEBOUNCE, function()
        self._pushTimer = nil
        local S = SuiteSync()
        if S then S.MarkDirty(NS_KEY) end
    end)
end

-- Read the merged local+remote view and apply every peer owner. This is the
-- literal "read peers' data via Daseeki.Sync.Get('bags')" the cutover calls for;
-- Nexus also delivers live peers through onRemote, so this is the login-time
-- backfill for data already cached in the Nexus store.
function SyncBridge:ReconcileFromStore()
    local S = SuiteSync()
    if not S then return end
    local view = S.Get(NS_KEY)
    if type(view) ~= 'table' then return end
    local selfKey = SelfKey()
    for ownerKey, data in pairs(view) do
        if ownerKey ~= selfKey then ApplyRemote(ownerKey, data) end
    end
end

-- Exposed so the legacy modules (and /dbg) can tell whether the suite mesh owns
-- cross-account sync this session.
function SyncBridge:IsActive() return self.active == true end
Addon.SuiteSyncActive = function() return SuiteSync() ~= nil end
