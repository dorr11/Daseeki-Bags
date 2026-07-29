-- Daseeki Bags 2.0 — ui_items.lua
-- The item button + grid group. Two layers, cleanly separated so the whole data
-- side is headless-testable and the render/interaction side stays thin:
--
--   PURE core (no WoW API; unit-tested by the harness):
--     Items.ContainerRank / cidInScope     — canonical container ordering + scope
--     Items.BuildGroups / Items.BuildEntries — turn a store owner into the entry lists
--                                              the frame agent consumes (per-container
--                                              grouping AND combined flatten)
--     Items.GridMetrics / Items.SlotPosition — grid math (cols/rows/self-size/xy)
--     Items.ResolveVisual                   — icon/quality/name derivation with the
--                                              nil-quality (migrated) -> pending path
--     Items.DimValues / Items.FormatCachedAge
--
--   FRAME layer (in-game only; every WoW API call guarded on _G):
--     Items.CreateButton -> B:SetSlot / B:SetEmpty / B:Clear / B:SetDimmed
--     Items.CreateGroup  -> G:SetGrid / G:ShowSlots / G:Clear (self-sizing, never 0)
--
-- Interface contract (shared with the sibling ui_frame.lua):
--   entries = array of { owner=<ownerRec>, cid=<containerID>, slot=<n>, data=<slot|nil> }
--
-- LIVE slots (owner == the logged-in character): buttons inherit the game's
-- ContainerFrameItemButtonTemplate and are parented to a per-container holder frame
-- carrying holder:SetID(cid); with button:SetID(slot) the template's OWN default
-- secure/combat-correct handlers (pickup / place / split / use / real-slot tooltip)
-- operate on the right (bag, slot) with zero behavior re-implemented — the public
-- Blizzard template contract, not transcribed addon code. Structural (re)builds are
-- deferred out of combat (secure frames are protected).
-- OFFLINE / REMOTE owners: render-only ItemButtonTemplate buttons — icon/count/quality
-- from cached data, hyperlink tooltip + "cached Xd ago", clicks inert (shift-link only).
--
-- Every API is catalog-verified against wow-api-catalog/1.15.9.68808:
--   C_Item.GetItemInfoInstant (icon, always resolvable), C_Item.GetItemInfo (name/quality,
--   async), C_Item.RequestLoadItemDataByID; Event.Item.GetItemInfoReceived
--   (== GET_ITEM_INFO_RECEIVED {itemID, success}); C_Container.GetContainerItemCooldown
--   / GetContainerItemQuestInfo; SetItemButtonTexture/Count/Desaturated; CooldownFrame_Set.

local ADDON, ns = ...

local Items = {}
ns.Items = Items

local Store = ns.Store

----------------------------------------------------------------------
-- Grid defaults (Classic bag cell is 37px; tune via G:SetGrid)
----------------------------------------------------------------------

Items.DEFAULT_SIZE    = 37
Items.DEFAULT_GAP     = 4
Items.DEFAULT_COLUMNS = 12
Items.MIN_CELL        = 30   -- 720p floor (C): below this the 1px quality edge + count numeral degrade together
Items.HEADER_HEIGHT   = 16   -- split-mode per-bag header band (sits ABOVE the grid)
Items.PLACEHOLDER_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Human labels per container class for the split-view bag header (fallback when the
-- bag item's real name is not resolvable from a link).
local CLASS_LABEL = {
    backpack = "Backpack", bag = "Bag", keyring = "Keyring",
    bank = "Bank", bankbag = "Bank Bag", unknown = "Items",
}

----------------------------------------------------------------------
-- PURE: container ordering + scope
----------------------------------------------------------------------

-- Canonical render order across containers (both combined flatten and split groups
-- sort by this): backpack, carried bags 1..N, keyring, bank main, bank bags.
function Items.ContainerRank(cid)
    local class = Store.ContainerClass(cid)
    if class == "backpack" then return 0 end
    if class == "bag"      then return tonumber(cid) or 900 end        -- 1..N
    if class == "keyring"  then return 50 end
    if class == "bank"     then return 100 end
    if class == "bankbag"  then return 100 + (tonumber(cid) or 800) end -- 100+id
    return 999
end

-- Scope maps a container CLASS to inclusion. `scope` is a preset string or a
-- predicate fn(cid)->bool; nil / "all" = everything.
local SCOPE_CLASSES = {
    bags    = { backpack = true, bag = true },
    carried = { backpack = true, bag = true, keyring = true },
    keyring = { keyring = true },
    bank    = { bank = true, bankbag = true },
}

local function cidInScope(cid, scope)
    if type(scope) == "function" then return scope(cid) and true or false end
    if scope == nil or scope == "all" then return true end
    local set = SCOPE_CLASSES[scope]
    if not set then return true end
    return set[Store.ContainerClass(cid)] and true or false
end
Items._cidInScope = cidInScope   -- exposed for self-tests

----------------------------------------------------------------------
-- PURE: entry-list building from a store owner
----------------------------------------------------------------------

-- Per-container grouping (split-bag-groups layout). Returns an array of
--   { cid, class, size, entries = { {owner,cid,slot,data}, ... } }   (empty slots
-- have data = nil), sorted by ContainerRank. `opts.scope` filters containers.
function Items.BuildGroups(owner, opts)
    opts = opts or {}
    local groups = {}
    if owner and owner.containers then
        for cid, c in pairs(owner.containers) do
            if cidInScope(cid, opts.scope) then
                local size = c.size or 0
                local entries = {}
                local slots = c.slots or {}
                for slot = 1, size do
                    entries[slot] = { owner = owner, cid = cid, slot = slot, data = slots[slot] }
                end
                groups[#groups + 1] = {
                    cid = cid, class = Store.ContainerClass(cid), size = size, entries = entries,
                }
            end
        end
    end
    table.sort(groups, function(a, b)
        local ra, rb = Items.ContainerRank(a.cid), Items.ContainerRank(b.cid)
        if ra == rb then return tostring(a.cid) < tostring(b.cid) end
        return ra < rb
    end)
    return groups
end

-- Combined flatten layout: the same entries, one flat array in container order then
-- slot order. The frame agent uses this for the combined view and BuildGroups for split.
function Items.BuildEntries(owner, opts)
    local flat = {}
    for _, g in ipairs(Items.BuildGroups(owner, opts)) do
        for _, e in ipairs(g.entries) do
            flat[#flat + 1] = e
        end
    end
    return flat
end

----------------------------------------------------------------------
-- PURE: grid math (self-size, never zero)
----------------------------------------------------------------------

-- Metrics for laying N cells in `columns` columns of `size` px with `gap` px between.
-- Width uses the number of columns actually populated (min(columns, N)) so a short
-- run hugs its content; height uses the full row count.
function Items.GridMetrics(n, columns, size, gap)
    columns = math.max(1, columns or Items.DEFAULT_COLUMNS)
    size    = size or Items.DEFAULT_SIZE
    gap     = gap or Items.DEFAULT_GAP
    n = math.max(0, n or 0)
    local cols = math.min(columns, math.max(n, 1))
    local rows = (n > 0) and math.ceil(n / columns) or 0
    local width  = cols * size + math.max(0, cols - 1) * gap
    local height = (rows > 0) and (rows * size + (rows - 1) * gap) or 0
    return { cols = cols, rows = rows, width = width, height = height }
end

-- Top-left (x, y) offset of the 1-based cell `index` within the grid. y is negative
-- (WoW anchors grow downward from TOPLEFT).
function Items.SlotPosition(index, columns, size, gap)
    columns = math.max(1, columns or Items.DEFAULT_COLUMNS)
    size    = size or Items.DEFAULT_SIZE
    gap     = gap or Items.DEFAULT_GAP
    local i = (index or 1) - 1
    local col = i % columns
    local row = math.floor(i / columns)
    return col * (size + gap), -(row * (size + gap))
end

----------------------------------------------------------------------
-- PURE: icon / quality / name resolution
----------------------------------------------------------------------

-- Derive what a button needs to render from a store slot `data`, using an injected
-- `resolver = { instant = <GetItemInfoInstant>, info = <GetItemInfo> }`:
--   * icon  — from GetItemInfoInstant, which resolves from static data for ANY valid
--             itemID even when the item is server-uncached (so migrated slots, which
--             cache no icon, still get one immediately).
--   * quality/name — captured quality wins; else GetItemInfo (server-cached). When
--             quality is still unresolvable the slot is `pending` (placeholder now,
--             repaint on GET_ITEM_INFO_RECEIVED).
-- Returns { id, count, icon, quality, name, link, pending } or nil for an empty slot.
function Items.ResolveVisual(data, resolver)
    if not data or not data.id then return nil end
    local v = { id = data.id, count = data.count or 1, link = data.link, quality = data.quality }

    if resolver and resolver.instant then
        local _, _, _, _, icon = resolver.instant(data.id)
        v.icon = icon
    end
    if resolver and resolver.info then
        local name, link, quality = resolver.info(data.id)
        v.name = name
        if v.link == nil then v.link = link end
        if v.quality == nil then v.quality = quality end
    end
    v.name = v.name or data.link
    v.pending = (v.quality == nil)
    return v
end

----------------------------------------------------------------------
-- PURE: dim state + cached-age formatting
----------------------------------------------------------------------

-- Search-dim (W4) reads this: returns alpha, desaturate for a dim flag.
function Items.DimValues(dimmed)
    if dimmed then return 0.25, true end
    return 1.0, false
end

-- Dress alpha for the whole slot dress (icon + quality edge + state markers + count).
-- The dim-cascade fix: search-dim recedes the ENTIRE dress together, not just the icon.
function Items.DressAlpha(dimmed)
    return dimmed and 0.25 or 1.0
end

-- Cell-size floor (720p, C): clamp the button cell so a laptop user can't shrink cells
-- into illegibility (the 1px quality edge and the count numeral fail together below ~30px).
-- Columns is the lever for fitting more, not shrinking cells.
function Items.ClampCell(size)
    size = size or Items.DEFAULT_SIZE
    if size < Items.MIN_CELL then return Items.MIN_CELL end
    return size
end

-- PURE: two-layer STATE resolver (Layer 2). Given a slot's live facts, decide the icon
-- treatment (mutually exclusive) and the corner markers (independent), with precedence:
--   icon:  dimmed  >  unusable  >  junk(quality 0)  >  normal
--   markers: new-item wax dot + quest tab show ONLY when NOT dimmed (dim recedes all)
-- This is the attention-inversion law at slot scale (BRAND_SPEC §5): quality is quiet
-- identity (Layer 1 edge); saturated state is EARNED (new loot / quest / can't-use).
--   ctx = { quality=<n|nil>, dimmed=<bool>, isNew=<bool>, isQuest=<bool>, isUnusable=<bool> }
-- returns { icon, iconDesat, unusableTint, showNewDot, showQuestTab, dressAlpha }.
function Items.ResolveState(ctx)
    ctx = ctx or {}
    local dimmed = ctx.dimmed and true or false
    local icon
    if dimmed then icon = "dimmed"
    elseif ctx.isUnusable then icon = "unusable"
    elseif ctx.quality == 0 then icon = "junk"
    else icon = "normal" end
    return {
        icon         = icon,
        iconDesat    = (icon ~= "normal"),
        unusableTint = (icon == "unusable"),
        showNewDot   = (ctx.isNew and not dimmed) and true or false,
        showQuestTab = (ctx.isQuest and not dimmed) and true or false,
        dressAlpha   = Items.DressAlpha(dimmed),
    }
end

-- "cached 3d ago" tooltip line from an age in seconds (nil for a fresh/unknown age).
function Items.FormatCachedAge(seconds)
    if not seconds or seconds < 0 then return nil end
    if seconds < 60    then return "cached just now" end
    if seconds < 3600  then return string.format("cached %dm ago", math.floor(seconds / 60)) end
    if seconds < 86400 then return string.format("cached %dh ago", math.floor(seconds / 3600)) end
    return string.format("cached %dd ago", math.floor(seconds / 86400))
end

-- =====================================================================
-- FRAME LAYER (in-game only)
-- =====================================================================

-- Self identity (which owner's bags are the live, interactive ones). Set at login
-- via Items.SetSelf; derived lazily from UnitName/GetRealmName if unset.
function Items.SetSelf(nameRealm) Items._self = nameRealm end

function Items.IsLive(owner)
    if not owner or owner.source ~= "full" then return false end
    if not Items._self and _G.UnitName and _G.GetRealmName then
        local realm = ((_G.GetRealmName() or ""):gsub("%s+", ""))
        Items._self = Store.MakeNameRealm(_G.UnitName("player"), realm)
    end
    return owner.nameRealm ~= nil and owner.nameRealm == Items._self
end

-- Injected-live resolver from the game globals (C_Item namespace; catalog-verified).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
    }
end

local function mutedRGB()
    if _G.DaseekiUI and _G.DaseekiUI.Color then return _G.DaseekiUI.Color("muted") end
    return 0.60, 0.56, 0.47
end

-- Token color with a hardcoded fallback (so per-slot dress still tints sensibly if
-- DaseekiUI is somehow absent). Colors are read at button CREATION and baked into the
-- dress (no per-cell ThemeChanged hook — 100+ hooks are the per-frame cost C vetoes;
-- the quality edge, which re-reads the live provider each paint, carries live rarity).
local TOKEN_FALLBACK = {
    inset  = { 0.0706, 0.0627, 0.0471 },
    text   = { 0.9137, 0.8784, 0.8039 },
    brand  = { 0.7529, 0.2824, 0.2353 }, -- crimson wax (Field Ledger)
    warn   = { 0.9600, 0.7600, 0.1800 },
    danger = { 0.8118, 0.3647, 0.2902 },
}
local function tokenRGB(name)
    if _G.DaseekiUI and _G.DaseekiUI.Color then return _G.DaseekiUI.Color(name) end
    local c = TOKEN_FALLBACK[name] or { 1, 1, 1 }
    return c[1], c[2], c[3]
end

-- Subtle danger tint for an UNUSABLE icon: danger mixed toward white so a desaturated
-- (greyscale) icon reads warm-red — the classic "can't use" cue — not a solid red block.
local function unusableTintRGB()
    local dr, dg, db = tokenRGB("danger")
    local m = 0.45
    return dr + (1 - dr) * m, dg + (1 - dg) * m, db + (1 - db) * m
end

local function iconOf(button)
    return button.icon or (button.GetName and _G[(button:GetName() or "") .. "IconTexture"]) or nil
end

----------------------------------------------------------------------
-- Async pending registry (GET_ITEM_INFO_RECEIVED)
----------------------------------------------------------------------

Items._pending = Items._pending or {}   -- [itemID] = weak set of buttons awaiting data

local function ensureEventFrame()
    if Items._evt or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(_, _, itemID)
        local set = Items._pending[itemID]
        if not set then return end
        Items._pending[itemID] = nil
        for btn in pairs(set) do
            if btn._dsRepaint then btn:_dsRepaint() end
        end
    end)
    Items._evt = f
end

local function watchPending(button, itemID)
    Items._pending[itemID] = Items._pending[itemID] or setmetatable({}, { __mode = "k" })
    Items._pending[itemID][button] = true
    ensureEventFrame()
    if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
        _G.C_Item.RequestLoadItemDataByID(itemID)
    end
end

----------------------------------------------------------------------
-- Button paint helpers
----------------------------------------------------------------------

----------------------------------------------------------------------
-- STATE layer (Layer 2): live-fact detection for the per-slot markers.
-- All three read the LIVE container/item APIs and are meaningful only for the logged-in
-- character's own bags (button._live). Offline/remote owners get no state markers (they
-- have no live new/quest/usable state) — junk calm still applies via captured quality.
----------------------------------------------------------------------

-- NEW-ITEM: C_NewItems is the game's own new-item set (1.x drove glowNew from it). The
-- wax dot shows while a slot is new; MarkSeen clears it on interaction (below).
local function slotIsNew(button)
    local CN = _G.C_NewItems
    if not (CN and CN.IsNewItem and button._cid and button._slot) then return false end
    return CN.IsNewItem(button._cid, button._slot) and true or false
end

-- QUEST: container quest info (isQuestItem / active questID) — same source as the old
-- native bang, now surfaced as a warn-token tab instead of the yellow "!" art.
local function slotIsQuest(button)
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemQuestInfo and button._cid and button._slot) then return false end
    local info = CC.GetContainerItemQuestInfo(button._cid, button._slot)
    return (info and (info.isQuestItem or info.questID)) and true or false
end

-- UNUSABLE: C_Item.IsUsableItem(id) -> usable, noMana. "Can't use" (wrong class/level/
-- skill) is usable == false with noMana falsey; a mere lack of mana (noMana) is NOT
-- unusable and must not tint red. Restores 1.x glowUnusable as desaturate + danger tint.
local function slotIsUnusable(button)
    local CI = _G.C_Item
    local id = button._data and button._data.id
    if not (CI and CI.IsUsableItem and id) then return false end
    local usable, noMana = CI.IsUsableItem(id)
    return (usable == false and not noMana) and true or false
end

-- Clear the new-item mark on interaction (1.x MarkSeen fact: RemoveNewItem on seen).
-- Wired as an insecure OnEnter post-hook on live buttons (hover-to-clear) so the secure
-- click path is never touched. RemoveNewItem is not a protected op.
function Items.MarkSeen(button)
    if not button._live then return end
    local CN = _G.C_NewItems
    if CN and CN.RemoveNewItem and button._cid and button._slot then
        CN.RemoveNewItem(button._cid, button._slot)
    end
    if button._dsNewDot then button._dsNewDot:Hide() end
end

-- Apply a resolved STATE spec to a button's dress. Operates ONLY on child textures/
-- frames/fontstrings + the icon sub-texture — never a protected op on the secure button.
-- This is also the DIM CASCADE: `spec.dressAlpha` recedes the icon, quality edge, count
-- numeral AND both markers together, so a search-dimmed slot fully recedes (no bright
-- quality rim or crimson dot floating over a non-match).
function Items._applyDress(button, spec)
    local a = spec.dressAlpha

    -- icon: alpha + desaturation + (unusable) subtle danger tint
    local icon = iconOf(button)
    if icon then
        if icon.SetAlpha then icon:SetAlpha(a) end
        if icon.SetDesaturated then icon:SetDesaturated(spec.iconDesat) end
        if icon.SetVertexColor then
            if spec.unusableTint then icon:SetVertexColor(unusableTintRGB())
            else icon:SetVertexColor(1, 1, 1) end
        end
    end
    if _G.SetItemButtonDesaturated then _G.SetItemButtonDesaturated(button, spec.iconDesat) end

    -- quality edge (Layer 1) recedes with the dim
    if ns.Borders and ns.Borders.SetAlpha then ns.Borders.SetAlpha(button, a) end

    -- count numeral recedes with the dim
    if button._dsCount and button._dsCount.SetAlpha then button._dsCount:SetAlpha(a) end

    -- keep the template's native quest bang suppressed (our warn tab replaces it)
    if button._dsNativeQuest then button._dsNativeQuest:Hide() end

    -- NEW-ITEM wax dot: one-shot 120ms fade-in on the rising edge (arrival), then still.
    -- No OnUpdate/loop; shown frames only. Hidden entirely while dimmed.
    local dot = button._dsNewDot
    if dot then
        if spec.showNewDot then
            if not (dot.IsShown and dot:IsShown()) then
                local UI = _G.DaseekiUI
                if UI and UI.Animate and UI.Animate.FadeIn then UI.Animate.FadeIn(dot, 120)
                else dot:SetAlpha(1); dot:Show() end
            else
                dot:SetAlpha(a)
            end
        else
            dot:Hide()
        end
    end

    -- QUEST warn tab
    local tab = button._dsQuestTab
    if tab then
        if spec.showQuestTab then tab:SetAlpha(a); tab:Show() else tab:Hide() end
    end
end

-- Detect the live facts, resolve the state spec, and apply it. Also the SetDimmed target.
local function applyDressState(button)
    local live = button._live and true or false
    local hasItem = button._data and button._data.id ~= nil
    local isNew, isQuest, isUnusable = false, false, false
    if hasItem and live then
        isNew      = slotIsNew(button)
        isQuest    = slotIsQuest(button)
        isUnusable = slotIsUnusable(button)
    end
    local spec = Items.ResolveState({
        quality    = button._quality,
        dimmed     = button._dimmed,
        isNew      = isNew,
        isQuest    = isQuest,
        isUnusable = isUnusable,
    })
    Items._applyDress(button, spec)
end

local function updateCooldown(button)
    local cd = button.Cooldown or button.cooldown
        or (button.GetName and _G[(button:GetName() or "") .. "Cooldown"])
    if not cd then return end
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemCooldown) then return end
    local start, duration, enable = CC.GetContainerItemCooldown(button._cid, button._slot)
    if _G.CooldownFrame_Set then
        _G.CooldownFrame_Set(cd, start or 0, duration or 0, enable or 0)
    elseif cd.SetCooldown then
        if (enable or 0) ~= 0 and (duration or 0) > 0 then cd:SetCooldown(start, duration)
        elseif cd.Clear then cd:Clear() end
    end
end

-- Style the stack-count numeral once, at creation: ARIALN + OUTLINE (UI.fonts.numeral),
-- cream `text` token (NOT bright white — a Bagnon tell that glares on the dark well),
-- bottom-right, −2px so the outline doesn't fatten the cell edge. SetItemButtonCount
-- sets only the TEXT, so font/color/anchor persist across repaints from this one call.
local function styleCount(button)
    local count = button.Count
        or (button.GetName and _G[(button:GetName() or "") .. "Count"])
    if not count then return end
    button._dsCount = count
    local UI = _G.DaseekiUI
    if UI and UI.fonts and UI.fonts.numeral then count:SetFontObject(UI.fonts.numeral) end
    count:SetTextColor(tokenRGB("text"))
    if count.ClearAllPoints then
        count:ClearAllPoints()
        count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    end
end

-- Build the per-slot dress ONCE, at button creation (out of combat, gated by the
-- combat-deferred layout): quiet inset well + new-item wax dot + quest warn tab. All are
-- non-secure children; nothing here (or at runtime) is a protected op on the button.
local function ensureDress(button)
    if button._dsWell or not _G.CreateFrame then return end

    -- Quiet inset WELL (BACKGROUND): a calm recessed substrate under every cell so empties
    -- read as intentional drop targets and fills sit in a dark well. No per-slot edge
    -- (C floor: 100+ snapped edges shimmer for little gain — the gap already IS the grid).
    local well = button:CreateTexture(nil, "BACKGROUND")
    well:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    well:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    well:SetColorTexture(tokenRGB("inset"))
    button._dsWell = well

    local sz = button:GetWidth() or Items.DEFAULT_SIZE

    -- NEW-ITEM wax dot (brand crimson), top-right corner. A Frame (so UI.Animate.FadeIn can
    -- play a one-shot 120ms reveal on arrival) holding a filled texture.
    local dot = _G.CreateFrame("Frame", nil, button)
    local dsz = math.max(5, math.floor(sz * 0.24))
    dot:SetSize(dsz, dsz)
    dot:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
    if dot.SetFrameLevel then dot:SetFrameLevel((button:GetFrameLevel() or 1) + 2) end
    local dt = dot:CreateTexture(nil, "OVERLAY")
    dt:SetAllPoints(dot)
    dt:SetColorTexture(tokenRGB("brand"))
    dot:Hide()
    button._dsNewDot = dot

    -- QUEST warn tab (warn token), top-left corner — WoW's "!" convention without the
    -- yellow bang art.
    local tab = button:CreateTexture(nil, "OVERLAY")
    local tsz = math.max(5, math.floor(sz * 0.26))
    tab:SetSize(tsz, tsz)
    tab:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    tab:SetColorTexture(tokenRGB("warn"))
    tab:Hide()
    button._dsQuestTab = tab

    -- Suppress the template's native yellow quest bang; our warn tab replaces it.
    local qt = button.IconQuestTexture
        or (button.GetName and _G[(button:GetName() or "") .. "IconQuestTexture"])
    if qt then qt:Hide(); button._dsNativeQuest = qt end

    styleCount(button)
end
Items._ensureDress = ensureDress

local function paintButton(button)
    local data = button._data
    if not data or not data.id then
        if _G.SetItemButtonTexture then _G.SetItemButtonTexture(button, nil) end
        if _G.SetItemButtonCount then _G.SetItemButtonCount(button, 0) end
        local icon = iconOf(button); if icon then icon:SetTexture(nil) end
        if ns.Borders then ns.Borders.Apply(button, nil) end
        if button._live then updateCooldown(button) end
        button._pendingId = nil
        button._quality = nil
        applyDressState(button)   -- resets icon, hides markers, cascades alpha; well stays
        return
    end

    local visual = Items.ResolveVisual(data, liveResolver())
    local icon = (visual and visual.icon) or Items.PLACEHOLDER_ICON
    if _G.SetItemButtonTexture then _G.SetItemButtonTexture(button, icon)
    else local t = iconOf(button); if t then t:SetTexture(icon) end end
    if _G.SetItemButtonCount then _G.SetItemButtonCount(button, (visual and visual.count) or 1) end

    if ns.Borders then ns.Borders.Apply(button, visual and visual.quality) end
    button._quality = visual and visual.quality

    if button._live then
        updateCooldown(button)
    end

    if visual and visual.pending then
        button._pendingId = data.id
        watchPending(button, data.id)
    else
        button._pendingId = nil
    end
    applyDressState(button)
end

local function showCachedTooltip(button)
    local GT = _G.GameTooltip
    if not GT then return end
    local data = button._data
    if not data then return end
    GT:SetOwner(button, "ANCHOR_RIGHT")
    local link = data.link
    if link and GT.SetHyperlink then GT:SetHyperlink(link)
    elseif data.id and GT.SetHyperlink then GT:SetHyperlink("item:" .. data.id) end
    local owner = button._owner
    local age = owner and button._cid and Store.ContainerAge(owner, button._cid)
    local ageStr = age and Items.FormatCachedAge(age)
    if ageStr and GT.AddLine then GT:AddLine(ageStr, mutedRGB()) end
    if GT.Show then GT:Show() end
end

----------------------------------------------------------------------
-- Button factory + methods
----------------------------------------------------------------------

local _btnSeq = 0
local function nextButtonName()
    _btnSeq = _btnSeq + 1
    return "DaseekiBags2Item" .. _btnSeq
end

-- Create an item button. opts.live selects the secure container template (interactive)
-- vs the plain render-only ItemButtonTemplate. opts.size sets the cell size.
function Items.CreateButton(parent, opts)
    opts = opts or {}
    if not _G.CreateFrame then return nil end
    local live = opts.live and true or false
    local template = live and "ContainerFrameItemButtonTemplate" or "ItemButtonTemplate"
    local button = _G.CreateFrame("Button", nextButtonName(), parent, template)
    button._live = live
    local cell = Items.ClampCell(opts.size)
    button:SetSize(cell, cell)
    button._dsRepaint = function(self) paintButton(self) end

    if not live then
        -- Render-only: hyperlink tooltip + inert click (shift-link only), no drag.
        if button.RegisterForDrag then button:RegisterForDrag() end
        button:SetScript("OnEnter", function(self) showCachedTooltip(self) end)
        button:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        button:SetScript("OnClick", function(self)
            if _G.HandleModifiedItemClick and self._data and self._data.link then
                _G.HandleModifiedItemClick(self._data.link)
            end
        end)
    else
        -- LIVE keeps the template's own OnClick/OnDragStart/OnReceiveDrag/OnEnter handlers
        -- (secure, combat-correct pickup/place/split/use + real-slot tooltip) untouched.
        -- An INSECURE OnEnter post-hook clears the new-item mark on hover (1.x MarkSeen
        -- fact) — a non-secure hook that never touches the secure click path.
        if button.HookScript then
            button:HookScript("OnEnter", function(self) Items.MarkSeen(self) end)
        end
    end

    if ns.Borders then ns.Borders.Attach(button) end
    ensureDress(button)

    button.SetSlot   = function(self, o, c, s, d) Items._setSlot(self, o, c, s, d) end
    button.SetEmpty  = function(self, o, c, s)    Items._setSlot(self, o, c, s, nil) end
    button.SetDimmed = function(self, on) self._dimmed = on and true or false; applyDressState(self) end
    button.Clear     = function(self)
        self._owner, self._cid, self._slot, self._data, self._pendingId, self._quality = nil, nil, nil, nil, nil, nil
        if _G.SetItemButtonTexture then _G.SetItemButtonTexture(self, nil) end
        if _G.SetItemButtonCount then _G.SetItemButtonCount(self, 0) end
        if ns.Borders then ns.Borders.Apply(self, nil) end
        if self._dsNewDot then self._dsNewDot:Hide() end
        if self._dsQuestTab then self._dsQuestTab:Hide() end
        self:Hide()
    end
    return button
end

function Items._setSlot(button, owner, cid, slot, data)
    button._owner, button._cid, button._slot, button._data = owner, cid, slot, data
    if button._live and button.SetID then button:SetID(slot) end  -- template reads slot from GetID()
    paintButton(button)
    button:Show()
end

----------------------------------------------------------------------
-- Per-container holder (carries SetID(cid) for the live template's bag lookup)
----------------------------------------------------------------------

local function holderFor(G, cid)
    local h = G._holders[cid]
    if not h then
        h = _G.CreateFrame("Frame", nil, G)
        h:SetID(cid)          -- ContainerFrameItemButtonTemplate reads parent:GetID() as bagID
        h:SetAllPoints(G)
        G._holders[cid] = h
    end
    return h
end

----------------------------------------------------------------------
-- Group factory
----------------------------------------------------------------------

local function combatFlush(G)
    if G._combatFrame or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        if G._pendingEntries then
            local e = G._pendingEntries
            G._pendingEntries = nil
            G:ShowSlots(e)
        end
    end)
    G._combatFrame = f
end

local function layoutGroup(G, entries)
    entries = entries or {}
    local n = #entries

    -- Secure item buttons are protected frames — never create/reparent them in combat.
    -- Defer the whole relayout to PLAYER_REGEN_ENABLED (repaint of existing buttons is
    -- safe, but a structural rebuild is not, so we defer wholesale for simplicity).
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        for _, e in ipairs(entries) do
            if Items.IsLive(e.owner) then
                G._pendingEntries = entries
                combatFlush(G)
                return
            end
        end
    end

    local cols, size, gap = G._columns, G._size, G._gap
    for i = 1, n do
        local e = entries[i]
        local live = Items.IsLive(e.owner)
        local button = G._buttons[i]
        if (not button) or (button._live ~= live) then
            if button then button:Hide(); if button.SetParent then button:SetParent(nil) end end
            local parent = live and holderFor(G, e.cid) or G
            button = Items.CreateButton(parent, { live = live, size = size })
            G._buttons[i] = button
        elseif live then
            button:SetParent(holderFor(G, e.cid))   -- keep the bag holder current
        end
        local x, y = Items.SlotPosition(i, cols, size, gap)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", G, "TOPLEFT", x, y)
        button:SetSize(size, size)
        button._dimmed = false
        if e.data then button:SetSlot(e.owner, e.cid, e.slot, e.data)
        else button:SetEmpty(e.owner, e.cid, e.slot) end
    end
    for i = n + 1, #G._buttons do G._buttons[i]:Hide() end

    local m = Items.GridMetrics(n, cols, size, gap)
    G:SetSize(math.max(m.width, size), math.max(m.height, size))  -- never zero-size
end

-- Split-view bag header text: the bag item's real name when a link resolves, else a
-- class label. `group` is the descriptor { cid, class, size, link }.
local function headerText(group)
    local class = group.class
    if not class and group.cid ~= nil then class = Store.ContainerClass(group.cid) end
    local label = CLASS_LABEL[class or "unknown"] or "Items"
    if group.link and _G.C_Item and _G.C_Item.GetItemInfo then
        local name = _G.C_Item.GetItemInfo(group.link)
        if name then label = name end
    end
    return label
end

-- Create a grid group. G:SetGrid(columns, buttonSize, gap); G:ShowSlots(entries);
-- G:Clear(); G:SetHeader(group) (split mode). The group self-sizes from grid math on
-- every ShowSlots.
function Items.CreateGroup(parent)
    if not _G.CreateFrame then return nil end
    local G = _G.CreateFrame("Frame", nil, parent)
    G._columns = Items.DEFAULT_COLUMNS
    G._size    = Items.DEFAULT_SIZE
    G._gap     = Items.DEFAULT_GAP
    G._buttons = {}
    G._holders = {}

    function G:SetGrid(columns, buttonSize, gap)
        if columns then self._columns = math.max(1, columns) end
        if buttonSize then self._size = Items.ClampCell(buttonSize) end  -- 720p cell floor (C)
        if gap ~= nil then self._gap = gap end
        -- Re-flow the current contents so a grid change is immediately visible.
        if self._lastEntries then layoutGroup(self, self._lastEntries) end
    end

    function G:ShowSlots(entries)
        self._lastEntries = entries
        layoutGroup(self, entries)
    end

    -- Split mode: label this group with its bag's header (icon + name), sitting in a
    -- band ABOVE the grid so it never displaces a cell (keeps the shared grid math,
    -- 37/4/12, exact). Pass nil to hide. Frame no-ops gracefully if never called.
    function G:SetHeader(group)
        if not group then
            if self._header then self._header:Hide() end
            return
        end
        local h = self._header
        if not h then
            h = _G.CreateFrame("Frame", nil, self)
            h:SetHeight(Items.HEADER_HEIGHT)
            h:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 2)
            h:SetPoint("BOTTOMRIGHT", self, "TOPRIGHT", 0, 2)
            h._icon = h:CreateTexture(nil, "ARTWORK")
            h._icon:SetSize(14, 14)
            h._icon:SetPoint("LEFT", h, "LEFT", 0, 0)
            h._label = h:CreateFontString(nil, "OVERLAY")
            if _G.DaseekiUI and _G.DaseekiUI.fonts and _G.DaseekiUI.fonts.small then
                h._label:SetFontObject(_G.DaseekiUI.fonts.small)
            else
                h._label:SetFontObject("GameFontNormalSmall")
            end
            self._header = h
        end
        local icon
        if group.link and _G.C_Item and _G.C_Item.GetItemInfoInstant then
            local _, _, _, _, i = _G.C_Item.GetItemInfoInstant(group.link)
            icon = i
        end
        h._label:ClearAllPoints()
        if icon then
            h._icon:SetTexture(icon); h._icon:Show()
            h._label:SetPoint("LEFT", h._icon, "RIGHT", 4, 0)
        else
            h._icon:Hide()
            h._label:SetPoint("LEFT", h, "LEFT", 0, 0)
        end
        h._label:SetText(headerText(group))
        if _G.DaseekiUI and _G.DaseekiUI.Color then h._label:SetTextColor(_G.DaseekiUI.Color("muted")) end
        h:Show()
    end

    function G:Clear()
        self._lastEntries = nil
        if self._header then self._header:Hide() end
        for _, b in ipairs(self._buttons) do b:Clear() end
    end

    local m = Items.GridMetrics(0, G._columns, G._size, G._gap)
    G:SetSize(math.max(m.width, G._size), math.max(m.height, G._size))
    return G
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_items")
----------------------------------------------------------------------

local function newOwnerWith(containers)
    _G.DaseekiBags2Data = nil; Store.Init()
    local o = Store.EnsureOwner("Tester-TestRealm")
    o.source = "full"
    for cid, spec in pairs(containers) do
        local c = Store.NewContainer(spec.size, spec.link)
        for slot, s in pairs(spec.slots or {}) do
            c.slots[slot] = Store.NewSlot(s.id, s.count, s.quality, s.link)
        end
        Store.PutContainer(o, cid, c, spec.ts or 1)
    end
    return o
end

local function testGridMath(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local m0 = Items.GridMetrics(0, 12, 37, 4)
    ck(m0.rows == 0 and m0.height == 0, "N=0 -> zero rows/height (group floors size itself)")
    local m1 = Items.GridMetrics(1, 12, 37, 4)
    ck(m1.cols == 1 and m1.rows == 1 and m1.width == 37 and m1.height == 37, "N=1 single cell")
    local m5 = Items.GridMetrics(5, 12, 37, 4)
    ck(m5.cols == 5 and m5.rows == 1, "N=5 hugs 5 columns, 1 row")
    ck(m5.width == 5 * 37 + 4 * 4, "N=5 width = 5 cells + 4 gaps")
    local m12 = Items.GridMetrics(12, 12, 37, 4)
    ck(m12.cols == 12 and m12.rows == 1, "N=12 fills the row")
    local m13 = Items.GridMetrics(13, 12, 37, 4)
    ck(m13.cols == 12 and m13.rows == 2, "N=13 wraps to 2 rows")
    ck(m13.height == 2 * 37 + 1 * 4, "N=13 height = 2 cells + 1 gap")
    -- positions
    local x1, y1 = Items.SlotPosition(1, 12, 37, 4)
    ck(x1 == 0 and y1 == 0, "cell 1 at origin")
    local x13, y13 = Items.SlotPosition(13, 12, 37, 4)
    ck(x13 == 0 and y13 == -(37 + 4), "cell 13 at row 2 col 1")
    local x12, y12 = Items.SlotPosition(12, 12, 37, 4)
    ck(x12 == 11 * (37 + 4) and y12 == 0, "cell 12 at row 1 col 12")
end

local function testEntryBuilding(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = newOwnerWith({
        [0]  = { size = 16, slots = { [1] = { id = 6948, count = 1 }, [5] = { id = 22157, count = 20, quality = 3 } } },
        [1]  = { size = 6,  link = "item:14046", slots = { [2] = { id = 4234, count = 4 } } },
        [-1] = { size = 24, slots = { [1] = { id = 4306, count = 20 } } },      -- bank main
        [5]  = { size = 16, slots = { [1] = { id = 4338, count = 8 } } },       -- bank bag
        [-2] = { size = 12, slots = { [1] = { id = 5175, count = 1 } } },       -- keyring
    })

    -- split grouping, "bags" scope: backpack + bag 1 only, in rank order.
    local gBags = Items.BuildGroups(o, { scope = "bags" })
    ck(#gBags == 2, "bags scope -> 2 groups (backpack + bag)")
    ck(gBags[1].cid == 0 and gBags[2].cid == 1, "groups sorted backpack(0) then bag(1)")
    ck(#gBags[1].entries == 16 and #gBags[2].entries == 6, "entries fill full container size incl. empties")
    ck(gBags[1].entries[1].data ~= nil and gBags[1].entries[1].data.id == 6948, "slot 1 populated")
    ck(gBags[1].entries[2].data == nil, "slot 2 empty -> nil data")
    ck(gBags[1].entries[5].data.quality == 3, "captured quality preserved on entry")

    -- combined flatten, "bags" scope: 16 + 6 = 22 entries, backpack first.
    local flat = Items.BuildEntries(o, { scope = "bags" })
    ck(#flat == 22, "combined flatten length = 16 + 6")
    ck(flat[1].cid == 0 and flat[17].cid == 1, "flatten runs backpack (1..16) then bag (17..)")

    -- "all" scope orders bank AFTER carried: backpack(0), bag(1), keyring(-2), bank(-1), bankbag(5).
    local gAll = Items.BuildGroups(o, { scope = "all" })
    local order = {}
    for i, g in ipairs(gAll) do order[i] = g.cid end
    ck(order[1] == 0 and order[2] == 1 and order[3] == -2 and order[4] == -1 and order[5] == 5,
        "all-scope rank order: backpack, bag, keyring, bank, bankbag")

    -- scope predicates
    ck(Items._cidInScope(0, "bags") == true and Items._cidInScope(-1, "bags") == false, "bags excludes bank")
    ck(Items._cidInScope(-1, "bank") == true and Items._cidInScope(0, "bank") == false, "bank scope is bank-only")
    ck(Items._cidInScope(-2, "carried") == true, "carried includes keyring")
end

local function testQualityDerivation(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Captured quality present -> resolved immediately, no pending, no info() needed.
    local vCaptured = Items.ResolveVisual({ id = 22157, count = 2, quality = 3 },
        { instant = function() return 22157, "Armor", "Cloth", "", 1338 end })
    ck(vCaptured.icon == 1338, "icon derived from instant path")
    ck(vCaptured.quality == 3 and vCaptured.pending == false, "captured quality -> not pending")

    -- Migrated slot: quality = nil, info() also returns nil quality (server-uncached).
    local uncached = { info = function() return nil, nil, nil end,
                       instant = function() return 4306, "Consumable", "Food", "", 5555 end }
    local vPending = Items.ResolveVisual({ id = 4306, count = 20 }, uncached)
    ck(vPending.icon == 5555, "uncached still gets an icon from instant")
    ck(vPending.quality == nil and vPending.pending == true, "nil quality -> pending")

    -- After the server responds, info() now returns the quality -> resolved.
    local resolved = { info = function() return "Roasted Boar", "item:4306", 1 end,
                       instant = function() return 4306, "Consumable", "Food", "", 5555 end }
    local vDone = Items.ResolveVisual({ id = 4306, count = 20 }, resolved)
    ck(vDone.quality == 1 and vDone.pending == false, "resolved quality -> not pending")
    ck(vDone.name == "Roasted Boar", "name resolved from info")

    ck(Items.ResolveVisual(nil) == nil, "nil data -> nil visual")
    ck(Items.ResolveVisual({ count = 1 }) == nil, "data without id -> nil visual")
end

local function testDimAndAge(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local a1, d1 = Items.DimValues(true)
    ck(a1 == 0.25 and d1 == true, "dimmed -> 0.25 alpha + desaturate")
    local a0, d0 = Items.DimValues(false)
    ck(a0 == 1.0 and d0 == false, "undimmed -> full alpha, no desaturate")

    ck(Items.FormatCachedAge(nil) == nil, "nil age -> nil")
    ck(Items.FormatCachedAge(30) == "cached just now", "<1m -> just now")
    ck(Items.FormatCachedAge(300) == "cached 5m ago", "5 minutes")
    ck(Items.FormatCachedAge(7200) == "cached 2h ago", "2 hours")
    ck(Items.FormatCachedAge(259200) == "cached 3d ago", "3 days")
end

-- Cell clamp (720p floor): the button cell never drops below MIN_CELL.
local function testCellClamp(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Items.ClampCell(37) == 37, "37 unchanged (above floor)")
    ck(Items.ClampCell(30) == 30, "30 == floor, unchanged")
    ck(Items.ClampCell(24) == Items.MIN_CELL, "24 clamped up to floor 30")
    ck(Items.ClampCell(nil) == Items.DEFAULT_SIZE, "nil -> default cell (above floor)")
    ck(Items.MIN_CELL == 30, "floor is 30 (C)")
end

-- STATE-marker precedence matrix (Layer 2). Verifies the icon precedence
--   dimmed > unusable > junk > normal
-- and that markers show only when NOT dimmed.
local function testStatePrecedence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- normal rare item: no treatment, no markers
    local s = Items.ResolveState({ quality = 3 })
    ck(s.icon == "normal" and s.iconDesat == false and s.unusableTint == false, "normal rare -> clean icon")
    ck(s.showNewDot == false and s.showQuestTab == false, "normal -> no markers")
    ck(s.dressAlpha == 1.0, "normal -> full dress alpha")

    -- junk (quality 0): slight desat, NO tint, calm
    local j = Items.ResolveState({ quality = 0 })
    ck(j.icon == "junk" and j.iconDesat == true and j.unusableTint == false, "junk -> desat, no tint")

    -- unusable OUTRANKS junk: an unusable poor item reads as unusable (tint), not junk
    local u = Items.ResolveState({ quality = 0, isUnusable = true })
    ck(u.icon == "unusable" and u.unusableTint == true, "unusable outranks junk")

    -- unusable OUTRANKS normal quality too
    local u2 = Items.ResolveState({ quality = 4, isUnusable = true })
    ck(u2.icon == "unusable" and u2.iconDesat == true and u2.unusableTint == true, "unusable epic -> desat + tint")

    -- markers are independent of icon treatment (a new, quest, unusable item shows both)
    local m = Items.ResolveState({ quality = 3, isNew = true, isQuest = true, isUnusable = true })
    ck(m.showNewDot == true and m.showQuestTab == true, "new+quest markers show alongside unusable")

    -- DIMMED outranks everything: icon=dimmed, markers suppressed, alpha 0.25
    local d = Items.ResolveState({ quality = 0, isNew = true, isQuest = true, isUnusable = true, dimmed = true })
    ck(d.icon == "dimmed" and d.iconDesat == true, "dimmed outranks unusable/junk")
    ck(d.showNewDot == false and d.showQuestTab == false, "dimmed suppresses all markers")
    ck(d.dressAlpha == 0.25, "dimmed -> 0.25 dress alpha")

    -- new-only and quest-only
    local n = Items.ResolveState({ quality = 2, isNew = true })
    ck(n.showNewDot == true and n.showQuestTab == false and n.icon == "normal", "new-only marker")
    local q = Items.ResolveState({ quality = 2, isQuest = true })
    ck(q.showQuestTab == true and q.showNewDot == false, "quest-only marker")
end

-- DIM CASCADE covering ALL dress layers: a dimmed slot recedes icon + quality edge +
-- count numeral + new dot + quest tab together (the C condition-4 bug fix). Uses a fake
-- button (no CreateFrame needed) so the wiring itself is asserted headless.
local function testDimCascade(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function recorder()
        local r = { alpha = nil, shown = true, desat = nil }
        function r:SetAlpha(a) self.alpha = a end
        function r:SetDesaturated(d) self.desat = d end
        function r:SetVertexColor() end
        function r:IsShown() return self.shown end
        function r:Show() self.shown = true end
        function r:Hide() self.shown = false end
        return r
    end

    -- a fake button carrying every dress layer
    local icon   = recorder()
    local border = recorder()
    local count  = recorder()
    local dot    = recorder(); dot.shown = true   -- currently shown (new)
    local tab    = recorder(); tab.shown = true
    local btn = {
        icon = icon, _dsBagsBorder = border, _dsCount = count,
        _dsNewDot = dot, _dsQuestTab = tab,
    }

    -- DIMMED spec: everything must land at 0.25 and markers hide
    Items._applyDress(btn, Items.ResolveState({ quality = 4, isNew = true, isQuest = true, dimmed = true }))
    ck(icon.alpha == 0.25,   "cascade: icon dimmed to 0.25")
    ck(border.alpha == 0.25, "cascade: quality edge dimmed to 0.25")
    ck(count.alpha == 0.25,  "cascade: count numeral dimmed to 0.25")
    ck(icon.desat == true,   "cascade: icon desaturated while dimmed")
    ck(dot.shown == false,   "cascade: new dot hidden while dimmed")
    ck(tab.shown == false,   "cascade: quest tab hidden while dimmed")

    -- UNDIMMED normal: dress alpha restored to 1.0, no desat
    local icon2, border2, count2 = recorder(), recorder(), recorder()
    local btn2 = { icon = icon2, _dsBagsBorder = border2, _dsCount = count2 }
    Items._applyDress(btn2, Items.ResolveState({ quality = 3 }))
    ck(icon2.alpha == 1.0 and border2.alpha == 1.0 and count2.alpha == 1.0, "undimmed -> full alpha across dress")
    ck(icon2.desat == false, "undimmed normal -> icon not desaturated")

    -- ns.Borders.SetAlpha path also cascades to the border container field
    local b3 = { _dsBagsBorder = recorder() }
    ns.Borders.SetAlpha(b3, 0.25)
    ck(b3._dsBagsBorder.alpha == 0.25, "Borders.SetAlpha recedes the quality edge container")
end

function Items.RunSelfTests(verbose)
    local suites = {
        { name = "grid math",          fn = testGridMath },
        { name = "entry building",     fn = testEntryBuilding },
        { name = "quality derivation", fn = testQualityDerivation },
        { name = "dim + cached age",   fn = testDimAndAge },
        { name = "cell clamp",         fn = testCellClamp },
        { name = "state precedence",   fn = testStatePrecedence },
        { name = "dim cascade",        fn = testDimCascade },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_items/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_items/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_items", Items.RunSelfTests)
end

return Items
