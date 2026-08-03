-- =====================================================================
-- Daseeki-Bags 2.0 headless self-test harness  (REAL Lua 5.1)
--
-- Loads store.lua / capture.lua / migrate.lua under a minimal WoW API stub,
-- runs every ns:RegisterSelfTest suite, then runs a migration suite against the
-- committed reduced 1.x fixture (harness/fixtures/bags1x-sample.lua).
--
-- Usage:  lua5.1 run-selftests.lua [BAGS2_DIR]
--   BAGS2_DIR defaults to the repo root two levels up from this file.
--   Exit code 0 = ALL PASS.
-- =====================================================================

local HARNESS_DIR = (arg[0]:match("^(.*)[\\/][^\\/]+$")) or "."
local function slash(p) return (p:gsub("\\", "/")) end
HARNESS_DIR = slash(HARNESS_DIR)
local BAGS2_DIR = slash(arg[1] or (HARNESS_DIR .. "/.."))

local function P(rel)  return BAGS2_DIR   .. "/" .. rel end
local function H(rel)  return HARNESS_DIR .. "/" .. rel end

----------------------------------------------------------------------
-- Captured print log
----------------------------------------------------------------------
local realprint = print
local LOG = {}
local function logline(s) LOG[#LOG + 1] = s end
local function flushlog() for i = 1, #LOG do realprint(LOG[i]) end LOG = {} end

----------------------------------------------------------------------
-- 0) TOC PARSE GATE  (added 2026-07-31 after a silent-green incident in the
--    sibling Daseeki-Nexus harness)
--
-- There, a leftover git conflict marker made hud.lua fail to COMPILE. The file
-- never ran, so its ns:RegisterSelfTest calls never ran, so its suites were
-- never in the registry -- and the runner, which only iterates suites that
-- DID register, finished "ALL PASS" with exit 0.
--
-- This harness already aborts on any file in TOC_ORDER failing to load, so the
-- straight version of that bug was covered. What was NOT covered: a .lua file
-- listed in the .toc but missing from the harness's hardcoded TOC_ORDER. The
-- addon ships it; the harness never opens it; a syntax error or a lost suite in
-- it is invisible. This gate parse-asserts (loadfile, no execution) EVERY .lua
-- entry in the .toc and cross-checks the two lists, before anything is run.
----------------------------------------------------------------------
local TOC_FILE = "Daseeki-Bags2.toc"

-- .toc grammar: "## Key: value" directives and "#" comments are skipped; every
-- other non-blank line is a file path relative to the addon folder. Non-.lua
-- entries (Bindings.xml) are not parseable by loadfile, so they are skipped.
local function readTocLuaFiles(tocPath)
    local fh, oerr = io.open(tocPath, "r")
    if not fh then return nil, "cannot open " .. tocPath .. ": " .. tostring(oerr) end
    local files = {}
    for line in fh:lines() do
        line = line:gsub("^\239\187\191", "")          -- strip UTF-8 BOM
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:lower():sub(-4) == ".lua" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    fh:close()
    return files
end

realprint("=== toc parse gate :: loadfile() every .lua in " .. TOC_FILE .. " ===")
local TOC_LUA, tocErr = readTocLuaFiles(P(TOC_FILE))
if not TOC_LUA or #TOC_LUA == 0 then
    realprint("  [FAIL] " .. (tocErr or (TOC_FILE .. " listed no .lua files -- parser or .toc is broken")))
    realprint("=== toc parse gate: FAIL ===")
    os.exit(1)
end
local parseFails = 0
for _, rel in ipairs(TOC_LUA) do
    local pfn, perr = loadfile(P(rel))
    if not pfn then
        parseFails = parseFails + 1
        realprint("  [PARSE FAIL] " .. rel)
        realprint("        " .. tostring(perr))
    end
end
if parseFails > 0 then
    realprint(string.format("=== toc parse gate: FAIL (%d of %d file(s) do not compile) ===",
        parseFails, #TOC_LUA))
    realprint("!!! aborting BEFORE self-tests: a file that does not compile never runs")
    realprint("!!! its ns:RegisterSelfTest calls, and the suite runner only iterates")
    realprint("!!! suites that registered -- so the run would have reported ALL PASS.")
    os.exit(1)
end
realprint(string.format("  [ok] %d .lua file(s) in %s compile", #TOC_LUA, TOC_FILE))
realprint("=== toc parse gate: PASS ===")
realprint("")

----------------------------------------------------------------------
-- 0b) BINDINGS GATE  (added 2026-08-02 after the SECOND Bindings.xml warning)
--
-- Keybindings reach the client by a path no .toc controls: the client
-- auto-discovers <AddOnFolder>/Bindings.xml for every ENABLED addon and feeds
-- it to the keybindings parser. Two distinct failure modes have now shipped:
--
--   1) "Unrecognized XML: Binding" (fixed in a0a8ae5) -- the file was ALSO
--      listed as a .toc file entry, so the generic UI-XML parser, which has no
--      <Binding> element, saw it a second time. Guarded below: no .toc in this
--      addon may list Bindings.xml.
--
--   2) "Binding DASEEKIBAGS2_TOGGLE was attempted to be loaded more than once"
--      -- the SAME action name registered from two sources. Within one file
--      that means duplicate <Binding name=> elements (guarded below). Across
--      the install it means a second installed addon FOLDER ships a
--      Bindings.xml declaring our names -- which is what actually happened:
--      the Daseeki-Bags repo checkout is junctioned into Interface/AddOns as
--      the live 1.x addon while parked on a v2 branch, so the v2 root
--      Bindings.xml rides along in a folder whose .toc never mentions it. The
--      .toc cannot suppress it; only the folder contents can. The live probe
--      at the end of this gate reports that collision (WARN, not FAIL: it is
--      a property of the machine's install, not of this repo).
----------------------------------------------------------------------
local BINDINGS_FILE = "Bindings.xml"
-- Every .toc this addon ships. A .toc that is absent is skipped (branches
-- differ); a .toc that exists MUST NOT list Bindings.xml.
local TOC_CANDIDATES = { "Daseeki-Bags2.toc", "v2.toc", "Daseeki-Bags.toc" }

local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end

realprint("=== bindings gate :: " .. BINDINGS_FILE .. " name uniqueness + toc silence ===")
local bindFails = 0
local bindSrc = readFile(P(BINDINGS_FILE))
local OUR_BINDINGS, ourBindingOrder = {}, {}
if not bindSrc then
    bindFails = bindFails + 1
    realprint("  [FAIL] cannot open " .. P(BINDINGS_FILE) ..
              " -- the addon ships no keybindings at all")
else
    -- Well-formedness trap this file has now hit twice: XML forbids the two-dash
    -- sequence INSIDE a comment. The client's parser rejects the whole file, so
    -- every binding silently disappears. Checked here because the comment block
    -- is long and prose-like, which is exactly where the sequence sneaks in.
    for body in bindSrc:gmatch("<!%-%-(.-)%-%->") do
        if body:find("%-%-") then
            bindFails = bindFails + 1
            realprint("  [FAIL] " .. BINDINGS_FILE .. " has an XML comment containing a")
            realprint("         double-dash sequence, which is illegal and makes the whole")
            realprint("         file unparseable (every binding lost). Rewrite that prose.")
        end
    end

    -- Duplicate-name check: the exact shape that produces "attempted to be
    -- loaded more than once" from a single file.
    for name in bindSrc:gmatch('<Binding%s[^>]-name%s*=%s*"([^"]+)"') do
        if OUR_BINDINGS[name] then
            bindFails = bindFails + 1
            realprint('  [FAIL] duplicate <Binding name="' .. name .. '"> in ' .. BINDINGS_FILE)
        else
            OUR_BINDINGS[name] = true
            ourBindingOrder[#ourBindingOrder + 1] = name
        end
    end
    if #ourBindingOrder == 0 then
        bindFails = bindFails + 1
        realprint("  [FAIL] " .. BINDINGS_FILE .. " declares no <Binding name=...> at all")
    else
        realprint(string.format("  [ok] %d binding name(s), all unique: %s",
            #ourBindingOrder, table.concat(ourBindingOrder, ", ")))
    end
end

-- No .toc may list Bindings.xml (regression guard for failure mode 1).
for _, toc in ipairs(TOC_CANDIDATES) do
    local src = readFile(P(toc))
    if src then
        for line in src:gmatch("[^\r\n]+") do
            local t = line:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" and t:sub(1, 1) ~= "#" and t:lower():find("bindings%.xml") then
                bindFails = bindFails + 1
                realprint("  [FAIL] " .. toc .. " lists " .. BINDINGS_FILE ..
                          " as a file entry -- the client already auto-loads it")
            end
        end
    end
end
if bindFails == 0 then
    realprint("  [ok] no .toc lists " .. BINDINGS_FILE)
end

-- Live-install probe (WARN only; skipped when no Era install is visible).
-- Enumerates sibling addon FOLDERS and flags any other one declaring our names.
do
    local addonsDir = os.getenv("DASEEKI_ERA_ADDONS")
    if not addonsDir then
        local guesses = {
            "C:/Program Files (x86)/World of Warcraft/_classic_era_/Interface/AddOns",
            "C:/Program Files/World of Warcraft/_classic_era_/Interface/AddOns",
        }
        for _, g in ipairs(guesses) do
            local probe = io.open(g .. "/../../WTF/Config.wtf", "r")
                       or io.open(g .. "/Blizzard_Console/Blizzard_Console.toc", "r")
            if probe then probe:close(); addonsDir = g; break end
            -- Directory existence without a known child: try the dir listing.
            local okp, ph = pcall(io.popen, 'dir /b /ad "' .. g:gsub("/", "\\") .. '" 2>nul')
            if okp and ph then
                local first = ph:read("*l"); ph:close()
                if first and first ~= "" then addonsDir = g; break end
            end
        end
    end
    local siblings = {}
    if addonsDir and next(OUR_BINDINGS) then
        local okp, ph = pcall(io.popen, 'dir /b /ad "' .. addonsDir:gsub("/", "\\") .. '" 2>nul')
        if okp and ph then
            for folder in ph:lines() do
                folder = folder:gsub("%s+$", "")
                if folder ~= "" then siblings[#siblings + 1] = folder end
            end
            ph:close()
        end
    end
    local hits = {}
    for _, folder in ipairs(siblings) do
        local src = readFile(addonsDir .. "/" .. folder .. "/" .. BINDINGS_FILE)
        if src then
            local shared = {}
            for name in src:gmatch('<Binding%s[^>]-name%s*=%s*"([^"]+)"') do
                if OUR_BINDINGS[name] then shared[#shared + 1] = name end
            end
            if #shared > 0 then
                hits[#hits + 1] = { folder = folder, names = shared }
            end
        end
    end
    if #hits > 1 then
        realprint("  [WARN] LIVE BINDING-NAME COLLISION in " .. addonsDir)
        for _, h in ipairs(hits) do
            realprint("         " .. h.folder .. "/" .. BINDINGS_FILE ..
                      "  ->  " .. table.concat(h.names, ", "))
        end
        realprint("         The client registers the first folder's names, then warns")
        realprint('         "Binding <NAME> was attempted to be loaded more than once"')
        realprint("         naming the SECOND folder as Source. Only one installed folder")
        realprint("         may ship these names -- this is install topology, not repo content.")
    elseif #hits == 1 then
        realprint("  [ok] live install: " .. hits[1].folder .. " is the only folder declaring our names")
    elseif addonsDir then
        realprint("  [ok] live install scanned, no folder declares our names (addon not installed)")
    else
        realprint("  [skip] no Era install visible (set DASEEKI_ERA_ADDONS to enable the probe)")
    end
end

if bindFails > 0 then
    realprint(string.format("=== bindings gate: FAIL (%d problem(s)) ===", bindFails))
    os.exit(1)
end
realprint("=== bindings gate: PASS ===")
realprint("")

----------------------------------------------------------------------
-- WoW global aliases for stdlib helpers the addon uses as bare globals
----------------------------------------------------------------------
_G.strmatch = string.match
_G.strfind  = string.find
_G.strsub   = string.sub
_G.format   = string.format
_G.wipe     = function(t) for k in pairs(t) do t[k] = nil end return t end

----------------------------------------------------------------------
-- Deterministic time / identity stubs
----------------------------------------------------------------------
local _time = 1700000000
_G.GetServerTime = function() return _time end
_G.time          = function() return _time end
_G.UnitName        = function() return "Tester" end
_G.GetRealmName    = function() return "TestRealm" end
_G.UnitClass       = function() return "Warlock", "WARLOCK" end
_G.UnitRace        = function() return "Orc", "Orc" end
_G.UnitSex         = function() return 2 end
_G.UnitFactionGroup = function() return "Horde" end
_G.UnitLevel       = function() return 60 end
_G.NUM_BAG_SLOTS     = 4
_G.NUM_BANKBAGSLOTS  = 7
-- No C_Container / GetMoney: forces capture's live path to no-op (self-tests
-- exercise the pure core with a fake api instead).

-- geterrorhandler stub: core.lua routes EVERY error here (standing rule: never a
-- silent pcall). This recorder surfaces routed errors to stdout so real breakage
-- stays visible; the core "bus + error routing" self-test temporarily swaps in
-- its own recorder to assert routing, then restores THIS handler.
_G.geterrorhandler = function() return function(err) realprint("  !! routed error: " .. tostring(err)) end end

----------------------------------------------------------------------
-- ns namespace — the REAL runtime now comes from core.lua (loaded FIRST in
-- TOC_ORDER below): Print / SafeCall / event dispatch / On-Fire bus / self-test
-- registry. The harness no longer stubs those; it drives the real core. After
-- load it only re-points ns.Print to the captured-log printer so terminal output
-- stays clean (core's in-game Print prefixes chat color-escape codes).
----------------------------------------------------------------------
local ADDON = "DaseekiBags"
local ns = {}

----------------------------------------------------------------------
-- Suite-registration sentinel (feeds the expected-suite roster gate below).
--
-- core.lua's `selfTests` table is a file-local, so the harness cannot read back
-- which suites registered. Instead we intercept the ONE assignment that creates
-- ns.RegisterSelfTest: `function ns:RegisterSelfTest(...)` in core.lua is a
-- write to a key `ns` does not have yet, so it goes through __newindex and we
-- rawset a recording wrapper in its place. Doing it via __newindex (rather than
-- wrapping after core.lua loads) is what lets us see core.lua's OWN
-- ns:RegisterSelfTest("core", ...) call, which happens during that same load.
-- Every other ns.<key> = v write is passed straight through to rawset.
----------------------------------------------------------------------
local registeredSuites = {}   -- name -> true
local suiteOrder       = {}   -- ordered names, for readable output
setmetatable(ns, {
    __newindex = function(t, k, v)
        if k == "RegisterSelfTest" and type(v) == "function" then
            rawset(t, k, function(self, name, fn)
                name = tostring(name)
                if not registeredSuites[name] then
                    registeredSuites[name] = true
                    suiteOrder[#suiteOrder + 1] = name
                end
                return v(self, name, fn)
            end)
        else
            rawset(t, k, v)
        end
    end,
})

----------------------------------------------------------------------
-- Load addon files in .toc order
----------------------------------------------------------------------
local loadResults = {}
local function loadAddon(rel)
    local fn, err = loadfile(P(rel))
    if not fn then
        loadResults[#loadResults + 1] = { rel, false, "compile: " .. tostring(err) }
        return false
    end
    local ok, rerr = pcall(fn, ADDON, ns)
    loadResults[#loadResults + 1] = { rel, ok, rerr }
    return ok
end

-- core.lua loads FIRST — it provides the ns runtime the other files consume at
-- load time (ns:RegisterSelfTest, ns:RegisterEvent, ns:On/Fire). It is headless-
-- safe (CreateFrame / SlashCmdList / geterrorhandler are all guarded).
-- Load order mirrors v2.toc: W1 engine, then borders before ui_items (buttons
-- attach borders at paint), then ui_frame last (it consumes ns.Items).
local TOC_ORDER = { "core.lua", "store.lua", "capture.lua", "migrate.lua",
                    "borders.lua", "ui_items.lua", "ui_frame.lua",
                    "ui_owner.lua", "ui_bank.lua",
                    "search.lua", "rules2.lua", "sort.lua", "ui_find.lua", "options.lua", "features.lua" }

-- Drift sub-check for the toc parse gate: the list the harness EXECUTES must be
-- the .toc's .lua entries, same files, same order. A file in the .toc but not
-- here compiles fine and still registers nothing (it is never loaded); a file
-- here but not in the .toc is dead weight the addon does not ship.
do
    local drift, inOrder, inToc = {}, {}, {}
    for _, f in ipairs(TOC_ORDER) do inOrder[f] = true end
    for _, f in ipairs(TOC_LUA)   do inToc[f]   = true end
    for _, f in ipairs(TOC_LUA) do
        if not inOrder[f] then drift[#drift + 1] = "in " .. TOC_FILE .. " but never loaded by the harness: " .. f end
    end
    for _, f in ipairs(TOC_ORDER) do
        if not inToc[f] then drift[#drift + 1] = "loaded by the harness but not in " .. TOC_FILE .. ": " .. f end
    end
    if #drift == 0 and #TOC_LUA == #TOC_ORDER then
        for i = 1, #TOC_ORDER do
            if TOC_ORDER[i] ~= TOC_LUA[i] then
                drift[#drift + 1] = string.format("load ORDER differs at slot %d: .toc has %s, harness has %s",
                    i, TOC_LUA[i], TOC_ORDER[i])
            end
        end
    end
    if #drift > 0 then
        realprint("=== toc/harness load-list drift: FAIL ===")
        for _, d in ipairs(drift) do realprint("  [FAIL] " .. d) end
        realprint("!!! update TOC_ORDER in run-selftests.lua to match " .. TOC_FILE .. " and re-run.")
        os.exit(1)
    end
end

for _, f in ipairs(TOC_ORDER) do loadAddon(f) end

-- core.lua's Print prefixes chat color-escape codes; re-point it to the captured
-- log for clean terminal output. (Dynamic dispatch: core's RunRegisteredSelfTests
-- resolves ns:Print at call time, so this override takes effect for the run.)
function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    logline(table.concat(parts, "\t"))
end

realprint("=== Daseeki-Bags 2.0 harness :: file load ===")
local criticalFail = false
for _, r in ipairs(loadResults) do
    realprint(string.format("  [%s] %s%s", r[2] and "ok  " or "FAIL", r[1],
        r[2] and "" or ("  -> " .. tostring(r[3]))))
    if not r[2] then criticalFail = true end
end
if criticalFail then
    realprint("!!! a file failed to load -- aborting.")
    os.exit(2)
end

----------------------------------------------------------------------
-- 1b) EXPECTED-SUITE ROSTER GATE  (added 2026-07-31, same incident as gate 0)
--
-- The parse gate catches a file that does not COMPILE. This catches the softer
-- version: a file that loads fine but whose RegisterSelfTest call never runs --
-- an early `return` from a guard that stopped being satisfied, a deleted
-- registration, a renamed suite. The runner iterates only what registered, so
-- every one of those reads as ALL PASS.
--
-- MISSING from the roster = hard failure (that is the regression).
-- EXTRA not in the roster = printed as a note only, so adding a suite does not
-- break the build before someone gets round to updating this list.
--
-- Regenerate the roster from the Daseeki-Bags repo root with:
--   grep -rho --include=*.lua 'RegisterSelfTest("[^"]*"' . | sed 's/.*("//; s/"$//' | sort -u
-- then drop "fixture-migration" -- that one is registered by THIS file, below,
-- which is deliberately after this gate runs.
----------------------------------------------------------------------
local EXPECTED_SUITES = {
    "borders", "capture", "core", "features", "migrate", "options",
    "rules2", "search", "sort", "store",
    "ui_bank", "ui_find", "ui_frame", "ui_items", "ui_owner",
}

realprint("")
realprint("=== expected-suite roster (" .. #EXPECTED_SUITES .. " suites) ===")
local rosterPass, gotCount = true, 0
local expectedSet = {}
for _, name in ipairs(EXPECTED_SUITES) do expectedSet[name] = true end
for _, name in ipairs(EXPECTED_SUITES) do
    if registeredSuites[name] then
        gotCount = gotCount + 1
    else
        rosterPass = false
        realprint("  [MISSING] suite \"" .. name .. "\" never registered -- its file loaded but")
        realprint("            the ns:RegisterSelfTest call did not run (guard bailed? deleted?)")
    end
end
for _, name in ipairs(suiteOrder) do
    if not expectedSet[name] then
        realprint("  [note] new suite \"" .. name .. "\" is not in EXPECTED_SUITES (not a failure;")
        realprint("         add it to the roster in run-selftests.lua so a later loss is caught)")
    end
end
realprint(string.format("  %d of %d expected suite(s) registered", gotCount, #EXPECTED_SUITES))
-- Not an early exit: the surviving suites still run, so one lost registration
-- does not hide the rest of the report. rosterPass folds into the verdict below.
realprint("=== expected-suite roster: " .. (rosterPass and "PASS" or "FAIL") .. " ===")

----------------------------------------------------------------------
-- Fixture-driven migration suite (registered last)
----------------------------------------------------------------------
ns:RegisterSelfTest("fixture-migration", function(verbose)
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Load the committed reduced 1.x fixture (sets _G.DaseekiBagsAccount/Mesh).
    local fn, err = loadfile(H("fixtures/bags1x-sample.lua"))
    if not fn then
        ns:Print("  FAIL fixture-migration :: cannot load fixture: " .. tostring(err))
        return false
    end
    fn()

    ck(type(_G.DaseekiBagsAccount) == "table", "fixture set DaseekiBagsAccount")
    ck(type(_G.DaseekiBagsMesh) == "table", "fixture set DaseekiBagsMesh")

    local data = ns.Store._defaultData()
    data.selfAccount = "acct-FIXTURE"
    local r = ns.Migrate.Run(data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh,
                             { selfAccount = "acct-FIXTURE" })
    ck(not r.skipped, "fixture migration ran")
    ck(r.full >= 1, "at least one full owner from Account")
    ck(r.summary >= 1, "at least one summary owner from Mesh")

    -- Cross-account gold total across full + summary owners.
    local total = 0
    for _, o in pairs(data.owners) do total = total + (o.money or 0) end
    ck(total > 0, "cross-account gold total is positive")

    -- Idempotency on the real fixture path.
    local r2 = ns.Migrate.Run(data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh,
                              { selfAccount = "acct-FIXTURE" })
    ck(r2.skipped == true, "second fixture run skipped")

    if verbose then
        ns:Print(string.format("  fixture: full=%d summary=%d owners=%d containers=%d slots=%d gold(copper)=%d",
            r.full, r.summary, r.owners, r.containers, r.slots, total))
    end

    for _, f in ipairs(fails) do ns:Print("  FAIL fixture-migration :: " .. f) end
    if #fails == 0 and verbose then ns:Print("  PASS fixture-migration") end
    return #fails == 0
end)

----------------------------------------------------------------------
-- Run all suites
----------------------------------------------------------------------
realprint("")
realprint("=== ns:RunRegisteredSelfTests (real Lua 5.1) ===")
local ok, pass = pcall(function() return ns:RunRegisteredSelfTests(true) end)
flushlog()
if not ok then
    realprint("HARNESS ERROR: " .. tostring(pass))
    os.exit(3)
end

local overall = pass and rosterPass
realprint("")
realprint("############################################################")
realprint("# toc parse gate (compiles)   : PASS (else we exited 1 above)")
realprint("# expected-suite roster       : " .. (rosterPass and "PASS" or "FAIL"))
realprint("# registered self-test suites : " .. (pass and "PASS" or "FAIL"))
realprint("# Daseeki-Bags 2.0 self-tests : " .. (overall and "ALL PASS" or "RED (see above)"))
realprint("############################################################")
os.exit(overall and 0 or 1)
