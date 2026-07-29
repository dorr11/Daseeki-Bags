-- Daseeki Bags 2.0 — ui_owner.lua  (W3)
-- The OWNER SELECTOR: a titlebar flyout (on BOTH the inventory and bank windows)
-- listing every cached owner so the player can flip the view to any of their
-- characters — self, own-account alts, or cross-account/mesh chars — and see that
-- character's bags/bank read-only (the offline-viewing workflow, parity audit 5.2).
--
-- Reuses the Nexus register-row grammar (BRAND_SPEC §7, Expert C §5d): each row is
--   [seal] · name(class color) · [source badge] · freshness
-- one open at a time (click-away close), self first, then own-account chars, then
-- cross-account. Selecting a non-self owner flips the shared viewed-owner state
-- (Frame.SetViewedOwner) — the Items contract already renders any non-self / summary
-- owner as read-only (Items.IsLive gates on source=="full" AND nameRealm==self), so
-- the selector is pure view-state; it performs ZERO secure/protected ops.
--
-- ── Purity split (mirrors the rest of 2.0) ────────────────────────────────────
--   PURE core (headless-tested): BuildOwnerList (ordering + descriptors),
--     FreshnessLabel, SourceBadge, HasBankData.
--   FRAME layer (in-game only; guarded on _G.CreateFrame): CreateSelector — the
--     titlebar button + click-away flyout, built from DaseekiUI tokens/fonts.
--
-- ── Catalog evidence (WoW Classic Era 1.15.9.68808) ───────────────────────────
--   RAID_CLASS_COLORS[classTag] (globals.txt) — class-color the character name.
--   No bank/secure APIs here: the selector only changes which owner RECORD the
--   windows render, never touches an item button.

local ADDON, ns = ...

local Owner = {}
ns.Owner = Owner

local Store = ns.Store

----------------------------------------------------------------------
-- Self identity (mirrors capture.selfNameRealm / features.selfKey; headless-safe)
----------------------------------------------------------------------

function Owner.SelfKey()
    local name  = (_G.UnitName and _G.UnitName("player")) or nil
    if not name then return nil end
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))
    return Store.MakeNameRealm(name, realm)
end

----------------------------------------------------------------------
-- PURE: descriptors
----------------------------------------------------------------------

-- True when an owner has ANY captured bank/bankbag container (so the selector can
-- tell the bank window whether flipping to this owner has bank data to show).
function Owner.HasBankData(owner)
    if type(owner) ~= "table" or type(owner.containers) ~= "table" then return false end
    for cid in pairs(owner.containers) do
        if Store.IsBankContainer(cid) then return true end
    end
    return false
end

-- Plain-copy freshness (BRAND_SPEC §6). Self is the logged-in character => "Online";
-- everyone else reads as faded ink by age. nil/0 age (never snapshot) => "No data".
function Owner.FreshnessLabel(ageSeconds, isSelf)
    if isSelf then return "Online" end
    if not ageSeconds or ageSeconds < 0 then return "No data" end
    if ageSeconds < 60    then return "Updated just now" end
    if ageSeconds < 3600  then return string.format("Updated %dm ago", math.floor(ageSeconds / 60)) end
    if ageSeconds < 86400 then return string.format("Updated %dh ago", math.floor(ageSeconds / 3600)) end
    return string.format("Updated %dd ago", math.floor(ageSeconds / 86400))
end

-- Source badge text: a fully-captured owner ("Full", per-slot bags/bank) vs a mesh
-- summary owner ("Summary", money + aggregate counts only, no browsable slots).
function Owner.SourceBadge(source)
    if source == "full" then return "Full" end
    return "Summary"
end

-- Build the ordered owner list for the flyout.
--   owners      = Store.data.owners shape  ([key] = ownerRecord)
--   selfKey     = the logged-in character's "Name-Realm" (Owner.SelfKey())
--   selfAccount = Store.data.selfAccount (own-account grouping; "" when unknown)
--   now         = injectable epoch (defaults Store.Now())
-- Returns an array of descriptors, ordered self → own-account → cross-account, then
-- name ascending within each group:
--   { key, name, class, account, source, isSelf, isOwnAccount, ageSeconds, hasBank, rank }
function Owner.BuildOwnerList(owners, selfKey, selfAccount, now)
    now = now or (Store.Now and Store.Now()) or 0
    local list = {}
    if type(owners) ~= "table" then return list end
    for key, o in pairs(owners) do
        local isSelf = (selfKey ~= nil and key == selfKey)
        local acct   = o.account or ""
        local isOwn  = (not isSelf) and acct ~= "" and selfAccount ~= nil
                       and selfAccount ~= "" and acct == selfAccount
        local age    = (o.ts and o.ts > 0) and (now - o.ts) or nil
        list[#list + 1] = {
            key = key, name = o.name or key, class = o.class, account = acct,
            source = o.source or "summary",
            isSelf = isSelf, isOwnAccount = isOwn and true or false,
            ageSeconds = age, hasBank = Owner.HasBankData(o),
            rank = isSelf and 0 or (isOwn and 1 or 2),
        }
    end
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        local an, bn = tostring(a.name):lower(), tostring(b.name):lower()
        if an ~= bn then return an < bn end
        return tostring(a.key) < tostring(b.key)
    end)
    return list
end

-- =====================================================================
-- FRAME LAYER (in-game only)
-- =====================================================================

local UI  -- DaseekiUI, bound lazily

local function classRGB(class)
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    if UI and UI.Color then return UI.Color("text") end
    return 0.925, 0.890, 0.816   -- cream fallback (#ECE3D0)
end

-- Current viewed owner key (shared state lives on ns.Frame; the selector only reads it).
local function viewedKey()
    if ns.Frame and ns.Frame.ViewedOwnerKey then return ns.Frame.ViewedOwnerKey() end
    return Owner.SelfKey()
end

-- Build the descriptor list live from the store.
function Owner.LiveList()
    local data = Store and Store.data
    local owners = data and data.owners or {}
    return Owner.BuildOwnerList(owners, Owner.SelfKey(), data and data.selfAccount, Store.Now())
end

-- Create a titlebar owner selector: a compact button showing the viewed character's
-- name (class-colored) with a caret, opening a click-away flyout of register rows.
--   opts = { onSelect = function(key) ... end, width = <n> }
-- Returns a frame with :Refresh() (re-syncs the button label to the current view).
function Owner.CreateSelector(parent, opts)
    opts = opts or {}
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end

    local width = opts.width or 150
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetSize(width, 22)

    -- The face button (current owner + caret), quiet control fill, crimson hover.
    local btn = _G.CreateFrame("Button", nil, frame, "BackdropTemplate")
    btn:SetAllPoints(frame)
    UI.Skin(btn, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("control"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    UI.Skin(hover, function(self) self:SetColorTexture(UI.Color("brand", 0.14)) end)
    btn:SetHighlightTexture(hover)

    -- seal pip (BRAND_SPEC §5: one square pip per register row; online=lit, offline=idle)
    local pip = btn:CreateTexture(nil, "OVERLAY")
    pip:SetSize(6, 6)
    pip:SetPoint("LEFT", btn, "LEFT", 6, 0)

    local nameFS = btn:CreateFontString(nil, "OVERLAY")
    nameFS:SetFontObject(UI.fonts.body)
    nameFS:SetPoint("LEFT", pip, "RIGHT", 5, 0)
    nameFS:SetPoint("RIGHT", btn, "RIGHT", -16, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)

    local caret = btn:CreateFontString(nil, "OVERLAY")
    caret:SetFontObject(UI.fonts.muted)
    caret:SetPoint("RIGHT", btn, "RIGHT", -5, 0)
    caret:SetText("v")

    frame._btn, frame._pip, frame._name = btn, pip, nameFS

    ----------------------------------------------------------------
    -- Click-away flyout (owned popup; one build, click-anywhere-outside closes)
    ----------------------------------------------------------------
    local popup, closer

    local function buildPopup()
        popup = _G.CreateFrame("Frame", nil, _G.UIParent, "BackdropTemplate")
        popup:SetFrameStrata("TOOLTIP")
        popup:EnableMouse(true)
        popup:Hide()
        UI.Skin(popup, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("panel"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
        end)
        if UI.PaintLedgerGround then UI.PaintLedgerGround(popup) end
        popup._rows = {}

        closer = _G.CreateFrame("Button", nil, _G.UIParent)
        closer:SetFrameStrata("FULLSCREEN_DIALOG")
        closer:SetAllPoints(_G.UIParent)
        closer:Hide()
        closer:SetScript("OnClick", function() popup:Hide() end)
        popup:SetScript("OnHide", function() closer:Hide() end)
    end

    -- Pool one register row.
    local function acquireRow(i)
        local row = popup._rows[i]
        if row then return row end
        row = _G.CreateFrame("Button", nil, popup)
        row:SetHeight(24)
        local rh = row:CreateTexture(nil, "BACKGROUND")
        rh:SetAllPoints(); rh:Hide()
        UI.Skin(rh, function(self) self:SetColorTexture(UI.Color("brand", 0.20)) end)
        row._hl = rh
        row._pip = row:CreateTexture(nil, "OVERLAY")
        row._pip:SetSize(6, 6)
        row._pip:SetPoint("LEFT", row, "LEFT", 8, 0)
        row._name = row:CreateFontString(nil, "OVERLAY")
        row._name:SetFontObject(UI.fonts.body)
        row._name:SetPoint("LEFT", row._pip, "RIGHT", 6, 0)
        row._badge = row:CreateFontString(nil, "OVERLAY")
        row._badge:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
        row._badge:SetPoint("LEFT", row._name, "RIGHT", 6, 0)
        row._fresh = row:CreateFontString(nil, "OVERLAY")
        row._fresh:SetFontObject(UI.fonts.small)
        row._fresh:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row:SetScript("OnEnter", function(self) self._hl:Show() end)
        row:SetScript("OnLeave", function(self) self._hl:Hide() end)
        popup._rows[i] = row
        return row
    end

    local function populate()
        local list = Owner.LiveList()
        local rowW = math.max(220, width + 90)
        local y = 4
        local shown = 0
        local curKey = viewedKey()
        for i, d in ipairs(list) do
            local row = acquireRow(i)
            row:SetWidth(rowW - 6)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", 3, -y)
            row._pip:SetColorTexture(UI.Color(d.isSelf and "brand" or "idle"))
            row._name:SetText(d.name .. (d.key == curKey and "  (viewing)" or ""))
            row._name:SetTextColor(classRGB(d.class))
            row._badge:SetText(Owner.SourceBadge(d.source):upper())
            row._badge:SetTextColor(UI.Color(d.source == "full" and "bronze" or "faint"))
            row._fresh:SetText(Owner.FreshnessLabel(d.ageSeconds, d.isSelf))
            row._fresh:SetTextColor(UI.Color(d.isSelf and "ok" or "muted"))
            row:SetScript("OnClick", function()
                popup:Hide()
                if opts.onSelect then opts.onSelect(d.key) end
            end)
            row:Show()
            y = y + 26
            shown = i
        end
        for i = shown + 1, #popup._rows do popup._rows[i]:Hide() end
        popup:SetSize(rowW, math.max(1, y) + 2)
    end

    btn:SetScript("OnClick", function(self)
        if popup and popup:IsShown() then popup:Hide(); return end
        if not popup then buildPopup() end
        populate()
        popup:ClearAllPoints()
        popup:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        closer:Show()
        popup:Show()
    end)

    function frame:Refresh()
        local key = viewedKey()
        local o = Store and Store.GetOwner and Store.GetOwner(key)
        local selfKey = Owner.SelfKey()
        local isSelf = (key == selfKey)
        self._name:SetText((o and o.name) or (key and Store.SplitNameRealm(key)) or "Bags")
        self._name:SetTextColor(classRGB(o and o.class))
        self._pip:SetColorTexture(UI.Color(isSelf and "brand" or "idle"))
    end
    frame:Refresh()

    -- Track selectors so a view change refreshes every attached one (both windows).
    Owner._selectors = Owner._selectors or setmetatable({}, { __mode = "k" })
    Owner._selectors[frame] = true
    frame:SetScript("OnHide", function() end)   -- retained; refresh is explicit
    return frame
end

-- Refresh every live selector face (called after a view change).
function Owner.RefreshAll()
    if not Owner._selectors then return end
    for sel in pairs(Owner._selectors) do
        if sel.Refresh then sel:Refresh() end
    end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_owner")
----------------------------------------------------------------------

local function testFreshnessAndBadge(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Owner.FreshnessLabel(nil, true) == "Online", "self -> Online")
    ck(Owner.FreshnessLabel(999999, true) == "Online", "self ignores age")
    ck(Owner.FreshnessLabel(nil, false) == "No data", "no age -> No data")
    ck(Owner.FreshnessLabel(30, false) == "Updated just now", "<1m -> just now")
    ck(Owner.FreshnessLabel(300, false) == "Updated 5m ago", "5 minutes")
    ck(Owner.FreshnessLabel(7200, false) == "Updated 2h ago", "2 hours")
    ck(Owner.FreshnessLabel(259200, false) == "Updated 3d ago", "3 days")
    ck(Owner.SourceBadge("full") == "Full", "full badge")
    ck(Owner.SourceBadge("summary") == "Summary", "summary badge")
    ck(Owner.SourceBadge(nil) == "Summary", "nil source -> Summary")
end

local function testHasBankData(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Owner.HasBankData({ containers = { [0] = {}, [1] = {} } }) == false, "carried only -> no bank")
    ck(Owner.HasBankData({ containers = { [0] = {}, [-1] = {} } }) == true, "bank main -> has bank")
    ck(Owner.HasBankData({ containers = { [5] = {} } }) == true, "bank bag -> has bank")
    ck(Owner.HasBankData({ containers = { [-2] = {} } }) == false, "keyring is not bank")
    ck(Owner.HasBankData({}) == false, "no containers -> false")
    ck(Owner.HasBankData(nil) == false, "nil owner -> false")
end

local function testOwnerListOrdering(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- self (Zed, acctA), own-account alts (Bob & Amy, acctA), cross-account (Cid, acctB),
    -- and a remote/mesh summary owner (Rex, no account). Deliberately unsorted keys.
    local owners = {
        ["Zed-R"] = { name = "Zed", class = "MAGE",    account = "acctA", source = "full",
                      ts = 1000, containers = { [0] = {}, [-1] = {} } },
        ["Bob-R"] = { name = "Bob", class = "WARRIOR", account = "acctA", source = "full",
                      ts = 940,  containers = { [0] = {} } },
        ["Amy-R"] = { name = "Amy", class = "PRIEST",  account = "acctA", source = "full",
                      ts = 900,  containers = { [0] = {}, [5] = {} } },
        ["Cid-R"] = { name = "Cid", class = "ROGUE",   account = "acctB", source = "full",
                      ts = 500,  containers = { [0] = {} } },
        ["Rex-R"] = { name = "Rex", class = "HUNTER",  account = "",      source = "summary",
                      ts = 0,    containers = {} },
    }
    local list = Owner.BuildOwnerList(owners, "Zed-R", "acctA", 1000)
    ck(#list == 5, "all five owners listed")
    -- self first
    ck(list[1].key == "Zed-R" and list[1].isSelf, "self sorts first")
    ck(list[1].rank == 0, "self rank 0")
    -- own-account alts next, alphabetical: Amy then Bob
    ck(list[2].name == "Amy" and list[2].isOwnAccount, "own-account Amy second (alpha)")
    ck(list[3].name == "Bob" and list[3].isOwnAccount, "own-account Bob third")
    ck(list[2].rank == 1 and list[3].rank == 1, "own-account rank 1")
    -- cross-account + summary last (rank 2), alphabetical: Cid then Rex
    ck(list[4].name == "Cid" and not list[4].isOwnAccount, "cross-account Cid fourth")
    ck(list[5].name == "Rex", "summary Rex last")
    ck(list[4].rank == 2 and list[5].rank == 2, "cross-account/summary rank 2")
    -- descriptor fields
    ck(list[1].hasBank == true, "self has bank data")
    ck(list[2].hasBank == true, "Amy has a bank bag -> hasBank")
    ck(list[3].hasBank == false, "Bob carried-only -> no bank")
    ck(list[1].ageSeconds == 0 and list[4].ageSeconds == 500, "age computed from ts vs now")
    ck(list[5].ageSeconds == nil, "ts 0 -> nil age")
    ck(list[5].source == "summary", "Rex source summary")
    -- freshness rendering of the built descriptors
    ck(Owner.FreshnessLabel(list[1].ageSeconds, list[1].isSelf) == "Online", "self row -> Online")
    ck(Owner.FreshnessLabel(list[4].ageSeconds, list[4].isSelf) == "Updated 8m ago", "Cid 500s -> 8m ago")
    -- empty / nil guards
    ck(#Owner.BuildOwnerList(nil, "X", "a", 1) == 0, "nil owners -> empty list")
    -- no selfAccount => nobody is "own account" (all non-self are rank 2)
    local noAcct = Owner.BuildOwnerList(owners, "Zed-R", "", 1000)
    ck(noAcct[1].isSelf and noAcct[2].rank == 2, "blank selfAccount -> no own-account group")
end

function Owner.RunSelfTests(verbose)
    local suites = {
        { name = "freshness + badge",   fn = testFreshnessAndBadge },
        { name = "has bank data",       fn = testHasBankData },
        { name = "owner-list ordering", fn = testOwnerListOrdering },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_owner/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_owner/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_owner", Owner.RunSelfTests)
end

return Owner
