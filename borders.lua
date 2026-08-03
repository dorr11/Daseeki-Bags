-- Daseeki Bags 2.0 — borders.lua
-- LAYER 1 of the two-layer item dress: QUALITY as quiet identity (Field Ledger).
--
-- The quality cue is INFORMATION the player wants (rarity-at-a-glance).
--
-- ── The cue is a soft GLOW + the template ring — now transcribed from 1.x SOURCE ──
-- The beta drew a thin hard quality-colored SQUARE OUTLINE around each cell. The look
-- the owner wants is 1.x's: a soft additive halo washing over the icon edge, WITH the
-- template's own IconBorder ring re-tinted underneath it. The display round shipped an
-- approximation; the round after that pinned it to the clean-room CII_BEHAVIOR_SPEC.md §2.
-- Neither was the target. The target is our own 1.x tree (Daseeki-Bags on main), and this
-- file is now a line-cited transcription of it — 67/37, alpha 0.5, no CENTER offset,
-- OVERLAY sublevel -1, and the IconBorder driven rather than killed. See the SUITE GLOW
-- GEOMETRY block for the parameter-by-parameter derivation and the four rows where 1.x
-- and the spec disagree.
--
-- Gating stays as it was and 1.x and the spec agree on it for the BAG surface: quality
-- above Common (1.x glowQuality `quality > 1`), plus the quest / unusable / equipment-set
-- overrides. The EVERY-QUALITY rule (poor and common included) belongs to the equipped-slot
-- path and lives in Daseeki-Armory's borders.lua.
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
-- This is 1.x VERBATIM (core/classes/item.lua:198: r,g,b = 1, .82, .2) and therefore the
-- owner's target. It DIVERGES from CII_BEHAVIOR_SPEC §3, whose quest-item override uses a
-- synthetic quality at PURE YELLOW (1, 1, 0) — the spec legitimises the OVERRIDE (quest
-- class wins over rarity, which is what our chain does), but 1.x wins on the tint, and
-- gold reads as "quest" against the near-black ground where a pure yellow sits close to
-- Legendary orange under an ADD blend.
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

-- EQUIPMENT-SET teal — 1.x item.lua:202 (glowSets branch): r,g,b = .2, 1, .8.
--
-- CELL-PARITY change: 2.0 previously expressed set membership as a separate BRONZE CORNER
-- PIP, which is a per-cell mark 1.x does not draw. 1.x has exactly one cue per cell — the
-- halo — and set membership is a BRANCH OF THAT CHAIN, sitting between the unusable red
-- and the rarity color. Restoring it here removes a mark from every set item's cell and is
-- the 1.x model verbatim. The db.setMarkers toggle still gates the cue; it now gates the
-- tint instead of the pip (no SavedVariables change).
--
-- REGRESSION FOLLOW-UP: this branch is CORRECT and stays exactly as transcribed — but the
-- cue that feeds it is now DEFAULT OFF. 1.x's set branch is unreachable on Classic Era
-- unless ItemRack is loaded (Daseeki-Bags/libs/ItemSearch-1.3/API.lua:145-146 assigns
-- `Lib.BelongsToSet = nop`), so "1.x parity" for the owner's install means NO teal at all.
-- Left on, the teal outranks rarity and repaints roughly a third of a geared character's
-- bag. The gate lives in ui_items (Items.SetCueEnabled); this file just resolves colours.
function Borders.SetRGB()
    return 0.2, 1, 0.8
end

-- PURE: the WHOLE precedence chain in one place — 1.x's UpdateBorder branch order, top
-- down (item.lua:197-205):
--     quest gold  >  unusable red  >  equipment-set teal  >  rarity (above the floor)
-- Returns r,g,b for the tint the cell should glow, or nil when it should not glow at all.
-- `provider` is injected exactly as for QualityRGB (live: the game's quality-color function).
--
-- This is the SINGLE glow decision. Apply() paints the halo AND the template's IconBorder
-- from it, so "is this cell glowing?" has exactly one answer and the two can never disagree.
function Borders.ResolveTint(quality, unusable, quest, set, enabled, minQuality, provider)
    if not enabled then return nil end
    if quest    then return Borders.QuestRGB() end           -- 1.x's FIRST branch
    if unusable then return Borders.UnusableRGB() end        -- "can't use", over rarity
    if set      then return Borders.SetRGB() end             -- 1.x glowSets, over rarity
    if not Borders.ShouldShow(quality, enabled, minQuality) then return nil end
    return Borders.QualityRGB(quality, provider)             -- may still be nil (unknown quality)
end

-- PURE: the boolean form of ResolveTint — "does this cell's halo show?".
function Borders.GlowShown(quality, unusable, quest, set, enabled, minQuality, provider)
    return Borders.ResolveTint(quality, unusable, quest, set, enabled, minQuality, provider) ~= nil
end

----------------------------------------------------------------------
-- SUITE GLOW GEOMETRY — TRANSCRIBED FROM 1.x, NOT FROM THE SPEC
--
-- HISTORY, so nobody re-litigates this a fourth time. Round 1 of the glow work pinned
-- these constants to CII_BEHAVIOR_SPEC.md §2 (68/37, alpha 0.49, a (0, 1) CENTER nudge,
-- a plain OVERLAY texture in a child frame one level ABOVE the button). The spec is a
-- clean-room description of a THIRD-PARTY reference addon. It is not our target.
--
-- The owner's target is verbatim "what 1.x looks like" — and 1.x is OUR OWN code, which
-- we can read. Where 1.x and the spec disagree, 1.x wins. They disagree on four rows,
-- every one of them transcribed below with its file:line:
--
--   Daseeki-Bags/core/classes/item.lua:54   b.IconGlow = b:CreateTexture(nil, 'OVERLAY', nil, -1)
--   Daseeki-Bags/core/classes/item.lua:55   :SetTexture('Interface/Buttons/UI-ActionButton-Border')
--   Daseeki-Bags/core/classes/item.lua:56   :SetBlendMode('ADD')
--   Daseeki-Bags/core/classes/item.lua:57   :SetPoint('CENTER')          -- NO (0,1) offset
--   Daseeki-Bags/core/classes/item.lua:58   :SetSize(67, 67)             -- 67, not 68
--   Daseeki-Bags/core/api/settings.lua:34   glowAlpha = 0.5              -- the DEFAULT, superseded
--   WTF/Account/309992577#1/SavedVariables/Daseeki-Bags.lua:3621  ["glowAlpha"] = 0.77
--   Daseeki-Bags/core/classes/item.lua:208  IconGlow:SetVertexColor(r,g,b, Addon.sets.glowAlpha)
--
-- ALPHA IS AN OWNER-PROFILE ROW, NOT A DEFAULT ROW (this is the release-blocking fix).
-- glowAlpha is the ONE glow parameter 1.x exposes as a slider, and the owner moved it years
-- ago: his LIVE account-level value is 0.77 (account #1, his main; #2 and #3 are 0.87).
-- Shipping 1.x's untouched default of 0.5 made the additive wash faint enough that the crisp
-- IconBorder ring dominated the cell — his verdict side by side was "in bags 1 the glow sort
-- of fades inward on the item slot, and bags 2 is just a hard border mostly". Nothing about
-- the RING changed; the wash was simply 35% too weak to be the primary cue. 0.77 is the spec.
-- This follows the precedent already set for slotBackground / slotAlpha / slotBorderColor in
-- ui_items and parity.lua: where the owner deliberately moved a 1.x setting, HIS value is the
-- 2.0 constant, not 1.x's shipped default.
--
-- and the 37 the ratios are taken against is the item button's own side length: 1.x never
-- resizes the button, it leaves ContainerFrameItemButtonTemplate at its native 37 and
-- scales it (skin/others.lua:10 — grid step 37 + spacing, button scaled by itemScale).
--
-- LAYER is the fourth row and the one with teeth. 1.x's glow is a texture ON THE BUTTON at
-- OVERLAY sublevel -1, so it sorts BELOW the button's other OVERLAY art (the stack-count
-- numeral, the quest bang, the cooldown text). Round 1 dropped the sublevel per the spec
-- AND kept the glow in a child frame at button level + 1 — which puts the halo above every
-- one of those, and above the neighbouring cells' overlay art too. We now reproduce 1.x:
-- same frame level as the button, texture at OVERLAY sublevel -1.
--
-- Our buttons are not fixed at 37 (the Bags density slider moves the cell), so the 1.x
-- pixel values are carried as RATIOS against 1.x's own 37px button and derived from the
-- host button's measured width. At 37 that reproduces 1.x literally (67, 0); at any other
-- density it reproduces the same halo PROPORTION, so every density reads like a scaled 1.x.
--
-- These ship as CONSTANTS, not settings — no new SavedVariables key. 1.x exposes glowAlpha
-- as a slider; we pin the OWNER'S OWN slider position (0.77) as our one value.
--
-- SIBLING CONTRACT: Daseeki-Armory's borders.lua carries this same GLOW_ALPHA and is trued
-- to this block. (It once carried the SPEC numbers; that drift is closed. Armory still owns
-- the equipped-surface EVERY-QUALITY floor, which is a gating row, not a look row.)
----------------------------------------------------------------------
Borders.GLOW_TEXTURE = "Interface\\Buttons\\UI-ActionButton-Border"  -- 1.x item.lua:55
Borders.GLOW_REF_BUTTON = 37        -- 1.x: the template item button, never resized
Borders.GLOW_SCALE      = 67 / 37   -- 1.x item.lua:58  SetSize(67, 67)
Borders.GLOW_SCALE_AMMO = 58 / 37   -- CII §2 Ammo exception; Bags has no ammo cell (dormant)
Borders.GLOW_ALPHA      = 0.77      -- owner profile glowAlpha, account #1 (1.x default 0.5 superseded)
Borders.GLOW_OFFSET_Y_SCALE = 0     -- 1.x item.lua:57  SetPoint('CENTER') — no offset
Borders.GLOW_LAYER      = "OVERLAY" -- 1.x item.lua:54
Borders.GLOW_SUBLEVEL   = -1        -- 1.x item.lua:54 — BELOW the button's other OVERLAY art

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
-- THE WELL IS GONE (this supersedes the previous round's WELL YIELD)
--
-- The round before this one made the per-cell WELL texture yield to alpha 0 while its cell
-- was glowing, because the owner reported a grey square reading through the halo. That was
-- a patch on one state of one element. The 1.x model has no such element in ANY state:
--
--   Daseeki-Bags/core/classes/item.lua:51-52   local normal = b:GetNormalTexture()
--                                              if normal then normal:Hide() end
--
-- ...and nothing is created to replace it. A 1.x cell draws exactly ONE substrate — the
-- icon texture itself — for both states: the item's icon when filled, and the empty-slot
-- art when empty (item.lua:12-19 Backgrounds[2] = 'interface/paperdoll/ui-backpack-emptyslot',
-- selected by the slotBackground = 2 default at core/api/settings.lua). There is no card,
-- no panel, no rect, and therefore no cell edge to fight the halo — filled OR empty,
-- glowing OR not.
--
-- ui_items no longer creates the well at all, so WellAlpha / SetWellAlpha / WELL_* are
-- retired rather than re-tuned. Nothing to suppress is strictly stronger than suppressing
-- it in one state, and it is what 1.x actually does.
----------------------------------------------------------------------

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

-- Size and re-anchor the halo to the button it belongs to, at 1.x's 67/37 proportion with
-- its plain CENTER anchor (no offset). The cell size follows the density slider, so both
-- are read from the button rather than hardcoded.
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
    -- CELL PARITY: the container sits at the button's OWN frame level, not one above it.
    -- 1.x's IconGlow is a texture ON the button (item.lua:54), so it is ordered against the
    -- button's other art by draw layer alone. A level+1 container ordered the halo above
    -- EVERYTHING — the count numeral, the quest bang, the cooldown, and the neighbouring
    -- cells' overlay art. Same level + OVERLAY(-1) below reproduces 1.x's ordering exactly.
    if b.SetFrameLevel then b:SetFrameLevel(button:GetFrameLevel() or 1) end
    b._host = button

    -- 1.x item.lua:54 — OVERLAY at sublevel -1, i.e. BELOW the button's other OVERLAY art.
    local glow = b:CreateTexture(nil, Borders.GLOW_LAYER, nil, Borders.GLOW_SUBLEVEL)
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

-- FRAME (texture-op): the TEMPLATE's own IconBorder, driven exactly as 1.x drives it.
--
-- CELL PARITY: 2.0 used to kill IconBorder outright (ui_items._killTemplateArt) on the
-- grounds that Blizzard's full-saturation quality ring was "the bright rim". 1.x does NOT
-- kill it — it re-colors it to the SAME tint as the halo and shows it on exactly the cells
-- that glow:
--
--   Daseeki-Bags/core/classes/item.lua:194   SetItemButtonQuality(self, quality, link, false, isBound)
--   Daseeki-Bags/core/classes/item.lua:210   self.IconBorder:SetVertexColor(r, g, b)
--   Daseeki-Bags/core/classes/item.lua:220   self.IconBorder:SetShown(r)
--
-- That crisp ring hugging the icon is what ANCHORS the soft 67px wash to its own cell. With
-- the ring killed, the halo was the only thing describing a glowing cell and read as an
-- unanchored coloured bloom spilling into the gutters — which is the "cluttered" half of
-- the owner's report. ui_items calls SetItemButtonQuality (as 1.x does) so Blizzard sets
-- the region's own art; we only override color + shown, so no texture path is guessed here.
--
-- RING-vs-WASH VERDICT (the "hard border" investigation - DO NOT dim this ring).
--
-- Q1: does 1.x render the IconBorder at FULL alpha, or does it alpha-scale it like the halo?
--     FULL. 1.x applies glowAlpha to the HALO ONLY:
--       Daseeki-Bags/core/classes/item.lua:208  IconGlow:SetVertexColor(r,g,b, sets.glowAlpha)
--       Daseeki-Bags/core/classes/item.lua:210  IconBorder:SetVertexColor(r,g,b)   -- 3 args
--       Daseeki-Bags/core/classes/item.lua:220  IconBorder:SetShown(r)             -- no SetAlpha
--     A 3-arg SetVertexColor leaves vertex alpha at 1, and 1.x never calls SetAlpha on the
--     region, so the template's own alpha (1) stands. Nothing in Daseeki-Bags/skin/ touches
--     IconBorder either (grep-verified over the whole 1.x tree: its ONLY IconBorder lines are
--     :210 and :220). 2.0 below is therefore AT PARITY, not brighter - same 3-arg vertex
--     color, plus an explicit SetAlpha(1) that merely restates the region default.
--     => the ring is LEFT EXACTLY AS IS. The imbalance was 100% on the wash side.
--
-- Q2: does the region even EXIST on Classic Era 1.15.9 - i.e. is 1.x's SetShown a silent
--     no-op, making 1.x's on-screen cue the wash ALONE? No. It exists. Evidence:
--       (a) 1.x drives sibling parentKeys of the SAME modern ItemButtonTemplate with NO nil
--           guard on paths that run for every button: item.lua:48 BattlepayItemTexture:Hide(),
--           :49 NewItemTexture:Hide() (Construct), :220 IconBorder:SetShown and :222
--           JunkIcon:SetShown (unconditional, every UpdateBorder). On the OLD template those
--           are nil and 1.x would throw "attempt to index field ... (a nil value)" on every
--           cell, so the bags would not render at all. They render - the owner runs 1.x as
--           his live bags on 1.15.9.
--       (b) wow-api-catalog/1.15.9.68808/globals.txt:7538 - SetItemButtonQuality is present in
--           the Era client's _G, and driving button.IconBorder is that helper's entire job.
--     So 1.x and 2.0 both draw ring + wash. Defaulting our ring off would have DELETED half
--     of 1.x's cue, not matched it.
--
-- SECURE / TAINT: SetVertexColor / SetShown on a CHILD region of the button. Not protected.
function Borders.SetIconBorder(button, r, g, bl)
    local ib = button and (button.IconBorder
        or (button.GetName and _G and _G[(button:GetName() or "") .. "IconBorder"]))
    if not ib then return end
    if r and ib.SetVertexColor then ib:SetVertexColor(r, g, bl) end
    if ib.SetAlpha then ib:SetAlpha(r and 1 or 0) end
    if r then if ib.Show then ib:Show() end
    else if ib.Hide then ib:Hide() end end
end

-- Color (or hide) a button's quality glow AND the template IconBorder under it.
-- Precedence is 1.x's UpdateBorder chain, top down:
--   quest (gold)  >  unusable (red)  >  equipment set (teal)  >  quality (rarity)
-- `quest` (1.x glowQuest) draws the GOLD tint every quest item carries — the glow half of
-- 1.x's quest treatment, the bang glyph being reserved for quest STARTERS (ui_items draws
-- that). `unusable` (1.x glowUnusable) draws a RED glow. `set` (1.x glowSets) draws the
-- teal. Otherwise a FULL-SATURATION rarity glow is drawn when the quality clears the
-- configurable floor. Honors the store toggle live. Recolor/resize/show/hide/alpha of
-- textures only — safe on every repaint, even in combat.
--
-- The tint is resolved ONCE (Borders.ResolveTint) and both consumers read that one verdict:
-- the halo and the IconBorder. The IconBorder op runs BEFORE the Attach guard on purpose —
-- it must hold on any item button, including a headless/harness one with no glow container.
function Borders.Apply(button, quality, unusable, quest, set)
    local r, g, bl = Borders.ResolveTint(
        quality, unusable, quest, set, Borders.Enabled(), Borders.MinQuality(), liveProvider)

    -- 1.x item.lua:210/220 — the crisp ring that anchors the wash to this cell.
    Borders.SetIconBorder(button, r, g, bl)

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

-- SUITE GLOW GEOMETRY — pinned to 1.x SOURCE (Daseeki-Bags on main), not to the spec.
-- These constants ARE the look; every one is a literal transcription with a file:line
-- citation in the constant block above. The former sibling-contract claim against
-- Daseeki-Armory is deliberately NOT asserted any more (Armory serves the equipped
-- surface and still carries the spec numbers) — see the constant block.
local function testGlowGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return math.abs(a - b) < 1e-9 end

    -- 1.x anatomy, constant by constant.
    ck(Borders.GLOW_TEXTURE == "Interface\\Buttons\\UI-ActionButton-Border",
        "1.x item.lua:55 glow texture")
    ck(Borders.GLOW_REF_BUTTON == 37, "1.x reference button is the template's own 37px")
    ck(near(Borders.GLOW_SCALE, 67 / 37), "1.x item.lua:58 SetSize(67,67) on a 37px button")
    ck(Borders.GLOW_ALPHA == 0.77,
        "owner profile glowAlpha 0.77 (WTF account #1), uniform on every tint")
    ck(Borders.GLOW_OFFSET_Y_SCALE == 0, "1.x item.lua:57 SetPoint('CENTER') — no offset")
    ck(Borders.GLOW_LAYER == "OVERLAY", "1.x item.lua:54 OVERLAY layer")
    ck(Borders.GLOW_SUBLEVEL == -1, "1.x item.lua:54 sublevel -1 (below the button's own overlay art)")

    -- REGRESSION LOCK on the previous round: these are the four spec values 1.x overrides.
    -- If any of them comes back, the glow is no longer the owner's target.
    ck(not near(Borders.GLOW_SCALE, 68 / 37), "NOT the spec's 68/37")
    ck(Borders.GLOW_ALPHA ~= 0.49, "NOT the spec's 0.49")
    -- ...and the release-blocking regression lock: 1.x's UNTOUCHED slider DEFAULT is not the
    -- owner's look. At 0.5 the wash is faint enough that the crisp IconBorder ring dominates
    -- and the cell reads as "just a hard border". Superseded by his live value.
    ck(Borders.GLOW_ALPHA ~= 0.5, "NOT 1.x's untouched default 0.5 (superseded by the profile)")
    ck(Borders.GLOW_ALPHA > 0.5, "the wash is the PRIMARY cue, stronger than the 1.x default")
    ck(Borders.GLOW_ALPHA < 1, "...and still a wash, not an opaque fill")
    ck(not near(Borders.GLOW_OFFSET_Y_SCALE, 1 / 37), "NOT the spec's (0,1) nudge")
    ck(Borders.GLOW_SUBLEVEL ~= nil, "NOT the spec's plain-OVERLAY (no sublevel)")

    -- The halo is strictly LARGER than the cell — that overhang is what makes it read as
    -- a wash over the icon edge rather than as a rim around it.
    ck(Borders.GLOW_SCALE > 1, "the halo overhangs the cell")
    ck(Borders.GLOW_SCALE_AMMO > 1, "even the Ammo halo overhangs")
    ck(Borders.GLOW_SCALE_AMMO < Borders.GLOW_SCALE, "the Ammo halo is the smaller exception")

    -- At 1.x's own button size the ratios reproduce its literal pixel values.
    ck(near(Borders.GlowSize(37), 67), "a 37px cell -> 1.x's literal 67px halo")
    ck(near(Borders.GlowOffsetY(37), 0), "…and the offset -> literally 0")

    -- Scales with the density slider's cell size, so the look holds at any cell.
    ck(Borders.GlowSize(48) > Borders.GlowSize(37), "a bigger cell gets a bigger halo")
    ck(near(Borders.GlowSize(74), 134), "a doubled cell doubles the halo (proportion held)")
    ck(Borders.GlowOffsetY(74) == 0, "…and the zero offset stays zero at every density")
    ck(Borders.GlowSize(0) == 0, "degenerate cell -> no halo")
    ck(Borders.GlowSize(-5) == 0, "negative cell -> no halo")
    ck(Borders.GlowSize(nil) == 0, "nil cell -> no halo")
    ck(Borders.GlowOffsetY(0) == 0 and Borders.GlowOffsetY(nil) == 0, "degenerate cell -> no offset")

    -- UNIFORM intensity across the precedence chain: 1.x applies ONE glowAlpha to quest
    -- gold, unusable red, set teal and every rarity, letting the COLOR carry the distinction.
    -- (The per-tier thickness below is retained for the shared outline factory only.)
    ck(Borders.TierPx(2) ~= Borders.TierPx(4), "TierPx still describes the rarity tiers")

    -- The retired well API must stay retired: 1.x draws no cell substrate in any state.
    ck(Borders.WellAlpha == nil and Borders.SetWellAlpha == nil, "well-yield API retired (1.x has no well)")
    ck(Borders.WELL_GLOW_ALPHA == nil and Borders.WELL_FULL_ALPHA == nil, "well constants retired")
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

-- CELL PARITY: the TEMPLATE IconBorder is 1.x's second half of the quality cue and is now
-- driven by the same single tint verdict as the halo. Drives the REAL Borders.Apply headless
-- — there is no _G.CreateFrame in the harness, so Attach returns nil and Apply exercises
-- exactly the pure decision + the IconBorder texture-op, which is the part under test.
local function testIconBorderParity(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return a and b and math.abs(a - b) < 1e-9 end

    local function fakeCell()
        local ib = { alpha = 0, shown = false, r = nil, g = nil, b = nil }
        function ib:SetVertexColor(r, g, b) self.r, self.g, self.b = r, g, b end
        function ib:SetAlpha(a) self.alpha = a end
        function ib:Show() self.shown = true end
        function ib:Hide() self.shown = false end
        return { IconBorder = ib }
    end

    local saved = Store.db
    Store.db = { qualityBorders = true }    -- toggle ON, default Uncommon+ floor

    -- SHOWN + TINTED for every branch of 1.x's chain, and always the SAME color the halo got.
    local rare = fakeCell()
    Borders.Apply(rare, 3)
    ck(rare.IconBorder.shown == true and rare.IconBorder.alpha == 1, "rarity -> IconBorder shown")
    ck(near(rare.IconBorder.r, FALLBACK[3][1]), "…tinted the rarity color, not Blizzard's own")
    -- RING-vs-WASH LOCK. 1.x applies glowAlpha to the HALO only (item.lua:208); the ring is a
    -- 3-arg SetVertexColor (item.lua:210) with no SetAlpha anywhere, so it renders at FULL
    -- alpha. If a future round ever "balances" the cell by dimming the ring toward
    -- GLOW_ALPHA, that is a divergence from 1.x, not a match to it — fail here first.
    ck(rare.IconBorder.alpha == 1 and rare.IconBorder.alpha ~= Borders.GLOW_ALPHA,
        "the ring is FULL alpha, never scaled by glowAlpha (1.x item.lua:210 vs :208)")
    -- ...and it carries the tint UNDIMMED: same rgb as the halo, no intensity applied.
    ck(near(rare.IconBorder.g, FALLBACK[3][2]) and near(rare.IconBorder.b, FALLBACK[3][3]),
        "…full-saturation tint on the ring, identical to the halo's")

    local questCell = fakeCell()
    Borders.Apply(questCell, 1, false, true)                 -- quest gold beats the floor
    local qr = select(1, Borders.QuestRGB())
    ck(questCell.IconBorder.shown == true and near(questCell.IconBorder.r, qr), "quest gold ring")

    local unusableCell = fakeCell()
    Borders.Apply(unusableCell, 1, true, false)              -- unusable red beats the floor
    ck(unusableCell.IconBorder.shown == true, "unusable red ring")

    local setCell = fakeCell()
    Borders.Apply(setCell, 1, false, false, true)            -- 1.x glowSets teal
    local sr, sg, sb = Borders.SetRGB()
    ck(setCell.IconBorder.shown == true, "equipment-set teal ring")
    ck(near(setCell.IconBorder.r, sr) and near(setCell.IconBorder.g, sg)
        and near(setCell.IconBorder.b, sb), "…at 1.x's (.2, 1, .8)")

    -- HIDDEN whenever the halo is hidden — the ring can never outlive the glow.
    for _, q in ipairs({ 0, 1 }) do
        local c = fakeCell()
        Borders.Apply(c, q)
        ck(c.IconBorder.shown == false and c.IconBorder.alpha == 0,
            "q" .. q .. " below the floor -> no ring at all")
    end

    -- SAME CELL, state transitions: every route that stops a glow must also drop the ring.
    local cell = fakeCell()
    Borders.Apply(cell, 5)
    ck(cell.IconBorder.shown == true, "legendary rings")
    Borders.Apply(cell, nil)                                  -- item removed -> empty slot
    ck(cell.IconBorder.shown == false, "item removed -> ring dropped")
    Borders.Apply(cell, 3)
    ck(cell.IconBorder.shown == true, "…re-rings on the next rare")
    Store.db = { qualityBorders = true, qualityBorderMin = 4 }  -- floor raised past rare
    Borders.Apply(cell, 3)
    ck(cell.IconBorder.shown == false, "floor raised past it -> ring dropped")
    Store.db = { qualityBorders = false }                       -- Item-borders toggled OFF
    Borders.Apply(cell, 5)
    ck(cell.IconBorder.shown == false, "toggle off -> no ring even on legendary")
    Store.db = { qualityBorders = true }

    -- EMPTY CELL: never glows, so it never rings. Repeated paints must stay quiet.
    local empty = fakeCell()
    for _ = 1, 3 do
        Borders.Apply(empty, nil, false, false, false)
        ck(empty.IconBorder.shown == false, "empty cell never rings")
    end

    -- $parentIconBorder fallback shape (a button with no accessor field but a name).
    local named = { GetName = function() return "DaseekiBags2FakeIB" end }
    local gib = fakeCell().IconBorder
    _G["DaseekiBags2FakeIBIconBorder"] = gib
    Borders.Apply(named, 4)
    ck(gib.shown == true, "global $parentIconBorder fallback is driven too")
    _G["DaseekiBags2FakeIBIconBorder"] = nil

    -- A foreign / region-less button must not error.
    ck(pcall(Borders.Apply, {}, 4), "a button with no IconBorder survives Apply")
    ck(pcall(Borders.SetIconBorder, nil, 1, 1, 1), "SetIconBorder(nil) is inert")

    Store.db = saved
end

-- HALO ANATOMY / LAYERING — the third half of the balance question.
--
-- The wash has to FADE INWARD over the icon edge. That is UI-ActionButton-Border's own inner
-- falloff, and it only reads that way if the halo is (a) additive, (b) larger than the cell so
-- its bright annulus lands ON the icon rather than around it, and (c) drawn OVER the ARTWORK
-- icon with nothing opaque in between. Attach/showGlow are the frame layer, so they normally
-- go untested headless (no _G.CreateFrame). This suite installs a RECORDING CreateFrame stub
-- for the duration and asserts the built structure against 1.x's:
--
--   Daseeki-Bags/core/classes/item.lua:54-58  IconGlow = CreateTexture(nil,'OVERLAY',nil,-1)
--                                             ADD blend, CENTER (no offset), 67 on a 37 button
--
-- LAYER ORDERING, stated plainly because it is the row that decides ring-vs-wash: 1.x's halo
-- is a texture ON the button at OVERLAY(-1), i.e. UNDER the button's own OVERLAY(0) art —
-- the IconBorder ring, the count numeral, the quest bang. 2.0 puts the halo on a child
-- CONTAINER frame instead (it carries the search-dim cascade), and pins that container to the
-- HOST BUTTON'S OWN frame level. Same level + OVERLAY(-1) reproduces 1.x's ordering: the
-- renderer sorts by strata, then level, then layer, then sublevel, so at equal levels the
-- halo's -1 still sorts under the button's 0. The level pin is therefore load-bearing and is
-- asserted below — a container at level+1 would float the wash over the ring and the bang.
local function testGlowAnatomy(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return a and b and math.abs(a - b) < 1e-6 end

    local function newTexture(layer, sublevel)
        local t = { layer = layer, sublevel = sublevel, shown = false, points = {} }
        function t:SetTexture(p) self.texture = p end
        function t:SetBlendMode(m) self.blend = m end
        function t:SetSize(w, h) self.w, self.h = w, h end
        function t:SetPoint(p, rel, rp, x, y)
            self.points[#self.points + 1] = { p, rel, rp, x, y }
            self.anchor, self.relTo, self.ox, self.oy = p, rel, x, y
        end
        function t:ClearAllPoints() self.points = {} end
        function t:SetVertexColor(r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
        function t:SetAlpha(a) self.alpha = a end
        function t:Show() self.shown = true end
        function t:Hide() self.shown = false end
        return t
    end

    local function newFrame(_, _, parent)
        local f = { parent = parent, level = 1, alpha = 1, shown = false, textures = {},
                    scripts = {}, events = {} }
        function f:SetPoint() end
        function f:SetFrameLevel(l) self.level = l end
        function f:GetFrameLevel() return self.level end
        function f:SetAlpha(a) self.alpha = a end
        function f:Show() self.shown = true end
        function f:Hide() self.shown = false end
        function f:SetScript(k, fn) self.scripts[k] = fn end
        function f:RegisterEvent(e) self.events[e] = true end
        function f:CreateTexture(_, layer, _, sublevel)
            local t = newTexture(layer, sublevel)
            self.textures[#self.textures + 1] = t
            return t
        end
        return f
    end

    local savedCF, savedDb = _G.CreateFrame, Store.db
    _G.CreateFrame = newFrame
    Store.db = { qualityBorders = true }

    local okRun, err = pcall(function()
        -- A 37px host button: 1.x's own cell size, so the ratios must land on 1.x's literals.
        local ib = { alpha = 0, shown = false }
        function ib:SetVertexColor(r, g, b) self.r, self.g, self.b = r, g, b end
        function ib:SetAlpha(a) self.alpha = a end
        function ib:Show() self.shown = true end
        function ib:Hide() self.shown = false end
        local button = { IconBorder = ib, level = 7 }
        function button:GetWidth() return 37 end
        function button:GetFrameLevel() return self.level end

        Borders.Apply(button, 3)                       -- a rare item: halo + ring
        local c = button._dsBagsBorder
        ck(c ~= nil, "Attach builds the halo container when CreateFrame exists")
        if not c then return end

        -- LAYER PIN: same frame level as the host button (see the block above).
        ck(c:GetFrameLevel() == button:GetFrameLevel(),
            "container sits at the HOST BUTTON'S own frame level, never above it")

        -- Exactly ONE texture in the container: the halo. Nothing else may be drawn between
        -- the ARTWORK icon and the wash — an extra opaque region here is what would flatten
        -- the inward falloff into a rim.
        ck(#c.textures == 1, "the container holds exactly one region: the halo")
        local glow = c.textures[1]
        ck(glow == c._glow, "…and it is the halo Attach cached")

        -- 1.x item.lua:54-56 anatomy.
        ck(glow.layer == Borders.GLOW_LAYER and glow.layer == "OVERLAY", "halo is OVERLAY")
        ck(glow.sublevel == Borders.GLOW_SUBLEVEL and glow.sublevel == -1,
            "…at sublevel -1, UNDER the button's own OVERLAY art (ring / count / bang)")
        ck(glow.texture == Borders.GLOW_TEXTURE, "…the UI-ActionButton-Border art (1.x item.lua:55)")
        ck(glow.blend == "ADD", "…additive, so it WASHES the icon instead of covering it")

        -- 1.x item.lua:57-58 geometry, at 1.x's own 37px cell.
        ck(near(glow.w, 67) and near(glow.h, 67), "37px cell -> 1.x's literal 67x67 halo")
        ck(glow.w > 37, "the halo overhangs the cell, so its bright ring lands ON the icon")
        ck(glow.anchor == "CENTER" and near(glow.oy or 0, 0), "CENTER anchor, no offset")

        -- THE BALANCE ROW: the painted alpha is the owner's profile value, not 1.x's default.
        ck(near(glow.a, Borders.GLOW_ALPHA), "the halo is painted at GLOW_ALPHA")
        ck(near(glow.a, 0.77), "…which is the owner's 0.77, not 1.x's untouched 0.5")
        ck(glow.shown == true and c.shown == true, "a rare cell's wash is shown")
        ck(c.alpha == 1, "…at full container alpha (no stale search-dim carried in)")

        -- ...and the RING under it is untouched by that alpha (1.x item.lua:210, 3-arg).
        ck(ib.shown == true and ib.alpha == 1, "the ring stays FULL alpha beside a 0.77 wash")

        -- Search-dim cascade still recedes the whole cue together, then restores on repaint.
        Borders.SetAlpha(button, 0.3)
        ck(near(c.alpha, 0.3), "search-dim recedes the halo container")
        Borders.Apply(button, 4)
        ck(c.alpha == 1, "…and the next paint clears the dim")

        -- Below the floor: wash off AND ring off, one verdict.
        Borders.Apply(button, 1)
        ck(c.shown == false and ib.shown == false, "common -> no wash, no ring")

        -- Density: a bigger cell scales the halo by the same 67/37 proportion.
        function button:GetWidth() return 74 end
        Borders.Apply(button, 4)
        ck(near(c._glow.w, 134), "a doubled cell doubles the halo (proportion held)")

        -- Attach is idempotent: a repaint never builds a second halo (C rule 1).
        local before = #c.textures
        Borders.Attach(button); Borders.Apply(button, 5)
        ck(button._dsBagsBorder == c and #c.textures == before,
            "Attach is idempotent — one halo per cell, baked at creation")
    end)
    ck(okRun, "glow anatomy stub run: " .. tostring(err))

    _G.CreateFrame = savedCF
    Store.db = savedDb
end

-- The glow decision is ONE decision: ResolveTint drives both the halo and the template
-- IconBorder, and it must reproduce 1.x's UpdateBorder precedence exactly
-- (item.lua:197-205 — quest > unusable > set > rarity).
local function testResolveTintPrecedence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    local MIN = DEFAULT_MIN_QUALITY

    -- quest gold wins over unusable, set AND a legendary rarity
    local r, g, b = Borders.ResolveTint(5, true, true, true, true, MIN)
    local qr, qg, qb = Borders.QuestRGB()
    ck(near(r, qr) and near(g, qg) and near(b, qb), "quest gold wins the chain")
    -- unusable red wins over set and rarity
    local ur = Borders.UnusableRGB()
    ck(near(select(1, Borders.ResolveTint(5, true, false, true, true, MIN)), ur),
        "unusable beats set + rarity")
    -- set teal wins over rarity
    local sr, sg, sb = Borders.SetRGB()
    local xr, xg, xb = Borders.ResolveTint(5, false, false, true, true, MIN)
    ck(near(xr, sr) and near(xg, sg) and near(xb, sb), "set teal beats rarity (1.x glowSets)")
    -- ...and a set item BELOW the rarity floor still glows teal (the branch is above the gate)
    ck(near(select(1, Borders.ResolveTint(1, false, false, true, true, MIN)), sr),
        "a COMMON set item still glows teal")
    -- rarity when no flag is set
    ck(near(select(1, Borders.ResolveTint(3, false, false, false, true, MIN)), FALLBACK[3][1]),
        "rarity color when no override")
    -- the floor and the toggle both close the gate
    ck(Borders.ResolveTint(1, false, false, false, true, MIN) == nil, "common -> no tint")
    ck(Borders.ResolveTint(nil, false, false, false, true, MIN) == nil, "empty -> no tint")
    ck(Borders.ResolveTint(5, true, true, true, false, MIN) == nil, "toggle off -> no tint at all")
    ck(Borders.ResolveTint(3, false, false, false, true, 4) == nil, "raised floor -> no tint")

    -- GlowShown is the boolean face of it, and it is exactly what the IconBorder keys off.
    ck(Borders.GlowShown(3, false, false, false, true, MIN) == true, "GlowShown: rare glows")
    ck(Borders.GlowShown(1, false, false, false, true, MIN) == false, "GlowShown: common does not")
    ck(Borders.GlowShown(1, false, true, false, true, MIN) == true, "GlowShown: quest common glows")
    ck(Borders.GlowShown(1, false, false, true, true, MIN) == true, "GlowShown: set common glows")
    ck(Borders.GlowShown(4, false, false, false, false, MIN) == false, "GlowShown: toggle off silences epic")
end

function Borders.RunSelfTests(verbose)
    local suites = {
        { name = "should-show gate",     fn = testShouldShow },
        { name = "glow geometry (1.x source)", fn = testGlowGeometry },
        { name = "spec colors + bag gate",  fn = testSpecColorsAndBagGate },
        { name = "resolve-tint precedence", fn = testResolveTintPrecedence },
        { name = "icon-border parity",      fn = testIconBorderParity },
        { name = "glow anatomy (layering)", fn = testGlowAnatomy },
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
