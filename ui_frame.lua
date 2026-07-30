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

-- Grid cell metrics (1.0-LOOK PARITY). buttonSize matches the Classic item-button
-- footprint (37); gap is 1.x's cell pitch fact: skin\defaults spacing=2 => 39px pitch
-- = 37 + 2, the tight red-brown grid of the owner's 1.0 window. columns is the fixed
-- band width (stable layout > responsive reflow); 11 mirrors the owner's real 1.x
-- DaseekiBagsSets config (inventory columns = 11).
Frame.DEFAULT_COLUMNS    = 11
Frame.DEFAULT_BUTTONSIZE = 37
Frame.DEFAULT_GAP        = 2

-- Window chrome bands (px). Kept in one place so the pure size math and the in-game
-- arrange agree exactly. 1.0 anatomy: a compact TITLE row (gold "<Char>'s Inventory"
-- + top-right utility icon buttons + red X), then the equipped-bag ICON STRIP
-- (top-left cluster, wraps to rows), the tight item grid, and a bottom bar
-- (small icon L · "N/M" free/total counter C · money R). The 1.x modern toolbar band
-- is GONE — its controls relocated into the title-row icon cluster.
Frame.PAD         = 8    -- window inner padding (1.x inset ~8)
Frame.TITLE_H     = 26   -- title row: gold title + right-cluster icon buttons + close
Frame.STRIP_ICON  = 28   -- equipped-bag icon button (1.x Bag.Size 32, tightened to suite)
Frame.STRIP_GAP   = 4    -- 1.x bag pitch 36 = 32 + 4
Frame.ICONBTN     = 20   -- top-right utility icon buttons (search/owner/find/sort)
Frame.WINDOW_BG_ALPHA = 0.94   -- 1.0-parity near-solid dark ground (Bags-side, not theme-wide)
-- 1.0-parity strip icons (1.x Bag.StaticIcons): the backpack + keyring use their canonical
-- game textures instead of "B"/"K" glyphs. Backpack = fileID 130716 = Button-Backpack-Up.
Frame.ICON_BACKPACK = "Interface\\Buttons\\Button-Backpack-Up"
Frame.ICON_KEYRING  = "Interface\\ContainerFrame\\KeyRing-Bag-Icon"
Frame.STRIP_ICON_TRIM = 0.08   -- SetTexCoord trim to crop an icon's built-in border (suite icon treatment)
Frame.MONEY_H     = 20   -- bottom bar (slot icon · free/total · money)
Frame.VGAP        = 6     -- vertical gap between chrome bands
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
-- sections there). The additive DB flag (R3 default OFF — combined opens as one flat
-- grid) is owned by rules2.ApplyDefaults; absence/nil reads as OFF so the flat grid
-- is the default with or without a saved value.
function Frame.CategoriesEnabled()
    if not (ns.Rules and ns.Rules.SectionsForRender) then return false end
    local db = Store and Store.db
    if ns.Rules.Enabled then return ns.Rules.Enabled(db) end
    return db ~= nil and db.categoriesEnabled == true
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
-- One-time 1.0-parity DENSITY migration (mirrors rules2 default-flip).
--
-- The look-parity pass tightened the grid defaults (gap 4->2, columns 12->11) so 2.0
-- reads "essentially EXACTLY like 1.0". ApplyDefaults is additive and never clobbers
-- an existing value, so a pre-parity beta DB stays at the loose 4/12 and the owner
-- would NOT see the tight grid — against his directive. This migrates the density ONCE
-- for a DB still sitting at BOTH old defaults, UNLESS the user deliberately set a grid
-- value (db.densityUserChose, written by the Columns / Cell-gap sliders in options.lua).
-- Any value other than exactly the old 4/12 pair is treated as a genuine customization
-- and left untouched. Guarded by a one-time marker so a later deliberate 4/12 (or any
-- opt-out) is never re-clobbered on a subsequent login. Idempotent.
----------------------------------------------------------------------

Frame.DENSITY_MARKER      = "densityMigrated"
Frame.OLD_DEFAULT_GAP     = 4    -- pre-parity loose gap
Frame.OLD_DEFAULT_COLUMNS = 12   -- pre-parity column band

function Frame.MigrateDensity(db)
    if type(db) ~= "table" then return false end
    if db[Frame.DENSITY_MARKER] then return false end   -- already migrated (one-time)
    local migrated = false
    if not db.densityUserChose
       and db.gap     == Frame.OLD_DEFAULT_GAP
       and db.columns == Frame.OLD_DEFAULT_COLUMNS then
        db.gap     = Frame.DEFAULT_GAP       -- 2  (1.0 cell pitch 39 = 37 + 2)
        db.columns = Frame.DEFAULT_COLUMNS   -- 11 (owner's real DaseekiBagsSets config)
        migrated = true
    end
    db[Frame.DENSITY_MARKER] = true
    return migrated
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
-- PURE: bag-slot STRIP enumeration + button-state matrix (bag management)
--
-- The toggle strip is also the bag-slot MANAGER (1.x parity, frames/inventory bag
-- behavior fact). Two facts drive it:
--   * For the LIVE self owner the strip lists EVERY real inventory bag slot
--     1..NumBagSlots — INCLUDING empty ones — so a newly-looted bigger bag has a
--     slot to be dropped onto (the owner's miss: an empty slot had no button, so
--     there was no way to equip). Backpack (0) and keyring (-2) frame it as pure
--     toggles (never equippable, BRAND_SPEC intent).
--   * For a CACHED/remote alt you can't equip anything, so the strip stays the old
--     owned-container toggle list (management disabled).
----------------------------------------------------------------------

-- Ordered strip entries: { cid, role="backpack"|"bag"|"keyring", manageable=bool }.
--   opts = { live=bool, showKeyring=bool, numBagSlots=<n> (test override) }
function Frame.StripSlots(owner, opts)
    opts = opts or {}
    local live        = opts.live and true or false
    local showKeyring = (opts.showKeyring ~= false)
    local n           = opts.numBagSlots or Store.NumBagSlots()
    local slots = {}
    slots[#slots + 1] = { cid = Store.BACKPACK_CONTAINER, role = "backpack", manageable = false }
    if live then
        -- Every equip slot, empty or not — the manager needs a target for each.
        for s = 1, n do slots[#slots + 1] = { cid = s, role = "bag", manageable = true } end
    else
        -- Cached alt: only the bags they actually own, toggle-only (no equip target).
        local ids = {}
        if owner and type(owner.containers) == "table" then
            for s = 1, n do if owner.containers[s] then ids[#ids + 1] = s end end
        end
        table.sort(ids)
        for _, s in ipairs(ids) do slots[#slots + 1] = { cid = s, role = "bag", manageable = false } end
    end
    if showKeyring then slots[#slots + 1] = { cid = Store.KEYRING_CONTAINER, role = "keyring", manageable = false } end
    return slots
end

-- Decide how a strip button presents + behaves given live facts. Pure so the whole
-- equipped/empty/toggled × cursor × combat matrix is harness-locked.
--   ctx = { role, manageable, equipped, toggledOff, cursorBag, inCombat }
-- returns {
--   manageable, role, equipped, toggledOff,
--   showPlus,     -- faint "+" equip affordance (empty manageable slot; hover/drag only)
--   clickAction,  -- "equip" | "toggle" | "none" | "blocked-combat"
--   dragAction,   -- "pickup" | "blocked-combat" | nil   (only when a bag is equipped)
--   dropAction,   -- "equip"  | "blocked-combat" | nil   (only on a manageable slot)
-- }
-- Rules: management is gated to manageable (numbered, live-self) slots. A bag on the
-- cursor turns a click/drop into an EQUIP/REPLACE; combat downgrades every equip/pickup
-- to "blocked-combat" (bag equip is protected in combat — we defer with a message).
-- Backpack/keyring/cached bags are pure toggles.
function Frame.StripButtonState(ctx)
    ctx = ctx or {}
    local manageable = ctx.manageable and true or false
    local equipped   = ctx.equipped and true or false
    local cursorBag  = ctx.cursorBag and true or false
    local inCombat   = ctx.inCombat and true or false

    local clickAction, dragAction, dropAction
    if manageable then
        dropAction = inCombat and "blocked-combat" or "equip"
        if cursorBag then
            clickAction = inCombat and "blocked-combat" or "equip"
        elseif equipped then
            clickAction = "toggle"           -- hide/show this bag's items in the grid
        else
            clickAction = "none"             -- empty slot, nothing on cursor: inert click
        end
        if equipped then
            dragAction = inCombat and "blocked-combat" or "pickup"
        end
    else
        clickAction = "toggle"               -- backpack / keyring / cached bag
    end

    return {
        manageable  = manageable,
        role        = ctx.role,
        equipped    = equipped,
        toggledOff  = ctx.toggledOff and true or false,
        showPlus    = manageable and not equipped,
        clickAction = clickAction,
        dragAction  = dragAction,
        dropAction  = dropAction,
    }
end

-- PURE: does the cursor hold an equippable BAG? `kind` is GetCursorInfo()'s first
-- return; `equipLoc` is GetItemInfoInstant(id)'s equip location. The strip's equip
-- affordance must key off an actual bag — CursorHasItem() alone is true for ANY item,
-- so a non-bag on the cursor wrongly read as an equip payload. GetCursorInfo("item")
-- + INVTYPE_BAG is the reliable holds-a-bag check (catalog-verified 1.15.9).
function Frame.CursorIsBag(kind, equipLoc)
    if kind ~= "item" then return false end
    return equipLoc == "INVTYPE_BAG"
end

-- PURE: cross-account gold tooltip lines. Ordered { label, copper, isTotal }: the
-- "All characters" grand total first, then each account by copper desc then label asc.
-- Harness-locked so the money tooltip content is provable; the live OnEnter only
-- formats copper into coin strings.
function Frame.BuildMoneyLines(total, byAccount)
    local lines = { { label = "All characters", copper = total or 0, isTotal = true } }
    local accts = {}
    for acct, copper in pairs(byAccount or {}) do
        accts[#accts + 1] = { label = (acct ~= "" and acct) or "Unlinked", copper = copper or 0 }
    end
    table.sort(accts, function(a, b)
        if a.copper ~= b.copper then return a.copper > b.copper end
        return tostring(a.label) < tostring(b.label)
    end)
    for _, a in ipairs(accts) do lines[#lines + 1] = a end
    return lines
end

-- PURE: the 1.0 Money-tooltip structure (playerMoney.lua parity). Builds an ordered row
-- list from per-character descriptors:
--   chars = { { name, class, account, copper }, ... }
--   opts  = { selfAccount, minCopper (default 0, from moneyTooltipMinGold*10000),
--             maxPerGroup (default 5) }
-- Behavior matched from 1.x: characters split into THIS account ("mine") vs OTHER accounts;
-- within each group, money>0 AND >=minCopper, sorted by copper DESC then name; the first
-- `maxPerGroup` shown, the rest summed into one "Others" rollup line; the Other-Accounts
-- group is preceded by a spacer + an "Other Accounts" section header; a "Total" footer holds
-- the grand total of every character. Row kinds: "char" | "others" | "spacer" | "section" |
-- "total". Harness-locked so the tooltip content is provable; the live render only colors +
-- coin-formats.
function Frame.BuildMoneyReport(chars, opts)
    opts = opts or {}
    local selfAccount = opts.selfAccount
    local minCopper   = opts.minCopper or 0
    local maxPerGroup = opts.maxPerGroup or 5
    local haveSelf    = (selfAccount ~= nil and selfAccount ~= "")

    local mine, others, total = {}, {}, 0
    for _, c in ipairs(chars or {}) do
        local copper = c.copper or 0
        total = total + copper
        if copper > 0 and copper >= minCopper then
            local acct = c.account or ""
            local isMine = (not haveSelf) or (acct == selfAccount)
            local row = { kind = "char", name = c.name or "?", class = c.class, account = acct, copper = copper }
            if isMine then mine[#mine + 1] = row else others[#others + 1] = row end
        end
    end
    local function sortGroup(g)
        table.sort(g, function(a, b)
            if a.copper ~= b.copper then return a.copper > b.copper end
            return tostring(a.name):lower() < tostring(b.name):lower()
        end)
    end
    sortGroup(mine); sortGroup(others)

    local rows = {}
    local function emitGroup(g)
        local overflow = 0
        for i, row in ipairs(g) do
            if i <= maxPerGroup then rows[#rows + 1] = row
            else overflow = overflow + row.copper end
        end
        if overflow > 0 then rows[#rows + 1] = { kind = "others", copper = overflow } end
    end
    emitGroup(mine)
    if #others > 0 then
        rows[#rows + 1] = { kind = "spacer" }
        rows[#rows + 1] = { kind = "section", label = "Other Accounts" }
        emitGroup(others)
    end
    rows[#rows + 1] = { kind = "total", copper = total }
    return rows
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

----------------------------------------------------------------------
-- PURE: 1.0-anatomy helpers (title text, free/total counter, bag-strip geometry).
-- All headless-tested so the window self-size and the rendered chrome agree exactly.
----------------------------------------------------------------------

-- Window title, 1.x TitleBags format ("<Character>'s Inventory"). A blank/nil name
-- (pre-capture / headless) falls back to the plain wordmark.
function Frame.WindowTitle(name)
    if type(name) == "string" and name ~= "" then return name .. "'s Inventory" end
    return "Bags"
end

-- Free / total carried slot counts for the bottom-bar "N/M" counter (1.x SlotCount:
-- text = free .. "/" .. total). Counts the SAME containers the grid shows (respects the
-- hidden set + keyring gate via CarriedContainerOrder). Pure: reads the store snapshot,
-- no live C_Container — so it works for a cached alt too. total = Σ size; free = empties.
function Frame.SlotCounts(owner, opts)
    local free, total = 0, 0
    if owner and type(owner.containers) == "table" then
        for _, cid in ipairs(Frame.CarriedContainerOrder(owner, opts)) do
            local c = owner.containers[cid]
            local size = c.size or 0
            total = total + size
            for s = 1, size do if c.slots[s] == nil then free = free + 1 end end
        end
    end
    return free, total
end

-- How many bag-strip icon buttons fit across a band of width `bandW`. >= 1 always.
function Frame.StripPerRow(bandW, iconSize, gap)
    iconSize = iconSize or Frame.STRIP_ICON
    gap      = gap or Frame.STRIP_GAP
    if not bandW or bandW <= 0 then return 1 end
    return math.max(1, math.floor((bandW + gap) / (iconSize + gap)))
end

-- Row count for `nStrip` bag buttons at `perRow` (min one row so the band is never 0-tall).
function Frame.StripRows(nStrip, perRow)
    nStrip = math.max(0, nStrip or 0)
    perRow = math.max(1, perRow or 1)
    if nStrip <= perRow then return 1 end
    return math.ceil(nStrip / perRow)
end

-- Bag-strip band height for `nStrip` buttons across a `bandW`-wide window. The 1.0
-- cluster wraps to a second row only when the bags overflow the band (usually one row).
function Frame.StripBandHeight(nStrip, bandW, iconSize, gap)
    iconSize = iconSize or Frame.STRIP_ICON
    gap      = gap or Frame.STRIP_GAP
    local rows = Frame.StripRows(nStrip, Frame.StripPerRow(bandW, iconSize, gap))
    return rows * iconSize + (rows - 1) * gap
end

-- The bag-strip button count for window sizing — same enumeration the render uses
-- (StripSlots), so the pre-computed band height matches the laid-out cluster.
function Frame.StripCount(owner, opts)
    opts = opts or {}
    return #Frame.StripSlots(owner, {
        live        = opts.live,
        showKeyring = (opts.showKeyring ~= false),
        numBagSlots = opts.numBagSlots,
    })
end

-- Full window size (content + all 1.0 chrome bands). Returns { width, height }.
-- The in-game arrange positions bands to these exact numbers, so a static test of
-- this function proves the rendered window is never zero-sized. Bands (top→bottom):
--   TITLE_H · VGAP · [bag strip, dynamic rows] · VGAP · content · VGAP · MONEY_H · PAD
function Frame.ComputeWindowSize(owner, layout, opts)
    opts = opts or {}
    local content = Frame.ComputeContentSize(owner, layout, opts)
    local stripH  = Frame.StripBandHeight(Frame.StripCount(owner, opts), content.width)
    local w = content.width + Frame.PAD * 2
    local h = Frame.TITLE_H
            + Frame.VGAP
            + stripH          + Frame.VGAP
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

-- Format copper as a coin-ICON string in-game (g/s/c coin textures — 1.0 parity); plain
-- g/s/c headless-safe.
local function moneyString(copper)
    if _G.GetCoinTextureString then return _G.GetCoinTextureString(copper or 0) end
    local g, s, c = Store.MoneyParts(copper or 0)
    return string.format("%dg %ds %dc", g, s, c)
end

-- Class-color for a money row's character name (RAID_CLASS_COLORS; cream fallback).
local function classColor(class)
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    if UI and UI.Color then return UI.Color("text") end
    return 0.9294, 0.9020, 0.8706
end

-- Live per-character money descriptors from the store (for the Money tooltip).
function Frame.MoneyChars()
    local out = {}
    if Store and Store.ForEachOwner then
        Store.ForEachOwner(function(_, o)
            out[#out + 1] = { name = o.name or "?", class = o.class, account = o.account or "", copper = o.money or 0 }
        end)
    end
    return out
end

-- Render the 1.0-format cross-character Money tooltip into GT: "Money" header, class-colored
-- per-character rows with right-aligned coin-icon amounts, an "Others" rollup, an "Other
-- Accounts" section, and a grey "Total" footer. Shared by the inventory + bank money bars so
-- the two read identically. Content comes from the pure Frame.BuildMoneyReport.
function Frame.RenderMoneyTooltip(GT)
    if not GT then return end
    local function tok(name) if UI and UI.Color then return UI.Color(name) end return 1, 1, 1 end
    GT:ClearLines()
    GT:AddLine(_G.MONEY or "Money", tok("text"))
    local selfAccount = Store and Store.data and Store.data.selfAccount
    local minGold     = (Store and Store.db and Store.db.moneyTooltipMinGold) or 0
    local rows = Frame.BuildMoneyReport(Frame.MoneyChars(), {
        selfAccount = selfAccount, minCopper = (minGold or 0) * 10000, maxPerGroup = 5,
    })
    for _, row in ipairs(rows) do
        if row.kind == "char" then
            local r, g, b = classColor(row.class)
            GT:AddDoubleLine(row.name, moneyString(row.copper), r, g, b, r, g, b)
        elseif row.kind == "others" then
            local mr, mg, mb = tok("muted")
            GT:AddDoubleLine("Others", moneyString(row.copper), mr, mg, mb, mr, mg, mb)
        elseif row.kind == "spacer" then
            GT:AddLine(" ")
        elseif row.kind == "section" then
            local fr, fg, fb = tok("faint")
            GT:AddLine(row.label, fr, fg, fb)
        elseif row.kind == "total" then
            local mr, mg, mb = tok("muted")
            GT:AddDoubleLine(_G.TOTAL or "Total", moneyString(row.copper), mr, mg, mb, mr, mg, mb)
        end
    end
    GT:Show()
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
        -- 1.0 PARITY (opacity): force a near-solid dark ground (Bags-side alpha, so the
        -- theme's ground token stays frosted for other addons). 1.x read almost solid at
        -- black @0.85α; 0.94 matches that heavier, "not see-through" body.
        self:SetBackdropColor(UI.Color("ground", Frame.WINDOW_BG_ALPHA))
        -- Dark edge under the bronze keyline; borderLite was the beta's bright-rim
        -- culprit (§1), so the visible frame edge is the aged keyline, not this.
        self:SetBackdropBorderColor(UI.Color("border"))
    end)
    -- Field Ledger material (BRAND_SPEC §4): grain substrate + aged-edge vignette +
    -- ONE bronze keyline. Guarded — a Core without the Phase-0 kit simply skips it.
    if UI.PaintLedgerGround then UI.PaintLedgerGround(win) end
    -- ESC closes it (FrameXML special-frame list; proven by Daseeki-Core hub).
    if _G.UISpecialFrames then table.insert(_G.UISpecialFrames, WINDOW_NAME) end

    -- ── Title row (1.0 anatomy): gold "<Char>'s Inventory" + top-right icon cluster
    --    (search · owner · find · sort) + red X. Drag to move; RIGHT-CLICK flips the
    --    combined/split layout (the modern segmented control relocated here — see
    --    Frame.SetLayout; also reachable from the options panel). ────────────────
    local titleBar = _G.CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLE_H)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing(); saveGeometry(win) end)
    titleBar:SetScript("OnMouseUp", function(_, mb)
        if mb == "RightButton" then
            Frame.SetLayout(Frame.Layout() == "split" and "combined" or "split")
        end
    end)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbBg:SetPoint("TOPLEFT", titleBar, "TOPLEFT", 1, -1)
    tbBg:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -1, 0)
    UI.Skin(tbBg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    -- Maker's mark — the ONE diamond on this window (BRAND_SPEC §4/§5), titlebar only.
    local mark
    if UI.MakerMark then
        mark = UI.MakerMark(titleBar, { size = 16 })
        mark:SetPoint("LEFT", titleBar, "LEFT", 7, 0)
        win.makerMark = mark
    end

    -- Title in warm GOLD (1.x TitleBags: GameFontNormalLeft gold). The framework ships
    -- no gold-tinted font object, so we set the "warn" token (#FFD100) explicitly on the
    -- ceremonial wordmark. Text is filled per viewed owner in Rebuild (WindowTitle).
    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.ceremonial or UI.fonts.header)
    if mark then title:SetPoint("LEFT", mark, "RIGHT", 7, 0)
    else         title:SetPoint("LEFT", titleBar, "LEFT", 9, 0) end
    title:SetText(Frame.WindowTitle(nil))
    UI.Skin(title, function(self) self:SetTextColor(UI.Color("warn")) end)   -- gold title (1.0)
    win.title = title

    -- Small square icon button factory for the title-row utility cluster. Each is a
    -- theme-skinned BackdropTemplate button rendering either a texture or a glyph, with
    -- a naming tooltip (1.0 had small icon menu buttons). Pure child textures — no
    -- protected op. Returns the button.
    local function makeIconButton(spec)
        local b = _G.CreateFrame("Button", nil, titleBar, "BackdropTemplate")
        b:SetSize(Frame.ICONBTN, Frame.ICONBTN)
        b:RegisterForClicks("LeftButtonUp")
        local face
        if spec.texture then
            face = b:CreateTexture(nil, "ARTWORK")
            face:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
            face:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
            face:SetTexture(spec.texture)
        else
            face = b:CreateFontString(nil, "OVERLAY")
            face:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
            face:SetPoint("CENTER", b, "CENTER", 0, 0)
            face:SetText(spec.glyph or "?")
        end
        b._face = face
        b._applySkin = function()
            b:SetBackdrop(UI.FLAT_BACKDROP)
            b:SetBackdropColor(UI.Color("control"))
            b:SetBackdropBorderColor(UI.Color("controlBorder"))
            if face.SetVertexColor and spec.texture then face:SetVertexColor(UI.Color("muted"))
            elseif face.SetTextColor then face:SetTextColor(UI.Color("muted")) end
        end
        UI.Skin(b, function() b._applySkin() end)
        b:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(UI.Color("brand"))
            if _G.GameTooltip and spec.tooltip then
                _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                _G.GameTooltip:SetText(spec.tooltip, UI.Color("text"))
                if spec.tooltip2 then _G.GameTooltip:AddLine(spec.tooltip2, UI.Color("muted")) end
                _G.GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(UI.Color("controlBorder"))
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        if spec.onClick then b:SetScript("OnClick", spec.onClick) end
        return b
    end

    local closeBtn = _G.CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY")
    cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    cx:SetText("X")
    UI.Skin(cx, function(self) self:SetTextColor(UI.Color("danger")) end)   -- red X (1.0)
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body); if cx.SetTextColor then cx:SetTextColor(UI.Color("danger")) end end)
    closeBtn:SetScript("OnClick", function() Frame.Close() end)

    -- Right cluster, laid right→left from the close button: search · sort · find · owner.
    local magBtn = makeIconButton({
        texture = "Interface\\Common\\UI-Searchbox-Icon",   -- the game's own magnifier (1.0 look)
        tooltip = "Search these bags", tooltip2 = "Filter the grid as you type",
        onClick = function() Frame.ToggleSearch() end,
    })
    magBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    win.magBtn = magBtn

    local sortBtn = makeIconButton({
        glyph = "\226\134\147",   -- down-arrow ↓
        tooltip = "Sort bags", tooltip2 = "Merge stacks and arrange by type",
        onClick = function() if ns.Sort and ns.Sort.Run then ns.Sort.Run(ns.Sort.CarriedBagIDs()) end end,
    })
    sortBtn:SetPoint("RIGHT", magBtn, "LEFT", -4, 0)
    win.sortBtn = sortBtn

    local findBtn = makeIconButton({
        glyph = "\226\137\161",   -- triple-bar ≡ (list across characters)
        tooltip = "Find an item", tooltip2 = "Search across all your characters",
        onClick = function() if ns.Find and ns.Find.Toggle then ns.Find.Toggle(win.searchBox and win.searchBox:GetText()) end end,
    })
    findBtn:SetPoint("RIGHT", sortBtn, "LEFT", -4, 0)
    win.findBtn = findBtn

    -- Owner selector (W3): compact flyout trigger in the icon cluster. Selecting an
    -- alt/remote owner flips the SHARED viewed-owner state (Frame.SetViewedOwner),
    -- re-rendering this window (and the bank) read-only.
    if ns.Owner and ns.Owner.CreateSelector then
        local sel = ns.Owner.CreateSelector(titleBar, {
            width = 26,   -- compact: reads as an icon-ish pip+caret trigger
            onSelect = function(key) Frame.SetViewedOwner(key) end,
        })
        if sel then
            sel:ClearAllPoints()
            sel:SetPoint("RIGHT", findBtn, "LEFT", -4, 0)
            sel:SetHeight(Frame.ICONBTN)
            win.ownerSelector = sel
        end
    end

    -- Collapsed inline SEARCH box (1.0: search lived behind a toggle, not a standing
    -- toolbar). Hidden until the magnifier opens it; grows leftward from the cluster.
    local searchWrap = UI.FlatFrame(titleBar, "inset", "controlBorder")
    searchWrap:SetSize(150, 18)
    searchWrap:SetPoint("RIGHT", magBtn, "LEFT", -4, 0)
    searchWrap:Hide()
    local search = _G.CreateFrame("EditBox", nil, searchWrap)
    search:SetPoint("TOPLEFT", searchWrap, "TOPLEFT", 6, 0)
    search:SetPoint("BOTTOMRIGHT", searchWrap, "BOTTOMRIGHT", -6, 0)
    search:SetAutoFocus(false)
    search:SetFontObject(UI.fonts.body)
    search:SetScript("OnEscapePressed", function(self)
        self:SetText("")                                   -- clear + restore all items
        if ns.Search then ns.Search.SetQuery("") end
        self:ClearFocus()
        Frame.ToggleSearch(false)
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
    win.searchBox  = search
    win.searchWrap = searchWrap

    -- One entry-head hairline under the titlebar (§3), pixel-snapped when the Phase-0
    -- kit is present so it stays crisp at 720p; plain texture otherwise.
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

    -- ── Bag-slot ICON STRIP (1.0 top-left cluster): equipped-bag icons with counts;
    --    also the bag-slot manager (equip / toggle). Wraps to rows; height set in
    --    RebuildStrip from the pure StripBandHeight math. ────────────────────────
    local strip = _G.CreateFrame("Frame", nil, win)
    strip:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, -(TITLE_H + Frame.VGAP))
    strip:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, -(TITLE_H + Frame.VGAP))
    strip:SetHeight(Frame.STRIP_ICON)
    win.strip = strip
    win._stripButtons = {}

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
    -- Defensive mouse wiring: explicitly enable mouse and float the money bar ABOVE the
    -- content grid's frame-level stack so a hover always lands on it (the owner reported
    -- the gold hover doing nothing). Buttons enable mouse by default, but the reskin path
    -- makes this explicit and re-asserts it so nothing can silently drop the hover.
    money:EnableMouse(true)
    money:SetFrameLevel((win:GetFrameLevel() or 1) + 10)
    local moneyFS = money:CreateFontString(nil, "OVERLAY")
    moneyFS:SetFontObject(UI.fonts.numeral or UI.fonts.body)   -- ARIALN numerals (§3)
    moneyFS:SetPoint("RIGHT", money, "RIGHT", 0, 0)
    moneyFS:SetJustifyH("RIGHT")
    -- Warm cream, not bright white — "gold is sacred" but rendered on-brand (§2/§3).
    UI.Skin(moneyFS, function(self) self:SetTextColor(UI.Color("text")) end)
    -- 1.0-format cross-character Money tooltip (D1 sacred): "Money" header · class-colored
    -- per-character coin rows · Others rollup · Other Accounts section · Total footer.
    money:SetScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        Frame.RenderMoneyTooltip(_G.GameTooltip)
    end)
    money:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)
    win.money   = money
    win.moneyFS = moneyFS

    -- Free/total slot counter, bottom-CENTER (1.x SlotCount: "free/total"). Condensed
    -- numerals, muted so the grid stays the focus (attention inversion). Filled per
    -- viewed owner in Rebuild via the pure Frame.SlotCounts.
    local slotCount = win:CreateFontString(nil, "OVERLAY")
    slotCount:SetFontObject(UI.fonts.numeral or UI.fonts.body)   -- ARIALN numerals (§3)
    slotCount:SetPoint("BOTTOM", win, "BOTTOM", 0, PAD)
    slotCount:SetJustifyH("CENTER")
    UI.Skin(slotCount, function(self) self:SetTextColor(UI.Color("muted")) end)
    win.slotCount = slotCount

    -- Small icon, bottom-LEFT (1.0): a quiet bag glyph that opens the options panel.
    local footIcon = _G.CreateFrame("Button", nil, win)
    footIcon:SetSize(18, 18)
    footIcon:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", PAD, PAD)
    local fi = footIcon:CreateTexture(nil, "ARTWORK")
    fi:SetAllPoints(footIcon)
    fi:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
    footIcon:SetScript("OnEnter", function(self)
        if fi.SetVertexColor then fi:SetVertexColor(UI.Color("text")) end
        if _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            _G.GameTooltip:SetText("Bag options", UI.Color("text"))
            _G.GameTooltip:AddLine("Open settings · right-click title toggles combined/split", UI.Color("muted"))
            _G.GameTooltip:Show()
        end
    end)
    footIcon:SetScript("OnLeave", function() if fi.SetVertexColor then fi:SetVertexColor(UI.Color("muted")) end if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    footIcon:SetScript("OnClick", function()
        -- Options live in the Daseeki suite hub (options.lua RegisterAddon id="bags").
        -- Try the hub's open surface defensively; guarded so a name mismatch just no-ops.
        local S = _G.DaseekiSuite
        if S then
            if     S.OpenTo then S:OpenTo("bags")
            elseif S.Open   then S:Open("bags")
            elseif S.Toggle then S:Toggle("bags") end
        end
    end)
    UI.Skin(fi, function(self) self:SetVertexColor(UI.Color("muted")) end)
    win.footIcon = footIcon

    Frame.window = win
    restoreGeometry(win)
    return win
end

----------------------------------------------------------------------
-- Bag-slot MANAGEMENT (frame layer; every WoW API guarded on _G).
--
-- Insecure + hardware-event-driven (OnClick / OnReceiveDrag / OnDragStart) — the
-- taint-safe surface (bags are NOT part of the secure action system on Classic Era;
-- 1.x-proven, frames/inventory bag behavior fact). The cursor ops PutItemInBag /
-- PickupBagFromSlot require a hardware event, which those handlers supply; NO protected
-- op on any secure frame runs here, and equip/pickup are combat-gated (bag equip is
-- protected in combat — we defer with a plain message). Catalog-verified against
-- wow-api-catalog/1.15.9.68808: C_Container.ContainerIDToInventoryID, PutItemInBag,
-- PickupBagFromSlot, GetInventoryItemLink, IsInventoryItemLocked, CursorHasItem,
-- InCombatLockdown.
----------------------------------------------------------------------

-- The inventory (equip) slot for a carried bag container (1..N), else nil.
local function bagInventorySlot(cid)
    if type(cid) ~= "number" or cid < 1 then return nil end
    local CC = _G.C_Container
    if CC and CC.ContainerIDToInventoryID then return CC.ContainerIDToInventoryID(cid) end
    if _G.ContainerIDToInventoryID then return _G.ContainerIDToInventoryID(cid) end
    return nil
end

-- Live "is a bag equipped in this inventory slot" (authoritative even before capture
-- re-snapshots the store on the next BAG_UPDATE).
local function bagEquippedLink(slot)
    if slot and _G.GetInventoryItemLink then return _G.GetInventoryItemLink("player", slot) end
    return nil
end

-- Live: is the cursor holding an actual BAG (the only valid strip equip payload)?
-- GetCursorInfo("item") + GetItemInfoInstant(equipLoc) is the reliable check; falls
-- back to CursorHasItem() only where GetCursorInfo is unavailable, and stays permissive
-- when the held item can't be classified (never worse than the old behavior).
local function cursorHasBag()
    if _G.GetCursorInfo then
        local kind, id = _G.GetCursorInfo()
        if kind ~= "item" then return false end
        local gii = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
        if gii and id then
            local _, _, _, equipLoc = gii(id)
            if equipLoc ~= nil then return Frame.CursorIsBag(kind, equipLoc) end
        end
        return true   -- item on cursor but unclassifiable: permissive
    end
    return (_G.CursorHasItem and _G.CursorHasItem()) and true or false
end

local function stripInCombat()
    return (_G.InCombatLockdown and _G.InCombatLockdown()) and true or false
end

-- Plain deferred-in-combat notice (no error spam; one concise line + a soft decline cue).
function Frame.NotifyBagCombatBlocked()
    if ns and ns.Print then ns:Print("Can't equip or swap bags while in combat — try again after combat.") end
    if _G.PlaySound and _G.SOUNDKIT then _G.PlaySound(_G.SOUNDKIT.IG_PLAYER_INVITE_DECLINE or 847) end
end

-- Live facts -> resolved strip state for a button.
local function stripStateNow(b)
    local db = Store.db
    return Frame.StripButtonState({
        role       = b._role,
        manageable = b._manageable,
        equipped   = (b._slot ~= nil) and (bagEquippedLink(b._slot) ~= nil) or false,
        toggledOff = (db and db.hiddenBags and db.hiddenBags[b._cid]) and true or false,
        cursorBag  = cursorHasBag(),
        inCombat   = stripInCombat(),
    })
end

-- Execute a resolved action (from Frame.StripButtonState) for one strip button.
local function runStripAction(action, cid, slot)
    if action == "toggle" then
        local db = Store.db
        if db then
            db.hiddenBags = db.hiddenBags or {}
            db.hiddenBags[cid] = (not db.hiddenBags[cid]) or nil
            Frame.Rebuild()
        end
    elseif action == "equip" then
        if slot and _G.PutItemInBag then _G.PutItemInBag(slot) end   -- equips/replaces the cursor bag (native swap)
    elseif action == "pickup" then
        if slot and _G.PickupBagFromSlot then
            if _G.PlaySound and _G.SOUNDKIT then _G.PlaySound(_G.SOUNDKIT.IG_BACKPACK_OPEN or 862) end
            _G.PickupBagFromSlot(slot)
        end
    elseif action == "blocked-combat" then
        Frame.NotifyBagCombatBlocked()
    end
    -- "none"/nil => inert
end

-- Strip tooltip: the equipped bag (name/size via SetInventoryItem) or "No bag equipped",
-- plus the context instruction. Quiet by default; the affordance copy appears on hover.
local function stripTooltip(b)
    local GT = _G.GameTooltip
    if not GT then return end
    GT:SetOwner(b, "ANCHOR_RIGHT")
    GT:ClearLines()
    local st = stripStateNow(b)
    if b._role == "backpack" then
        GT:SetText("Backpack", UI.Color("text"))
        GT:AddLine(st.toggledOff and "Click to show its items" or "Click to hide its items", UI.Color("muted"))
    elseif b._role == "keyring" then
        GT:SetText("Keyring", UI.Color("text"))
        GT:AddLine(st.toggledOff and "Click to show its keys" or "Click to hide its keys", UI.Color("muted"))
    elseif st.manageable then
        if st.equipped then
            if b._slot and GT.SetInventoryItem then GT:SetInventoryItem("player", b._slot) end
            GT:AddLine(st.cursorBag and "Click to replace this bag"
                or "Drag out to unequip · Left-click to hide/show its items", UI.Color("muted"))
        else
            GT:SetText("No bag equipped", UI.Color("text"))
            GT:AddLine(st.cursorBag and "Click to equip the bag on your cursor"
                or "Drag a bag here to equip it", UI.Color("muted"))
        end
    else
        -- cached alt bag: its own tooltip when a link is cached.
        local owner = Frame.ViewedOwner()
        local c = owner and owner.containers and owner.containers[b._cid]
        if c and c.link and GT.SetHyperlink then GT:SetHyperlink(c.link)
        else GT:SetText("Bag " .. tostring(b._cid), UI.Color("text")) end
    end
    GT:Show()
end

-- Rebuild the bag-slot strip for the viewed owner. For the LIVE self it is the bag
-- MANAGER (every equip slot 1..N incl. empty ones — drag/drop or click-with-cursor to
-- equip/replace, drag-out to unequip). For a cached alt it is the old toggle-only list.
function Frame.RebuildStrip()
    local win = Frame.window
    if not win or not UI then return end
    local owner = Frame.ViewedOwner()
    local db = Store.db
    local hidden = (db and db.hiddenBags) or {}
    local live = (ns.Items and ns.Items.IsLive and ns.Items.IsLive(owner)) and true or false

    for _, b in ipairs(win._stripButtons) do b:Hide() end

    local slots = Frame.StripSlots(owner, { live = live, showKeyring = Frame.KeyringEnabled() })
    local SIZE, GAP = Frame.STRIP_ICON, Frame.STRIP_GAP
    -- 1.0 top-left cluster: wrap the bag icons across the band, growing downward.
    local bandW  = (win.strip:GetWidth() or 0)
    if bandW <= 0 then bandW = Frame.GridDims(0, Frame.Columns(), Frame.ButtonSize(), Frame.Gap()).width end
    local perRow = Frame.StripPerRow(bandW, SIZE, GAP)
    win.strip:SetHeight(Frame.StripBandHeight(#slots, bandW, SIZE, GAP))
    for i, entry in ipairs(slots) do
        local cid = entry.cid
        local b = win._stripButtons[i]
        if not b then
            b = _G.CreateFrame("Button", nil, win.strip, "BackdropTemplate")
            b:SetSize(SIZE, SIZE)
            b:RegisterForClicks("LeftButtonUp")
            b:RegisterForDrag("LeftButton")
            -- Equipped-bag ICON (R3 design point 2): the numbered strip buttons show the
            -- equipped bag's item texture, trimmed of its built-in border to match the
            -- suite icon treatment. Sits UNDER the number/underline/plus (ARTWORK layer);
            -- hidden until an icon resolves so backpack/keyring/empty keep their glyph.
            -- Pure art on an insecure child texture — never a protected op on the button.
            local icon = b:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
            icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
            local t = Frame.STRIP_ICON_TRIM
            icon:SetTexCoord(t, 1 - t, t, 1 - t)
            icon:Hide()
            b._icon = icon
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
            -- Faint "+" equip affordance for an empty slot — hover/drag only, NOT standing
            -- decoration (BRAND_SPEC quiet-until-needed). Overlays the number when shown.
            local plus = b:CreateFontString(nil, "OVERLAY")
            plus:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
            plus:SetPoint("CENTER", b, "CENTER", 0, 0)
            plus:SetText("+")
            plus:Hide()
            b._plus = plus
            -- Item COUNT (1.0: "bag/keyring icon buttons WITH counts") — the filled-slot
            -- tally for this container, bottom-right corner over the icon. Condensed numeral.
            local cnt = b:CreateFontString(nil, "OVERLAY")
            cnt:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
            cnt:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
            cnt:Hide()
            b._count = cnt
            b._applySkin = function()
                local on = b._on and true or false
                b:SetBackdrop(UI.FLAT_BACKDROP)
                -- shown bag = calm raised parchment; hidden/empty = recessed idle well.
                b:SetBackdropColor(UI.Color(on and "raised" or "inset"))
                b:SetBackdropBorderColor(UI.Color(on and "border" or "controlBorder"))
                b._fs:SetTextColor(UI.Color(on and "text" or "faint"))
                b._underline:SetColorTexture(UI.Color("bronze"))
                b._underline:SetShown(on)
                b._plus:SetTextColor(UI.Color("bronze"))
                b._count:SetTextColor(UI.Color("muted"))
            end
            UI.Skin(b, function() if b._applySkin then b._applySkin() end end)
            -- Hover: contextual tooltip + reveal the equip "+" on an empty slot.
            b:SetScript("OnEnter", function(self)
                stripTooltip(self)
                local st = stripStateNow(self)
                self._plus:SetShown(st.showPlus)
                -- "+" replaces the number while hovering an empty slot; when an equipped-
                -- bag icon is shown the number stays hidden (the icon is the content).
                self._fs:SetShown(not st.showPlus and not self._icon:IsShown())
            end)
            b:SetScript("OnLeave", function(self)
                if _G.GameTooltip then _G.GameTooltip:Hide() end
                self._plus:Hide()
                self._fs:SetShown(not self._icon:IsShown())
            end)
            -- Left-click: equip (cursor bag) / toggle (shown bag) / inert (empty) — combat-gated.
            b:SetScript("OnClick", function(self)
                local st = stripStateNow(self)
                runStripAction(st.clickAction, self._cid, self._slot)
            end)
            -- Drop a bag onto the slot: equip/replace (native content swap), combat-gated.
            b:SetScript("OnReceiveDrag", function(self)
                local st = stripStateNow(self)
                runStripAction(st.dropAction, self._cid, self._slot)
            end)
            -- Drag the equipped bag off the slot to unequip/swap, combat-gated.
            b:SetScript("OnDragStart", function(self)
                local st = stripStateNow(self)
                runStripAction(st.dragAction, self._cid, self._slot)
            end)
            win._stripButtons[i] = b
        end
        b._cid        = cid
        b._role       = entry.role
        b._manageable = entry.manageable and true or false
        b._slot       = entry.manageable and bagInventorySlot(cid) or nil
        b:SetSize(SIZE, SIZE)
        -- Row/col placement (top-left cluster wrapping downward at perRow).
        local col = (i - 1) % perRow
        local row = math.floor((i - 1) / perRow)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", win.strip, "TOPLEFT", col * (SIZE + GAP), -(row * (SIZE + GAP)))
        -- glyph label (fallback / non-icon slots): backpack "B", keyring "K", bags by number
        local lbl = (cid == Store.BACKPACK_CONTAINER and "B")
                 or (cid == Store.KEYRING_CONTAINER  and "K")
                 or tostring(cid)
        b._fs:SetText(lbl)
        b._plus:Hide()
        -- Filled-slot count for this container (from the viewed owner's store snapshot),
        -- shown as a corner numeral (1.0 "icon buttons with counts"). Hidden when 0/empty.
        local c = owner and owner.containers and owner.containers[cid]
        local filled = 0
        if c and c.slots then for s = 1, (c.size or 0) do if c.slots[s] then filled = filled + 1 end end end
        if c and filled > 0 then b._count:SetText(tostring(filled)); b._count:Show() else b._count:Hide() end
        -- "shown" (underline/raised) only when a bag actually occupies the slot and isn't hidden.
        local equipped = b._manageable and (bagEquippedLink(b._slot) ~= nil)
                      or (not b._manageable and owner and owner.containers and owner.containers[cid] ~= nil)
        b._on = equipped and not hidden[cid]

        -- Resolve the strip icon. A carried bag equipped in this slot renders the equipped
        -- bag's inventory texture (live self). 1.0-PARITY (item 6): the BACKPACK and KEYRING
        -- get their proper game icons (1.x Bag.StaticIcons) instead of the "B"/"K" glyphs.
        -- Empty/cached carried slots keep their number glyph (no icon resolved).
        local isHidden = hidden[cid] and true or false
        local iconTex
        if b._slot and equipped and _G.GetInventoryItemTexture then
            iconTex = _G.GetInventoryItemTexture("player", b._slot)
        elseif b._role == "backpack" then
            iconTex = Frame.ICON_BACKPACK
        elseif b._role == "keyring" then
            iconTex = Frame.ICON_KEYRING
        end
        if iconTex then
            b._icon:SetTexture(iconTex)
            -- hidden bag reads as a dimmed + desaturated icon (the toggle-state cue over the icon).
            if b._icon.SetDesaturated then b._icon:SetDesaturated(isHidden) end
            b._icon:SetAlpha(isHidden and 0.35 or 1.0)
            b._icon:Show()
            b._fs:Hide()               -- the icon is the content; number glyph steps aside
        else
            b._icon:Hide()
            b._fs:Show()
        end

        b._applySkin()
        -- Lock feedback: a bag mid-pickup desaturates (IsInventoryItemLocked).
        if b._slot and _G.IsInventoryItemLocked and _G.IsInventoryItemLocked(b._slot) then
            if b._icon:IsShown() and b._icon.SetDesaturated then b._icon:SetDesaturated(true) end
            b._fs:SetTextColor(UI.Color("faint"))
        end
        b:Show()
    end
end

----------------------------------------------------------------------
-- Diagnostics (/bags debug strip|toolbar|money) — print live gate/handler/geometry
-- state so a silent behavioral report (BugSack shows no Lua error) becomes a concrete
-- readout. Guarded + in-game only (needs the built window).
----------------------------------------------------------------------

local function P(s) if ns and ns.Print then ns:Print(s) end end

function Frame.DebugStrip()
    if not (ns and ns.Print) then return end
    local win = Frame.window
    if not win then P("[strip] window not built — open the bags first (/bags)"); return end
    local owner = Frame.ViewedOwner()
    local live = (ns.Items and ns.Items.IsLive and ns.Items.IsLive(owner)) and true or false
    P(string.format("[strip] viewedKey=%s selfKey=%s IsLive=%s Items._self=%s inCombat=%s cursorBag=%s",
        tostring(Frame.ViewedOwnerKey()), tostring(Frame.SelfKey()), tostring(live),
        tostring(ns.Items and ns.Items._self), tostring(stripInCombat()), tostring(cursorHasBag())))
    if not live then
        P("  NOTE: viewed owner is not live-self -> strip is toggle-only (no bag equip). If")
        P("        this is your OWN character, the self-key derivation is mismatched.")
    end
    for i, b in ipairs(win._stripButtons or {}) do
        if b.IsShown and b:IsShown() then
            local st = stripStateNow(b)
            P(string.format("  btn%d cid=%s role=%s manageable=%s invSlot=%s equipped=%s | click=%s drop=%s drag=%s | handlers onClick=%s onDrag=%s onRecv=%s",
                i, tostring(b._cid), tostring(b._role), tostring(b._manageable), tostring(b._slot),
                tostring(st.equipped), tostring(st.clickAction), tostring(st.dropAction), tostring(st.dragAction),
                tostring(b:GetScript("OnClick") ~= nil), tostring(b:GetScript("OnDragStart") ~= nil),
                tostring(b:GetScript("OnReceiveDrag") ~= nil)))
        end
    end
end

function Frame.DebugToolbar()
    if not (ns and ns.Print) then return end
    local win = Frame.window
    if not win then P("[toolbar] window not built — open the bags first (/bags)"); return end
    local function d(name, f)
        if not f then P("  " .. name .. " = MISSING"); return end
        P(string.format("  %-14s shown=%s w=%.0f left=%.0f right=%.0f level=%s",
            name, tostring(f.IsShown and f:IsShown()), (f.GetWidth and f:GetWidth()) or -1,
            (f.GetLeft and f:GetLeft()) or -1, (f.GetRight and f:GetRight()) or -1,
            tostring(f.GetFrameLevel and f:GetFrameLevel())))
    end
    P("[title-row] control geometry (left/right in screen px; overlaps => crowding):")
    d("magBtn(search)", win.magBtn)
    d("ownerSelector", win.ownerSelector)
    d("findBtn", win.findBtn)
    d("sortBtn", win.sortBtn)
    d("searchWrap", win.searchWrap)
    d("slotCount", win.slotCount)
    d("footIcon", win.footIcon)
    P("  ns.Find present=" .. tostring(ns.Find ~= nil) .. " ns.Sort present=" .. tostring(ns.Sort ~= nil))
end

function Frame.DebugMoney()
    if not (ns and ns.Print) then return end
    local win = Frame.window
    if not win or not win.money then P("[money] not built — open the bags first (/bags)"); return end
    local m = win.money
    P(string.format("[money] shown=%s mouseEnabled=%s left=%.0f right=%.0f bottom=%.0f top=%.0f level=%s onEnter=%s",
        tostring(m:IsShown()), tostring(m.IsMouseEnabled and m:IsMouseEnabled()),
        (m:GetLeft() or -1), (m:GetRight() or -1), (m:GetBottom() or -1), (m:GetTop() or -1),
        tostring(m:GetFrameLevel()), tostring(m:GetScript("OnEnter") ~= nil)))
    for _, ln in ipairs(Frame.BuildMoneyLines(Store.TotalMoney(), Store.MoneyByAccount())) do
        P(string.format("  %s = %s", ln.label, moneyString(ln.copper)))
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
                   live = (ns.Items and ns.Items.IsLive and ns.Items.IsLive(owner)) and true or false,
                   hidden = (Store.db and Store.db.hiddenBags) or {} }

    -- Gold title "<Character>'s Inventory" for the VIEWED owner (1.0 TitleBags).
    if win.title then
        local nm = owner and owner.name
        if not nm then
            local key = Frame.ViewedOwnerKey()
            nm = (key and Store.SplitNameRealm and Store.SplitNameRealm(key)) or nil
        end
        win.title:SetText(Frame.WindowTitle(nm))
    end
    if win.ownerSelector and win.ownerSelector.Refresh then win.ownerSelector:Refresh() end
    -- money (viewed owner)
    if win.moneyFS then win.moneyFS:SetText(moneyString(owner and owner.money or 0)) end
    -- free/total slot counter, bottom-center (1.x SlotCount: "free/total")
    if win.slotCount then
        local free, total = Frame.SlotCounts(owner, opts)
        win.slotCount:SetText(free .. "/" .. total)
    end

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
            if g.SetHeader then g:SetHeader(nil) end   -- clear any leftover split bag-header on a reused group
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

-- Collapsed search toggle (1.0: search behind the magnifier). force nil => toggle;
-- force=true/false => show/hide. Hiding clears the query so the grid restores.
function Frame.ToggleSearch(force)
    local win = Frame.window
    if not win or not win.searchWrap then return end
    local show
    if force == nil then show = not win.searchWrap:IsShown() else show = force and true or false end
    win.searchWrap:SetShown(show)
    if show then
        if win.searchBox and win.searchBox.SetFocus then win.searchBox:SetFocus() end
    else
        if win.searchBox then
            win.searchBox:SetText("")
            if ns.Search then ns.Search.SetQuery("") end
            if win.searchBox.ClearFocus then win.searchBox:ClearFocus() end
        end
    end
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

-- One frame drives the strip's live refresh: PLAYER_REGEN_ENABLED re-enables equip and
-- clears the combat-blocked state; ITEM_LOCK_CHANGED reflects a bag mid-pickup/equip.
-- (BAG_UPDATE already flows through capture -> BAGS_CAPTURED -> RequestRefresh.)
function Frame.EnsureStripEvents()
    if Frame._stripEvt or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("ITEM_LOCK_CHANGED")
    f:SetScript("OnEvent", function() Frame.RequestRefresh() end)
    Frame._stripEvt = f
end

function Frame.OnLogin()
    if Store and Store.db then Frame.ApplyDefaults(Store.db); Frame.MigrateDensity(Store.db) end
    Frame.HookBagToggles()
    Frame.EnsureStripEvents()
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

-- 1.0-PARITY one-time density migration: an old-default (4/12) beta DB flips to the tight
-- 2/11 grid ONCE; genuine customizations survive; the marker + user-touched flag guard
-- re-runs; idempotent (mirrors rules2's categories default-flip).
local function testDensityMigration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- (1) Old-default beta DB migrates once to the tight 1.0 grid, sets the marker.
    local old = { gap = 4, columns = 12 }
    ck(Frame.MigrateDensity(old) == true, "old-default 4/12 db migrates")
    ck(old.gap == Frame.DEFAULT_GAP and old.columns == Frame.DEFAULT_COLUMNS, "migrated to parity 2/11")
    ck(old[Frame.DENSITY_MARKER] == true, "one-time marker set")
    -- idempotent: after the marker, a later deliberate change is never re-clobbered.
    old.gap = 5; old.columns = 13
    ck(Frame.MigrateDensity(old) == false, "second run is a no-op (marker guards)")
    ck(old.gap == 5 and old.columns == 13, "post-migration values untouched by the re-run")

    -- (2) Genuine customizations survive — anything other than exactly the 4/12 pair.
    for _, spec in ipairs({ { 4, 10 }, { 3, 12 }, { 2, 11 }, { 0, 20 } }) do
        local db = { gap = spec[1], columns = spec[2] }
        ck(Frame.MigrateDensity(db) == false, "non-old-default " .. spec[1] .. "/" .. spec[2] .. " not migrated")
        ck(db.gap == spec[1] and db.columns == spec[2], "custom " .. spec[1] .. "/" .. spec[2] .. " survives")
        ck(db[Frame.DENSITY_MARKER] == true, "marker set even when nothing migrated")
    end

    -- (3) A user-touched grid marker blocks the flip even at exactly 4/12.
    local chose = { gap = 4, columns = 12, densityUserChose = true }
    ck(Frame.MigrateDensity(chose) == false, "densityUserChose blocks the flip at 4/12")
    ck(chose.gap == 4 and chose.columns == 12, "deliberate 4/12 preserved")

    -- (4) nil / non-table guarded.
    ck(Frame.MigrateDensity(nil) == false, "nil db -> no migration")

    -- (5) Fresh DB: ApplyDefaults lands on parity, Migrate is then a no-op.
    local fresh = {}
    Frame.ApplyDefaults(fresh)
    ck(fresh.gap == Frame.DEFAULT_GAP and fresh.columns == Frame.DEFAULT_COLUMNS, "fresh db defaults to parity")
    ck(Frame.MigrateDensity(fresh) == false, "fresh parity db not migrated (already tight)")
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

-- STRIP SLOT ENUMERATION (bag-manager fix): the LIVE self strip lists every equip slot
-- 1..N — including EMPTY ones — so a newly-looted bag has a target (the owner's miss).
-- A cached alt lists only owned bags, toggle-only.
local function testStripSlots(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = fixtureOwner()   -- owns bags 1 and 2 (of a 4-slot inventory)

    -- LIVE self: all 4 bag slots present + manageable, plus backpack/keyring toggles.
    local live = Frame.StripSlots(o, { live = true, showKeyring = true, numBagSlots = 4 })
    ck(#live == 6, "live strip = backpack + 4 bag slots + keyring, got " .. #live)
    ck(live[1].cid == 0 and live[1].role == "backpack" and live[1].manageable == false, "backpack first, pure toggle")
    ck(live[6].cid == Store.KEYRING_CONTAINER and live[6].role == "keyring" and live[6].manageable == false, "keyring last, pure toggle")
    local bagCount, manageable = 0, 0
    for i = 2, 5 do
        ck(live[i].cid == i - 1 and live[i].role == "bag", "bag slot " .. (i - 1) .. " enumerated")
        bagCount = bagCount + 1
        if live[i].manageable then manageable = manageable + 1 end
    end
    ck(bagCount == 4 and manageable == 4, "all 4 bag slots present AND manageable (empty slots 3,4 included)")

    -- keyring off drops the keyring entry.
    local noKey = Frame.StripSlots(o, { live = true, showKeyring = false, numBagSlots = 4 })
    ck(#noKey == 5 and noKey[#noKey].role == "bag", "showKeyring=false -> no keyring entry")

    -- CACHED alt: only owned bags (1,2), none manageable.
    local cached = Frame.StripSlots(o, { live = false, showKeyring = true, numBagSlots = 4 })
    ck(#cached == 4, "cached strip = backpack + owned bags(1,2) + keyring, got " .. #cached)
    ck(cached[2].cid == 1 and cached[3].cid == 2, "cached lists only owned bags, sorted")
    for _, e in ipairs(cached) do ck(e.manageable == false, "cached entries are all toggle-only") end
end

-- STRIP BUTTON STATE MATRIX: equipped / empty / toggled × cursor-bag × combat, plus the
-- backpack/keyring pure-toggle guarantee. Locks the equip/pickup/drop/toggle dispatch.
local function testStripButtonState(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local S = Frame.StripButtonState

    -- Empty manageable slot: shows the "+" affordance; a bare click is inert; a bag on
    -- the cursor makes click AND drop equip; nothing to drag out.
    local empty = S({ role = "bag", manageable = true, equipped = false })
    ck(empty.showPlus == true, "empty slot shows the + equip affordance")
    ck(empty.clickAction == "none", "empty slot, no cursor -> inert click")
    ck(empty.dropAction == "equip", "empty slot -> drop equips")
    ck(empty.dragAction == nil, "empty slot -> nothing to drag out")
    local emptyCursor = S({ role = "bag", manageable = true, equipped = false, cursorBag = true })
    ck(emptyCursor.clickAction == "equip", "empty slot + cursor bag -> click equips")

    -- Equipped manageable slot: no "+"; bare click toggles hide/show; cursor bag replaces;
    -- drag out picks up the equipped bag.
    local eq = S({ role = "bag", manageable = true, equipped = true })
    ck(eq.showPlus == false, "equipped slot has no + affordance")
    ck(eq.clickAction == "toggle", "equipped slot, no cursor -> click toggles hide/show")
    ck(eq.dragAction == "pickup", "equipped slot -> drag picks up the bag")
    local eqCursor = S({ role = "bag", manageable = true, equipped = true, cursorBag = true })
    ck(eqCursor.clickAction == "equip", "equipped slot + cursor bag -> click replaces")

    -- COMBAT downgrades every equip/pickup to blocked-combat (deferred, not attempted).
    local combatEmpty = S({ role = "bag", manageable = true, equipped = false, cursorBag = true, inCombat = true })
    ck(combatEmpty.clickAction == "blocked-combat" and combatEmpty.dropAction == "blocked-combat",
        "combat: equip/drop deferred (blocked)")
    local combatEq = S({ role = "bag", manageable = true, equipped = true, inCombat = true })
    ck(combatEq.dragAction == "blocked-combat", "combat: pickup deferred (blocked)")
    ck(combatEq.clickAction == "toggle", "combat still allows the (non-protected) hide/show toggle")

    -- Backpack + keyring are PURE toggles regardless of cursor/equip (never equippable).
    for _, role in ipairs({ "backpack", "keyring" }) do
        local t = S({ role = role, manageable = false, equipped = true, cursorBag = true })
        ck(t.clickAction == "toggle", role .. " is a pure toggle even with a bag on the cursor")
        ck(t.showPlus == false and t.dragAction == nil and t.dropAction == nil, role .. " exposes no equip affordance")
    end

    -- Cached alt bag: manageable=false -> toggle-only, no equip/drag/plus.
    local cachedBag = S({ role = "bag", manageable = false, equipped = true, cursorBag = true })
    ck(cachedBag.clickAction == "toggle" and cachedBag.dropAction == nil and cachedBag.showPlus == false,
        "cached alt bag is toggle-only")
end

-- CURSOR-IS-BAG (Task 2): the strip's equip affordance must fire only for an actual
-- bag on the cursor, not any item (CursorHasItem was over-broad).
local function testCursorIsBag(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Frame.CursorIsBag("item", "INVTYPE_BAG") == true, "item + INVTYPE_BAG -> is a bag")
    ck(Frame.CursorIsBag("item", "INVTYPE_CHEST") == false, "item with non-bag equipLoc -> not a bag")
    ck(Frame.CursorIsBag("item", "") == false, "non-equippable item -> not a bag")
    ck(Frame.CursorIsBag("spell", "INVTYPE_BAG") == false, "non-item cursor -> not a bag")
    ck(Frame.CursorIsBag(nil, nil) == false, "empty cursor -> not a bag")
end

-- MONEY LINES (Task 4): the cross-account gold tooltip builder — grand total first,
-- accounts by copper desc, empty account => "Unlinked", nil-safe.
local function testMoneyLines(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local lines = Frame.BuildMoneyLines(1000, { ["acctA"] = 700, ["acctB"] = 300, [""] = 0 })
    ck(lines[1].isTotal and lines[1].label == "All characters" and lines[1].copper == 1000, "grand total line first")
    ck(lines[2].label == "acctA" and lines[2].copper == 700, "richest account second")
    ck(lines[3].label == "acctB" and lines[3].copper == 300, "next account by copper desc")
    ck(lines[4].label == "Unlinked" and lines[4].copper == 0, "empty account label -> Unlinked")
    local solo = Frame.BuildMoneyLines(50, {})
    ck(#solo == 1 and solo[1].copper == 50 and solo[1].isTotal, "no accounts -> just the total line")
    ck(#Frame.BuildMoneyLines(nil, nil) == 1, "nil args -> one zero total line")
    ck(Frame.BuildMoneyLines(nil, nil)[1].copper == 0, "nil total -> 0 copper")
end

-- 1.0-PARITY money tooltip (item 2): per-character rows, Others rollup at >5, Other Accounts
-- section, grand-total footer, and the moneyTooltipMinGold display filter.
local function testMoneyReport(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local G = 10000
    local chars = {
        { name = "Zed", class = "MAGE",    account = "A", copper = 100 * G },
        { name = "Bob", class = "WARRIOR", account = "A", copper = 50 * G },
        { name = "Amy", class = "PRIEST",  account = "A", copper = 10 * G },
        { name = "Ann", class = "ROGUE",   account = "A", copper = 4 * G },
        { name = "Abe", class = "DRUID",   account = "A", copper = 3 * G },
        { name = "Ada", class = "SHAMAN",  account = "A", copper = 2 * G },   -- 6th in A -> overflow
        { name = "Cid", class = "ROGUE",   account = "B", copper = 200 * G },
        { name = "Rex", class = "HUNTER",  account = "B", copper = 5 * G },
        { name = "Zip", class = "MAGE",    account = "A", copper = 0 },        -- money 0 -> excluded
    }
    local expTotal = (100 + 50 + 10 + 4 + 3 + 2 + 200 + 5 + 0) * G
    local rows = Frame.BuildMoneyReport(chars, { selfAccount = "A", maxPerGroup = 5 })
    -- self (A) group, copper desc: Zed, Bob, Amy, Ann, Abe (5 shown), then Others = Ada (2g).
    ck(rows[1].kind == "char" and rows[1].name == "Zed", "richest self char first")
    ck(rows[5].name == "Abe", "5th self char shown (cap)")
    ck(rows[6].kind == "others" and rows[6].copper == 2 * G, "6th self char rolled into Others (2g)")
    ck(rows[7].kind == "spacer" and rows[8].kind == "section" and rows[8].label == "Other Accounts",
        "spacer + Other Accounts header before the other-account group")
    ck(rows[9].kind == "char" and rows[9].name == "Cid" and rows[9].copper == 200 * G, "other-account richest first")
    ck(rows[10].name == "Rex", "other-account second char")
    ck(rows[#rows].kind == "total" and rows[#rows].copper == expTotal,
        "Total footer = grand total of everyone, got " .. rows[#rows].copper)

    -- moneyTooltipMinGold = 20g: only >=20g chars DISPLAYED (A: Zed,Bob; B: Cid); Total unchanged.
    local rows2 = Frame.BuildMoneyReport(chars, { selfAccount = "A", minCopper = 20 * G, maxPerGroup = 5 })
    ck(rows2[1].name == "Zed" and rows2[2].name == "Bob", "minGold: only >=20g self chars shown")
    ck(rows2[3].kind == "spacer" and rows2[4].kind == "section", "minGold: no self Others (under cap)")
    ck(rows2[5].kind == "char" and rows2[5].name == "Cid", "minGold: other-account Cid shown, Rex filtered")
    ck(rows2[#rows2].kind == "total" and rows2[#rows2].copper == expTotal, "minGold: Total still counts everyone")

    -- No self account known -> a single group, NO Other Accounts section, still a Total footer.
    local rows3 = Frame.BuildMoneyReport(chars, { selfAccount = "", maxPerGroup = 99 })
    for _, r in ipairs(rows3) do ck(r.kind ~= "section", "no self account -> no Other Accounts section") end
    ck(rows3[#rows3].kind == "total", "single-group still has a Total footer")

    -- Empty -> just a Total(0).
    local empty = Frame.BuildMoneyReport({}, {})
    ck(#empty == 1 and empty[1].kind == "total" and empty[1].copper == 0, "no chars -> Total 0 only")
end

-- 1.0-LOOK PARITY: the new anatomy helpers — title format, free/total counter, and the
-- bag-strip band geometry — plus the toolbar-free window math. All pure/headless.
local function testParityAnatomy(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Title (1.x TitleBags "%s's Inventory").
    ck(Frame.WindowTitle("Daseeki") == "Daseeki's Inventory", "title = <name>'s Inventory")
    ck(Frame.WindowTitle(nil) == "Bags", "nil name -> plain wordmark")
    ck(Frame.WindowTitle("")  == "Bags", "blank name -> plain wordmark")

    -- Tight-grid density facts (1.x pitch 39 = 37 + 2, owner columns 11).
    ck(Frame.DEFAULT_GAP == 2, "default gap tightened to 2 (1.0 density)")
    ck(Frame.DEFAULT_BUTTONSIZE == 37, "cell stays 37 (Classic footprint)")
    ck(Frame.DEFAULT_COLUMNS == 11, "columns = 11 (owner 1.x config)")

    -- Free/total counter over the fixture owner: 16+14+6+12 = 48 slots; filled = bp(3)+bag1(1)+keyring(1) = 5.
    local o = fixtureOwner()
    local free, total = Frame.SlotCounts(o, { showKeyring = true })
    ck(total == 48, "slot counter total = sum of container sizes (48), got " .. total)
    ck(free == 48 - 5, "slot counter free = total - filled (43), got " .. free)
    local _, t2 = Frame.SlotCounts(o, { showKeyring = true, hidden = { [1] = true } })
    ck(t2 == 48 - 14, "hiding bag1 (14 slots) drops them from the total")
    local _, t3 = Frame.SlotCounts(o, { showKeyring = false })
    ck(t3 == 48 - 12, "keyring off drops its 12 slots from the total")
    ck(select(2, Frame.SlotCounts(nil, {})) == 0, "nil owner -> 0 total")

    -- Bag-strip band geometry: perRow / rows / height (single row unless overflow).
    ck(Frame.StripPerRow(500, 28, 4) >= 6, "wide band fits many strip icons in one row")
    ck(Frame.StripPerRow(0, 28, 4) == 1, "degenerate band width -> at least 1 per row")
    ck(Frame.StripRows(6, 15) == 1, "6 bags in a 15-wide row -> 1 row")
    ck(Frame.StripRows(6, 4)  == 2, "6 bags at 4/row -> 2 rows")
    ck(Frame.StripRows(0, 4)  == 1, "no bags -> still one (empty) row band")
    ck(Frame.StripBandHeight(6, 500, 28, 4) == 28, "single-row strip band = one icon tall (28)")
    ck(Frame.StripBandHeight(6, 4 * 28 + 3 * 4, 28, 4) == 2 * 28 + 4, "wrapped strip band = 2 rows + gap")

    -- Window math dropped the (removed) toolbar band: height = TITLE + VGAP + strip + VGAP
    -- + content + VGAP + MONEY + PAD; width = band + 2*PAD.
    local opts = { columns = 11, buttonSize = 37, gap = 2, showKeyring = true, live = false }
    local content = Frame.ComputeContentSize(o, "combined", opts)
    local stripH  = Frame.StripBandHeight(Frame.StripCount(o, opts), content.width)
    local expH = Frame.TITLE_H + Frame.VGAP + stripH + Frame.VGAP
               + content.height + Frame.VGAP + Frame.MONEY_H + Frame.PAD
    local sz = Frame.ComputeWindowSize(o, "combined", opts)
    ck(sz.height == expH, "window height = title+strip+content+money bands (no toolbar), got " .. sz.height .. " exp " .. expH)
    ck(sz.width == content.width + Frame.PAD * 2, "window width = band + 2*pad")
    ck(Frame.TOOLBAR_H == nil, "the modern toolbar band metric is gone (controls relocated)")
end

function Frame.RunSelfTests(verbose)
    local suites = {
        { name = "1.0 anatomy",         fn = testParityAnatomy },
        { name = "container order",     fn = testContainerOrder },
        { name = "cursor is bag",       fn = testCursorIsBag },
        { name = "money lines",         fn = testMoneyLines },
        { name = "money report (1.0)",  fn = testMoneyReport },
        { name = "combined entries",    fn = testCombinedEntries },
        { name = "split groups",        fn = testSplitGroups },
        { name = "grid + window size",  fn = testGridAndWindowSize },
        { name = "geometry round-trip", fn = testGeometryRoundTrip },
        { name = "apply defaults",      fn = testApplyDefaults },
        { name = "density migration",   fn = testDensityMigration },
        { name = "keyring gate",        fn = testKeyringGate },
        { name = "keyring dynamic size", fn = testKeyringDynamicSize },
        { name = "category section size", fn = testCategorySectionSize },
        { name = "effective mode",       fn = testEffectiveMode },
        { name = "strip slots",          fn = testStripSlots },
        { name = "strip button state",   fn = testStripButtonState },
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
