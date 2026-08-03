-- Daseeki-Bags 2.0 — real-SavedVariables CUTOVER validator (tooling; not shipped in-game).
--
-- Loads one or more real Daseeki-Bags.lua SavedVariables files (each sets some subset of
-- DaseekiBagsAccount / DaseekiBagsSets / DaseekiBagsMesh, and possibly DaseekiBags2DB /
-- DaseekiBags2Data) and replays the FIRST POST-CUTOVER LOGIN against each in isolation,
-- then a second login, reporting what the owner would actually get.
--
-- The 1.x files are only READ (loaded as chunks in this process); nothing is ever written
-- back to disk. Point it at COPIES of the real WTF files anyway.
--
-- WHY IT DRIVES THE WHOLE CHAIN, not just migrate.Run. Before the cutover this script
-- exercised the owner pass and the lock pass directly. Post-cutover the first login is
-- the ONLY chance every pass gets, and the passes are order-coupled (the settings pass
-- claims db.densityUserChose, which is what stops Frame.MigrateDensity re-defaulting the
-- grid it just imported). So this replays the client's real sequence:
--
--   ADDON_LOADED   Store.Init() -> Migrate.Migrate()   [owners -> self-heal -> settings
--                                                       -> rules -> sort locks]
--                  ns:Fire("STORE_READY")              [rules/options/features defaults]
--   PLAYER_LOGIN   Frame.ApplyDefaults -> MigrateDensity -> MigrateScale
--
-- The module list is PARSED FROM THE SHIPPING .toc rather than hardcoded, so this file
-- can never drift from what the addon actually loads.
--
-- Usage:  lua5.1 validate-real.lua <BAGS_DIR> <label=path.lua> [<label=path.lua> ...]
--   e.g.  lua5.1 validate-real.lua ..  acct1=/scratch/acct1.lua acct2=/scratch/acct2.lua

local BAGS_DIR = (arg[1] or "."):gsub("\\", "/")
local function P(rel) return BAGS_DIR .. "/" .. rel end

----------------------------------------------------------------------
-- Minimal WoW stubs (mirror run-selftests.lua)
----------------------------------------------------------------------
_G.strmatch = string.match
_G.strfind  = string.find
_G.strsub   = string.sub
_G.format   = string.format
_G.wipe     = function(t) for k in pairs(t) do t[k] = nil end return t end

_G.GetServerTime = function() return 1700000000 end
_G.time          = function() return 1700000000 end
_G.UnitName         = function() return "Tester" end
_G.GetRealmName     = function() return "TestRealm" end
_G.UnitClass        = function() return "Warlock", "WARLOCK" end
_G.UnitRace         = function() return "Orc", "Orc" end
_G.UnitSex          = function() return 2 end
_G.UnitFactionGroup = function() return "Horde" end
_G.UnitLevel        = function() return 60 end
_G.NUM_BAG_SLOTS    = 4
_G.NUM_BANKBAGSLOTS = 7
_G.geterrorhandler  = function() return function(err) print("  !! routed error: " .. tostring(err)) end end

local ADDON, ns = "DaseekiBags", {}

----------------------------------------------------------------------
-- Load the addon exactly as the shipping .toc lists it
----------------------------------------------------------------------
local TOC_FILE = "Daseeki-Bags.toc"

local function readTocLuaFiles(tocPath)
    local fh = assert(io.open(tocPath, "r"), "cannot open " .. tocPath)
    local files = {}
    for line in fh:lines() do
        line = line:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:lower():sub(-4) == ".lua" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    fh:close()
    assert(#files > 0, TOC_FILE .. " listed no .lua files")
    return files
end

for _, rel in ipairs(readTocLuaFiles(P(TOC_FILE))) do
    local fn, err = loadfile(P(rel))
    if not fn then error("compile " .. rel .. ": " .. tostring(err), 0) end
    local ok, rerr = pcall(fn, ADDON, ns)
    if not ok then error("load " .. rel .. ": " .. tostring(rerr), 0) end
end

-- Silence the addon's own chat output; the report below is the output.
local chat = {}
function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    chat[#chat + 1] = table.concat(parts, " ")
end

local Store, Migrate, Locks, Frame = ns.Store, ns.Migrate, ns.Locks, ns.Frame

----------------------------------------------------------------------
-- Deep copy / compare, for the READ-ONLY assertion on the 1.x globals
----------------------------------------------------------------------
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function deepeq(a, b, path)
    path = path or ""
    if type(a) ~= type(b) then return false, path .. " <type>" end
    if type(a) ~= "table" then
        if a ~= b then return false, path .. " <value>" end
        return true
    end
    for k, v in pairs(a) do
        local ok, why = deepeq(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. " <added>" end
    end
    return true
end

local SOURCE_GLOBALS = { "DaseekiBagsAccount", "DaseekiBagsSets", "DaseekiBagsMesh" }

----------------------------------------------------------------------
-- One full login, in the client's order (mirrors core.lua's ADDON_LOADED handler,
-- the STORE_READY fire, and Frame.OnLogin's migration prologue).
----------------------------------------------------------------------
local function login()
    local out = {}
    Store.Init()
    out.migrate = Migrate.Migrate()
    ns:Fire("STORE_READY")
    if Frame then
        Frame.ApplyDefaults(Store.db)
        out.density = Frame.MigrateDensity(Store.db)
        out.scale   = Frame.MigrateScale(Store.db)
    end
    return out
end

local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
local function gold(c) return math.floor((c or 0) / 10000) end

local function validateOne(label, path)
    print("")
    print("--------------------------------------------------------------------")
    print("[" .. label .. "] " .. path)

    -- Fresh process state per file.
    _G.DaseekiBagsAccount, _G.DaseekiBagsSets, _G.DaseekiBagsMesh = nil, nil, nil
    _G.DaseekiBags2DB, _G.DaseekiBags2Data = nil, nil
    Store.db, Store.data = nil, nil
    chat = {}

    local fn, err = loadfile(path)
    if not fn then print("  LOAD ERROR: " .. tostring(err)); return end
    local ok, rerr = pcall(fn)
    if not ok then print("  EXEC ERROR: " .. tostring(rerr)); return end

    -- What the file actually carried.
    local carried = {}
    for _, g in ipairs(SOURCE_GLOBALS) do
        if type(_G[g]) == "table" then carried[#carried + 1] = g end
    end
    for _, g in ipairs({ "DaseekiBags2DB", "DaseekiBags2Data" }) do
        if type(_G[g]) == "table" then carried[#carried + 1] = g .. " (pre-existing 2.0)" end
    end
    print("  file declares: " .. (next(carried) and table.concat(carried, ", ") or "nothing we read"))

    local pristine = {}
    for _, g in ipairs(SOURCE_GLOBALS) do pristine[g] = deepcopy(_G[g]) end

    ----------------------------------------------------------------
    -- FIRST post-cutover login
    ----------------------------------------------------------------
    local r1  = login()
    local db  = Store.db
    local dat = Store.data
    local m   = r1.migrate

    local total, fullMoney, remoteMoney = 0, 0, 0
    local containers, slots = 0, 0
    for _, o in pairs(dat.owners) do
        total = total + (o.money or 0)
        if o.source == "full" then fullMoney = fullMoney + (o.money or 0)
        else remoteMoney = remoteMoney + (o.money or 0) end
        for _, c in pairs(o.containers or {}) do
            containers = containers + 1
            slots = slots + count(c.slots)
        end
    end

    print(string.format("  owners  : %d  (full=%d  summary=%d)   containers=%d  slots=%d",
        count(dat.owners), m.full or 0, m.summary or 0, containers, slots))
    print(string.format("  gold    : %dg total  (full=%dg  cross-account=%dg)",
        gold(total), gold(fullMoney), gold(remoteMoney)))
    print(string.format("  markers : owners=%s  settings=%s  locks=%s  density=%s  scale=%s  rulesFlip=%s",
        tostring(dat.migratedFrom1x == true),
        tostring(db.migratedSettingsFrom1x == true),
        tostring(db[Locks.MIGRATION_MARKER] == true),
        tostring(db[Frame.DENSITY_MARKER] == true),
        tostring(db[Frame.SCALE_MARKER] == true),
        tostring(db[ns.Rules.DEFAULT_FLIP_MARKER] == true)))

    local s = m.settings
    if s then
        print(string.format("  settings: profile=%s  applied=%d  matched=%d  kept=%d  ran=%s%s",
            tostring(s.settings and s.settings.source), s.appliedCount or 0,
            s.matchedCount or 0, s.keptCount or 0, tostring(s.ran),
            s.reason and ("  (" .. s.reason .. ")") or ""))
        if s.settings and #s.settings.applied > 0 then
            print("            applied: " .. table.concat(s.settings.applied, ", "))
        end
        if s.rules then
            print(string.format("  rules   : imported=%d  skipped=%d  duplicates=%d",
                s.rules.imported, s.rules.skipped, s.rules.duplicates))
            for _, why in ipairs(s.rules.reasons or {}) do
                print("            skipped \"" .. tostring(why.name) .. "\": " .. tostring(why.reason))
            end
        end
    end

    print(string.format("  grid    : columns=%s gap=%s buttonSize=%s scale=%s  layout=%s  " ..
                        "densityUserChose=%s  densityFlipped=%s  scaleHealed=%s",
        tostring(db.columns), tostring(db.gap), tostring(db.buttonSize), tostring(db.scale),
        tostring(db.layout), tostring(db.densityUserChose == true),
        tostring(r1.density), tostring(r1.scale)))

    local L = s and s.locks
    if L then
        print(string.format("  locks   : imported=%d  alreadySet=%d  chars=%d  marker=%s%s",
            L.imported or 0, L.alreadySet or 0, L.characters or 0, tostring(L.markerSet),
            L.reason and ("  (" .. L.reason .. ")") or ""))
        local detail = {}
        for key, root in pairs(db[Locks.DB_KEY] or {}) do
            for cid, bag in pairs(root) do
                local ss = {}
                for slot in pairs(bag) do ss[#ss + 1] = slot end
                table.sort(ss)
                detail[#detail + 1] = string.format("%s cid %d [%s]", key, cid, table.concat(ss, ","))
            end
        end
        table.sort(detail)
        for _, d in ipairs(detail) do print("            " .. d) end
    end

    if #chat > 0 then
        print("  chat the owner would see on this login:")
        for _, line in ipairs(chat) do print("            " .. line) end
    end

    ----------------------------------------------------------------
    -- READ-ONLY contract: the three 1.x globals are untouched.
    ----------------------------------------------------------------
    local roOk = true
    for _, g in ipairs(SOURCE_GLOBALS) do
        local eq, why = deepeq(pristine[g], _G[g])
        if not eq then
            roOk = false
            print("  !! READ-ONLY VIOLATION: " .. g .. " changed at " .. tostring(why))
        end
    end
    if roOk then print("  read-only: the three 1.x globals are byte-identical after the login") end

    ----------------------------------------------------------------
    -- SECOND login: everything must be a no-op.
    ----------------------------------------------------------------
    local before = deepcopy(db)
    chat = {}
    local r2 = login()
    local stable, why = deepeq(before, Store.db)
    -- A pass that is NOT marker-skipped is not automatically a defect: marker discipline
    -- deliberately leaves the marker unset when the source was absent or unreadable, so
    -- the pass re-offers itself on every login until a real source turns up. That reads
    -- as "not skipped" here and is exactly right, which is why the reason is printed.
    local function passState(rep)
        if rep == nil then return "absent" end
        if rep.skipped then return "skipped" end
        if rep.ran then return "RE-RAN (check!)" end
        return "open: " .. tostring(rep.reason)
    end
    print(string.format("  2nd login: ownerPass=%s  settingsPass=%s  density=%s  scale=%s  dbUnchanged=%s%s",
        passState(r2.migrate), passState(r2.migrate.settings),
        tostring(r2.density), tostring(r2.scale), tostring(stable),
        stable and "" or ("  <- " .. tostring(why))))
    if r2.migrate.selfHealed then print("  !! the self-heal fired on the second login (unexpected)") end
    if #chat > 0 then
        print("  !! the second login printed to chat (a one-shot notice repeated):")
        for _, line in ipairs(chat) do print("            " .. line) end
    end
end

print("=== Daseeki-Bags 2.0 cutover validation against real SavedVariables ===")
print("(read-only: these files are loaded as chunks and never written)")
for i = 2, #arg do
    local label, path = arg[i]:match("^(.-)=(.+)$")
    if not label then label, path = ("file" .. (i - 1)), arg[i] end
    validateOne(label, path)
end
print("")
print("=== done ===")
