-- Daseeki Bags 2.0 — ui_frame.lua
-- The inventory window: the DaseekiUI-skinned frame that hosts the item-button
-- grid(s). W2 owns the WINDOW side; the item buttons + grid groups are the
-- sibling's (ns.Items). This file CONSUMES the interface contract:
--
--   G = ns.Items.CreateGroup(parent)
--   G:SetGrid(columns, buttonSize, gap)
--   G:ShowSlots(entries)         -- entries = array of { owner, cid, slot, data|nil }
--   G:Clear()
--   (G self-sizes)
--
-- Everything is DaseekiUI token-driven and theme-reactive (UI.Skin / tokens),
-- per DREW_UI_STYLE (prime directive: clean and compact). No hardcoded colors.
--
-- ── Layouts (design D3: BOTH are first-class, live-switchable, no reload) ──
--   "combined": one continuous grid — every carried container's slots flow
--               together (backpack cid 0, bags 1..N in cid order, keyring last),
--               per-container identity preserved on each entry (never flattened).
--   "split":    one small-headered group per container, stacked in a column.
-- Switched live via DaseekiBags2DB.layout; Rebuild() re-derives entry lists and
-- re-groups without a /reload.
--
-- ── Open/close hook surface (catalog-verified, WoW Classic Era 1.15) ──
-- The default backpack toggle paths are FrameXML *globals* (globals.txt):
--   ToggleBackpack, ToggleAllBags, ToggleBag, OpenBag,
--   OpenAllBags, OpenBackpack, CloseAllBags, CloseBackpack, CloseBag
-- These are insecure FrameXML functions; bag frames are NOT part of the secure
-- action system on Classic Era, so replacing them (the 1.x uiOverrides fact) is
-- taint-safe. Our replacements Show/Hide a plain unprotected Frame, which is
-- always permitted in combat — no protected call, no taint. (InCombatLockdown is
-- catalog-present and used only as a belt-and-suspenders guard around anything
-- that could ever touch a protected path; our own frame never does.)
--
-- ── Purity ──
-- All layout MATH is in pure functions that touch no WoW API, so the headless
-- harness exercises entry-list construction, window self-sizing, split grouping
-- and geometry round-trip with no live globals. Every CreateFrame call lives
-- inside an in-game-only function, never at file scope.

local ADDON, ns = ...

local Frame = {}
ns.Frame = Frame

local Store = ns.Store

----------------------------------------------------------------------
-- Metrics / default settings (all ADDITIVE keys on DaseekiBags2DB)
----------------------------------------------------------------------

-- Grid cell metrics. buttonSize matches the Classic item-button footprint (37);
-- gap kept tight for Drew's compact directive. columns is the fixed band width
-- (stable layout > responsive reflow): the window hugs a fixed column count.
Frame.DEFAULT_COLUMNS    = 12
Frame.DEFAULT_BUTTONSIZE = 37
Frame.DEFAULT_GAP        = 4

-- Window chrome bands (px). Kept in one place so the pure size math and the
-- in-game arrange agree exactly.
Frame.PAD         = 10   -- window inner padding
Frame.TITLE_H     = 28   -- title bar
Frame.TOOLBAR_H   = 26   -- layout toggle + owner selector stub + search box row
Frame.STRIP_H     = 20   -- bag-slot toggle strip
Frame.MONEY_H     = 20   -- bottom money bar
Frame.VGAP        = 8     -- vertical gap between chrome bands
Frame.GROUP_HDR_H = 16   -- small per-bag header (split layout)
Frame.GROUP_GAP   = 8    -- vertical gap between split groups
-- Category-section chrome (combined-with-categories, W4.5). Same footprint as the
-- split group header/gap so the shared grid math stays identical; kept separate so
-- the two can be tuned independently.
Frame.SECTION_HDR_H = 16 -- microLabel + count header above each category section
Frame.SECTION_GAP   = 8  -- vertical gap between category sections

-- Settings accessors (guarded; the store owns the DB). These read the live
-- DaseekiBags2DB when present, else the documented defaults — so the pure math
-- helpers work headless with an injected opts table too.
function Frame.Columns()    local db = Store and Store.db; return (db and db.columns)    or Frame.DEFAULT_COLUMNS    end
function Frame.ButtonSize()  local db = Store and Store.db; return (db and db.buttonSize) or Frame.DEFAULT_BUTTONSIZE end
function Frame.Gap()         local db = Store and Store.db; return (db and db.gap)        or Frame.DEFAULT_GAP        end
function Frame.Layout()      local db = Store and Store.db; return (db and db.layout)     or "combined"              end
function Frame.ShowKeyring() local db = Store and Store.db; if db and db.showKeyring ~= nil then return db.showKeyring end return true end

-- W4.5: the combined view groups items into category SECTIONS when the categories
-- feature is on AND the rules2 engine is present. SPLIT is UNAFFECTED (bags are the
-- sections there). The additive DB flag (default ON) is owned by rules2.ApplyDefaults;
-- absence/nil reads as ON so behaviour is identical with or without a saved value.
function Frame.CategoriesEnabled()
    if not (ns.Rules and ns.Rules.SectionsForRender) then return false end
    local db = Store and Store.db
    if ns.Rules.Enabled then return ns.Rules.Enabled(db) end
    return not (db and db.categoriesEnabled == false)
end

-- The effective render mode: "split" (unchanged), "categories" (combined + sections),
-- or "combined" (the flat cid-ordered grid). Categories apply only to combined.
function Frame.EffectiveMode()
    if Frame.Layout() == "split" then return "split" end
    if Frame.CategoriesEnabled() then return "categories" end
    return "combined"
end

-- Additive-defaults hook: fills any W2 settings keys the W1 store didn't know
-- about. Called from OnLogin after Store.Init(). Never clobbers existing values.
function Frame.ApplyDefaults(db)
    if type(db) ~= "table" then return end
    if db.columns     == nil then db.columns     = Frame.DEFAULT_COLUMNS    end
    if db.buttonSize  == nil then db.buttonSize  = Frame.DEFAULT_BUTTONSIZE end
    if db.gap         == nil then db.gap         = Frame.DEFAULT_GAP        end
    if db.showKeyring == nil then db.showKeyring = true                     end
    if type(db.hiddenBags) ~= "table" then db.hiddenBags = {} end  -- [cid]=true
    -- geometry keys are left nil until first save (RestoreGeometry falls back)
    return db
end

----------------------------------------------------------------------
-- PURE: container ordering
--
-- Stable carried-container order for THIS window (inventory, not bank):
-- backpack (0) first, carried bags 1..NumBagSlots in ascending cid, keyring (-2)
-- last (only when shown). A container is included only if the owner actually has
-- it captured, and only if it is not in the hidden set (bag-slot toggle strip).
--   opts = { showKeyring=bool (default true), hidden = { [cid]=true } }
----------------------------------------------------------------------

function Frame.CarriedContainerOrder(owner, opts)
    opts = opts or {}
    local hidden = opts.hidden or {}
    local showKeyring = (opts.showKeyring ~= false)
    local ids = {}
    if not owner or type(owner.containers) ~= "table" then return ids end

    local function consider(cid)
        if hidden[cid] then return end
        if owner.containers[cid] then ids[#ids + 1] = cid end
    end

    consider(Store.BACKPACK_CONTAINER)                     -- 0
    for cid = 1, Store.NumBagSlots() do consider(cid) end  -- 1..N ascending
    if showKeyring then consider(Store.KEYRING_CONTAINER) end -- -2 last
    return ids
end

----------------------------------------------------------------------
-- PURE: entry-list construction
--
-- One entry per slot index 1..container.size, INCLUDING empty slots (data=nil)
-- so the grid renders drop-target cells. `owner` on each entry is the owner
-- RECORD (carries .nameRealm/.source; the item button decides interactivity —
-- only a "full" self owner is live-clickable). Slot order is ascending; the
-- store never flattens container identity, so cid rides on every entry.
----------------------------------------------------------------------

-- Append this container's slot entries onto `out`. Returns `out`.
function Frame.AppendContainerEntries(out, owner, cid)
    local c = owner and owner.containers and owner.containers[cid]
    if not c then return out end
    local size = c.size or 0
    for slot = 1, size do
        out[#out + 1] = { owner = owner, cid = cid, slot = slot, data = c.slots[slot] }
    end
    return out
end

-- Combined: every ordered container's slots in one flat list.
function Frame.BuildCombinedEntries(owner, opts)
    local out = {}
    for _, cid in ipairs(Frame.CarriedContainerOrder(owner, opts)) do
        Frame.AppendContainerEntries(out, owner, cid)
    end
    return out
end

-- Split: one group descriptor per ordered container.
--   group = { cid, class, size, link, entries = { {owner,cid,slot,data}, ... } }
function Frame.BuildSplitGroups(owner, opts)
    local groups = {}
    for _, cid in ipairs(Frame.CarriedContainerOrder(owner, opts)) do
        local c = owner.containers[cid]
        local g = {
            cid     = cid,
            class   = Store.ContainerClass(cid),
            size    = c.size or 0,
            link    = c.link,
            entries = Frame.AppendContainerEntries({}, owner, cid),
        }
        groups[#groups + 1] = g
    end
    return groups
end

----------------------------------------------------------------------
-- PURE: grid + window self-sizing (identical math the in-game arrange uses)
----------------------------------------------------------------------

-- Grid geometry for `count` cells at a FIXED `columns` width. A fixed band width
-- (not min(count,columns)) keeps the window stable as items come and go — Drew's
-- "stable layouts over responsive cleverness". count 0 => 0 rows / 0 height, but
-- width stays the full band so an empty container still reads as a band.
function Frame.GridDims(count, columns, buttonSize, gap)
    columns    = math.max(1, columns    or Frame.DEFAULT_COLUMNS)
    buttonSize = buttonSize or Frame.DEFAULT_BUTTONSIZE
    gap        = gap or Frame.DEFAULT_GAP
    local rows = math.ceil((count or 0) / columns)
    local width  = columns * buttonSize + (columns - 1) * gap
    local height = rows > 0 and (rows * buttonSize + (rows - 1) * gap) or 0
    return { cols = columns, rows = rows, width = width, height = height }
end

-- Content region size (grid area only, no window chrome) for a layout.
--   layout = "combined" | "split"
-- Returns { width, height }.
function Frame.ComputeContentSize(owner, layout, opts)
    opts = opts or {}
    local columns = opts.columns    or Frame.Columns()
    local bs      = opts.buttonSize or Frame.ButtonSize()
    local gap     = opts.gap        or Frame.Gap()
    local bandW   = Frame.GridDims(0, columns, bs, gap).width  -- full-band width

    -- Category sections (W4.5): when a prebuilt section list is supplied, size from
    -- it — each section is a microLabel header band + its own grid, stacked. Empty
    -- sections are already omitted by the builder (collapse). Takes precedence over
    -- the layout branches so it composes with layout == "combined".
    if opts.sections then
        local h = 0
        for i, s in ipairs(opts.sections) do
            if i > 1 then h = h + Frame.SECTION_GAP end
            local gd = Frame.GridDims(#s.entries, columns, bs, gap)
            h = h + Frame.SECTION_HDR_H + gd.height
        end
        return { width = bandW, height = h }
    end

    if layout == "split" then
        local groups = Frame.BuildSplitGroups(owner, opts)
        local h = 0
        for i, g in ipairs(groups) do
            if i > 1 then h = h + Frame.GROUP_GAP end
            local gd = Frame.GridDims(#g.entries, columns, bs, gap)
            h = h + Frame.GROUP_HDR_H + gd.height
        end
        return { width = bandW, height = h }
    end

    -- combined
    local entries = Frame.BuildCombinedEntries(owner, opts)
    local gd = Frame.GridDims(#entries, columns, bs, gap)
    return { width = bandW, height = gd.height }
end

-- Full window size (content + all chrome bands). Returns { width, height }.
-- The in-game arrange positions bands to these exact numbers, so a static test
-- of this function proves the rendered window is never zero-sized.
function Frame.ComputeWindowSize(owner, layout, opts)
    local content = Frame.ComputeContentSize(owner, layout, opts)
    local w = content.width + Frame.PAD * 2
    local h = Frame.TITLE_H
            + Frame.PAD                       -- gap under title
            + Frame.TOOLBAR_H + Frame.VGAP
            + Frame.STRIP_H   + Frame.VGAP
            + content.height  + Frame.VGAP
            + Frame.MONEY_H
            + Frame.PAD
    return { width = w, height = h }
end

----------------------------------------------------------------------
-- PURE: geometry persistence round-trip (additive DaseekiBags2DB keys)
----------------------------------------------------------------------

-- Write a placed window's geometry into the settings DB.
function Frame.WriteGeometry(db, point, relPoint, x, y)
    if type(db) ~= "table" then return end
    db.framePoint    = point
    db.frameRelPoint = relPoint
    db.frameX        = x
    db.frameY        = y
end

-- Read geometry back, falling back to a centered default when unset. Returns
-- point, relPoint, x, y (never nil).
function Frame.ReadGeometry(db)
    db = db or {}
    return db.framePoint or "CENTER",
           db.frameRelPoint or "CENTER",
           db.frameX or 0,
           db.frameY or 0
end

----------------------------------------------------------------------
-- Viewed owner (self-only this wave; W3 adds the owner dropdown)
----------------------------------------------------------------------

-- The owner record currently displayed. Defaults to self; W3's owner selector sets
-- Frame._viewKey to browse an alt/remote owner. Callers use this indirection so
-- nothing hard-codes "self" outside here. This is the SHARED viewed-owner state the
-- bank window and both owner selectors read.
function Frame.ViewedOwnerKey()
    if Frame._viewKey then return Frame._viewKey end
    -- self identity, matching capture.selfNameRealm() shape
    local name  = (_G.UnitName and _G.UnitName("player")) or "Unknown"
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))
    return Store.MakeNameRealm(name, realm)
end

function Frame.ViewedOwner()
    return Store.GetOwner(Frame.ViewedOwnerKey())
end

-- The self identity key (used to detect "am I viewing an alt?").
function Frame.SelfKey()
    local name  = (_G.UnitName and _G.UnitName("player")) or "Unknown"
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))
    return Store.MakeNameRealm(name, realm)
end

-- Set the shared viewed owner (W3 owner selector). Passing the self key (or nil)
-- returns to the live self view. Repaints the inventory window, notifies the bank
-- window, and refreshes every attached owner selector so both windows agree.
function Frame.SetViewedOwner(key)
    if key == Frame.SelfKey() then key = nil end   -- nil == self (live)
    Frame._viewKey = key
    if Frame.IsShown and Frame.IsShown() then Frame.Rebuild() end
    if ns.Bank and ns.Bank.OnOwnerChanged then ns.Bank.OnOwnerChanged() end
    if ns.Owner and ns.Owner.RefreshAll then ns.Owner.RefreshAll() end
end

----------------------------------------------------------------------
-- PURE: keyring enable gate (W3, Expert C §5c)
--
-- Keyring renders in THIS (inventory) window as W2 built it (container -2). W3 adds
-- the live IsKeyRingEnabled() gate so it doesn't show when the game feature is off,
-- and confirms its size stays dynamic (capture re-scans -2 on BAG_UPDATE, so the
-- store's container.size — and thus the entry count — follows the live keyring).
----------------------------------------------------------------------

-- settingOn = the user's "Show keyring" preference; apiEnabled = IsKeyRingEnabled().
-- Both must be true. apiEnabled nil (headless / API absent) is treated as enabled so
-- the keyring still renders under the harness and on any client lacking the global.
function Frame.KeyringGate(settingOn, apiEnabled)
    if not settingOn then return false end
    if apiEnabled == nil then return true end
    return apiEnabled and true or false
end

-- Live wrapper: the persisted "Show keyring" setting AND the game's IsKeyRingEnabled().
function Frame.KeyringEnabled()
    local apiEnabled
    if _G.IsKeyRingEnabled then apiEnabled = _G.IsKeyRingEnabled() and true or false end
    return Frame.KeyringGate(Frame.ShowKeyring(), apiEnabled)
end

----------------------------------------------------------------------
-- ══════════════ IN-GAME UI (guarded; no CreateFrame at file scope) ══════════
----------------------------------------------------------------------

local UI  -- DaseekiUI, bound lazily in-game

local WINDOW_NAME = "DaseekiBags2Window"

-- Format copper as a coin-icon string in-game; plain g/s/c headless-safe.
local function moneyString(copper)
    if _G.GetCoinTextureString then return _G.GetCoinTextureString(copper or 0) end
    local g, s, c = Store.MoneyParts(copper or 0)
    return string.format("%dg %ds %dc", g, s, c)
end

-- Save the live window position into settings.
local function saveGeometry(win)
    local db = Store and Store.db
    if not db then return end
    local point, _, relPoint, x, y = win:GetPoint()
    Frame.WriteGeometry(db, point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5))
end

-- Restore position (size is self-computed each Rebuild, so only the anchor).
local function restoreGeometry(win)
    local point, relPoint, x, y = Frame.ReadGeometry(Store and Store.db)
    win:ClearAllPoints()
    win:SetPoint(point, _G.UIParent, relPoint, x, y)
end

-- Build the window chrome once. Returns the window frame.
function Frame.Ensure()
    if Frame.window then return Frame.window end
    if not _G.CreateFrame then return nil end   -- headless: never build UI
    UI = UI or _G.DaseekiUI
    if not UI then return nil end               -- Daseeki-Core absent: no-op

    local PAD, TITLE_H = Frame.PAD, Frame.TITLE_H

    local win = _G.CreateFrame("Frame", WINDOW_NAME, _G.UIParent, "BackdropTemplate")
    -- Defensive creation-time size (zero-size-frame audit): a valid chrome-only
    -- size from the pure math with no owner. Rebuild() re-sizes to real content
    -- before the window is ever shown (Open => Rebuild => Show).
    do local sz = Frame.ComputeWindowSize(nil, "combined", {}); win:SetSize(sz.width, sz.height) end
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:SetUserPlaced(true)     -- keep our anchor; don't let the layout manager move it
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
        -- Dark edge under the bronze keyline; borderLite was the beta's bright-rim
        -- culprit (§1), so the visible frame edge is the aged keyline, not this.
        self:SetBackdropBorderColor(UI.Color("border"))
    end)
    -- Field Ledger material (BRAND_SPEC §4): grain substrate + aged-edge vignette +
    -- ONE bronze keyline. Guarded — a Core without the Phase-0 kit simply skips it.
    if UI.PaintLedgerGround then UI.PaintLedgerGround(win) end
    -- ESC closes it (FrameXML special-frame list; proven by Daseeki-Core hub).
    if _G.UISpecialFrames then table.insert(_G.UISpecialFrames, WINDOW_NAME) end

    -- ── Title bar (drag to move) ──────────────────────────────────────────────
    local titleBar = _G.CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLE_H)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing(); saveGeometry(win) end)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbBg:SetPoint("TOPLEFT", titleBar, "TOPLEFT", 1, -1)
    tbBg:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -1, 0)
    UI.Skin(tbBg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    -- Maker's mark — the ONE diamond on this window (BRAND_SPEC §4/§5), titlebar
    -- only. Bank/keyring (W3) each get their own single mark.
    local mark
    if UI.MakerMark then
        mark = UI.MakerMark(titleBar, { size = 18 })
        mark:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
        win.makerMark = mark
    end

    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.ceremonial or UI.fonts.header)   -- MORPHEUS wordmark (§3)
    if mark then title:SetPoint("LEFT", mark, "RIGHT", 8, 0)
    else         title:SetPoint("LEFT", titleBar, "LEFT", 10, 0) end
    title:SetText("Bags")
    win.title = title

    local closeBtn = _G.CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY")
    cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
    closeBtn:SetScript("OnClick", function() Frame.Close() end)

    -- One entry-head hairline under the titlebar (§3), pixel-snapped when the
    -- Phase-0 kit is present so it stays crisp at 720p; plain texture otherwise.
    local titleRule
    if UI.Hairline then
        titleRule = UI.Hairline(win, { token = "borderLite", layer = "ARTWORK" })
    else
        titleRule = win:CreateTexture(nil, "ARTWORK")
        titleRule:SetHeight(1)
        UI.Skin(titleRule, function(self) self:SetColorTexture(UI.Color("borderLite")) end)
    end
    titleRule:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -TITLE_H)
    titleRule:SetPoint("TOPRIGHT", win, "TOPRIGHT", -1, -TITLE_H)
    win.titleRule = titleRule

    -- ── Toolbar: layout toggle + owner stub + search placeholder ──────────────
    local toolbar = _G.CreateFrame("Frame", nil, win)
    toolbar:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, -(TITLE_H + PAD))
    toolbar:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, -(TITLE_H + PAD))
    toolbar:SetHeight(Frame.TOOLBAR_H)
    win.toolbar = toolbar

    -- Combined/Split live switch (segmented). SetLayout persists + rebuilds.
    local seg = UI.MakeSegmented(toolbar, {
        compact = true,
        choices = { { value = "combined", text = "Combined" }, { value = "split", text = "Split" } },
        get = function() return Frame.Layout() end,
        set = function(v) Frame.SetLayout(v) end,
    })
    seg:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    win.layoutSeg = seg

    -- Owner selector (W3): the titlebar flyout listing every cached owner. Selecting
    -- an alt/remote owner flips the SHARED viewed-owner state (Frame.SetViewedOwner),
    -- re-rendering this window (and the bank) read-only. Falls back to a plain label
    -- if ui_owner.lua is somehow absent.
    local ownerLbl = toolbar:CreateFontString(nil, "OVERLAY")
    ownerLbl:SetFontObject(UI.fonts.muted)
    ownerLbl:SetPoint("LEFT", seg, "RIGHT", 10, 0)
    win.ownerLabel = ownerLbl
    if ns.Owner and ns.Owner.CreateSelector then
        local sel = ns.Owner.CreateSelector(toolbar, {
            onSelect = function(key) Frame.SetViewedOwner(key) end,
        })
        if sel then
            sel:SetPoint("LEFT", seg, "RIGHT", 10, 0)
            win.ownerSelector = sel
            ownerLbl:Hide()
        end
    end

    -- Search box PLACEHOLDER (inert; W4 wires the matcher). Right-pinned.
    local searchWrap = UI.FlatFrame(toolbar, "inset", "controlBorder")
    searchWrap:SetSize(150, 22)
    searchWrap:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    local search = _G.CreateFrame("EditBox", nil, searchWrap)
    search:SetPoint("TOPLEFT", searchWrap, "TOPLEFT", 6, 0)
    search:SetPoint("BOTTOMRIGHT", searchWrap, "BOTTOMRIGHT", -6, 0)
    search:SetAutoFocus(false)
    search:SetFontObject(UI.fonts.body)
    search:SetScript("OnEscapePressed", function(self)
        self:SetText("")                                   -- clear + restore all items
        if ns.Search then ns.Search.SetQuery("") end
        self:ClearFocus()
    end)
    search:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
    local searchHint = search:CreateFontString(nil, "ARTWORK")
    searchHint:SetFontObject(UI.fonts.microLabel or UI.fonts.small)   -- ARIALN micro-label (§3)
    searchHint:SetPoint("LEFT", search, "LEFT", 0, 0)
    searchHint:SetText("Search")                                       -- plain copy (§6)
    UI.Skin(searchHint, function(self) self:SetTextColor(UI.Color("faint")) end)
    -- W4: as-you-type -> debounced dim filter across BOTH layouts (ns.Search).
    search:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        searchHint:SetShown(text == "")
        if ns.Search then ns.Search.SetQuery(text) end
    end)
    win.searchBox = search

    -- Sort button (W4): arrange the carried bags via the sort engine (ns.Sort).
    local sortBtn = UI.MakeButton(toolbar, {
        text = "Sort", width = 52,
        onClick = function()
            if ns.Sort and ns.Sort.Run then ns.Sort.Run(ns.Sort.CarriedBagIDs()) end
        end,
    })
    sortBtn:SetPoint("RIGHT", searchWrap, "LEFT", -6, 0)
    win.sortBtn = sortBtn

    -- Find button (W3): open the cross-character Find window, seeded with the current
    -- search text so "search everywhere" is one click from the in-bag search.
    local findBtn = UI.MakeButton(toolbar, {
        text = "Find", width = 48,
        onClick = function()
            if ns.Find and ns.Find.Toggle then ns.Find.Toggle(win.searchBox and win.searchBox:GetText()) end
        end,
    })
    findBtn:SetPoint("RIGHT", sortBtn, "LEFT", -6, 0)
    win.findBtn = findBtn

    -- ── Bag-slot toggle strip (show/hide a container's slots) ─────────────────
    local strip = _G.CreateFrame("Frame", nil, win)
    strip:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -Frame.VGAP)
    strip:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -Frame.VGAP)
    strip:SetHeight(Frame.STRIP_H)
    win.strip = strip
    win._stripButtons = {}

    -- One section hairline separating the toggle strip from the grid (§3/§9 budget:
    -- titlebar + strip = two rules total).
    if UI.Hairline then
        local stripRule = UI.Hairline(win, { token = "border", layer = "ARTWORK" })
        stripRule:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -math.floor(Frame.VGAP / 2))
        stripRule:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, -math.floor(Frame.VGAP / 2))
        win.stripRule = stripRule
    end

    -- ── Content host (the grid area) ──────────────────────────────────────────
    local content = _G.CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -Frame.VGAP)
    content:SetSize(1, 1)   -- non-zero seed; Rebuild() sizes to the grid content
    win.content = content
    win._groups = {}     -- pooled ns.Items groups (index 1 = combined; 1..N = split)

    -- ── Money bar (bottom-right; viewed owner, cross-account total on tooltip) ─
    local money = _G.CreateFrame("Button", nil, win)
    money:SetSize(160, Frame.MONEY_H)
    money:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD, PAD)
    local moneyFS = money:CreateFontString(nil, "OVERLAY")
    moneyFS:SetFontObject(UI.fonts.numeral or UI.fonts.body)   -- ARIALN numerals (§3)
    moneyFS:SetPoint("RIGHT", money, "RIGHT", 0, 0)
    moneyFS:SetJustifyH("RIGHT")
    -- Warm cream, not bright white — "gold is sacred" but rendered on-brand (§2/§3).
    UI.Skin(moneyFS, function(self) self:SetTextColor(UI.Color("text")) end)
    money:SetScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        _G.GameTooltip:AddLine("Gold", UI.Color("text"))
        -- cross-account totals are sacred (D1): show the grand total + per account.
        _G.GameTooltip:AddDoubleLine("All characters", moneyString(Store.TotalMoney()), 1,1,1, 1,1,1)
        for acct, copper in pairs(Store.MoneyByAccount()) do
            local label = acct ~= "" and acct or "Unlinked"
            _G.GameTooltip:AddDoubleLine(label, moneyString(copper))
        end
        _G.GameTooltip:Show()
    end)
    money:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)
    win.money   = money
    win.moneyFS = moneyFS

    Frame.window = win
    restoreGeometry(win)
    return win
end

-- Rebuild the bag-slot toggle strip for the viewed owner (one small button per
-- carried container; click hides/shows that container's slots).
function Frame.RebuildStrip()
    local win = Frame.window
    if not win or not UI then return end
    local owner = Frame.ViewedOwner()
    local db = Store.db
    local hidden = (db and db.hiddenBags) or {}

    for _, b in ipairs(win._stripButtons) do b:Hide() end

    -- ALL carried containers (ignore the hidden filter here — the strip needs to
    -- show hidden ones too so they can be toggled back on).
    local order = Frame.CarriedContainerOrder(owner, { showKeyring = Frame.KeyringEnabled() })
    local x, SIZE, GAP = 0, Frame.STRIP_H, 4
    for i, cid in ipairs(order) do
        local b = win._stripButtons[i]
        if not b then
            b = _G.CreateFrame("Button", nil, win.strip, "BackdropTemplate")
            b:SetSize(SIZE, SIZE)
            local fs = b:CreateFontString(nil, "OVERLAY")
            fs:SetFontObject(UI.fonts.microLabel or UI.fonts.small)   -- ARIALN micro-label (§3)
            fs:SetPoint("CENTER", b, "CENTER", 0, 0)
            b._fs = fs
            -- Thin bronze underline, shown ONLY in the active (bag-shown) state — the
            -- quiet marker that replaces the crimson accent wash (§3, attention inversion).
            local ul = b:CreateTexture(nil, "OVERLAY")
            ul:SetHeight(1)
            ul:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 1)
            ul:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 1)
            b._underline = ul
            -- State-driven skin, registered ONCE (theme-reactive; re-run each rebuild
            -- via b._applySkin() so pooled buttons never leak theme callbacks).
            b._applySkin = function()
                local on = b._on and true or false
                b:SetBackdrop(UI.FLAT_BACKDROP)
                -- shown = calm raised parchment; hidden = recessed idle well.
                b:SetBackdropColor(UI.Color(on and "raised" or "inset"))
                b:SetBackdropBorderColor(UI.Color(on and "border" or "controlBorder"))
                b._fs:SetTextColor(UI.Color(on and "text" or "faint"))
                b._underline:SetColorTexture(UI.Color("bronze"))
                b._underline:SetShown(on)
            end
            UI.Skin(b, function() if b._applySkin then b._applySkin() end end)
            win._stripButtons[i] = b
        end
        b._cid = cid
        b:ClearAllPoints()
        b:SetPoint("LEFT", win.strip, "LEFT", x, 0)
        x = x + SIZE + GAP
        -- label: backpack "B", keyring "K", carried bags by number
        local lbl = (cid == Store.BACKPACK_CONTAINER and "B")
                 or (cid == Store.KEYRING_CONTAINER  and "K")
                 or tostring(cid)
        b._fs:SetText(lbl)
        b._on = not hidden[cid]
        b._applySkin()
        b:SetScript("OnClick", function(self)
            db.hiddenBags[self._cid] = (not db.hiddenBags[self._cid]) or nil
            Frame.Rebuild()
        end)
        b:Show()
    end
end

-- Acquire a pooled ns.Items group under the content host.
local function acquireGroup(win, index)
    local g = win._groups[index]
    if not g and ns.Items and ns.Items.CreateGroup then
        g = ns.Items.CreateGroup(win.content)
        win._groups[index] = g
    end
    return g
end

-- Hide every pooled group from `fromIndex` on (used when a rebuild needs fewer).
local function releaseGroupsFrom(win, fromIndex)
    for i = fromIndex, #win._groups do
        local g = win._groups[i]
        if g then if g.Clear then g:Clear() end if g.Hide then g:Hide() end end
    end
end

-- Acquire a pooled category-section header (microLabel name + muted count), a plain
-- FontString band drawn by ui_frame — the item grid's own G:SetHeader is bag-specific
-- (ui_items owns it, untouched here), so category headers live on the window side.
local function acquireSectionHeader(win, index)
    win._sectionHeaders = win._sectionHeaders or {}
    local h = win._sectionHeaders[index]
    if not h then
        h = _G.CreateFrame("Frame", nil, win.content)
        h:SetHeight(Frame.SECTION_HDR_H)
        local name = h:CreateFontString(nil, "OVERLAY")
        name:SetFontObject(UI.fonts.microLabel or UI.fonts.small)   -- ARIALN micro-label (§3)
        name:SetPoint("LEFT", h, "LEFT", 0, 0)
        name:SetJustifyH("LEFT")
        h._name = name
        local count = h:CreateFontString(nil, "OVERLAY")
        count:SetFontObject(UI.fonts.numeral or UI.fonts.small)     -- ARIALN numeral (§3)
        count:SetPoint("RIGHT", h, "RIGHT", 0, 0)
        count:SetJustifyH("RIGHT")
        h._count = count
        -- theme-reactive colors, registered once (attention inversion: calm muted)
        UI.Skin(h, function()
            h._name:SetTextColor(UI.Color("muted"))
            h._count:SetTextColor(UI.Color("faint"))
        end)
        win._sectionHeaders[index] = h
    end
    return h
end

local function releaseSectionHeadersFrom(win, fromIndex)
    if not win._sectionHeaders then return end
    for i = fromIndex, #win._sectionHeaders do
        local h = win._sectionHeaders[i]
        if h then h:Hide() end
    end
end

-- W4 wiring: iterate every live item button across BOTH layouts (all pooled
-- ns.Items groups). The search controller uses this to dim non-matching slots.
function Frame.ForEachButton(fn)
    local win = Frame.window
    if not win or not win._groups then return end
    for _, g in ipairs(win._groups) do
        local btns = g and g._buttons
        if btns then for i = 1, #btns do fn(btns[i]) end end
    end
end

-- The core repaint: derive entry lists for the active layout, feed ns.Items,
-- position the group(s), and size the window to the pure math. Degrades to a
-- chrome-only window when ns.Items is absent (sibling not merged yet).
function Frame.Rebuild()
    local win = Frame.window
    if not win or not UI then return end
    local owner  = Frame.ViewedOwner()
    local layout = Frame.Layout()
    local cols, bs, gap = Frame.Columns(), Frame.ButtonSize(), Frame.Gap()
    local opts = { columns = cols, buttonSize = bs, gap = gap, showKeyring = Frame.KeyringEnabled(),
                   hidden = (Store.db and Store.db.hiddenBags) or {} }

    -- owner label (fallback stub) + owner selector (W3)
    if win.ownerLabel then
        local key = Frame.ViewedOwnerKey()
        win.ownerLabel:SetText(owner and (owner.name or key) or key)
    end
    if win.ownerSelector and win.ownerSelector.Refresh then win.ownerSelector:Refresh() end
    -- money (viewed owner)
    if win.moneyFS then win.moneyFS:SetText(moneyString(owner and owner.money or 0)) end
    if win.layoutSeg and win.layoutSeg.Refresh then win.layoutSeg:Refresh() end

    Frame.RebuildStrip()

    -- W4.5: in combined mode with categories on, bucket the combined entry list into
    -- category sections up front. SPLIT is unaffected. When the engine yields sections
    -- they drive both the pure size math (opts.sections) and the render loop below.
    local mode = Frame.EffectiveMode()
    local sections
    if mode == "categories" then
        local entries = Frame.BuildCombinedEntries(owner, opts)
        sections = ns.Rules.SectionsForRender(entries, true)   -- includeFree => drop cells
        opts.sections = sections
    end

    -- Content sizing from the PURE math (never depends on the item frame).
    local content = Frame.ComputeContentSize(owner, layout, opts)
    win.content:SetSize(math.max(content.width, 1), math.max(content.height, 1))

    if ns.Items and ns.Items.CreateGroup then
        if mode == "categories" then
            -- One pooled ns.Items group per category section, stacked vertically, each
            -- under a window-drawn microLabel+count header. A section's entries are
            -- mixed-cid (per-container identity preserved on every entry — D3 law); the
            -- item grid parents each live button to its own cid holder internally, so a
            -- single group renders items from many bags correctly. Empty sections are
            -- already omitted by the builder (collapse).
            local y = 0
            for i, s in ipairs(sections) do
                local g = acquireGroup(win, i)
                if g.SetHeader then g:SetHeader(nil) end   -- clear any split bag-header on a reused group
                g:SetGrid(cols, bs, gap)
                g:ClearAllPoints()
                g:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -(y + Frame.SECTION_HDR_H))
                g:ShowSlots(s.entries)
                if g.Show then g:Show() end
                -- window-drawn section header (name + count)
                local hdr = acquireSectionHeader(win, i)
                hdr:ClearAllPoints()
                hdr:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -y)
                hdr:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", 0, -y)
                hdr._name:SetText(s.name)
                hdr._count:SetText(tostring(s.count))
                hdr:Show()
                local gd = Frame.GridDims(#s.entries, cols, bs, gap)
                y = y + Frame.SECTION_HDR_H + gd.height + Frame.SECTION_GAP
            end
            releaseGroupsFrom(win, #sections + 1)
            releaseSectionHeadersFrom(win, #sections + 1)
        elseif layout == "split" then
            local groups = Frame.BuildSplitGroups(owner, opts)
            local y = 0
            for i, grp in ipairs(groups) do
                local g = acquireGroup(win, i)
                g:SetGrid(cols, bs, gap)
                g:ClearAllPoints()
                -- header sits above each group; group grid below it
                g:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -(y + Frame.GROUP_HDR_H))
                if g.SetHeader then g:SetHeader(grp) end   -- optional contract extra
                g:ShowSlots(grp.entries)
                if g.Show then g:Show() end
                local gd = Frame.GridDims(#grp.entries, cols, bs, gap)
                y = y + Frame.GROUP_HDR_H + gd.height + Frame.GROUP_GAP
            end
            releaseGroupsFrom(win, #groups + 1)
            releaseSectionHeadersFrom(win, 1)   -- no category headers in split mode
        else
            local entries = Frame.BuildCombinedEntries(owner, opts)
            local g = acquireGroup(win, 1)
            g:SetGrid(cols, bs, gap)
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, 0)
            g:ShowSlots(entries)
            if g.Show then g:Show() end
            releaseGroupsFrom(win, 2)
            releaseSectionHeadersFrom(win, 1)   -- no category headers in flat combined mode
        end
    end

    -- Window self-size (pure math => never zero-sized).
    local sz = Frame.ComputeWindowSize(owner, layout, opts)
    win:SetSize(sz.width, sz.height)

    -- W4: re-apply the active search dim to the freshly-painted buttons.
    if ns.Search and ns.Search.Reapply then ns.Search.Reapply() end
end

----------------------------------------------------------------------
-- Show / hide / toggle / layout switch
----------------------------------------------------------------------

function Frame.Open()
    local win = Frame.Ensure()
    if not win then return end
    Frame.Rebuild()
    win:Show()
end

function Frame.Close()
    if Frame.window then Frame.window:Hide() end
end

function Frame.Toggle()
    local win = Frame.Ensure()
    if not win then return end
    if win:IsShown() then Frame.Close() else Frame.Open() end
end

function Frame.IsShown()
    return Frame.window and Frame.window:IsShown() and true or false
end

-- Set the search box text (published surface for ns.Features Alt-click flash-find).
-- SetText fires the box's OnTextChanged, which drives ns.Search; the highlight is
-- the visible "flash". No-op before the window exists / headless.
function Frame.SetSearch(text)
    local win = Frame.window
    if not win or not win.searchBox then return end
    text = text or ""
    win.searchBox:SetText(text)
    if win.searchBox.HighlightText then win.searchBox:HighlightText() end
    if win.searchBox.SetCursorPosition then win.searchBox:SetCursorPosition(#text) end
end

-- Live combined<->split switch (D3): persist + rebuild, no reload.
function Frame.SetLayout(mode)
    if mode ~= "combined" and mode ~= "split" then return end
    if Store and Store.db then Store.db.layout = mode end
    if Frame.IsShown() then Frame.Rebuild() end
end

----------------------------------------------------------------------
-- Debounced refresh (coalesce bursty capture events into one repaint/tick)
----------------------------------------------------------------------

Frame._refreshQueued = false
function Frame.RequestRefresh()
    if Frame._refreshQueued then return end
    Frame._refreshQueued = true
    local fire = function()
        Frame._refreshQueued = false
        if Frame.IsShown() then
            if ns.SafeCall then ns:SafeCall(Frame.Rebuild) else Frame.Rebuild() end
        end
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, fire) else fire() end
end

----------------------------------------------------------------------
-- Open/close hook surface — replace the FrameXML bag-toggle globals
--
-- Bags are not part of the secure action system on Classic Era, so replacing
-- these insecure FrameXML globals is the taint-safe 1.x-proven surface. Our
-- replacements only Show/Hide an unprotected frame (always allowed in combat).
-- Guarded so it installs once; originals are captured for future restore.
----------------------------------------------------------------------

Frame._hooked = false
function Frame.HookBagToggles()
    if Frame._hooked then return end
    if not _G.CreateFrame then return end   -- headless: never patch globals
    Frame._hooked = true
    Frame._orig = {}

    local function capture(name) Frame._orig[name] = _G[name] end
    for _, n in ipairs({ "ToggleBackpack", "ToggleAllBags", "ToggleBag",
                         "OpenAllBags", "OpenBackpack", "OpenBag",
                         "CloseAllBags", "CloseBackpack", "CloseBag" }) do
        capture(n)
    end

    local function openOurs()   Frame.Open()  end
    local function closeOurs()  Frame.Close() end
    local function toggleOurs() Frame.Toggle() end

    _G.ToggleBackpack = toggleOurs
    _G.ToggleAllBags  = toggleOurs
    _G.ToggleBag      = function() toggleOurs() end   -- individual bag icon => our window
    _G.OpenAllBags    = function() openOurs() end     -- bank/merchant "show my bags"
    _G.OpenBackpack   = openOurs
    _G.OpenBag        = function() openOurs() end
    _G.CloseAllBags   = function() closeOurs() end
    _G.CloseBackpack  = closeOurs
    _G.CloseBag       = function() closeOurs() end
end

----------------------------------------------------------------------
-- Login wiring (called by a future core.lua). Idempotent + guarded.
----------------------------------------------------------------------

function Frame.OnLogin()
    if Store and Store.db then Frame.ApplyDefaults(Store.db) end
    Frame.HookBagToggles()
    -- Subscribe to W1 capture's store-updated event (capture.lua fires
    -- ns:Fire("BAGS_CAPTURED", nameRealm, owner)). The subscribe side is provided
    -- by core.lua's message bus; guard until it exists.  ⚠ CONTRACT FRICTION:
    -- W1 fires via ns:Fire but neither W1 nor the harness defines an ns:On/
    -- subscribe API — core.lua must add one (ns:On(msg, fn)).
    if ns.On then
        ns:On("BAGS_CAPTURED", function() Frame.RequestRefresh() end)
    elseif ns.RegisterMessage then
        ns:RegisterMessage("BAGS_CAPTURED", function() Frame.RequestRefresh() end)
    end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_frame")
----------------------------------------------------------------------

-- Build a deterministic self owner with a backpack, two bags and a keyring.
local function fixtureOwner()
    _G.DaseekiBags2Data = nil; Store.Init()
    local o = Store.EnsureOwner("Tester-TestRealm")
    o.source = "full"
    Store.SetMoney(o, 1022693)

    local bp = Store.NewContainer(16)             -- backpack, 16 slots
    bp.slots[1]  = Store.NewSlot(6948, 1)
    bp.slots[5]  = Store.NewSlot(22157, 20, 3)
    bp.slots[16] = Store.NewSlot(4306, 5)
    Store.PutContainer(o, 0, bp, 100)

    local bag1 = Store.NewContainer(14, "item:14046")  -- carried bag
    bag1.slots[1] = Store.NewSlot(22157, 1)
    Store.PutContainer(o, 1, bag1, 100)

    local bag2 = Store.NewContainer(6, "item:11000")   -- small carried bag, empty
    Store.PutContainer(o, 2, bag2, 100)

    local key = Store.NewContainer(12)             -- keyring
    key.slots[1] = Store.NewSlot(5175, 1)
    Store.PutContainer(o, -2, key, 100)
    return o
end

local function testContainerOrder(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = fixtureOwner()
    local ids = Frame.CarriedContainerOrder(o, { showKeyring = true })
    ck(#ids == 4, "4 carried containers ordered")
    ck(ids[1] == 0 and ids[2] == 1 and ids[3] == 2, "backpack then bags ascending")
    ck(ids[4] == -2, "keyring last")
    -- keyring hidden by option
    local noKey = Frame.CarriedContainerOrder(o, { showKeyring = false })
    ck(#noKey == 3 and noKey[3] == 2, "showKeyring=false drops keyring")
    -- hidden set skips a bag (bag-slot toggle strip)
    local hid = Frame.CarriedContainerOrder(o, { showKeyring = true, hidden = { [1] = true } })
    ck(#hid == 3 and hid[1] == 0 and hid[2] == 2 and hid[3] == -2, "hidden cid 1 skipped, order stable")
end

local function testCombinedEntries(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = fixtureOwner()
    local e = Frame.BuildCombinedEntries(o, { showKeyring = true })
    -- 16 + 14 + 6 + 12 = 48 slot entries (empty slots included)
    ck(#e == 48, "combined entry count = sum of container sizes (48), got " .. #e)
    -- stable ordering: first 16 are backpack slots 1..16 in order
    ck(e[1].cid == 0 and e[1].slot == 1, "first entry is backpack slot 1")
    ck(e[1].data and e[1].data.id == 6948, "backpack slot1 data carried")
    ck(e[2].data == nil, "empty backpack slot2 has nil data")
    ck(e[5].data and e[5].data.id == 22157 and e[5].data.quality == 3, "backpack slot5 quality carried")
    ck(e[16].cid == 0 and e[16].slot == 16, "backpack slot16 is entry 16")
    ck(e[17].cid == 1 and e[17].slot == 1, "bag1 slot1 follows backpack (cid identity preserved)")
    ck(e[31].cid == 2 and e[31].slot == 1, "bag2 (cid 2) starts at entry 31")
    ck(e[37].cid == -2 and e[37].slot == 1, "keyring starts after the bags")
    -- every entry carries the owner record + a cid (never flattened)
    ck(e[1].owner == o and e[48].owner == o, "owner record on every entry")
    -- hidden bag removed from the flow
    local eh = Frame.BuildCombinedEntries(o, { showKeyring = true, hidden = { [1] = true } })
    ck(#eh == 48 - 14, "hiding bag1 removes its 14 slots")
end

local function testSplitGroups(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = fixtureOwner()
    local g = Frame.BuildSplitGroups(o, { showKeyring = true })
    ck(#g == 4, "4 split groups")
    ck(g[1].cid == 0 and g[1].class == "backpack" and g[1].size == 16, "group1 = backpack, size 16")
    ck(#g[1].entries == 16, "backpack group has 16 slot entries")
    ck(g[2].cid == 1 and g[2].link == "item:14046", "group2 = bag1 with its bag link")
    ck(g[3].size == 6 and #g[3].entries == 6, "group3 = 6-slot bag, 6 entries")
    ck(g[4].class == "keyring", "group4 = keyring")
    -- each group's entries all share that group's cid
    for _, e in ipairs(g[1].entries) do ck(e.cid == 0, "backpack group entries all cid 0") end
end

local function testGridAndWindowSize(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- GridDims fixed-band math (12 cols, 37px, 4 gap)
    local gd = Frame.GridDims(48, 12, 37, 4)
    ck(gd.cols == 12 and gd.rows == 4, "48 slots @12 cols = 4 rows")
    local expW = 12 * 37 + 11 * 4          -- 488
    ck(gd.width == expW, "band width = 12*37+11*4 = " .. expW)
    local expH = 4 * 37 + 3 * 4            -- 160
    ck(gd.height == expH, "grid height = 4*37+3*4 = " .. expH)
    ck(Frame.GridDims(0, 12, 37, 4).height == 0, "empty grid has 0 height")
    ck(Frame.GridDims(0, 12, 37, 4).width == expW, "empty grid keeps full band width (stable)")

    local o = fixtureOwner()
    -- Window self-size at 3 column widths, both layouts — never zero.
    for _, cols in ipairs({ 8, 12, 16 }) do
        for _, layout in ipairs({ "combined", "split" }) do
            local opts = { columns = cols, buttonSize = 37, gap = 4, showKeyring = true }
            local sz = Frame.ComputeWindowSize(o, layout, opts)
            ck(sz.width > 0 and sz.height > 0, layout .. "@" .. cols .. " window non-zero")
            local bandW = Frame.GridDims(0, cols, 37, 4).width
            ck(sz.width == bandW + Frame.PAD * 2, layout .. "@" .. cols .. " width = band + 2*pad")
        end
    end
    -- Combined vs split height differ (split adds per-group headers/gaps).
    local optsC = { columns = 12, buttonSize = 37, gap = 4, showKeyring = true }
    local hC = Frame.ComputeWindowSize(o, "combined", optsC).height
    local hS = Frame.ComputeWindowSize(o, "split", optsC).height
    ck(hS > hC, "split window taller than combined (headers + group gaps)")
    -- Exact combined content height check: 48 slots @12 = 4 rows = 160.
    local content = Frame.ComputeContentSize(o, "combined", optsC)
    ck(content.height == 160, "combined content height 160 (4 rows)")
end

local function testGeometryRoundTrip(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {}
    -- unset => centered defaults
    local p, rp, x, y = Frame.ReadGeometry(db)
    ck(p == "CENTER" and rp == "CENTER" and x == 0 and y == 0, "default geometry centered")
    Frame.WriteGeometry(db, "TOPLEFT", "TOPLEFT", 120, -340)
    local p2, rp2, x2, y2 = Frame.ReadGeometry(db)
    ck(p2 == "TOPLEFT" and rp2 == "TOPLEFT" and x2 == 120 and y2 == -340, "geometry round-trips")
    ck(db.framePoint == "TOPLEFT" and db.frameX == 120, "geometry keys are additive on the DB")
end

local function testApplyDefaults(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = { layout = "split", columns = 9 }   -- pre-existing values kept
    Frame.ApplyDefaults(db)
    ck(db.layout == "split", "existing layout not clobbered")
    ck(db.columns == 9, "existing columns not clobbered")
    ck(db.buttonSize == Frame.DEFAULT_BUTTONSIZE, "buttonSize default filled")
    ck(db.showKeyring == true, "showKeyring default filled")
    ck(type(db.hiddenBags) == "table", "hiddenBags map created")
end

-- W3: keyring enable gate (setting AND IsKeyRingEnabled), API-absent = enabled.
local function testKeyringGate(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Frame.KeyringGate(true, nil)   == true,  "setting on, API absent (headless) -> enabled")
    ck(Frame.KeyringGate(true, true)  == true,  "setting on, keyring enabled -> enabled")
    ck(Frame.KeyringGate(true, false) == false, "setting on, keyring DISABLED in game -> hidden")
    ck(Frame.KeyringGate(false, true) == false, "setting off -> hidden even when enabled")
    ck(Frame.KeyringGate(false, nil)  == false, "setting off, API absent -> hidden")
end

-- W3: keyring size is DYNAMIC — it follows the store's captured container size (which
-- capture re-scans on BAG_UPDATE), never a cached constant. Growing the stored keyring
-- must grow the rendered entry count with no other change (Expert C §5c quirk 3).
local function testKeyringDynamicSize(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = fixtureOwner()
    -- fixtureOwner's keyring (-2) is size 12; count keyring entries in the combined flow.
    local function keyringEntryCount()
        local n = 0
        for _, e in ipairs(Frame.BuildCombinedEntries(o, { showKeyring = true })) do
            if e.cid == Store.KEYRING_CONTAINER then n = n + 1 end
        end
        return n
    end
    ck(keyringEntryCount() == 12, "keyring renders its captured size (12)")
    -- Simulate a keyring upgrade: capture re-scans -2 to a larger size in the store.
    local key = Store.NewContainer(24)
    key.slots[1] = Store.NewSlot(5175, 1)
    Store.PutContainer(o, Store.KEYRING_CONTAINER, key, 200)
    ck(keyringEntryCount() == 24, "grown keyring (24) reflected immediately — size is store-driven")
    -- And it disappears entirely when the gate is off (setting/feature), not by size.
    ck(#Frame.CarriedContainerOrder(o, { showKeyring = false }) ==
       #Frame.CarriedContainerOrder(o, { showKeyring = true }) - 1, "gate off drops the keyring container")
end

-- W4.5: category-section content/window sizing (pure). A prebuilt section list
-- drives the size math the same way split groups do — one header band + grid per
-- section, stacked, gaps between; empty sections are pre-collapsed by the builder.
local function testCategorySectionSize(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function make(n) local t = {} for i = 1, n do t[i] = { cid = 0, slot = i, data = { id = i } } end return t end
    local sections = {
        { name = "Junk",        entries = make(2),  count = 2 },
        { name = "Consumables", entries = make(9),  count = 9 },
        { name = "Equipment",   entries = make(13), count = 13 },
    }
    local opts = { columns = 12, buttonSize = 37, gap = 4, sections = sections }
    local function gh(n) return Frame.GridDims(n, 12, 37, 4).height end
    local exp = Frame.SECTION_HDR_H + gh(2)
              + Frame.SECTION_GAP + Frame.SECTION_HDR_H + gh(9)
              + Frame.SECTION_GAP + Frame.SECTION_HDR_H + gh(13)
    local cs = Frame.ComputeContentSize(nil, "combined", opts)
    ck(cs.height == exp, "category content height = Σ(header+grid)+gaps, got " .. cs.height .. " exp " .. exp)
    ck(cs.width == Frame.GridDims(0, 12, 37, 4).width, "category width = full band")
    -- window adds chrome, stays non-zero and band-wide
    local ws = Frame.ComputeWindowSize(nil, "combined", opts)
    ck(ws.width == cs.width + Frame.PAD * 2, "category window width = band + 2*pad")
    ck(ws.height > cs.height, "category window taller than content (chrome added)")
    -- all-collapsed (no sections) => 0 content height, still a full-band width
    local cs0 = Frame.ComputeContentSize(nil, "combined", { columns = 12, buttonSize = 37, gap = 4, sections = {} })
    ck(cs0.height == 0 and cs0.width == Frame.GridDims(0, 12, 37, 4).width, "no visible sections -> 0 height, full band width")
end

-- W4.5: effective-mode gating — categories apply only to combined; split is
-- UNAFFECTED; the master toggle flips combined between sections and the flat grid.
local function testEffectiveMode(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    _G.DaseekiBags2DB = nil; _G.DaseekiBags2Data = nil; Store.Init()
    if ns.Rules and ns.Rules.ApplyDefaults then ns.Rules.ApplyDefaults(Store.db) end
    Store.db.layout = "combined"; Store.db.categoriesEnabled = true
    ck(Frame.CategoriesEnabled() == true, "categories enabled when flag on + engine present")
    ck(Frame.EffectiveMode() == "categories", "combined + categories on -> sections")
    Store.db.categoriesEnabled = false
    ck(Frame.CategoriesEnabled() == false, "master toggle off disables categories")
    ck(Frame.EffectiveMode() == "combined", "combined + categories off -> flat grid returns")
    Store.db.layout = "split"; Store.db.categoriesEnabled = true
    ck(Frame.EffectiveMode() == "split", "split is unaffected by the categories flag")
end

function Frame.RunSelfTests(verbose)
    local suites = {
        { name = "container order",     fn = testContainerOrder },
        { name = "combined entries",    fn = testCombinedEntries },
        { name = "split groups",        fn = testSplitGroups },
        { name = "grid + window size",  fn = testGridAndWindowSize },
        { name = "geometry round-trip", fn = testGeometryRoundTrip },
        { name = "apply defaults",      fn = testApplyDefaults },
        { name = "keyring gate",        fn = testKeyringGate },
        { name = "keyring dynamic size", fn = testKeyringDynamicSize },
        { name = "category section size", fn = testCategorySectionSize },
        { name = "effective mode",       fn = testEffectiveMode },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_frame/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_frame/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_frame", Frame.RunSelfTests)
end

return Frame
