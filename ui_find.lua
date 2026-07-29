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
--   Find.FormatOwnerResult(result)       -> "Poonyx — Bank: 12 · Bags: 40"
-- The FRAME layer is a small Ledger window (its own maker's mark) with a search box
-- and a click-to-jump result list.
--
-- Summary (mesh) owners carry only aggregate itemCounts, not per-slot records, so they
-- cannot be searched by name/type here — Find covers FULL owners (own characters). A
-- future wave can fold aggregate-only hits in once the mesh goes live (W5).
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
--   { key, name, class, source, bagsCount, bankCount, total, isSelf,
--     matches = { { cid, slot, data }, ... } }
-- Only owners with >=1 match are included.
----------------------------------------------------------------------

function Find.Search(owners, query, resolver, opts)
    opts = opts or {}
    local results = {}
    if type(owners) ~= "table" or not query or query.isEmpty then return results end

    for key, owner in pairs(owners) do
        local containers = owner.containers
        if type(containers) == "table" then
            local bags, bank, matches = 0, 0, {}
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
            if #matches > 0 then
                results[#results + 1] = {
                    key = key, name = owner.name or key, class = owner.class,
                    source = owner.source or "summary",
                    bagsCount = bags, bankCount = bank, total = bags + bank,
                    isSelf = (opts.selfKey ~= nil and key == opts.selfKey),
                    matches = matches,
                }
            end
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
function Find.FormatOwnerResult(result)
    local parts = {}
    if (result.bankCount or 0) > 0 then parts[#parts + 1] = "Bank: " .. result.bankCount end
    if (result.bagsCount or 0) > 0 then parts[#parts + 1] = "Bags: " .. result.bagsCount end
    if #parts == 0 then parts[1] = "0" end
    return result.name .. " — " .. table.concat(parts, " \194\183 ")   -- \194\183 = middot
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
    win:SetSize(320, 260)
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("ground"))
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

    -- Results host
    local list = _G.CreateFrame("Frame", nil, win)
    list:SetPoint("TOPLEFT", wrap, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)
    win.list = list
    win._rows = {}

    local empty = list:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(UI.fonts.muted)
    empty:SetPoint("TOPLEFT", list, "TOPLEFT", 2, -2)
    win.emptyFS = empty

    win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
    Find.window = win
    return win
end

local function acquireRow(win, i)
    local row = win._rows[i]
    if row then return row end
    row = _G.CreateFrame("Button", nil, win.list)
    row:SetHeight(22)
    local hl = row:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:Hide()
    UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("brand", 0.18)) end)
    row._hl = hl
    local nm = row:CreateFontString(nil, "OVERLAY"); nm:SetFontObject(UI.fonts.body)
    nm:SetPoint("LEFT", row, "LEFT", 4, 0); nm:SetJustifyH("LEFT"); nm:SetWordWrap(false)
    row._label = nm
    row:SetScript("OnEnter", function(self) self._hl:Show() end)
    row:SetScript("OnLeave", function(self) self._hl:Hide() end)
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

    local query = ns.Search and ns.Search.Compile and ns.Search.Compile(text)
    if not query or query.isEmpty then
        win.emptyFS:SetText("Type an item name to search every character.")
        win.emptyFS:Show()
        return
    end

    local data = Store and Store.data
    local selfKey = ns.Owner and ns.Owner.SelfKey and ns.Owner.SelfKey()
    local results = Find.Search(data and data.owners or {}, query, liveResolver(), { selfKey = selfKey })

    if #results == 0 then
        win.emptyFS:SetText("No character has a matching item.")
        win.emptyFS:Show()
        return
    end
    win.emptyFS:Hide()

    local y = 0
    for i, res in ipairs(results) do
        local row = acquireRow(win, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", win.list, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", win.list, "RIGHT", 0, 0)
        row._label:SetText(Find.FormatOwnerResult(res))
        row._label:SetTextColor(classRGB(res.class))
        row:SetScript("OnClick", function() Find.JumpTo(res.key, text) end)
        row:Show()
        y = y + 22
    end
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
    -- Alt "Zug": 5 in a bank bag (cid 5). "NoPetal": only item 200 -> no match. Summary "Rex": skipped.
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
    ck(#res == 2, "two holders match 'songflower' (self + Zug; NoPetal/Rex excluded)")
    ck(res[1].key == "Poonyx-R" and res[1].isSelf, "self sorts first")
    ck(res[1].bagsCount == 40 and res[1].bankCount == 12 and res[1].total == 52,
        "Poonyx split: 40 bags / 12 bank / 52 total")
    ck(#res[1].matches == 3, "Poonyx has 3 matching stacks (2 bag + 1 bank)")
    ck(res[2].key == "Zug-R" and res[2].bankCount == 5 and res[2].bagsCount == 0,
        "Zug: 5 in a bank bag, 0 in bags")
    -- format strings
    ck(Find.FormatOwnerResult(res[1]) == "Poonyx — Bank: 12 \194\183 Bags: 40", "self line format")
    ck(Find.FormatOwnerResult(res[2]) == "Zug — Bank: 5", "bank-only line omits Bags")
    local bagsOnly = { name = "X", bagsCount = 7, bankCount = 0 }
    ck(Find.FormatOwnerResult(bagsOnly) == "X — Bags: 7", "bags-only line omits Bank")

    -- empty query -> no results
    ck(#Find.Search(owners, ns.Search.Compile(""), R, {}) == 0, "empty query -> no results")
    -- a query nobody matches
    ck(#Find.Search(owners, ns.Search.Compile("thunderfury"), R, {}) == 0, "no holder -> empty")
    -- summary owner never contributes matches (no per-slot records)
    for _, r in ipairs(res) do ck(r.source == "full", "only full owners in results") end
end

function Find.RunSelfTests(verbose)
    local suites = {
        { name = "find across owners", fn = testFindAcrossOwners },
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
