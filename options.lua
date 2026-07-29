-- Daseeki Bags 2.0 — options.lua
-- The DaseekiUI settings page: a single clean, scannable flow page registered with
-- the Daseeki hub exactly like every other suite addon (Daseeki-Nexus is the model —
-- DaseekiSuite:RegisterAddon{ flow = true }). Style-guide compliant: every group has
-- a header + a one-line description, controls hug their natural width, no dead gaps.
--
-- Sections (consolidated per DREW_UI_STYLE rule 9 — one page, in-pane headers):
--   Layout & Display  — Combined/Split layout, money bar, quality borders, keyring
--   Grid              — columns, button size, cell gap (all live re-grid)
--   Sorting           — the sort action + a note on what it does / how to trigger it
--
-- Every control's get/set closure reads and writes DaseekiBags2DB directly, then
-- live-applies through the already-merged Frame API (SetLayout / Rebuild) — no reload.
--
-- ── Degradation (OptionalDeps: Daseeki-Core) ──────────────────────────────────
-- If Daseeki-Core / DaseekiUI is absent the page cannot be built, so Register is a
-- clean no-op. Crucially, the ADDITIVE store default this wave owns —
-- `DaseekiBags2DB.qualityBorders = true` (the W2 borders.lua flag: "the one-line
-- store default to add") — is applied in a Core-INDEPENDENT hook on STORE_READY, so
-- borders behave identically with or without the options page present.

local ADDON, ns = ...

local Options = {}
ns.Options = Options

local Store = ns.Store

----------------------------------------------------------------------
-- Additive store default (owned by W4; Core-independent)
--
-- borders.lua already treats an ABSENT key as ON, so this is purely additive: it
-- gives the setting a persisted home so the Quality Borders checkbox has a value to
-- toggle. Never clobbers an existing choice.
----------------------------------------------------------------------

function Options.ApplyDefaults(db)
    if type(db) ~= "table" then return end
    if db.qualityBorders == nil then db.qualityBorders = true end
    return db
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function DB() return Store and Store.db or nil end

-- Live-apply a grid/display change: rebuild the window if it exists (guarded — the
-- Frame no-ops headless / before login). Persisted either way for the next open.
local function regrid()
    if ns.Frame and ns.Frame.Rebuild then
        if ns.SafeCall then ns:SafeCall(ns.Frame.Rebuild) else ns.Frame.Rebuild() end
    end
end

-- Per-page control refreshers (re-sync checkbox/segment/slider state when shown).
local refreshers = {}
local function register(fn) refreshers[#refreshers + 1] = fn end
local function refreshAll()
    for i = 1, #refreshers do
        if ns.SafeCall then ns:SafeCall(refreshers[i]) else refreshers[i]() end
    end
end
Options._refresh = refreshAll

----------------------------------------------------------------------
-- Page builder (called once when the section is first shown)
----------------------------------------------------------------------

function Options.Build(flow)
    local intFmt = function(v) return tostring(math.floor(v + 0.5)) end

    -- ── Layout & Display ──────────────────────────────────────────────────────
    local disp = flow:AddSection("Layout & Display")
    disp:Hint("How the bag window is arranged and what it shows.")

    -- Combined vs split-bag-groups (design D3: both are first-class). Drives the
    -- live layout switch — same setter the toolbar segmented control uses.
    local layoutRow = disp:AddRow({ vAlign = "center" })
    layoutRow:Label("Layout");
    register(layoutRow:SegmentedChoice({
        compact = true,
        choices = { { value = "combined", text = "Combined" }, { value = "split", text = "Split" } },
        get = function() return (DB() and DB().layout) or "combined" end,
        set = function(v) if ns.Frame and ns.Frame.SetLayout then ns.Frame.SetLayout(v) end end,
    }).Refresh)
    disp:Hint("Combined flows every bag into one grid; Split shows one titled group per bag.")

    register(disp:Checkbox({
        label = "Show money bar",
        tooltip = "Show this character's gold, with cross-account totals on hover.",
        get = function() local db = DB(); return db and db.showMoney ~= false end,
        set = function(v) local db = DB(); if db then db.showMoney = v and true or false end regrid() end,
    }).Refresh)

    register(disp:Checkbox({
        label = "Quality borders",
        tooltip = "Color item slots by quality (uncommon and above).",
        get = function() local db = DB(); return db == nil or db.qualityBorders ~= false end,
        set = function(v) local db = DB(); if db then db.qualityBorders = v and true or false end regrid() end,
    }).Refresh)

    register(disp:Checkbox({
        label = "Show keyring",
        tooltip = "Include the keyring as a container in the bag window.",
        get = function() local db = DB(); return db == nil or db.showKeyring ~= false end,
        set = function(v) local db = DB(); if db then db.showKeyring = v and true or false end regrid() end,
    }).Refresh)

    -- ── Grid ──────────────────────────────────────────────────────────────────
    local grid = flow:AddSection("Grid")
    grid:Hint("Slot size and spacing. Changes re-grid the open window instantly.")

    register(grid:Slider({
        label = "Columns", min = 6, max = 20, step = 1, width = 260, format = intFmt,
        get = function() local db = DB(); return (db and db.columns) or 12 end,
        set = function(v) local db = DB(); if db then db.columns = math.floor(v + 0.5) end regrid() end,
    }).Refresh)

    register(grid:Slider({
        label = "Button size", min = 28, max = 48, step = 1, width = 260, format = intFmt,
        get = function() local db = DB(); return (db and db.buttonSize) or 37 end,
        set = function(v) local db = DB(); if db then db.buttonSize = math.floor(v + 0.5) end regrid() end,
    }).Refresh)

    register(grid:Slider({
        label = "Cell gap", min = 0, max = 10, step = 1, width = 260, format = intFmt,
        get = function() local db = DB(); return (db and db.gap) or 4 end,
        set = function(v) local db = DB(); if db then db.gap = math.floor(v + 0.5) end regrid() end,
    }).Refresh)

    -- ── Sorting ───────────────────────────────────────────────────────────────
    local sorting = flow:AddSection("Sorting")
    sorting:Hint("Groups items by type, then name; merges partial stacks; leaves locked slots in place.")

    local sortRow = sorting:AddRow({ vAlign = "center" })
    sortRow:Button({
        text = "Sort Bags Now", width = 150,
        onClick = function()
            if ns.Sort and ns.Sort.Run then ns.Sort.Run(ns.Sort.CarriedBagIDs()) end
        end,
    })
    sorting:Hint("Or click the Sort button in the bag window's toolbar. Bank sorting arrives with the bank view.")

    -- ── Auto-open ───────────────────────────────────────────────────────────────
    -- Open the bags automatically at these interactions and close them after —
    -- the ns.Features auto-display set (audit §1.5). All default ON, matching 1.x.
    -- Reads/writes DaseekiBags2DB.autoDisplay.* (defaults applied by Features on
    -- STORE_READY); a missing/true sub-key = enabled, only explicit false disables.
    local auto = flow:AddSection("Auto-open")
    auto:Hint("Show the bags automatically at the merchant, bank and mailbox — and hide them again after.")

    local function adGet(key)
        local db = DB(); local ad = db and db.autoDisplay
        return not ad or ad[key] ~= false
    end
    local function adSet(key, v)
        local db = DB(); if not db then return end
        if type(db.autoDisplay) ~= "table" then db.autoDisplay = {} end
        db.autoDisplay[key] = v and true or false
    end

    register(auto:Checkbox({
        label = "At the merchant", tooltip = "Open the bags when you talk to a vendor.",
        get = function() return adGet("merchant") end, set = function(v) adSet("merchant", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "At the bank", tooltip = "Open the bags when you open the bank.",
        get = function() return adGet("bank") end, set = function(v) adSet("bank", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "At the mailbox", tooltip = "Open the bags when you open the mail.",
        get = function() return adGet("mail") end, set = function(v) adSet("mail", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "Close when combat starts", tooltip = "Hide the bags when you enter combat.",
        get = function() return adGet("combatClose") end, set = function(v) adSet("combatClose", v) end,
    }).Refresh)
end

----------------------------------------------------------------------
-- Registration with the Daseeki hub (flow = true) — Core-gated
----------------------------------------------------------------------

Options._built = false

function Options.Register()
    if not _G.DaseekiSuite then return end
    if not (_G.DaseekiUI and _G.DaseekiUI.Token) then
        print("|cffc9a24dDaseeki Bags|r requires Daseeki Core — please update Daseeki Core.")
        return
    end
    _G.DaseekiSuite:RegisterAddon({
        id    = "bags",
        title = "Bags",
        icon  = "Interface\\Icons\\INV_Misc_Bag_08",
        order = 45,
        flow  = true,
        sections = {
            {
                id = "settings", title = "Settings",
                build = function(flow)
                    if Options._built then return end
                    Options._built = true
                    if ns.SafeCall then ns:SafeCall(Options.Build, flow) else Options.Build(flow) end
                end,
                refresh = function() refreshAll() end,
            },
        },
    })
end

-- Apply the additive default the moment the store is ready (Core-independent), then
-- register the options page (Core-gated inside Register).
if ns.On then
    ns:On("STORE_READY", function()
        Options.ApplyDefaults(Store and Store.db)
        if ns.SafeCall then ns:SafeCall(Options.Register) else Options.Register() end
    end)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "options")
----------------------------------------------------------------------

local function testDefaultsAdditive(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- fresh db gets the border default set to ON
    local db = {}
    Options.ApplyDefaults(db)
    ck(db.qualityBorders == true, "qualityBorders default filled to true")
    -- an existing explicit choice is NEVER clobbered (additive contract)
    local off = { qualityBorders = false }
    Options.ApplyDefaults(off)
    ck(off.qualityBorders == false, "existing qualityBorders=false preserved")
    local on = { qualityBorders = true }
    Options.ApplyDefaults(on)
    ck(on.qualityBorders == true, "existing qualityBorders=true preserved")
    -- unrelated keys untouched
    local mixed = { layout = "split", columns = 9 }
    Options.ApplyDefaults(mixed)
    ck(mixed.layout == "split" and mixed.columns == 9, "unrelated keys untouched")
    ck(mixed.qualityBorders == true, "border default added alongside existing keys")
    -- non-table guard
    Options.ApplyDefaults(nil)
    ck(true, "nil db is a safe no-op")
end

function Options.RunSelfTests(verbose)
    local suites = {
        { name = "defaults additive", fn = testDefaultsAdditive },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS options/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL options/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("options", Options.RunSelfTests)
end

return Options
