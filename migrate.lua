-- Daseeki Bags 2.0 — migrate.lua
-- One-time, READ-ONLY, marker-guarded, idempotent conversion of the 1.x
-- SavedVariables into the 2.0 store. The 1.x globals are NEVER written.
--
-- 1.x source globals (verified from the shipping .toc and real WTF copies):
--   DaseekiBagsAccount[realm][char] = FULL per-slot data for THIS account's
--       characters. Container ids are the char table's NUMERIC keys:
--         [0]=backpack, [1..N]=carried bags, [-1]=bank, [-2]=keyring,
--         [N+1..]=bank bags. Each container = { items={[slot]="id" | "id;count"},
--         size=<n>, link="<bagItemId>" }. Non-container fields are string-keyed:
--         money, class, race, sex, faction, level, equip={[invSlot]="id[;count]"},
--         mesh={itemCounts={[id]=n}, rev=n}, guild, mail, currency.
--   DaseekiBagsMesh[realm][char] = SUMMARY for characters known through the
--       cross-account mesh: { money, level, class, race, sex, faction,
--       itemCounts={[id]=n}, rev, ts } — NO bag slots. This is what powered
--       1.x cross-account gold totals, so it MUST be converted (D1: gold sacred).
--   DaseekiBagsSets = 1.x settings/colors (not migrated here; W4 owns options).
--
-- Because SavedVariables are per-account, one account's file already contains
-- its own FULL characters plus SUMMARY entries for every other account's
-- characters. Converting both preserves the exact cross-account view 1.x had.
--
-- Idempotency: a marker (data.migratedFrom1x) guards the whole pass so a later
-- user edit in 2.0 (e.g. deleting an owner) is never re-clobbered by a re-run.
--
-- MARKER DISCIPLINE (ROLLOUT_CONTINUITY_AUDIT AT-RISK-1c; house pattern taken from
-- Daseeki-Conduit's migrate.lua, where an absent source returns BEFORE the marker is
-- written). The marker is set ONLY when the pass actually converted at least one
-- owner. A run against an absent or empty 1.x source leaves it UNSET, so the import
-- still happens when the source turns up later — the addon installed before the WTF
-- file was copied over, a second machine, 1.x re-enabled after being disabled for a
-- session. A marker written on an empty run is a permanently sticky "already done"
-- that can never be cleared from the UI, which is exactly the defect the audit found
-- in the Nexus Bags-import and Inventory-module one-shots.
--
-- SELF-HEAL: a DB that already carries a sticky marker from the pre-fix build (or any
-- other route to marker-set-but-nothing-imported) is repaired at startup — see
-- Migrate.SelfHeal, which re-runs the import forcibly and says so loudly.
--
-- MESH-IMPORT DEFERRAL (Nexus Inventory module, W2). When the Daseeki-Nexus Inventory
-- store is ACTIVE (see nexus.lua), it — not Bags — is the system of record for REMOTE
-- owners, so step 2 below (DaseekiBagsMesh -> summary owners) is skipped and Bags
-- reads those characters through the bridge instead of holding its own copies. Step 1
-- is untouched: THIS account's characters keep their full per-slot detail from
-- DaseekiBagsAccount, converted and owned by Bags exactly as before.
--
-- The deferral is threaded through as `opts.deferMesh` rather than probed inside these
-- functions, so every one of them stays pure and the harness can drive both directions
-- deterministically. It also flows into CountSourceChars, and therefore into SelfHeal:
-- a source census that counted deferred mesh records would make the self-heal fire on
-- a run that is CORRECTLY importing nothing, burning its bounded attempts and printing
-- a repair notice for a store that is not broken.

local ADDON, ns = ...

local Migrate = {}
ns.Migrate = Migrate

local Store = ns.Store

----------------------------------------------------------------------
-- Parsing: "id" or "id;count" -> id (number), count (number, default 1)
----------------------------------------------------------------------

function Migrate.ParseItemRef(str)
    if type(str) == "number" then return str, 1 end
    if type(str) ~= "string" then return nil, nil end
    local id, count = string.match(str, "^(%d+);(%d+)$")
    if id then return tonumber(id), tonumber(count) end
    id = string.match(str, "^(%d+)$")
    if id then return tonumber(id), 1 end
    -- Some 1.x links stored a full "id;count;..." with trailing fields; take the
    -- leading id;count pair defensively.
    id, count = string.match(str, "^(%d+);(%d+)")
    if id then return tonumber(id), tonumber(count) end
    id = string.match(str, "^(%d+)")
    if id then return tonumber(id), 1 end
    return nil, nil
end

----------------------------------------------------------------------
-- Convert one 1.x container -> a 2.0 store container (or nil to skip).
-- Truly-empty {} entries (unowned bag slots) are skipped; real storage
-- (backpack/bank with a size, or any container with items/link) is kept.
----------------------------------------------------------------------

function Migrate.ConvertContainer(oldC)
    if type(oldC) ~= "table" then return nil, 0 end
    local hasItems = type(oldC.items) == "table" and next(oldC.items) ~= nil
    local hasSize  = type(oldC.size) == "number" and oldC.size > 0
    if not hasItems and not hasSize and oldC.link == nil then
        return nil, 0   -- empty/unowned bag slot
    end
    local link = oldC.link
    if type(link) == "string" then link = tonumber(link) or link end
    local c = Store.NewContainer(oldC.size or 0, link)
    local nSlots = 0
    if type(oldC.items) == "table" then
        for slot, ref in pairs(oldC.items) do
            local id, count = Migrate.ParseItemRef(ref)
            if id then
                c.slots[slot] = Store.NewSlot(id, count)   -- quality unknown from 1.x
                nSlots = nSlots + 1
            end
        end
    end
    return c, nSlots
end

----------------------------------------------------------------------
-- Convert a FULL 1.x character into an owner record.
-- Returns owner, { containers, slots }.
----------------------------------------------------------------------

function Migrate.ConvertFullChar(realm, name, oldChar, account)
    local nameRealm = Store.MakeNameRealm(name, realm)
    local o = Store.NewOwner(nameRealm, name, realm)
    o.source  = "full"
    o.account = account or ""

    o.class   = oldChar.class
    o.race    = oldChar.race
    o.sex     = oldChar.sex
    o.faction = oldChar.faction
    o.level   = oldChar.level or 0
    o.money   = oldChar.money or 0

    local nContainers, nSlots = 0, 0
    for k, v in pairs(oldChar) do
        if type(k) == "number" and type(v) == "table" then   -- a container id
            local c, sc = Migrate.ConvertContainer(v)
            if c then
                o.containers[k] = c
                nContainers = nContainers + 1
                nSlots = nSlots + sc
            end
        end
    end

    -- Equipped items (appearance-relevant): string key "equip" = { [invSlot]=ref }
    if type(oldChar.equip) == "table" then
        for invSlot, ref in pairs(oldChar.equip) do
            local id, count = Migrate.ParseItemRef(ref)
            if id then o.equip[invSlot] = { id = id, count = count } end
        end
    end

    -- 1.x pre-aggregated item counts live under mesh.itemCounts; carry them so
    -- tooltip counts survive before the first live recapture. Recompute from
    -- our own converted containers where possible (more authoritative), falling
    -- back to the stored aggregate.
    Store.RecomputeItemCounts(o, true)
    if next(o.itemCounts) == nil and type(oldChar.mesh) == "table"
       and type(oldChar.mesh.itemCounts) == "table" then
        for id, n in pairs(oldChar.mesh.itemCounts) do o.itemCounts[id] = n end
    end
    if type(oldChar.mesh) == "table" and oldChar.mesh.rev then
        o.rev = oldChar.mesh.rev
    end
    o.ts = Store.Now()

    return o, { containers = nContainers, slots = nSlots }
end

----------------------------------------------------------------------
-- Convert a SUMMARY (mesh) 1.x character into an owner record (no containers).
----------------------------------------------------------------------

function Migrate.ConvertSummaryChar(realm, name, oldMesh)
    local nameRealm = Store.MakeNameRealm(name, realm)
    local o = Store.NewOwner(nameRealm, name, realm)
    o.source  = "summary"
    o.account = ""          -- remote/unknown account (flat, as 1.x mesh was)

    o.class   = oldMesh.class
    o.race    = oldMesh.race
    o.sex     = oldMesh.sex
    o.faction = oldMesh.faction
    o.level   = oldMesh.level or 0
    o.money   = oldMesh.money or 0
    o.rev     = oldMesh.rev or 0
    o.ts      = oldMesh.ts or 0

    if type(oldMesh.itemCounts) == "table" then
        for id, n in pairs(oldMesh.itemCounts) do o.itemCounts[id] = n end
    end
    return o
end

----------------------------------------------------------------------
-- The migration pass. Operates directly on `data` (the store cache DB), so
-- tests can pass a standalone table. READ-ONLY on oldAccount / oldMesh.
--
--   data       : the 2.0 cache DB (data.owners, data.migratedFrom1x)
--   oldAccount : DaseekiBagsAccount (may be nil)
--   oldMesh    : DaseekiBagsMesh (may be nil)
--   opts       : { selfAccount=<id>, force=<bool>, deferMesh=<bool> }
-- Returns counts { skipped, owners, full, summary, containers, slots, meshDeferred }.
----------------------------------------------------------------------

function Migrate.Run(data, oldAccount, oldMesh, opts)
    opts = opts or {}
    if type(data) ~= "table" then return { skipped = true } end
    if type(data.owners) ~= "table" then data.owners = {} end
    if data.migratedFrom1x and not opts.force then
        return { skipped = true }
    end

    local selfAccount = opts.selfAccount or data.selfAccount or ""
    local deferMesh   = opts.deferMesh and true or false
    local counts = { skipped = false, owners = 0, full = 0, summary = 0,
                     containers = 0, slots = 0, meshDeferred = deferMesh }

    -- 1) FULL characters (this account) — authoritative, keyed with selfAccount.
    if type(oldAccount) == "table" then
        for realm, chars in pairs(oldAccount) do
            if type(chars) == "table" then
                for name, oldChar in pairs(chars) do
                    if type(oldChar) == "table" then
                        local o, c = Migrate.ConvertFullChar(realm, name, oldChar, selfAccount)
                        data.owners[o.nameRealm] = o
                        counts.owners = counts.owners + 1
                        counts.full = counts.full + 1
                        counts.containers = counts.containers + c.containers
                        counts.slots = counts.slots + c.slots
                    end
                end
            end
        end
    end

    -- 2) SUMMARY characters (mesh) — only for owners not already FULL, so our
    --    own converted characters keep their per-slot data and are not
    --    downgraded to a summary.
    --
    --    DEFERRED when the Nexus Inventory store is active: those same remote
    --    characters live in the Nexus owners graph, which is then the system of
    --    record for them, and nexus.lua serves them to the summary consumers with
    --    a newest-wins merge. Importing our own second copy here would give the
    --    money tooltip two sources for one character and put Bags in the business
    --    of ageing remote data it no longer receives.
    if type(oldMesh) == "table" and not deferMesh then
        for realm, chars in pairs(oldMesh) do
            if type(chars) == "table" then
                for name, oldMeshChar in pairs(chars) do
                    if type(oldMeshChar) == "table" then
                        local nameRealm = Store.MakeNameRealm(name, realm)
                        local existing = data.owners[nameRealm]
                        if not existing then
                            data.owners[nameRealm] = Migrate.ConvertSummaryChar(realm, name, oldMeshChar)
                            counts.owners = counts.owners + 1
                            counts.summary = counts.summary + 1
                        elseif existing.source == "full" then
                            -- Backfill only genuinely-missing fields; never
                            -- overwrite the fuller record.
                            if (existing.money or 0) == 0 and oldMeshChar.money then
                                existing.money = oldMeshChar.money
                            end
                        end
                    end
                end
            end
        end
    end

    -- Marker discipline (AT-RISK-1c): set ONLY on a non-empty result. Zero owners
    -- means there was nothing to read (no source, empty source, or a source shaped
    -- so unexpectedly that nothing converted) — leaving the marker unset keeps the
    -- door open for the real source to arrive on a later login.
    if counts.owners == 0 then
        counts.markerSet = false
        return counts
    end

    data.migratedFrom1x = true
    counts.markerSet = true
    return counts
end

----------------------------------------------------------------------
-- Source census: how many 1.x character records the source globals actually hold.
-- READ-ONLY. Used by the self-heal to tell "nothing to import" (a legitimately
-- empty source; leave everything alone) apart from "something to import but the
-- marker says we already did" (the sticky-marker anomaly).
--
-- `deferMesh` must match the flag Migrate.Run is being given, because the census
-- answers "is there anything this pass WOULD import?". With the mesh deferred to the
-- Nexus store, mesh records are not importable, and counting them would make the
-- self-heal diagnose an anomaly in a store that is behaving exactly as designed.
--
-- The two sources are counted by explicit calls rather than by iterating a
-- {oldAccount, oldMesh} literal: with oldAccount nil that literal is {[2]=oldMesh},
-- whose ipairs stops at the hole and visits NOTHING — so a store whose only 1.x
-- source is DaseekiBagsMesh censused as 0 and could never be self-healed.
----------------------------------------------------------------------

local function countChars(src)
    local n = 0
    if type(src) ~= "table" then return n end
    for _, chars in pairs(src) do
        if type(chars) == "table" then
            for _, rec in pairs(chars) do
                if type(rec) == "table" then n = n + 1 end
            end
        end
    end
    return n
end

function Migrate.CountSourceChars(oldAccount, oldMesh, deferMesh)
    local n = countChars(oldAccount)
    if not deferMesh then n = n + countChars(oldMesh) end
    return n
end

----------------------------------------------------------------------
-- Startup self-heal (ROLLOUT_CONTINUITY_AUDIT AT-RISK-1c).
--
-- The anomaly: the marker says the 1.x import is done, the store holds ZERO owners,
-- and the 1.x source is sitting right there with real characters in it. That is a
-- migration that never happened but can never retry — the user's alts, banks and
-- cross-account gold are simply missing, with nothing on screen to explain it.
--
-- Detect it and force the import through, loudly (a silent repair of missing data is
-- indistinguishable from the bug for anyone comparing the window against 1.x).
--
-- Bounded: each attempt is counted, and after MAX_SELFHEAL_ATTEMPTS the pass stops
-- trying, so a pathological source can never turn into a chat-spam loop on every
-- login. A successful heal converts owners, which makes the trigger condition false
-- forever after anyway.
--
--   data       : the 2.0 cache DB
--   oldAccount / oldMesh : the 1.x globals (never written)
--   opts       : { selfAccount=<id>, quiet=<bool>, deferMesh=<bool> }
-- Returns the forced-run counts, or nil when nothing needed healing.
--
-- deferMesh flows through UNCHANGED into both the census and the forced run, so a
-- repair never re-imports what the Nexus store now owns — and, just as important,
-- never diagnoses an anomaly that is only the deferral doing its job.
----------------------------------------------------------------------

Migrate.MAX_SELFHEAL_ATTEMPTS = 3

function Migrate.SelfHeal(data, oldAccount, oldMesh, opts)
    opts = opts or {}
    if type(data) ~= "table" then return nil end
    if not data.migratedFrom1x then return nil end          -- normal path owns this
    if type(data.owners) == "table" and next(data.owners) ~= nil then return nil end

    local available = Migrate.CountSourceChars(oldAccount, oldMesh, opts.deferMesh)
    if available == 0 then return nil end   -- nothing importable; marker is honest

    local attempts = tonumber(data.selfHealAttempts) or 0
    if attempts >= Migrate.MAX_SELFHEAL_ATTEMPTS then return nil end
    data.selfHealAttempts = attempts + 1

    if not opts.quiet and ns and ns.Print then
        ns:Print(("1.x import repair: the saved data holds %d character record(s) but " ..
                  "none were imported, while the one-time import was already marked done. " ..
                  "Re-importing now."):format(available))
    end

    local counts = Migrate.Run(data, oldAccount, oldMesh,
                               { selfAccount = opts.selfAccount or data.selfAccount or "",
                                 force = true, deferMesh = opts.deferMesh })
    counts.selfHealed = true
    counts.sourceChars = available

    if not opts.quiet and ns and ns.Print then
        if counts.owners > 0 then
            ns:Print(("1.x import repair complete: %d character(s) restored (%d with full bag " ..
                      "contents, %d cross-account summaries)."):format(counts.owners, counts.full, counts.summary))
        else
            ns:Print("1.x import repair found no convertible characters; the saved 1.x data " ..
                     "is present but not in a shape this version can read. Nothing was changed.")
        end
    end
    return counts
end

----------------------------------------------------------------------
-- Live wrapper: read the 1.x globals and migrate into the attached store.
-- Runs once at login (after Store.Init); a no-op if already migrated.
--
-- The Nexus bridge is probed HERE, once, at the migration moment — not cached at
-- load and not consulted inside the pure passes. ns.Nexus ships with this addon, but
-- the call is still guarded the house way: an absent or half-loaded bridge simply
-- reads as "not deferring", which is the pre-bridge behaviour.
----------------------------------------------------------------------

function Migrate.Migrate()
    if not Store.data then return { skipped = true } end
    local deferMesh = (ns.Nexus and ns.Nexus.DeferMeshImport and ns.Nexus.DeferMeshImport()) and true or false
    local opts = { selfAccount = Store.data.selfAccount or "", deferMesh = deferMesh }
    local counts = Migrate.Run(Store.data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, opts)

    -- A skipped run means the marker was already set. That is normal on every login
    -- after the first — but it is also the sticky-marker anomaly's signature, so check.
    if counts.skipped then
        local healed = Migrate.SelfHeal(Store.data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, opts)
        if healed then counts = healed end
    end

    -- The SETTINGS + custom-rules pass (audit NW-1) runs at this same migration
    -- moment, against a different source global with its own marker. Optional by
    -- design: if migrate_settings.lua is absent the owner data still converts.
    if ns.MigrateSettings and ns.MigrateSettings.Migrate then
        counts.settings = ns.MigrateSettings.Migrate()
    end
    return counts
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "migrate")
----------------------------------------------------------------------

-- A tiny inline 1.x-shaped fixture (structure-faithful, values trimmed).
local function sampleAccount()
    return {
        ["Whitemane"] = {
            ["Puuchoco"] = {
                [0]  = { items = { [1] = "6948", [12] = "22261;10" }, size = 20 },
                [1]  = { items = { "22157", "22157" }, size = 14, link = "14046" },
                [4]  = { },                       -- unowned bag slot (skip)
                [-1] = { items = { [3] = "4306;20" }, size = 24 },   -- bank main
                [-2] = { items = { [1] = "5175" }, size = 32 },      -- keyring
                ["equip"] = { [7] = "139", [18] = "3111;100" },
                ["money"] = 39000,
                ["class"] = "WARRIOR", ["race"] = "Troll", ["sex"] = 2,
                ["faction"] = "Horde", ["level"] = 60,
                ["mesh"] = { itemCounts = { [22157] = 2, [22261] = 10 }, rev = 32 },
            },
        },
    }
end

local function sampleMesh()
    return {
        ["Whitemane"] = {
            ["Puuchoco"] = {   -- same char as FULL -> must NOT downgrade
                money = 39000, level = 60, class = "WARRIOR", faction = "Horde",
                itemCounts = { [22157] = 2 }, rev = 32, ts = 111,
            },
            ["Shalk"] = {      -- remote char, summary only
                money = 1022693, level = 60, class = "SHAMAN", race = "Orc",
                faction = "Horde", itemCounts = { [6948] = 1, [13724] = 52 },
                rev = 179, ts = 222,
            },
        },
    }
end

local function testParse(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local id, n = Migrate.ParseItemRef("22261;10"); ck(id == 22261 and n == 10, "id;count parse")
    id, n = Migrate.ParseItemRef("22157");          ck(id == 22157 and n == 1, "bare id -> count 1")
    id, n = Migrate.ParseItemRef("3111;100");        ck(id == 3111 and n == 100, "large count parse")
    ck(Migrate.ParseItemRef("") == nil, "empty string -> nil")
    ck(Migrate.ParseItemRef(nil) == nil, "nil -> nil")
end

local function testConvertContainer(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local c, sc = Migrate.ConvertContainer({ items = { [1] = "22157", [13] = "22261;2" },
                                             size = 14, link = "14046" })
    ck(c.size == 14 and c.link == 14046, "size + numeric link")
    ck(c.slots[1].id == 22157 and c.slots[1].count == 1, "slot 1")
    ck(c.slots[13].id == 22261 and c.slots[13].count == 2, "slot 13 with count")
    ck(c.slots[1].quality == nil, "quality left nil (derived at render)")
    ck(sc == 2, "slot count = 2")
    ck(Migrate.ConvertContainer({}) == nil, "empty {} -> nil (unowned bag)")
end

local function testEndToEndAndIdempotency(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local data = Store._defaultData()
    data.selfAccount = "acctSELF"
    local r = Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF" })
    ck(r.skipped == false, "first run not skipped")
    ck(r.full == 1, "one full char (Puuchoco)")
    ck(r.summary == 1, "one summary char (Shalk); Puuchoco mesh not double-counted")
    ck(r.owners == 2, "two owners total")

    local pu = data.owners["Puuchoco-Whitemane"]
    ck(pu.source == "full" and pu.account == "acctSELF", "Puuchoco full + self account")
    ck(pu.money == 39000 and pu.class == "WARRIOR", "Puuchoco money/class")
    ck(pu.containers[0] and pu.containers[-1] and pu.containers[-2], "backpack/bank/keyring kept")
    ck(pu.containers[4] == nil, "empty bag slot 4 skipped")
    ck(pu.containers[0].slots[12].id == 22261 and pu.containers[0].slots[12].count == 10,
        "backpack slot 12 = 22261 x10")
    ck(pu.equip[18].id == 3111 and pu.equip[18].count == 100, "equipped ammo id;count")
    -- itemCounts recomputed from converted containers + equip (authoritative).
    ck(pu.itemCounts[22157] == 2, "Puuchoco 22157 count from slots")

    local sh = data.owners["Shalk-Whitemane"]
    ck(sh.source == "summary" and sh.account == "", "Shalk summary + unknown account")
    ck(sh.money == 1022693 and next(sh.containers) == nil, "Shalk money, no containers")
    ck(sh.itemCounts[13724] == 52, "Shalk itemCounts carried")

    -- Cross-account gold total (D1): full + summary both participate.
    -- Recreate the store-total math directly on the data.
    local total = 0
    for _, o in pairs(data.owners) do total = total + (o.money or 0) end
    ck(total == 39000 + 1022693, "cross-account gold total = full + summary money")

    -- Idempotency: a second run is skipped and mutates nothing.
    local before = pu.money
    local r2 = Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF" })
    ck(r2.skipped == true, "second run skipped via marker")
    ck(data.owners["Puuchoco-Whitemane"].money == before, "owners unchanged on skip")
    ck(Store.OwnerCount ~= nil, "store still intact")

    -- Read-only guarantee: converting must not have mutated the source tables.
    local acc = sampleAccount()
    Migrate.Run(Store._defaultData(), acc, nil, { selfAccount = "x" })
    ck(acc["Whitemane"]["Puuchoco"]["money"] == 39000, "source account not mutated")
    ck(acc["Whitemane"]["Puuchoco"][0].items[1] == "6948", "source item strings not mutated")
end

-- AT-RISK-1c: the marker must never be written by a run that imported nothing, and a
-- source that only shows up later must still import.
local function testEmptySourceLeavesMarkerUnset(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- 1) No source at all (the 1.x addon was never installed / SV never written).
    local data = Store._defaultData()
    local r = Migrate.Run(data, nil, nil, { selfAccount = "acctSELF" })
    ck(r.skipped == false, "a run with no source still executes (it is not 'already done')")
    ck(r.owners == 0, "no source converts no owners")
    ck(r.markerSet == false, "marker reported as NOT set")
    ck(data.migratedFrom1x == false, "marker left unset after an empty run")

    -- 2) Present but empty tables (1.x installed, never logged a character).
    local data2 = Store._defaultData()
    Migrate.Run(data2, {}, {}, { selfAccount = "acctSELF" })
    ck(data2.migratedFrom1x == false, "empty source tables leave the marker unset")

    -- 3) Realms present but holding no character records.
    local data3 = Store._defaultData()
    Migrate.Run(data3, { ["Whitemane"] = {} }, nil, { selfAccount = "acctSELF" })
    ck(data3.migratedFrom1x == false, "empty realm table leaves the marker unset")

    -- 4) THE POINT OF THE RULE: the source appears on a later login and imports.
    local r4 = Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF" })
    ck(r4.skipped == false, "late-appearing source is not blocked by a marker")
    ck(r4.owners == 2, "late-appearing source imports both owners")
    ck(r4.markerSet == true and data.migratedFrom1x == true, "marker set once real data landed")

    -- ...and only then does the guard engage.
    ck(Migrate.Run(data, sampleAccount(), sampleMesh(), {}).skipped == true,
        "marker now guards re-runs")
end

-- AT-RISK-1c self-heal: marker true + zero owners + a real source = repair it.
local function testSelfHeal(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local quiet = { selfAccount = "acctSELF", quiet = true }

    -- The anomaly: a DB carrying a sticky marker from the pre-fix build.
    local data = Store._defaultData()
    data.migratedFrom1x = true              -- "already imported"
    ck(Migrate.Run(data, sampleAccount(), sampleMesh(), quiet).skipped == true,
        "the normal path is blocked by the sticky marker (this is the bug)")
    ck(next(data.owners) == nil, "and the store is still empty")

    local healed = Migrate.SelfHeal(data, sampleAccount(), sampleMesh(), quiet)
    ck(healed ~= nil, "self-heal fired")
    ck(healed.selfHealed == true and healed.sourceChars == 3, "reports the heal + source census")
    ck(healed.owners == 2, "self-heal imported both owners")
    ck(data.owners["Puuchoco-Whitemane"].money == 39000, "full char restored with its money")
    ck(data.owners["Shalk-Whitemane"].source == "summary", "summary char restored")
    ck(data.selfHealAttempts == 1, "attempt counted")

    -- Now healthy: the trigger condition is false, so it never fires again.
    ck(Migrate.SelfHeal(data, sampleAccount(), sampleMesh(), quiet) == nil,
        "no re-heal once owners exist")

    -- Not an anomaly: marker set and the source is genuinely empty (the ordinary
    -- state of a fresh 2.0 install that already ran once against nothing).
    local clean = Store._defaultData()
    clean.migratedFrom1x = true
    ck(Migrate.SelfHeal(clean, nil, nil, quiet) == nil, "empty source is not an anomaly")
    ck(clean.selfHealAttempts == nil, "and costs no attempt")

    -- Not an anomaly: marker unset (the normal path owns that case).
    local fresh = Store._defaultData()
    ck(Migrate.SelfHeal(fresh, sampleAccount(), nil, quiet) == nil, "unset marker is not an anomaly")

    -- Bounded: an unconvertible-but-present source cannot spam forever.
    local weird = Store._defaultData()
    weird.migratedFrom1x = true
    local junk = { ["Whitemane"] = { ["Ghost"] = "not-a-table" } }
    ck(Migrate.CountSourceChars(junk, nil) == 0, "non-table records are not counted as source")
    -- A source that counts but converts to nothing: records are tables, but the whole
    -- pass yields owners because ANY table converts -- so force the bound directly.
    weird.selfHealAttempts = Migrate.MAX_SELFHEAL_ATTEMPTS
    ck(Migrate.SelfHeal(weird, sampleAccount(), nil, quiet) == nil,
        "attempts are bounded (no login-loop chat spam)")

    -- The loud print path must not error (harness re-points ns.Print to its log).
    local noisy = Store._defaultData()
    noisy.migratedFrom1x = true
    local okPrint = pcall(Migrate.SelfHeal, noisy, sampleAccount(), nil, { selfAccount = "x" })
    ck(okPrint, "the loud repair notice prints without error")
end

-- W2 (Nexus bridge): the mesh-import deferral, and the proof that it does not
-- disturb the cutover-continuity contract it sits next to.
local function testMeshDeferral(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local defer = { selfAccount = "acctSELF", deferMesh = true }
    local normal = { selfAccount = "acctSELF" }

    -- 1) THE DEFERRAL. Local characters still convert in full; the mesh summaries
    --    are left to the Nexus store.
    local data = Store._defaultData()
    local r = Migrate.Run(data, sampleAccount(), sampleMesh(), defer)
    ck(r.skipped == false, "a deferred run still executes")
    ck(r.meshDeferred == true, "the run reports the deferral")
    ck(r.full == 1, "LOCAL characters still convert with full detail")
    ck(r.summary == 0, "no mesh summaries imported while Nexus owns them")
    ck(r.owners == 1, "one owner total")
    ck(data.owners["Shalk-Whitemane"] == nil, "the remote character is NOT in the Bags store")
    local pu = data.owners["Puuchoco-Whitemane"]
    ck(pu ~= nil and pu.source == "full", "the local character is present and full")
    ck(pu.containers[0] and pu.containers[-1], "...with its bags and bank intact")
    ck(pu.money == 39000, "...and its money")
    ck(data.migratedFrom1x == true, "a deferred run that converted an owner still latches the marker")

    -- 2) The NON-deferred run is unchanged (regression guard on the default path).
    local data2 = Store._defaultData()
    local r2 = Migrate.Run(data2, sampleAccount(), sampleMesh(), normal)
    ck(r2.meshDeferred == false, "the default path reports no deferral")
    ck(r2.summary == 1 and data2.owners["Shalk-Whitemane"] ~= nil,
        "without Nexus the mesh summary is imported exactly as before")

    -- 3) MARKER DISCIPLINE survives the deferral: a mesh-ONLY source with the mesh
    --    deferred converts nothing, so the marker must stay clear and the import must
    --    still land if Nexus later goes away.
    local data3 = Store._defaultData()
    local r3 = Migrate.Run(data3, nil, sampleMesh(), defer)
    ck(r3.owners == 0, "mesh-only source + deferral converts nothing")
    ck(r3.markerSet == false and data3.migratedFrom1x == false,
        "...and therefore leaves the marker UNSET (AT-RISK-1c holds)")
    local r3b = Migrate.Run(data3, nil, sampleMesh(), normal)
    ck(r3b.summary == 2 and data3.migratedFrom1x == true,
        "...so removing Nexus later still imports the mesh and latches then")

    -- 4) SELF-HEAL still works with the deferral on, and is not misfired BY it.
    local quiet = { selfAccount = "acctSELF", quiet = true, deferMesh = true }

    --    (a) census: deferred mesh records are not "available to import".
    ck(Migrate.CountSourceChars(sampleAccount(), sampleMesh(), false) == 3,
        "census counts both sources when nothing is deferred")
    ck(Migrate.CountSourceChars(sampleAccount(), sampleMesh(), true) == 1,
        "census counts only the local source when the mesh is deferred")
    ck(Migrate.CountSourceChars(nil, sampleMesh(), false) == 2,
        "census sees a mesh-only source (no ipairs hole)")
    ck(Migrate.CountSourceChars(nil, sampleMesh(), true) == 0,
        "...and reports nothing importable when that mesh is deferred")

    --    (b) the real anomaly still heals, and heals WITHOUT re-importing the mesh.
    local sticky = Store._defaultData()
    sticky.migratedFrom1x = true
    local healed = Migrate.SelfHeal(sticky, sampleAccount(), sampleMesh(), quiet)
    ck(healed ~= nil, "self-heal still fires under the deferral")
    ck(healed.sourceChars == 1, "census reported only the importable (local) records")
    ck(healed.owners == 1 and healed.full == 1 and healed.summary == 0,
        "the repair restored the local character and left the mesh to Nexus")
    ck(sticky.owners["Puuchoco-Whitemane"].money == 39000, "the repaired character kept its money")
    ck(sticky.selfHealAttempts == 1, "attempt counted exactly once")

    --    (c) THE MISFIRE GUARD: marker set, store empty, and the ONLY 1.x source is a
    --        mesh the Nexus store now owns. Nothing is broken — the store is empty
    --        because Bags correctly imported nothing — so the repair must NOT fire,
    --        must not print, and must not spend an attempt.
    local honest = Store._defaultData()
    honest.migratedFrom1x = true
    ck(Migrate.SelfHeal(honest, nil, sampleMesh(), quiet) == nil,
        "a deferred mesh-only source is not an anomaly")
    ck(honest.selfHealAttempts == nil, "...and costs no self-heal attempt")
    --        ...while the same state WITHOUT the deferral is still the real anomaly.
    ck(Migrate.SelfHeal(honest, nil, sampleMesh(), { selfAccount = "x", quiet = true }) ~= nil,
        "the same state without the deferral still heals")
end

function Migrate.RunSelfTests(verbose)
    local suites = {
        { name = "parse item ref",   fn = testParse },
        { name = "convert container", fn = testConvertContainer },
        { name = "end-to-end + idempotency", fn = testEndToEndAndIdempotency },
        { name = "empty source leaves marker unset", fn = testEmptySourceLeavesMarkerUnset },
        { name = "sticky-marker self-heal", fn = testSelfHeal },
        { name = "nexus mesh-import deferral", fn = testMeshDeferral },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS migrate/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL migrate/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("migrate", Migrate.RunSelfTests)
end

return Migrate
