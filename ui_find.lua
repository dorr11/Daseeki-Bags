-- Daseeki Bags 2.0 — ui_find.lua  (W3)
-- The CROSS-CHARACTER FIND WINDOW (parity audit §3.2, GAP #3 full): search every
-- cached owner's stored items at once, grouped by owner, and jump straight to a
-- holder's view with the search applied. This is the signature Daseeki feature the
-- Bagnon-clones lack — "which of my alts has a Songflower?" in one query.
--
-- Reuses search.lua's compiled matcher UNCHANGED (Search.Compile(text):Match(slot,
-- resolver)) so the Find grammar is identical to the in-bag search (name substring +
-- q:/t:/slot: prefixes, AND-ed). The heavy lifting is PURE and headless-tested:
--   Find.Search(owners, query, resolver) -> per-owner grouped results (bank/bags split)
--   Find.BuildItemRows(results, resolver) -> ONE aggregate row per distinct item
--   Find.WindowHeight(rowCount)          -> size-to-content, clamped, then scroll
-- The FRAME layer is a small Ledger window (its own maker's mark) with a search box
-- and a scrolling result list.
--
-- ── DISPLAY ROUND (owner-directed) ────────────────────────────────────────────
-- ITEM 2 — AGGREGATE ROWS. The window used to render one row per (item, owner,
--   location), so ten alts holding a Chronoboon produced ten near-identical rows. It
--   now renders ONE row per distinct ITEM: icon + quality-colored name + the TOTAL
--   across every owner and location. The per-character breakdown did not disappear —
--   it moved to where it belongs, the item tooltip (features.lua's 1.x anatomy), which
--   the row anchors on hover.
-- ITEM 3 — BOUNDARIES. Rows used to be laid straight into a plain frame that clipped
--   nothing, so a long result list drew straight through the window's bottom border.
--   The list is now a ScrollFrame (which clips its scroll child by construction), the
--   window SIZES TO CONTENT up to MAX_ROWS and scrolls past that, and the name column
--   owns everything between the icon and the right-aligned count.
-- ITEM 4 — SUMMARY OWNERS ARE SEARCHED. Find.Search used to visit owner.containers
--   only, so a cross-account SUMMARY owner (mesh / Nexus bridge) contributed nothing
--   BY CONSTRUCTION: the owner searched an item, Find said 1 copy, the tooltip said 2.
--   A summary owner carries an aggregate map (itemCounts: id -> count) with no slots,
--   so its ids are now run through the SAME compiled matcher against a synthetic
--   record { id = <id>, count = <n> } — the matcher only ever reads record.id and
--   resolves name/type/quality from the resolver, so the grammar is identical. A
--   summary hit has no slot location: it contributes to the TOTAL only, and the
--   tooltip's Other Accounts section names who holds it.
--
-- Secure audit: zero protected ops — reads store records, sets view state + the
-- inventory search box (both insecure), Show/Hides its own unprotected window.

local ADDON, ns = ...

local Find = {}
ns.Find = Find

local Store = ns.Store

----------------------------------------------------------------------
-- PURE: search across every owner
--
-- owners  = Store.data.owners shape ([key] = ownerRecord)
-- query   = a compiled query (Search.Compile(text)); Find no-ops on an empty query.
-- resolver= { instant=, info= } (Search's live resolver, or a fake in tests)
-- opts    = { selfKey = <key to sort first> }
-- Returns an array (sorted self-first, then total desc, then name) of:
--   { key, name, class, source, bagsCount, bankCount, summaryCount, total, isSelf,
--     matches      = { { cid, slot, data }, ... },        -- per-slot hits (full owners)
--     summaryHits  = { { id, count }, ... } }             -- aggregate hits (summary owners)
-- Only owners with >=1 match are included.
--
-- ITEM 4 (cross-account): a SUMMARY owner has no containers, only owner.itemCounts —
-- the exact shape features.CountItemInOwner falls back to for its tooltip numbers. Its
-- ids are matched with the same compiled query against a synthetic record, so the two
-- surfaces can no longer disagree about who holds what. The containers branch and the
-- itemCounts branch are MUTUALLY EXCLUSIVE (a full owner also mirrors an aggregate
-- itemCounts map; counting both would double every number).
----------------------------------------------------------------------

function Find.Search(owners, query, resolver, opts)
    opts = opts or {}
    local results = {}
    if type(owners) ~= "table" or not query or query.isEmpty then return results end

    for key, owner in pairs(owners) do
        local containers = owner.containers
        local hasSlots = (type(containers) == "table") and next(containers) ~= nil
        local bags, bank, summary = 0, 0, 0
        local matches, summaryHits = {}, {}

        if hasSlots then
            for cid, c in pairs(containers) do
                local isBank = Store.IsBankContainer(cid)
                local slots = c and c.slots
                if type(slots) == "table" then
                    for slot, rec in pairs(slots) do
                        if rec and rec.id then
                            local matched = query:Match(rec, resolver)
                            if matched then
                                local n = rec.count or 1
                                if isBank then bank = bank + n else bags = bags + n end
                                matches[#matches + 1] = { cid = cid, slot = slot, data = rec }
                            end
                        end
                    end
                end
            end
        elseif type(owner.itemCounts) == "table" then
            -- Aggregate-only owner: no slot, no location — a contribution to the total.
            for id, n in pairs(owner.itemCounts) do
                id, n = tonumber(id), tonumber(n)
                if id and n and n > 0 then
                    local rec = { id = id, count = n }
                    if query:Match(rec, resolver) then
                        summary = summary + n
                        summaryHits[#summaryHits + 1] = { id = id, count = n }
                    end
                end
            end
            -- Deterministic order (pairs over itemCounts is arbitrary).
            table.sort(summaryHits, function(a, b) return a.id < b.id end)
        end

        if #matches > 0 or #summaryHits > 0 then
            results[#results + 1] = {
                key = key, name = owner.name or key, class = owner.class,
                source = owner.source or "summary",
                bagsCount = bags, bankCount = bank, summaryCount = summary,
                total = bags + bank + summary,
                isSelf = (opts.selfKey ~= nil and key == opts.selfKey),
                matches = matches, summaryHits = summaryHits,
            }
        end
    end

    table.sort(results, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        if a.total ~= b.total then return a.total > b.total end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return results
end

-- Plain-copy result line: "Poonyx — Bank: 12 · Bags: 40" (only non-zero parts shown).
-- (Retained for callers/tests; the window renders per-ITEM aggregate rows instead.)
function Find.FormatOwnerResult(result)
    local parts = {}
    if (result.bankCount or 0) > 0 then parts[#parts + 1] = "Bank: " .. result.bankCount end
    if (result.bagsCount or 0) > 0 then parts[#parts + 1] = "Bags: " .. result.bagsCount end
    if (result.summaryCount or 0) > 0 then parts[#parts + 1] = "Elsewhere: " .. result.summaryCount end
    if #parts == 0 then parts[1] = "0" end
    return result.name .. " — " .. table.concat(parts, " \194\183 ")   -- \194\183 = middot
end

----------------------------------------------------------------------
-- PURE: the AGGREGATE ROW model (display round, ITEM 2).
--
-- ONE row per distinct ITEM, carrying the TOTAL across every owner and every location:
--   [icon] <qualityColor>Chronoboon Displacer</>                            x63
-- Ten alts each holding one no longer produce ten rows; the per-character breakdown is
-- the item TOOLTIP's job now (features.lua's 1.x anatomy: Total header, same-account
-- rows with location badges, an Other Accounts section), and the row anchors it on hover.
--
--   results  = Find.Search output (already sorted self-first, then total desc, then name)
--   resolver = { instant=<GetItemInfoInstant>, info=<GetItemInfo> }
--
-- Row = { itemID, itemName, quality, icon, total, holders, hasSummary,
--         jumpKey, jumpName }
--   holders    — how many distinct characters hold it (drives the "on N characters" hint)
--   hasSummary — at least one contribution came from a cross-account SUMMARY owner, i.e.
--                the number includes copies whose slots are not browsable here
--   jumpKey    — click-to-jump target: the FIRST holder in the Search order that is a
--                FULL owner (summary owners have no slots to jump to, so a summary-only
--                item has jumpKey == nil and its row click is inert).
--
-- Row ORDER is item name ASCENDING. Deliberately not total-desc: names resolve
-- asynchronously through GetItemInfo while the player is still typing, and a count-
-- ordered list re-shuffles under the cursor every time one lands.
----------------------------------------------------------------------

function Find.BuildItemRows(results, resolver)
    local agg, order = {}, {}

    local function identify(id, data)
        local name, quality, icon = nil, data and data.quality, nil
        if resolver then
            if resolver.instant then local _, _, _, _, ic = resolver.instant(id); icon = ic end
            if resolver.info then
                local nm, _, q = resolver.info(id)
                name = nm
                if quality == nil then quality = q end
            end
        end
        return name, quality, icon
    end

    local function bucket(id, data)
        local row = agg[id]
        if not row then
            local name, quality, icon = identify(id, data)
            row = {
                itemID = id, itemName = name or (data and data.link) or ("item:" .. id),
                quality = quality, icon = icon,
                total = 0, holders = 0, hasSummary = false,
                jumpKey = nil, jumpName = nil,
                _seen = {},
            }
            agg[id] = row
            order[#order + 1] = row
        end
        return row
    end

    for _, res in ipairs(results or {}) do
        local isFull = (res.source == "full")
        for _, mt in ipairs(res.matches or {}) do
            local data = mt.data
            local id = data and data.id
            if id then
                local row = bucket(id, data)
                row.total = row.total + (data.count or 1)
                if not row._seen[res.key] then
                    row._seen[res.key] = true
                    row.holders = row.holders + 1
                end
                -- First FULL holder in the Search order wins the jump target.
                if isFull and not row.jumpKey then
                    row.jumpKey, row.jumpName = res.key, res.name
                end
            end
        end
        for _, hit in ipairs(res.summaryHits or {}) do
            local row = bucket(hit.id, nil)
            row.total = row.total + (hit.count or 0)
            row.hasSummary = true
            if not row._seen[res.key] then
                row._seen[res.key] = true
                row.holders = row.holders + 1
            end
            if isFull and not row.jumpKey then
                row.jumpKey, row.jumpName = res.key, res.name
            end
        end
    end

    for _, row in ipairs(order) do row._seen = nil end
    table.sort(order, function(a, b)
        local an, bn = tostring(a.itemName):lower(), tostring(b.itemName):lower()
        if an ~= bn then return an < bn end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    return order
end

-- The two row columns, as plain testable strings. `qualityHex` is injected so the
-- headless tests can assert the shape; the live render passes a real color escape.
--   left  = "<qualityHex>Chronoboon Displacer|r"
--   right = "x63"   (the count tag is bare "1" -> "x1" is still shown: an aggregate row
--                    of exactly one copy is information, not noise)
function Find.FormatItemRow(row, qualityHex)
    qualityHex = qualityHex or ""
    local nameStr = qualityHex .. (row.itemName or "?") .. (qualityHex ~= "" and "|r" or "")
    return nameStr, "x" .. tostring(row.total or 0)
end

----------------------------------------------------------------------
-- PURE: WINDOW GEOMETRY (display round, ITEM 3).
--
-- The beta laid rows into an unclipped frame at a fixed window height, so any result
-- list longer than the window drew straight through the bottom border. The window now
-- sizes to its content between MIN_ROWS and MAX_ROWS and scrolls beyond that (the
-- frame layer parents the rows to a ScrollFrame, which clips by construction).
----------------------------------------------------------------------

Find.WIN_W    = 420   -- wide enough for "Supercharged Chronoboon Displacer" + the count
Find.ROW_H    = 20
Find.CHROME_H = 78    -- titlebar (36) + search box (24) + gap (8) + bottom pad (10)
Find.MIN_ROWS = 3
Find.MAX_ROWS = 14

-- Window height for a result count, clamped to the min/max row band.
function Find.WindowHeight(rowCount)
    local n = rowCount or 0
    if n < Find.MIN_ROWS then n = Find.MIN_ROWS end
    if n > Find.MAX_ROWS then n = Find.MAX_ROWS end
    return Find.CHROME_H + n * Find.ROW_H
end

-- True when the list exceeds the window band and the scroll range is live.
function Find.NeedsScroll(rowCount)
    return (rowCount or 0) > Find.MAX_ROWS
end

-- Scrollable overshoot in pixels (0 when everything fits).
function Find.ScrollRange(rowCount)
    local extra = (rowCount or 0) - Find.MAX_ROWS
    if extra <= 0 then return 0 end
    return extra * Find.ROW_H
end

-- =====================================================================
-- FRAME LAYER (in-game only)
-- =====================================================================

local UI
local WINDOW_NAME = "DaseekiBags2FindWindow"

-- Live resolver (same C_Item path as search.lua / ui_items.lua).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
    }
end

local function classRGB(class)
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    if UI and UI.Color then return UI.Color("text") end
    return 0.925, 0.890, 0.816
end

function Find.Ensure()
    if Find.window then return Find.window end
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end

    local win = _G.CreateFrame("Frame", WINDOW_NAME, _G.UIParent, "BackdropTemplate")
    -- ITEM 3: seeded at the empty-state height; Find.Refresh re-sizes to content.
    win:SetSize(Find.WIN_W, Find.WindowHeight(0))
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        -- 1.0 PARITY (opacity): near-solid dark ground (Bags-side alpha; sibling of inventory).
        self:SetBackdropColor(UI.Color("ground", (ns.Frame and ns.Frame.WINDOW_BG_ALPHA) or 0.94))
        self:SetBackdropBorderColor(UI.Color("border"))
    end)
    if UI.PaintLedgerGround then UI.PaintLedgerGround(win) end
    if _G.UISpecialFrames then table.insert(_G.UISpecialFrames, WINDOW_NAME) end

    -- Title bar
    local titleBar = _G.CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT"); titleBar:SetPoint("TOPRIGHT"); titleBar:SetHeight(28)
    titleBar:EnableMouse(true); titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing() end)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbBg:SetPoint("TOPLEFT", 1, -1); tbBg:SetPoint("BOTTOMRIGHT", -1, 0)
    UI.Skin(tbBg, function(self) self:SetColorTexture(UI.Color("panel")) end)
    local mark
    if UI.MakerMark then mark = UI.MakerMark(titleBar, { size = 18 }); mark:SetPoint("LEFT", 8, 0) end
    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.ceremonial or UI.fonts.header)
    if mark then title:SetPoint("LEFT", mark, "RIGHT", 8, 0) else title:SetPoint("LEFT", 10, 0) end
    title:SetText("Find")
    local closeBtn = _G.CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(24, 24); closeBtn:SetPoint("RIGHT", -6, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY"); cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER"); cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
    closeBtn:SetScript("OnClick", function() Find.Close() end)

    -- Search box
    local wrap = UI.FlatFrame(win, "inset", "controlBorder")
    wrap:SetHeight(24)
    wrap:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -36)
    wrap:SetPoint("TOPRIGHT", win, "TOPRIGHT", -10, -36)
    local box = _G.CreateFrame("EditBox", nil, wrap)
    box:SetPoint("TOPLEFT", 6, 0); box:SetPoint("BOTTOMRIGHT", -6, 0)
    box:SetAutoFocus(true)
    box:SetFontObject(UI.fonts.body)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); Find.Close() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnTextChanged", function(self) Find.RequestSearch(self:GetText()) end)
    win.box = box
    local hint = box:CreateFontString(nil, "ARTWORK")
    hint:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    hint:SetPoint("LEFT", box, "LEFT", 0, 0)
    hint:SetText("Search all characters")
    UI.Skin(hint, function(self) self:SetTextColor(UI.Color("faint")) end)
    win.hint = hint

    -- ── Results host (ITEM 3) ────────────────────────────────────────────────
    -- A ScrollFrame, NOT a plain frame: a ScrollFrame clips its scroll child to its own
    -- rect by construction, which is exactly the defect the owner screenshotted (rows
    -- drawn past the bottom border). Its viewport is inset from the backdrop on all
    -- sides so a row can never touch the window edge. The scroll child holds the rows.
    local list = _G.CreateFrame("ScrollFrame", nil, win)
    list:SetPoint("TOPLEFT", wrap, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)
    local content = _G.CreateFrame("Frame", nil, list)
    content:SetSize(Find.WIN_W - 20, 1)
    list:SetScrollChild(content)
    -- Wheel scrolling, clamped to the live range (set per refresh in Find.Refresh).
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        local range = self._range or 0
        if range <= 0 then return end
        local v = (self:GetVerticalScroll() or 0) - delta * Find.ROW_H
        if v < 0 then v = 0 elseif v > range then v = range end
        self:SetVerticalScroll(v)
    end)
    win.list    = list
    win.content = content
    win._rows   = {}

    local empty = content:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(UI.fonts.muted)
    empty:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -2)
    empty:SetPoint("RIGHT", content, "RIGHT", -2, 0)
    empty:SetJustifyH("LEFT")
    win.emptyFS = empty

    win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
    Find.window = win
    return win
end

-- Quality hex ("|cffRRGGBB") for the item name; class hex for the character name.
local function qualityHex(quality)
    local q = quality or 1
    local c = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[q]
    if c and c.hex then return c.hex end
    local r, g, b
    if _G.C_Item and _G.C_Item.GetItemQualityColor then r, g, b = _G.C_Item.GetItemQualityColor(q) end
    if not r then r, g, b = 1, 1, 1 end
    return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end
local function classHex(class)
    local r, g, b = classRGB(class)
    return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end

-- ITEM 3 (truncation): the count column is right-aligned at a fixed width so the NAME
-- column owns everything else. Names longer than that ellipsize instead of clipping
-- mid-word ("(Ba…"): SetWordWrap(false) on a two-point-anchored fontstring gives WoW's
-- native "…" truncation, and the two-point anchor is what makes the width real.
local ICON_W, ICON_GAP, COUNT_W, ROW_PAD = 16, 5, 46, 2

local function acquireRow(win, i)
    local row = win._rows[i]
    if row then return row end
    row = _G.CreateFrame("Button", nil, win.content)
    row:SetHeight(Find.ROW_H)
    local hl = row:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:Hide()
    UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("brand", 0.18)) end)
    row._hl = hl
    -- Row icon: 16px item icon at the left.
    local ic = row:CreateTexture(nil, "ARTWORK"); ic:SetSize(ICON_W, ICON_W)
    ic:SetPoint("LEFT", row, "LEFT", ROW_PAD, 0)
    row._icon = ic
    -- Count column FIRST (right-aligned, fixed width) so the name can anchor against it.
    local ct = row:CreateFontString(nil, "OVERLAY")
    ct:SetFontObject(UI.fonts.numeral or UI.fonts.body)
    ct:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD, 0)
    ct:SetWidth(COUNT_W)
    ct:SetJustifyH("RIGHT")
    UI.Skin(ct, function(self) self:SetTextColor(UI.Color("text")) end)
    row._count = ct
    local nm = row:CreateFontString(nil, "OVERLAY"); nm:SetFontObject(UI.fonts.body)
    nm:SetPoint("LEFT", ic, "RIGHT", ICON_GAP, 0)
    nm:SetPoint("RIGHT", ct, "LEFT", -6, 0)
    nm:SetJustifyH("LEFT"); nm:SetWordWrap(false)
    row._label = nm
    row:SetScript("OnEnter", function(self)
        self._hl:Show()
        -- ITEM 2: the row anchors the REAL item tooltip — which, with the 1.x anatomy
        -- restored in features.lua, is where the per-character breakdown now lives.
        if _G.GameTooltip and self._link then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if _G.GameTooltip.SetHyperlink then _G.GameTooltip:SetHyperlink(self._link) end
            _G.GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self) self._hl:Hide(); if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    win._rows[i] = row
    return row
end

-- Run the search and repaint the result rows.
function Find.Refresh(text)
    local win = Find.window
    if not win then return end
    text = text or (win.box and win.box:GetText()) or ""
    if win.hint then win.hint:SetShown(text == "") end

    for _, r in ipairs(win._rows) do r:Hide() end

    -- Size the window + reset the scroll for an N-row result (ITEM 3).
    local function fit(n)
        win:SetHeight(Find.WindowHeight(n))
        win.list._range = Find.ScrollRange(n)
        win.list:SetVerticalScroll(0)
        win.content:SetHeight(math.max(1, n * Find.ROW_H))
        -- The viewport width is only real once the window has been laid out; before that
        -- (first Refresh off Find.Open) fall back to the design width, never to 0 — a
        -- zero-width scroll child would collapse every row's two-point anchor.
        local vw = (win.list.GetWidth and win.list:GetWidth()) or 0
        if not vw or vw <= 1 then vw = Find.WIN_W - 20 end
        win.content:SetWidth(vw)
    end

    local query = ns.Search and ns.Search.Compile and ns.Search.Compile(text)
    if not query or query.isEmpty then
        fit(0)
        win.emptyFS:SetText("Type an item name to search every character.")
        win.emptyFS:Show()
        return
    end

    local data = Store and Store.data
    local selfKey = ns.Owner and ns.Owner.SelfKey and ns.Owner.SelfKey()
    -- ITEM 4: the owner universe is the NEXUS-MERGED view when the bridge is live —
    -- Bags' own owners plus the Nexus store's cross-account SUMMARY owners, newest-wins.
    -- Reading Store.data.owners directly is what made Find blind to the other account
    -- even after the summary branch above existed. Type-guarded; falls back to the store.
    local owners = data and data.owners or {}
    if ns.Nexus and ns.Nexus.Owners then
        local view = ns.Nexus.Owners()
        if type(view) == "table" then owners = view end
    end
    local results = Find.Search(owners, query, liveResolver(), { selfKey = selfKey })

    if #results == 0 then
        fit(0)
        win.emptyFS:SetText("No character has a matching item.")
        win.emptyFS:Show()
        return
    end
    win.emptyFS:Hide()

    -- ITEM 2: ONE aggregate row per distinct item — icon, quality-colored name, TOTAL.
    local itemRows = Find.BuildItemRows(results, liveResolver())
    fit(#itemRows)
    local y = 0
    for i, r in ipairs(itemRows) do
        local row = acquireRow(win, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", win.content, "RIGHT", 0, 0)
        row._icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local nameStr, countStr = Find.FormatItemRow(r, qualityHex(r.quality))
        row._label:SetText(nameStr)
        row._label:SetTextColor(1, 1, 1)   -- the embedded color escape carries the coloring
        row._count:SetText(countStr)
        row._link = r.itemID and ("item:" .. r.itemID) or nil
        -- Click-to-jump still targets a browsable holder; a summary-only item has none,
        -- so its row is inert (the tooltip already names who holds it).
        if r.jumpKey then
            row:SetScript("OnClick", function() Find.JumpTo(r.jumpKey, text) end)
            row:Enable()
        else
            row:SetScript("OnClick", nil)
        end
        row:Show()
        y = y + Find.ROW_H
    end
    for i = #itemRows + 1, #win._rows do win._rows[i]:Hide() end
end

Find._searchQueued = false
function Find.RequestSearch(text)
    Find._pendingText = text
    if Find._searchQueued then return end
    Find._searchQueued = true
    local fire = function()
        Find._searchQueued = false
        if ns.SafeCall then ns:SafeCall(Find.Refresh, Find._pendingText) else Find.Refresh(Find._pendingText) end
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, fire) else fire() end
end

-- Jump to a holder: flip the shared view to that owner, open the inventory (and the
-- bank if it has bank data), and apply the query so the matches highlight there.
function Find.JumpTo(ownerKey, text)
    local Frame = ns.Frame
    if Frame and Frame.SetViewedOwner then Frame.SetViewedOwner(ownerKey) end
    if Frame and Frame.Open then Frame.Open() end
    if Frame and Frame.SetSearch then Frame.SetSearch(text or "") end
    local owner = Store and Store.GetOwner and Store.GetOwner(ownerKey)
    if ns.Bank and ns.Bank.Open and ns.Owner and ns.Owner.HasBankData and ns.Owner.HasBankData(owner) then
        ns.Bank.Open()
    end
end

function Find.Open(text)
    local win = Find.Ensure()
    if not win then return end
    win:Show()
    if text and text ~= "" and win.box then win.box:SetText(text) end
    Find.Refresh(win.box and win.box:GetText() or text)
    if win.box then win.box:SetFocus() end
end

function Find.Close()
    if Find.window then Find.window:Hide() end
end

function Find.Toggle(text)
    local win = Find.Ensure()
    if not win then return end
    if win:IsShown() then Find.Close() else Find.Open(text) end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_find")
----------------------------------------------------------------------

-- Fake resolver: name/type from an item db keyed by id (see search.lua's shape).
local function fakeResolver(db)
    return {
        instant = function(id) local e = db[id]; if not e then return nil end
            return id, e.itype, e.isub, e.equip, 1 end,
        info = function(id) local e = db[id]; if not e then return nil end
            return e.name, "item:" .. id, e.quality end,
    }
end

local function testFindAcrossOwners(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [100] = { name = "Songflower Serenade Petal", quality = 1, itype = "Consumable", cached = true },
        [200] = { name = "Arcanite Bar", quality = 3, itype = "Trade Goods", cached = true },
    }
    local R = fakeResolver(db)
    -- Poonyx (self): 40 in bags (cid 0), 12 in bank (cid -1). Also unrelated item 200.
    -- Alt "Zug": 5 in a bank bag (cid 5). "NoPetal": only item 200 -> no match.
    -- Summary "Rex": 99 in its aggregate map — searched as of the display round (ITEM 4).
    local owners = {
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full", containers = {
            [0]  = { slots = { [1] = { id = 100, count = 20 }, [2] = { id = 100, count = 20 },
                               [3] = { id = 200, count = 5 } } },
            [-1] = { slots = { [1] = { id = 100, count = 12 } } },
        } },
        ["Zug-R"] = { name = "Zug", class = "WARRIOR", source = "full", containers = {
            [5] = { slots = { [1] = { id = 100, count = 5 } } },   -- bank bag
        } },
        ["NoPetal-R"] = { name = "NoPetal", class = "ROGUE", source = "full", containers = {
            [0] = { slots = { [1] = { id = 200, count = 3 } } },
        } },
        ["Rex-R"] = { name = "Rex", source = "summary", containers = {}, itemCounts = { [100] = 99 } },
    }

    local q = ns.Search.Compile("songflower")
    local res = Find.Search(owners, q, R, { selfKey = "Poonyx-R" })
    ck(#res == 3, "three holders match 'songflower' (self + Zug + summary Rex), got " .. #res)
    ck(res[1].key == "Poonyx-R" and res[1].isSelf, "self sorts first")
    ck(res[1].bagsCount == 40 and res[1].bankCount == 12 and res[1].total == 52,
        "Poonyx split: 40 bags / 12 bank / 52 total")
    ck(#res[1].matches == 3, "Poonyx has 3 matching stacks (2 bag + 1 bank)")
    local zug, rex
    for _, r in ipairs(res) do
        if r.key == "Zug-R" then zug = r elseif r.key == "Rex-R" then rex = r end
    end
    ck(zug and zug.bankCount == 5 and zug.bagsCount == 0, "Zug: 5 in a bank bag, 0 in bags")
    -- ITEM 4: the summary owner "Rex" holds 99 of item 100 in its aggregate map and is
    -- now a result — it used to be invisible by construction. Its contribution has no
    -- slot location: bagsCount/bankCount stay 0 and summaryCount carries the number.
    ck(rex ~= nil, "the summary owner is searched (ITEM 4)")
    ck(rex and rex.summaryCount == 99 and rex.bagsCount == 0 and rex.bankCount == 0,
        "summary hit contributes to the total with no location")
    ck(res[2].key == "Rex-R", "results still sort self-first, then total desc")
    -- format strings
    ck(Find.FormatOwnerResult(res[1]) == "Poonyx — Bank: 12 \194\183 Bags: 40", "self line format")
    ck(Find.FormatOwnerResult(zug) == "Zug — Bank: 5", "bank-only line omits Bags")
    local bagsOnly = { name = "X", bagsCount = 7, bankCount = 0 }
    ck(Find.FormatOwnerResult(bagsOnly) == "X — Bags: 7", "bags-only line omits Bank")

    -- empty query -> no results
    ck(#Find.Search(owners, ns.Search.Compile(""), R, {}) == 0, "empty query -> no results")
    -- a query nobody matches
    ck(#Find.Search(owners, ns.Search.Compile("thunderfury"), R, {}) == 0, "no holder -> empty")
end

-- ITEM 2 (display round): ONE aggregate row per distinct ITEM, carrying the TOTAL
-- across every owner and location. The per-(item, owner, location) explosion is gone.
local function testFindAggregateRows(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [100] = { name = "Chronoboon Displacer", quality = 1, itype = "Consumable" },
        [101] = { name = "Supercharged Chronoboon Displacer", quality = 1, itype = "Consumable" },
    }
    local R = fakeResolver(db)
    -- Ten alts each holding a stack, plus self holding two stacks in two locations and a
    -- single supercharged one — the owner's exact screenshot shape.
    local owners = {}
    for i = 1, 10 do
        owners["Alt" .. i .. "-R"] = { name = "Alt" .. i, class = "ROGUE", source = "full",
            containers = { [0] = { slots = { [1] = { id = 100, count = 6 } } } } }
    end
    owners["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full", containers = {
        [0]  = { slots = { [1] = { id = 100, count = 2 }, [2] = { id = 101, count = 1 } } },
        [-1] = { slots = { [1] = { id = 100, count = 1 } } },
    } }

    local q = ns.Search.Compile("chronoboon")
    local res = Find.Search(owners, q, R, { selfKey = "Poonyx-R" })
    ck(#res == 11, "eleven holders match, got " .. #res)
    local rows = Find.BuildItemRows(res, R)
    -- The whole point: 11 holders x up-to-2 locations collapses to TWO item rows.
    ck(#rows == 2, "two distinct items -> two rows, got " .. #rows)
    -- Name ascending: "Chronoboon Displacer" before "Supercharged ...".
    ck(rows[1].itemName == "Chronoboon Displacer", "rows sort by item name ascending")
    ck(rows[2].itemName == "Supercharged Chronoboon Displacer", "second row is the supercharged one")
    ck(rows[1].total == 10 * 6 + 2 + 1, "total sums every owner AND both locations, got " .. rows[1].total)
    ck(rows[1].holders == 11, "holder count is distinct characters, got " .. rows[1].holders)
    ck(rows[1].hasSummary == false, "no summary contribution in an all-full result")
    ck(rows[1].jumpKey == "Poonyx-R", "self (first in the Search order) is the jump target")
    ck(rows[1].quality == 1 and rows[1].icon ~= nil, "row carries quality + icon for the render")
    ck(rows[1]._seen == nil, "the holder-dedupe scratch table is cleaned off the row")

    -- Row columns: "<qHex>Name|r" and "xN".
    local nameStr, countStr = Find.FormatItemRow(rows[1], "|cffFFFFFF")
    ck(nameStr == "|cffFFFFFFChronoboon Displacer|r", "name column carries the quality escape, got: " .. nameStr)
    ck(countStr == "x63", "count column is the grand total, got " .. countStr)
    local bare = select(1, Find.FormatItemRow({ itemName = "Hearthstone", total = 1 }))
    ck(bare == "Hearthstone", "no hex -> bare name")
    ck(select(2, Find.FormatItemRow({ itemName = "Hearthstone", total = 1 })) == "x1",
        "a single copy still shows its count")

    -- Unresolved name (GetItemInfo not back yet) falls back to a stable key, never nil.
    local unresolved = Find.BuildItemRows({ { key = "K", name = "K", source = "full",
        matches = { { cid = 0, slot = 1, data = { id = 4242, count = 3 } } }, summaryHits = {} } }, nil)
    ck(#unresolved == 1 and unresolved[1].itemName == "item:4242", "unresolved name falls back to item:<id>")

    ck(#Find.BuildItemRows({}, R) == 0, "no results -> no rows")
    ck(#Find.BuildItemRows(nil, R) == 0, "nil results -> no rows")
end

-- ITEM 4 (display round): SUMMARY owners are searched via their aggregate itemCounts.
-- The owner's proven gap: Find showed 1 copy where the tooltip showed 2, the second on a
-- cross-account summary character. The lock is that a summary holder BOTH appears in the
-- results AND lands in the aggregate total, while a FULL owner (which also mirrors an
-- itemCounts map) is never double-counted.
local function testFindSummaryOwners(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [100] = { name = "Chronoboon Displacer", quality = 1, itype = "Consumable" },
        [200] = { name = "Arcanite Bar", quality = 3, itype = "Trade Goods" },
    }
    local R = fakeResolver(db)
    local owners = {
        -- FULL owner: 1 in bags. Its itemCounts mirror MUST NOT be counted a second time.
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full",
            containers = { [0] = { slots = { [1] = { id = 100, count = 1 } } } },
            itemCounts = { [100] = 1 } },
        -- SUMMARY owner on another account: 1 copy, aggregate only.
        ["Remote-R"] = { name = "Remote", class = "PRIEST", source = "summary",
            containers = {}, itemCounts = { [100] = 1, [200] = 9 } },
    }
    local q = ns.Search.Compile("chronoboon")
    local res = Find.Search(owners, q, R, { selfKey = "Poonyx-R" })
    ck(#res == 2, "the summary owner now shows up as a holder, got " .. #res)

    local full, summary
    for _, r in ipairs(res) do
        if r.key == "Poonyx-R" then full = r elseif r.key == "Remote-R" then summary = r end
    end
    ck(full and full.total == 1, "the full owner is counted ONCE (no itemCounts double-count)")
    ck(full and #full.summaryHits == 0, "a full owner produces no summary hits")
    ck(summary and summary.total == 1 and summary.summaryCount == 1,
        "the summary owner contributes its aggregate")
    ck(summary and summary.bagsCount == 0 and summary.bankCount == 0,
        "a summary hit has NO slot location")
    ck(summary and #summary.summaryHits == 1 and summary.summaryHits[1].id == 100,
        "summary hits carry the matched item id (the non-matching 200 is filtered)")

    -- The aggregate row now reports 2 — the number the tooltip has always shown.
    local rows = Find.BuildItemRows(res, R)
    ck(#rows == 1, "one aggregate row for one distinct item")
    ck(rows[1].total == 2, "cross-account total is 2 (1 local + 1 remote), got " .. tostring(rows[1].total))
    ck(rows[1].holders == 2, "two holders")
    ck(rows[1].hasSummary == true, "row flags that part of the total is cross-account")
    ck(rows[1].jumpKey == "Poonyx-R", "jump target is the FULL holder")

    -- A summary-ONLY item has no browsable holder, so no jump target.
    local res2 = Find.Search(owners, ns.Search.Compile("arcanite"), R, { selfKey = "Poonyx-R" })
    local rows2 = Find.BuildItemRows(res2, R)
    ck(#rows2 == 1 and rows2[1].total == 9, "summary-only item totals 9")
    ck(rows2[1].jumpKey == nil, "summary-only row has no jump target (nothing to browse)")

    -- The grammar still applies to summary ids: a t: term filters them too.
    local res3 = Find.Search(owners, ns.Search.Compile("t:trade"), R, { selfKey = "Poonyx-R" })
    ck(#res3 == 1 and res3[1].key == "Remote-R", "type prefix filters summary ids as well")
end

-- ITEM 3 (display round): the window sizes to content, then scrolls. The defect was
-- rows drawn past the bottom border; this geometry contract is the pure half of the fix
-- (the frame half is the ScrollFrame, which clips its child by construction).
local function testFindWindowGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local H, MIN, MAX, RH = Find.CHROME_H, Find.MIN_ROWS, Find.MAX_ROWS, Find.ROW_H
    ck(Find.WindowHeight(0) == H + MIN * RH, "empty state clamps to the minimum band")
    ck(Find.WindowHeight(1) == H + MIN * RH, "1 row still clamps to the minimum band")
    ck(Find.WindowHeight(MIN + 2) == H + (MIN + 2) * RH, "grows with content between the bounds")
    ck(Find.WindowHeight(MAX) == H + MAX * RH, "exactly MAX rows fits without scrolling")
    ck(Find.WindowHeight(MAX + 50) == H + MAX * RH, "beyond MAX the window stops growing")
    ck(Find.WindowHeight(nil) == H + MIN * RH, "nil row count is the empty state")

    ck(Find.NeedsScroll(MAX) == false, "MAX rows needs no scroll")
    ck(Find.NeedsScroll(MAX + 1) == true, "MAX+1 rows scrolls")
    ck(Find.ScrollRange(MAX) == 0, "no overshoot at MAX")
    ck(Find.ScrollRange(MAX + 3) == 3 * RH, "overshoot is the hidden rows' height")
    ck(Find.ScrollRange(0) == 0, "empty list has no scroll range")
    -- THE REGRESSION LOCK: the visible rows always fit inside the window, at every count.
    for n = 0, MAX + 5 do
        local visible = math.min(n, MAX)
        ck(H + visible * RH <= Find.WindowHeight(n),
            "rows fit inside the window at n=" .. n)
    end
    -- Wide enough for the owner's longest cited name plus the right-aligned count column.
    ck(Find.WIN_W >= 400, "window is wide enough for a long consumable name")
end

function Find.RunSelfTests(verbose)
    local suites = {
        { name = "find across owners",  fn = testFindAcrossOwners },
        { name = "aggregate item rows", fn = testFindAggregateRows },
        { name = "summary owners",      fn = testFindSummaryOwners },
        { name = "window geometry",     fn = testFindWindowGeometry },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_find/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_find/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_find", Find.RunSelfTests)
end

return Find
