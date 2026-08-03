-- Daseeki Bags 2.0 — borders.lua
-- LAYER 1 of the two-layer item dress: QUALITY as quiet identity (Field Ledger).
--
-- The quality cue is INFORMATION the player wants (rarity-at-a-glance).
--
-- ── The cue is a soft GLOW, not a hard outline — now SPEC-EXACT ───────────────────
-- The beta drew a thin hard quality-colored SQUARE OUTLINE around each cell. The look
-- the owner wants is a soft additive halo that washes over the icon edge. The display
-- round shipped an approximation of that; this file now matches the clean-room
-- CII_BEHAVIOR_SPEC.md §2 anatomy exactly — 68/37 (not 67/37), alpha 0.49 (not 0.5),
-- a (0, 1) CENTER offset, and a plain OVERLAY texture with no sublevel. See the SUITE
-- GLOW GEOMETRY block for the parameter-by-parameter derivation, including why the
-- spec's fixed pixel sizes are carried here as ratios against its 37px reference button.
--
-- Spec §3 gating is SURFACE-DEPENDENT and this file serves the BAG surface: the
-- reference's item-link/id lookup path (bags, bank, merchant) requires quality above
-- Common, which is exactly our Uncommon+ floor, plus the quest-item override. The
-- EVERY-QUALITY rule (poor and common included) belongs to the equipped-slot path and
-- lives in Daseeki-Armory's borders.lua.
--
-- What did NOT change: the per-quality COLORS (full saturation), the configurable
-- min-quality floor (db.qualityBorderMin, default Uncommon+), the on/off toggle
-- (db.qualityBorders), and the precedence chain quest gold > unusable red > rarity.
-- The quest-bang and marker art in ui_items are untouched — this file only ever drew
-- the rarity cue.
--
-- Historical note (the outline era, kept because its reasoning still governs the
-- SHARED snapped-outline factory at the bottom of this file, which the item grid's
-- per-cell WELL border still uses): a 1px edgeSize on a BackdropTemplate half-samples
-- at fractional scale into a fuzzy grey rim, so snapped WHITE8X8 textures with
-- SetSnapToPixelGrid(true) + SetTexelSnappingBias(0) are what stay crisp at 720p.
--
-- SECURE / TAINT (C rule 1): the glow is a non-secure Frame child of the button with
-- texture children only. Attach() (structure) runs at button CREATION (out of combat,
-- gated by ui_items' combat-deferred layout) — the dress is BAKED at creation, never
-- restyled-in-combat structurally. Apply() (recolor / show / hide / resize the edge
-- textures) touches ONLY children and is a texture op, safe even mid-combat. No
-- protected op (SetParent/SetPoint/Show/Hide/SetID/SetAttribute/SetSize/SetFrameLevel)
-- is ever called on the secure button itself at runtime.
--
-- Split into a PURE decision layer (ShouldShow / QualityRGB / GlowSize / TierPx /
-- Desaturate / Enabled — headless-testable) and a thin FRAME layer (Attach / Apply /
-- SetAlpha — in-game only, guarded on _G.CreateFrame). Fresh code — no lines copied
-- from anywhere; the glow PARAMETERS are behavior facts quoted from the clean-room
-- CII_BEHAVIOR_SPEC.md, which is the only reference this file was written against.
--
-- Toggle: Store.db.qualityBorders (defaults ON when unset).

local ADDON, ns = ...

local Borders = {}
ns.Borders = Borders

local Store = ns.Store

-- 1.0-PARITY floor: UNCOMMON and up (1.x glowQuality: quality > 1). Below this a slot
-- shows no colored edge. The floor is now CONFIGURABLE (db.qualityBorderMin) via the
-- "Item borders" options group; this is the default when unset.
local DEFAULT_MIN_QUALITY = 2
Borders.DEFAULT_MIN_QUALITY = DEFAULT_MIN_QUALITY
Borders.MIN_QUALITY = DEFAULT_MIN_QUALITY   -- back-compat alias (== the default floor)
-- Epic and up render a 2px snapped edge (the only 2px in the grid).
local EPIC_QUALITY = 4
Borders.EPIC_QUALITY = EPIC_QUALITY

-- Desaturation util retained for callers/tests; the quality edge no longer uses it —
-- 1.0 parity (and CII) shows FULL-SATURATION rarity colors, since the old ~15%
-- parchment pull read grey on the near-black Daseeki ground (owner report).
local PARCHMENT_PULL = 0.15
Borders.PARCHMENT_PULL = PARCHMENT_PULL
local PARCHMENT = { 0.9137, 0.8784, 0.8039 }
Borders._parchment = PARCHMENT

-- Live min-quality floor: db.qualityBorderMin (Uncommon 2 / Rare 3 / Epic 4), default 2.
function Borders.MinQuality()
    local db = Store and Store.db
    local v = db and db.qualityBorderMin
    if type(v) == "number" and v >= 0 then return v end
    return DEFAULT_MIN_QUALITY
end

-- UNUSABLE red — the exact 1.x glowUnusable color: RED_FONT_COLOR (~ {1, 0.1, 0.1}).
-- Deliberately NOT the Daseeki `danger` token: that token is an ORANGE-red (#E05528) that
-- sits close to Legendary orange, whereas a pure bright red is the unmistakable "can't use"
-- cue and stays maximally distinct from every rarity color. Fall back to a literal red.
function Borders.UnusableRGB()
    local rc = _G.RED_FONT_COLOR
    if rc and rc.r then return rc.r, rc.g, rc.b end
    return 1, 0.1, 0.1
end

-- QUEST gold — our 1.x quest tint (1, .82, .2), kept as a literal because it is NOT
-- NORMAL_FONT_COLOR (which is 1, .82, 0): routing it through a Blizzard global would
-- silently shift the blue channel.
--
-- DELIBERATE DIVERGENCE from CII_BEHAVIOR_SPEC §3. The spec's quest-item override uses
-- a synthetic quality appended to the color table at PURE YELLOW (1, 1, 0). We keep our
-- warmer GOLD. The spec legitimises the OVERRIDE (quest class wins over rarity, which is
-- what our precedence chain does); the exact tint is a suite look decision, and gold
-- reads as "quest" against the near-black Daseeki ground where a pure yellow sits close
-- to Legendary orange under an ADD blend. Owner-flagged, not an oversight.
function Borders.QuestRGB()
    return 1, 0.82, 0.2
end

-- POOR near-black (CII_BEHAVIOR_SPEC §3). The reference MUTATES the bag quality-color
-- table at load so quality 0 is r=g=b=0.1 rather than Blizzard's 0.62 grey, and every
-- surface that resolves a color reads the mutated table. Under an ADD blend a 0.1 tint
-- is very nearly nothing, which is the point: a poor item registers as "bordered but
-- almost dark" rather than as a bright grey halo. Modelled here as an OVERRIDE that
-- wins over the live provider, because the reference's mutation likewise wins over
-- Blizzard's own value. In Bags this is a DORMANT path — the bag floor is Uncommon+
-- (spec §3, the item-link lookup requires quality > Common) so a poor item never
-- glows here — but the color layer is a sibling contract with Armory's equipped
-- surface (where poor DOES glow), so both files carry it verbatim.
local POOR_RGB = { 0.1, 0.1, 0.1 }
Borders.POOR_RGB = POOR_RGB

----------------------------------------------------------------------
-- Public quality colors (Blizzard's ITEM_QUALITY_COLORS values; game facts, not
-- addon code) — used only when neither C_Item nor _G.ITEM_QUALITY_COLORS is present
-- (i.e. the headless harness), so QualityRGB is deterministic under test.
----------------------------------------------------------------------
local FALLBACK = {
    [0] = { 0.1,  0.1,  0.1  }, -- Poor — spec §3 near-black override, NOT Blizzard's 0.62 grey
    [1] = { 1.00, 1.00, 1.00 }, -- Common (white)
    [2] = { 0.12, 1.00, 0.00 }, -- Uncommon (green)
    [3] = { 0.00, 0.44, 0.87 }, -- Rare (blue)
    [4] = { 0.64, 0.21, 0.93 }, -- Epic (purple)
    [5] = { 1.00, 0.50, 0.00 }, -- Legendary (orange)
    [6] = { 0.90, 0.80, 0.50 }, -- Artifact
    [7] = { 0.00, 0.80, 1.00 }, -- Heirloom
}
Borders._fallback = FALLBACK

----------------------------------------------------------------------
-- PURE decision layer (headless-testable)
----------------------------------------------------------------------

-- r,g,b (0..1) for a quality. `provider(quality) -> r,g,b` is injected (live: the
-- game's quality-color function); the static table is the last resort. nil quality
-- (a still-uncached migrated item) yields nil so the caller hides the edge.
function Borders.QualityRGB(quality, provider)
    if quality == nil then return nil end
    -- Poor is the one quality whose color is NOT the game's: spec §3 replaces it with
    -- near-black, so the override runs BEFORE the provider (the reference mutates the
    -- shared table, so its value is what every lookup sees).
    if quality == 0 then return POOR_RGB[1], POOR_RGB[2], POOR_RGB[3] end
    if provider then
        local r, g, b = provider(quality)
        if r then return r, g, b end
    end
    local c = FALLBACK[quality]
    if c then return c[1], c[2], c[3] end
    return nil
end

-- True when a colored edge should be shown for this quality given the toggle and the
-- (configurable) minimum-quality floor. minQuality defaults to the Uncommon+ default.
function Borders.ShouldShow(quality, enabled, minQuality)
    if not enabled then return false end
    if quality == nil then return false end
    return quality >= (minQuality or DEFAULT_MIN_QUALITY)
end

-- PURE: the WHOLE precedence chain in one place — 1.x's UpdateBorder branch order, top
-- down: quest gold > unusable red > rarity (above the floor). Returns r,g,b for the tint
-- the cell should glow, or nil when it should not glow at all. `provider` is injected
-- exactly as for QualityRGB (live: the game's quality-color function).
--
-- This is the SINGLE glow decision. Apply() paints from it and the well-yield suppression
-- keys off it, so "is this cell glowing?" has exactly one answer and the halo and the well
-- can never disagree about a cell's state.
function Borders.ResolveTint(quality, unusable, quest, enabled, minQuality, provider)
    if not enabled then return nil end
    if quest    then return Borders.QuestRGB() end          -- 1.x's FIRST branch
    if unusable then return Borders.UnusableRGB() end       -- "can't use", over rarity
    if not Borders.ShouldShow(quality, enabled, minQuality) then return nil end
    return Borders.QualityRGB(quality, provider)            -- may still be nil (unknown quality)
end

-- PURE: the boolean form of ResolveTint — "does this cell's halo show?".
function Borders.GlowShown(quality, unusable, quest, enabled, minQuality, provider)
    return Borders.ResolveTint(quality, unusable, quest, enabled, minQuality, provider) ~= nil
end

----------------------------------------------------------------------
-- SUITE GLOW GEOMETRY — the CII_BEHAVIOR_SPEC §2 border anatomy
--
-- 2.0 first drew the quality cue as a thin HARD square outline; the owner wanted the
-- soft additive halo back, and the display round shipped an approximation of it. This
-- block is the SPEC-EXACT version: every number below is taken from the clean-room
-- behavioral spec (CII_BEHAVIOR_SPEC.md §2), not from an approximation.
--
-- Spec §2, restated:
--   * texture  Interface\Buttons\UI-ActionButton-Border (the soft action-button glow)
--   * layer    a plain OVERLAY child texture of the button — NO negative sublevel
--   * blend    ADD, so it adds light over the icon edge instead of rimming it
--   * size     68 x 68 on a 37 x 37 item button (Ammo slot excepted: 58 x 58)
--   * anchor   CENTER to the parent's CENTER, offset (0, 1)
--   * alpha    0.49 applied UNIFORMLY to every border
--
-- Those are FIXED pixel values in the reference because the reference only ever draws
-- on 37px buttons. Our buttons are not fixed: the Bags density slider moves the cell
-- size, and the sibling Armory draws on 37px paper-doll slots AND 32px flyout leads.
-- So we carry the spec's numbers as RATIOS against its 37px reference button —
-- 68/37, 58/37, 1/37 — and derive size and offset from the host button's measured
-- width. At 37px that reproduces the spec exactly (68, 58, 1); at any other size it
-- reproduces the same halo PROPORTION, so the look is identical at every density.
--
-- The overhang is the whole point: at 68/37 the halo is ~1.84x the cell, which is what
-- makes it bleed past the icon as a wash instead of sitting on the edge as a rim.
--
-- These ship as CONSTANTS, not settings — no new SavedVariables key. The reference
-- exposes alpha as a user "intensity" clamped [0.1, 1.0]; we deliberately do not, and
-- pin its DEFAULT (0.49) as our one value. Precedence (quest gold > unusable red >
-- rarity) and the configurable Borders.MinQuality() floor are unchanged.
--
-- Armory's borders.lua carries this identical constant block (the sibling contract);
-- both harnesses gate the numbers so the two can never drift apart silently.
----------------------------------------------------------------------
Borders.GLOW_TEXTURE = "Interface\\Buttons\\UI-ActionButton-Border"
Borders.GLOW_REF_BUTTON = 37     -- spec §2: the reference's item-button side length
Borders.GLOW_SCALE      = 68 / 37   -- spec §2: a 68px halo on a 37px item button
Borders.GLOW_SCALE_AMMO = 58 / 37   -- spec §2 exception: the Ammo slot halo is 58px
Borders.GLOW_ALPHA      = 0.49      -- spec §2/§5: the reference "intensity" default
Borders.GLOW_OFFSET_Y_SCALE = 1 / 37 -- spec §2: CENTER anchored with a (0, 1) offset

-- PURE: the halo's side length for a cell of `buttonSize`, so the wash bleeds past the
-- icon by the spec's proportion at any cell size the density slider produces. Pass
-- `ammo` truthy for the spec's 58px Ammo-slot exception (no ammo cell exists in Bags;
-- the parameter is here so the pure layer matches Armory's byte for byte).
function Borders.GlowSize(buttonSize, ammo)
    local s = tonumber(buttonSize) or 0
    if s <= 0 then return 0 end
    return s * (ammo and Borders.GLOW_SCALE_AMMO or Borders.GLOW_SCALE)
end

-- PURE: the halo's vertical CENTER offset for a cell of `buttonSize` — the spec's
-- (0, 1) nudge, carried as a ratio so it stays proportional at any cell size.
function Borders.GlowOffsetY(buttonSize)
    local s = tonumber(buttonSize) or 0
    if s <= 0 then return 0 end
    return s * Borders.GLOW_OFFSET_Y_SCALE
end

----------------------------------------------------------------------
-- WELL YIELD — the glowing cell's own edge art steps out of the halo's way
--
-- The per-slot dress (ui_items.ensureDress) paints a WELL texture on every cell: a solid
-- `inset` rect when empty, recolored `raised` when filled, inset 1px inside the button.
-- That rect IS the cell's visible edge in 2.0 — there is no separate hairline any more.
-- Its boundary is HARD and full-strength, so under the soft additive halo a glowing cell
-- read as "grey square with a glow behind it" instead of "the glow owns this cell"
-- (owner report, side-by-side against 1.x).
--
-- 1.x has no such conflict by construction: Item:Construct does `normal:Hide()` on the
-- button's NormalTexture outright, so a 1.x cell carries NO slot art of its own and the
-- IconGlow is the only thing describing the cell edge. We match the PERCEIVED result
-- rather than the mechanism — our well still exists (empty and non-glowing cells want
-- it), it just yields to alpha 0 for exactly as long as that cell is glowing.
--
-- STATE-DRIVEN, single source of truth: the suppression is keyed off ResolveTint below —
-- the same call that decides whether the halo shows at all — so the two can never drift.
-- Any tint (quest gold, unusable red, rarity) suppresses; no tint restores. Restoration
-- is automatic on every repaint that stops glowing: item removed (Apply(button, nil)),
-- quality dropped below the floor, the min-quality slider raised, or the Item-borders
-- toggle switched off (options.lua's regrid repaints).
--
-- CONSTANTS, not settings — no new SavedVariables key, exactly like the glow geometry.
--
-- SEARCH-DIM is untouched: the dim cascade (Items._applyDress -> Borders.SetAlpha) scales
-- the GLOW CONTAINER's alpha and has never touched the well. Region alpha (SetAlpha) and
-- texture color alpha (SetColorTexture) are independent multipliers, so ui_items'
-- setWellState recolor after Apply cannot resurrect a suppressed well, and our SetAlpha
-- cannot fight the recolor — the two are order-independent.
----------------------------------------------------------------------
Borders.WELL_GLOW_ALPHA = 0    -- glowing cell: the well yields entirely (1.x: normal:Hide())
Borders.WELL_FULL_ALPHA = 1    -- everything else: the quiet inset/raised well, unchanged

-- PURE: the well's region alpha for a cell whose glow is / is not shown.
function Borders.WellAlpha(glowShown)
    if glowShown then return Borders.WELL_GLOW_ALPHA end
    return Borders.WELL_FULL_ALPHA
end

-- Edge thickness in LOGICAL pixels for a quality: epic+ = 2, uncommon/rare = 1. Only
-- meaningful when ShouldShow is true. RETAINED as a pure tier descriptor (and used by
-- the shared snapped-outline factory below), but it no longer drives the QUALITY cue:
-- since ITEM 8 that is a uniform-intensity glow, exactly as 1.x, which applies one
-- glowAlpha to every rarity and lets the COLOR carry the distinction.
function Borders.TierPx(quality)
    if quality == nil then return 0 end
    if quality >= EPIC_QUALITY then return 2 end
    if quality >= DEFAULT_MIN_QUALITY then return 1 end
    return 0
end

-- Desaturate a color toward a parchment target by `amount` (0 = original, 1 = target).
-- Pulls each channel a fraction of the way to parchment cream: retains (1-amount) of
-- the original chroma while warming slightly toward the ledger substrate. Hue-preserving
-- for small amounts (verified by the hue-table self-test). tr,tg,tb default to PARCHMENT.
function Borders.Desaturate(r, g, b, amount, tr, tg, tb)
    if r == nil then return nil end
    amount = amount or PARCHMENT_PULL
    tr = tr or PARCHMENT[1]; tg = tg or PARCHMENT[2]; tb = tb or PARCHMENT[3]
    return r + (tr - r) * amount,
           g + (tg - g) * amount,
           b + (tb - b) * amount
end

-- The edge toggle, read live from the store settings. Defaults ON when the store or
-- the key is absent (so edges render before W4 writes a persisted value).
function Borders.Enabled()
    local db = Store and Store.db
    if type(db) ~= "table" then return true end
    if db.qualityBorders == nil then return true end
    return db.qualityBorders and true or false
end

----------------------------------------------------------------------
-- FRAME layer (in-game only; every WoW API call guarded)
----------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Live quality-color provider: C_Item is authoritative; ITEM_QUALITY_COLORS is the
-- FrameXML fallback. Passed into QualityRGB so the static table is never reached live.
local function liveProvider(quality)
    local CI = _G.C_Item
    if CI and CI.GetItemQualityColor then
        local r, g, b = CI.GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    local c = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[quality]
    if c then return c.r, c.g, c.b end
end

-- One physical pixel in `frame`'s local coordinate units (game fact; mirrors Blizzard's
-- PixelUtil math: 768/physicalHeight / effective scale). Used so the snapped edge is a
-- true 1px (or 2px) at any resolution/scale and re-snaps crisply at 720p.
local function onePixel(frame)
    local physH = 1080
    if _G.GetPhysicalScreenSize then
        local _, h = _G.GetPhysicalScreenSize()
        if h and h > 0 then physH = h end
    end
    local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
    if scale <= 0 then scale = 1 end
    return (768 / physH) / scale
end

-- Shared re-snap driver: one frame listens for the two display events and re-lays every
-- live quality edge so the physical thickness stays exact across scale/resolution
-- changes (dead ones self-prune). Mirrors the Core UI.Hairline snap driver.
local snapSet
local snapDriver
local function ensureSnapDriver()
    if snapDriver or not _G.CreateFrame then return end
    snapSet = snapSet or setmetatable({}, { __mode = "k" })
    snapDriver = _G.CreateFrame("Frame")
    snapDriver:RegisterEvent("UI_SCALE_CHANGED")
    snapDriver:RegisterEvent("DISPLAY_SIZE_CHANGED")
    snapDriver:SetScript("OnEvent", function()
        for b in pairs(snapSet) do
            if b._dsRelayout then b:_dsRelayout() end
        end
    end)
end

-- Size and re-anchor the halo to the button it belongs to, at the spec's 68/37
-- proportion with the (0, 1)-at-37px CENTER offset. The cell size follows the density
-- slider, so both are read from the button rather than hardcoded.
local function layoutGlow(b)
    local glow = b._glow
    if not glow then return end
    local host = b._host
    local w = (host and host.GetWidth and host:GetWidth()) or 0
    local side = Borders.GlowSize(w)
    if side <= 0 then return end
    glow:SetSize(side, side)
    if glow.ClearAllPoints then
        glow:ClearAllPoints()
        glow:SetPoint("CENTER", b, "CENTER", 0, Borders.GlowOffsetY(w))
    end
end

-- Attach the quality-GLOW structure to a button ONCE, at creation. Idempotent: returns
-- the existing container on repeat calls. The container is a non-secure Frame child
-- holding ONE additive halo texture (created here, never re-created at runtime).
function Borders.Attach(button)
    if not button then return nil end
    if button._dsBagsBorder then return button._dsBagsBorder end
    if not _G.CreateFrame then return nil end
    local b = _G.CreateFrame("Frame", nil, button)
    -- The container spans the button; the halo is CENTERED in it and deliberately larger
    -- than the cell (1.x's 67-on-37), so the wash bleeds over the icon edge on all sides.
    b:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    b:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    if b.SetFrameLevel then b:SetFrameLevel((button:GetFrameLevel() or 1) + 1) end
    b._host = button

    -- Spec §2: a PLAIN OVERLAY texture — no negative sublevel. (The sublevel is inert
    -- here anyway: this container frame holds exactly ONE texture, and it already sits a
    -- frame level above the button, so the sublevel could never order it against the
    -- button's own OVERLAY art — the cooldown text, quest bang and marker pips. Dropping
    -- it to the spec's plain OVERLAY is therefore a no-op in render order and simply
    -- removes a parameter we had no basis for.)
    local glow = b:CreateTexture(nil, "OVERLAY")
    glow:SetTexture(Borders.GLOW_TEXTURE)
    glow:SetBlendMode("ADD")
    glow:SetPoint("CENTER", b, "CENTER", 0, 0)   -- re-anchored with the spec offset by layoutGlow
    glow:Hide()
    b._glow = glow
    layoutGlow(b)

    b._dsRelayout = function(self) layoutGlow(self) end
    -- Re-size on show: the cell size is only reliable once the button has been laid out,
    -- and the density slider can change it under a pooled button. Own-frame OnShow —
    -- never touches the secure button.
    b:SetScript("OnShow", function(self) layoutGlow(self) end)

    b:Hide()
    button._dsBagsBorder = b
    ensureSnapDriver()
    if snapSet then snapSet[b] = true end
    return b
end

-- Paint the halo one color and show it. Alpha is the spec's single uniform intensity
-- for every branch — quest, unusable and rarity all glow at the same strength, and the
-- COLOR is what distinguishes them (spec §2: one alpha "applied to every border").
local function showGlow(b, r, g, bl)
    local glow = b._glow
    if not glow then return end
    layoutGlow(b)
    if glow.SetVertexColor then glow:SetVertexColor(r, g, bl, Borders.GLOW_ALPHA) end
    glow:Show()
    -- Idempotent re-show: a prior search-dim may have parked the container at 0.25
    -- alpha (Borders.SetAlpha). Reset to full here so Apply is self-contained and a
    -- re-shown glow never inherits a stale dim, regardless of paint call order. The
    -- dim cascade re-applies afterward from _applyDress if the slot is still dimmed.
    if b.SetAlpha then b:SetAlpha(1) end
    b:Show()
end

-- FRAME (texture-op): park the cell's WELL at the yield alpha while its halo is shown,
-- and restore it the moment the halo is not. Guard-free of the WoW API (it only ever
-- calls SetAlpha on a texture region the dress already created), so the harness drives it
-- headless with a fake button. A cell without our dress — or an empty cell, which never
-- glows and therefore always lands on WELL_FULL_ALPHA — is left exactly as it was.
--
-- SECURE / TAINT: SetAlpha on a CHILD texture of the button. Not a protected op; safe in
-- combat, same class as everything else Apply does.
function Borders.SetWellAlpha(button, glowShown)
    local well = button and button._dsWell
    if not (well and well.SetAlpha) then return end
    well:SetAlpha(Borders.WellAlpha(glowShown))
end

-- Color (or hide) a button's quality glow, and yield/restore that cell's well with it.
-- Precedence is 1.x's UpdateBorder chain, top down:
--   quest (gold)  >  unusable (red)  >  quality (rarity)
-- `quest` (1.x glowQuest) draws the GOLD tint every quest item carries — the glow half of
-- 1.x's quest treatment, the bang glyph being reserved for quest STARTERS (ui_items draws
-- that). `unusable` (1.x glowUnusable) draws a RED glow. Otherwise a FULL-SATURATION
-- rarity glow is drawn when the quality clears the configurable floor. Honors the store
-- toggle live. Recolor/resize/show/hide/alpha of textures only — safe on every repaint,
-- even in combat.
--
-- The tint is resolved ONCE (Borders.ResolveTint) and both consumers read that one
-- verdict: the halo is painted from it, and the well yields iff it is non-nil. The well
-- op runs BEFORE the Attach guard on purpose — the yield must hold on any button carrying
-- our dress, including a headless/harness button with no glow container.
function Borders.Apply(button, quality, unusable, quest)
    local r, g, bl = Borders.ResolveTint(
        quality, unusable, quest, Borders.Enabled(), Borders.MinQuality(), liveProvider)

    -- WELL YIELD: the glowing cell's own edge art steps aside so the halo owns the edge.
    Borders.SetWellAlpha(button, r ~= nil)

    local b = Borders.Attach(button)
    if not b then return end
    if not r then b:Hide(); return end
    showGlow(b, r, g, bl)
end

-- Dim-cascade support (search-dim): scale the whole container's alpha so a dimmed slot's
-- quality glow recedes with its icon instead of floating at full strength. A hidden glow
-- stays hidden (SetAlpha on a hidden frame is inert); this never force-shows one.
function Borders.SetAlpha(button, alpha)
    local b = button and button._dsBagsBorder
    if b and b.SetAlpha then b:SetAlpha(alpha or 1) end
end

----------------------------------------------------------------------
-- SHARED pixel-snapped outline factory (borders.lua owns ALL snapped-edge
-- drawing in the grid). The quality edge above is the rare+ consumer; the item
-- grid's per-cell WELL border (the quiet "inset input" hairline that defines
-- every cell — dead-calm, `border` token) is the other. One implementation, one
-- snap driver, so both stay crisp at 720p and re-snap together on scale changes.
----------------------------------------------------------------------

-- PURE: physical thickness (local units) of a `logicalPx`-thick line given the
-- one-physical-pixel unit. Kept pure so the grid can assert 1px stays 1px.
function Borders.PhysicalThickness(logicalPx, onePixelUnit)
    local px = logicalPx or 1
    if px < 0 then px = 0 end
    return px * (onePixelUnit or 1)
end

-- Position a four-texture outline of physical thickness `unit` around frame `b`.
local function layoutOutline(b, unit)
    local e = b._edges
    if not e then return end
    e.top:ClearAllPoints()
    e.top:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    e.top:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
    e.top:SetHeight(unit)
    e.bottom:ClearAllPoints()
    e.bottom:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    e.bottom:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    e.bottom:SetHeight(unit)
    e.left:ClearAllPoints()
    e.left:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -unit)
    e.left:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, unit)
    e.left:SetWidth(unit)
    e.right:ClearAllPoints()
    e.right:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, -unit)
    e.right:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, unit)
    e.right:SetWidth(unit)
end

-- Create a snapped-outline Frame parented to `parent`. opts:
--   outset      — px the outline sits outside the parent's box (default 0)
--   layer       — draw layer for the edge textures (default "BORDER")
--   thicknessPx — logical thickness (default 1)
-- Returns an object o with o.frame + o:SetColor(r,g,b,a) / o:Show() / o:Hide() /
--   o:SetThickness(px) / o:Relayout(). In-game only (guarded on CreateFrame); the
--   textures are non-secure children — pure texture ops, never a protected call.
function Borders.NewSnappedOutline(parent, opts)
    if not parent or not _G.CreateFrame then return nil end
    opts = opts or {}
    local outset = opts.outset or 0
    local layer  = opts.layer or "BORDER"
    local f = _G.CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", -outset, outset)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", outset, -outset)
    if f.SetFrameLevel then f:SetFrameLevel((parent:GetFrameLevel() or 1) + 1) end

    local function newEdge()
        local t = f:CreateTexture(nil, layer)
        t:SetTexture(WHITE)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        return t
    end
    f._edges  = { top = newEdge(), bottom = newEdge(), left = newEdge(), right = newEdge() }
    f._pxTier = opts.thicknessPx or 1

    local o = { frame = f }
    function o:SetThickness(px) f._pxTier = px; layoutOutline(f, Borders.PhysicalThickness(px, onePixel(f))) end
    function o:Relayout()       layoutOutline(f, Borders.PhysicalThickness(f._pxTier, onePixel(f))) end
    function o:SetColor(r, g, b, a)
        local e = f._edges
        e.top:SetVertexColor(r, g, b, a or 1); e.bottom:SetVertexColor(r, g, b, a or 1)
        e.left:SetVertexColor(r, g, b, a or 1); e.right:SetVertexColor(r, g, b, a or 1)
    end
    function o:SetAlpha(a) if f.SetAlpha then f:SetAlpha(a or 1) end end
    function o:Show() f:Show() end
    function o:Hide() f:Hide() end

    -- Re-snap on show (effective scale only reliable once shown) and on display events.
    f:SetScript("OnShow", function(self) o:Relayout() end)
    f._dsRelayout = function() if f:IsShown() then o:Relayout() end end
    o:SetThickness(f._pxTier)
    ensureSnapDriver()
    if snapSet then snapSet[f] = true end
    return o
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "borders")
----------------------------------------------------------------------

local function testShouldShow(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Borders.ShouldShow(nil, true) == false, "nil quality -> no edge")
    ck(Borders.ShouldShow(0, true)   == false, "poor -> no edge")
    ck(Borders.ShouldShow(1, true)   == false, "common -> no edge")
    ck(Borders.ShouldShow(2, true)   == true,  "uncommon -> edge (1.0 Uncommon+ floor)")
    ck(Borders.ShouldShow(3, true)   == true,  "rare -> edge")
    ck(Borders.ShouldShow(4, true)   == true,  "epic -> edge")
    ck(Borders.ShouldShow(5, true)   == true,  "legendary -> edge")
    ck(Borders.ShouldShow(4, false)  == false, "disabled -> no edge even for epic")
    -- configurable floor: raising the min to Rare hides uncommon; Epic hides rare.
    ck(Borders.ShouldShow(2, true, 3) == false, "min=Rare hides uncommon")
    ck(Borders.ShouldShow(3, true, 3) == true,  "min=Rare shows rare")
    ck(Borders.ShouldShow(3, true, 4) == false, "min=Epic hides rare")
    ck(Borders.DEFAULT_MIN_QUALITY == 2, "default floor is Uncommon (2)")
end

-- Quality-floor matrix incl. per-tier thickness and the hue table.
local function testQualityFloorMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Tier thickness: below floor = 0, rare = 1px, epic/legendary/artifact = 2px.
    ck(Borders.TierPx(nil) == 0, "nil -> 0px")
    ck(Borders.TierPx(0)   == 0, "poor -> 0px")
    ck(Borders.TierPx(1)   == 0, "common -> 0px")
    ck(Borders.TierPx(2)   == 1, "uncommon -> 1px (1.0 Uncommon+ floor)")
    ck(Borders.TierPx(3)   == 1, "rare -> 1px")
    ck(Borders.TierPx(4)   == 2, "epic -> 2px")
    ck(Borders.TierPx(5)   == 2, "legendary -> 2px")
    ck(Borders.TierPx(6)   == 2, "artifact -> 2px")

    -- Desaturation moves each channel toward parchment (never past it) and keeps the
    -- edge readable as tinted ink: every channel strictly between original and target.
    local function between(v, a, tgt) return (v >= math.min(a, tgt) - 1e-9) and (v <= math.max(a, tgt) + 1e-9) end
    for _, q in ipairs({ 3, 4, 5 }) do
        local r, g, b = FALLBACK[q][1], FALLBACK[q][2], FALLBACK[q][3]
        local dr, dg, db = Borders.Desaturate(r, g, b)
        ck(between(dr, r, PARCHMENT[1]), "q" .. q .. " R pulled toward parchment")
        ck(between(dg, g, PARCHMENT[2]), "q" .. q .. " G pulled toward parchment")
        ck(between(db, b, PARCHMENT[3]), "q" .. q .. " B pulled toward parchment")
        -- retained ~85% chroma: moved only a small fraction (not collapsed to grey)
        local moved = math.abs(dr - r) + math.abs(dg - g) + math.abs(db - b)
        local span  = math.abs(PARCHMENT[1] - r) + math.abs(PARCHMENT[2] - g) + math.abs(PARCHMENT[3] - b)
        ck(span == 0 or moved <= span * (PARCHMENT_PULL + 1e-6), "q" .. q .. " retains most chroma (<=15% pull)")
    end

    -- HUE TABLE: after desaturation, rare(blue)/epic(purple)/legendary(orange) must stay
    -- mutually distinguishable at 1px. Assert pairwise Euclidean distance is comfortably
    -- large AND the dominant-channel identity is preserved.
    local function desat(q)
        local r, g, b = FALLBACK[q][1], FALLBACK[q][2], FALLBACK[q][3]
        return { Borders.Desaturate(r, g, b) }
    end
    local blue, purple, orange = desat(3), desat(4), desat(5)
    local function dist(a, b)
        local dr, dg, db = a[1] - b[1], a[2] - b[2], a[3] - b[3]
        return math.sqrt(dr * dr + dg * dg + db * db)
    end
    ck(dist(blue, purple)   >= 0.25, "rare vs epic distinguishable (>=0.25)")
    ck(dist(purple, orange) >= 0.25, "epic vs legendary distinguishable (>=0.25)")
    ck(dist(blue, orange)   >= 0.25, "rare vs legendary distinguishable (>=0.25)")
    -- dominant-channel identity: blue -> B is max; orange -> R is max & B is min;
    -- purple -> B is max but R clearly exceeds G (magenta lean), separating it from blue.
    ck(blue[3] > blue[1] and blue[3] > blue[2], "rare stays blue-dominant")
    ck(orange[1] > orange[2] and orange[2] > orange[3], "legendary stays orange (R>G>B)")
    ck(purple[3] > purple[2] and purple[1] > purple[2], "epic stays purple (B>G, R>G)")
    ck(purple[1] > blue[1] + 0.15, "epic separable from rare by the red channel")
end

local function testQualityRGB(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- injected provider wins when it returns a color
    local r, g, b = Borders.QualityRGB(3, function(q) return 0.10, 0.20, 0.30 end)
    ck(r == 0.10 and g == 0.20 and b == 0.30, "provider color used")
    -- fall back to the static table when the provider returns nil
    local r2 = Borders.QualityRGB(4, function() return nil end)
    ck(r2 ~= nil, "static fallback used when provider yields nil")
    ck(select(1, Borders.QualityRGB(3)) == FALLBACK[3][1], "no provider -> static rare color")
    ck(Borders.QualityRGB(nil) == nil, "nil quality -> nil color")
end

local function testEnabledToggle(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved = Store.db
    Store.db = nil
    ck(Borders.Enabled() == true, "no store -> default ON")
    Store.db = {}
    ck(Borders.Enabled() == true, "unset key -> default ON")
    Store.db = { qualityBorders = false }
    ck(Borders.Enabled() == false, "explicit false honored")
    Store.db = { qualityBorders = true }
    ck(Borders.Enabled() == true, "explicit true honored")
    Store.db = saved
end

-- REALISTIC MIXED BAG (defect #2 regression lock): a warrior's bags are mostly
-- whites/greys/greens with the odd rare and a single epic — NOT "all epics". This
-- reproduces the owner's mixed inventory and asserts the edge maps ONLY onto rare+,
-- with the correct per-tier thickness. It proves the quality-edge LOGIC is quiet by
-- construction (the beta's "every slot rimmed bright" was the template's native
-- UI-Quickslot2 ring, killed in ui_items._neutralizeSlotArt — not this mapping).
local function testMixedBagMapping(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- 12 slots: poor, commons, three uncommons, one rare, one epic, an empty (nil quality).
    local bag = { 0, 1, 1, 1, 2, 2, 1, 3, 1, 2, 4, nil }
    local rimmed, px1, px2 = 0, 0, 0
    for slot = 1, 12 do
        local q = bag[slot]
        if Borders.ShouldShow(q, true) then
            rimmed = rimmed + 1
            local p = Borders.TierPx(q)
            if p == 1 then px1 = px1 + 1 elseif p == 2 then px2 = px2 + 1 end
        else
            ck(Borders.TierPx(q) == 0, "sub-uncommon slot (q=" .. tostring(q) .. ") -> 0px")
        end
    end
    -- 1.0 Uncommon+ floor: the three greens + the rare + the epic are rimmed (5 of 12).
    ck(rimmed == 5, "mixed bag: 5 of 12 rimmed (3 uncommon + rare + epic), got " .. rimmed)
    ck(px1 == 4, "four 1px edges (the three uncommons + the rare), got " .. px1)
    ck(px2 == 1, "exactly one 2px edge (the epic)")
    -- Poor + commons stay quiet; uncommons NOW carry the 1.0 green border.
    ck(Borders.ShouldShow(0, true) == false and Borders.ShouldShow(1, true) == false,
        "poor + commons stay edgeless")
    ck(Borders.ShouldShow(2, true) == true, "uncommons carry the 1.0 green border")
    -- Disabling the toggle silences everything.
    local silenced = 0
    for slot = 1, 12 do if Borders.ShouldShow(bag[slot], false) then silenced = silenced + 1 end end
    ck(silenced == 0, "toggle off -> no slot rimmed at all")
end

-- PURE snapped-thickness helper (shared outline factory): a logical Npx line maps to
-- N physical pixels, clamps negatives to 0, and defaults the unit to 1 (headless).
local function testPhysicalThickness(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Borders.PhysicalThickness(1, 0.5) == 0.5, "1px * 0.5 unit = 0.5")
    ck(Borders.PhysicalThickness(2, 0.5) == 1.0, "2px * 0.5 unit = 1.0")
    ck(Borders.PhysicalThickness(1) == 1, "unit defaults to 1")
    ck(Borders.PhysicalThickness(nil, 0.7) == 0.7, "nil px -> 1px")
    ck(Borders.PhysicalThickness(-3, 0.5) == 0, "negative px clamps to 0")
end

-- 1.0-PARITY: configurable minimum-quality floor + the unusable red.
local function testMinQualityConfig(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved = Store.db
    Store.db = nil;  ck(Borders.MinQuality() == 2, "no store -> default Uncommon (2)")
    Store.db = {};   ck(Borders.MinQuality() == 2, "unset -> default Uncommon (2)")
    Store.db = { qualityBorderMin = 3 }; ck(Borders.MinQuality() == 3, "explicit Rare floor honored")
    Store.db = { qualityBorderMin = 4 }; ck(Borders.MinQuality() == 4, "explicit Epic floor honored")
    Store.db = { qualityBorderMin = "x" }; ck(Borders.MinQuality() == 2, "non-number -> default")
    Store.db = saved
    -- Unusable red is red-dominant (headless: falls back to a literal red).
    local r, g, b = Borders.UnusableRGB()
    ck(r and r > g and r > b, "unusable red is red-dominant")
end

-- SUITE GLOW GEOMETRY — pinned to CII_BEHAVIOR_SPEC §2. These constants ARE the look,
-- and they are a SIBLING CONTRACT: Daseeki-Armory's borders.lua declares the identical
-- block and its harness gates the identical numbers, so the character window and the
-- bag grid can never drift apart. Any edit here must be mirrored there.
local function testGlowGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return math.abs(a - b) < 1e-9 end

    -- Spec §2 anatomy, constant by constant.
    ck(Borders.GLOW_TEXTURE == "Interface\\Buttons\\UI-ActionButton-Border",
        "spec §2 glow texture")
    ck(Borders.GLOW_REF_BUTTON == 37, "spec §2 reference button is 37px")
    ck(near(Borders.GLOW_SCALE, 68 / 37), "spec §2 proportion: a 68px halo on a 37px button")
    ck(near(Borders.GLOW_SCALE_AMMO, 58 / 37), "spec §2 Ammo exception: a 58px halo")
    ck(Borders.GLOW_ALPHA == 0.49, "spec §2 intensity default 0.49, uniform on every border")
    ck(near(Borders.GLOW_OFFSET_Y_SCALE, 1 / 37), "spec §2 CENTER anchor offset (0, 1)")

    -- The halo is strictly LARGER than the cell — that overhang is what makes it read as
    -- a wash over the icon edge rather than as a rim around it.
    ck(Borders.GLOW_SCALE > 1, "the halo overhangs the cell")
    ck(Borders.GLOW_SCALE_AMMO > 1, "even the Ammo halo overhangs")
    ck(Borders.GLOW_SCALE_AMMO < Borders.GLOW_SCALE, "the Ammo halo is the smaller exception")

    -- At the spec's own button size the ratios reproduce its literal pixel values.
    ck(near(Borders.GlowSize(37), 68), "a 37px cell -> the spec's literal 68px halo")
    ck(near(Borders.GlowSize(37, true), 58), "…and the Ammo variant -> literally 58")
    ck(near(Borders.GlowOffsetY(37), 1), "…and the offset -> literally 1")

    -- Scales with the density slider's cell size, so the look holds at any cell.
    ck(Borders.GlowSize(48) > Borders.GlowSize(37), "a bigger cell gets a bigger halo")
    ck(near(Borders.GlowSize(74), 136), "a doubled cell doubles the halo (proportion held)")
    ck(near(Borders.GlowOffsetY(74), 2), "…and doubles the offset")
    ck(Borders.GlowSize(0) == 0, "degenerate cell -> no halo")
    ck(Borders.GlowSize(-5) == 0, "negative cell -> no halo")
    ck(Borders.GlowSize(nil) == 0, "nil cell -> no halo")
    ck(Borders.GlowOffsetY(0) == 0 and Borders.GlowOffsetY(nil) == 0, "degenerate cell -> no offset")

    -- UNIFORM intensity across the precedence chain: the spec applies ONE alpha to quest
    -- gold, unusable red and every rarity, and lets the COLOR carry the distinction.
    -- (The per-tier thickness below is retained for the shared outline factory only.)
    ck(Borders.TierPx(2) ~= Borders.TierPx(4), "TierPx still describes the rarity tiers")
end

-- Spec §3 colors + the BAG-surface gating rule, kept next to the geometry because the
-- two together are what makes our halo read as the reference's.
local function testSpecColorsAndBagGate(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Poor is the spec's near-black override, and it beats the live provider (the
    -- reference mutates the shared color table, so its value wins over Blizzard's).
    ck(Borders.POOR_RGB[1] == 0.1 and Borders.POOR_RGB[2] == 0.1 and Borders.POOR_RGB[3] == 0.1,
        "spec §3 Poor is near-black 0.1/0.1/0.1")
    local pr, pg, pb = Borders.QualityRGB(0, function() return 0.62, 0.62, 0.62 end)
    ck(pr == 0.1 and pg == 0.1 and pb == 0.1, "…and it overrides the live provider's grey")
    ck(Borders._fallback[0][1] == 0.1, "the static table agrees with the override")
    -- Common stays white (spec §3: white items get white on the equipped surface).
    ck(Borders._fallback[1][1] == 1 and Borders._fallback[1][3] == 1, "spec §3 Common is white")

    -- BAG surface gate (spec §3, the item-link lookup row): quality must exceed Common.
    -- This is the floor Bags ships; the every-quality rule is the EQUIPPED path and
    -- belongs to Armory, not here.
    ck(Borders.DEFAULT_MIN_QUALITY == 2, "bag surface floor is above Common (spec §3)")
    ck(Borders.ShouldShow(0, true) == false, "bag: poor does NOT glow")
    ck(Borders.ShouldShow(1, true) == false, "bag: common does NOT glow")
    ck(Borders.ShouldShow(2, true) == true,  "bag: uncommon glows")

    -- The quest override survives the gate (spec §3 quest-class row) — it is applied by
    -- Apply() ahead of the floor, so a Common quest item still glows. DELIBERATE
    -- DIVERGENCE: our tint is gold (1, .82, .2), the spec's synthetic quest quality is
    -- pure yellow (1, 1, 0). The override is the spec's; the tint is ours.
    local qr, qg, qb = Borders.QuestRGB()
    ck(qr == 1 and qg == 0.82 and qb == 0.2, "quest gold is our suite tint, not the spec's pure yellow")
    ck(qg < 1, "…deliberately warmer than the spec's (1, 1, 0)")
end

-- WELL YIELD (owner defect: "the grey inset well border renders at full strength
-- underneath/through the halo"). Drives the REAL Borders.Apply headless — there is no
-- _G.CreateFrame in the harness, so Attach returns nil and Apply exercises exactly the
-- pure decision + the well texture-op, which is the part under test. A fake button
-- carrying only `_dsWell` records the alpha it was parked at.
local function testWellYield(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function fakeCell()
        local well = { alpha = 1 }
        function well:SetAlpha(a) self.alpha = a end
        return { _dsWell = well }
    end

    local saved = Store.db
    Store.db = { qualityBorders = true }    -- toggle ON, default Uncommon+ floor

    -- The constants themselves: the well yields to (near) nothing and restores to full.
    ck(Borders.WELL_GLOW_ALPHA <= 0.05, "a glowing cell's well yields to ~0 alpha")
    ck(Borders.WELL_FULL_ALPHA == 1, "a non-glowing cell's well is fully opaque")
    ck(Borders.WellAlpha(true) == Borders.WELL_GLOW_ALPHA, "WellAlpha(shown) -> yield alpha")
    ck(Borders.WellAlpha(false) == Borders.WELL_FULL_ALPHA, "WellAlpha(hidden) -> full alpha")
    ck(Borders.WellAlpha(nil) == Borders.WELL_FULL_ALPHA, "WellAlpha(nil) -> full alpha")

    -- GLOW SHOWN -> well suppressed, for EVERY tint in the precedence chain.
    local rare = fakeCell()
    Borders.Apply(rare, 3)                                   -- rarity blue
    ck(rare._dsWell.alpha == Borders.WELL_GLOW_ALPHA, "rarity glow suppresses the well")
    local epic = fakeCell()
    Borders.Apply(epic, 4)
    ck(epic._dsWell.alpha == Borders.WELL_GLOW_ALPHA, "epic glow suppresses the well")
    local questCell = fakeCell()
    Borders.Apply(questCell, 1, false, true)                 -- quest gold beats the floor
    ck(questCell._dsWell.alpha == Borders.WELL_GLOW_ALPHA, "quest gold suppresses the well")
    local unusableCell = fakeCell()
    Borders.Apply(unusableCell, 1, true, false)              -- unusable red beats the floor
    ck(unusableCell._dsWell.alpha == Borders.WELL_GLOW_ALPHA, "unusable red suppresses the well")

    -- GLOW HIDDEN -> well restored, by every route that can stop a glow.
    local common = fakeCell()
    Borders.Apply(common, 1)
    ck(common._dsWell.alpha == Borders.WELL_FULL_ALPHA, "below-floor common keeps its well")
    local poor = fakeCell()
    Borders.Apply(poor, 0)
    ck(poor._dsWell.alpha == Borders.WELL_FULL_ALPHA, "poor keeps its well")

    -- RESTORE PATH on the SAME cell: glow, then stop glowing (item removed / replaced by a
    -- common / floor raised / toggle off). Each must hand the well back at full alpha.
    local cell = fakeCell()
    Borders.Apply(cell, 5)
    ck(cell._dsWell.alpha == Borders.WELL_GLOW_ALPHA, "legendary suppresses")
    Borders.Apply(cell, nil)                                  -- item removed -> empty slot
    ck(cell._dsWell.alpha == Borders.WELL_FULL_ALPHA, "item removed -> well restored")
    Borders.Apply(cell, 3)
    ck(cell._dsWell.alpha == Borders.WELL_GLOW_ALPHA, "…re-suppressed on the next rare")
    Store.db = { qualityBorders = true, qualityBorderMin = 4 }  -- floor raised past rare
    Borders.Apply(cell, 3)
    ck(cell._dsWell.alpha == Borders.WELL_FULL_ALPHA, "floor raised past it -> well restored")
    Store.db = { qualityBorders = false }                       -- Item-borders toggled OFF
    Borders.Apply(cell, 5)
    ck(cell._dsWell.alpha == Borders.WELL_FULL_ALPHA, "toggle off -> well restored even on legendary")
    Store.db = { qualityBorders = true }

    -- EMPTY CELL: never glows, so its well is never touched off full — the owner's
    -- "grey empty cells look correct as-is" is a hard invariant here.
    -- (An empty slot is quality nil with no flags — paintButton's empty branch calls
    -- Apply(button, nil). Repeated paints must never move it off full alpha.)
    local empty = fakeCell()
    for _ = 1, 3 do
        Borders.Apply(empty, nil, false, false)
        ck(empty._dsWell.alpha == Borders.WELL_FULL_ALPHA, "empty cell's well is untouched")
    end

    -- No dress (a foreign / not-yet-dressed button) must not error.
    local ok = pcall(Borders.Apply, {}, 4)
    ck(ok, "a button without a well survives Apply")
    ck(pcall(Borders.SetWellAlpha, nil, true), "SetWellAlpha(nil) is inert")

    Store.db = saved
end

-- The glow decision is ONE decision: ResolveTint drives both the halo and the well yield,
-- and it must reproduce 1.x's UpdateBorder precedence exactly (quest > unusable > rarity).
local function testResolveTintPrecedence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    local MIN = DEFAULT_MIN_QUALITY

    -- quest gold wins over BOTH unusable and a legendary rarity
    local r, g, b = Borders.ResolveTint(5, true, true, true, MIN)
    local qr, qg, qb = Borders.QuestRGB()
    ck(near(r, qr) and near(g, qg) and near(b, qb), "quest gold wins the chain")
    -- unusable red wins over rarity
    local ur = Borders.UnusableRGB()
    ck(near(select(1, Borders.ResolveTint(5, true, false, true, MIN)), ur), "unusable beats rarity")
    -- rarity when neither flag is set
    ck(near(select(1, Borders.ResolveTint(3, false, false, true, MIN)), FALLBACK[3][1]),
        "rarity color when no override")
    -- the floor and the toggle both close the gate
    ck(Borders.ResolveTint(1, false, false, true, MIN) == nil, "common -> no tint")
    ck(Borders.ResolveTint(nil, false, false, true, MIN) == nil, "empty -> no tint")
    ck(Borders.ResolveTint(5, true, true, false, MIN) == nil, "toggle off -> no tint at all")
    ck(Borders.ResolveTint(3, false, false, true, 4) == nil, "raised floor -> no tint")

    -- GlowShown is the boolean face of it, and it is exactly what the well keys off.
    ck(Borders.GlowShown(3, false, false, true, MIN) == true, "GlowShown: rare glows")
    ck(Borders.GlowShown(1, false, false, true, MIN) == false, "GlowShown: common does not")
    ck(Borders.GlowShown(1, false, true, true, MIN) == true, "GlowShown: quest common glows")
    ck(Borders.GlowShown(4, false, false, false, MIN) == false, "GlowShown: toggle off silences epic")
    -- the invariant the fix rests on: well suppressed IFF the halo is shown
    for _, case in ipairs({
        { 0, false, false }, { 1, false, false }, { 2, false, false }, { 4, false, false },
        { 1, true, false }, { 1, false, true }, { nil, false, false },
    }) do
        local shown = Borders.GlowShown(case[1], case[2], case[3], true, MIN)
        local want  = shown and Borders.WELL_GLOW_ALPHA or Borders.WELL_FULL_ALPHA
        ck(Borders.WellAlpha(shown) == want, "well alpha tracks the halo for q=" .. tostring(case[1]))
    end
end

function Borders.RunSelfTests(verbose)
    local suites = {
        { name = "should-show gate",     fn = testShouldShow },
        { name = "glow geometry (spec §2)", fn = testGlowGeometry },
        { name = "spec colors + bag gate",  fn = testSpecColorsAndBagGate },
        { name = "resolve-tint precedence", fn = testResolveTintPrecedence },
        { name = "well yield under glow",   fn = testWellYield },
        { name = "quality-floor matrix", fn = testQualityFloorMatrix },
        { name = "mixed-bag mapping",    fn = testMixedBagMapping },
        { name = "min-quality + unusable", fn = testMinQualityConfig },
        { name = "quality color",        fn = testQualityRGB },
        { name = "enabled toggle",       fn = testEnabledToggle },
        { name = "physical thickness",   fn = testPhysicalThickness },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS borders/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL borders/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("borders", Borders.RunSelfTests)
end

return Borders
