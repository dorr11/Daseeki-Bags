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
-- WINDOW-SCALE WRITE PATH (marker discipline)
--
-- Named and db-injected rather than inlined in the slider's set closure, because the
-- headless harness cannot build a DaseekiUI panel and this is the ONE thing about the
-- slider that has to be gated: a deliberate scale must claim db.scaleUserChose, or the
-- next default bump's match-by-value heal (Frame.MigrateScale) cannot tell a shipped
-- default apart from an owner setting that happens to equal it. Same discipline the
-- Columns / Cell-gap sliders use for db.densityUserChose.
--
-- Frame.WriteScale owns the clamp + marker; the fallback branch exists only for the
-- can't-happen case of options.lua loaded without ui_frame, and records the same intent.
-- PURE: no frames, no live-apply — the caller does the RefreshScale.
----------------------------------------------------------------------

function Options.WriteWindowScale(db, v)
    if ns.Frame and ns.Frame.WriteScale then return ns.Frame.WriteScale(db, v) end
    local s = tonumber(v) or 0.92
    if type(db) == "table" then
        db.scale = s
        db.scaleUserChose = true
    end
    return s
end

----------------------------------------------------------------------
-- Page builder (called once when the section is first shown)
----------------------------------------------------------------------

function Options.Build(flow)
    local intFmt = function(v) return tostring(math.floor(v + 0.5)) end

    -- ── Layout & Display ──────────────────────────────────────────────────────
    local disp = flow:AddSection("Layout & Display")
    disp:Hint("How the bag window is arranged and what it shows.")

    -- Combined vs split-bag-groups (design D3: both are first-class). Drives the
    -- live layout switch (also reachable by right-clicking the window title bar).
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

    -- Same-faction-only Money tooltip filter (audit §4.4). Additive; default OFF (shows every
    -- character's gold, the current 2.0 behavior). Only changes the hover tooltip, not the bar.
    register(disp:Checkbox({
        label = "Money tooltip: same faction only",
        tooltip = "On the gold hover, list only characters of your own faction (and their total).",
        get = function() local db = DB(); return db and db.moneyTooltipFaction == true end,
        set = function(v) local db = DB(); if db then db.moneyTooltipFaction = v and true or false end end,
    }).Refresh)

    register(disp:Checkbox({
        label = "Show keyring",
        tooltip = "Include the keyring as a container in the bag window.",
        get = function() local db = DB(); return db == nil or db.showKeyring ~= false end,
        set = function(v) local db = DB(); if db then db.showKeyring = v and true or false end regrid() end,
    }).Refresh)

    -- Frame lock (audit §9.8). Additive; default OFF (draggable). When on, the title-bar drag
    -- is suppressed so the window can't be moved by accident.
    register(disp:Checkbox({
        label = "Lock window position",
        tooltip = "Prevent dragging the bag window by its title bar.",
        get = function() local db = DB(); return db and db.frameLock == true end,
        set = function(v) local db = DB(); if db then db.frameLock = v and true or false end end,
    }).Refresh)

    -- ── Categories ──────────────────────────────────────────────────────────────
    -- The simplified custom-categories editor (BAGS2 GAP §6.4-6.5, D1-KEEP). A
    -- category is a saved SEARCH QUERY; the combined view groups items into labelled
    -- sections by first-match-wins. SPLIT layout is unaffected. All the reorder / add /
    -- delete / rename / enable LOGIC lives in the pure rules2 engine (unit-tested); this
    -- page is a thin DaseekiUI wiring over ns.Rules + a live "matches N" readout.
    if ns.Rules then Options.BuildCategories(flow) end

    -- ── Grid ──────────────────────────────────────────────────────────────────
    local grid = flow:AddSection("Grid")
    grid:Hint("Slot size and spacing. Changes re-grid the open window instantly.")

    -- Touching Columns or Cell gap marks the grid density as user-chosen, so the one-time
    -- 1.0-parity density migration (Frame.MigrateDensity) never re-defaults a value the
    -- owner deliberately set. Button size is NOT a migrated key, so it does not set the
    -- marker (a beta DB that only tweaked cell size still receives the tight 1.0 grid).
    register(grid:Slider({
        label = "Columns", min = 6, max = 20, step = 1, width = 260, format = intFmt,
        get = function() local db = DB(); return (db and db.columns) or (ns.Frame and ns.Frame.DEFAULT_COLUMNS) or 11 end,
        set = function(v) local db = DB(); if db then db.columns = math.floor(v + 0.5); db.densityUserChose = true end regrid() end,
    }).Refresh)

    register(grid:Slider({
        label = "Button size", min = 28, max = 48, step = 1, width = 260, format = intFmt,
        get = function() local db = DB(); return (db and db.buttonSize) or (ns.Frame and ns.Frame.DEFAULT_BUTTONSIZE) or 37 end,
        set = function(v) local db = DB(); if db then db.buttonSize = math.floor(v + 0.5) end regrid() end,
    }).Refresh)

    register(grid:Slider({
        label = "Cell gap", min = 0, max = 10, step = 1, width = 260, format = intFmt,
        get = function() local db = DB(); return (db and db.gap) or (ns.Frame and ns.Frame.DEFAULT_GAP) or 2 end,
        set = function(v) local db = DB(); if db then db.gap = math.floor(v + 0.5); db.densityUserChose = true end regrid() end,
    }).Refresh)

    -- Window scale. Separate from Button size on purpose: Button size changes the GRID
    -- (more or less of the screen for the same number of slots), while this shrinks the
    -- whole window — chrome, title, bag strip and all — the way 1.x's frame scale did.
    -- Default 0.92 is the owner's bumped value (2026-08-03, "bring the default scale of
    -- bags 2 up just a bit"), deliberately above the 1.0-size-parity 0.89 — see
    -- Frame.DEFAULT_SCALE. Applies to the bank window too; RefreshScale re-scales both and
    -- repaints so the pixel-snapped quality borders re-derive at the new effective scale.
    -- The write goes through Frame.WriteScale, which clamps AND claims db.scaleUserChose,
    -- so a future default bump can never heal away a scale the owner deliberately set
    -- (the same marker discipline the Columns / Cell-gap sliders use for density).
    register(grid:Slider({
        label = "Window scale",
        min   = (ns.Frame and ns.Frame.MIN_SCALE) or 0.5,
        max   = (ns.Frame and ns.Frame.MAX_SCALE) or 1.5,
        step  = 0.01, width = 260,
        format = function(v) return string.format("%d%%", math.floor((tonumber(v) or 1) * 100 + 0.5)) end,
        get = function()
            local db = DB()
            if ns.Frame and ns.Frame.ClampScale then return ns.Frame.ClampScale(db and db.scale) end
            return (db and db.scale) or 0.92
        end,
        set = function(v)
            Options.WriteWindowScale(DB(), v)
            if ns.Frame and ns.Frame.RefreshScale then
                if ns.SafeCall then ns:SafeCall(ns.Frame.RefreshScale) else ns.Frame.RefreshScale() end
            end
        end,
    }).Refresh)

    -- ── Item borders (1.0 / CII-style) ──────────────────────────────────────────
    -- Full-saturation quality borders with a configurable minimum quality (default
    -- Uncommon, matching 1.x's Uncommon+ floor). Unusable gear always shows a red border.
    local ib = flow:AddSection("Item borders")
    ib:Hint("Color item slots by quality (full-saturation, like 1.0 / ColoredInventoryItems).")
    register(ib:Checkbox({
        label = "Show quality borders",
        tooltip = "Draw a colored border on items at or above the minimum quality below.",
        get = function() local db = DB(); return db == nil or db.qualityBorders ~= false end,
        set = function(v) local db = DB(); if db then db.qualityBorders = v and true or false end regrid() end,
    }).Refresh)
    local minRow = ib:AddRow({ vAlign = "center" })
    minRow:Label("Minimum quality")
    register(minRow:SegmentedChoice({
        compact = true,
        choices = { { value = 2, text = "Uncommon" }, { value = 3, text = "Rare" }, { value = 4, text = "Epic" } },
        get = function() local db = DB(); return (db and db.qualityBorderMin) or (ns.Borders and ns.Borders.DEFAULT_MIN_QUALITY) or 2 end,
        set = function(v) local db = DB(); if db then db.qualityBorderMin = tonumber(v) or 2 end regrid() end,
    }).Refresh)
    ib:Hint("Unusable gear (your class can't equip it, or it's below its required level) always shows a red border.")

    -- Equipment-set teal (Daseeki-Armory bridge). DEFAULT OFF, deliberately — see the long
    -- note above slotIsSet in ui_items.lua: Bags 1 CANNOT draw this cue on Classic Era
    -- unless ItemRack is loaded (ItemSearch-1.3/API.lua:145-146 binds BelongsToSet to a
    -- no-op otherwise), so "off" is what Bags 1 renders. Left ON it repaints roughly a
    -- third of a geared character's bag teal, hiding those cells' rarity colours.
    register(ib:Checkbox({
        label = "Glow equipment-set items",
        tooltip = "Glow bag items that belong to a Daseeki-Armory equipment set in teal. OFF by default: the teal wins over the rarity colour, so on a geared character it can repaint a large part of the bag. Search with set:<name> (or bare set: for any set) works either way. Requires Daseeki-Armory.",
        get = function() local db = DB(); return db ~= nil and db.setMarkers == true end,
        set = function(v) local db = DB(); if db then db.setMarkers = v and true or false end regrid() end,
    }).Refresh)

    -- New-item glow sheet. DEFAULT ON, which is Bags 1's own shipped `glowNew`. This is
    -- Bags 1's indicator restored: the game's own per-quality "new loot" glow plus its
    -- flash, on its own layer — so it never takes a colour away from anything else.
    register(ib:Checkbox({
        label = "Glow newly-acquired items",
        tooltip = "Show the game's own 'new item' glow — the coloured burst and slow pulse Bags 1 used — on items you have picked up but not looked at yet. The cue clears as soon as you hover the item. It draws OVER the slot rather than recolouring it, so a new epic still shows its purple border.",
        get = function() return not (ns.Borders and ns.Borders.NewCueEnabled) or ns.Borders.NewCueEnabled() end,
        set = function(v) local db = DB(); if db then db.newItemMarkers = v and true or false end regrid() end,
    }).Refresh)

    -- ── Slot appearance (Bags 1 parity: slotBackground / slotAlpha / slotBorderColor) ──
    -- The owner's deliberate Bags 1 look: a quiet faction crest in each EMPTY cell at low
    -- opacity, and a dark, slightly-opaque 2px edge on EVERY cell. Defaults here are his
    -- live Bags 1 profile values, not Bags 1's shipped defaults.
    local slot = flow:AddSection("Slot appearance")
    slot:Hint("The empty-slot artwork and the quiet edge every slot carries — the darkened, easier-on-the-eyes look from Bags 1.")

    local bgRow = slot:AddRow({ vAlign = "center" })
    bgRow:Label("Empty slot art")
    register(bgRow:SegmentedChoice({
        compact = true,
        choices = (ns.Items and ns.Items.SLOT_BACKGROUND_CHOICES)
            or { { value = 1, text = "None" }, { value = 2, text = "Classic" } },
        get = function()
            local db = DB()
            if db and type(db.slotBackground) == "number" then return db.slotBackground end
            return (ns.Items and ns.Items.DEFAULT_SLOT_BACKGROUND) or 6
        end,
        set = function(v)
            local db = DB()
            if db then db.slotBackground = tonumber(v) or (ns.Items and ns.Items.DEFAULT_SLOT_BACKGROUND) or 6 end
            regrid()
        end,
    }).Refresh)

    register(slot:Slider({
        label = "Empty slot opacity", min = 0, max = 100, step = 1, width = 260,
        format = function(v) return string.format("%d%%", math.floor((tonumber(v) or 0) + 0.5)) end,
        get = function()
            local db = DB()
            local a = (db and type(db.slotAlpha) == "number") and db.slotAlpha
                or (ns.Items and ns.Items.DEFAULT_SLOT_ALPHA) or 0.29
            return a * 100
        end,
        set = function(v)
            local db = DB()
            if db then db.slotAlpha = math.max(0, math.min(1, (tonumber(v) or 0) / 100)) end
            regrid()
        end,
    }).Refresh)

    register(slot:Slider({
        label = "Slot edge opacity", min = 0, max = 100, step = 1, width = 260,
        format = function(v) return string.format("%d%%", math.floor((tonumber(v) or 0) + 0.5)) end,
        get = function()
            if not (ns.Items and ns.Items.SlotBorderColor) then return 0 end
            local _, _, _, a = ns.Items.SlotBorderColor()
            return (a or 0) * 100
        end,
        set = function(v)
            local db = DB()
            if db and ns.Items and ns.Items.SlotBorderColor then
                local r, g, b = ns.Items.SlotBorderColor()
                db.slotBorderColor = { r, g, b, math.max(0, math.min(1, (tonumber(v) or 0) / 100)) }
            end
            regrid()
        end,
    }).Refresh)
    slot:Hint("Empty slot art and opacity apply to empty slots; the edge frames every slot, filled or not — exactly as Bags 1 does it.")

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

    -- Sort direction (audit §6.3). Additive; default OFF = ascending (categories A→Z). When on,
    -- the item groups sort in the opposite order; within an item, fuller stacks stay first.
    register(sorting:Checkbox({
        label = "Sort descending",
        tooltip = "Reverse the category order when sorting (Z→A groups).",
        get = function() local db = DB(); return db and db.sortDescending == true end,
        set = function(v) local db = DB(); if db then db.sortDescending = v and true or false end end,
    }).Refresh)

    -- ── Auto-open ───────────────────────────────────────────────────────────────
    -- Open the bags automatically at these interactions and close them after —
    -- the ns.Features auto-display set (audit §1.5). All default ON, matching 1.x.
    -- Reads/writes DaseekiBags2DB.autoDisplay.* (defaults applied by Features on
    -- STORE_READY); a missing/true sub-key = enabled, only explicit false disables.
    local auto = flow:AddSection("Auto-open")
    auto:Hint("Show the bags automatically at these interactions — and hide them again after.")

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
    -- Whether OUR bank window replaces Blizzard's at a banker. Separate from "At the bank"
    -- above, which is about the BAG window. Off restores Blizzard's panel immediately (the
    -- ShowUIPanel hook re-parents it back to UIParent and gives it its OnHide back) — no
    -- reload needed. See ui_bank.lua's BLIZZARD BANK-FRAME OVERRIDE block.
    register(auto:Checkbox({
        label = "Use the Daseeki bank window",
        tooltip = "Replace Blizzard's bank window with the Daseeki one when you visit a banker. Turn this off to get the default Blizzard bank back.",
        get = function() return not (ns.Bank and ns.Bank.Enabled) or ns.Bank.Enabled() end,
        set = function(v) local db = DB(); if db then db.bankWindow = v and true or false end end,
    }).Refresh)
    register(auto:Checkbox({
        label = "At the mailbox", tooltip = "Open the bags when you open the mail.",
        get = function() return adGet("mail") end, set = function(v) adSet("mail", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "At the auction house", tooltip = "Open the bags when you open the auction house.",
        get = function() return adGet("auction") end, set = function(v) adSet("auction", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "When trading", tooltip = "Open the bags when a trade window opens.",
        get = function() return adGet("trade") end, set = function(v) adSet("trade", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "At the crafting window", tooltip = "Open the bags when a tradeskill/crafting window opens.",
        get = function() return adGet("craft") end, set = function(v) adSet("craft", v) end,
    }).Refresh)
    register(auto:Checkbox({
        label = "Close when combat starts", tooltip = "Hide the bags when you enter combat.",
        get = function() return adGet("combatClose") end, set = function(v) adSet("combatClose", v) end,
    }).Refresh)
end

----------------------------------------------------------------------
-- Categories editor (list + inline editor; logic delegated to ns.Rules)
--
-- Master toggle + a selectable list of categories with an inline editor for the
-- selected one (Enabled / Move Up / Move Down / Delete, Name, Query + a live
-- "matches N items" readout). Add / Restore defaults below the list. Every button
-- calls a PURE ns.Rules op then re-grids the bag window — no reload, no drag-drop
-- builder, no per-category color (theme owns color): the "simplified" contract.
----------------------------------------------------------------------

local catSel = 1   -- selected category index (1-based into DB().categories)

-- Mark that the user has made a DELIBERATE choice about categories (toggled the
-- master switch or edited the list). The R3 one-time default-flip migration
-- (Rules.MigrateDefaultFlip) respects this marker so a future default change never
-- clobbers an intentional opt-in.
local function markCategoriesChosen()
    local db = DB()
    if db then db.categoriesUserChose = true end
end

-- The viewed owner's combined entry list, for the live match count.
local function viewedEntries()
    if not (ns.Frame and ns.Frame.BuildCombinedEntries and ns.Frame.ViewedOwner) then return {} end
    local owner = ns.Frame.ViewedOwner()
    if not owner then return {} end
    local db = DB()
    return ns.Frame.BuildCombinedEntries(owner, { showKeyring = true, hidden = (db and db.hiddenBags) or {} })
end

local function catList()
    local db = DB()
    return (db and db.categories) or {}
end

local function selectedCat()
    local list = catList()
    return list[catSel]
end

function Options.BuildCategories(flow)
    local UI = _G.DaseekiUI
    local Rules = ns.Rules
    local sec = flow:AddSection("Categories")
    -- Truth check (W2): this hint used to say 1.x custom rules were NOT imported.
    -- migrate_settings.lua converts every convertible 1.x custom rule into a category
    -- at the migration moment, and deliberately leaves this master toggle OFF, so the
    -- accurate statement is "imported, waiting behind this switch". Rules that use
    -- filters a saved-search category cannot express are reported in chat and skipped.
    sec:Hint("Group items into labelled sections in the combined view. Your 1.x custom rules were imported here as categories, waiting behind this switch (rules a search cannot express were skipped). Split layout is unaffected.")

    -- Master toggle: group vs flat grid. Re-grids live.
    register(sec:Checkbox({
        label = "Group items into categories",
        tooltip = "When on, the combined view stacks labelled category sections. Turn off for one flat grid.",
        get = function() local db = DB(); return Rules.Enabled(db) end,
        set = function(v)
            local db = DB()
            if db then db.categoriesEnabled = v and true or false end
            markCategoriesChosen()
            regrid()
        end,
    }).Refresh)

    -- References resolved as controls are created; the editor + list refresh together.
    local list, nameField, queryField, enableBox, countHint

    local function refreshEditor()
        local c = selectedCat()
        if nameField  and nameField.Refresh  then nameField.Refresh()  end
        if queryField and queryField.Refresh then queryField.Refresh() end
        if enableBox  and enableBox.Refresh  then enableBox.Refresh()  end
        if countHint and countHint._label then
            if c then
                local n = Rules.LiveCountMatches(c.query or "", viewedEntries())
                countHint._label:SetText("Matches " .. n .. " item" .. (n == 1 and "" or "s") .. " in your bags now.")
            else
                countHint._label:SetText("No category selected.")
            end
        end
    end

    local function refreshAllCats()
        if list and list.Rebuild then list:Rebuild() end
        refreshEditor()
    end

    -- Selectable category list (value = index). Disabled rows read as faint + "(off)".
    list = sec:List({
        height = 150,
        selected = catSel,
        items = function()
            local out = {}
            for i, c in ipairs(catList()) do
                local on = c.enabled ~= false
                out[#out + 1] = {
                    text   = (on and "" or "(off)  ") .. (c.name or ("Category " .. i)),
                    value  = i,
                    status = on and "ok" or "faint",
                }
            end
            if #out == 0 then out[#out + 1] = { header = true, text = "NO CATEGORIES — everything shows under \"Everything else\"" } end
            return out
        end,
        onSelect = function(i) catSel = i; refreshEditor() end,
    })

    -- Add / Restore defaults.
    local mgmt = sec:AddRow()
    mgmt:Button({ text = "Add Category", width = 120, onClick = function()
        local _, idx = Rules.Add(catList(), "New Category", "")
        catSel = idx or catSel
        markCategoriesChosen()
        if list and list.SetSelected then list:SetSelected(catSel) end
        refreshAllCats(); regrid()
    end })
    mgmt:Button({ text = "Restore Defaults", width = 140, variant = "quiet", onClick = function()
        local db = DB(); if not db then return end
        Rules.RestoreDefaults(db)
        catSel = 1
        markCategoriesChosen()
        if list and list.SetSelected then list:SetSelected(catSel) end
        refreshAllCats(); regrid()
    end })

    -- ── Inline editor for the selected category ────────────────────────────────
    sec:Hint("Edit the selected category:")

    local actions = sec:AddRow({ vAlign = "center" })
    enableBox = actions:Checkbox({
        label = "Enabled",
        tooltip = "Uncheck to skip this category without deleting it.",
        get = function() local c = selectedCat(); return c ~= nil and c.enabled ~= false end,
        set = function(v)
            local i = catSel
            Rules.SetEnabled(catList(), i, v)
            refreshAllCats(); regrid()
        end,
    })
    actions:Button({ text = "Move Up", width = 90, onClick = function()
        catSel = Rules.MoveUp(catList(), catSel)
        if list and list.SetSelected then list:SetSelected(catSel) end
        refreshAllCats(); regrid()
    end })
    actions:Button({ text = "Move Down", width = 100, onClick = function()
        catSel = Rules.MoveDown(catList(), catSel)
        if list and list.SetSelected then list:SetSelected(catSel) end
        refreshAllCats(); regrid()
    end })
    actions:Button({ text = "Delete", width = 80, variant = "danger", onClick = function()
        Rules.Delete(catList(), catSel)
        if catSel > #catList() then catSel = math.max(1, #catList()) end
        if list and list.SetSelected then list:SetSelected(catSel) end
        refreshAllCats(); regrid()
    end })

    local nameRow = sec:AddRow({ vAlign = "center" })
    nameRow:Label("Name")
    nameField = nameRow:EditBox({
        width = 220,
        get = function() local c = selectedCat(); return c and c.name or "" end,
        set = function(v)
            local i = catSel
            Rules.Rename(catList(), i, (v ~= "" and v) or "Category " .. i)
            refreshAllCats()
        end,
    })
    nameField._fillWidth = false

    local queryRow = sec:AddRow({ vAlign = "center" })
    queryRow:Label("Query")
    queryField = queryRow:EditBox({
        width = 300,
        get = function() local c = selectedCat(); return c and c.query or "" end,
        set = function(v)
            Rules.SetQuery(catList(), catSel, v)
            refreshEditor(); regrid()
        end,
    })
    queryField._fillWidth = false

    countHint = sec:Hint("Matches 0 items in your bags now.")
    sec:Hint("Query = a search: t:consumable, q:>=3, slot:head, or item names. Specials: junk (grey items), new. Comma = OR (e.g. \"t:armor, t:weapon\"). First matching category wins, top to bottom.")

    -- keep the whole editor in sync when the page (re)shows
    register(refreshEditor)
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

-- WINDOW-SCALE SLIDER WRITE. The gate on the marker discipline: every deliberate scale
-- write must claim db.scaleUserChose, so the one-time 0.89 -> 0.92 heal (owner directive
-- 2026-08-03) can never take back a scale the owner actually chose.
local function testScaleSliderWrite(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local db = {}
    ck(Options.WriteWindowScale(db, 1.10) == 1.10, "the slider write returns the stored value")
    ck(db.scale == 1.10, "the slider write persists the value")
    ck(db.scaleUserChose == true, "the slider write CLAIMS the user-chose marker")

    -- Clamped through Frame.WriteScale, not stored raw.
    local hi = {}
    Options.WriteWindowScale(hi, 9)
    ck(hi.scale == (ns.Frame and ns.Frame.MAX_SCALE or 1.5), "the slider write clamps out-of-band values")
    ck(hi.scaleUserChose == true, "…and still marks the choice")

    -- THE ROW THAT MATTERS: setting the slider to exactly the superseded default is a real
    -- choice, and the marker is what makes it survive the next login's heal.
    local at89 = {}
    Options.WriteWindowScale(at89, 0.89)
    ck(at89.scale == 0.89, "the slider can still be set to the old default")
    if ns.Frame and ns.Frame.MigrateScale then
        ck(ns.Frame.MigrateScale(at89) == false, "…and the heal leaves that deliberate 0.89 alone")
        ck(at89.scale == 0.89, "…so it is still 0.89 after login")
    else
        ck(false, "ns.Frame.MigrateScale missing — the heal is not wired")
    end

    -- nil db is a safe no-op that still reports a value (headless / pre-login).
    ck(Options.WriteWindowScale(nil, 0.75) == 0.75, "a write with no db still returns the clamped value")
end

function Options.RunSelfTests(verbose)
    local suites = {
        { name = "defaults additive", fn = testDefaultsAdditive },
        { name = "window scale slider write", fn = testScaleSliderWrite },
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
