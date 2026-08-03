-- Daseeki Bags 2.0 — store.lua
-- SavedVariables layer: settings + the inventory cache DB. Two globals,
-- both ADDITIVE and coexisting with the 1.x globals (DaseekiBagsAccount /
-- DaseekiBagsSets / DaseekiBagsMesh), which 2.0 never writes.
--
--   DaseekiBags2DB   — settings (schema-versioned, small).
--   DaseekiBags2Data — the churny inventory cache (owners graph), so it can
--                      be version-migrated independently of settings.
--
-- Data model (design D1/D3): owners keyed by "Name-Realm" (globally unique on
-- Classic Era — a character name is unique per realm regardless of account).
-- Each owner keeps PER-CONTAINER identity (never flattened) so both the
-- combined and split-bag-group layouts can be rendered downstream. Money is a
-- first-class per-owner field with cross-account totalling helpers (D1: gold
-- features are sacred).
--
-- Style reference: Daseeki-Nexus store.lua (flat module on the ns table,
-- applyDefaults recursion, versioned/idempotent migration guards, in-file
-- self-test suites registered via ns:RegisterSelfTest).

local ADDON, ns = ...

local Store = {}
ns.Store = Store

----------------------------------------------------------------------
-- Version constants
----------------------------------------------------------------------

-- Bump SETTINGS_VERSION to run a settings migration (MigrateSettings).
Store.SETTINGS_VERSION = 1
-- Bump SCHEMA_VERSION to run a cache-DB migration (MigrateData). A bump does
-- NOT wipe: MigrateData transforms in place. The owner has months of parked-alt
-- bank snapshots we must never discard.
Store.SCHEMA_VERSION = 1

----------------------------------------------------------------------
-- Container identity (WoW Classic Era 1.15 container ids)
--
-- These are the real bag ids; the store keys containers by them so the split
-- view can group by class without re-deriving. NUM_BAG_SLOTS / NUM_BANKBAGSLOTS
-- are read from the live globals when present (FrameXML constants), with the
-- Era-stable fallbacks; the store itself is id-agnostic — it stores whatever
-- container id capture/migration hands it.
----------------------------------------------------------------------

Store.BACKPACK_CONTAINER = 0
Store.BANK_CONTAINER     = -1
Store.KEYRING_CONTAINER  = -2

local function numBagSlots()
    return _G.NUM_BAG_SLOTS or 4
end
local function numBankBagSlots()
    return _G.NUM_BANKBAGSLOTS or 7
end
Store.NumBagSlots     = numBagSlots
Store.NumBankBagSlots = numBankBagSlots

-- Classify a container id into a paradigm-independent class, so both layouts
-- (combined = all classes together; split = one group per class) can partition
-- an owner's containers from the same stored identity.
function Store.ContainerClass(cid)
    cid = tonumber(cid)
    if cid == nil then return "unknown" end
    if cid == Store.BACKPACK_CONTAINER then return "backpack" end
    if cid == Store.KEYRING_CONTAINER  then return "keyring"  end
    if cid == Store.BANK_CONTAINER     then return "bank"     end
    if cid >= 1 and cid <= numBagSlots() then return "bag" end
    if cid >= numBagSlots() + 1 and cid <= numBagSlots() + numBankBagSlots() then
        return "bankbag"
    end
    -- Ids beyond the known bag ranges (should not occur on Era) are treated as
    -- bank-side storage so a stray high id never renders as a carried bag.
    if cid > 0 then return "bankbag" end
    return "unknown"
end

-- True when a container id belongs to the bank (only capturable at the bank).
function Store.IsBankContainer(cid)
    local c = Store.ContainerClass(cid)
    return c == "bank" or c == "bankbag"
end

----------------------------------------------------------------------
-- Time helper (catalog-verified GetServerTime, time() fallback)
----------------------------------------------------------------------

local function serverNow()
    if _G.GetServerTime then return _G.GetServerTime() end
    return (_G.time or os.time)()
end
Store.Now = serverNow

----------------------------------------------------------------------
-- Defaults trees
----------------------------------------------------------------------

-- Settings kept intentionally minimal for W1; the options page (W4) grows this.
-- Every key here is additive and back-compat via applyDefaults.
local function defaultSettings()
    return {
        settingsVersion = Store.SETTINGS_VERSION,
        -- Layout paradigm the owner last used. Both are supported (D3); this is
        -- only the remembered default, never a capability gate.
        layout      = "combined",   -- "combined" | "split"
        showMoney   = true,
        showItemCounts = true,      -- tooltip cross-character counts (D1 keep)
    }
end

-- Fresh, empty cache DB.
local function defaultData()
    return {
        schema      = Store.SCHEMA_VERSION,
        selfAccount = "",        -- this account's mesh id; set at runtime once known
        owners      = {},        -- ["Name-Realm"] = ownerRecord
        migratedFrom1x = false,  -- one-time marker guarding migrate.lua
    }
end

Store._defaultSettings = defaultSettings   -- exposed for self-tests
Store._defaultData     = defaultData

----------------------------------------------------------------------
-- Recursive defaults fill (never clobbers an existing value)
----------------------------------------------------------------------

local function applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            applyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end
Store.ApplyDefaults = applyDefaults

----------------------------------------------------------------------
-- Owner + container record constructors
----------------------------------------------------------------------

-- A canonical empty owner record. `source` distinguishes a fully-captured owner
-- (our own characters, with per-slot container contents) from a summary owner
-- (a remote character known only through the cross-account mesh: money + level
-- + aggregate item counts, no bag slots). Both totals-participate for gold.
function Store.NewOwner(nameRealm, name, realm)
    return {
        nameRealm  = nameRealm,
        name       = name,
        realm      = realm,
        account    = "",          -- account id owning this char ("" = unknown/remote)
        source     = "summary",   -- "full" | "summary"
        -- identity / appearance-relevant fields
        class      = nil,
        race       = nil,
        sex        = nil,
        faction    = nil,
        level      = 0,
        -- money (copper); the cross-account total sums this across owners
        money      = 0,
        -- per-container identity: [cid] = container (see NewContainer)
        containers = {},
        -- equipped items (appearance): [invSlot] = { id, count }
        equip      = {},
        -- aggregate item counts across this owner's storage: [itemID] = total
        itemCounts = {},
        -- bookkeeping
        rev        = 0,   -- monotonic revision (bumped on each snapshot)
        ts         = 0,   -- epoch of the most recent snapshot for this owner
    }
end

-- A container holds its own size/link/timestamp plus a sparse slot map. The
-- per-container `ts` is what lets the bank stay "as last seen at the bank"
-- while carried bags refresh live (design risk note: bank capture only fires
-- at the bank).
function Store.NewContainer(size, link, family)
    return {
        size   = size or 0,
        link   = link,     -- the bag item id occupying this bag slot (nil for 0/-1/-2)
        family = family,   -- bag family bitmask when known (quiver/soul/etc)
        ts     = 0,
        slots  = {},       -- [slotIndex] = { id, count, quality, link }
    }
end

-- A single occupied slot. `id` is the itemID (enough to render via GetItemInfo);
-- `quality`/`link` are populated by live capture and left nil by migration
-- (1.x never stored per-slot quality — it is derived from the id at render).
function Store.NewSlot(id, count, quality, link)
    return { id = id, count = count or 1, quality = quality, link = link }
end

----------------------------------------------------------------------
-- Init: attach SVs, migrate, apply defaults
----------------------------------------------------------------------

function Store.Init()
    -- Settings SV
    if type(_G.DaseekiBags2DB) ~= "table" then _G.DaseekiBags2DB = {} end
    Store.MigrateSettings(_G.DaseekiBags2DB)
    applyDefaults(_G.DaseekiBags2DB, defaultSettings())
    _G.DaseekiBags2DB.settingsVersion = Store.SETTINGS_VERSION

    -- Cache SV
    if type(_G.DaseekiBags2Data) ~= "table" then
        _G.DaseekiBags2Data = defaultData()
    end
    Store.MigrateData(_G.DaseekiBags2Data)
    applyDefaults(_G.DaseekiBags2Data, defaultData())

    Store.db   = _G.DaseekiBags2DB
    Store.data = _G.DaseekiBags2Data
    return Store.data
end

----------------------------------------------------------------------
-- Migration scaffolds (idempotent; version-guarded)
----------------------------------------------------------------------

-- Settings migration hook. No transforms needed at version 1; the shape is a
-- placeholder so a future settings-schema change has a home. Idempotent.
function Store.MigrateSettings(db)
    if type(db) ~= "table" then return end
    if (db.settingsVersion or 1) >= Store.SETTINGS_VERSION then return end
    -- (future per-version transforms go here)
    db.settingsVersion = Store.SETTINGS_VERSION
end

-- Cache-DB migration hook. Transforms in place and re-stamps `schema`; never
-- wipes owner data. At version 1 there is nothing to transform, but the guard
-- and stamp exist so a later bump lands safely. Idempotent.
function Store.MigrateData(data)
    if type(data) ~= "table" then return end
    local v = data.schema or 0
    if v == Store.SCHEMA_VERSION then return end
    -- if v < 2 then ...transform... end   (future)
    data.schema = Store.SCHEMA_VERSION
end

----------------------------------------------------------------------
-- Owner access
----------------------------------------------------------------------

-- Split "Name-Realm" into name, realm (realm may itself be absent).
function Store.SplitNameRealm(nameRealm)
    local name, realm = string.match(nameRealm or "", "^(.-)%-(.+)$")
    if name then return name, realm end
    return nameRealm, nil
end

function Store.MakeNameRealm(name, realm)
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

function Store.GetOwner(nameRealm)
    if not Store.data then return nil end
    return Store.data.owners[nameRealm]
end

function Store.EnsureOwner(nameRealm, name, realm)
    local owners = Store.data.owners
    local o = owners[nameRealm]
    if not o then
        if not name then name, realm = Store.SplitNameRealm(nameRealm) end
        o = Store.NewOwner(nameRealm, name, realm)
        owners[nameRealm] = o
    end
    return o
end

function Store.RemoveOwner(nameRealm)
    if Store.data then Store.data.owners[nameRealm] = nil end
end

-- Iterate owners; fn(nameRealm, ownerRecord). Order is unspecified (pairs).
function Store.ForEachOwner(fn)
    if not Store.data then return end
    for nr, o in pairs(Store.data.owners) do fn(nr, o) end
end

function Store.OwnerCount()
    local n = 0
    if Store.data then for _ in pairs(Store.data.owners) do n = n + 1 end end
    return n
end

----------------------------------------------------------------------
-- Identity / money writers
----------------------------------------------------------------------

function Store.SetIdentity(owner, ident)
    if not owner or not ident then return end
    if ident.class   ~= nil then owner.class   = ident.class   end
    if ident.race    ~= nil then owner.race    = ident.race    end
    if ident.sex     ~= nil then owner.sex     = ident.sex     end
    if ident.faction ~= nil then owner.faction = ident.faction end
    if ident.level   ~= nil then owner.level   = ident.level   end
    if ident.account ~= nil then owner.account = ident.account end
end

function Store.SetMoney(owner, copper)
    if not owner then return end
    owner.money = copper or 0
end

function Store.SetSelfAccount(id)
    if Store.data then Store.data.selfAccount = id or "" end
end

----------------------------------------------------------------------
-- Container writers / readers (per-container timestamp semantics)
----------------------------------------------------------------------

-- Store a container under an owner, stamping its snapshot time. `now` is
-- injectable for deterministic tests.
function Store.PutContainer(owner, cid, container, now)
    if not owner or not container then return end
    container.ts = now or serverNow()
    owner.containers[cid] = container
    owner.ts = container.ts
end

function Store.GetContainer(owner, cid)
    if not owner then return nil end
    return owner.containers[cid]
end

-- Age (seconds) of a container's snapshot; nil when never captured.
function Store.ContainerAge(owner, cid, now)
    local c = owner and owner.containers[cid]
    if not c or not c.ts or c.ts == 0 then return nil end
    return (now or serverNow()) - c.ts
end

-- Iterate an owner's containers filtered by class ("bag","bankbag",...),
-- or all when class is nil. fn(cid, container).
function Store.ForEachContainer(owner, class, fn)
    if not owner then return end
    for cid, c in pairs(owner.containers) do
        if class == nil or Store.ContainerClass(cid) == class then
            fn(cid, c)
        end
    end
end

-- Bump an owner's revision after a completed snapshot pass.
function Store.BumpRevision(owner, now)
    if not owner then return end
    owner.rev = (owner.rev or 0) + 1
    owner.ts  = now or serverNow()
end

----------------------------------------------------------------------
-- Item-count aggregation (tooltip cross-character counts — D1 keep)
----------------------------------------------------------------------

-- Recompute an owner's itemCounts from its stored containers (+ equipped
-- items). Returns the table. For summary owners (no containers) this leaves any
-- migrated itemCounts untouched only if `keepIfEmpty` is set.
function Store.RecomputeItemCounts(owner, keepIfEmpty)
    if not owner then return nil end
    local counts = {}
    local any = false
    for _, c in pairs(owner.containers) do
        for _, slot in pairs(c.slots) do
            if slot.id then
                counts[slot.id] = (counts[slot.id] or 0) + (slot.count or 1)
                any = true
            end
        end
    end
    for _, e in pairs(owner.equip) do
        if e.id then
            counts[e.id] = (counts[e.id] or 0) + (e.count or 1)
            any = true
        end
    end
    if not any and keepIfEmpty and owner.itemCounts then
        return owner.itemCounts
    end
    owner.itemCounts = counts
    return counts
end

----------------------------------------------------------------------
-- Money totals (D1: cross-account gold totals are sacred)
----------------------------------------------------------------------

-- Total copper across all owners (optionally filtered by fn(nameRealm,owner)).
function Store.TotalMoney(filter)
    local total = 0
    Store.ForEachOwner(function(nr, o)
        if not filter or filter(nr, o) then
            total = total + (o.money or 0)
        end
    end)
    return total
end

-- Copper subtotals grouped by account id: { [account] = copper }. Owners with
-- an empty account id are grouped under "" (the unknown/remote bucket). This is
-- the raw material the cross-account gold panel renders.
function Store.MoneyByAccount()
    local by = {}
    Store.ForEachOwner(function(_, o)
        local a = o.account or ""
        by[a] = (by[a] or 0) + (o.money or 0)
    end)
    return by
end

-- Break copper into gold/silver/copper (UI formats it; store only computes).
function Store.MoneyParts(copper)
    copper = copper or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return g, s, c
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "store")
----------------------------------------------------------------------

local function testDefaultsAndInit(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Fresh init from empty globals.
    _G.DaseekiBags2DB = nil
    _G.DaseekiBags2Data = nil
    Store.Init()
    ck(Store.data.schema == Store.SCHEMA_VERSION, "data schema stamped")
    ck(Store.db.settingsVersion == Store.SETTINGS_VERSION, "settings version stamped")
    ck(type(Store.data.owners) == "table", "owners table present")
    ck(Store.data.migratedFrom1x == false, "migration marker starts false")
    ck(Store.db.layout == "combined", "default layout combined")
end

local function testContainerClass(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Store.ContainerClass(0)  == "backpack", "0 -> backpack")
    ck(Store.ContainerClass(1)  == "bag",      "1 -> bag")
    ck(Store.ContainerClass(4)  == "bag",      "4 -> bag")
    ck(Store.ContainerClass(-1) == "bank",     "-1 -> bank")
    ck(Store.ContainerClass(-2) == "keyring",  "-2 -> keyring")
    ck(Store.ContainerClass(5)  == "bankbag",  "5 -> bankbag")
    ck(Store.ContainerClass(11) == "bankbag",  "11 -> bankbag")
    ck(Store.IsBankContainer(-1) == true,      "-1 is bank")
    ck(Store.IsBankContainer(6)  == true,      "6 is bank")
    ck(Store.IsBankContainer(0)  == false,     "0 not bank")
    ck(Store.IsBankContainer(-2) == false,     "keyring not bank")
end

local function testOwnerRoundTrip(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    _G.DaseekiBags2Data = nil; Store.Init()
    local o = Store.EnsureOwner("Puuchoco-Whitemane")
    ck(o.name == "Puuchoco" and o.realm == "Whitemane", "name/realm split")
    ck(Store.EnsureOwner("Puuchoco-Whitemane") == o, "ensure is idempotent (same table)")
    Store.SetIdentity(o, { class = "WARRIOR", faction = "Horde", level = 60, account = "acctA" })
    Store.SetMoney(o, 39000)
    ck(o.class == "WARRIOR" and o.level == 60 and o.account == "acctA", "identity written")
    ck(o.money == 39000, "money written")
    -- container round-trip with deterministic ts
    local c = Store.NewContainer(14, 14046)
    c.slots[1] = Store.NewSlot(22157, 1, 3, "item:22157")
    c.slots[13] = Store.NewSlot(22261, 2)
    Store.PutContainer(o, 0, c, 1700000000)
    local got = Store.GetContainer(o, 0)
    ck(got.slots[1].id == 22157 and got.slots[1].quality == 3, "slot with quality round-trips")
    ck(got.slots[13].count == 2 and got.slots[13].quality == nil, "slot without quality (migration-style)")
    ck(got.ts == 1700000000, "container ts stamped")
    ck(Store.ContainerAge(o, 0, 1700000060) == 60, "container age = 60s")
    ck(Store.OwnerCount() == 1, "one owner")
end

local function testItemCounts(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    _G.DaseekiBags2Data = nil; Store.Init()
    local o = Store.EnsureOwner("A-Realm")
    local c = Store.NewContainer(14)
    c.slots[1] = Store.NewSlot(22157, 10)
    c.slots[2] = Store.NewSlot(22157, 5)
    c.slots[3] = Store.NewSlot(6948, 1)
    Store.PutContainer(o, 0, c, 1)
    o.equip[7] = { id = 22157, count = 1 }   -- boots also count toward the total
    local counts = Store.RecomputeItemCounts(o)
    ck(counts[22157] == 16, "22157 aggregated across slots + equip (10+5+1)")
    ck(counts[6948] == 1, "6948 counted once")
end

local function testMoneyTotals(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    _G.DaseekiBags2Data = nil; Store.Init()
    local a = Store.EnsureOwner("A-R"); Store.SetIdentity(a, { account = "acctA" }); Store.SetMoney(a, 1022693)
    local b = Store.EnsureOwner("B-R"); Store.SetIdentity(b, { account = "acctA" }); Store.SetMoney(b, 39000)
    local c = Store.EnsureOwner("C-R"); Store.SetIdentity(c, { account = "acctB" }); Store.SetMoney(c, 63)
    local d = Store.EnsureOwner("D-R"); Store.SetMoney(d, 500)  -- no account (remote/unknown)
    ck(Store.TotalMoney() == 1022693 + 39000 + 63 + 500, "grand total sums all owners")
    local by = Store.MoneyByAccount()
    ck(by["acctA"] == 1022693 + 39000, "acctA subtotal")
    ck(by["acctB"] == 63, "acctB subtotal")
    ck(by[""] == 500, "unknown-account bucket subtotal")
    -- gold/silver/copper split
    local g, s, cc = Store.MoneyParts(1022693)   -- 102g 26s 93c
    ck(g == 102 and s == 26 and cc == 93, "money parts 1022693 -> 102g 26s 93c")
    -- filter helper (self only)
    local selfTotal = Store.TotalMoney(function(_, o) return o.account == "acctA" end)
    ck(selfTotal == 1022693 + 39000, "filtered total (acctA)")
end

local function testMigrationScaffold(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- MigrateData stamps schema without wiping owners; idempotent.
    local data = { schema = 0, owners = { ["X-Y"] = { money = 5 } }, migratedFrom1x = true }
    Store.MigrateData(data)
    ck(data.schema == Store.SCHEMA_VERSION, "MigrateData stamps schema")
    ck(data.owners["X-Y"].money == 5, "MigrateData preserves owners")
    Store.MigrateData(data)  -- second run no-ops
    ck(data.owners["X-Y"].money == 5, "MigrateData idempotent")
end

function Store.RunSelfTests(verbose)
    local suites = {
        { name = "defaults+init",     fn = testDefaultsAndInit },
        { name = "container class",   fn = testContainerClass },
        { name = "owner round-trip",  fn = testOwnerRoundTrip },
        { name = "item counts",       fn = testItemCounts },
        { name = "money totals",      fn = testMoneyTotals },
        { name = "migration scaffold", fn = testMigrationScaffold },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS store/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL store/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("store", Store.RunSelfTests)
end

return Store
