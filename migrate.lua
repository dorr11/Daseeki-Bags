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
--   opts       : { selfAccount=<id>, force=<bool> }
-- Returns counts { skipped, owners, full, summary, containers, slots }.
----------------------------------------------------------------------

function Migrate.Run(data, oldAccount, oldMesh, opts)
    opts = opts or {}
    if type(data) ~= "table" then return { skipped = true } end
    if type(data.owners) ~= "table" then data.owners = {} end
    if data.migratedFrom1x and not opts.force then
        return { skipped = true }
    end

    local selfAccount = opts.selfAccount or data.selfAccount or ""
    local counts = { skipped = false, owners = 0, full = 0, summary = 0,
                     containers = 0, slots = 0 }

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
    if type(oldMesh) == "table" then
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

    data.migratedFrom1x = true
    return counts
end

----------------------------------------------------------------------
-- Live wrapper: read the 1.x globals and migrate into the attached store.
-- Runs once at login (after Store.Init); a no-op if already migrated.
----------------------------------------------------------------------

function Migrate.Migrate()
    if not Store.data then return { skipped = true } end
    return Migrate.Run(Store.data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh,
                       { selfAccount = Store.data.selfAccount or "" })
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

function Migrate.RunSelfTests(verbose)
    local suites = {
        { name = "parse item ref",   fn = testParse },
        { name = "convert container", fn = testConvertContainer },
        { name = "end-to-end + idempotency", fn = testEndToEndAndIdempotency },
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
