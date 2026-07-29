-- Daseeki Bags 2.0 — borders.lua
-- LAYER 1 of the two-layer item dress: QUALITY as quiet identity (Field Ledger).
--
-- The quality edge is INFORMATION the player wants (rarity-at-a-glance) but rendered
-- as tinted ink, never neon (BRAND_SPEC §5 attention-inversion; a bag of greens must
-- read calm). Reconciliation, per the B/C design:
--   * Floor raised to RARE+ (quality >= 3). Uncommon (2) and below get NO edge — a
--     full bag of whites/greens stays quiet. (Was uncommon+ 2px full-sat: the beta's
--     "very bright" culprit.)
--   * The edge is a 1px PIXEL-SNAPPED texture outline — SetSnapToPixelGrid(true) +
--     SetTexelSnappingBias(0), NOT a BackdropTemplate edgeSize (a 1px edgeSize half-
--     samples at fractional scale -> a fuzzy grey rim; snapped textures stay crisp at
--     720p). Epic+ (quality >= 4) gets a 2px snapped edge — the rare exception the eye
--     should catch, which is attention-aligned by construction.
--   * Color is desaturated ~15% toward parchment (retain ~85% chroma) so it reads as
--     tinted ink, not an LED — while staying hue-distinguishable at 1px (blue/purple/
--     orange remain separable; see the hue-table self-test).
--
-- SECURE / TAINT (C rule 1): the edge is a non-secure Frame child of the button with
-- texture children only. Attach() (structure) runs at button CREATION (out of combat,
-- gated by ui_items' combat-deferred layout) — the dress is BAKED at creation, never
-- restyled-in-combat structurally. Apply() (recolor / show / hide / resize the edge
-- textures) touches ONLY children and is a texture op, safe even mid-combat. No
-- protected op (SetParent/SetPoint/Show/Hide/SetID/SetAttribute/SetSize/SetFrameLevel)
-- is ever called on the secure button itself at runtime.
--
-- Split into a PURE decision layer (ShouldShow / QualityRGB / TierPx / Desaturate /
-- Enabled — headless-testable) and a thin FRAME layer (Attach / Apply / SetAlpha —
-- in-game only, guarded on _G.CreateFrame). Fresh code — no Bagnon lines.
--
-- Toggle: Store.db.qualityBorders (defaults ON when unset).

local ADDON, ns = ...

local Borders = {}
ns.Borders = Borders

local Store = ns.Store

-- Rare and up. Below this a slot shows no colored edge (suite-quiet aesthetic).
local MIN_QUALITY = 3
Borders.MIN_QUALITY = MIN_QUALITY
-- Epic and up render a 2px snapped edge (the only 2px in the grid).
local EPIC_QUALITY = 4
Borders.EPIC_QUALITY = EPIC_QUALITY

-- Desaturation toward parchment: retain ~85% chroma (pull 15% toward the cream text
-- tone) so the edge reads as tinted ink. Kept small so hue survives at 1px.
local PARCHMENT_PULL = 0.15
Borders.PARCHMENT_PULL = PARCHMENT_PULL
-- Default parchment target for the headless/pure path (= the default "text" cream).
-- The live path passes the active theme's text token instead.
local PARCHMENT = { 0.9137, 0.8784, 0.8039 }
Borders._parchment = PARCHMENT

----------------------------------------------------------------------
-- Public quality colors (Blizzard's ITEM_QUALITY_COLORS values; game facts, not
-- addon code) — used only when neither C_Item nor _G.ITEM_QUALITY_COLORS is present
-- (i.e. the headless harness), so QualityRGB is deterministic under test.
----------------------------------------------------------------------
local FALLBACK = {
    [0] = { 0.62, 0.62, 0.62 }, -- Poor (grey)
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
    if provider then
        local r, g, b = provider(quality)
        if r then return r, g, b end
    end
    local c = FALLBACK[quality]
    if c then return c[1], c[2], c[3] end
    return nil
end

-- True when a colored edge should be shown for this quality given the toggle.
function Borders.ShouldShow(quality, enabled)
    if not enabled then return false end
    if quality == nil then return false end
    return quality >= MIN_QUALITY
end

-- Edge thickness in LOGICAL pixels for a quality: epic+ = 2, rare = 1. Only meaningful
-- when ShouldShow is true. (The frame layer multiplies this by one physical pixel.)
function Borders.TierPx(quality)
    if quality == nil then return 0 end
    if quality >= EPIC_QUALITY then return 2 end
    if quality >= MIN_QUALITY then return 1 end
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

-- Live parchment target = the active theme's "text" cream (so the desaturation warms
-- toward the real substrate under any theme). Falls back to the default cream.
local function liveParchment()
    if _G.DaseekiUI and _G.DaseekiUI.Color then return _G.DaseekiUI.Color("text") end
    return PARCHMENT[1], PARCHMENT[2], PARCHMENT[3]
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

-- Position the four edge textures as a 1px/2px snapped outline of thickness b._pxTier.
local function layoutEdges(b)
    if not b._edges then return end
    local unit = onePixel(b) * (b._pxTier or 1)
    local e = b._edges
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

local function forEachEdge(b, fn)
    if not b._edges then return end
    fn(b._edges.top); fn(b._edges.bottom); fn(b._edges.left); fn(b._edges.right)
end

-- Attach the quality-edge structure to a button ONCE, at creation. Idempotent: returns
-- the existing edge container on repeat calls. The container is a non-secure Frame child
-- holding four snapped WHITE8X8 edge textures (created here, never re-created at runtime).
function Borders.Attach(button)
    if not button then return nil end
    if button._dsBagsBorder then return button._dsBagsBorder end
    if not _G.CreateFrame then return nil end
    local b = _G.CreateFrame("Frame", nil, button)
    -- Frame a hair OUTSIDE the icon so the edge rims the slot without clipping the art.
    b:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
    b:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
    if b.SetFrameLevel then b:SetFrameLevel((button:GetFrameLevel() or 1) + 1) end

    local function newEdge()
        local t = b:CreateTexture(nil, "OVERLAY")
        t:SetTexture(WHITE)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(true) end   -- crisp 1px at 720p
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        t:Hide()
        return t
    end
    b._edges = { top = newEdge(), bottom = newEdge(), left = newEdge(), right = newEdge() }
    b._pxTier = 1
    b._dsRelayout = function(self)
        -- Only re-lay a currently-shown edge (thickness follows scale); hidden edges are
        -- re-laid on their next Apply. Cheap and self-limiting.
        if self:IsShown() then layoutEdges(self) end
    end
    -- Re-lay on show so the physical thickness is computed at the realized effective
    -- scale (paint runs before the button's first Show; effective scale is only reliable
    -- once shown). Own-frame OnShow — never touches the secure button.
    b:SetScript("OnShow", function(self) layoutEdges(self) end)

    b:Hide()
    button._dsBagsBorder = b
    ensureSnapDriver()
    if snapSet then snapSet[b] = true end
    return b
end

-- Color (or hide) a button's quality edge. Honors the store toggle live. Recolor/resize/
-- show/hide of the edge textures only — safe to call on every repaint, even in combat.
function Borders.Apply(button, quality)
    local b = Borders.Attach(button)
    if not b then return end
    if not Borders.ShouldShow(quality, Borders.Enabled()) then
        b:Hide()
        return
    end
    local r, g, bl = Borders.QualityRGB(quality, liveProvider)
    if not r then b:Hide(); return end
    local tr, tg, tb = liveParchment()
    r, g, bl = Borders.Desaturate(r, g, bl, PARCHMENT_PULL, tr, tg, tb)
    b._pxTier = Borders.TierPx(quality)
    layoutEdges(b)
    forEachEdge(b, function(t)
        if t.SetVertexColor then t:SetVertexColor(r, g, bl, 1) end
        t:Show()
    end)
    b:Show()
end

-- Dim-cascade support (search-dim): scale the whole edge's alpha so a dimmed slot's
-- quality rim recedes with its icon instead of floating at full strength. A hidden edge
-- stays hidden (SetAlpha on a hidden frame is inert); this never force-shows an edge.
function Borders.SetAlpha(button, alpha)
    local b = button and button._dsBagsBorder
    if b and b.SetAlpha then b:SetAlpha(alpha or 1) end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "borders")
----------------------------------------------------------------------

local function testShouldShow(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Borders.ShouldShow(nil, true) == false, "nil quality -> no edge")
    ck(Borders.ShouldShow(0, true)   == false, "poor -> no edge")
    ck(Borders.ShouldShow(1, true)   == false, "common -> no edge")
    ck(Borders.ShouldShow(2, true)   == false, "uncommon -> NO edge (rare+ floor)")
    ck(Borders.ShouldShow(3, true)   == true,  "rare -> edge")
    ck(Borders.ShouldShow(4, true)   == true,  "epic -> edge")
    ck(Borders.ShouldShow(5, true)   == true,  "legendary -> edge")
    ck(Borders.ShouldShow(4, false)  == false, "disabled -> no edge even for epic")
end

-- Quality-floor matrix incl. per-tier thickness and the hue table.
local function testQualityFloorMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Tier thickness: below floor = 0, rare = 1px, epic/legendary/artifact = 2px.
    ck(Borders.TierPx(nil) == 0, "nil -> 0px")
    ck(Borders.TierPx(0)   == 0, "poor -> 0px")
    ck(Borders.TierPx(1)   == 0, "common -> 0px")
    ck(Borders.TierPx(2)   == 0, "uncommon -> 0px (below floor)")
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
    -- 12 slots: poor, commons, uncommons, one rare, one epic, an empty (nil quality).
    local bag = { 0, 1, 1, 1, 2, 2, 1, 3, 1, 2, 4, nil }
    local rimmed, px1, px2 = 0, 0, 0
    for slot = 1, 12 do
        local q = bag[slot]
        if Borders.ShouldShow(q, true) then
            rimmed = rimmed + 1
            local p = Borders.TierPx(q)
            if p == 1 then px1 = px1 + 1 elseif p == 2 then px2 = px2 + 1 end
        else
            ck(Borders.TierPx(q) == 0, "sub-rare slot (q=" .. tostring(q) .. ") -> 0px")
        end
    end
    ck(rimmed == 2, "mixed bag: exactly 2 of 12 slots rimmed (the rare + the epic), got " .. rimmed)
    ck(px1 == 1, "exactly one 1px edge (the rare)")
    ck(px2 == 1, "exactly one 2px edge (the epic)")
    -- The commons/uncommons that dominate the bag are explicitly quiet.
    ck(Borders.ShouldShow(1, true) == false and Borders.ShouldShow(2, true) == false,
        "commons + uncommons stay edgeless (bag reads calm)")
    -- Disabling the toggle silences even the rare+ pair.
    local silenced = 0
    for slot = 1, 12 do if Borders.ShouldShow(bag[slot], false) then silenced = silenced + 1 end end
    ck(silenced == 0, "toggle off -> no slot rimmed at all")
end

function Borders.RunSelfTests(verbose)
    local suites = {
        { name = "should-show gate",     fn = testShouldShow },
        { name = "quality-floor matrix", fn = testQualityFloorMatrix },
        { name = "mixed-bag mapping",    fn = testMixedBagMapping },
        { name = "quality color",        fn = testQualityRGB },
        { name = "enabled toggle",       fn = testEnabledToggle },
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
