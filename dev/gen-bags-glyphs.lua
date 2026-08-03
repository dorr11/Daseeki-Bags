-- Daseeki-Bags 2.0 — window control glyphs (owned assets).
--
-- Authors the icon set for the window's control strips, in the SAME stroke family
-- as the Nexus dashboard icons (icon-gear / icon-close), so the two addons read as
-- one system:
--
--   icon-search.tga   — magnifier            (filter this window as you type)
--   icon-sort.tga     — down arrow           (sort bags)
--   icon-find.tga     — bulleted list        (find an item across all characters)
--   icon-layout.tga   — two vertical panes   (combined <-> split toggle)
--   icon-owner.tga    — person bust          (owner selector)
--   icon-raidprep.tga — stoppered flask      (Daseeki-Raid-Prep checklist toggle)
--   icon-lock-slot.tga — prohibition sign    (a SORT-LOCKED item cell; see its block
--                                             below — cell-scale, not strip-scale)
--
-- icon-gear.tga and icon-close.tga are NOT authored here: they are copied verbatim
-- from Daseeki-Nexus/textures (our own assets, same 64x64 byte format), so the gear
-- and the close mark are pixel-identical across the suite. Do not redraw them.
--
-- CLEAN-ROOM: every shape below is generated from the geometry in this file. No
-- addon's art is read, traced or copied. The SHAPES are universal symbols; the
-- pixels are ours.
--
-- Output format byte-matches Daseeki-Nexus/textures/round-corner.tga: an 18-byte
-- uncompressed true-colour TGA header (type 2), 32-bit BGRA, descriptor 0x28
-- (top-left origin), 64x64 => 16402 bytes exactly. White RGB on a transparent field
-- so SetVertexColor tints the glyph with a theme token (muted at rest, accent on
-- hover; danger on the close).
--
-- Usage:  lua5.1 gen-bags-glyphs.lua <outdir>      (outdir defaults to ".")
--
-- DESIGN INVARIANTS (carried over from the Nexus set — keep them):
--   * STROKE = 6 is shared by the whole set so every icon reads at one weight.
--   * Optical reach ~20-24 from centre (gear teeth 24, close arm 14*sqrt2 ~= 20).
--     Each glyph below is tuned to that same reach so none looks bigger than the
--     rest when they sit shoulder-to-shoulder in the title row.
--   * Glyphs carry their own margin inside the 64px field, so the runtime uses NO
--     SetTexCoord crop — the texture is anchored with a flat 2px inset on a 22x22
--     button (18x18 drawn), exactly like the Nexus dashboard.

local W, H   = 64, 64
local CX, CY = W / 2, H / 2
local SS     = 6                 -- supersample grid per pixel (6x6 = 36 samples) for AA
local STROKE = 6                 -- shared stroke weight (px, in the 64px field)
local HALF   = STROKE / 2

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

----------------------------------------------------------------------
-- shape primitives (all take MATH coords: +x right, +y up, origin at centre)
----------------------------------------------------------------------

local function inDisc(x, y, r) return (x * x + y * y) <= r * r end

-- Distance from point to segment AB, for round-capped thick strokes (capsules).
local function inSegment(x, y, ax, ay, bx, by, halfW)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then
        t = ((x - ax) * dx + (y - ay) * dy) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local px, py = ax + t * dx, ay + t * dy
    local ex, ey = x - px, y - py
    return (ex * ex + ey * ey) <= halfW * halfW
end

-- Point-in-triangle (barycentric sign test).
local function inTriangle(x, y, x1, y1, x2, y2, x3, y3)
    local function sign(ax, ay, bx, by, cx, cy)
        return (ax - cx) * (by - cy) - (bx - cx) * (ay - cy)
    end
    local d1 = sign(x, y, x1, y1, x2, y2)
    local d2 = sign(x, y, x2, y2, x3, y3)
    local d3 = sign(x, y, x3, y3, x1, y1)
    local neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (neg and pos)
end

-- Annulus ("ring wall") of radius r and half-thickness halfW, centred at (cx, cy).
-- The Nexus generator only had an origin-centred sector; the magnifier and the
-- shoulder line need an OFFSET ring, so the centre is a parameter here.
local function inRingAt(x, y, cx, cy, r, halfW)
    local dx, dy = x - cx, y - cy
    local d = math.sqrt(dx * dx + dy * dy)
    return d >= (r - halfW) and d <= (r + halfW)
end

-- The same ring, clipped to an angular sector [a0, a1] in degrees CCW (wrap-aware).
local function inArcAt(x, y, cx, cy, r, a0, a1, halfW)
    if not inRingAt(x, y, cx, cy, r, halfW) then return false end
    local ang = math.deg(math.atan2(y - cy, x - cx))
    if ang < 0 then ang = ang + 360 end
    a0 = a0 % 360; a1 = a1 % 360
    if a0 <= a1 then return ang >= a0 and ang <= a1 end
    return ang >= a0 or ang <= a1          -- wrapped sector
end

----------------------------------------------------------------------
-- glyph definitions
----------------------------------------------------------------------

-- SEARCH: the universal magnifier — a ring plus a tangential handle running to the
-- lower right. The ring is pushed up-left so the whole mark balances in the field
-- (the handle carries weight to the lower right).
local S_CX, S_CY, S_R = -4, 4, 12
local function glyphSearch(x, y)
    if inRingAt(x, y, S_CX, S_CY, S_R, HALF) then return true end
    -- handle: from the ring's -45 degree point outward along the same diagonal
    local th = math.rad(-45)
    local hx, hy = S_CX + S_R * math.cos(th), S_CY + S_R * math.sin(th)
    if inSegment(x, y, hx, hy, 16, -16, HALF) then return true end
    return false
end

-- SORT: a plain down-arrow — a capsule shaft with a solid head. Reads as
-- "arrange / collapse downward" and matches the ~24 reach of the gear's teeth.
local function glyphSort(x, y)
    if inSegment(x, y, 0, 20, 0, -6, HALF) then return true end
    if inTriangle(x, y, 0, -24, -13, -5, 13, -5) then return true end
    return false
end

-- FIND (across characters): a bulleted list — three rows, each a leading dot plus a
-- rule. Deliberately NOT a second magnifier: this opens the cross-character roster,
-- so it reads as a list of results, not as a filter on the current window.
local F_ROWS   = { 13, 0, -13 }
local F_DOT_X  = -17
local F_DOT_R  = 3.2
local F_BAR_A, F_BAR_B = -8, 18
local function glyphFind(x, y)
    for i = 1, #F_ROWS do
        local ry = F_ROWS[i]
        if inDisc(x - F_DOT_X, y - ry, F_DOT_R) then return true end
        if inSegment(x, y, F_BAR_A, ry, F_BAR_B, ry, 2.6) then return true end
    end
    return false
end

-- LAYOUT (combined <-> split): two vertical panes standing side by side. Vertical
-- bars, so it never reads as the horizontal FIND list next to it in the strip.
local L_HALF_W = 6.5      -- half-width of one pane
local L_GAP    = 4        -- half the air between the two panes
local L_TOP    = 16
local function glyphLayout(x, y)
    local cx = L_GAP + L_HALF_W          -- pane centre offset from the middle
    if inSegment(x, y, -cx, L_TOP, -cx, -L_TOP, L_HALF_W) then return true end
    if inSegment(x, y,  cx, L_TOP,  cx, -L_TOP, L_HALF_W) then return true end
    return false
end

-- OWNER: a person bust — a head disc over a shoulder arc. The arc is a wide, shallow
-- sector of a big offset ring, which keeps the silhouette open (not a filled blob)
-- and holds the same stroke weight as the rest of the set.
local O_HEAD_R, O_HEAD_Y = 8, 8
local O_SH_CY, O_SH_R    = -28, 24
local function glyphOwner(x, y)
    if inDisc(x, y - O_HEAD_Y, O_HEAD_R) then return true end
    if inArcAt(x, y, 0, O_SH_CY, O_SH_R, 42, 138, 3.5) then return true end
    return false
end

-- RAID PREP: a stoppered FLASK — a round-bottomed body arc, two shoulders rising to a
-- narrow neck, capped by a stopper bar. Raid Prep is a consumables checklist, and 1.x's
-- own button wore a potion item icon (Mighty Rage Potion), so the flask is the honest
-- symbol for it. Drawn as an OUTLINE, not a filled bottle, so it keeps the set's open
-- silhouette; the arc is deliberately cut at the shoulders instead of closing into a
-- circle, which is what stops it reading as the gear or the owner bust beside it.
local P_BODY_CY, P_BODY_R = -6, 13     -- body arc centre + radius (reach 22 downward)
local P_NECK_X            = 6.5        -- neck half-separation
local P_NECK_TOP          = 15.5
local P_SHOULDER_Y        = 7
local P_CAP_Y, P_CAP_X    = 18, 9.5    -- stopper bar (reach 21 upward)
local function glyphRaidPrep(x, y)
    -- body: the arc from the left shoulder round the bottom to the right shoulder
    if inArcAt(x, y, 0, P_BODY_CY, P_BODY_R, 150, 30, HALF) then return true end
    -- shoulders: arc ends (r*cos150, cy + r*sin150) angling in to the neck
    local ax = P_BODY_R * math.cos(math.rad(150))
    local ay = P_BODY_CY + P_BODY_R * math.sin(math.rad(150))
    if inSegment(x, y, ax, ay, -P_NECK_X, P_SHOULDER_Y, HALF) then return true end
    if inSegment(x, y, -ax, ay, P_NECK_X, P_SHOULDER_Y, HALF) then return true end
    -- neck: two uprights to the stopper
    if inSegment(x, y, -P_NECK_X, P_SHOULDER_Y, -P_NECK_X, P_NECK_TOP, 2.8) then return true end
    if inSegment(x, y,  P_NECK_X, P_SHOULDER_Y,  P_NECK_X, P_NECK_TOP, 2.8) then return true end
    -- stopper
    if inSegment(x, y, -P_CAP_X, P_CAP_Y, P_CAP_X, P_CAP_Y, HALF) then return true end
    return false
end

-- LOCK SLOT: the PROHIBITION SIGN — a ring with a diagonal bar through it. This is the
-- mark a sort-locked cell wears in the lock config mode (locks.lua / ui_items.lua), and
-- it is the one glyph in this file that is NOT a title-row control:
--
--   * it is drawn over a whole 37px ITEM CELL, not inside a 22px button, so it uses its
--     own reach (26 + half-stroke = 30 of the 32 available) instead of the set's 20-24.
--     At cell size the strip reach would read as a small dot in the middle of an icon.
--   * it carries its own heavier stroke (8) for the same reason: it has to be legible
--     ON TOP of a busy item icon, where the strip's 6 would disappear into the artwork.
--
-- Everything else is the house treatment: white on transparent, so the runtime tints it
-- with a theme token (`danger` — the same red 1.x's own overlay reads as).
--
-- CLEAN-ROOM: a circle and a line. 1.x used a Blizzard file id for its overlay; this is
-- generated from the geometry right here, like every other glyph in this file.
local K_R      = 26      -- ring radius (cell-scale, not strip-scale)
local K_STROKE = 8
local K_HALF   = K_STROKE / 2
local function glyphLockSlot(x, y)
    if inRingAt(x, y, 0, 0, K_R, K_HALF) then return true end
    -- the bar: the 135 degree diameter (upper-left to lower-right), the orientation
    -- every "no" sign uses.
    local th = math.rad(135)
    local bx, by = K_R * math.cos(th), K_R * math.sin(th)
    if inSegment(x, y, bx, by, -bx, -by, K_HALF) then return true end
    return false
end

----------------------------------------------------------------------
-- rasteriser
----------------------------------------------------------------------

local function writeTGA(path, hit)
    local hdr = string.char(
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        W % 256, math.floor(W / 256),
        H % 256, math.floor(H / 256),
        32, 0x28)                              -- 32bpp, top-left origin
    local rows, step = {}, 1 / SS
    for yi = 0, H - 1 do                       -- top-left origin: first row is the TOP
        local cols = {}
        for xi = 0, W - 1 do
            local hits = 0
            for sy = 0, SS - 1 do
                for sx = 0, SS - 1 do
                    local px = (xi + (sx + 0.5) * step) - CX
                    -- flip to math coords (+y up) so the shape maths reads naturally
                    local py = CY - (yi + (sy + 0.5) * step)
                    if hit(px, py) then hits = hits + 1 end
                end
            end
            local a = math.floor(clamp01(hits / (SS * SS)) * 255 + 0.5)
            cols[#cols + 1] = string.char(255, 255, 255, a)   -- B,G,R,A — white glyph
        end
        rows[#rows + 1] = table.concat(cols)
    end
    local f = assert(io.open(path, "wb"))
    f:write(hdr); f:write(table.concat(rows)); f:close()
    print("wrote " .. path)
end

local dir = (arg and arg[1]) or "."
writeTGA(dir .. "/icon-search.tga", glyphSearch)
writeTGA(dir .. "/icon-sort.tga",   glyphSort)
writeTGA(dir .. "/icon-find.tga",   glyphFind)
writeTGA(dir .. "/icon-layout.tga", glyphLayout)
writeTGA(dir .. "/icon-owner.tga",  glyphOwner)
writeTGA(dir .. "/icon-raidprep.tga", glyphRaidPrep)
writeTGA(dir .. "/icon-lock-slot.tga", glyphLockSlot)
