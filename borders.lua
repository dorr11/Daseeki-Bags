-- Daseeki Bags 2.0 — borders.lua
-- Quality-colored borders for item buttons (Daseeki-Armory borders.lua parity,
-- adapted from equipped-slot buttons to bag item buttons). Uncommon (q>=2) and up
-- get a thin flat colored frame; poor/common stay plain so a full bag reads quiet.
--
-- Deliberately SELF-CONTAINED and split into a PURE decision layer (ShouldShow /
-- QualityRGB / Enabled — headless-testable) and a thin FRAME layer (Attach / Apply
-- — in-game only, guarded on CreateFrame). Colors come from C_Item.GetItemQualityColor
-- (authoritative) with an ITEM_QUALITY_COLORS fallback and, for the headless harness,
-- a small table of the game's public quality colors. Fresh code — no Bagnon lines.
--
-- Toggle: Store.db.qualityBorders (a store setting; defaults ON when unset so borders
-- show before the W4 options page persists a value). W1's defaults tree does not yet
-- carry this key — see the merge notes for the one-line store default to add.

local ADDON, ns = ...

local Borders = {}
ns.Borders = Borders

local Store = ns.Store

-- Uncommon and up. Below this a slot shows no colored border (suite-quiet aesthetic).
local MIN_QUALITY = 2
Borders.MIN_QUALITY = MIN_QUALITY

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
-- (a still-uncached migrated item) yields nil so the caller hides the border.
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

-- True when a colored border should be shown for this quality given the toggle.
function Borders.ShouldShow(quality, enabled)
    if not enabled then return false end
    if quality == nil then return false end
    return quality >= MIN_QUALITY
end

-- The border toggle, read live from the store settings. Defaults ON when the store
-- or the key is absent (so borders render before W4 writes a persisted value).
function Borders.Enabled()
    local db = Store and Store.db
    if type(db) ~= "table" then return true end
    if db.qualityBorders == nil then return true end
    return db.qualityBorders and true or false
end

----------------------------------------------------------------------
-- FRAME layer (in-game only; every WoW API call guarded)
----------------------------------------------------------------------

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

-- A thin flat colored border framing a button's icon (suite-flat, 2px), created once
-- and reused. Idempotent: returns the existing border on repeat calls.
local FLAT_EDGE = { edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 }
function Borders.Attach(button)
    if not button then return nil end
    if button._dsBagsBorder then return button._dsBagsBorder end
    if not _G.CreateFrame then return nil end
    local b = _G.CreateFrame("Frame", nil, button, "BackdropTemplate")
    b:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
    b:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
    b:SetFrameLevel((button:GetFrameLevel() or 1) + 1)
    if b.SetBackdrop then b:SetBackdrop(FLAT_EDGE) end
    b:Hide()
    button._dsBagsBorder = b
    return b
end

-- Color (or hide) a button's quality border. Honors the store toggle live.
function Borders.Apply(button, quality)
    local b = Borders.Attach(button)
    if not b then return end
    if Borders.ShouldShow(quality, Borders.Enabled()) then
        local r, g, bl = Borders.QualityRGB(quality, liveProvider)
        if r and b.SetBackdropBorderColor then
            b:SetBackdropBorderColor(r, g, bl, 1)
            b:Show()
            return
        end
    end
    b:Hide()
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "borders")
----------------------------------------------------------------------

local function testShouldShow(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Borders.ShouldShow(nil, true) == false, "nil quality -> no border")
    ck(Borders.ShouldShow(0, true)   == false, "poor -> no border")
    ck(Borders.ShouldShow(1, true)   == false, "common -> no border")
    ck(Borders.ShouldShow(2, true)   == true,  "uncommon -> border")
    ck(Borders.ShouldShow(3, true)   == true,  "rare -> border")
    ck(Borders.ShouldShow(4, true)   == true,  "epic -> border")
    ck(Borders.ShouldShow(5, true)   == true,  "legendary -> border")
    ck(Borders.ShouldShow(4, false)  == false, "disabled -> no border even for epic")
end

local function testQualityRGB(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- injected provider wins when it returns a color
    local r, g, b = Borders.QualityRGB(3, function(q) return 0.10, 0.20, 0.30 end)
    ck(r == 0.10 and g == 0.20 and b == 0.30, "provider color used")
    -- fall back to the static table when the provider returns nil
    local r2 = Borders.QualityRGB(4, function() return nil end)
    ck(r2 ~= nil, "static fallback used when provider yields nil")
    ck(select(1, Borders.QualityRGB(2)) == FALLBACK[2][1], "no provider -> static uncommon color")
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

function Borders.RunSelfTests(verbose)
    local suites = {
        { name = "should-show gate", fn = testShouldShow },
        { name = "quality color",    fn = testQualityRGB },
        { name = "enabled toggle",   fn = testEnabledToggle },
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
