-- Daseeki Bags 2.0 — ui_bank.lua  (W3)
-- The BANK WINDOW: a second DaseekiUI-skinned logbook page (its own maker's mark),
-- born Field Ledger (parity audit 1.3 — bank was genuinely unbuilt). Opens on
-- BANKFRAME_OPENED alongside the inventory window (features.lua auto-display), shows
-- bank main + bank bags through the SAME ns.Items grid contract the inventory uses,
-- offers the 1.x bank-bag PURCHASE affordance behind a gold-confirm, a Sort button
-- reusing the bank container-id set, and flips to a read-only cached view when you
-- walk away from the banker (Expert C engineering sketch §5a/§5b).
--
-- ── Live vs cached (the BANKFRAME lifecycle rule, C §5a) ──────────────────────
-- Bank slots are only server-readable and interactive AT the bank. So:
--   * viewing SELF while the bank is OPEN  -> live secure buttons (Items.IsLive true:
--     self + source "full"); the game's ContainerFrameItemButtonTemplate does the
--     real pickup/place/split on (bankBagID, slot).
--   * viewing SELF while the bank is CLOSED, or viewing ANY OTHER owner -> render-only
--     (cached) buttons with a "Updated Xm ago" stamp. Self is demoted to render-only
--     via Bank.CachedView (a shallow proxy whose source is "summary" so Items.IsLive
--     rejects it) — no ui_items change, pure contract reuse. Other owners are already
--     read-only (full-but-not-self / summary both fail IsLive).
-- capture.lua already snapshots the bank on BANKFRAME_CLOSED and fires BAGS_CAPTURED;
-- this window just listens and repaints, flipping _live off so the swap to cached
-- buttons happens out of combat (the bank is never reachable in combat).
--
-- ── Purchase flow (1.x parity, C §5b) ─────────────────────────────────────────
-- GetNumBankSlots() -> (purchasedCount, isFull); GetBankSlotCost() -> next slot price;
-- PurchaseSlot() buys the next slot. The bank-bag strip renders purchased bags, the
-- one next-buyable slot as a bronze "buy" well (cost on the tooltip), and the rest as
-- idle locked wells. Clicking the buyable well raises a UI.Confirm gold dialog; only
-- its accept calls PurchaseSlot() (spends gold — never auto-fired), and only out of
-- combat. Purchase controls appear only when actually AT the bank (self + live).
--
-- ── Secure audit ──────────────────────────────────────────────────────────────
-- Item buttons follow the W2 template rules (bake at creation, combat-defer) via the
-- unchanged ns.Items path. This file itself performs ZERO protected item ops: it
-- Show/Hides its own unprotected window, and PurchaseSlot (an insecure FrameXML global
-- — the default UI calls it from a StaticPopup OnAccept) runs only behind the confirm,
-- out of combat. Sort at the bank routes through ns.Sort.Run(cids,{needsBank=true}),
-- which already guards combat + bank-open.
--
-- ── Catalog evidence (WoW Classic Era 1.15.9.68808, globals.txt / events.txt) ──
--   GetNumBankSlots (5326), GetBankSlotCost (4852), PurchaseSlot (7029),
--   BankFrame frame (BankFrame_OnShow 218), Event.Bank.BankframeOpened/Closed
--   (== BANKFRAME_OPENED / BANKFRAME_CLOSED), C_Container.GetContainerNumSlots(-1).

local ADDON, ns = ...

local Bank = {}
ns.Bank = Bank

local Store = ns.Store

----------------------------------------------------------------------
-- Window chrome bands (px) — kept beside the pure size math so both agree.
----------------------------------------------------------------------

-- 1.0-LOOK PARITY: mirror the inventory chrome metrics so the two windows read as
-- siblings (gold "<Char> · Bank" title, tight red-brown grid via the shared Frame.Gap,
-- bottom bar = small icon L · free/total C · money R).
Bank.PAD       = 8
Bank.TITLE_H   = 30   -- matches Frame.TITLE_H: room for the 22px title-row controls
Bank.STRIP_H   = 22   -- bank-bag purchase/toggle strip
-- FOOTER band, sibling of Frame.FOOTER_H (was MONEY_H = 20). The footer round moved the
-- owner selector out of the title row into the bottom-left corner on BOTH windows, so
-- this band now holds a 22px control and is one control tall. Its three zones — controls
-- LEFT, free/total CENTRE, money RIGHT — are the inventory footer's, element for element,
-- minus the raid-prep glyph (1.x only ever put that on the inventory frame).
Bank.FOOTER_H  = 22
Bank.VGAP      = 6

----------------------------------------------------------------------
-- PURE: bank container ordering (bank main first, then bank bags ascending)
----------------------------------------------------------------------

-- The cid of bank-bag STRIP index i (1-based). Bank bags occupy the container ids
-- immediately after the carried bags: NumBagSlots()+1 .. +NumBankBagSlots().
function Bank.BankBagCID(index)
    return Store.NumBagSlots() + (index or 1)
end

-- Ordered bank container ids the owner actually has captured: -1 (main) first, then
-- bank bags in ascending cid.
function Bank.BankContainerOrder(owner)
    local ids = {}
    if not owner or type(owner.containers) ~= "table" then return ids end
    if owner.containers[Store.BANK_CONTAINER] then ids[#ids + 1] = Store.BANK_CONTAINER end
    local first = Store.NumBagSlots() + 1
    local last  = Store.NumBagSlots() + Store.NumBankBagSlots()
    for cid = first, last do
        if owner.containers[cid] then ids[#ids + 1] = cid end
    end
    return ids
end

-- True when the owner has any browsable bank container (main or a bank bag).
function Bank.HasBankData(owner)
    return #Bank.BankContainerOrder(owner) > 0
end

----------------------------------------------------------------------
-- PURE: bank-bag purchase state (C §5b)
--
-- Bank bags are bought sequentially: GetNumBankSlots() returns how many are already
-- purchased; the NEXT one (purchased+1) is buyable; the remainder are locked (not yet
-- purchasable). Returns an array over the NumBankBagSlots() strip cells:
--   { index, cid, state = "purchased" | "buyable" | "locked" }
----------------------------------------------------------------------

function Bank.PurchaseState(numPurchased, totalSlots)
    numPurchased = math.max(0, math.floor(numPurchased or 0))
    totalSlots   = math.max(0, math.floor(totalSlots or Store.NumBankBagSlots()))
    local out = {}
    for i = 1, totalSlots do
        local state
        if i <= numPurchased then state = "purchased"
        elseif i == numPurchased + 1 then state = "buyable"
        else state = "locked" end
        out[i] = { index = i, cid = Bank.BankBagCID(i), state = state }
    end
    return out
end

----------------------------------------------------------------------
-- PURE: cached-view proxy (demote self to render-only away from the bank)
--
-- A shallow proxy over an owner record whose `source` is forced to "summary" so
-- Items.IsLive rejects it (=> render-only ItemButtonTemplate), while every other
-- field (containers, name, class, ts, nameRealm) reads through to the real record.
-- Used ONLY for self when the bank is closed; alts already render read-only.
----------------------------------------------------------------------

function Bank.CachedView(owner)
    if type(owner) ~= "table" then return owner end
    return setmetatable({ source = "summary" }, { __index = owner })
end

----------------------------------------------------------------------
-- PURE: bank entry list + content sizing (reuses the shared grid math)
----------------------------------------------------------------------

-- Flat bank entry list (bank main then bank bags, empties included) via the Items
-- contract's bank scope. Returns {} when Items or the owner is absent.
function Bank.BuildBankEntries(owner)
    if not (ns.Items and ns.Items.BuildEntries) then return {} end
    return ns.Items.BuildEntries(owner, { scope = "bank" })
end

-- Content region (grid only) size for the bank, using the inventory's grid math so
-- the two windows share one geometry. count 0 keeps the full band width (stable).
function Bank.ComputeContentSize(owner, opts)
    opts = opts or {}
    local Frame = ns.Frame
    local cols = opts.columns    or (Frame and Frame.Columns    and Frame.Columns())    or 12
    local bs   = opts.buttonSize or (Frame and Frame.ButtonSize and Frame.ButtonSize()) or 37
    local gap  = opts.gap        or (Frame and Frame.Gap        and Frame.Gap())        or 4
    local gd   = (Frame and Frame.GridDims) and Frame.GridDims(#Bank.BuildBankEntries(owner), cols, bs, gap)
                 or { width = cols * bs + (cols - 1) * gap, height = 0 }
    return { width = gd.width, height = gd.height }
end

-- Full bank window size (content + chrome). Never zero (zero-frame audit).
function Bank.ComputeWindowSize(owner, opts)
    local content = Bank.ComputeContentSize(owner, opts)
    local w = content.width + Bank.PAD * 2
    local h = Bank.TITLE_H
            + Bank.PAD
            + Bank.STRIP_H + Bank.VGAP
            + math.max(content.height, 1) + Bank.VGAP
            + Bank.FOOTER_H
            + Bank.PAD
    return { width = w, height = h }
end

-- Window title: "<Character> · Bank". The possessive is dropped to match the inventory
-- window's name-first treatment; the role word is kept because, unlike the inventory,
-- this window is not identifiable from its contents alone. Blank/nil -> "Bank".
function Bank.WindowTitle(name)
    if type(name) == "string" and name ~= "" then return name .. " \194\183 Bank" end
    return "Bank"
end

-- Free / total bank slot counts for the bottom-bar "N/M" counter (mirrors the inventory
-- SlotCount, over the bank containers). Pure: reads the store snapshot, so it works for a
-- cached bank view too. total = Σ size; free = empty slots.
function Bank.SlotCounts(owner)
    local free, total = 0, 0
    if owner and type(owner.containers) == "table" then
        for _, cid in ipairs(Bank.BankContainerOrder(owner)) do
            local c = owner.containers[cid]
            if c then
                local size = c.size or 0
                total = total + size
                for s = 1, size do if not (c.slots and c.slots[s]) then free = free + 1 end end
            end
        end
    end
    return free, total
end

-- =====================================================================
-- FRAME LAYER (in-game only; guarded on _G.CreateFrame)
-- =====================================================================

local UI
local WINDOW_NAME = "DaseekiBags2BankWindow"

Bank._live = false   -- true while the bank frame is actually open (interactive)

local function moneyString(copper)
    if _G.GetCoinTextureString then return _G.GetCoinTextureString(copper or 0) end
    local g, s, c = Store.MoneyParts(copper or 0)
    return string.format("%dg %ds %dc", g, s, c)
end

-- Which owner record the bank grid renders, and whether it is live-interactive.
-- Returns renderOwner, live, isSelf, viewedOwner.
local function bankRenderModel()
    local Frame = ns.Frame
    local viewed = Frame and Frame.ViewedOwner and Frame.ViewedOwner()
    if not viewed then return nil, false, false, nil end
    local selfKey = ns.Owner and ns.Owner.SelfKey and ns.Owner.SelfKey()
    local isSelf  = (viewed.nameRealm ~= nil and viewed.nameRealm == selfKey)
    if isSelf and Bank._live then
        return viewed, true, true, viewed          -- live secure bank buttons at the bank
    end
    if isSelf then
        return Bank.CachedView(viewed), false, true, viewed   -- self, away -> read-only cached
    end
    return viewed, false, false, viewed            -- alt / summary -> already read-only
end

-- The cross-character gold tooltip (D1 sacred). Delegates WHOLLY to the one money model
-- (Frame.RenderMoneyTooltip, defined in ui_owner.lua) so the bank and inventory windows
-- read identically — this file contributes no lines of its own.
--
-- ── 1.x facts behind this function (verified on branch main) ──────────────────
-- ANCHOR_TOP: 1.x's money widget family is the ONLY one that ignores the generic
-- left/right-by-screen-side anchor — PlayerMoney:GetTipAnchor returns a fixed
-- ANCHOR_TOP (core/classes/playerMoney.lua), so the money tip rises above the bar.
-- The bank's money widget subclasses PlayerMoney and does NOT override GetTipAnchor,
-- so BOTH surfaces anchor ANCHOR_TOP. This matches the inventory window's OnEnter.
--
-- NO Deposit/Withdraw hints: 1.x's bank-side warband widget (which is what carries the
-- "Warband Money" + Deposit/Withdraw hint tooltip) hard-returns at file scope unless
-- C_Bank.FetchDepositedMoney exists. This addon targets Classic Era (## Interface
-- 11507-11509), which has no C_Bank at all — so on our client 1.x's bank money frame
-- falls back to the plain PlayerMoney widget: the full cross-character tooltip, no
-- warband line, and NO hint lines. Matching that is exactly "same as the inventory",
-- which is why nothing bank-specific is added below.
function Bank.ShowMoneyTooltip(GT, anchor)
    if not GT then return end
    GT:SetOwner(anchor, "ANCHOR_TOP")
    local render = ns.Frame and ns.Frame.RenderMoneyTooltip
    if render then render(GT) end
end

-- Coin pickup on the BANK money bar (audit §4.5). 1.x fact: the coin-pickup click lives on
-- the PlayerMoney widget itself (OpenCoinPickupFrame on the gold/silver/copper sub-buttons,
-- suppressed only for a cached view) — and since our client resolves the bank's money frame
-- to that very widget (see the C_Bank note above), 1.x DOES offer pickup on the bank's money
-- bar. The bank window is the surface where pickup is legal, so it gets the same click the
-- inventory bar has.
--
-- The DECISION is not re-implemented here: it comes from the one harness-locked pure model,
-- Frame.MoneyClickAction (bank-only · self-only · combat-guarded). Only the pickup dialog's
-- anchor differs — it hangs off the BANK window's money frame, not the inventory's, which is
-- why this does not simply call Frame.OnMoneyClick.
function Bank.OnMoneyClick()
    local Frame = ns.Frame
    if not (Frame and Frame.MoneyClickAction) then return end
    local inCombat  = (_G.InCombatLockdown and _G.InCombatLockdown()) and true or false
    local isSelf    = (Frame.ViewedOwnerKey and Frame.SelfKey
                       and Frame.ViewedOwnerKey() == Frame.SelfKey()) and true or false
    local atBank    = (_G.BankFrame and _G.BankFrame.IsShown and _G.BankFrame:IsShown()) and true or false
    local hasPickup = (_G.OpenCoinPickupFrame ~= nil)
    local action = Frame.MoneyClickAction({ inCombat = inCombat, isSelf = isSelf,
                                            atBank = atBank, hasPickup = hasPickup })
    if action == "combat" then
        if ns.Print then ns:Print("Can't move money in combat.") end
        return
    end
    if action ~= "pickup" then return end   -- alt view / away from the bank / unsupported
    local amount = (_G.GetMoney and _G.GetMoney()) or 0
    local mf = Bank.window and Bank.window.money
    if ns.SafeCall then ns:SafeCall(_G.OpenCoinPickupFrame, amount, mf, _G.UIParent)
    else _G.OpenCoinPickupFrame(amount, mf, _G.UIParent) end
end

----------------------------------------------------------------------
-- Window construction
----------------------------------------------------------------------

function Bank.Ensure()
    if Bank.window then return Bank.window end
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end

    local PAD, TITLE_H = Bank.PAD, Bank.TITLE_H

    local win = _G.CreateFrame("Frame", WINDOW_NAME, _G.UIParent, "BackdropTemplate")
    do local sz = Bank.ComputeWindowSize(nil, {}); win:SetSize(sz.width, sz.height) end
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:SetUserPlaced(true)
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        -- 1.0 PARITY (opacity): near-solid dark ground (Bags-side alpha; sibling of inventory).
        self:SetBackdropColor(UI.Color("ground", (ns.Frame and ns.Frame.WINDOW_BG_ALPHA) or 0.94))
        self:SetBackdropBorderColor(UI.Color("border"))
    end)
    if UI.PaintLedgerGround then UI.PaintLedgerGround(win) end
    if _G.UISpecialFrames then table.insert(_G.UISpecialFrames, WINDOW_NAME) end

    -- ── Title bar (drag to move) ──────────────────────────────────────────────
    local titleBar = _G.CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLE_H)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing() end)
    titleBar:SetScript("OnMouseUp", function(_, mb)
        if mb == "RightButton" and ns.Frame and ns.Frame.SetLayout then
            ns.Frame.SetLayout(ns.Frame.Layout() == "split" and "combined" or "split")
        end
    end)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbBg:SetPoint("TOPLEFT", titleBar, "TOPLEFT", 1, -1)
    tbBg:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -1, 0)
    UI.Skin(tbBg, function(self) self:SetColorTexture(UI.Color("panel")) end)

    -- Maker's mark — the ONE diamond on the bank window (its own, per BRAND_SPEC §5).
    local mark
    if UI.MakerMark then
        mark = UI.MakerMark(titleBar, { size = 16 })
        mark:SetPoint("LEFT", titleBar, "LEFT", 7, 0)
    end
    -- Gold "<Character> · Bank". Same header treatment as the inventory window: the
    -- possessive is dropped and the face moves off the ceremonial MORPHEUS smallcaps onto
    -- UI.fonts.header (the user's picked face). The role word STAYS here — unlike the
    -- inventory, this window is not self-evident from its contents, and the two windows
    -- are open side by side at the bank. Text filled per viewed owner in Rebuild.
    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.header or UI.fonts.body)
    if mark then title:SetPoint("LEFT", mark, "RIGHT", 7, 0)
    else         title:SetPoint("LEFT", titleBar, "LEFT", 9, 0) end
    title:SetText(Bank.WindowTitle(nil))
    UI.Skin(title, function(self) self:SetTextColor(UI.Color("warn")) end)   -- gold title (1.0)
    win.title = title

    -- (The OWNER SELECTOR used to sit here, right of the gold title, at its full 150px
    -- name-and-caret width. The footer round moved it to the window's bottom-left corner
    -- in the same 22px glyph form the inventory window uses — see the footer block below.
    -- Nothing about the widget changed; the bank's own title already names the character,
    -- so the name column it used to carry was saying the same thing twice.)

    -- Offline "Updated …" stamp (shown when the viewed bank is a cached snapshot).
    local stamp = titleBar:CreateFontString(nil, "OVERLAY")
    stamp:SetFontObject(UI.fonts.small)
    -- Clear of the title-row controls: 8 edge + 22 close + 8 + 22 gear = 60, plus air.
    stamp:SetPoint("RIGHT", titleBar, "RIGHT", -68, 0)
    UI.Skin(stamp, function(self) self:SetTextColor(UI.Color("muted")) end)
    win.stamp = stamp

    -- Close: the same owned ✕ mask + hover behaviour as the inventory window and the
    -- Nexus dashboard (22x22, glyph inset 2px, `muted` at rest -> `danger` on hover, and
    -- `_hot` stashed so a ThemeChanged re-skin under a parked cursor keeps the hover).
    -- The metrics are read off ns.Frame so the two title rows can never drift apart.
    local F = ns.Frame
    local ICONBTN = (F and F.ICONBTN) or 22
    local INSET   = (F and F.ICON_INSET) or 2
    local SPACE   = (F and F.ICON_SPACE) or 8
    local closeBtn = _G.CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    closeBtn:SetSize(ICONBTN, ICONBTN)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -SPACE, 0)
    local cx = closeBtn:CreateTexture(nil, "ARTWORK")
    cx:SetPoint("TOPLEFT", closeBtn, "TOPLEFT", INSET, -INSET)
    cx:SetPoint("BOTTOMRIGHT", closeBtn, "BOTTOMRIGHT", -INSET, INSET)
    cx:SetTexture(((F and F.ART) or ("Interface\\AddOns\\" .. tostring(ADDON) .. "\\art\\")) .. "icon-close")
    closeBtn._face = cx
    UI.Skin(closeBtn, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
        self._face:SetVertexColor(UI.Color(self._hot and "danger" or "muted"))
    end)
    closeBtn:SetScript("OnEnter", function(self) self._hot = true;  self._face:SetVertexColor(UI.Color("danger")) end)
    closeBtn:SetScript("OnLeave", function(self) self._hot = nil;   self._face:SetVertexColor(UI.Color("muted"))  end)
    closeBtn:SetScript("OnClick", function() Bank.Close() end)
    win.closeBtn = closeBtn

    -- Settings gear, left of the ✕ — same pair, same order as the inventory window and
    -- the Nexus dashboard. Hovers `accent` (not `danger`) and keeps a tooltip, because a
    -- cog is ambiguous where a ✕ is not.
    local gearBtn = _G.CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    gearBtn:SetSize(ICONBTN, ICONBTN)
    gearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -SPACE, 0)
    local gx = gearBtn:CreateTexture(nil, "ARTWORK")
    gx:SetPoint("TOPLEFT", gearBtn, "TOPLEFT", INSET, -INSET)
    gx:SetPoint("BOTTOMRIGHT", gearBtn, "BOTTOMRIGHT", -INSET, INSET)
    gx:SetTexture(((F and F.ART) or ("Interface\\AddOns\\" .. tostring(ADDON) .. "\\art\\")) .. "icon-gear")
    gearBtn._face = gx
    UI.Skin(gearBtn, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("borderLite"))
        self._face:SetVertexColor(UI.Color(self._hot and "accent" or "muted"))
    end)
    gearBtn:SetScript("OnEnter", function(self)
        self._hot = true
        self._face:SetVertexColor(UI.Color("accent"))
        if _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            _G.GameTooltip:SetText("Bag settings", UI.Color("text"))
            _G.GameTooltip:Show()
        end
    end)
    gearBtn:SetScript("OnLeave", function(self)
        self._hot = nil
        self._face:SetVertexColor(UI.Color("muted"))
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    gearBtn:SetScript("OnClick", function()
        local S = _G.DaseekiSuite
        if S then
            if     S.OpenTo then S:OpenTo("bags")
            elseif S.Open   then S:Open("bags")
            elseif S.Toggle then S:Toggle("bags") end
        end
    end)
    win.gearBtn = gearBtn

    -- One entry-head hairline under the titlebar (§3).
    local titleRule
    if UI.Hairline then titleRule = UI.Hairline(win, { token = "borderLite", layer = "ARTWORK" })
    else titleRule = win:CreateTexture(nil, "ARTWORK"); titleRule:SetHeight(1)
         UI.Skin(titleRule, function(self) self:SetColorTexture(UI.Color("borderLite")) end) end
    titleRule:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -TITLE_H)
    titleRule:SetPoint("TOPRIGHT", win, "TOPRIGHT", -1, -TITLE_H)

    -- ── Bank-bag purchase / toggle strip ──────────────────────────────────────
    local strip = _G.CreateFrame("Frame", nil, win)
    strip:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, -(TITLE_H + PAD))
    strip:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, -(TITLE_H + PAD))
    strip:SetHeight(Bank.STRIP_H)
    win.strip = strip
    win._stripCells = {}

    -- Sort button (bank cids; needsBank). Right-pinned in the strip row.
    --
    -- DUAL-PURPOSE, exactly like the inventory window's sort glyph (ui_frame's
    -- Frame.SortClickAction is the ONE seam that decides which click means what, so the
    -- two windows can never disagree): left-click sorts the bank, RIGHT-click opens the
    -- lock config mode. Bank slots are lockable too — they are containers the sort
    -- engine moves items in — so the affordance has to exist on the window the owner is
    -- actually looking at when he is at the bank.
    local sortBtn = UI.MakeButton(strip, {
        text = "Sort", width = 52,
        onClick = function(_, button)
            if ns.Frame and ns.Frame.SortClickAction
               and ns.Frame.SortClickAction(button) == "locks" then
                if ns.Frame.ToggleLockMode then ns.Frame.ToggleLockMode() end
                return
            end
            Bank.SortBank()
        end,
    })
    if sortBtn.RegisterForClicks then sortBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    sortBtn:SetPoint("RIGHT", strip, "RIGHT", 0, 0)
    win.sortBtn = sortBtn

    -- ── Content host (the bank grid) ──────────────────────────────────────────
    local content = _G.CreateFrame("Frame", nil, win)
    content:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -Bank.VGAP)
    content:SetSize(1, 1)
    win.content = content

    -- Empty-state copy (BRAND_SPEC §6 plain copy).
    local empty = content:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(UI.fonts.muted)
    empty:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -4)
    empty:SetText("No bank data recorded for this character.")
    empty:Hide()
    win.emptyFS = empty

    -- ── FOOTER ROW (sibling of the inventory footer, same three zones) ────────
    -- controls LEFT · free/total CENTRE · money RIGHT, all anchored INSIDE this band so
    -- they share one baseline. Built from Bank.FOOTER_H, which matches Frame.FOOTER_H.
    local footer = _G.CreateFrame("Frame", nil, win)
    footer:SetPoint("BOTTOMLEFT",  win, "BOTTOMLEFT",   PAD, PAD)
    footer:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -PAD, PAD)
    footer:SetHeight(Bank.FOOTER_H)
    -- Float the band above the grid's frame-level stack (see the inventory footer note).
    footer:SetFrameLevel((win:GetFrameLevel() or 1) + 10)
    win.footer = footer

    -- Owner selector (shared viewed-owner; flipping it re-renders both windows), MOVED
    -- here from the title row so the bank matches the inventory window corner for corner.
    -- Dressed by the inventory's own Frame.DressSelectorAsGlyph, so the two windows
    -- cannot end up wearing different treatments of the same widget; the guard keeps the
    -- widget in its default name-and-caret form if ui_frame is somehow not loaded.
    if ns.Owner and ns.Owner.CreateSelector then
        local F2 = ns.Frame
        local sel = ns.Owner.CreateSelector(footer, {
            width = (F2 and F2.ICONBTN) or 22,
            menuGrow = "up",
            onSelect = function(key)
                if ns.Frame and ns.Frame.SetViewedOwner then ns.Frame.SetViewedOwner(key) end
            end,
        })
        if sel then
            sel:ClearAllPoints()
            sel:SetPoint("LEFT", footer, "LEFT", 0, 0)
            sel:SetSize((F2 and F2.ICONBTN) or 22, (F2 and F2.ICONBTN) or 22)
            if F2 and F2.DressSelectorAsGlyph then F2.DressSelectorAsGlyph(sel, UI) end
            win.ownerSelector = sel
        end
    end
    -- (The decorative backpack glyph that used to sit in this corner is GONE. It was
    -- ornament in the one footer position that is now a control, and the inventory
    -- window retired its own corner glyph for the same reason a round earlier.)

    -- ── Money bar (bank char's gold; cross-account total on hover) ────────────
    local money = _G.CreateFrame("Button", nil, footer)
    money:SetSize(160, Bank.FOOTER_H)
    -- Same right-edge allowance as the inventory money strip (Frame.MONEY_EDGE_INSET):
    -- GetCoinTextureString draws each coin 2px right of the width it measures, so the
    -- trailing coin used to paint onto the window's keyline. Read off ns.Frame so the two
    -- windows can never disagree about the inset.
    money:SetPoint("RIGHT", footer, "RIGHT", -((ns.Frame and ns.Frame.MONEY_EDGE_INSET) or 6), 0)
    -- Defensive mouse wiring, mirrored from the inventory money bar: explicitly enable mouse
    -- and float the bar ABOVE the content grid's frame-level stack so a hover always lands on
    -- it (the owner reported the inventory gold hover doing nothing before this was added; the
    -- bank grid stacks the same way, so the same assertion belongs here).
    money:EnableMouse(true)
    money:SetFrameLevel((win:GetFrameLevel() or 1) + 10)
    local moneyFS = money:CreateFontString(nil, "OVERLAY")
    moneyFS:SetFontObject(UI.fonts.numeral or UI.fonts.body)
    moneyFS:SetPoint("RIGHT", money, "RIGHT", 0, 0)
    moneyFS:SetJustifyH("RIGHT")
    UI.Skin(moneyFS, function(self) self:SetTextColor(UI.Color("text")) end)
    money:SetScript("OnEnter", function(self) Bank.ShowMoneyTooltip(_G.GameTooltip, self) end)
    money:SetScript("OnLeave", function() _G.GameTooltip:Hide() end)
    -- Coin pickup: left-click to pick up coins — self-only, combat-guarded, and only while
    -- actually at the bank (all decided by Frame.MoneyClickAction via Bank.OnMoneyClick).
    money:RegisterForClicks("LeftButtonUp")
    money:SetScript("OnClick", function() Bank.OnMoneyClick() end)
    win.money, win.moneyFS = money, moneyFS

    -- Free/total bank-slot counter, footer CENTRE (sibling of the inventory SlotCount).
    local slotCount = footer:CreateFontString(nil, "OVERLAY")
    slotCount:SetFontObject(UI.fonts.numeral or UI.fonts.body)
    slotCount:SetPoint("CENTER", footer, "CENTER", 0, 0)
    slotCount:SetJustifyH("CENTER")
    UI.Skin(slotCount, function(self) self:SetTextColor(UI.Color("muted")) end)
    win.slotCount = slotCount

    win._group = nil   -- pooled ns.Items group (built on first Rebuild)
    Bank.window = win

    -- LOCK CONFIG MODE: closing this window leaves the mode, exactly as closing the
    -- inventory window does. The mode suspends normal item interaction on every live
    -- cell, so it must never survive the window that explains it. ui_frame owns both the
    -- state transition and the notice card; this is only the exit trigger.
    win:SetScript("OnHide", function()
        if ns.Frame and ns.Frame.SetLockMode then ns.Frame.SetLockMode(false) end
    end)

    Bank.ApplyScale()

    -- Anchor the bank window offset from the inventory window if that exists, else centered.
    win:ClearAllPoints()
    win:SetPoint("CENTER", _G.UIParent, "CENTER", 260, 0)
    return win
end

-- Window scale. The bank deliberately has NO scale setting of its own: it reads the one
-- shared db.scale through ns.Frame, so the two windows are always the same size side by
-- side (they sit next to each other at the bank, where a mismatch would be obvious).
-- Called from Ensure and re-called by Frame.RefreshScale when the slider moves.
function Bank.ApplyScale()
    local win = Bank.window
    if not win or not win.SetScale then return end
    local s = (ns.Frame and ns.Frame.Scale and ns.Frame.Scale()) or 1
    win:SetScale(s)
end

----------------------------------------------------------------------
-- Purchase strip
----------------------------------------------------------------------

-- Live purchased-count / next-cost readers (guarded).
local function numBankBagsPurchased()
    if _G.GetNumBankSlots then return (_G.GetNumBankSlots()) or 0 end
    return 0
end
local function nextBankSlotCost()
    if _G.GetBankSlotCost then return (_G.GetBankSlotCost()) or 0 end
    return 0
end

-- Raise the gold-confirm and buy the next slot (only its accept spends gold; combat-gated).
function Bank.BuyNextSlot()
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        if ns.Print then ns:Print("can't buy a bank slot in combat.") end
        return
    end
    local cost = nextBankSlotCost()
    UI.Confirm({
        title = "Buy Bank Bag Slot",
        text  = "Purchase this bank bag slot for " .. moneyString(cost) .. "?",
        acceptText = "Buy",
        onAccept = function()
            if _G.InCombatLockdown and _G.InCombatLockdown() then return end
            if _G.PurchaseSlot then _G.PurchaseSlot() end
        end,
    })
end

-- Rebuild the purchase/toggle strip. Purchase controls appear only AT the bank
-- (self + live); otherwise the strip is hidden (no stale cost away from the banker).
function Bank.RebuildStrip(renderModelLive, isSelf)
    local win = Bank.window
    if not win or not UI then return end
    for _, c in ipairs(win._stripCells) do c:Hide() end

    if not (renderModelLive and isSelf) then
        win.strip:Hide()
        return
    end
    win.strip:Show()

    local purchased = numBankBagsPurchased()
    local states = Bank.PurchaseState(purchased, Store.NumBankBagSlots())
    local SIZE, GAP, x = Bank.STRIP_H, 4, 0
    for i, s in ipairs(states) do
        local cell = win._stripCells[i]
        if not cell then
            cell = _G.CreateFrame("Button", nil, win.strip, "BackdropTemplate")
            cell:SetSize(SIZE, SIZE)
            -- Equipped bank-bag ICON (R3 design point 2): a PURCHASED bank-bag cell shows
            -- the equipped bag's item texture (trimmed to the suite icon treatment). Under
            -- the number; hidden for buyable/locked/empty cells. Pure insecure-child art.
            local icon = cell:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("TOPLEFT", cell, "TOPLEFT", 2, -2)
            icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -2, 2)
            local t = (ns.Frame and ns.Frame.STRIP_ICON_TRIM) or 0.08
            icon:SetTexCoord(t, 1 - t, t, 1 - t)
            icon:Hide()
            cell._icon = icon
            local fs = cell:CreateFontString(nil, "OVERLAY")
            fs:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
            fs:SetPoint("CENTER", cell, "CENTER", 0, 0)
            cell._fs = fs
            win._stripCells[i] = cell
        end
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", win.strip, "LEFT", x, 0)
        x = x + SIZE + GAP
        cell:SetBackdrop(UI.FLAT_BACKDROP)
        if s.state == "purchased" then
            cell:SetBackdropColor(UI.Color("raised"))
            cell:SetBackdropBorderColor(UI.Color("border"))
            cell._fs:SetText(tostring(s.index))
            cell._fs:SetTextColor(UI.Color("text"))
            -- Show the equipped bank bag's icon (its mapped inventory slot). Falls back
            -- to the index number if the texture can't be resolved.
            local CC = _G.C_Container
            local invSlot = (CC and CC.ContainerIDToInventoryID and CC.ContainerIDToInventoryID(s.cid))
                         or (_G.ContainerIDToInventoryID and _G.ContainerIDToInventoryID(s.cid))
            local tex = invSlot and _G.GetInventoryItemTexture and _G.GetInventoryItemTexture("player", invSlot)
            if tex then
                cell._icon:SetTexture(tex)
                if cell._icon.SetDesaturated then cell._icon:SetDesaturated(false) end
                cell._icon:SetAlpha(1.0)
                cell._icon:Show()
                cell._fs:Hide()
            else
                cell._icon:Hide()
                cell._fs:Show()
            end
            cell:SetScript("OnEnter", nil)
            cell:SetScript("OnClick", nil)
        elseif s.state == "buyable" then
            cell._icon:Hide(); cell._fs:Show()
            cell:SetBackdropColor(UI.Color("control"))
            cell:SetBackdropBorderColor(UI.Color("bronze"))   -- the one bronze "buy" well
            cell._fs:SetText("+")
            cell._fs:SetTextColor(UI.Color("bronze"))
            cell:SetScript("OnEnter", function(self)
                local GT = _G.GameTooltip; if not GT then return end
                GT:SetOwner(self, "ANCHOR_RIGHT")
                GT:AddLine("Buy bank bag slot", UI.Color("text"))
                GT:AddLine(moneyString(nextBankSlotCost()), 1, 1, 1)
                GT:Show()
            end)
            cell:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
            cell:SetScript("OnClick", function() Bank.BuyNextSlot() end)
        else -- locked
            cell:SetBackdropColor(UI.Color("inset"))
            cell:SetBackdropBorderColor(UI.Color("controlBorder"))
            cell._icon:Hide(); cell._fs:Show()
            cell._fs:SetText("")
            cell:SetScript("OnEnter", nil)
            cell:SetScript("OnClick", nil)
        end
        cell:Show()
    end
end

----------------------------------------------------------------------
-- Sort (bank container set; needsBank so the executor guards bank-open + combat)
----------------------------------------------------------------------

function Bank.SortBank()
    if not (ns.Sort and ns.Sort.Run) then return end
    if not Bank._live then
        if ns.Print then ns:Print("open the bank to sort it.") end
        return
    end
    local selfKey = ns.Owner and ns.Owner.SelfKey and ns.Owner.SelfKey()
    local selfOwner = selfKey and Store.GetOwner(selfKey)
    local ids = Bank.BankContainerOrder(selfOwner)
    if #ids == 0 then return end
    ns.Sort.Run(ids, { needsBank = true })
end

----------------------------------------------------------------------
-- Repaint
----------------------------------------------------------------------

function Bank.Rebuild()
    local win = Bank.window
    if not win or not UI then return end
    local Frame = ns.Frame
    local renderOwner, live, isSelf, viewed = bankRenderModel()

    -- Owner selector face. MUST be a COLON call: ui_owner defines it as `function frame:Refresh()`
    -- and the body dereferences self._name / self._pip, so a dot call passes self = nil and hard
    -- errors. Bank.Open calls Bank.Rebuild UNPROTECTED, so that error aborted the repaint before
    -- the title, money and grid were ever painted — the bank window came up blank.
    if win.ownerSelector and win.ownerSelector.Refresh then win.ownerSelector:Refresh() end

    -- Gold "<Character> · Bank" for the VIEWED owner (see Bank.WindowTitle).
    if win.title then
        local nm = viewed and viewed.name
        if not nm then
            local key = Frame and Frame.ViewedOwnerKey and Frame.ViewedOwnerKey()
            nm = (key and Store.SplitNameRealm and Store.SplitNameRealm(key)) or nil
        end
        win.title:SetText(Bank.WindowTitle(nm))
    end

    -- money (viewed owner). The "Show money bar" toggle (audit §9.4) is honored here exactly as
    -- the inventory window honors it, off the SAME predicate — 1.x carries one per-frame `money`
    -- profile flag that both its inventory and bank frames read, so one option must govern both
    -- surfaces. The bottom band stays either way (it also holds the slot counter).
    if win.money then
        local shown = not (Frame and Frame.MoneyShown) or Frame.MoneyShown()
        win.money:SetShown(shown and true or false)
    end
    if win.moneyFS then win.moneyFS:SetText(moneyString(viewed and viewed.money or 0)) end

    -- free/total bank-slot counter, bottom-center (sibling of the inventory SlotCount)
    if win.slotCount then
        local free, total = Bank.SlotCounts(viewed)
        win.slotCount:SetText(free .. "/" .. total)
    end

    -- offline stamp: shown when this is a cached view (not live self at the bank)
    if win.stamp then
        if live then
            win.stamp:SetText("")
        elseif viewed then
            local age = viewed.containers and Store.ContainerAge(viewed, Store.BANK_CONTAINER)
                        or (viewed.ts and viewed.ts > 0 and (Store.Now() - viewed.ts) or nil)
            local selfKey = ns.Owner and ns.Owner.SelfKey and ns.Owner.SelfKey()
            win.stamp:SetText(ns.Owner and ns.Owner.FreshnessLabel(age, viewed.nameRealm == selfKey and live) or "")
        else
            win.stamp:SetText("")
        end
    end

    Bank.RebuildStrip(live, isSelf)

    -- grid
    local opts = { columns = Frame and Frame.Columns and Frame.Columns() or 12,
                   buttonSize = Frame and Frame.ButtonSize and Frame.ButtonSize() or 37,
                   gap = Frame and Frame.Gap and Frame.Gap() or 4 }
    local hasBank = Bank.HasBankData(viewed)
    if win.emptyFS then win.emptyFS:SetShown(not hasBank) end

    local content = Bank.ComputeContentSize(renderOwner, opts)
    win.content:SetSize(math.max(content.width, 1), math.max(content.height, 1))

    if ns.Items and ns.Items.CreateGroup then
        if not win._group then win._group = ns.Items.CreateGroup(win.content) end
        local g = win._group
        g:SetGrid(opts.columns, opts.buttonSize, opts.gap)
        g:ClearAllPoints()
        g:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, 0)
        if hasBank then
            g:ShowSlots(Bank.BuildBankEntries(renderOwner))
            if g.Show then g:Show() end
        else
            g:Clear(); if g.Hide then g:Hide() end
        end
    end

    -- sort button only enabled at the bank (self, live)
    if win.sortBtn then
        local on = live and isSelf
        if win.sortBtn.SetEnabled then win.sortBtn:SetEnabled(on) end
        win.sortBtn:SetAlpha(on and 1 or 0.4)
    end

    local sz = Bank.ComputeWindowSize(renderOwner, opts)
    win:SetSize(sz.width, sz.height)

    if ns.Search and ns.Search.Reapply then ns.Search.Reapply() end
end

----------------------------------------------------------------------
-- Show / hide / lifecycle
----------------------------------------------------------------------

function Bank.Open()
    local win = Bank.Ensure()
    if not win then return end
    Bank.Rebuild()
    win:Show()
end

function Bank.Close()
    if Bank.window then Bank.window:Hide() end
end

function Bank.Toggle()
    local win = Bank.Ensure()
    if not win then return end
    if win:IsShown() then Bank.Close() else Bank.Open() end
end

function Bank.IsShown()
    return Bank.window and Bank.window:IsShown() and true or false
end

-- Called by the owner selector (via Frame.SetViewedOwner) when the view changes.
function Bank.OnOwnerChanged()
    if Bank.IsShown() then Bank.RequestRefresh() end
end

Bank._refreshQueued = false
function Bank.RequestRefresh()
    if Bank._refreshQueued then return end
    Bank._refreshQueued = true
    local fire = function()
        Bank._refreshQueued = false
        if Bank.IsShown() then
            if ns.SafeCall then ns:SafeCall(Bank.Rebuild) else Bank.Rebuild() end
        end
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, fire) else fire() end
end

-- Self-registered login wiring (never touches core.lua). Mirrors features.lua.
function Bank.OnLogin()
    if not ns.RegisterEvent then return end
    ns:RegisterEvent("BANKFRAME_OPENED", function()
        Bank._live = true
        Bank.Open()                 -- open the bank window alongside the inventory window
    end)
    ns:RegisterEvent("BANKFRAME_CLOSED", function()
        Bank._live = false          -- flip to cached; capture.lua already snapshots on close
        Bank.RequestRefresh()       -- repaint read-only; BAGS_CAPTURED will refresh with fresh data
    end)
    -- Repaint when a capture lands (esp. the bank snapshot on open/close).
    if ns.On then ns:On("BAGS_CAPTURED", function() Bank.RequestRefresh() end) end
end

if ns.On then
    ns:On("LOGIN", function()
        if ns.SafeCall then ns:SafeCall(Bank.OnLogin) else Bank.OnLogin() end
    end)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_bank")
----------------------------------------------------------------------

local function makeOwner(containers, extra)
    local o = { source = "full", nameRealm = "Tester-TestRealm", name = "Tester",
                money = 0, containers = {}, equip = {}, itemCounts = {}, ts = 0 }
    for cid, spec in pairs(containers or {}) do
        local c = Store.NewContainer(spec.size or 0, spec.link)
        for slot, s in pairs(spec.slots or {}) do
            c.slots[slot] = Store.NewSlot(s.id, s.count, s.quality, s.link)
        end
        c.ts = spec.ts or 0
        o.containers[cid] = c
    end
    if extra then for k, v in pairs(extra) do o[k] = v end end
    return o
end

local function testBankContainerOrder(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- NumBagSlots=4, NumBankBagSlots=7 under the harness stub -> bank bags are cid 5..11.
    local o = makeOwner({
        [0]  = { size = 16 },                 -- backpack (ignored)
        [-1] = { size = 24 },                 -- bank main
        [5]  = { size = 16, link = "item:1" },-- bank bag (first)
        [7]  = { size = 12, link = "item:2" },-- bank bag (later)
        [-2] = { size = 12 },                 -- keyring (ignored)
    })
    local ids = Bank.BankContainerOrder(o)
    ck(#ids == 3, "3 bank containers (main + 2 bank bags)")
    ck(ids[1] == -1, "bank main first")
    ck(ids[2] == 5 and ids[3] == 7, "bank bags ascending after main")
    ck(Bank.HasBankData(o) == true, "owner with bank -> hasBank")
    ck(Bank.HasBankData(makeOwner({ [0] = { size = 16 }, [-2] = { size = 12 } })) == false,
        "carried/keyring only -> no bank")
    ck(Bank.BankBagCID(1) == 5 and Bank.BankBagCID(7) == 11, "strip index -> cid mapping")
end

local function testPurchaseStateMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- none purchased: slot 1 buyable, 2..7 locked
    local s0 = Bank.PurchaseState(0, 7)
    ck(#s0 == 7, "7 strip cells")
    ck(s0[1].state == "buyable", "first slot buyable when none owned")
    ck(s0[2].state == "locked" and s0[7].state == "locked", "rest locked")
    ck(s0[1].cid == 5, "cell 1 maps to bank bag cid 5")
    -- three purchased: 1..3 purchased, 4 buyable, 5..7 locked
    local s3 = Bank.PurchaseState(3, 7)
    ck(s3[1].state == "purchased" and s3[3].state == "purchased", "owned slots purchased")
    ck(s3[4].state == "buyable", "next slot buyable")
    ck(s3[5].state == "locked" and s3[7].state == "locked", "beyond-next locked")
    -- full: all purchased, nothing buyable
    local s7 = Bank.PurchaseState(7, 7)
    for i = 1, 7 do ck(s7[i].state == "purchased", "full bank slot " .. i .. " purchased") end
    local anyBuyable = false
    for _, s in ipairs(s7) do if s.state == "buyable" then anyBuyable = true end end
    ck(not anyBuyable, "full bank -> nothing buyable")
    -- clamp / defaults
    ck(#Bank.PurchaseState(0, 0) == 0, "zero slots -> empty")
    ck(Bank.PurchaseState(-3, 3)[1].state == "buyable", "negative purchased clamps to 0")
end

local function testCachedViewProxy(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local real = makeOwner({ [-1] = { size = 24, slots = { [1] = { id = 4306, count = 20 } } } },
        { source = "full", nameRealm = "Tester-TestRealm", class = "MAGE", money = 500 })
    local proxy = Bank.CachedView(real)
    ck(proxy.source == "summary", "proxy demotes source to summary (render-only)")
    ck(proxy.nameRealm == "Tester-TestRealm", "proxy reads through nameRealm")
    ck(proxy.class == "MAGE" and proxy.money == 500, "proxy reads through identity/money")
    ck(proxy.containers[-1].slots[1].id == 4306, "proxy shares the real containers")
    -- Items.IsLive must reject the proxy even though the real owner would be live-eligible.
    if ns.Items and ns.Items.SetSelf then
        local savedSelf = ns.Items._self          -- restore so later suites aren't affected
        ns.Items.SetSelf("Tester-TestRealm")
        ck(ns.Items.IsLive(real) == true, "real self owner is live-eligible")
        ck(ns.Items.IsLive(proxy) == false, "cached proxy is NOT live (renders read-only)")
        ns.Items.SetSelf(savedSelf)
    end
end

local function testBankEntriesAndSizing(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = makeOwner({
        [-1] = { size = 4, slots = { [1] = { id = 4306, count = 20 } } },
        [5]  = { size = 2, link = "item:1", slots = { [1] = { id = 4338, count = 8 } } },
        [0]  = { size = 16, slots = { [1] = { id = 6948, count = 1 } } },  -- carried, must be excluded
    })
    local entries = Bank.BuildBankEntries(o)
    ck(#entries == 6, "bank entries = bank main (4) + bank bag (2), carried excluded")
    ck(entries[1].cid == -1 and entries[1].slot == 1, "first entry = bank main slot 1")
    ck(entries[5].cid == 5, "bank bag entries follow the bank main")
    for _, e in ipairs(entries) do ck(e.cid ~= 0, "no carried (cid 0) entry leaks into the bank") end
    -- sizing is never zero (zero-frame audit), even with no owner
    local wz = Bank.ComputeWindowSize(nil, { columns = 12, buttonSize = 37, gap = 4 })
    ck(wz.width > 0 and wz.height > 0, "empty bank window is non-zero")
    local wz2 = Bank.ComputeWindowSize(o, { columns = 12, buttonSize = 37, gap = 4 })
    ck(wz2.height >= wz.height, "populated bank at least as tall as empty")
end

-- FOOTER ROUND: the bank's bottom band is the inventory footer's sibling — same height,
-- same three zones, same money edge allowance, and it now carries the owner selector in
-- the bottom-left corner. Pinned here because the two windows drifting apart on any of
-- those is exactly the class of defect the owner keeps having to screenshot.
local function testBankFooterParity(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local F = ns.Frame
    ck(F ~= nil, "ui_frame is loaded (the bank reads its footer metrics)")
    if not F then return end
    ck(Bank.FOOTER_H == F.FOOTER_H,
        "bank footer band (" .. tostring(Bank.FOOTER_H) .. ") = inventory footer band (" .. tostring(F.FOOTER_H) .. ")")
    ck(Bank.FOOTER_H == F.ICONBTN, "the bank footer is one control tall, so its row shares a baseline")
    ck(Bank.PAD == F.PAD, "both windows inset their footer by the same padding")
    ck(Bank.MONEY_H == nil, "the money-only band metric is gone on the bank too")
    -- The dressing helper the bank calls must exist on ns.Frame; without it the bank's
    -- selector silently reverts to the 150px name form and the two footers diverge.
    ck(type(F.DressSelectorAsGlyph) == "function", "the shared selector dressing helper is published")
    ck(type(F.MoneyRightInset) == "function" and F.MoneyRightInset() > F.PAD,
        "the shared money edge allowance is published and larger than the plain padding")
    -- The band must still be accounted for in the window height (a footer nobody measured
    -- is a footer that overlaps the last grid row).
    local tall = Bank.ComputeWindowSize(nil, { columns = 12, buttonSize = 37, gap = 4 }).height
    ck(tall > Bank.TITLE_H + Bank.STRIP_H + Bank.FOOTER_H, "the footer band is inside the window height")
end

-- 1.0-LOOK PARITY: bank title format + free/total counter (bottom-center sibling).
local function testBankTitleAndCounts(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Bank.WindowTitle("Daseeki") == "Daseeki \194\183 Bank", "title = <name> \194\183 Bank")
    ck(Bank.WindowTitle(nil) == "Bank", "nil name -> Bank")
    ck(Bank.WindowTitle("")  == "Bank", "blank name -> Bank")
    local o = makeOwner({
        [-1] = { size = 4, slots = { [1] = { id = 4306, count = 20 } } },
        [5]  = { size = 2, link = "item:1", slots = { [1] = { id = 4338, count = 8 } } },
        [0]  = { size = 16, slots = { [1] = { id = 6948, count = 1 } } },  -- carried, must be excluded
    })
    local free, total = Bank.SlotCounts(o)
    ck(total == 6, "bank slot total = bank main(4)+bank bag(2), carried excluded, got " .. total)
    ck(free == 4, "bank free = total - filled (4), got " .. free)
    ck(select(2, Bank.SlotCounts(nil)) == 0, "nil owner -> 0 total")
end

-- MONEY TOOLTIP (1.x parity): the bank money hover must anchor ANCHOR_TOP (1.x's money widget
-- family fixes that anchor and the bank widget inherits it), must delegate its whole content to
-- the ONE money model, and must add NO lines of its own — on Classic Era 1.x's bank money frame
-- resolves to the plain player-money widget, so there are no Deposit/Withdraw hints to match.
local function testMoneyTooltip(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Recording GameTooltip stub: captures the owner/anchor and every line the bank itself adds.
    local function newGT()
        local gt = { owner = nil, anchor = nil, lines = 0, shown = false }
        function gt:SetOwner(o, a) self.owner, self.anchor = o, a end
        function gt:ClearLines() self.lines = 0 end
        function gt:AddLine() self.lines = self.lines + 1 end
        function gt:AddDoubleLine() self.lines = self.lines + 1 end
        function gt:Show() self.shown = true end
        return gt
    end

    local Frame = ns.Frame
    local saved = Frame and Frame.RenderMoneyTooltip
    local rendered
    if Frame then Frame.RenderMoneyTooltip = function(gt) rendered = gt end end

    local anchorFrame = { tag = "bank money bar" }
    local gt = newGT()
    Bank.ShowMoneyTooltip(gt, anchorFrame)
    ck(gt.anchor == "ANCHOR_TOP", "bank money tip anchors ANCHOR_TOP (1.x), got " .. tostring(gt.anchor))
    ck(gt.owner == anchorFrame, "tip owned by the money bar it was hovered on")
    ck(rendered == gt, "content delegated to the one money model (Frame.RenderMoneyTooltip)")
    ck(gt.lines == 0, "bank adds NO lines of its own (no Deposit/Withdraw hint), got " .. gt.lines)

    -- No money model installed -> no divergent local fallback tooltip is painted.
    if Frame then Frame.RenderMoneyTooltip = nil end
    local gt2 = newGT()
    Bank.ShowMoneyTooltip(gt2, anchorFrame)
    ck(gt2.anchor == "ANCHOR_TOP", "anchor still ANCHOR_TOP without the model")
    ck(gt2.lines == 0 and gt2.shown == false,
        "no money model -> bank paints nothing (no non-1.x fallback), got " .. gt2.lines .. " line(s)")

    if Frame then Frame.RenderMoneyTooltip = saved end
    Bank.ShowMoneyTooltip(nil, anchorFrame)   -- must not error
end

-- MONEY CLICK: the bank money bar offers the coin pickup (1.x fact: pickup lives on the same
-- player-money widget our client resolves the bank's money frame to), gated by the ONE pure
-- decision Frame.MoneyClickAction — self-only, at-bank-only, combat-guarded.
local function testMoneyClick(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local Frame = ns.Frame
    if not (Frame and Frame.MoneyClickAction) then
        fails[#fails + 1] = "Frame.MoneyClickAction missing (the shared decision model)"
        return
    end

    local sVOK, sSK = Frame.ViewedOwnerKey, Frame.SelfKey
    local sBank, sPickup, sMoney, sCombat =
        _G.BankFrame, _G.OpenCoinPickupFrame, _G.GetMoney, _G.InCombatLockdown

    local picked
    _G.OpenCoinPickupFrame = function(amount) picked = amount end
    _G.GetMoney            = function() return 4321 end
    _G.InCombatLockdown    = function() return false end
    local atBank = true
    _G.BankFrame = { IsShown = function() return atBank end }
    Frame.ViewedOwnerKey = function() return "Tester-TestRealm" end
    Frame.SelfKey        = function() return "Tester-TestRealm" end

    picked = nil; Bank.OnMoneyClick()
    ck(picked == 4321, "at bank + self + out of combat -> coin pickup opens, got " .. tostring(picked))

    picked = nil; atBank = false; Bank.OnMoneyClick()
    ck(picked == nil, "away from the bank -> no pickup")
    atBank = true

    picked = nil
    Frame.ViewedOwnerKey = function() return "Alt-TestRealm" end
    Bank.OnMoneyClick()
    ck(picked == nil, "viewing an alt's cached money -> no pickup")
    Frame.ViewedOwnerKey = function() return "Tester-TestRealm" end

    picked = nil
    _G.InCombatLockdown = function() return true end
    Bank.OnMoneyClick()
    ck(picked == nil, "in combat -> no pickup")
    _G.InCombatLockdown = function() return false end

    picked = nil
    _G.OpenCoinPickupFrame = nil
    Bank.OnMoneyClick()   -- client without the pickup surface: must be a silent no-op, not an error
    ck(picked == nil, "no pickup surface -> silent no-op")

    Frame.ViewedOwnerKey, Frame.SelfKey = sVOK, sSK
    _G.BankFrame, _G.OpenCoinPickupFrame, _G.GetMoney, _G.InCombatLockdown =
        sBank, sPickup, sMoney, sCombat
end

function Bank.RunSelfTests(verbose)
    local suites = {
        { name = "bank container order",   fn = testBankContainerOrder },
        { name = "money tooltip (1.x)",    fn = testMoneyTooltip },
        { name = "money click (pickup)",   fn = testMoneyClick },
        { name = "title + slot counts",    fn = testBankTitleAndCounts },
        { name = "purchase-state matrix",  fn = testPurchaseStateMatrix },
        { name = "cached-view proxy",      fn = testCachedViewProxy },
        { name = "bank entries + sizing",  fn = testBankEntriesAndSizing },
        { name = "footer parity",          fn = testBankFooterParity },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_bank/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_bank/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_bank", Bank.RunSelfTests)
end

return Bank
