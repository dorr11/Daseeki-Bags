-- Daseeki Bags 2.0 — parity.lua
-- THE CELL-PARITY GATE. This file exists to end an iteration loop, not to add a feature.
--
-- Background. The owner reported, twice, that the 2.0 bag grid "feels cluttered, hard to
-- view" side by side with Daseeki-Bags 1.x, and said plainly: "we have bags 1.x which does
-- it perfectly, we should be able to replicate that in our codebase." Two rounds patched
-- individual deltas (the glow's geometry against a clean-room third-party SPEC, then
-- suppressing the per-cell well underneath a glowing cell) and the grid still read wrong,
-- because each round guessed at the NEXT delta instead of modelling the WHOLE cell.
--
-- So this file is a literal, line-cited TRANSCRIPTION of what 1.x draws in one bag cell,
-- kept next to what 2.0 draws, with an assertion on every row. It is the thing that makes
-- "does 2.0 render a cell the way 1.x does?" a test result instead of a screenshot
-- argument. If a future round changes any per-cell element without changing 1.x's model
-- with it, this suite goes red and names the row.
--
-- GROUND TRUTH is the 1.x source tree (the same repository, parked on `main`), not
-- CII_BEHAVIOR_SPEC.md. Where the two disagree, 1.x wins — that is the owner's stated
-- target, verbatim. Every ONE_X_* constant below carries its file:line.
--
-- WHAT THIS FILE CANNOT SEE. Three things are properties of the running client, not of our
-- Lua, and are therefore asserted only as "we do the same call 1.x does", with the in-game
-- A/B named in the comment:
--   1. the rendered appearance of Interface\Buttons\UI-ActionButton-Border under ADD blend;
--   2. the ItemButtonTemplate's own internal geometry (icon inset, IconBorder art, count
--      anchor). It is the SAME template in 1.x and 2.0, so it cancels out of every delta —
--      which is exactly why the model below records "template default" as a value rather
--      than trying to name a pixel;
--   3. the exact art of Interface\PaperDoll\UI-Backpack-EmptySlot.
--
-- PURE Lua. No WoW API, no addon frames. Suite name: "cell-parity".

local ADDON, ns = ...

local Parity = {}
ns.Parity = Parity

----------------------------------------------------------------------
-- 1.x MODEL — transcribed from Daseeki-Bags (main), file:line on every row
----------------------------------------------------------------------

-- Geometry. 1.x never resizes the item button: it leaves the template at its native 37 and
-- SCALES it, and the grid step is 37 + spacing in the button's own coordinate space.
--   skin/others.lua:8-11    LayoutTraits -> profile.columns, profile.itemScale, 37 + profile.spacing
--   core/classes/itemGroup.lua:143-146   button:SetPoint(..., size * x, -size * y); button:SetScale(scale)
--   skin/defaults.lua:20    itemScale = 1, bagScale = 1, spacing = 2
-- The owner's real 1.x profile (DaseekiBagsSets, inventory): scale 0.98, itemScale 0.91,
-- columns 11, spacing 2.
Parity.ONE_X = {
    BUTTON_SIZE   = 37,      -- template native; 1.x never calls SetSize on it
    SPACING       = 2,       -- skin/defaults.lua:20
    PITCH_UNITS   = 39,      -- skin/others.lua:10  37 + spacing, in button-local units
    ITEM_SCALE    = 0.91,    -- owner profile (skin/defaults.lua:20 default is 1)
    FRAME_SCALE   = 0.98,    -- owner profile (skin/defaults.lua:20 default is 1)
    COLUMNS       = 11,      -- owner profile

    -- Quality glow (core/classes/item.lua:54-58, 208)
    GLOW_TEXTURE  = "Interface\\Buttons\\UI-ActionButton-Border",  -- :55
    GLOW_SIZE     = 67,      -- :58  SetSize(67, 67)
    GLOW_BLEND    = "ADD",   -- :56
    GLOW_LAYER    = "OVERLAY",  -- :54
    GLOW_SUBLEVEL = -1,      -- :54  CreateTexture(nil, 'OVERLAY', nil, -1)
    GLOW_OFFSET_Y = 0,       -- :57  SetPoint('CENTER') with no offset
    GLOW_ALPHA    = 0.5,     -- core/api/settings.lua:34  glowAlpha = 0.5

    -- Tint chain (core/classes/item.lua:197-205), top down
    TINT_ORDER    = { "quest", "unusable", "set", "quality" },
    QUEST_RGB     = { 1, 0.82, 0.2 },   -- :198
    SET_RGB       = { 0.2, 1, 0.8 },    -- :202
    MIN_QUALITY   = 2,                  -- :203  glowQuality and quality > 1

    -- IS THE SET BRANCH REACHABLE ON THIS CLIENT? No — and this row is why the teal
    -- regression happened. 1.x's :201 calls Search:BelongsToSet, and ItemSearch binds that
    -- method by environment: libs/ItemSearch-1.3/API.lua:113 needs ItemRack loaded (the
    -- owner's AddOns.txt says `ItemRack: disabled`), :128 needs a client NEWER than
    -- Classic, and :145-146 is the else — `Lib.BelongsToSet = nop`. On Classic Era with
    -- ItemRack off, 1.x therefore paints ZERO set teal no matter what glowSets says.
    SET_BRANCH_LIVE = false,     -- libs/ItemSearch-1.3/API.lua:145-146  Lib.BelongsToSet = nop

    -- What is drawn on the cell besides the icon
    CELL_SUBSTRATE_REGIONS = 0,  -- :51-52 normal:Hide(); nothing is created to replace it
    ICON_TEXCOORD          = nil, -- 1.x never calls SetTexCoord on the item icon (grep-verified)

    -- EMPTY CELL — the OWNER'S PROFILE, not 1.x's shipped default. The previous round
    -- cited skin/defaults.lua:59-60 (slotBackground = 2, slotAlpha = 1) and shipped the
    -- bevelled backpack art at full opacity. His live DaseekiBagsSets (WTF, account #1 and
    -- confirmed identical in #2/#3, and in every one of his named profiles) says:
    --   slotBackground = 6  ->  item.lua:18 Backgrounds[6] = icon:SetAtlas(
    --                           'MountJournalIcons-Horde') — the faction crest, not a bevel
    --                           (his Alliance profile is 5, the Alliance crest)
    --   slotAlpha      = 0.29 -> item.lua:167 draws that crest at 29% on an empty cell
    -- ...which renders as the near-black cell carrying a faint tint in his screenshot.
    -- OWNER-DIRECTED, not incidental: "this was something i deliberately implemented in
    -- bags 1. the darkened, slightly opaque background is easier on the eyes."
    EMPTY_BACKGROUND = 6,        -- owner profile slotBackground (item.lua:18 atlas entry)
    EMPTY_ALPHA      = 0.29,     -- owner profile slotAlpha; item.lua:167
    EMPTY_ICON_1X_DEFAULT = "interface/paperdoll/ui-backpack-emptyslot",  -- :14 Backgrounds[2]

    ICONBORDER_DRIVEN = true,    -- :194 SetItemButtonQuality, :210 SetVertexColor, :220 SetShown(r)
    JUNKICON_DRIVEN   = true,    -- :222 SetShown(glowPoor and quality == 0 and not hasNoValue)
    NEWITEM_KILLED    = true,    -- :49  b.NewItemTexture:Hide()  -> 1.x shows NO new-item cue
    COUNT_RESTYLED    = false,   -- :168 bare SetItemButtonCount; no font/colour/anchor call

    -- SLOT BORDER — again the owner's profile, not the default. 1.x CREATES a 2px backdrop
    -- edge on every cell (:65-71) and re-colours it on every update from slotBorderColor
    -- (:171-174), unconditionally — filled cells included. Its shipped default is invisible
    -- ({1,1,1,0}, :70), which is why the previous round recorded alpha 0 and drew nothing.
    -- The owner's value is a near-black maroon at 59%, and it is the other half of the
    -- "darkened, slightly opaque" look he asked for.
    SLOT_BORDER_PX     = 2,      -- :69  edgeSize = 2
    SLOT_BORDER_RGBA   = { 0.207843, 0, 0.023529, 0.59 },  -- owner profile slotBorderColor
    SLOT_BORDER_SCOPE  = "all",  -- :171-174 runs for every cell, filled or empty
    SLOT_BORDER_ALPHA_1X_DEFAULT = 0,  -- :70 SetBackdropBorderColor(1,1,1,0)

    DIM_ALPHA         = 0.3,     -- :233 SetAlpha(matches and 1 or 0.3)
    CORNER_PIPS       = 0,       -- 1.x draws no addon-owned corner marks at all
    GROUND_RGBA       = { 0, 0, 0, 0.85 },  -- skin/defaults.lua:17  color = {0,0,0,0.85}
}

----------------------------------------------------------------------
-- Effective on-screen numbers (UIParent units) at a given profile
----------------------------------------------------------------------

-- 1.x composes TWO multiplicative scales and applies the grid step inside the scaled
-- button's own space, so both the cell and the pitch carry itemScale * frameScale.
function Parity.OneXComposite(itemScale, frameScale)
    local X = Parity.ONE_X
    itemScale  = itemScale  or X.ITEM_SCALE
    frameScale = frameScale or X.FRAME_SCALE
    local k = itemScale * frameScale
    return {
        cell    = X.BUTTON_SIZE * k,
        pitch   = X.PITCH_UNITS * k,
        gap     = X.SPACING     * k,
        halo    = X.GLOW_SIZE   * k,
        haloOff = X.GLOW_OFFSET_Y * k,
    }
end

-- 2.0 has ONE scale and sizes the button directly, so its composite is buttonSize/gap
-- times the window scale. `size` and `gap` are the shipped defaults unless overridden.
function Parity.TwoOhComposite(scale, size, gap)
    local Items   = ns.Items
    local Borders = ns.Borders
    scale = scale or 0.89                      -- ui_frame.lua Frame.DEFAULT_SCALE
    size  = size  or (Items and Items.DEFAULT_SIZE) or 37
    gap   = gap   or (Items and Items.DEFAULT_GAP)  or 2
    return {
        cell    = size * scale,
        pitch   = (size + gap) * scale,
        gap     = gap * scale,
        halo    = (Borders and Borders.GlowSize(size) or 0) * scale,
        haloOff = (Borders and Borders.GlowOffsetY(size) or 0) * scale,
    }
end

-- Derived read-outs the owner actually perceives, from a composite.
--   overhang — how far the halo sticks out past the icon on ONE side
--   bleed    — how far the halo reaches ONTO the neighbouring icon
--              (overhang minus the gap; the halo owns the gutter first)
--   fill     — icon width as a fraction of the pitch ("breathing room")
function Parity.Perceived(c)
    local overhang = (c.halo - c.cell) / 2
    return {
        overhang = overhang,
        bleed    = overhang - c.gap,
        fill     = c.cell / c.pitch,
    }
end

----------------------------------------------------------------------
-- ELEMENT COUNT — "how many things are drawn on one cell"
--
-- The owner's verdict ("cluttered", "hard to view") is, mechanically, a count. Both models
-- are reduced to that count here for the same slot facts, so the comparison is a number
-- rather than a screenshot. ctx = { quality, isNew, isQuest, isQuestStarter, isUnusable,
-- isSet, hasNoValue, dimmed, filled }.
----------------------------------------------------------------------

-- 1.x, straight off core/classes/item.lua's Update / UpdateBorder.
function Parity.OneXElementCount(ctx)
    local n = 1                        -- :156-167  the icon region, ALWAYS drawn (item art
                                       --            when filled, Backgrounds[slotBackground]
                                       --            at slotAlpha when empty)
    -- :51-52 the NormalTexture is hidden and nothing replaces it -> no substrate FILL
    -- :48-49 BattlepayItemTexture / NewItemTexture hidden -> no new-item cue at all

    -- :65-71 / :171-174 SlotBorder — created for EVERY cell and coloured on every update.
    -- Drawn iff the profile's slotBorderColor alpha is above zero, which the owner's is.
    if (Parity.ONE_X.SLOT_BORDER_RGBA[4] or 0) > 0 then n = n + 1 end

    if not ctx.filled then return n end
    local quest    = ctx.isQuest or ctx.isQuestStarter
    local glows = false
    if not ctx.dimmed then                                    -- :197-205 the tint chain
        if quest then glows = true
        elseif ctx.isUnusable then glows = true
        -- :201 the set branch, gated by whether ItemSearch bound BelongsToSet at all
        elseif ctx.isSet and Parity.ONE_X.SET_BRANCH_LIVE then glows = true
        elseif ctx.quality and ctx.quality > 1 then glows = true end
    end
    if glows then
        n = n + 1                      -- :219 IconGlow  (the soft halo)
        n = n + 1                      -- :220 IconBorder (the crisp ring under it)
    end
    if ctx.isQuestStarter and not ctx.dimmed then n = n + 1 end  -- :221 QuestBang
    if ctx.quality == 0 and not ctx.hasNoValue and not ctx.dimmed then
        n = n + 1                      -- :222 JunkIcon (the vendor coin)
    end
    return n
end

-- 2.0, derived from the LIVE Items.ResolveState + Borders.ResolveTint. Nothing is hardcoded
-- here: adding a region to the dress and wiring it to a state flag moves this number.
function Parity.TwoOhElementCount(ctx)
    local Items, B = ns.Items, ns.Borders
    local n = 1                        -- the icon region (item art / slot-background art)
    -- the well is retired; no hairline
    -- the per-cell SLOT BORDER, drawn on every cell iff its live alpha is above zero
    local _, _, _, sba = Items.SlotBorderColor()
    if (sba or 0) > 0 then n = n + 1 end
    if not ctx.filled then return n end
    local spec = Items.ResolveState(ctx)
    -- the set cue only reaches the chain when the (default-OFF) toggle is on, exactly as
    -- 1.x's only reaches it when ItemSearch bound BelongsToSet to something real
    local setLive = ctx.isSet and Items.SetCueEnabled()
    local glows = B.GlowShown(ctx.quality, ctx.isUnusable,
        (ctx.isQuest or ctx.isQuestStarter), setLive, true, B.DEFAULT_MIN_QUALITY)
    if ctx.dimmed then glows = false end
    if glows then n = n + 2 end        -- halo + template IconBorder (borders.Apply)
    if spec.showQuestTab then n = n + 1 end
    if spec.junkCoin      then n = n + 1 end
    if spec.showNewDot    then n = n + 1 end   -- the ONE knowing divergence from 1.x
    if spec.showSetMark   then n = n + 1 end   -- retired; must never fire
    return n
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "cell-parity")
----------------------------------------------------------------------

local function approx(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end

-- Build a slot context: quality nil means an EMPTY cell.
local function ctxOf(quality, extra)
    local c = { quality = quality, filled = quality ~= nil }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

-- ROW 1-5: the GEOMETRY composite. Both models must land on the same on-screen numbers at
-- the shipped defaults; the ratios must match exactly at every density.
local function testGeometryComposite(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local one = Parity.OneXComposite()
    local two = Parity.TwoOhComposite()

    -- 1.x at the owner's real settings: 0.91 * 0.98 = 0.8918
    ck(approx(one.cell,  37 * 0.8918, 1e-9), "1.x cell = 37 * 0.91 * 0.98 = 33.00")
    ck(approx(one.pitch, 39 * 0.8918, 1e-9), "1.x pitch = 39 * 0.91 * 0.98 = 34.78")
    ck(approx(one.gap,    2 * 0.8918, 1e-9), "1.x gap = 2 * 0.91 * 0.98 = 1.78")
    ck(approx(one.halo,  67 * 0.8918, 1e-9), "1.x halo = 67 * 0.91 * 0.98 = 59.75")
    ck(one.haloOff == 0, "1.x halo has no vertical offset")

    -- 2.0 at its shipped defaults: one window scale of 0.89 stands in for both 1.x knobs.
    -- The absolute sizes agree to well under a pixel; the RATIOS agree exactly.
    ck(math.abs(one.cell  - two.cell)  < 0.1, "cell parity within 0.1px")
    ck(math.abs(one.pitch - two.pitch) < 0.1, "pitch parity within 0.1px")
    ck(math.abs(one.gap   - two.gap)   < 0.1, "gap parity within 0.1px")
    ck(math.abs(one.halo  - two.halo)  < 0.2, "halo parity within 0.2px")
    ck(two.haloOff == 0, "2.0 halo has no vertical offset either (1.x item.lua:57)")

    -- RATIOS are the density-invariant contract: whatever the density slider does, a 2.0
    -- cell must be the same SHAPE as a 1.x cell.
    ck(approx(one.cell / one.pitch, two.cell / two.pitch), "icon-to-pitch ratio identical (37/39)")
    ck(approx(one.halo / one.cell,  two.halo / two.cell),  "halo-to-cell ratio identical (67/37)")

    -- ...and it holds at a non-default density, which is what "every density reads like a
    -- scaled 1.x" means. 2.0 at cell 48 vs 1.x scaled to the same cell.
    local twoBig = Parity.TwoOhComposite(1.0, 48, math.floor(48 * 2 / 37 + 0.5))
    ck(approx(twoBig.halo / twoBig.cell, one.halo / one.cell), "halo ratio holds at cell 48")

    -- PERCEIVED read-outs, the numbers the owner is actually looking at.
    local p1, p2 = Parity.Perceived(one), Parity.Perceived(two)
    ck(math.abs(p1.overhang - p2.overhang) < 0.1, "halo overhang past the icon matches (~13.4px)")
    ck(math.abs(p1.bleed    - p2.bleed)    < 0.1, "halo bleed onto the neighbour icon matches (~11.6px)")
    ck(math.abs(p1.fill     - p2.fill)     < 1e-9, "icon fill of the pitch matches (0.949)")
    -- Sanity on the shape of the answer: the halo DOES reach the neighbour in both models
    -- (that is 1.x's look, not a defect) and it overhangs by more than the gap.
    ck(p1.bleed > 0 and p2.bleed > 0, "both models bleed onto the neighbour (1.x behaviour)")
end

-- ROW 6-9: the GLOW constants, 2.0's live values against the 1.x transcription.
local function testGlowRow(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local B, X = ns.Borders, Parity.ONE_X
    if not B then fails[#fails + 1] = "ns.Borders not loaded"; return end

    ck(B.GLOW_TEXTURE == X.GLOW_TEXTURE, "glow texture == 1.x item.lua:55")
    ck(approx(B.GlowSize(X.BUTTON_SIZE), X.GLOW_SIZE), "a 37px cell yields 1.x's literal 67px halo")
    ck(B.GLOW_ALPHA == X.GLOW_ALPHA, "glow alpha == 1.x settings.lua:34 (0.5)")
    ck(B.GlowOffsetY(X.BUTTON_SIZE) == X.GLOW_OFFSET_Y, "glow offset == 1.x item.lua:57 (none)")
    ck(B.GLOW_LAYER == X.GLOW_LAYER, "glow layer == 1.x item.lua:54 (OVERLAY)")
    ck(B.GLOW_SUBLEVEL == X.GLOW_SUBLEVEL, "glow sublevel == 1.x item.lua:54 (-1)")

    -- Tint chain ORDER and the two literal colours 1.x hardcodes.
    local MIN = X.MIN_QUALITY
    local qr, qg, qb = B.QuestRGB()
    ck(approx(qr, X.QUEST_RGB[1]) and approx(qg, X.QUEST_RGB[2]) and approx(qb, X.QUEST_RGB[3]),
        "quest gold == 1.x item.lua:198 (1, .82, .2)")
    local sr, sg, sb = B.SetRGB()
    ck(approx(sr, X.SET_RGB[1]) and approx(sg, X.SET_RGB[2]) and approx(sb, X.SET_RGB[3]),
        "set teal == 1.x item.lua:202 (.2, 1, .8)")
    ck(B.DEFAULT_MIN_QUALITY == X.MIN_QUALITY, "rarity floor == 1.x item.lua:203 (quality > 1)")

    -- Walk the transcribed order and assert each branch wins over everything below it.
    for i, winner in ipairs(X.TINT_ORDER) do
        if winner ~= "quality" then
            -- turn on the winner AND every loser below it
            local f = { quest = false, unusable = false, set = false }
            for j = i, #X.TINT_ORDER do
                if X.TINT_ORDER[j] ~= "quality" then f[X.TINT_ORDER[j]] = true end
            end
            local r = { B.ResolveTint(5, f.unusable, f.quest, f.set, true, MIN) }
            local want
            if winner == "quest" then want = X.QUEST_RGB
            elseif winner == "set" then want = X.SET_RGB
            else want = { B.UnusableRGB() } end
            ck(approx(r[1], want[1]) and approx(r[2], want[2]) and approx(r[3], want[3]),
                "chain row " .. i .. ": '" .. winner .. "' wins over everything below it")
        end
    end
    -- ...and the bottom of the chain (rarity) only fires when nothing above it does.
    ck(approx((select(1, B.ResolveTint(3, false, false, false, true, MIN))), B.QualityRGB(3)),
        "chain row " .. #X.TINT_ORDER .. ": 'quality' is the fallthrough")
end

-- ROW 10-16: THE CELL COMPOSITION — how many things, and which things, are drawn on one
-- cell. This is the row the owner's "cluttered" verdict is actually about.
local function testCellComposition(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local Items, B, X = ns.Items, ns.Borders, Parity.ONE_X
    if not (Items and B) then fails[#fails + 1] = "ns.Items / ns.Borders not loaded"; return end

    -- SUBSTRATE. 1.x creates ZERO cell-background regions (item.lua:51-52 hides the
    -- template's and adds none). 2.0 must create zero too — the retired `inset`/`raised`
    -- well is the lattice of hard-edged squares the owner read as "borders".
    ck(X.CELL_SUBSTRATE_REGIONS == 0, "1.x model: no cell substrate region")
    ck(B.WellAlpha == nil and B.SetWellAlpha == nil, "2.0: the well API is retired")
    ck(B.WELL_GLOW_ALPHA == nil and B.WELL_FULL_ALPHA == nil, "2.0: no well alpha constants")

    -- EMPTY CELL — measured against the OWNER'S live 1.x profile, not 1.x's shipped
    -- defaults. His slotBackground is the faction crest (6), NOT the bevelled backpack art
    -- (2), and his slotAlpha is 0.29, NOT 1.
    ck(Items.SlotBackground() == X.EMPTY_BACKGROUND,
        "2.0 empty cell uses the owner's slotBackground (6 = faction crest, item.lua:18)")
    ck(approx(Items.SlotAlpha(), X.EMPTY_ALPHA),
        "…at the owner's slotAlpha (0.29), not 1.x's shipped default of 1")
    ck(type(Items.SlotBackgroundArt(X.EMPTY_BACKGROUND)) == "table"
        and Items.SlotBackgroundArt(X.EMPTY_BACKGROUND).atlas ~= nil,
        "…and enum 6 resolves to an ATLAS entry, as 1.x's Backgrounds[6] function does")
    ck(Items.SlotBackgroundArt(1) == nil, "enum 1 (None) draws no empty-slot art (1.x Era)")
    ck(tostring(Items.SlotBackgroundArt(2)):lower():gsub("\\", "/")
        :find("paperdoll/ui%-backpack%-emptyslot") ~= nil,
        "enum 2 is still 1.x's Backgrounds[2] art (item.lua:14) for anyone who picks it")
    -- The empty cell's icon alpha reaches the dress as its OWN multiplier, so the search
    -- dim and slotAlpha compose the way they compose on screen in 1.x.
    ck(approx(Items.ResolveState({ emptySlot = true }).iconAlpha, X.EMPTY_ALPHA),
        "…and the empty-cell spec carries slotAlpha as the icon's own alpha")
    ck(Items.ResolveState({ quality = 2, filled = true }).iconAlpha == 1,
        "…while a FILLED cell's icon is always full alpha (1.x item.lua:167)")

    -- SLOT BORDER. 1.x creates it for every cell and colours it on every update; the owner
    -- runs it visible. 2.0 must draw it on every cell too, at his colour, 2px.
    ck(X.SLOT_BORDER_SCOPE == "all", "1.x model: the slot border frames EVERY cell")
    ck(Items.SLOT_BORDER_PX == X.SLOT_BORDER_PX, "slot border is 2px (1.x item.lua:69)")
    do
        local r, g, b, a = Items.SlotBorderColor()
        local w = X.SLOT_BORDER_RGBA
        ck(approx(r, w[1]) and approx(g, w[2]) and approx(b, w[3]) and approx(a, w[4]),
            "slot border colour == the owner's slotBorderColor (0.208, 0, 0.024, 0.59)")
        ck(a > X.SLOT_BORDER_ALPHA_1X_DEFAULT,
            "…and it is VISIBLE, unlike 1.x's shipped {1,1,1,0} default")
    end

    -- ICON CROP. 1.x never calls SetTexCoord on an item icon, so the icon file's own baked
    -- dark rim shows and gives each cell its separation. 2.0 must not crop either.
    ck(X.ICON_TEXCOORD == nil, "1.x model: icon is uncropped (no SetTexCoord)")

    -- ICONBORDER + JUNKICON: driven, not killed.
    ck(X.ICONBORDER_DRIVEN == true and type(B.SetIconBorder) == "function",
        "2.0 drives the template IconBorder (1.x item.lua:210/220)")
    ck(X.JUNKICON_DRIVEN == true and Items.ResolveState({ quality = 0 }).junkCoin == true,
        "2.0 drives the template JunkIcon (1.x item.lua:222)")
    ck(Items.ResolveState({ quality = 0 }).iconDesat == false,
        "…and does NOT greyscale a junk icon (1.x item.lua:170 keeps full colour)")

    -- COUNT numeral: template default in both.
    ck(X.COUNT_RESTYLED == false, "1.x model: the numeral is never restyled")

    -- SEARCH DIM.
    ck(Items.DressAlpha(true) == X.DIM_ALPHA, "dim alpha == 1.x item.lua:233 (0.3)")

    -- CORNER PIPS. 1.x draws none. 2.0 keeps exactly ONE knowingly-divergent mark (the
    -- new-item wax dot, an owner-requested 2.0 feature 1.x has no counterpart for — 1.x
    -- hides NewItemTexture outright at item.lua:49). The equipment-set pip is retired
    -- because 1.x DOES have a counterpart for it and it is a glow branch, not a mark.
    ck(X.CORNER_PIPS == 0 and X.NEWITEM_KILLED == true, "1.x model: no corner pips at all")
    ck(Items.MarkerArt("set") == nil, "2.0: the set pip is retired (1.x makes it a teal glow)")
    ck(Items.MarkerArt("new") ~= nil, "2.0: the new-item dot is the ONE knowing divergence")
    ck(Items.ResolveState({ quality = 3, isSet = true }).showSetMark == false,
        "…and no state can turn the set pip back on")

    -- THE COUNT. This is the single number the owner's "cluttered" verdict reduces to:
    -- how many distinct things are drawn on ONE cell. Derived from the LIVE 2.0 model, not
    -- asserted as a literal, so it moves the moment a future round adds an element.
    ck(Parity.TwoOhElementCount(ctxOf(1)) == Parity.OneXElementCount(ctxOf(1)),
        "filled COMMON cell: same element count as 1.x")
    ck(Parity.TwoOhElementCount(ctxOf(nil)) == Parity.OneXElementCount(ctxOf(nil)),
        "EMPTY cell: same element count as 1.x")
    ck(Parity.TwoOhElementCount(ctxOf(4)) == Parity.OneXElementCount(ctxOf(4)),
        "EPIC cell: same element count as 1.x (icon + halo + ring)")
    ck(Parity.TwoOhElementCount(ctxOf(0)) == Parity.OneXElementCount(ctxOf(0)),
        "JUNK cell: same element count as 1.x (icon + coin)")
    -- SET MEMBER. This is the regression row. 1.x cannot draw the teal on this client at
    -- all (SET_BRANCH_LIVE = false), and 2.0's cue is default-OFF, so a set member must
    -- render EXACTLY like any other cell of its rarity — no extra element, and the rarity
    -- colour it would otherwise lose.
    ck(Parity.TwoOhElementCount(ctxOf(3, { isSet = true }))
        == Parity.OneXElementCount(ctxOf(3, { isSet = true })),
        "SET member: same element count as 1.x (no teal — 1.x's set branch is a nop here)")
    ck(Items.SetCueEnabled() == false,
        "the equipment-set teal is OFF by default (1.x parity: ItemSearch nop on Era)")
    ck(Parity.TwoOhElementCount(ctxOf(3, { isSet = true }))
        == Parity.TwoOhElementCount(ctxOf(3)),
        "…so a RARE set member draws the same cell as a rare non-member")

    -- The ONE row where the two models are knowingly allowed to differ, by exactly one:
    -- the new-item wax dot, which 1.x does not have at all (it hides NewItemTexture).
    local newCtx = ctxOf(1, { isNew = true })
    ck(Parity.TwoOhElementCount(newCtx) - Parity.OneXElementCount(newCtx) == 1,
        "NEW item: 2.0 draws exactly ONE more element than 1.x (the wax dot — owner feature)")
end

-- MUTATION TESTS. A parity suite that cannot fail is worthless. These flip a row of the
-- 1.x model and assert the corresponding check would have caught it — proving the suite
-- is wired to the real values and not to itself.
local function testMutations(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local X = Parity.ONE_X

    -- MUTATION 1 — the GLOW SIZE row. Put the previous round's spec value (68) back into the
    -- 1.x model and the geometry composite must diverge beyond its own tolerance.
    local saved = X.GLOW_SIZE
    X.GLOW_SIZE = 68
    local one, two = Parity.OneXComposite(), Parity.TwoOhComposite()
    ck(math.abs(one.halo - two.halo) >= 0.2 or math.abs(one.halo / one.cell - two.halo / two.cell) > 1e-9,
        "MUTATION: a 68px 1.x halo is detected as a mismatch (the glow-size row is live)")
    X.GLOW_SIZE = saved
    local one2, two2 = Parity.OneXComposite(), Parity.TwoOhComposite()
    ck(math.abs(one2.halo - two2.halo) < 0.2, "…and restoring 67 makes the row pass again")

    -- MUTATION 2 — the CELL PITCH row. Loosen 1.x's spacing to the pre-parity 4 and the
    -- pitch/gap/fill checks must all diverge.
    local savedSp, savedPitch = X.SPACING, X.PITCH_UNITS
    X.SPACING, X.PITCH_UNITS = 4, 41
    local one3, two3 = Parity.OneXComposite(), Parity.TwoOhComposite()
    ck(math.abs(one3.pitch - two3.pitch) >= 0.1, "MUTATION: a 41px 1.x pitch is detected (pitch row is live)")
    ck(math.abs(Parity.Perceived(one3).fill - Parity.Perceived(two3).fill) > 1e-9,
        "MUTATION: …and the icon-fill ratio moves with it")
    X.SPACING, X.PITCH_UNITS = savedSp, savedPitch
    local one4, two4 = Parity.OneXComposite(), Parity.TwoOhComposite()
    ck(math.abs(one4.pitch - two4.pitch) < 0.1, "…and restoring 39 makes the row pass again")

    -- MUTATION 3 — the DIM row, against the live 2.0 value rather than a local copy.
    local savedDim = X.DIM_ALPHA
    X.DIM_ALPHA = 0.25
    ck(ns.Items.DressAlpha(true) ~= X.DIM_ALPHA, "MUTATION: a 0.25 dim is detected (dim row is live)")
    X.DIM_ALPHA = savedDim
    ck(ns.Items.DressAlpha(true) == X.DIM_ALPHA, "…and restoring 0.3 makes the row pass again")

    -- MUTATION 4 — the EMPTY-CELL row. Put the previous round's citation (1.x's shipped
    -- defaults: the bevelled backpack art at alpha 1) back into the model and the live 2.0
    -- values must be detected as a mismatch.
    local savedBg, savedAlpha = X.EMPTY_BACKGROUND, X.EMPTY_ALPHA
    X.EMPTY_BACKGROUND, X.EMPTY_ALPHA = 2, 1
    ck(ns.Items.SlotBackground() ~= X.EMPTY_BACKGROUND,
        "MUTATION: '1.x default' slotBackground=2 is detected (the empty-art row is live)")
    ck(ns.Items.SlotAlpha() ~= X.EMPTY_ALPHA,
        "MUTATION: …and slotAlpha=1 is detected too")
    X.EMPTY_BACKGROUND, X.EMPTY_ALPHA = savedBg, savedAlpha
    ck(ns.Items.SlotBackground() == X.EMPTY_BACKGROUND and ns.Items.SlotAlpha() == X.EMPTY_ALPHA,
        "…and restoring the owner's 6 / 0.29 makes the row pass again")

    -- MUTATION 5 — the SLOT-BORDER row. Flip the model back to 1.x's invisible default and
    -- both the colour check and the per-cell element count must move.
    local savedRGBA = X.SLOT_BORDER_RGBA
    X.SLOT_BORDER_RGBA = { 1, 1, 1, 0 }
    local r5, g5, b5, a5 = ns.Items.SlotBorderColor()
    ck(not (approx(r5, 1) and approx(g5, 1) and approx(b5, 1) and approx(a5, 0)),
        "MUTATION: 1.x's invisible {1,1,1,0} default is detected (the slot-border row is live)")
    ck(Parity.OneXElementCount(ctxOf(1)) ~= Parity.TwoOhElementCount(ctxOf(1)),
        "MUTATION: …and an unpainted 1.x slot border moves the element count")
    X.SLOT_BORDER_RGBA = savedRGBA
    ck(Parity.OneXElementCount(ctxOf(1)) == Parity.TwoOhElementCount(ctxOf(1)),
        "…and restoring the owner's 59% edge makes the row pass again")

    -- MUTATION 6 — the SET-CUE row. Declare 1.x's set branch live (as it would be with
    -- ItemRack loaded) while 2.0's cue stays off, and the set member's cell must diverge.
    local savedLive = X.SET_BRANCH_LIVE
    X.SET_BRANCH_LIVE = true
    local setCtx = ctxOf(1, { isSet = true })
    ck(Parity.OneXElementCount(setCtx) ~= Parity.TwoOhElementCount(setCtx),
        "MUTATION: a live 1.x set branch is detected against 2.0's default-off cue")
    X.SET_BRANCH_LIVE = savedLive
    ck(Parity.OneXElementCount(setCtx) == Parity.TwoOhElementCount(setCtx),
        "…and restoring the nop makes the row pass again")

    -- MUTATION 7 — the ELEMENT-COUNT row, mutated on the 2.0 side. Re-introduce a cell
    -- substrate (the retired well) as one more drawn element and the count row must break.
    local realTwoOh = Parity.TwoOhElementCount
    Parity.TwoOhElementCount = function(ctx) return realTwoOh(ctx) + 1 end   -- "the well is back"
    local c = ctxOf(1)
    ck(Parity.TwoOhElementCount(c) ~= Parity.OneXElementCount(c),
        "MUTATION: a resurrected cell substrate is detected (the element-count row is live)")
    Parity.TwoOhElementCount = realTwoOh
    ck(Parity.TwoOhElementCount(c) == Parity.OneXElementCount(c),
        "…and removing it again makes the row pass")
end

function Parity.RunSelfTests(verbose)
    local suites = {
        { name = "geometry composite",  fn = testGeometryComposite },
        { name = "glow row (1.x)",      fn = testGlowRow },
        { name = "cell composition",    fn = testCellComposition },
        { name = "mutation guards",     fn = testMutations },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS cell-parity/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL cell-parity/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("cell-parity", Parity.RunSelfTests)
end

return Parity
