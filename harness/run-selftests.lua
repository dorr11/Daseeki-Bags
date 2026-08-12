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
--
--  5. THE 1.x TREE STAYS DELETED (added 2026-08-03 with the syncBridge.lua removal).
--     The cutover (423aa3d) deleted main.xml + core/ config/ frames/ skin/ libs/, but
--     core/features/syncBridge.lua survived it: the file was created on `main` AFTER the
--     v2 branch point, so it was absent from the merge base and the merge kept it as an
--     unrelated addition. It then sat in the tree for months -- git-tracked, shipped in
--     the zip (.pkgmeta ignores harness/ and dev/, not core/), never on the load list.
--     That is a landmine, not just clutter: it publishes the 1.x `bags` namespace via
--     Addon:NewModule('SyncBridge'), and Daseeki-Nexus's inventory coexistence probe
--     reads a live SyncBridge module as "Bags owns the wire" and flips the account to
--     consume-only. One line added to a load list would do it silently. A file that is
--     not on disk cannot be re-added by accident, so the gate pins the ABSENCE of the
--     whole retired tree rather than any one filename.
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
-- The 1.x source tree the cutover deleted (see the gate header, point 5). Nothing in the
-- 2.0 load list lives under any of these; a path that comes back is 1.x code returning.
local RETIRED_1X_PATHS = { "main.xml", "core", "config", "frames", "skin", "libs" }

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

-- The 1.x tree must stay gone (gate header, point 5). os.rename(p, p) is the pure-Lua
-- 5.1 existence probe that works for DIRECTORIES as well as files (io.open cannot open a
-- directory); renaming a path onto itself is a no-op when it exists and nil when it does
-- not. No lfs, no shelling out.
local treeFails = 0
for _, path in ipairs(RETIRED_1X_PATHS) do
    if os.rename(P(path), P(path)) then
        idFails, treeFails = idFails + 1, treeFails + 1
        realprint("  [FAIL] the retired 1.x tree is back on disk: " .. path)
        realprint("         The 2.0 cutover deleted main.xml + core/ config/ frames/ skin/")
        realprint("         libs/; git history and tag v1.1.5 keep them. 1.x sources left in")
        realprint("         the folder ship in the CurseForge zip and are one load-list line")
        realprint("         away from running -- core/features/syncBridge.lua was exactly")
        realprint("         that, and it would hand cross-account sync back to the 1.x bags")
        realprint("         namespace (Nexus reads a live SyncBridge module as 'Bags owns")
        realprint("         the wire' and drops the account to consume-only).")
    end
end
if treeFails == 0 then
    realprint("  [ok] the retired 1.x tree is absent (" ..
              table.concat(RETIRED_1X_PATHS, ", ") .. ")")
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
-- QUEUE-AND-PUMP TIMER  (2026-08-07 — simulator doctrine)
--
-- WHAT WAS HERE BEFORE: nothing at the top level, and `_G.C_Timer = { After = function() end }`
-- — a NO-OP — inside the core-absent-login suite. With no C_Timer at all, every deferral in
-- the addon takes its `else fire()` branch and runs INLINE; with the no-op, it never runs at
-- all. Neither is a client. Both are KIND, in the specific sense the suite async audit
-- names: they erase the gap between "scheduled" and "ran", and a whole defect class lives
-- in that gap.
--
-- That is not theoretical here. BAG-1 — BANKFRAME_CLOSED scheduling a deferred capture and
-- then clearing `_bankOpen` on the very next SYNCHRONOUS line — is invisible under an inline
-- timer, because inline means the capture ran BEFORE the flag was cleared. Under a real
-- queue the capture runs after, reads `{ bank = false }`, and silently skips the bank. The
-- bug was structurally unobservable headless for as long as this stub existed.
--
-- So: a real queue with a virtual clock. Ports the shape the repo already trusts —
-- sort.lua's in-file simulator (`S.after`) and capture.lua's equip sim — up to harness
-- level, so every suite runs against it by default rather than each rig having to build its
-- own. Sequence numbers break ties so equal-deadline callbacks fire in schedule order
-- (Class 8: never let a retry loop depend on table order), and a callback that schedules
-- another timer is picked up inside the same sweep.
--
-- `flush` is the between-suites broom: it drains the whole queue whatever the deadlines,
-- so one suite's pending deferral can never fire in the middle of the next one. Suites that
-- want to observe timing drive `advance` themselves.
----------------------------------------------------------------------
local HTIMER = { clock = 0, queue = {}, seq = 0, ran = 0, peak = 0 }

function HTIMER.After(delay, fn)
    if type(fn) ~= "function" then return end
    HTIMER.seq = HTIMER.seq + 1
    HTIMER.queue[#HTIMER.queue + 1] =
        { at = HTIMER.clock + (tonumber(delay) or 0), fn = fn, seq = HTIMER.seq }
    if #HTIMER.queue > HTIMER.peak then HTIMER.peak = #HTIMER.queue end
end

function HTIMER.pending() return #HTIMER.queue end

-- Run every callback due at or before clock+dt, earliest-then-oldest first, and park the
-- clock at the target. `dt` of nil/huge with `all` set drains everything.
local function drain(target, all)
    while true do
        local best, bi
        for i = 1, #HTIMER.queue do
            local t = HTIMER.queue[i]
            if (all or t.at <= target) and
               (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then
                best, bi = t, i
            end
        end
        if not best then break end
        table.remove(HTIMER.queue, bi)
        if best.at > HTIMER.clock then HTIMER.clock = best.at end
        HTIMER.ran = HTIMER.ran + 1
        local ok, err = pcall(best.fn)
        if not ok then realprint("  !! harness timer callback error: " .. tostring(err)) end
    end
    if target and target > HTIMER.clock then HTIMER.clock = target end
end

function HTIMER.advance(dt) drain(HTIMER.clock + (tonumber(dt) or 0), false) end
function HTIMER.flush()     drain(nil, true) end
function HTIMER.reset()
    HTIMER.queue, HTIMER.seq = {}, 0
end

_G.C_Timer = { After = function(delay, fn) HTIMER.After(delay, fn) end }

-- The harness handle. Deliberately a name no addon file mentions, so a suite reaching for
-- it is obviously reaching for the RIG and not for a shipped API.
_G.__DaseekiHarnessTimer = HTIMER

----------------------------------------------------------------------
-- THE OWNERSHIP BEACON  (2026-08-12 — the container-click taint fix)
--
-- Every simulator in this addon installs a fake client over the global table: sort.lua's
-- swaps eleven globals including C_Container and BankFrame, capture's swaps C_Container and
-- GetTime, ui_bank's swaps BankFrame, store's nils the SavedVariables tables. That contract
-- — "I own _G" — is TRUE here and FALSE in a client, and the addon used to assume it either
-- way: `/bags debug selftest` ran the whole set in-game. Two of those globals are read by
-- ContainerFrame_Shared.lua:1341 on the way to the protected UseContainerItem call, so one
-- diagnostic command blocked every right-click-to-use for the rest of the session and put
-- this addon's name on the error. (It also re-inited the owner's saved data.)
--
-- ns:HarnessOwnsGlobals() now answers that question from POSITIVE EVIDENCE only: this
-- beacon, which exists in this file and nowhere else. Planted before the addon loads so the
-- suites see it; the taint gate at the bottom takes it away again to prove the refusal.
----------------------------------------------------------------------
_G.__DaseekiBagsHarness = true

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
                -- Every suite runs between two timer flushes. Before: whatever the previous
                -- suite left scheduled has already fired, so it cannot land in the middle of
                -- this one's premise. After: this suite's own deferrals actually RUN, inside
                -- its own world, rather than leaking into the next suite's.
                -- (Real timers make deferrals real; that is the point, and it also makes
                -- suite isolation something the rig has to state rather than assume.)
                return v(self, name, function(...)
                    HTIMER.flush()
                    local r = fn(...)
                    HTIMER.flush()
                    return r
                end)
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
    "bank-closeout",
    "borders", "capture", "cell-parity", "core", "equip-refresh", "features", "locks",
    "migrate", "migrate_settings", "nexus",
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
    -- The REAL queue-and-pump timer, not the no-op this line used to install. A no-op here
    -- meant "scheduled" and "ran" were the same word, which is exactly the blindness that
    -- hid BAG-1. This suite exercises the login wiring, which schedules; the flush at the
    -- end of the run drains whatever it left.
    _G.C_Timer          = { After = function(d, fn) HTIMER.After(d, fn) end }
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
-- FRESH-LOGIN FIND SUITE  (added 2026-08-07, data-honesty BAG-1 / BAG-2)
--
-- ui_find.lua's own suite pins the PURE contract: Find.Search hands back the ids it could
-- not judge, and Find.StatusText refuses to call an unanswered question a miss. What it
-- cannot see is the LIVE CHAIN those pieces hang from, which is where the defect actually
-- lived: the file registered no events at all, asked the client for nothing, and so never
-- ran the search a second time. Pure functions returning the right values are worth
-- nothing if nobody ever calls them again.
--
-- This suite is the fresh-login fixture end to end, against a client sim as unkind as the
-- real one (simulator doctrine): GetItemInfoInstant answers from static data, GetItemInfo
-- answers NOTHING until the sim is warmed id by id, and time only passes when the
-- queue-and-pump clock is pumped. The four things it proves:
--
--   RED CONTROL   a cold first pass finds zero holders — that is real, and it is exactly
--                 what the shipped window rendered as "No character has a matching item"
--                 for an item three alts were holding. The new chain renders the SAME zero
--                 rows as an in-progress instead, and asks the client for the ids.
--   GREEN         warming the sim and firing GET_ITEM_INFO_RECEIVED re-runs the search
--                 with no further input, and the matches appear.
--   THE BOUND     ids that NEVER answer do not spin: the ladder runs its rungs, the queue
--                 drains, the surfaces stop claiming to be loading. (A run that hangs here
--                 IS the failure — an unbounded retry has no other symptom headless.)
--   WARM CLIENT   nothing pending -> no event frame, no request, no timer, one pass. The
--                 fix must not tax the healthy path.
--
-- The surface is a faithful stand-in for Find.Refresh's body minus the frame calls (the
-- window itself needs Daseeki-Core), so it drives the real Find.Search / BuildItemRows /
-- MergeIDs / NotePending / StatusText and the real shared watch.
----------------------------------------------------------------------
ns:RegisterSelfTest("cold-find-chain", function(verbose)
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local Find = ns.Find
    if not (Find and Find.NotePending) then
        ns:Print("  FAIL cold-find-chain :: ns.Find has no cold-item watch (ui_find.lua changed)")
        return false
    end

    -- ── saved state ───────────────────────────────────────────────────────────────
    local savedCI, savedCF = _G.C_Item, _G.CreateFrame
    local savedWatch, savedAsks, savedSurfaces = Find._watch, Find._asks, Find._surfaces
    local savedEvt, savedRound = Find._evt, Find._watchRound
    local savedExh, savedTimer, savedQueued =
        Find._watchExhausted, Find._watchTimer, Find._repaintQueued

    -- ── the client sim ────────────────────────────────────────────────────────────
    -- Three ids on three characters: two in slots, one in a cross-account summary
    -- aggregate — so both of Find.Search's branches are cold at once.
    local CATALOG = {
        [100] = { name = "Songflower Serenade Petal", quality = 1, itype = "Consumable" },
        [101] = { name = "Songflower Petal Pouch",    quality = 2, itype = "Consumable" },
        [102] = { name = "Songflower Essence",        quality = 3, itype = "Consumable" },
    }
    local owners = {
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full",
            containers = { [0] = { slots = { [1] = { id = 100, count = 20 } } } } },
        ["Zug-R"] = { name = "Zug", class = "WARRIOR", source = "full",
            containers = { [5] = { slots = { [1] = { id = 101, count = 5 } } } } },
        ["Rex-R"] = { name = "Rex", source = "summary", containers = {},
            itemCounts = { [102] = 99 } },
    }

    local warm, asks, evtFrames, instantWarm
    local fireInfoReceived
    -- CLASS 9 (2026-08-11). `dispatch` is the sim's delivery posture and it defaults to the
    -- UNKIND one. RequestLoadItemDataByID does not always SCHEDULE its answer: for an id the
    -- client already holds, GET_ITEM_INFO_RECEIVED is dispatched from INSIDE the request and
    -- every handler in the session runs before it returns. This sim used to record the ask
    -- and nothing else — it never echoed at all, which is even kinder than echoing late, and
    -- it is why "subscribe after the asks" survived here for two releases. "async" is the
    -- named variant (the old behaviour: an answer only ever arrives via fireInfoReceived).
    local dispatch = "sync"
    local function newSim()
        warm, asks, evtFrames, instantWarm = {}, {}, {}, {}
        _G.C_Item = {
            GetItemInfoInstant = function(id)
                local e = CATALOG[id]; if not e then return nil end
                return id, e.itype, e.itype, "", 5000 + id
            end,
            -- THE UNKIND BIT: nil until this id has been warmed, exactly as the client
            -- answers for an itemID no tooltip has touched this session.
            GetItemInfo = function(id)
                local e = CATALOG[id]
                if not (e and warm[id]) then return nil end
                return e.name, "item:" .. id, e.quality
            end,
            RequestLoadItemDataByID = function(id)
                asks[id] = (asks[id] or 0) + 1
                -- THE CLASS-9 BIT: for an id the client already holds, the request
                -- MATERIALISES the data and announces it from inside itself. The addon's
                -- own first ask is therefore also its first echo.
                if dispatch == "sync" and instantWarm[id] then
                    warm[id] = true
                    fireInfoReceived(id)
                end
            end,
        }
        _G.CreateFrame = function()
            local f = { _events = {} }
            function f:RegisterEvent(e) self._events[e] = true end
            function f:UnregisterEvent(e) self._events[e] = nil end
            function f:SetScript(which, fn) if which == "OnEvent" then self._onEvent = fn end end
            evtFrames[#evtFrames + 1] = f
            return f
        end
    end
    function fireInfoReceived(id, success)
        for _, f in ipairs(evtFrames) do
            if f._events["GET_ITEM_INFO_RECEIVED"] and f._onEvent then
                f._onEvent(f, "GET_ITEM_INFO_RECEIVED", id, success ~= false)
            end
        end
    end
    local function askCount()
        local n = 0
        for _ in pairs(asks) do n = n + 1 end
        return n
    end

    -- ── the surface (Find.Refresh's body, minus the frame calls) ──────────────────
    local view
    local function resolver()
        return { instant = _G.C_Item.GetItemInfoInstant, info = _G.C_Item.GetItemInfo }
    end
    local function render(fromWatch)
        view.renders = view.renders + 1
        if not fromWatch then Find.ResetWatch() end
        local q = ns.Search.Compile(view.query)
        local R = resolver()
        local results, searchPending = Find.Search(owners, q, R, {})
        local rows, rowPending = Find.BuildItemRows(results, R)
        local ids = Find.MergeIDs(searchPending, rowPending)
        Find.NotePending(ids)
        view.rows, view.pending = #rows, #ids
        view.empty, view.status = Find.StatusText({
            hasQuery = true, rows = #rows, pending = #ids,
            exhausted = Find._watchExhausted })
    end
    local function freshWorld(query)
        newSim()
        Find._watch, Find._asks = {}, {}
        Find._evt, Find._watchRound = nil, 0
        Find._watchExhausted, Find._watchTimer, Find._repaintQueued = false, false, false
        Find._surfaces = { function() render(true) end }
        view = { query = query, renders = 0 }
        HTIMER.flush(); HTIMER.reset()
    end

    -- ══ 1. RED CONTROL: the cold first pass ═══════════════════════════════════════
    freshWorld("songflower")
    render(false)

    ck(view.rows == 0,
       "PREMISE: on a cold client the matcher can judge nothing, so the first pass finds " ..
       "ZERO rows (this part was always true and is not the bug)")
    ck(view.empty ~= "No character has a matching item.",
       "THE FIX: those zero rows are NOT rendered as a miss — the shipped window said " ..
       "exactly that line about an item three alts were holding")
    ck(type(view.empty) == "string" and view.empty:find("Still loading", 1, true) == 1,
       "…it reads as an in-progress instead: " .. tostring(view.empty))
    ck(view.pending == 3, "…all three ids are held pending (got " .. view.pending .. ")")

    ck(askCount() == 3, "…the client was ASKED for each of them (got " .. askCount() .. " ids)")
    ck(asks[100] == 1 and asks[101] == 1 and asks[102] == 1,
       "…once each; NotePending does not re-ask what is already on the watch")
    ck(#evtFrames == 1 and evtFrames[1]._events["GET_ITEM_INFO_RECEIVED"] == true,
       "…and ONE event frame now listens for the answers (the file used to register none)")
    ck(HTIMER.pending() == 1, "…with exactly one ladder rung armed (got " .. HTIMER.pending() .. ")")

    -- ══ 2. GREEN: answers land, the search re-runs itself ═════════════════════════
    -- One id warms. Nothing else happens — no keystroke, no re-open, no owner action.
    warm[100] = true
    fireInfoReceived(100)
    ck(view.renders == 1, "the event alone does not re-run the search inline (it debounces)")
    HTIMER.advance(0)
    ck(view.renders == 2, "…the debounced repaint runs on the next tick")
    ck(view.rows == 1,
       "THE MATCH APPEARS with no further input from the owner (got " .. view.rows .. " row(s))")
    ck(view.pending == 2, "…and the two still-unanswered ids stay held (got " .. view.pending .. ")")
    ck(view.empty == nil, "…so there is no empty line at all now")
    ck(view.status == "still loading 2 items\226\128\166",
       "…and the short list TAGS its own incompleteness: " .. tostring(view.status))

    -- The rest warm.
    warm[101], warm[102] = true, true
    fireInfoReceived(101); fireInfoReceived(102)
    HTIMER.advance(0)
    ck(view.rows == 3, "every holder lands once the client is warm (got " .. view.rows .. ")")
    ck(view.pending == 0 and view.status == nil,
       "…nothing outstanding, so the surface stops talking about loading")
    ck(next(Find._watch) == nil, "…and the watch set is empty again")

    -- The ladder was still armed underneath; draining it must be a no-op, not a re-ask.
    local asksBefore = asks[100]
    HTIMER.flush()
    ck(asks[100] == asksBefore, "a rung firing after everything answered re-asks nothing")
    ck(HTIMER.pending() == 0, "…and schedules nothing further")

    -- ══ 3. THE BOUND: ids that never answer ═══════════════════════════════════════
    -- Nothing is ever warmed. A run that HANGS here is the failure this asserts against:
    -- an unbounded retry ladder has no other headless symptom.
    freshWorld("songflower")
    render(false)
    ck(view.pending == 3, "premise: three ids the client will never answer for")
    HTIMER.flush()                       -- drains rungs, repaints, and their nested timers
    ck(HTIMER.pending() == 0, "THE BOUND: the queue drains to empty — the ladder is finite")
    ck(Find._watchExhausted == true, "…and the cycle closes itself out as exhausted")
    ck(Find._watchRound == #Find.WATCH_LADDER,
       "…after exactly " .. #Find.WATCH_LADDER .. " rungs (got " .. Find._watchRound .. ")")
    ck(view.rows == 0, "still no rows (nothing warmed) …")
    ck(view.empty:find("No character has a matching item.", 1, true) == 1,
       "…so the miss is now STATED rather than implied: " .. view.empty)
    ck(view.empty:find("3 items never sent their data", 1, true) ~= nil,
       "…together with what went unchecked, which is the honest half")
    ck(view.empty:find("Still loading", 1, true) == nil,
       "…and it has stopped claiming to be loading, because it is not")
    for id in pairs(asks) do
        ck(asks[id] <= Find.MAX_ASKS,
           "id " .. id .. " was asked for " .. asks[id] .. " time(s), within the ceiling of " ..
           Find.MAX_ASKS)
    end

    -- A late answer STILL heals, after the timers have stopped: the event subscription is
    -- free, so only the ladder is bounded, not the listening.
    local rendersAtRest = view.renders
    warm[100] = true
    fireInfoReceived(100)
    HTIMER.advance(0)
    ck(view.renders == rendersAtRest + 1, "a late GET_ITEM_INFO_RECEIVED still repaints")
    ck(view.rows == 1, "…and the match appears even past the ladder's last rung")
    HTIMER.flush()

    -- ══ 4. WARM CLIENT: unchanged, single pass ════════════════════════════════════
    freshWorld("songflower")
    warm[100], warm[101], warm[102] = true, true, true
    render(false)
    ck(view.rows == 3, "a warm client finds all three holders on the first pass")
    ck(view.pending == 0 and view.status == nil and view.empty == nil, "…with nothing to say")
    ck(askCount() == 0, "…asks the client for NOTHING (got " .. askCount() .. ")")
    ck(#evtFrames == 0, "…creates no event frame")
    ck(Find._evt == nil, "…leaves the watch frame unbuilt")
    ck(HTIMER.pending() == 0, "…and arms no timer: the healthy path is untaxed")
    HTIMER.flush()
    ck(view.renders == 1, "…and never re-runs itself (got " .. view.renders .. " render(s))")

    -- ══ 5. CLASS 9: THE CLIENT ANSWERS INSIDE THE ASK ═════════════════════════════
    -- The posture the sim was blind to until 2026-08-11. Every id here is one the client
    -- already holds: cold to the matcher when it is judged, warm the instant it is asked
    -- for, and announced from INSIDE RequestLoadItemDataByID. The whole first pass is
    -- therefore its own echo, and whether it is heard depends entirely on whether the
    -- listener existed BEFORE the first ask.
    local function class9Round(buildFrameLate)
        freshWorld("songflower")
        for id in pairs(CATALOG) do instantWarm[id] = true end
        local realEnsure = Find.EnsureWatchFrame
        if buildFrameLate then
            -- 2.0.7's ordering, reproduced exactly: no listener exists while the asks go
            -- out, and the frame is built afterwards.
            Find.EnsureWatchFrame = function() end
        end
        render(false)
        Find.EnsureWatchFrame = realEnsure
        if buildFrameLate then Find.EnsureWatchFrame() end
        local left = 0
        for _ in pairs(Find._watch) do left = left + 1 end
        return left
    end

    ck(class9Round(true) == 3,
       "RED CONTROL: with the watch frame built AFTER the asks, all 3 in-call answers are " ..
       "delivered to nothing and every id stays on the watch")
    ck(view.rows == 0 and view.pending == 3,
       "…so the first pass shows NOTHING for three items the client answered for in the " ..
       "very calls that asked (rows=" .. view.rows .. " pending=" .. view.pending .. ")")
    ck(view.empty ~= nil and view.empty:find("Still loading", 1, true) == 1,
       "…and tells the owner it is still loading them: " .. tostring(view.empty))
    -- It is not permanent — the ladder's first rung re-asks and the frame exists by then —
    -- but the heal costs a rung of latency and a SECOND request per id against the ceiling,
    -- for data the client had already handed over.
    HTIMER.advance(Find.WATCH_LADDER[1]); HTIMER.advance(0)
    ck(view.rows == 3, "…the ladder eventually heals it (rows=" .. view.rows .. ")")
    ck(asks[100] == 2, "…having spent a second ask per id to get there (asked "
       .. tostring(asks[100]) .. "x of a ceiling of " .. Find.MAX_ASKS .. ")")
    HTIMER.flush()

    ck(class9Round(false) == 0,
       "GREEN: subscribed before the first ask, every in-call answer lands and the watch " ..
       "empties inside the render itself")
    HTIMER.advance(0)
    ck(view.rows == 3, "…all three holders resolve on the FIRST pass (got " .. view.rows .. ")")
    ck(view.pending == 0 and view.status == nil and view.empty == nil,
       "…with nothing left to claim about loading")
    ck(asks[100] == 1, "…for ONE request per id (got " .. tostring(asks[100]) .. ")")
    ck(Find._watchExhausted == false, "…and the ladder never had to run out")
    HTIMER.flush()

    -- THE BLIND SPOT, NAMED: run the SAME late-built sequence with async delivery and it
    -- looks perfectly healthy — the answers simply have not arrived yet, and the ladder
    -- heals it. That posture is why the ordering above survived two releases.
    dispatch = "async"
    ck(class9Round(true) == 3, "async premise: nothing answered in the call")
    HTIMER.advance(0)
    for id in pairs(CATALOG) do warm[id] = true; fireInfoReceived(id) end
    HTIMER.advance(0)
    ck(view.rows == 3,
       "…and under async the late-built frame still catches every answer — a sim that " ..
       "delivers after the call returns can never see this defect")
    dispatch = "sync"
    HTIMER.flush()

    -- ── restore ───────────────────────────────────────────────────────────────────
    HTIMER.flush(); HTIMER.reset()
    _G.C_Item, _G.CreateFrame = savedCI, savedCF
    Find._watch, Find._asks, Find._surfaces = savedWatch, savedAsks, savedSurfaces
    Find._evt, Find._watchRound = savedEvt, savedRound
    Find._watchExhausted, Find._watchTimer, Find._repaintQueued =
        savedExh, savedTimer, savedQueued

    if verbose then
        ns:Print(string.format("  cold-find: ladder=%d rung(s)/%.2fs ceiling, max %d ask(s) per id",
            #Find.WATCH_LADDER, Find.LadderCeiling(), Find.MAX_ASKS))
    end

    for _, f in ipairs(fails) do ns:Print("  FAIL cold-find-chain :: " .. f) end
    if #fails == 0 and verbose then ns:Print("  PASS cold-find-chain") end
    return #fails == 0
end)

----------------------------------------------------------------------
-- TIMER GATE — the rig proving itself
--
-- This gate exists because the thing it tests used to be a lie. A no-op C_Timer.After made
-- "scheduled" and "ran" the same word, and a whole defect class (BAG-1) lived in the gap
-- between them. A rig that can be wrong about its own clock cannot be trusted about
-- anything downstream of one, so the clock is now a gate in its own right — alongside the
-- toc parse gate and the suite roster, and before a single suite runs.
--
-- The last block is the one that matters: a REAL deferred capture, scheduled by the real
-- Capture.RequestCapture, must be observably NOT DONE before the pump and DONE after.
----------------------------------------------------------------------
realprint("")
realprint("=== queue-and-pump timer gate ===")
local timerPass = true
do
    local function ck(c, m)
        if not c then timerPass = false; realprint("  [FAIL] " .. m) end
    end

    HTIMER.flush()
    HTIMER.reset()
    local order = {}

    -- 1. QUEUES rather than runs.
    _G.C_Timer.After(0, function() order[#order + 1] = "a0" end)
    ck(#order == 0, "C_Timer.After(0) QUEUES; it must not run inline (this is the whole point)")
    ck(HTIMER.pending() == 1, "…and the callback is on the queue")

    -- 2. Deadline order, with schedule order as the tiebreak (Class 8: never let equal
    --    deadlines resolve by table order).
    _G.C_Timer.After(0, function() order[#order + 1] = "b0" end)
    _G.C_Timer.After(0.5, function()
        order[#order + 1] = "c50"
        -- 3. A callback that schedules another is picked up in the SAME sweep.
        _G.C_Timer.After(0, function() order[#order + 1] = "d-nested" end)
    end)
    _G.C_Timer.After(0.1, function() order[#order + 1] = "e10" end)

    HTIMER.advance(1.0)
    ck(table.concat(order, ",") == "a0,b0,e10,c50,d-nested",
       "callbacks fire earliest-deadline-first, ties in schedule order, nested picked up in " ..
       "the same sweep (got: " .. table.concat(order, ",") .. ")")
    ck(HTIMER.pending() == 0, "…and the queue drains")

    -- 4. A deadline beyond the advance window does NOT fire; flush takes it regardless.
    order = {}
    _G.C_Timer.After(30, function() order[#order + 1] = "far" end)
    HTIMER.advance(1.0)
    ck(#order == 0, "a callback 30s out does not fire on a 1s advance (the clock is real)")
    HTIMER.flush()
    ck(order[1] == "far", "…and flush drains it whatever the deadline (the between-suites broom)")

    -- 5. THE POINT: a real deferred capture actually runs.
    local Capture, Store = ns.Capture, ns.Store
    if not (Capture and Store) then
        ck(false, "ns.Capture / ns.Store missing — the load order changed")
    else
        local savedData, savedDB, savedCC = _G.DaseekiBags2Data, _G.DaseekiBags2DB, _G.C_Container
        local savedQueued, savedBank = Capture._captureQueued, Capture._bankOpen
        local scans = 0
        _G.DaseekiBags2Data, _G.DaseekiBags2DB = nil, nil
        Store.Init()
        _G.C_Container = {
            GetContainerNumSlots = function(cid)
                if cid == 0 then scans = scans + 1 end
                return cid == 0 and 16 or 0
            end,
            GetContainerItemInfo     = function() return nil end,
            ContainerIDToInventoryID = function(cid) return 19 + cid end,
            GetContainerNumFreeSlots = function() return 0, 0 end,
        }
        Capture._captureQueued, Capture._bankOpen = false, false
        HTIMER.reset()

        Capture.RequestCapture()
        ck(scans == 0,
           "a requested capture has NOT run yet (scans=" .. scans .. ") — under the old no-op " ..
           "stub this was indistinguishable from having run, which is exactly why BAG-1 was " ..
           "structurally unobservable headless")
        ck(HTIMER.pending() == 1, "…it is sitting on the queue")
        HTIMER.advance(0.01)
        ck(scans == 1, "…and it REALLY RUNS when the clock is pumped (scans=" .. scans .. ")")

        _G.C_Container = savedCC
        Capture._captureQueued, Capture._bankOpen = savedQueued, savedBank
        _G.DaseekiBags2Data, _G.DaseekiBags2DB = savedData, savedDB
        Store.Init()
    end

    HTIMER.flush()
    HTIMER.reset()
    realprint(string.format("  %d callback(s) run, queue peak %d", HTIMER.ran, HTIMER.peak))
end
realprint("=== queue-and-pump timer gate: " .. (timerPass and "PASS" or "FAIL") .. " ===")

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

----------------------------------------------------------------------
-- TAINT / STOCK-SURFACE GATE   (2026-08-12 — the container-click taint defect)
--
-- WHAT THE CLIENT SAID, and what it means:
--
--   [ADDON_ACTION_BLOCKED] AddOn 'Daseeki-Bags' tried to call the protected
--   function 'UseContainerItem()'.
--   [C]: in function 'UseContainerItem'
--   [Blizzard_UIPanels_Game/Classic/ContainerFrame_Shared.lua]:1341: in function <...1288>
--
-- Line 1288 is `function ContainerFrameItemButton_OnClick(self, button)`; line 1341 is the
-- right-button branch's protected call, and it reads exactly two GLOBALS on the way:
--
--   C_Container.UseContainerItem(self:GetParent():GetID(), self:GetID(), nil, nil,
--                                BankFrame:IsShown() and (BankFrame.selectedTab == 2));
--
-- Reading a value an addon wrote taints the reader; the reader here is one token away from a
-- protected call. Our self-test rigs write BOTH of those globals — and the addon let them
-- run in a client.
--
-- WHAT THIS GATE CAN PROVE, HONESTLY. It cannot model the client's real taint bits: those
-- live in Blizzard's Lua VM and no headless rig has them. What it CAN do, and does:
--
--   LEG 1  BEHAVIOUR — take the ownership beacon away (i.e. BE a client), ask the addon to
--          run its self-tests, and assert (a) it refuses and (b) not one watched global or
--          saved-variable table changed identity. This is the defect itself, reproduced:
--          against 2.0.8 leg 1 is RED — the suites run, C_Container becomes sort.lua's fake,
--          BankFrame becomes nil, DaseekiBags2Data is re-inited from defaults.
--   LEG 2  MECHANISM — a taint MODEL: a transcription of line 1341's read set, plus a rule
--          ("a global whose identity we changed is a global we tainted"). It is driven twice:
--          once with the pre-fix write set fed in, which must BLOCK and must name this addon
--          (proving the model has teeth and pinning the mechanism as a fact); once with
--          whatever leg 1 actually observed, which must not block.
--   LEG 3  STRUCTURE — the stock-surface ledger, walked: every Blizzard-owned name the addon
--          touches, with its kind, checked against two rules (nothing we touch may be read by
--          the secure click path; `replace` only for the nine enumerated bag toggles). Plus a
--          SOURCE scan of every `_G.<Name> =` in the shipping tree cross-checked against a
--          committed roster, so a new stock-surface write cannot arrive quietly — that is the
--          part that survives a future refactor the model cannot foresee.
--
-- WHAT IT STILL CANNOT PROVE: that a taint-clean ledger means a taint-clean client. Widget
-- taint (SetParent/SetScript on a Blizzard frame, addon-created frames handed to secure code)
-- is not modelled here and is not modellable headless; ui_bank's BankFrame reparent is
-- deliberately still in the ledger as a securehook-driven touch, and the only honest claim
-- about it is that we no longer write a field of ours onto that frame.
----------------------------------------------------------------------
realprint("")
realprint("=== taint / stock-surface gate :: ContainerFrame_Shared.lua:1341 ===")
local taintFails = 0
local function tck(cond, msg)
    if cond then realprint("  [ok] " .. msg)
    else taintFails = taintFails + 1; realprint("  [FAIL] " .. msg) end
end

-- Every global a shipping self-test rig is known to swap, plus the saved-variable tables.
-- The first two are the ones ContainerFrame_Shared.lua:1341 reads.
local WATCHED = {
    "C_Container", "BankFrame",
    "GetTime", "CreateFrame", "InCombatLockdown", "ClearCursor", "CursorHasItem",
    "C_Item", "C_Timer", "bit", "Enum", "GetMoney", "GetInventoryItemID",
    "GetInventoryItemLink", "geterrorhandler", "hooksecurefunc",
    "OpenCoinPickupFrame", "CloseBankFrame", "UIParent", "DaseekiUI",
    "DaseekiBags2DB", "DaseekiBags2Data", "DaseekiBagsAccount", "DaseekiBagsSets",
    "DaseekiBagsMesh", "DaseekiNexusData", "DaseekiNexusDB",
}

------------------------------------------------------------------ LEG 1: the refusal
do
    local before = {}
    for _, n in ipairs(WATCHED) do before[n] = _G[n] end

    -- Tolerate a build that has no gate at all, rather than erroring out: pointing this
    -- harness at the 2.0.8 tree (`lua5.1 harness/run-selftests.lua <old-dir>`) is how the
    -- red baseline is demonstrated, and a crash there proves nothing readable.
    -- `ok and v or nil` would fold the CORRECT answer (false) into "no answer" — the exact
    -- truthy-fallback trap CLIENT_ASYNC_LESSONS class 5 names. Branch explicitly.
    local owns = function()
        if type(ns.HarnessOwnsGlobals) ~= "function" then return "no-predicate" end
        local ok, v = pcall(function() return ns:HarnessOwnsGlobals() end)
        if not ok then return "errored" end
        return v
    end
    tck(type(ns.HarnessOwnsGlobals) == "function",
        "the addon publishes an ownership predicate (ns:HarnessOwnsGlobals)")

    -- WHY A TRAP AND NOT A BEFORE/AFTER COMPARE. The rigs SWAP AND RESTORE, so a compare only
    -- catches what they forgot to put back (real — store.lua's rig leaves the saved variables
    -- re-inited — but not the taint). In the client the taint is made by the WRITE and
    -- survives the restore, because the restore is another write by the same tainted code.
    -- So catch the write itself: Lua 5.1 fires __newindex only for keys the table does not
    -- have, and every global that matters here — C_Container and BankFrame included — is
    -- ABSENT headless. That absence is what makes the trap possible at all.
    local WATCHED_SET = {}
    for _, n in ipairs(WATCHED) do WATCHED_SET[n] = true end
    local trappableN = 0
    local trappable = {}
    for _, n in ipairs(WATCHED) do
        if rawget(_G, n) == nil then trappable[n] = true; trappableN = trappableN + 1 end
    end
    tck(trappable.C_Container and trappable.BankFrame and true or false,
        "the two globals line 1341 reads are absent headless, so a write to either is " ..
        "trappable (" .. trappableN .. " of " .. #WATCHED .. " watched globals are)")

    local writes, writeOrder = {}, {}
    local savedMT = getmetatable(_G)
    setmetatable(_G, { __newindex = function(t, k, v)
        if WATCHED_SET[k] and not writes[k] then
            writes[k] = true
            writeOrder[#writeOrder + 1] = k
        end
        rawset(t, k, v)
    end })

    _G.__DaseekiBagsHarness = nil          -- from here on we are, as far as the addon knows, a client
    tck(owns() == false, "with the beacon gone the addon knows it is in a client")

    -- Count what actually RAN. A refusal that still ran one suite is not a refusal, and the
    -- return value alone cannot tell those two apart.
    local said, savedPrint = {}, ns.Print
    ns.Print = function(_, ...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        said[#said + 1] = table.concat(parts, "\t")
    end
    local ranOk, verdict = pcall(function() return ns:RunRegisteredSelfTests(true) end)
    ns.Print = savedPrint
    setmetatable(_G, savedMT)

    tck(ranOk, "the refusal path does not error")
    tck(verdict == false, "ns:RunRegisteredSelfTests REFUSES in a client (returned " ..
                          tostring(verdict) .. ")")

    local suiteLines = 0
    for _, s in ipairs(said) do if s:match("^selftest: ") then suiteLines = suiteLines + 1 end end
    tck(suiteLines == 0, "…and not one suite started (the verbose run printed " ..
                         suiteLines .. " suite banner(s))")
    tck(#said == 1 and said[1] == (ns.SELFTEST_REFUSAL or ""),
        "…the one thing it said was the refusal, in plain language")

    table.sort(writeOrder)
    tck(#writeOrder == 0, "…and not one watched global was WRITTEN — trapped at the write, " ..
        "not inferred from a before/after compare" ..
        (#writeOrder > 0 and (" — WROTE: " .. table.concat(writeOrder, ", ")) or ""))
    if #writeOrder > 0 then
        realprint("         Restoring them afterwards does not take the taint back off.")
    end

    local changed = {}
    for _, n in ipairs(WATCHED) do
        if _G[n] ~= before[n] then changed[#changed + 1] = n end
    end
    table.sort(changed)
    tck(#changed == 0, "…and nothing was left swapped either (identity compare)" ..
        (#changed > 0 and (" — LEFT CHANGED: " .. table.concat(changed, ", ")) or ""))
    if #changed > 0 then
        realprint("         Those are values ContainerFrame_Shared.lua and the rest of")
        realprint("         FrameXML read. A global this addon writes is a global this")
        realprint("         addon taints, and C_Container/BankFrame are read one token")
        realprint("         away from the protected UseContainerItem call on line 1341.")
        for _, n in ipairs(changed) do _G[n] = before[n] end
    end

    -- Leg 2 grades its model on what leg 1 actually caught: trapped writes first, leftovers
    -- second. Nothing here is a guess about what the addon does — it is what it did.
    local observed = {}
    for _, n in ipairs(writeOrder) do observed[#observed + 1] = n end
    for _, n in ipairs(changed) do if not writes[n] then observed[#observed + 1] = n end end
    _G.__DaseekiBagsHarnessChanged = observed

    -- The published simulator hook has a caller the registry gate never sees, so it carries
    -- its own belt. Same question, asked of the rig directly.
    if ns.Sort and ns.Sort._Simulator then
        local okc, S = pcall(ns.Sort._Simulator, { bags = { { cid = 0, size = 4 } }, seed = 1 })
        if okc and type(S) == "table" and S.install then
            local bf, cc = _G.BankFrame, _G.C_Container
            local oki, res = pcall(function() return S:install() end)
            tck(oki and res == false, "sort.lua's published simulator refuses to install in a client")
            tck(_G.BankFrame == bf and _G.C_Container == cc,
                "…and leaves BankFrame and C_Container exactly as the client set them")
            if _G.BankFrame ~= bf or _G.C_Container ~= cc then
                _G.BankFrame, _G.C_Container = bf, cc
            end
        else
            realprint("  [note] sort simulator could not be constructed for the belt check")
        end
    end

    _G.__DaseekiBagsHarness = true          -- back to being the harness
    tck(owns() == true, "the beacon restores headless ownership")
end

------------------------------------------------------------------ LEG 2: the taint model
do
    -- A taint model with exactly two rules, both quoted from the wiki's taint page:
    --   "When code sets global values, the resulting value has the taint of the execution path"
    --   "When code accesses tainted values ... the execution path is also tainted"
    -- so: a global this addon wrote is tainted, and secure code that reads one is tainted.
    local function newWorld(taintedNames)
        local W = { tainted = {}, exec = nil }
        for _, n in ipairs(taintedNames) do W.tainted[n] = "Daseeki-Bags" end
        function W:read(name)
            if self.tainted[name] then self.exec = self.tainted[name] end
            return _G[name]
        end
        -- ContainerFrame_Shared.lua:1341, transcribed. `self`/parent are widgets, not
        -- globals, and are deliberately NOT modelled as taint carriers: every bag addon in
        -- the ecosystem creates its cells from this template and is not blocked for it, so
        -- widget identity is demonstrably not what the client is objecting to here.
        function W:rightClickUse()
            self.exec = nil
            local CC = self:read("C_Container")
            local BF = self:read("BankFrame")
            local atBankTab = BF and BF.IsShown and BF:IsShown() and (BF.selectedTab == 2)
            if self.exec then
                return false, self.exec        -- ADDON_ACTION_BLOCKED, attributed to exec
            end
            return true, CC, atBankTab
        end
        return W
    end

    -- (a) The model reproduces the SHIPPED defect. This is the fact 2.0.8 taught us, kept
    --     as an assertion rather than as prose: write those two globals and the right-click
    --     is dead, with our name on it.
    local shipped = newWorld({ "C_Container", "BankFrame" })
    local okUse, who = shipped:rightClickUse()
    tck(okUse == false and who == "Daseeki-Bags",
        "MODEL: writing C_Container/BankFrame blocks the right-click-to-use path and the " ..
        "client blames Daseeki-Bags (this is 2.0.8's live defect, reproduced)")

    -- (b) Each of the two, alone, is enough. Neither is a "both or nothing" condition.
    tck(select(1, newWorld({ "BankFrame" }):rightClickUse()) == false,
        "MODEL: BankFrame alone is enough (line 1341 reads BankFrame:IsShown() and .selectedTab)")
    tck(select(1, newWorld({ "C_Container" }):rightClickUse()) == false,
        "MODEL: C_Container alone is enough (line 1341 resolves UseContainerItem through it)")

    -- (c) A global we do NOT touch does not block — the model is not simply always-red.
    tck(select(1, newWorld({ "GetTime" }):rightClickUse()) == true,
        "MODEL: a global line 1341 does not read does not block it (the model discriminates)")

    -- (d) THE LIVE ANSWER: feed the model exactly what leg 1 observed the addon do while it
    --     believed it was in a client. Empty set -> nothing tainted -> nothing blocked.
    local observed = _G.__DaseekiBagsHarnessChanged or {}
    local nowWorld = newWorld(observed)
    local okNow, whoNow = nowWorld:rightClickUse()
    tck(okNow == true,
        "LIVE: after the fix the addon writes no global in a client, so the modelled " ..
        "right-click-to-use is NOT blocked" ..
        (okNow and "" or (" — blocked by " .. tostring(whoNow) ..
                          "; observed writes: " .. table.concat(observed, ", "))))
    _G.__DaseekiBagsHarnessChanged = nil
end

------------------------------------------------------------------ LEG 3: the ledger + source
do
    local SS = ns.StockSurface
    tck(type(SS) == "table" and type(SS.Record) == "function",
        "the stock-surface ledger exists (ns.StockSurface)")
    -- Stand-in so an older tree reports every rule as failed instead of erroring out.
    if type(SS) ~= "table" or type(SS.Record) ~= "function" then
        SS = { entries = {}, byName = {}, REPLACE_ALLOWED = {},
               Record = function() end,
               Violations = function() return { "ns.StockSurface is missing entirely" } end }
    end
    local SECURE_READS = ns.SECURE_CLICK_READS or {}

    -- Drive the four real installers under a minimal client so the ledger is populated by
    -- the shipping code paths, not by the gate. Everything is restored afterwards.
    -- NIL IS A VALUE HERE. Most of what we stub does not exist headless, so `savedG[n] = nil`
    -- would vanish from pairs() and the stub would outlive the gate. Order + explicit table.
    local savedOrder, savedG = {}, {}
    local function remember(n)
        if savedG[n] == nil then savedOrder[#savedOrder + 1] = n; savedG[n] = { _G[n] } end
    end
    local function stub(n, v) remember(n); _G[n] = v end
    local hooked = {}
    stub("hooksecurefunc", function(name) hooked[name] = (hooked[name] or 0) + 1 end)
    stub("CreateFrame", function()
        local f = {}
        setmetatable(f, { __index = function() return function() end end })
        return f
    end)
    stub("DaseekiUI", { })
    stub("UIParent", {})
    stub("SetItemButtonTexture", function() end)
    stub("SetItemButtonQuality", function() end)
    stub("HandleModifiedItemClick", function() end)
    stub("SetItemRef", function() end)
    for _, n in ipairs({ "ToggleBackpack", "ToggleAllBags", "ToggleBag", "OpenAllBags",
                         "OpenBackpack", "OpenBag", "CloseAllBags", "CloseBackpack",
                         "CloseBag" }) do
        stub(n, function() end)
    end

    if ns.Frame then ns.Frame._hooked = false; pcall(ns.Frame.HookBagToggles) end
    if ns.Bank then
        ns.Bank._overrideInstalled = false; pcall(ns.Bank.InstallOverride)
    end
    if ns.Items and ns.Items._installArtHooks then
        ns.Items._artHooksInstalled = false; pcall(ns.Items._installArtHooks)
    end
    if ns.Features and ns.Features.HookAltClick then
        ns.Features._altHooked = false; pcall(ns.Features.HookAltClick)
    end
    -- The BINDING_* block: declared behind `if _G.SlashCmdList` at load, so the harness has
    -- never run it. Drive it here (and put the strings back) so the ledger's `binding`
    -- entries are recorded by the shipping path rather than asserted from prose.
    if ns.DeclareBindingGlobals then
        local bindingNames = { "BINDING_HEADER_DASEEKIBAGS2", "BINDING_CATEGORY_DASEEKIBAGS2",
            "BINDING_NAME_DASEEKIBAGS2_TOGGLE", "BINDING_NAME_DASEEKIBAGS2_BANK_TOGGLE",
            "BINDING_NAME_DASEEKIBAGS2_FIND", "BINDING_NAME_DASEEKIBAGS_TOGGLE",
            "BINDING_NAME_DASEEKIBAGS_BANK_TOGGLE", "DaseekiBags2_ToggleBags",
            "DaseekiBags2_ToggleBank", "DaseekiBags2_ToggleFind" }
        for _, n in ipairs(bindingNames) do remember(n) end
        pcall(ns.DeclareBindingGlobals)
    end
    -- The slash registry entry, same reasoning (guarded on _G.SlashCmdList at load).
    if not ns.StockSurface.byName.SlashCmdList then
        stub("SlashCmdList", {})
        for i, cmdText in ipairs(ns.SLASH_COMMANDS or {}) do
            remember("SLASH_DASEEKIBAGS" .. i)
            _G["SLASH_DASEEKIBAGS" .. i] = cmdText
        end
        _G.SlashCmdList["DASEEKIBAGS"] = function() end
        ns.StockSurface.Record("SlashCmdList", "registry",
            "one entry added under our own key (DASEEKIBAGS) — the sanctioned slash mechanism")
    end
    -- The StaticPopup registry entry: written lazily the first time the owner deletes a
    -- cached character, so it has to be driven rather than waited for.
    if ns.Owner and ns.Owner._ConfirmRemoveOwner then
        stub("StaticPopupDialogs", {})
        stub("StaticPopup_Show", function() end)
        pcall(ns.Owner._ConfirmRemoveOwner, "Someone-Realm", "Someone", nil)
    end

    for i = #savedOrder, 1, -1 do
        local n = savedOrder[i]
        _G[n] = savedG[n][1]
    end

    local kinds = {}
    for _, e in ipairs(SS.entries) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
    realprint(string.format("  ledger: %d entr(ies) — %d securehook, %d replace, %d binding, %d registry",
        #SS.entries, kinds.securehook or 0, kinds.replace or 0, kinds.binding or 0,
        kinds.registry or 0))

    local bad = SS.Violations()
    tck(#bad == 0, "ledger walk is clean")
    for _, v in ipairs(bad) do realprint("         VIOLATION: " .. v) end

    -- The two rules, asserted directly as well, so a Violations() that stopped checking
    -- would not read as clean.
    local touchedSecureRead, replacedOutsideRoster = {}, {}
    for _, e in ipairs(SS.entries) do
        if SECURE_READS[e.name] then touchedSecureRead[#touchedSecureRead + 1] = e.name end
        if e.kind == "replace" and not SS.REPLACE_ALLOWED[e.name] then
            replacedOutsideRoster[#replacedOutsideRoster + 1] = e.name
        end
    end
    tck(#touchedSecureRead == 0,
        "nothing in the ledger is a global the secure container click path reads" ..
        (#touchedSecureRead > 0 and (" — " .. table.concat(touchedSecureRead, ", ")) or ""))
    tck(#replacedOutsideRoster == 0,
        "every outright takeover is one of the nine bag-toggle globals" ..
        (#replacedOutsideRoster > 0 and (" — " .. table.concat(replacedOutsideRoster, ", ")) or ""))
    tck(SECURE_READS.C_Container and SECURE_READS.BankFrame and true or false,
        "the read set names C_Container and BankFrame (the two on line 1341)")

    -- Every securehook the installers claimed really went in through hooksecurefunc, and
    -- the nine takeovers really replaced their globals. A ledger that is merely a list of
    -- good intentions is not a gate.
    local hookedNames = 0
    for _, e in ipairs(SS.entries) do
        if e.kind == "securehook" then
            hookedNames = hookedNames + 1
            if (hooked[e.name] or 0) < 1 then
                taintFails = taintFails + 1
                realprint("  [FAIL] ledger claims a securehook on " .. e.name ..
                          " but hooksecurefunc was never called with that name")
            end
        end
    end
    tck(hookedNames >= 6, "…and all " .. hookedNames .. " securehook entries really went " ..
        "through hooksecurefunc")

    ------------------------------------------------------------ SOURCE SCAN
    -- Every `_G.<Name> = ` in the shipping tree, classified. RUNTIME names are the ones the
    -- addon writes in a live client (they must be ledger-legal); RIG names are the ones only
    -- a self-test simulator writes (legal only under the ownership beacon, which is exactly
    -- what leg 1 pins). A name in neither list fails the gate until someone classifies it.
    local RUNTIME_WRITES = {
        -- the nine bag toggles (ledger kind `replace`)
        ToggleBackpack = true, ToggleAllBags = true, ToggleBag = true, OpenAllBags = true,
        OpenBackpack = true, OpenBag = true, CloseAllBags = true, CloseBackpack = true,
        CloseBag = true,
        -- keybinding display strings (ledger kind `binding`)
        BINDING_HEADER_DASEEKIBAGS2 = true, BINDING_CATEGORY_DASEEKIBAGS2 = true,
        BINDING_NAME_DASEEKIBAGS2_TOGGLE = true, BINDING_NAME_DASEEKIBAGS2_BANK_TOGGLE = true,
        BINDING_NAME_DASEEKIBAGS2_FIND = true, BINDING_NAME_DASEEKIBAGS_TOGGLE = true,
        BINDING_NAME_DASEEKIBAGS_BANK_TOGGLE = true,
        -- Blizzard registry tables we add one entry to, under our own key (ledger `registry`)
        SlashCmdList = true, StaticPopupDialogs = true,
        -- our own namespace: saved variables and the binding handler globals
        DaseekiBags2DB = true, DaseekiBags2Data = true,
        DaseekiBags2_ToggleBags = true, DaseekiBags2_ToggleBank = true,
        DaseekiBags2_ToggleFind = true,
    }
    -- Only a self-test rig may write these, and only under the ownership beacon — which is
    -- the property leg 1 pins. Every name here is a real game global (or a saved-variable
    -- table) that a simulator swaps for a fake and puts back.
    local RIG_WRITES = {
        C_Container = true, C_Timer = true, C_Item = true, CreateFrame = true, GetTime = true,
        GetMoney = true, GetInventoryItemID = true, GetInventoryItemLink = true,
        InCombatLockdown = true, CursorHasItem = true, ClearCursor = true, bit = true,
        BankFrame = true, Enum = true, geterrorhandler = true, hooksecurefunc = true,
        OpenCoinPickupFrame = true, CloseBankFrame = true,
        UnitName = true, UnitSex = true, UnitLevel = true, UnitFactionGroup = true,
        GetRealmName = true, CooldownFrame_Set = true, TEXTURE_ITEM_QUEST_BANG = true,
        DaseekiUI = true, UIParent = true, GameTooltip = true, GetScreenWidth = true,
        CursorUpdate = true, C_NewItems = true, BankButtonIDToInvSlotID = true,
        ContainerIDToInventoryID = true, IsAddOnLoaded = true, IsKeyRingEnabled = true,
        DaseekiBagsSets = true, DaseekiBagsAccount = true, DaseekiBagsMesh = true,
        DaseekiNexusData = true, DaseekiNexusDB = true,
    }
    local unclassified, seenRuntime = {}, {}
    for _, rel in ipairs(TOC_ORDER) do
        local src = readFile(P(rel)) or ""
        -- Lua 5.1: gmatch("[^\r\n]*") yields an empty match after every line, which doubles
        -- the count and makes every reported line number wrong. Split explicitly.
        local lines, lineNo = {}, 0
        for chunk in (src .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = chunk end
        for _, line in ipairs(lines) do
            lineNo = lineNo + 1
            -- `function _G.Name(` is a write too.
            for name in line:gmatch("function%s+_G%.([%w_]+)") do
                if not (RUNTIME_WRITES[name] or RIG_WRITES[name]) then
                    unclassified[#unclassified + 1] = rel .. ":" .. lineNo .. " " .. name
                end
                if RUNTIME_WRITES[name] then seenRuntime[name] = true end
            end
            -- assignment: take the text left of the first assignment `=`
            local eq = line:find("[^=~<>]=[^=]")
            if eq then
                local lhs = line:sub(1, eq)
                if not lhs:find("^%s*%-%-") then
                    -- `_G.Name(` is a CALL and can never be an assignment target; the `=`
                    -- that made this line look like an assignment is inside its arguments.
                    -- `_G.Name[` IS a target (StaticPopupDialogs[k] = ...), so only "(" goes.
                    for name, nextch in lhs:gmatch("_G%.([%w_]+)(.?)") do
                      if nextch ~= "(" then
                        if not (RUNTIME_WRITES[name] or RIG_WRITES[name]) then
                            unclassified[#unclassified + 1] = rel .. ":" .. lineNo .. " " .. name
                        end
                        if RUNTIME_WRITES[name] then seenRuntime[name] = true end
                      end
                    end
                end
            end
        end
    end
    tck(#unclassified == 0,
        "every `_G.<Name> =` in the shipping tree is classified runtime-or-rig")
    for i = 1, math.min(#unclassified, 12) do
        realprint("         unclassified global write: " .. unclassified[i])
    end
    if #unclassified > 0 then
        realprint("         Add it to RUNTIME_WRITES (and to ns.StockSurface, with a kind)")
        realprint("         or to RIG_WRITES (and make sure the rig is beacon-gated).")
    end

    -- Every RUNTIME name must be one the ledger knows about, or one of ours.
    local unledgered = {}
    for name in pairs(seenRuntime) do
        if not name:match("^Daseeki") and not SS.byName[name] then
            unledgered[#unledgered + 1] = name
        end
    end
    table.sort(unledgered)
    tck(#unledgered == 0, "every Blizzard-owned runtime write is declared in the ledger" ..
        (#unledgered > 0 and (" — missing: " .. table.concat(unledgered, ", ")) or ""))
end

local taintPass = (taintFails == 0)
realprint(string.format("=== taint / stock-surface gate: %s (%d failure(s)) ===",
    taintPass and "PASS" or "FAIL", taintFails))

local overall = pass and rosterPass and timerPass and taintPass
realprint("")
realprint("############################################################")
realprint("# toc parse gate (compiles)   : PASS (else we exited 1 above)")
realprint("# expected-suite roster       : " .. (rosterPass and "PASS" or "FAIL"))
realprint("# queue-and-pump timer gate   : " .. (timerPass and "PASS" or "FAIL"))
realprint("# registered self-test suites : " .. (pass and "PASS" or "FAIL"))
realprint("# taint / stock-surface gate  : " .. (taintPass and "PASS" or "FAIL") ..
          string.format("  (%d failure(s))", taintFails))
realprint("# Daseeki-Bags 2.0 self-tests : " .. (overall and "ALL PASS" or "RED (see above)"))
realprint("############################################################")
os.exit(overall and 0 or 1)
