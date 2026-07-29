-- Daseeki-Bags 2.0 — real-SV migration validator (tooling; not shipped in-game).
--
-- Loads one or more real 1.x Daseeki-Bags.lua SavedVariables files (each sets
-- DaseekiBagsAccount / DaseekiBagsMesh), runs the 2.0 migration against each in
-- ISOLATION, and reports converted owner/container/slot/money counts per file.
-- The 1.x files are only READ (loaded as chunks); they are never written.
--
-- Usage:  lua5.1 validate-real.lua <BAGS2_DIR> <label=path.lua> [<label=path.lua> ...]
--   e.g.  lua5.1 validate-real.lua ..  acct1=/scratch/acct1.lua acct2=/scratch/acct2.lua
--
-- Point it at COPIES of the real WTF files (never the originals).

local BAGS2_DIR = (arg[1] or "."):gsub("\\", "/")
local function P(rel) return BAGS2_DIR .. "/" .. rel end

-- Minimal stubs (mirror run-selftests.lua).
_G.GetServerTime = function() return 1700000000 end
_G.time          = function() return 1700000000 end
_G.NUM_BAG_SLOTS = 4
_G.NUM_BANKBAGSLOTS = 7

local ADDON, ns = "DaseekiBags", {}
function ns:Print() end
function ns:RegisterSelfTest() end

assert(loadfile(P("store.lua")))(ADDON, ns)
assert(loadfile(P("capture.lua")))(ADDON, ns)
assert(loadfile(P("migrate.lua")))(ADDON, ns)

local Store, Migrate = ns.Store, ns.Migrate

local function migrateOne(label, path)
    -- Load the SV chunk in a sandbox so each file is isolated.
    _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, _G.DaseekiBagsSets = nil, nil, nil
    local fn, err = loadfile(path)
    if not fn then print(string.format("  [%s] LOAD ERROR: %s", label, tostring(err))); return end
    local ok, rerr = pcall(fn)
    if not ok then print(string.format("  [%s] EXEC ERROR: %s", label, tostring(rerr))); return end

    local data = Store._defaultData()
    data.selfAccount = label
    local r = Migrate.Run(data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, { selfAccount = label })

    -- Money totals over the migrated owners.
    local total, fullMoney, summaryMoney = 0, 0, 0
    for _, o in pairs(data.owners) do
        total = total + (o.money or 0)
        if o.source == "full" then fullMoney = fullMoney + (o.money or 0)
        else summaryMoney = summaryMoney + (o.money or 0) end
    end
    local g = math.floor(total / 10000)

    print(string.format(
        "  [%s] owners=%d (full=%d summary=%d) containers=%d slots=%d  gold=%dg (full=%dg remote=%dg)",
        label, r.owners, r.full, r.summary, r.containers, r.slots,
        g, math.floor(fullMoney / 10000), math.floor(summaryMoney / 10000)))

    -- Idempotency check on the real data.
    local r2 = Migrate.Run(data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, { selfAccount = label })
    if not r2.skipped then print(string.format("  [%s] WARNING: second run not skipped!", label)) end
end

print("=== Daseeki-Bags 2.0 real-SV migration validation ===")
for i = 2, #arg do
    local label, path = arg[i]:match("^(.-)=(.+)$")
    if not label then label, path = ("file" .. (i - 1)), arg[i] end
    migrateOne(label, path)
end
print("=== done ===")
