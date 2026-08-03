-- =====================================================================
-- Daseeki-Bags 2.0 headless self-test harness  (REAL Lua 5.1)
--
-- Loads the whole shipping load list under a minimal WoW API stub, runs the release
-- gates (toc parse / bindings / toc identity), runs every ns:RegisterSelfTest suite,
-- then two fixture-driven suites this file registers itself:
--   fixture-migration      — the owner pass + lock pass against the committed reduced
--                            1.x fixture (harness/fixtures/bags1x-sample.lua)
--   cutover-orchestration  — the FULL first-post-cutover login chain against a
--                            synthetic complete 1.x file (fixtures/bags1x-full.lua)
--
-- Usage:  lua5.1 run-selftests.lua [BAGS_DIR]
--   BAGS_DIR defaults to the repo root two levels up from this file.
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
-- Post-cutover (2.0.0) there is exactly ONE .toc: the shipping Daseeki-Bags.toc, which
-- now loads the 2.0 tree. The side-by-side beta tocs (Daseeki-Bags2.toc, v2.toc) and the
-- whole 1.x source tree were deleted at the cutover, so every gate below targets this
-- single file. If a second .toc ever reappears in this folder, the client would load
-- neither reliably (it loads the .toc whose name matches the FOLDER) -- add it to the
-- candidate lists rather than switching this one.
local TOC_FILE = "Daseeki-Bags.toc"

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
-- Every .toc this addon ships. Post-cutover that is one file; the retired beta names are
-- still listed so a stray re-added copy is caught. A .toc that is absent is skipped (old
-- branches differ); a .toc that exists MUST NOT list Bindings.xml.
local TOC_CANDIDATES = { "Daseeki-Bags.toc", "Daseeki-Bags2.toc", "v2.toc" }

-- Release-gate C.9 ("no Bindings.xml action name is changed or removed"): the exact
-- roster this addon must declare. FIVE names are legitimate as of the cutover work:
-- the three 2.0 actions, plus the two LEGACY 1.x action names re-declared so a key the
-- owner bound under 1.x keeps working after the 1.x folder is uninstalled
-- (ROLLOUT_CONTINUITY_AUDIT AT-RISK-4). Both legacy bodies call the 2.0 handlers.
-- A missing name here is a hard FAIL: that is a user losing a keybinding.
local EXPECTED_BINDINGS = {
    "DASEEKIBAGS2_TOGGLE", "DASEEKIBAGS2_BANK_TOGGLE", "DASEEKIBAGS2_FIND",
    "DASEEKIBAGS_TOGGLE", "DASEEKIBAGS_BANK_TOGGLE",
}
-- The subset that exists purely for cutover continuity: the 1.x action names, re-declared
-- by 2.0 so a key bound under 1.x survives. Dropping one of these is the AT-RISK-4
-- regression, so a missing legacy name is a hard FAIL below just like a 2.0 name.
--
-- POST-CUTOVER NOTE: while the beta ran side by side, these two names were legitimately
-- declared by TWO of our folders at once and the live probe classified that as expected.
-- That case cannot occur any more -- the cutover leaves exactly one folder (Daseeki-Bags)
-- and the beta folder is uninstalled -- so the probe no longer has an "expected overlap"
-- bucket. Any name declared by two folders is now a real collision to fix in the install.
local LEGACY_BINDINGS = { DASEEKIBAGS_TOGGLE = true, DASEEKIBAGS_BANK_TOGGLE = true }
-- Our one installed folder name. WoW loads the .toc whose name matches the FOLDER, and
-- since the cutover the repo ships exactly one .toc for exactly one folder.
local OUR_FOLDERS = { ["Daseeki-Bags"] = true }
-- Folders that were ours during the beta and must NOT still be installed. A collision
-- naming one of these is the leftover-beta-install defect, with a one-line fix.
local RETIRED_FOLDERS = { ["Daseeki-Bags2"] = true }

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

    -- Roster check (release-gate C.9). Missing = FAIL (a bound key would be orphaned);
    -- extra = note only, so adding an action does not block the build.
    local missing = {}
    local expectedSet = {}
    for _, name in ipairs(EXPECTED_BINDINGS) do
        expectedSet[name] = true
        if not OUR_BINDINGS[name] then missing[#missing + 1] = name end
    end
    for _, name in ipairs(missing) do
        bindFails = bindFails + 1
        realprint("  [FAIL] action name \"" .. name .. "\" is no longer declared in " ..
                  BINDINGS_FILE)
        if LEGACY_BINDINGS[name] then
            realprint("         It is a LEGACY 1.x name kept for cutover continuity: dropping it")
            realprint("         orphans every key the owner bound before 2.0. Keep it for at")
            realprint("         least 2 releases after cutover (audit AT-RISK-4).")
        end
    end
    for _, name in ipairs(ourBindingOrder) do
        if not expectedSet[name] then
            realprint("  [note] new action \"" .. name .. "\" is not in EXPECTED_BINDINGS")
            realprint("         (not a failure; add it to the roster so a later loss is caught)")
        end
    end
    if #missing == 0 then
        realprint(string.format("  [ok] all %d expected action name(s) present (%d legacy-continuity)",
            #EXPECTED_BINDINGS, 2))
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
    -- Per-NAME folder map. Post-cutover the rule is simple again: exactly ONE installed
    -- folder (Daseeki-Bags) may declare any of our action names. The beta's expected
    -- two-folder overlap on the legacy names is gone with the beta folder, so every
    -- multi-folder name below is a genuine collision -- reported with the specific fix
    -- when the second folder is the retired beta one.
    local hits = {}                 -- ordered { folder=, names={} }
    local foldersByName = {}        -- name -> { folder, ... }
    for _, folder in ipairs(siblings) do
        local src = readFile(addonsDir .. "/" .. folder .. "/" .. BINDINGS_FILE)
        if src then
            local shared = {}
            for name in src:gmatch('<Binding%s[^>]-name%s*=%s*"([^"]+)"') do
                if OUR_BINDINGS[name] then
                    shared[#shared + 1] = name
                    local list = foldersByName[name] or {}
                    list[#list + 1] = folder
                    foldersByName[name] = list
                end
            end
            if #shared > 0 then
                hits[#hits + 1] = { folder = folder, names = shared }
            end
        end
    end

    -- Every name declared by more than one folder is a collision now (see above).
    local genuine, staleBeta = {}, {}
    for name, folders in pairs(foldersByName) do
        if #folders > 1 then
            genuine[#genuine + 1] = { name = name, folders = folders }
            for _, f in ipairs(folders) do
                if RETIRED_FOLDERS[f] then staleBeta[f] = true end
            end
        end
    end

    if #genuine > 0 then
        realprint("  [WARN] LIVE BINDING-NAME COLLISION in " .. addonsDir)
        for _, e in ipairs(genuine) do
            realprint("         " .. e.name .. "  <-  " .. table.concat(e.folders, ", "))
        end
        realprint("         The client registers the first folder's names, then warns")
        realprint('         "Binding <NAME> was attempted to be loaded more than once"')
        realprint("         naming the SECOND folder as Source. Only one installed folder")
        realprint("         may ship these names -- this is install topology, not repo content.")
        for folder in pairs(staleBeta) do
            realprint("         FIX: " .. folder .. " is the retired side-by-side BETA folder.")
            realprint("         The cutover moved everything into Daseeki-Bags; delete that")
            realprint("         folder (or its junction) and the warning goes away.")
        end
        realprint("         Never 'fix' a collision by renaming an action: that is what")
        realprint("         orphans every key the owner has already bound (audit AT-RISK-4).")
    end
    if #genuine == 0 then
        if #hits == 1 then
            realprint("  [ok] live install: " .. hits[1].folder .. " is the only folder declaring our names")
        elseif addonsDir then
            realprint("  [ok] live install scanned, no folder declares our names (addon not installed)")
        else
            realprint("  [skip] no Era install visible (set DASEEKI_ERA_ADDONS to enable the probe)")
        end
    end
end

if bindFails > 0 then
    realprint(string.format("=== bindings gate: FAIL (%d problem(s)) ===", bindFails))
    os.exit(1)
end
realprint("=== bindings gate: PASS ===")
realprint("")

----------------------------------------------------------------------
-- 0c) TOC IDENTITY GATE  (added 2026-08-02 with the cutover continuity work)
--
-- Two release-gate properties that live in the .toc, where no self-test can see them:
--
--  1. SAVEDVARIABLES (gate A.1; audit AT-RISK-1). The client rewrites this addon's SV
--     file at every logout from the DECLARED names only, so a global dropped from that
--     line is deleted at the next logout, silently. The shipping toc must declare all
--     FIVE globals: the 2.0 pair plus the three 1.x globals kept as the cutover rollback
--     net (2.0 reads them read-only and never writes them). This gate is the regression
--     guard for the single most destructive defect in the rollout audit, and it matters
--     MORE after cutover than before: until now the 1.x toc was the one the client
--     actually loaded, so the 1.x globals were declared no matter what the beta tocs
--     said. Now this file is the only thing standing between the owner's 1.x data and
--     the next logout.
--
--  2. VERSION (gate C.12; audit NW-8, which found the shipped toc reading 1.1.4 while
--     the released tag was v1.1.5). The shipping toc must agree with core.lua's
--     ns.VERSION -- 2.0.0 at the cutover -- and, at release time, with the tag.
--
--  3. OPTIONALDEPS (added with the W2 Nexus bridge). Daseeki-Nexus must stay on the
--     OptionalDeps line. It is NOT a dependency -- nexus.lua is fully type-guarded and
--     Bags runs unchanged without it -- it is a LOAD-ORDER statement: it is what makes
--     the client load Daseeki-Nexus first when present, so DaseekiNexusData is attached
--     before our ADDON_LOADED runs Store.Init -> Migrate.Migrate and the mesh-import
--     deferral decision can actually see the Nexus store. Drop the name and the bridge
--     still works for the tooltips (they read at hover time) but the deferral silently
--     stops deciding correctly on the first login of every session.
--
--     A HARD "## Dependencies:" line naming Daseeki-NEXUS would be a defect: it would
--     stop Bags loading at all when a genuinely optional companion is absent. Guarded.
--
--  4. DEPENDENCIES -- Daseeki-Core (release verification N1, added 2026-08-03). This one
--     inverted. Core was on OptionalDeps beside Nexus, on the theory that Bags degrades
--     gracefully without it. It does not: ui_frame.lua's Frame.Ensure() returns nil the
--     moment _G.DaseekiUI is absent, so no window can ever be built, while
--     Frame.HookBagToggles() replaced all NINE Blizzard bag toggle globals regardless.
--     A Core-less install therefore lost BOTH sets of bags, silently. Core is now a hard
--     "## Dependencies:" line -- the honest statement of what Bags actually needs -- and
--     must NOT be on OptionalDeps as well (two lines naming the same addon is ambiguous
--     and hides which one is load-bearing). Both halves are asserted below.
--
--     The .pkgmeta relation (required-dependencies: daseeki-core) is the CurseForge-side
--     half of the same fix; it is asserted here too, because the toc and the packager
--     must not disagree about what is required.
----------------------------------------------------------------------
local REQUIRED_SV_2X = {
    "DaseekiBags2DB", "DaseekiBags2Data",
    "DaseekiBagsAccount", "DaseekiBagsSets", "DaseekiBagsMesh",
}
local REQUIRED_OPTIONAL_DEPS = { "Daseeki-Nexus" }
local FORBIDDEN_HARD_DEPS    = { "Daseeki-Nexus" }
-- N1: hard deps that MUST be declared, and must not also appear on OptionalDeps.
local REQUIRED_HARD_DEPS     = { "Daseeki-Core" }
-- N1: the CurseForge slug the packager must upload as a requiredDependency relation.
-- BigWigsMods/packager reads `required-dependencies:` from .pkgmeta as a list of project
-- SLUGS (lower-cased), not project ids.
local REQUIRED_PKGMETA_RELATIONS = { ["required-dependencies"] = "daseeki-core" }
-- Post-cutover this is the single SHIPPING toc. It was { "Daseeki-Bags2.toc", "v2.toc" }
-- while the 2.0 tree rode in beside a 1.x Daseeki-Bags.toc; both beta files are gone and
-- the name below is the one the client loads. A .toc absent on a branch is skipped, so
-- this list is safe to grow if a second identity ever ships.
local TOCS_2X = { "Daseeki-Bags.toc" }
-- Retired beta tocs. Present here only so their RETURN is caught: two .toc files in one
-- folder is ambiguous to the client and re-introduces the duplicate-binding warning.
local RETIRED_TOCS = { "Daseeki-Bags2.toc", "v2.toc" }

local function tocDirective(src, key)
    for line in src:gmatch("[^\r\n]+") do
        local v = line:match("^%s*##%s*" .. key .. "%s*:%s*(.-)%s*$")
        if v then return v end
    end
    return nil
end

realprint("=== toc identity gate :: SavedVariables declaration + ## Version ===")
local idFails = 0

-- The beta tocs must stay deleted: a folder holding more than one .toc is ambiguous, and
-- a stray Daseeki-Bags2.toc is also what makes a leftover beta FOLDER load and re-declare
-- our binding names.
for _, toc in ipairs(RETIRED_TOCS) do
    if readFile(P(toc)) then
        idFails = idFails + 1
        realprint("  [FAIL] " .. toc .. " is back. The 2.0 cutover retired the side-by-side")
        realprint("         beta tocs; the shipping identity is Daseeki-Bags.toc alone.")
    end
end

for _, toc in ipairs(TOCS_2X) do
    local src = readFile(P(toc))
    if not src then
        idFails = idFails + 1
        realprint("  [FAIL] " .. toc .. " is missing -- that is the file the client loads")
    else
        local decl = tocDirective(src, "SavedVariables") or ""
        local declared = {}
        for name in decl:gmatch("[^,%s]+") do declared[name] = true end
        local missingSV = {}
        for _, name in ipairs(REQUIRED_SV_2X) do
            if not declared[name] then missingSV[#missingSV + 1] = name end
        end
        if #missingSV > 0 then
            idFails = idFails + 1
            realprint("  [FAIL] " .. toc .. " does not declare: " .. table.concat(missingSV, ", "))
            realprint("         An undeclared global is NOT written back at logout -- it is")
            realprint("         erased. The three 1.x globals must stay declared for at least")
            realprint("         2 releases after cutover (rollback net + migration retry).")
        else
            realprint("  [ok] " .. toc .. " declares all " .. #REQUIRED_SV_2X .. " globals")
        end

        -- Nexus-bridge load-order guarantee (see the gate header, point 3).
        local optional = {}
        for name in (tocDirective(src, "OptionalDeps") or ""):gmatch("[^,%s]+") do
            optional[name] = true
        end
        local missingOpt = {}
        for _, name in ipairs(REQUIRED_OPTIONAL_DEPS) do
            if not optional[name] then missingOpt[#missingOpt + 1] = name end
        end
        if #missingOpt > 0 then
            idFails = idFails + 1
            realprint("  [FAIL] " .. toc .. " OptionalDeps is missing: " .. table.concat(missingOpt, ", "))
            realprint("         OptionalDeps is the ONLY thing that makes the client load that")
            realprint("         addon BEFORE this one. Without Daseeki-Nexus on the line, its")
            realprint("         SavedVariables are not attached when our ADDON_LOADED runs the")
            realprint("         migration, so the mesh-import deferral decides on a store it")
            realprint("         cannot see yet. Add the name back; do NOT promote it to")
            realprint("         Dependencies (that would stop Bags loading without Nexus).")
        else
            realprint("  [ok] " .. toc .. " OptionalDeps carries " .. table.concat(REQUIRED_OPTIONAL_DEPS, ", "))
        end

        local hard = {}
        for name in (tocDirective(src, "Dependencies") or ""):gmatch("[^,%s]+") do hard[name] = true end
        for name in (tocDirective(src, "RequiredDeps") or ""):gmatch("[^,%s]+") do hard[name] = true end
        for _, name in ipairs(FORBIDDEN_HARD_DEPS) do
            if hard[name] then
                idFails = idFails + 1
                realprint("  [FAIL] " .. toc .. " lists " .. name .. " as a HARD dependency")
                realprint("         Bags must load and work with that addon absent. Move it to")
                realprint("         OptionalDeps.")
            end
        end

        -- N1: the honest hard dependency. Missing = the silent-no-bags defect is back.
        local hardOk = true
        for _, name in ipairs(REQUIRED_HARD_DEPS) do
            if not hard[name] then
                idFails, hardOk = idFails + 1, false
                realprint("  [FAIL] " .. toc .. " does not list " .. name .. " on ## Dependencies")
                realprint("         Bags cannot draw a single window without it (Frame.Ensure")
                realprint("         returns nil with no _G.DaseekiUI) yet it takes over the nine")
                realprint("         Blizzard bag globals -- so a user without it loses ALL bags.")
                realprint("         Declare it hard; do NOT put it back on OptionalDeps.")
            end
            if optional[name] then
                idFails, hardOk = idFails + 1, false
                realprint("  [FAIL] " .. toc .. " lists " .. name .. " on BOTH Dependencies and")
                realprint("         OptionalDeps. It is required (release verification N1); one")
                realprint("         line must own that fact. Remove it from OptionalDeps.")
            end
        end
        if hardOk then
            realprint("  [ok] " .. toc .. " Dependencies carries " ..
                      table.concat(REQUIRED_HARD_DEPS, ", ") .. ", and OptionalDeps does not")
        end
    end
end

-- N1 (CurseForge half): the packager relation must agree with the .toc. Without it the
-- site happily hands a user Bags on its own, which is exactly the state the hard
-- dependency exists to prevent.
do
    local pkg = readFile(P(".pkgmeta"))
    if not pkg then
        idFails = idFails + 1
        realprint("  [FAIL] .pkgmeta is missing -- the packager cannot build a release")
    else
        for key, slug in pairs(REQUIRED_PKGMETA_RELATIONS) do
            -- The list under `key:` runs until the next non-indented directive.
            -- "-" is a Lua pattern quantifier, so the key has to be escaped before use.
            local keyPat = "^" .. key:gsub("%p", "%%%0") .. "%s*:"
            local found, inBlock = false, false
            for line in pkg:gmatch("[^\r\n]+") do
                local stripped = line:gsub("%s+$", "")
                if stripped:match(keyPat) then
                    inBlock = true
                elseif inBlock then
                    local item = stripped:match("^%s+%-%s*(%S+)")
                    if item then
                        if item:lower() == slug then found = true end
                    elseif not stripped:match("^%s*#") and stripped:match("%S") then
                        inBlock = false
                    end
                end
            end
            if found then
                realprint("  [ok] .pkgmeta " .. key .. " carries " .. slug ..
                          " (CurseForge relation matches the toc)")
            else
                idFails = idFails + 1
                realprint("  [FAIL] .pkgmeta has no `" .. key .. ": - " .. slug .. "` entry")
                realprint("         The .toc says Daseeki-Core is required; CurseForge would not.")
                realprint("         BigWigsMods/packager reads that key as a list of project")
                realprint("         SLUGS and uploads it as the requiredDependency relation.")
            end
        end
    end
end

do
    local versions, order = {}, {}
    for _, toc in ipairs(TOCS_2X) do
        local src = readFile(P(toc))
        if src then
            local v = tocDirective(src, "Version")
            versions[toc] = v
            order[#order + 1] = toc
            if not v then
                idFails = idFails + 1
                realprint("  [FAIL] " .. toc .. " has no ## Version line")
            end
        end
    end
    local coreSrc = readFile(P("core.lua"))
    local coreVersion = coreSrc and coreSrc:match('ns%.VERSION%s*=%s*"([^"]+)"')
    if not coreVersion then
        idFails = idFails + 1
        realprint("  [FAIL] cannot read ns.VERSION from core.lua")
    else
        for _, toc in ipairs(order) do
            if versions[toc] and versions[toc] ~= coreVersion then
                idFails = idFails + 1
                realprint(string.format("  [FAIL] %s ## Version %s does not match core.lua ns.VERSION %s",
                    toc, versions[toc], coreVersion))
            end
        end
        if idFails == 0 then
            realprint("  [ok] ## Version " .. coreVersion .. " consistent across the shipping toc and core.lua")
            realprint("       (release-gate C.12 also requires this to match the tag at release time)")
        end
    end
end

if idFails > 0 then
    realprint(string.format("=== toc identity gate: FAIL (%d problem(s)) ===", idFails))
    os.exit(1)
end
realprint("=== toc identity gate: PASS ===")
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
-- Load order mirrors the shipping Daseeki-Bags.toc: W1 engine, then borders before
-- ui_items (buttons attach borders at paint), then ui_frame after (it consumes ns.Items).
-- The drift sub-check below proves this list and the .toc's are the same, in order.
local TOC_ORDER = { "core.lua", "store.lua", "locks.lua", "nexus.lua", "capture.lua", "migrate.lua",
                    "migrate_settings.lua",
                    "borders.lua", "ui_items.lua", "parity.lua", "ui_frame.lua",
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
-- then drop "fixture-migration" and "cutover-orchestration" -- those two are registered
-- by THIS file, below, which is deliberately after this gate runs.
----------------------------------------------------------------------
local EXPECTED_SUITES = {
    "borders", "capture", "cell-parity", "core", "features", "locks", "migrate", "migrate_settings", "nexus",
    "options", "rules2", "search", "sort", "store",
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

    -- SORT LOCKS, against the same committed fixture. Separate source field, separate
    -- marker, separate target (the settings DB) — so it is asserted separately.
    local db = { settingsVersion = 1 }
    local lr = ns.Locks.MigrateFrom1x(db, _G.DaseekiBagsAccount)
    ck(lr.ran == true, "fixture lock import ran")
    ck(lr.imported == 2, "fixture imported 2 locked slots (got " .. tostring(lr.imported) .. ")")
    ck(lr.characters == 1, "only Puuchoco carried locks (Itchey's table is empty)")
    ck(db[ns.Locks.MIGRATION_MARKER] == true, "fixture lock import set its own marker")
    local roots = db[ns.Locks.DB_KEY]
    ck(type(roots) == "table" and roots["Itchey-Whitemane"] == nil,
       "a character whose 1.x lock table is empty gets no root")
    ck(ns.Locks.RootIsLocked(roots["Puuchoco-Whitemane"], 1, 13)
       and ns.Locks.RootIsLocked(roots["Puuchoco-Whitemane"], 1, 14),
       "Puuchoco's bag-1 locks landed on the right container and slots")
    ck(ns.Locks.RootCount(roots["Puuchoco-Whitemane"]) == 2, "and nothing else did")
    ck(ns.Locks.MigrateFrom1x(db, _G.DaseekiBagsAccount).skipped == true,
       "second fixture lock import skipped by the marker")

    if verbose then
        ns:Print(string.format("  fixture: full=%d summary=%d owners=%d containers=%d slots=%d gold(copper)=%d",
            r.full, r.summary, r.owners, r.containers, r.slots, total))
    end

    for _, f in ipairs(fails) do ns:Print("  FAIL fixture-migration :: " .. f) end
    if #fails == 0 and verbose then ns:Print("  PASS fixture-migration") end
    return #fails == 0
end)

----------------------------------------------------------------------
-- CUTOVER ONE-SHOT ORCHESTRATION SUITE  (added 2026-08-03 with the 2.0 cutover)
--
-- Every individual migration pass has its own unit suite. What none of them can see is
-- the thing the cutover actually risks: whether ALL of them fire, ONCE, IN THE RIGHT
-- ORDER, on the FIRST login of a real 1.x install — and then never again.
--
-- Post-cutover that first login is the only chance any of them get. It is driven by a
-- chain that crosses five files and two events:
--
--   ADDON_LOADED  core.lua:257  Store.Init()                     attach + defaults
--                               Migrate.Migrate()                migrate.lua:391
--                                 -> Migrate.Run                 owners / bags / gold
--                                 -> Migrate.SelfHeal            sticky-marker repair
--                                 -> MigrateSettings.Migrate()   migrate_settings:584
--                                      -> MigrateSettings.Run    settings + rules
--                                      -> Locks.Migrate()        locks.lua:408
--                               ns:Fire("STORE_READY")
--   STORE_READY                 Rules.ApplyDefaults / MigrateDefaultFlip  rules2:466
--                               Options.ApplyDefaults, Features.ApplyDefaults
--   PLAYER_LOGIN  Frame.OnLogin Frame.ApplyDefaults -> MigrateDensity -> MigrateScale
--
-- The suite runs that whole chain against harness/fixtures/bags1x-full.lua and asserts
-- the ORDER-SENSITIVE outcomes, not just the individual reports. The load-bearing one:
-- the fixture's 1.x grid is EXACTLY the pre-parity 12/4 pair that Frame.MigrateDensity
-- flips to 11/2. The settings pass claims db.densityUserChose when it writes a grid
-- from 1.x, and MigrateDensity honours that marker — so 12/4 survives if and only if
-- the settings pass ran first. Invert the order and the owner's imported 1.x grid is
-- silently re-defaulted on the same login that imported it.
--
-- It also asserts the two properties the whole rollback net rests on: the three 1.x
-- globals are still deep-equal to what the fixture loaded (READ-ONLY on the source),
-- and a second full login changes nothing at all (every marker holds).
----------------------------------------------------------------------
ns:RegisterSelfTest("cutover-orchestration", function(verbose)
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function deepcopy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, x in pairs(v) do t[k] = deepcopy(x) end
        return t
    end
    local function deepeq(a, b, path)
        path = path or ""
        if type(a) ~= type(b) then return false, path .. " type" end
        if type(a) ~= "table" then
            if a ~= b then return false, path .. " value" end
            return true
        end
        for k, v in pairs(a) do
            local ok, why = deepeq(v, b[k], path .. "." .. tostring(k))
            if not ok then return false, why end
        end
        for k in pairs(b) do
            if a[k] == nil then return false, path .. "." .. tostring(k) .. " added" end
        end
        return true
    end

    -- A FRESH install meeting a full 1.x file: no 2.0 globals at all.
    _G.DaseekiBags2DB, _G.DaseekiBags2Data = nil, nil
    _G.DaseekiBagsAccount, _G.DaseekiBagsSets, _G.DaseekiBagsMesh = nil, nil, nil

    local fn, err = loadfile(H("fixtures/bags1x-full.lua"))
    if not fn then
        ns:Print("  FAIL cutover-orchestration :: cannot load fixture: " .. tostring(err))
        return false
    end
    fn()
    ck(type(_G.DaseekiBagsAccount) == "table", "fixture set DaseekiBagsAccount")
    ck(type(_G.DaseekiBagsSets)    == "table", "fixture set DaseekiBagsSets")
    ck(type(_G.DaseekiBagsMesh)    == "table", "fixture set DaseekiBagsMesh")

    -- Pristine copies, for the read-only assertion at the end.
    local pristine = {
        DaseekiBagsAccount = deepcopy(_G.DaseekiBagsAccount),
        DaseekiBagsSets    = deepcopy(_G.DaseekiBagsSets),
        DaseekiBagsMesh    = deepcopy(_G.DaseekiBagsMesh),
    }

    -- One full login, in the client's order. Mirrors core.lua's ADDON_LOADED handler,
    -- the STORE_READY fire, and Frame.OnLogin's migration prologue.
    local Frame = ns.Frame
    local function login()
        local out = {}
        ns.Store.Init()
        out.migrate = ns.Migrate.Migrate()
        ns:Fire("STORE_READY")
        if Frame then
            Frame.ApplyDefaults(ns.Store.db)
            out.density = Frame.MigrateDensity(ns.Store.db)
            out.scale   = Frame.MigrateScale(ns.Store.db)
        end
        return out
    end

    local r1  = login()
    local db  = ns.Store.db
    local dat = ns.Store.data

    -- ── 1. Owners / bags / gold ───────────────────────────────────────────────────
    local m = r1.migrate
    ck(m and not m.skipped, "owner pass ran on the first login")
    ck(m.full == 2, "2 full characters imported (got " .. tostring(m and m.full) .. ")")
    ck(m.summary == 2, "2 summary-only characters imported (got " .. tostring(m and m.summary) .. ")")
    ck(m.owners == 4, "4 owners total (got " .. tostring(m and m.owners) .. ")")
    ck(dat.migratedFrom1x == true, "owner marker set")
    ck(dat.owners["Puuchoco-Whitemane"].source == "full",
       "a character present in BOTH sources stays FULL (never downgraded to summary)")
    local gold = 0
    for _, o in pairs(dat.owners) do gold = gold + (o.money or 0) end
    ck(gold == 39000 + 63 + 1022693 + 500, "cross-account gold total (got " .. gold .. ")")

    -- ── 2. Settings ───────────────────────────────────────────────────────────────
    local s = m.settings
    ck(s and s.ran, "settings pass ran at the same migration moment")
    ck(s.markerSet == true and db.migratedSettingsFrom1x == true, "settings marker set")
    ck(s.settings.source == "global", "1.x profile precedence picked the global profile")
    ck(db.layout == "split", "bagBreak 2 became the split layout")
    ck(db.showMoney == false, "an explicit 1.x money=false carried over")
    ck(db.showItemCounts == false, "countItems=false carried over")
    ck(db.qualityBorders == false, "glowQuality=false carried over")
    ck(db.moneyTooltipFaction == true and db.moneyTooltipMinGold == 25,
       "money-tooltip options carried over")
    ck(type(db.autoDisplay) == "table" and db.autoDisplay.merchant == false
       and db.autoDisplay.mail == false, "the explicit display OFFs carried over")
    -- A 1.x display=true is not carried (both sides default ON), so `bank` reaches its
    -- value from Features.ApplyDefaults at STORE_READY, not from the import. Asserting
    -- the RESULT rather than the absence: the interactions the owner left on stay on.
    ck(db.autoDisplay.bank == true, "a display ON survives as ON (seeded, not imported)")
    ck(db.setMarkers ~= true, "1.x glowSets is deliberately NOT carried (inert on Era)")

    -- ── 3. THE ORDERING ASSERTION ─────────────────────────────────────────────────
    ck(db.densityUserChose == true, "the settings pass claimed the density marker")
    ck(db.columns == 12 and db.gap == 4,
       "the 1.x grid SURVIVED the density heal on the same login (settings pass ran " ..
       "first) — got columns=" .. tostring(db.columns) .. " gap=" .. tostring(db.gap))
    ck(r1.density == false, "…and MigrateDensity correctly declined to flip it")
    ck(db[Frame.DENSITY_MARKER] == true, "…while still stamping its one-time marker")
    ck(db.scale == Frame.DEFAULT_SCALE, "a fresh DB takes the CURRENT default scale")
    ck(r1.scale == false, "…so the 0.89 heal is a no-op rather than a double-move")
    ck(db[Frame.SCALE_MARKER] == true, "…and stamps its marker too")

    -- ── 4. Rules -> categories ────────────────────────────────────────────────────
    ck(m.settings.rules.imported == 1, "the convertible search rule became a category")
    ck(m.settings.rules.skipped == 1, "the macro rule was reported, not silently dropped")
    ck(db.categories[1] and db.categories[1].name == "Herbs",
       "imported categories sit ABOVE the seeded defaults (first-match-wins)")
    ck(db.categoriesUserChose == true, "…and claim the user-chose marker")
    ck(db.categoriesEnabled == false,
       "the R3 flat-grid default is NOT overridden by an import")
    ck(db[ns.Rules.DEFAULT_FLIP_MARKER] == true, "the R3 flip stamped its marker")

    -- ── 5. Sort locks ─────────────────────────────────────────────────────────────
    local L = m.settings.locks
    ck(L and L.ran, "the lock pass ran, on its OWN marker")
    ck(L.imported == 5, "5 locked slots imported (got " .. tostring(L and L.imported) .. ")")
    ck(L.characters == 2, "across 2 characters (got " .. tostring(L and L.characters) .. ")")
    ck(db[ns.Locks.MIGRATION_MARKER] == true, "lock marker set")
    local roots = db[ns.Locks.DB_KEY]
    ck(ns.Locks.RootIsLocked(roots["Puuchoco-Whitemane"], 0, 3)
       and ns.Locks.RootIsLocked(roots["Puuchoco-Whitemane"], 1, 13)
       and ns.Locks.RootIsLocked(roots["Itchey-Whitemane"], 1, 9),
       "locks landed on the right character, container and slot")
    ck(ns.Locks.RootIsLocked(roots["Itchey-Whitemane"], 0, 1) == false,
       "an empty 1.x lock table contributes nothing")

    -- ── 6. READ-ONLY on the source (the rollback net) ─────────────────────────────
    for name, before in pairs(pristine) do
        local ok, why = deepeq(before, _G[name])
        ck(ok, "the 1.x global " .. name .. " was not modified (" .. tostring(why) .. ")")
    end

    -- ── 7. The SECOND login changes nothing ───────────────────────────────────────
    local snapshot = deepcopy(db)
    local r2 = login()
    ck(r2.migrate.skipped == true, "second login: owner pass skipped by its marker")
    ck(r2.migrate.selfHealed ~= true,
       "second login: the self-heal did NOT fire (owners are present, marker is honest)")
    ck(r2.migrate.settings.skipped == true, "second login: settings pass skipped")
    ck(r2.density == false and r2.scale == false, "second login: no default heal re-ran")
    local ok2, why2 = deepeq(snapshot, db)
    ck(ok2, "second login left the settings DB byte-identical (" .. tostring(why2) .. ")")
    ck(db.columns == 12 and db.gap == 4, "…the imported grid in particular")

    -- ── 8. The sticky-marker self-heal still has a door ───────────────────────────
    -- The AT-RISK-1c anomaly: marker set, zero owners, source sitting right there.
    dat.owners = {}
    local r3 = ns.Migrate.Migrate()
    ck(r3.selfHealed == true, "a marked-but-empty store self-heals from the 1.x source")
    ck(r3.owners == 4, "…recovering all 4 owners (got " .. tostring(r3.owners) .. ")")

    if verbose then
        ns:Print(string.format(
            "  cutover: owners=%d (full=%d summary=%d) gold=%dg | settings applied=%d matched=%d kept=%d | " ..
            "rules in=%d skipped=%d | locks=%d/%d chars",
            m.owners, m.full, m.summary, math.floor(gold / 10000),
            m.settings.appliedCount or 0, m.settings.matchedCount or 0, m.settings.keptCount or 0,
            m.settings.rules.imported, m.settings.rules.skipped,
            L and L.imported or -1, L and L.characters or -1))
    end

    -- Leave the globals as we found them for anything that runs after us.
    _G.DaseekiBags2DB, _G.DaseekiBags2Data = nil, nil
    ns.Store.db, ns.Store.data = nil, nil

    for _, f in ipairs(fails) do ns:Print("  FAIL cutover-orchestration :: " .. f) end
    if #fails == 0 and verbose then ns:Print("  PASS cutover-orchestration") end
    return #fails == 0
end)

----------------------------------------------------------------------
-- CORE-ABSENT LOGIN SUITE  (added 2026-08-03, release verification N1)
--
-- Every other suite in this file runs HEADLESS: no _G.CreateFrame, so Frame.OnLogin's UI
-- wiring no-ops and the question this suite asks cannot even be posed. The defect N1
-- found needs the opposite stub set -- the game's CreateFrame PRESENT (so we are really
-- in-game) and Daseeki-Core ABSENT (so _G.DaseekiUI is nil):
--
--   * Frame.Ensure() returns nil without DaseekiUI  -> no window can EVER be built
--   * Frame.HookBagToggles() replaced all NINE Blizzard bag globals unconditionally
--
-- so the owner pressed their bag key and got nothing at all, from either addon, with no
-- message. Core is a hard "## Dependencies" now (asserted by the toc identity gate), which
-- should make this unreachable -- but a dependency can be force-loaded or merely disabled,
-- so ui_frame.lua keeps a guard and this suite is its regression test.
--
-- Both directions are asserted: Core absent => hook SKIPPED, Blizzard globals identical,
-- exactly one notice; Core present => hook INSTALLED, all nine replaced. A guard that
-- always skips would be just as broken as one that never does.
----------------------------------------------------------------------
local BLIZZ_BAG_GLOBALS = {
    "ToggleBackpack", "ToggleAllBags", "ToggleBag",
    "OpenAllBags", "OpenBackpack", "OpenBag",
    "CloseAllBags", "CloseBackpack", "CloseBag",
}

ns:RegisterSelfTest("core-absent-login", function(verbose)
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local Frame = ns.Frame
    if not Frame then
        ns:Print("  FAIL core-absent-login :: ns.Frame is nil (ui_frame.lua did not load)")
        return false
    end

    -- ── stub set: a frame factory good enough for the login wiring ────────────────
    local function newFrame()
        local f = {}
        setmetatable(f, { __index = function(t, k)
            local v = rawget(t, "__m_" .. k)
            if v then return v end
            local fn = function() return nil end
            rawset(t, "__m_" .. k, fn)
            return fn
        end })
        return f
    end

    -- Everything we touch, saved for restore. Later suites (and the ui_frame suite's own
    -- headless OnLogin) must not see any of this. Saved into ORDERED slots rather than a
    -- name->value map on purpose: in this harness nearly every one of these globals is
    -- legitimately nil, and a nil value simply vanishes from a table (pairs would skip
    -- it), which would leave the stubs installed for every suite that runs after us.
    local STUBBED_GLOBALS = { "CreateFrame", "DaseekiUI", "UIParent", "UISpecialFrames",
                              "hooksecurefunc", "C_Timer", "InCombatLockdown" }
    local savedGlobal = {}
    for i, n in ipairs(STUBBED_GLOBALS) do savedGlobal[i] = _G[n] end
    local savedBag = {}
    for i, n in ipairs(BLIZZ_BAG_GLOBALS) do savedBag[i] = _G[n] end
    local savedHooked, savedOrig      = Frame._hooked, Frame._orig
    local savedStrip, savedNoticed    = Frame._stripEvt, Frame._coreMissingNoticed
    local savedPrint                  = ns.Print

    local function restore()
        for i, n in ipairs(STUBBED_GLOBALS)  do _G[n] = savedGlobal[i] end
        for i, n in ipairs(BLIZZ_BAG_GLOBALS) do _G[n] = savedBag[i] end
        Frame._hooked, Frame._orig = savedHooked, savedOrig
        Frame._stripEvt, Frame._coreMissingNoticed = savedStrip, savedNoticed
        ns.Print = savedPrint
    end

    _G.CreateFrame      = function() return newFrame() end
    _G.UIParent         = newFrame()
    _G.UISpecialFrames  = {}
    _G.hooksecurefunc   = function() end
    _G.C_Timer          = { After = function() end }
    _G.InCombatLockdown = function() return false end

    -- Sentinel Blizzard bag globals: distinct closures, so "was it replaced?" is an
    -- identity comparison and "did Blizzard's own function run?" is observable.
    local blizzRan = {}
    for _, n in ipairs(BLIZZ_BAG_GLOBALS) do
        _G[n] = function() blizzRan[#blizzRan + 1] = n end
    end
    local sentinel = {}
    for _, n in ipairs(BLIZZ_BAG_GLOBALS) do sentinel[n] = _G[n] end

    -- Capture what the addon says to the owner.
    local notices = {}
    ns.Print = function(_, ...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        notices[#notices + 1] = table.concat(parts, "\t")
    end

    -- ── 1. CORE ABSENT ────────────────────────────────────────────────────────────
    _G.DaseekiUI = nil
    Frame._hooked, Frame._coreMissingNoticed, Frame._stripEvt = false, false, nil

    ck(Frame.Ensure() == nil,
       "PREMISE: Frame.Ensure() returns nil without DaseekiUI -- no window can be built")

    local okLogin, errLogin = pcall(Frame.OnLogin)
    ck(okLogin, "Frame.OnLogin runs in-game with Core absent (" .. tostring(errLogin) .. ")")

    local replaced = {}
    for _, n in ipairs(BLIZZ_BAG_GLOBALS) do
        if _G[n] ~= sentinel[n] then replaced[#replaced + 1] = n end
    end
    ck(#replaced == 0,
       "THE FIX: Blizzard's bag globals are LEFT ALONE with Core absent (replaced: " ..
       (#replaced > 0 and table.concat(replaced, ", ") or "none") .. ")")
    ck(Frame._hooked == false, "…HookBagToggles never ran, so nothing was captured either")

    ck(#notices == 1, "exactly one notice printed (got " .. #notices .. ")")
    ck(notices[1] == Frame.CORE_MISSING_NOTICE,
       "…and it is the plain-language Core notice, verbatim (got " ..
       tostring(notices[1]) .. ")")
    ck(Frame.CORE_MISSING_NOTICE:find("Daseeki%-Core") ~= nil and
       Frame.CORE_MISSING_NOTICE:find("Blizzard") ~= nil,
       "…the notice names the missing addon AND says the standard bags are in use")

    -- The whole point: the owner's bag key still opens the Blizzard backpack.
    blizzRan = {}
    local okT = pcall(_G.ToggleBackpack)
    ck(okT and blizzRan[1] == "ToggleBackpack",
       "the bag key still reaches Blizzard's own ToggleBackpack (the owner has bags)")

    -- Idempotent: a /reload-storm must not spam chat.
    pcall(Frame.OnLogin)
    ck(#notices == 1, "a second login does not repeat the notice (got " .. #notices .. ")")

    -- ── 2. CORE PRESENT (the guard is not a permanent off-switch) ─────────────────
    Frame._hooked, Frame._coreMissingNoticed, Frame._stripEvt = false, false, nil
    for _, n in ipairs(BLIZZ_BAG_GLOBALS) do _G[n] = sentinel[n] end
    -- EnsureBagToggleHook only asks whether DaseekiUI EXISTS; it never builds the window,
    -- so an opaque marker table is a faithful stand-in for Daseeki-Core here.
    _G.DaseekiUI = { __harnessStub = true }

    ck(Frame.EnsureBagToggleHook() == true, "with Core present the hook reports installed")
    local stillBlizz = {}
    for _, n in ipairs(BLIZZ_BAG_GLOBALS) do
        if _G[n] == sentinel[n] then stillBlizz[#stillBlizz + 1] = n end
    end
    ck(#stillBlizz == 0,
       "…and all " .. #BLIZZ_BAG_GLOBALS .. " Blizzard bag globals are ours again (missed: " ..
       (#stillBlizz > 0 and table.concat(stillBlizz, ", ") or "none") .. ")")
    ck(type(Frame._orig) == "table" and Frame._orig.ToggleBackpack == sentinel.ToggleBackpack,
       "…with the originals captured for restore")
    ck(#notices == 1, "…and nothing extra printed on the healthy path")

    -- ── 3. HEADLESS stays silent ──────────────────────────────────────────────────
    -- No CreateFrame means no bag globals to protect and no chat to print to; the other
    -- suites drive OnLogin in exactly that state and must not accumulate chat noise.
    Frame._hooked, Frame._coreMissingNoticed = false, false
    _G.CreateFrame, _G.DaseekiUI = nil, nil
    ck(Frame.EnsureBagToggleHook() == false, "headless: the hook reports not installed")
    ck(#notices == 1, "headless: and prints nothing (got " .. #notices .. " notices total)")

    restore()

    if verbose then
        ns:Print(string.format("  core-absent: %d bag global(s) protected, notice=%q",
            #BLIZZ_BAG_GLOBALS, Frame.CORE_MISSING_NOTICE))
    end

    for _, f in ipairs(fails) do ns:Print("  FAIL core-absent-login :: " .. f) end
    if #fails == 0 and verbose then ns:Print("  PASS core-absent-login") end
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
