-- Daseeki Bags 2.0 — nexus.lua   (Nexus Inventory consumer bridge, W2)
--
-- SOFT-REQUIRED bridge to the Daseeki-Nexus "Inventory" module. When Nexus is
-- installed and that module has a populated owners graph, Bags sources its
-- SUMMARY owners (the cross-account characters behind the money tooltip's "Other
-- Accounts" section and the cross-character tooltip counts) from the NEXUS store
-- instead of from its own mesh-imported copies. Without Nexus, Bags is exactly
-- what it is today: standalone-local, its own store, its own numbers.
--
-- ── Why the SavedVariables global and not a function call ─────────────────────
-- Nexus keeps its module tables on its own PRIVATE addon namespace (`local ADDON,
-- ns = ...`); the only things it publishes globally are Daseeki.Sync / Daseeki.Config
-- from syncns.lua. Its Inventory OWNERS GRAPH, though, is a plain SavedVariables
-- table — DaseekiNexusData.inventory — and that is the documented system of record
-- (Nexus store.lua: "INVENTORY OWNERS GRAPH ... additive area"). Reading the SV
-- table directly needs nothing published, cannot break when Nexus refactors an
-- internal, and is trivially testable headless. We READ it and NEVER write it, the
-- exact mirror of how Nexus reads DaseekiBagsAccount during its own migration.
--
-- Bags' .toc does NOT declare DaseekiNexusData — declaring another addon's global
-- would make BOTH addons write the same file. It declares only the OptionalDeps
-- line (`## OptionalDeps: Daseeki-Core, Daseeki-Nexus`), which is a LOAD-ORDER
-- statement, not a dependency: the client loads Daseeki-Nexus first WHEN IT IS
-- PRESENT AND ENABLED, so its SavedVariables are attached before our ADDON_LOADED
-- runs Store.Init -> Migrate.Migrate. With Nexus absent the line costs nothing and
-- Bags loads exactly as before.
--
-- ── The Nexus store shape (read off Daseeki-Nexus store.lua / inventory.lua) ───
--   DaseekiNexusData.inventory = {
--     schema  = 1,                    -- Store.INVENTORY_SCHEMA
--     migrated = <bool>,              -- its own 1.x import marker
--     parts   = { [nameRealm] = <its cold bank/mail components> },   -- not ours
--     owners  = { [ownerKey] = { rev = <n>, updatedAt = <epoch>, data = <payload> } },
--   }
--   <payload> is the FROZEN "bags" wire contract:
--     { key, class, race, sex, faction, level, money,
--       itemCounts = { [itemID] = count }, currency, tracked, ts,
--       mail = { n, money } }         -- `mail` additive/optional; we ignore it
--   ownerKey is "Name-Realm" with the realm space-stripped — byte-identical to the
--   key Store.MakeNameRealm produces here, which is what lets the two graphs merge
--   by key at all.
--
-- ── EVERY call is type-guarded ────────────────────────────────────────────────
-- There is no hard dependency anywhere: Nexus.Owners() falls back to
-- Store.data.owners the moment any guard fails (global absent, area absent, owners
-- absent, module toggled off, empty graph, or a schema newer than this build reads).
-- "Fall back" means literally returning the same table Bags used before this file
-- existed, so the standalone path allocates nothing and behaves identically.
--
-- ── SCOPE (deliberate boundaries) ─────────────────────────────────────────────
--   * BRIDGED (W2): the money tooltip (ui_owner.MoneyChars) and the cross-character
--     tooltip counts (features.appendCounts). Both are pure summary consumers.
--   * BRIDGED (display round): the FIND window. Find.Search grew an itemCounts branch,
--     so a summary owner does contribute rows; ui_find reads Nexus.Owners().
--   * BRIDGED (2.0.2): the OWNER SELECTOR — the earlier scope cut, reversed on the
--     owner's ask. The two affordances a Nexus-only row cannot honour are answered
--     rather than avoided: BROWSE resolves to a read-only SUMMARY VIEW (gold + an
--     aggregate item list) instead of an empty grid, and DELETE is HIDDEN, because
--     Owner.RemoveOwner nils an entry in DaseekiBags2Data and the row would simply
--     come back from the Nexus graph on the next merge. The favourite STAR is kept:
--     favourites are a Bags-side preference keyed by "Name-Realm"
--     (DaseekiBags2DB.ownerFavorites), so it is ours to store and it sticks.
--     NOTHING here is ever written into the Bags store — the merged view stays a view.
--
-- Clean-room: the Nexus shape above was read from OUR OWN Daseeki-Nexus repo. No
-- third-party addon source was opened.

local ADDON, ns = ...

local Nexus = {}
ns.Nexus = Nexus

local Store = ns.Store

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

Nexus.ADDON_NAME  = "Daseeki-Nexus"
Nexus.DATA_GLOBAL = "DaseekiNexusData"   -- churny data SV (holds .inventory)
Nexus.DB_GLOBAL   = "DaseekiNexusDB"     -- settings SV (holds inventoryEnabled)

-- The highest Store.INVENTORY_SCHEMA this build knows how to read. A graph stamped
-- HIGHER than this is refused outright rather than guessed at: a newer Nexus may
-- have reshaped an entry, and a misread money field is worse than no bridge.
Nexus.SCHEMA = 1

-- Merged views are rebuilt at most once a second. The money tooltip and the item
-- tooltip both rebuild on hover, and a merge allocates one record per Nexus owner;
-- one second is short enough that nothing on screen is ever visibly stale and long
-- enough that a fast mouse does not churn the collector. Any capture invalidates
-- it immediately anyway (see the bus hook at the bottom).
local CACHE_TTL = 1

local EMPTY = {}

----------------------------------------------------------------------
-- PRESENCE / ENABLEMENT PROBES  (pure; `G` is injectable for the harness)
----------------------------------------------------------------------

-- The Nexus Inventory area, or nil + a human reason. Every step is a type guard.
function Nexus.Area(G)
    G = G or _G
    if type(G) ~= "table" then return nil, "no global table" end
    local data = G[Nexus.DATA_GLOBAL]
    if type(data) ~= "table" then
        return nil, "Daseeki Nexus is not installed (no " .. Nexus.DATA_GLOBAL .. ")"
    end
    local area = data.inventory
    if type(area) ~= "table" then
        return nil, "Daseeki Nexus is installed but its Inventory module has not run yet"
    end
    if type(area.owners) ~= "table" then
        return nil, "the Nexus Inventory area carries no owners graph"
    end
    local schema = tonumber(area.schema)
    if schema and schema > Nexus.SCHEMA then
        return nil, string.format(
            "the Nexus owners graph is schema %d; this build of Bags reads schema %d",
            schema, Nexus.SCHEMA)
    end
    return area
end

-- The module toggle, read with Nexus's OWN rule: the key defaults to true and an
-- ABSENT key also means ON (Nexus inventory.lua Inventory.IsEnabled). Reading it any
-- other way would switch the bridge off for every save written before the key existed.
function Nexus.IsEnabled(G)
    G = G or _G
    if type(G) ~= "table" then return true end
    local db = G[Nexus.DB_GLOBAL]
    if type(db) ~= "table" then return true end
    if db.inventoryEnabled == nil then return true end
    return db.inventoryEnabled and true or false
end

function Nexus.CountOwners(owners)
    local n = 0
    if type(owners) == "table" then for _ in pairs(owners) do n = n + 1 end end
    return n
end

-- The single decision point: is the Nexus store the summary system of record right
-- now? Returns active(bool), reason(string), area(table|nil), count(number).
--
-- The EMPTY-GRAPH rule is a fail-safe, not a nicety. Deferring to a store that holds
-- nothing would blank the owner's cross-account gold for however long Nexus takes to
-- import or receive its first payload. An empty graph therefore reads as INACTIVE:
-- Bags keeps (and keeps importing) its own copies, and the merge below quietly hands
-- authority over as soon as Nexus actually has something fresher to say.
function Nexus.Status(G)
    local area, why = Nexus.Area(G)
    if not area then return false, why, nil, 0 end
    if not Nexus.IsEnabled(G) then
        return false, "the Nexus Inventory module is switched off", area, 0
    end
    local n = Nexus.CountOwners(area.owners)
    if n == 0 then
        return false, "the Nexus owners graph is empty (nothing to source yet)", area, 0
    end
    return true, string.format("sourcing %d owner(s) from the Nexus Inventory store", n), area, n
end

function Nexus.IsActive(G)
    local active = Nexus.Status(G)
    return active
end

-- migrate.lua's question, spelled out so the answer has one home. When the Nexus
-- store is active it is the system of record for REMOTE owners, so Bags stops
-- importing DaseekiBagsMesh into its own graph. LOCAL characters are untouched by
-- this — their full per-slot detail comes from DaseekiBagsAccount and stays
-- Bags-owned, exactly as today.
function Nexus.DeferMeshImport(G)
    return Nexus.IsActive(G)
end

----------------------------------------------------------------------
-- PURE: one Nexus graph entry -> a Bags owner record
----------------------------------------------------------------------

-- The freshness stamp to compare against a Bags owner's `ts`.
--
-- `data.ts` is the CAPTURE moment — the semantic twin of Bags' owner.ts, which
-- Store.PutContainer/BumpRevision also set at capture. `updatedAt` is when the entry
-- landed in the local Nexus graph, which for a relayed payload can be days after the
-- data was taken. Comparing arrival times against capture times would let a freshly
-- RECEIVED but week-old peer payload outrank a Bags record captured yesterday, so
-- data.ts leads and updatedAt is only the fallback for an entry that carries none.
function Nexus.EntryTimestamp(entry)
    if type(entry) ~= "table" then return 0 end
    local d = entry.data
    local ts = (type(d) == "table") and tonumber(d.ts) or nil
    if ts and ts > 0 then return ts end
    return tonumber(entry.updatedAt) or 0
end

-- Convert { rev, updatedAt, data = <wire payload> } into a store-shaped owner record.
-- Always source = "summary": the wire contract carries aggregate itemCounts and money,
-- never per-slot containers, which is precisely what "summary" means here (store.lua
-- NewOwner). Returns nil for anything unconvertible.
--
-- `nexus = true` is a VIEW-ONLY provenance marker. Merged views are built on demand
-- and never written back to DaseekiBags2Data, so this field never reaches disk.
function Nexus.ToOwnerRecord(ownerKey, entry)
    if type(ownerKey) ~= "string" or ownerKey == "" then return nil end
    if type(entry) ~= "table" or type(entry.data) ~= "table" then return nil end
    local d = entry.data

    local name, realm = Store.SplitNameRealm(ownerKey)
    local o = Store.NewOwner(ownerKey, name, realm)
    o.source  = "summary"
    o.account = ""                       -- remote/unknown, as migrate.ConvertSummaryChar
    o.class   = d.class
    o.race    = d.race
    o.sex     = tonumber(d.sex)
    o.faction = d.faction
    o.level   = tonumber(d.level) or 0
    o.money   = tonumber(d.money) or 0
    o.rev     = tonumber(entry.rev) or 0
    o.ts      = Nexus.EntryTimestamp(entry)
    if type(d.itemCounts) == "table" then
        for id, n in pairs(d.itemCounts) do
            id, n = tonumber(id), tonumber(n)
            if id and n and id > 0 and n > 0 then o.itemCounts[id] = n end
        end
    end
    o.nexus = true
    return o
end

----------------------------------------------------------------------
-- PURE: the MERGE, and THE PRECEDENCE RULE
--
-- ═══ NEWEST WINS — a fresher Bags-local record is never shadowed by a staler
--     Nexus copy. ═══
--
-- Per owner key, in this order:
--
--   1. Bags holds NOTHING for the key            -> take the Nexus record.
--   2. Bags holds a "full" record                -> KEEP IT, unconditionally. A full
--      record is a locally-captured character with per-slot containers, equipped
--      items and a browsable bank; a summary has none of that. Replacing it with a
--      Nexus summary would trade browsable detail for a money field, which is a
--      capability regression however fresh the summary is. This is the design's
--      "LOCAL characters' full detail stays Bags-owned" line, enforced here.
--   3. Bags holds a "summary" record             -> compare stamps and take the
--      NEWER: Nexus wins only on Nexus.EntryTimestamp(entry) > (localOwner.ts or 0).
--      STRICTLY greater, so a tie leaves the Bags record in place — ties are the
--      normal case for the same snapshot reaching both stores, and a stable
--      tiebreak keeps the money tooltip from flickering between two equal copies.
--
-- KEY ALIASING (gold is sacred): two graphs that disagree about realm spacing or
-- capitalisation for the SAME character would merge as two owners, and the money
-- tooltip totals every owner — inventing gold the player does not have. Local keys
-- are therefore indexed by a normalised form (space-stripped, lowercased) and a
-- Nexus key that normalises onto an existing local key is merged ONTO that key
-- rather than added beside it.
--
-- Neither input table is mutated: the result is a fresh map holding the SAME local
-- owner tables (by reference — the store stays the one writable copy) plus newly
-- built records for the Nexus-sourced entries.
----------------------------------------------------------------------

-- Normalised owner key for alias detection. nil for anything that is not a string.
function Nexus.NormalizeKey(key)
    if type(key) ~= "string" or key == "" then return nil end
    return (key:gsub("%s+", ""):lower())
end

-- localOwners = Store.data.owners shape; nexusOwners = <area>.owners shape.
-- Returns the merged map plus stats { local_, added, refreshed, keptLocal, keptFull }.
function Nexus.MergeOwners(localOwners, nexusOwners)
    local out, byNorm = {}, {}
    local stats = { local_ = 0, added = 0, refreshed = 0, keptLocal = 0, keptFull = 0 }

    if type(localOwners) == "table" then
        for key, o in pairs(localOwners) do
            if type(key) == "string" and type(o) == "table" then
                out[key] = o
                stats.local_ = stats.local_ + 1
                local n = Nexus.NormalizeKey(key)
                if n then byNorm[n] = key end
            end
        end
    end
    if type(nexusOwners) ~= "table" then return out, stats end

    for key, entry in pairs(nexusOwners) do
        local norm = Nexus.NormalizeKey(key)
        if norm and type(entry) == "table" then
            local target = byNorm[norm] or key      -- alias onto the local key when one exists
            local cur = out[target]
            if cur ~= nil and cur.source == "full" then
                stats.keptFull = stats.keptFull + 1              -- rule 2
            else
                local ts = Nexus.EntryTimestamp(entry)
                if cur ~= nil and ts <= (tonumber(cur.ts) or 0) then
                    stats.keptLocal = stats.keptLocal + 1        -- rule 3, local is fresher
                else
                    local rec = Nexus.ToOwnerRecord(target, entry)
                    if rec then
                        if cur == nil then stats.added = stats.added + 1        -- rule 1
                        else stats.refreshed = stats.refreshed + 1 end          -- rule 3, Nexus is fresher
                        out[target] = rec
                        byNorm[norm] = target
                    end
                end
            end
        end
    end
    return out, stats
end

----------------------------------------------------------------------
-- LIVE: the owners view every bridged consumer reads
----------------------------------------------------------------------

Nexus._cache   = nil
Nexus._cacheAt = nil

function Nexus.Invalidate()
    Nexus._cache, Nexus._cacheAt = nil, nil
end

-- The one accessor. Returns Store.data.owners ITSELF when the bridge is inactive —
-- same table, no copy, no allocation — so the standalone path is byte-for-byte the
-- behaviour Bags had before this file existed.
function Nexus.Owners()
    local data = Store and Store.data
    local localOwners = (type(data) == "table" and type(data.owners) == "table") and data.owners or EMPTY

    local active, _, area = Nexus.Status()
    if not active then
        Nexus.Invalidate()
        return localOwners
    end

    local now = (Store and Store.Now and Store.Now()) or 0
    local at  = Nexus._cacheAt
    if Nexus._cache and at and now - at >= 0 and now - at < CACHE_TTL then
        return Nexus._cache
    end
    local merged = Nexus.MergeOwners(localOwners, area.owners)
    Nexus._cache, Nexus._cacheAt = merged, now
    return merged
end

-- Convenience for the two bridged call sites that want a plain iterator.
function Nexus.ForEachOwner(fn)
    for key, o in pairs(Nexus.Owners()) do fn(key, o) end
end

----------------------------------------------------------------------
-- Diagnostics (/bags debug nexus)
----------------------------------------------------------------------

function Nexus.Debug()
    if not ns.Print then return end
    local active, why, area, n = Nexus.Status()
    ns:Print("Nexus bridge: " .. (active and "ACTIVE" or "inactive") .. " — " .. tostring(why))
    local data = Store and Store.data
    local localN = Nexus.CountOwners(data and data.owners)
    if not active then
        ns:Print(string.format("  Bags is sourcing all %d owner(s) from its own store.", localN))
        return
    end
    local _, stats = Nexus.MergeOwners(data and data.owners, area.owners)
    ns:Print(string.format("  local=%d nexus=%d | added=%d refreshed=%d kept-local=%d kept-full=%d",
        localN, n, stats.added, stats.refreshed, stats.keptLocal, stats.keptFull))
    ns:Print(string.format("  mesh import deferral: %s", Nexus.DeferMeshImport() and "ON (Nexus owns remote owners)" or "off"))
    -- BAG-5: whether a deferred mesh half is still owed, and when one was settled.
    -- The deferral itself is only half the story; the DEBT is what bites six months
    -- later, so the diagnostic has to say whether one is outstanding.
    if data then
        if data.meshImportDeferred then
            ns:Print("  1.x mesh half: DEFERRED and still owed — it settles automatically the " ..
                     "first login without the Nexus inventory module (/bags mesh import forces it)")
        elseif data.meshImportCompletedAt then
            ns:Print("  1.x mesh half: settled")
        end
    end
end

----------------------------------------------------------------------
-- Wiring: a fresh capture or a fresh store makes the merged view stale.
----------------------------------------------------------------------

if ns.On then
    ns:On("STORE_READY",   function() Nexus.Invalidate() end)
    ns:On("BAGS_CAPTURED", function() Nexus.Invalidate() end)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "nexus")
----------------------------------------------------------------------

-- A fake global environment carrying a Nexus store, so every probe can be driven
-- headless without touching the real _G.
local function fakeG(owners, opts)
    opts = opts or {}
    local G = {}
    if owners ~= false then
        G.DaseekiNexusData = {
            inventory = {
                schema   = opts.schema or 1,
                migrated = true,
                parts    = {},
                owners   = owners or {},
            },
        }
    end
    if opts.enabled ~= nil then
        G.DaseekiNexusDB = { inventoryEnabled = opts.enabled }
    elseif opts.emptyDB then
        G.DaseekiNexusDB = {}
    end
    return G
end

-- A Nexus graph entry, byte-shaped like the frozen "bags" wire contract.
local function entry(key, money, ts, extra)
    local d = {
        key = key, class = "MAGE", race = "Gnome", sex = 2, faction = "Alliance",
        level = 60, money = money, itemCounts = { [6948] = 1, [4306] = 40 },
        currency = {}, ts = ts,
        mail = { n = 2, money = 500 },     -- the additive field we must simply ignore
    }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { rev = 7, updatedAt = ts + 100, data = d }
end

local function testProbes(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Absent Nexus.
    local area, why = Nexus.Area({})
    ck(area == nil, "no DaseekiNexusData -> no area")
    ck(type(why) == "string" and why:find("not installed"), "absence gives a readable reason")
    ck(Nexus.IsActive({}) == false, "absent Nexus -> bridge inactive")
    ck(Nexus.DeferMeshImport({}) == false, "absent Nexus -> mesh import NOT deferred")

    -- Installed but the module never ran.
    ck(Nexus.Area({ DaseekiNexusData = {} }) == nil, "no .inventory -> no area")
    ck(Nexus.Area({ DaseekiNexusData = { inventory = {} } }) == nil, "no .owners -> no area")
    ck(Nexus.Area({ DaseekiNexusData = { inventory = { owners = "nope" } } }) == nil,
        "non-table owners -> no area")

    -- Present and populated.
    local G = fakeG({ ["Alt-Faerlina"] = entry("Alt-Faerlina", 500, 1700000000) })
    ck(Nexus.Area(G) ~= nil, "populated graph resolves an area")
    local active, reason, _, n = Nexus.Status(G)
    ck(active == true, "populated + enabled -> ACTIVE")
    ck(n == 1, "owner count reported")
    ck(type(reason) == "string" and reason:find("1 owner"), "active reason names the count")
    ck(Nexus.DeferMeshImport(G) == true, "active bridge defers the mesh import")

    -- Empty graph is the fail-safe: never defer to a store with nothing in it.
    local empty = fakeG({})
    ck(Nexus.IsActive(empty) == false, "empty graph -> inactive (fail-safe)")
    ck(select(2, Nexus.Status(empty)):find("empty"), "empty graph says so")

    -- Enablement: absent DB and absent key both read as ON, only explicit false is OFF.
    ck(Nexus.IsEnabled({}) == true, "absent settings DB reads as enabled")
    ck(Nexus.IsEnabled(fakeG({}, { emptyDB = true })) == true, "absent key reads as enabled")
    ck(Nexus.IsEnabled(fakeG({}, { enabled = true })) == true, "explicit true is enabled")
    ck(Nexus.IsEnabled(fakeG({}, { enabled = false })) == false, "explicit false is disabled")
    local offG = fakeG({ ["Alt-Faerlina"] = entry("Alt-Faerlina", 500, 1700000000) }, { enabled = false })
    ck(Nexus.IsActive(offG) == false, "module switched off -> bridge inactive")
    ck(Nexus.DeferMeshImport(offG) == false, "module off -> Bags keeps importing the mesh")

    -- Forward compatibility: a newer schema is refused, not guessed at.
    local futureG = fakeG({ ["A-R"] = entry("A-R", 1, 1) }, { schema = 99 })
    ck(Nexus.Area(futureG) == nil, "a newer schema is refused")
    ck(select(2, Nexus.Area(futureG)):find("schema 99"), "the refusal names the schema")
    ck(Nexus.IsActive(futureG) == false, "newer schema -> inactive, Bags stays standalone")
end

local function testConversion(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local e = entry("Rich-Whitemane", 123456789, 1700000123)
    local o = Nexus.ToOwnerRecord("Rich-Whitemane", e)
    ck(o ~= nil, "entry converts")
    ck(o.nameRealm == "Rich-Whitemane" and o.name == "Rich" and o.realm == "Whitemane",
        "name/realm split from the key")
    ck(o.source == "summary", "a wire payload is always a SUMMARY owner")
    ck(o.account == "", "remote/unknown account bucket")
    ck(o.money == 123456789, "money carried")
    ck(o.class == "MAGE" and o.race == "Gnome" and o.sex == 2
        and o.faction == "Alliance" and o.level == 60, "identity carried")
    ck(o.rev == 7, "rev carried")
    ck(o.ts == 1700000123, "ts is the CAPTURE stamp, not updatedAt")
    ck(o.itemCounts[6948] == 1 and o.itemCounts[4306] == 40, "item counts carried")
    ck(next(o.containers) == nil and next(o.equip) == nil, "a summary has no per-slot detail")
    ck(o.nexus == true, "provenance marked (view-only)")

    -- updatedAt is the fallback only.
    local noTs = { rev = 1, updatedAt = 1700009999, data = { key = "X-R", money = 5 } }
    ck(Nexus.EntryTimestamp(noTs) == 1700009999, "stamp falls back to updatedAt")
    ck(Nexus.EntryTimestamp(entry("A-R", 1, 42)) == 42, "data.ts leads over updatedAt")
    ck(Nexus.EntryTimestamp(nil) == 0 and Nexus.EntryTimestamp({}) == 0, "junk entries stamp 0")

    -- Junk is inert.
    ck(Nexus.ToOwnerRecord("", e) == nil, "empty key -> nil")
    ck(Nexus.ToOwnerRecord("A-R", nil) == nil, "nil entry -> nil")
    ck(Nexus.ToOwnerRecord("A-R", { rev = 1 }) == nil, "entry without data -> nil")
    ck(Nexus.ToOwnerRecord("A-R", { data = { itemCounts = { [0] = 5, ["x"] = 2, [7] = -1, [9] = 3 } } })
        .itemCounts[9] == 3, "junk item counts dropped, the good one kept")
    local junk = Nexus.ToOwnerRecord("A-R", { data = { itemCounts = { [0] = 5, [7] = -1 } } })
    ck(junk.itemCounts[0] == nil and junk.itemCounts[7] == nil, "itemID 0 and negative counts dropped")
    ck(junk.money == 0 and junk.level == 0, "absent numbers default to 0, never nil")
end

-- THE PRECEDENCE RULE, in both directions.
local function testNewestWins(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local localOwners = {
        -- a locally captured character: per-slot detail, Bags-owned
        ["Puuchoco-Whitemane"] = { nameRealm = "Puuchoco-Whitemane", name = "Puuchoco",
            source = "full", money = 39000, ts = 1700000000,
            containers = { [0] = { slots = { [1] = { id = 6948, count = 1 } } } },
            equip = {}, itemCounts = { [6948] = 1 } },
        -- a mesh summary Bags imported itself, captured RECENTLY
        ["Fresh-Whitemane"] = { nameRealm = "Fresh-Whitemane", name = "Fresh",
            source = "summary", money = 111, ts = 1700009000,
            containers = {}, equip = {}, itemCounts = {} },
        -- a mesh summary Bags imported itself, captured LONG AGO
        ["Stale-Whitemane"] = { nameRealm = "Stale-Whitemane", name = "Stale",
            source = "summary", money = 222, ts = 1700001000,
            containers = {}, equip = {}, itemCounts = {} },
        -- a summary whose stamp exactly matches the Nexus copy
        ["Tie-Whitemane"] = { nameRealm = "Tie-Whitemane", name = "Tie",
            source = "summary", money = 333, ts = 1700005000,
            containers = {}, equip = {}, itemCounts = {} },
    }
    local nexusOwners = {
        ["Puuchoco-Whitemane"] = entry("Puuchoco-Whitemane", 999999, 1700009999),  -- newer, but full wins
        ["Fresh-Whitemane"]    = entry("Fresh-Whitemane",    999,    1700002000),  -- STALER than local
        ["Stale-Whitemane"]    = entry("Stale-Whitemane",    777,    1700008000),  -- FRESHER than local
        ["Tie-Whitemane"]      = entry("Tie-Whitemane",      444,    1700005000),  -- exact tie
        ["Remote-Faerlina"]    = entry("Remote-Faerlina",    555,    1700003000),  -- Nexus only
    }

    local merged, stats = Nexus.MergeOwners(localOwners, nexusOwners)

    -- Rule 2: full local detail is never downgraded to a summary, however fresh.
    ck(merged["Puuchoco-Whitemane"].source == "full", "a full local owner is never replaced")
    ck(merged["Puuchoco-Whitemane"].money == 39000, "...and keeps its own money")
    ck(merged["Puuchoco-Whitemane"].containers[0] ~= nil, "...and keeps its browsable slots")
    ck(stats.keptFull == 1, "kept-full counted")

    -- Rule 3, the headline: a STALER Nexus copy never shadows a fresher Bags record.
    ck(merged["Fresh-Whitemane"].money == 111, "staler Nexus copy does NOT shadow the fresher local record")
    ck(merged["Fresh-Whitemane"].nexus == nil, "...the local record is the one that survived")

    -- Rule 3, the other direction: a fresher Nexus copy DOES supersede.
    ck(merged["Stale-Whitemane"].money == 777, "fresher Nexus copy supersedes the staler local record")
    ck(merged["Stale-Whitemane"].nexus == true, "...and is marked Nexus-sourced")
    ck(stats.refreshed == 1, "refreshed counted exactly once")

    -- Ties leave the local record alone (strictly-greater, so no flicker).
    ck(merged["Tie-Whitemane"].money == 333, "an equal stamp leaves the local record in place")
    ck(stats.keptLocal == 2, "kept-local counted for the staler copy and the tie")

    -- Rule 1: an owner Bags has never heard of is added.
    ck(merged["Remote-Faerlina"] ~= nil, "a Nexus-only owner is added")
    ck(merged["Remote-Faerlina"].money == 555 and merged["Remote-Faerlina"].source == "summary",
        "...as a summary owner with its money")
    ck(stats.added == 1, "added counted")

    -- Gold total: exactly one row per character, no phantom duplicates.
    local total = 0
    for _, o in pairs(merged) do total = total + (o.money or 0) end
    ck(total == 39000 + 111 + 777 + 333 + 555, "merged gold total counts each character once")

    -- Neither source table was mutated.
    ck(localOwners["Stale-Whitemane"].money == 222, "the local store was not written")
    ck(nexusOwners["Stale-Whitemane"].data.money == 777, "the Nexus store was not written")
    ck(localOwners["Fresh-Whitemane"].nexus == nil, "no marker leaked onto a local record")

    -- The merged map hands back the SAME local tables (the store stays the one writable copy).
    ck(merged["Fresh-Whitemane"] == localOwners["Fresh-Whitemane"], "local records pass through by reference")

    -- Degenerate inputs.
    -- (parenthesised: MergeOwners returns map + stats, and next(map, stats) would
    --  read the stats table as a KEY -- "invalid key to 'next'")
    ck(next((Nexus.MergeOwners(nil, nil))) == nil, "nil inputs merge to an empty map")
    ck(Nexus.MergeOwners(localOwners, nil)["Stale-Whitemane"].money == 222, "nil Nexus side is a pass-through")
    ck(Nexus.MergeOwners(nil, nexusOwners)["Remote-Faerlina"].money == 555, "nil local side takes everything")
    ck(Nexus.MergeOwners({}, { [42] = entry("x", 1, 1), ["A-R"] = "nope" })["A-R"] == nil,
        "non-string keys and non-table entries are skipped")
end

-- Two graphs disagreeing about realm spacing/case must not invent a second character
-- (and therefore must not invent gold).
local function testKeyAliasing(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Nexus.NormalizeKey("Puu-Blood Sail Buccaneers") == "puu-bloodsailbuccaneers",
        "normalize strips spaces and case")
    ck(Nexus.NormalizeKey(nil) == nil and Nexus.NormalizeKey("") == nil, "junk normalizes to nil")

    local localOwners = {
        ["Puu-Whitemane"] = { nameRealm = "Puu-Whitemane", name = "Puu", source = "summary",
                              money = 100, ts = 1700000000, containers = {}, equip = {}, itemCounts = {} },
    }
    local merged = Nexus.MergeOwners(localOwners, {
        ["puu-whitemane"] = entry("puu-whitemane", 900, 1700009000),   -- same char, different case
    })
    local n = 0
    for _ in pairs(merged) do n = n + 1 end
    ck(n == 1, "a case-variant key merges onto the local owner instead of doubling it")
    ck(merged["Puu-Whitemane"].money == 900, "...and the fresher copy still wins on the local key")
    ck(merged["puu-whitemane"] == nil, "no second row under the variant key")

    -- ...and the staler direction still holds through the alias.
    local merged2 = Nexus.MergeOwners(localOwners, {
        ["puu-whitemane"] = entry("puu-whitemane", 900, 1699000000),   -- older
    })
    ck(merged2["Puu-Whitemane"].money == 100, "a staler aliased copy does not shadow the local record")
end

-- The standalone contract: with no Nexus, Owners() is the store's own table, and the
-- cache never serves a merged view.
local function testLiveFallback(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedData = _G.DaseekiNexusData
    local savedDB   = _G.DaseekiNexusDB
    _G.DaseekiNexusData, _G.DaseekiNexusDB = nil, nil
    Nexus.Invalidate()

    local okStore = Store and Store.data and type(Store.data.owners) == "table"
    ck(okStore, "store is initialised for the live check")
    if okStore then
        ck(Nexus.Owners() == Store.data.owners,
            "with no Nexus, Owners() returns the store's own table (no copy, no allocation)")
        ck(Nexus._cache == nil, "inactive bridge holds no cache")
    end
    ck(Nexus.IsActive() == false, "live probe against the real _G is inactive headless")
    ck(Nexus.DeferMeshImport() == false, "...so the mesh import is NOT deferred headless")

    -- Now install a Nexus store on the REAL _G and confirm the live path merges + caches.
    _G.DaseekiNexusData = { inventory = { schema = 1, owners = {
        ["Ghost-Faerlina"] = entry("Ghost-Faerlina", 4242, 1700000500),
    } } }
    Nexus.Invalidate()
    ck(Nexus.IsActive() == true, "a live Nexus store activates the bridge")
    local view = Nexus.Owners()
    ck(view ~= Store.data.owners, "an active bridge returns a merged view, not the store table")
    ck(view["Ghost-Faerlina"] ~= nil and view["Ghost-Faerlina"].money == 4242,
        "the Nexus owner is visible to the bridged consumers")
    ck(Nexus.Owners() == view, "the merged view is cached within the TTL")
    ck(Store.data.owners["Ghost-Faerlina"] == nil, "and NOTHING was written into the Bags store")

    -- Diagnostics must not error on either path.
    ck(pcall(Nexus.Debug), "Nexus.Debug runs against an active bridge")
    _G.DaseekiNexusData = nil
    Nexus.Invalidate()
    ck(pcall(Nexus.Debug), "Nexus.Debug runs against an inactive bridge")
    ck(Nexus.Owners() == Store.data.owners, "removing Nexus returns the standalone table immediately")

    _G.DaseekiNexusData, _G.DaseekiNexusDB = savedData, savedDB
    Nexus.Invalidate()
end

function Nexus.RunSelfTests(verbose)
    local suites = {
        { name = "presence + enablement probes", fn = testProbes },
        { name = "wire payload -> owner record", fn = testConversion },
        { name = "newest-wins precedence",       fn = testNewestWins },
        { name = "key aliasing (no phantom gold)", fn = testKeyAliasing },
        { name = "live fallback + cache",        fn = testLiveFallback },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS nexus/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL nexus/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("nexus", Nexus.RunSelfTests)
end

return Nexus
