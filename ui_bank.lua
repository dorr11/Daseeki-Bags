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
-- Accept-cue alpha for a purchased bank-bag cell while a bag rides the cursor. Deliberately
-- softer than the inventory strip's 0.75 active-bag halo: this one is transient guidance,
-- not a standing state, and it must not shout over a strip of otherwise-calm wells.
Bank.ACCEPT_GLOW_ALPHA = 0.45

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
-- PURE: bank-bag STRIP CELL behaviour  (2.0.4 — owner-reported "the bank window
-- in bags won't let me swap bags")
--
-- THE DEFECT this replaces: a PURCHASED cell rendered the equipped bag's icon and
-- then set OnEnter/OnClick to nil. It was a picture. And because 2.0 SUPPRESSES
-- Blizzard's bank panel (the override block further down), the native bank bag
-- slots are unreachable too — so equipping or swapping a bank bag was not merely
-- awkward, it was IMPOSSIBLE while our window was on. 1.x had this: its bank bag
-- buttons were the same Bag class as the carried ones (frames/bank/bankBag.lua
-- subclasses core/classes/bag.lua, whose OnClick does PutItemInBag(self.slot),
-- OnDragStart does PickupBagFromSlot(self.slot), and OnReceiveDrag IS OnClick).
-- This is 1.x parity, restored on the 2.0 surface.
--
-- The decision is pure so the whole cursor × state × view × combat matrix is
-- harness-locked; the executor below it is the only impure half.
--
--   ctx = { state, live, isSelf, cursorItem, cursorBag, equipped, inCombat }
--     state      "purchased" | "buyable" | "locked"
--     live/isSelf   the exact pair Bank.RebuildStrip already gates the strip on —
--                   cells are interactive ONLY on the live self view at the bank,
--                   never on a cached or alt view.
--     cursorItem    something is on the cursor at all
--     cursorBag     ...and it is an equippable CONTAINER (INVTYPE_BAG). A non-bag
--                   must be REFUSED, not eaten: we never call PutItemInBag with a
--                   sword on the cursor, and we never ClearCursor it either.
--     equipped      a bag currently occupies this bank bag slot
--
--   returns {
--     interactive,      -- cell takes any handler at all
--     clickAction,      -- "equip" | "pickup" | "buy" | "refuse" | "blocked-combat" | "none"
--     dragAction,       -- "pickup" | "blocked-combat" | nil
--     dropAction,       -- "equip"  | "refuse" | "blocked-combat" | nil
--     acceptHighlight,  -- subtle "this cell will take that bag" cue
--     tooltip,          -- "bag" | "empty-slot" | "buy" | nil
--   }
--
-- NOTE on swapping onto an OCCUPIED slot: we do not pre-judge it. PutItemInBag is
-- the same call the default UI makes; the client itself refuses a swap whose bag
-- still holds items and prints its own error. Surfacing the client's refusal is
-- honest; blocking a swap the client would have allowed is not.
----------------------------------------------------------------------

function Bank.StripCellState(ctx)
    ctx = ctx or {}
    local state      = ctx.state
    local usable     = (ctx.live and ctx.isSelf) and true or false
    local cursorItem = ctx.cursorItem and true or false
    local cursorBag  = ctx.cursorBag  and true or false
    local equipped   = ctx.equipped   and true or false
    local inCombat   = ctx.inCombat   and true or false

    local out = { interactive = false, clickAction = "none", dragAction = nil,
                  dropAction = nil, acceptHighlight = false, tooltip = nil }

    -- Cached / alt / bank-closed view: the strip is not even shown, and a stale
    -- click must never reach an equip call. Locked cells are inert by definition.
    if not usable or state == "locked" then return out end

    if state == "buyable" then
        -- Unchanged from 2.0.0: the one bronze "buy" well, its own confirm, its own
        -- tooltip. It is NOT a bag slot yet, so it takes no drop and no drag.
        out.interactive = true
        out.clickAction = "buy"
        out.tooltip     = "buy"
        return out
    end

    if state ~= "purchased" then return out end

    out.interactive = true
    out.tooltip     = equipped and "bag" or "empty-slot"

    if cursorItem and not cursorBag then
        -- Something on the cursor that is not a container. Refuse it plainly and
        -- leave the cursor holding it (eating it would be a silent item move).
        out.clickAction = "refuse"
        out.dropAction  = "refuse"
        return out
    end

    if cursorBag then
        out.acceptHighlight = not inCombat
        out.clickAction = inCombat and "blocked-combat" or "equip"
        out.dropAction  = inCombat and "blocked-combat" or "equip"
        return out
    end

    -- Empty cursor: click or drag picks the equipped bag up so it can be moved or
    -- swapped naturally. An empty purchased slot has nothing to take.
    if equipped then
        out.clickAction = inCombat and "blocked-combat" or "pickup"
        out.dragAction  = inCombat and "blocked-combat" or "pickup"
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

    -- ── OWNER DROPDOWN (header-selector round) ────────────────────────────────
    -- The same arrow-after-the-name the inventory window grew, built by the SAME shared
    -- constructor (ns.Frame.BuildOwnerHeader) so the two headers cannot drift apart. The
    -- bank's title already reads "<Character> · Bank", so the arrow annotates a name that
    -- is on screen either way — which is exactly why the 150px name-and-caret face this
    -- window used to carry was saying the same thing twice.
    --
    -- Two deliberate differences from the inventory call, both pre-existing policy of THIS
    -- window: the bank has never had a frame lock (so no dragOK gate), and it does not
    -- persist its anchor (so no onDragStop). The drag itself still works, forwarded exactly
    -- as this window's bare titlebar forwards it, five lines up.
    local ownerArrow, ownerHit
    if ns.Frame and ns.Frame.BuildOwnerHeader then
        ownerArrow, ownerHit = ns.Frame.BuildOwnerHeader(titleBar, title, win, {
            onSelect = function(key)
                if ns.Frame and ns.Frame.SetViewedOwner then ns.Frame.SetViewedOwner(key) end
            end,
        })
    end
    win.ownerArrow, win.ownerHit = ownerArrow, ownerHit

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

    -- (The OWNER SELECTOR sat in this corner for exactly one round, and the decorative
    -- backpack glyph before that. Both are gone: the character menu is the dropdown arrow
    -- beside the title, built up in the title block, and the corner is empty because this
    -- window has no raid-prep sibling to put there. The bank footer is now purely the two
    -- per-owner readouts the inventory footer also carries — slot count and money — which
    -- is the corner-for-corner parity that matters.)

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
        -- END THE BANK SESSION. While our window is overriding Blizzard's panel that
        -- panel's own OnHide is neutralised (see the BLIZZARD BANK-FRAME OVERRIDE block),
        -- so nothing else will call CloseBankFrame — closing OUR window is now the only
        -- thing that tells the server we walked away. Without this the session stays open
        -- until the range check drops it and the bank looks live when it is not.
        if ns.SafeCall then ns:SafeCall(Bank.EndBankSession) else Bank.EndBankSession() end
        -- CHARACTER MENU (2.0.2, owner-reported): the flyout lives on UIParent, so this
        -- window closing does not take it with it. Same fix, same reason, as the
        -- inventory window's OnHide. Guarded — ui_owner is optional to this file.
        if ns.Owner and ns.Owner.CloseAllMenus then ns.Owner.CloseAllMenus() end
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

----------------------------------------------------------------------
-- BANK-BAG SLOT MANAGEMENT (the impure half of Bank.StripCellState)
--
-- Insecure + hardware-event-driven (OnClick / OnReceiveDrag / OnDragStart), exactly
-- as ui_frame.lua's carried-bag strip: bags are NOT part of the secure action system
-- on Classic Era, and PutItemInBag / PickupBagFromSlot need a hardware event, which
-- those three handlers supply. NO protected op on any secure frame runs here.
--
-- Catalog-verified against wow-api-catalog/1.15.9.68808 (interface 11509):
--   C_Container.ContainerIDToInventoryID(containerID) -> inventoryID  (functions.txt)
--   PutItemInBag, PickupBagFromSlot, GetInventoryItemLink,
--   GetInventoryItemTexture, IsInventoryItemLocked, CursorHasItem, GetCursorInfo,
--   GetItemInfoInstant / C_Item.GetItemInfoInstant, InCombatLockdown  (globals.txt)
--   Event.Cursor.CursorChanged == CURSOR_CHANGED,
--   Event.Bank.PlayerbankbagslotsChanged == PLAYERBANKBAGSLOTS_CHANGED,
--   Event.Container.BagUpdateDelayed == BAG_UPDATE_DELAYED  (events.txt)
----------------------------------------------------------------------

-- The inventory (equip) slot for a BANK BAG container id — the ONE mapping between a
-- strip cell and the slot PutItemInBag / PickupBagFromSlot act on. It is the same call
-- the cell's icon code has always made; hoisted to a named function so the paint and the
-- handlers cannot drift apart, and public so the harness can lock cell index -> cid ->
-- inventory slot end to end. Nil when the client API is absent (never guessed).
function Bank.BagInventorySlot(cid)
    if type(cid) ~= "number" then return nil end
    local CC = _G.C_Container
    if CC and CC.ContainerIDToInventoryID then return CC.ContainerIDToInventoryID(cid) end
    if _G.ContainerIDToInventoryID then return _G.ContainerIDToInventoryID(cid) end
    return nil
end
local function bankInvSlot(cid) return Bank.BagInventorySlot(cid) end

-- Live "is a bag equipped in this bank bag slot" (authoritative before capture re-snapshots).
local function bankSlotEquipped(invSlot)
    if invSlot and _G.GetInventoryItemLink then
        return _G.GetInventoryItemLink("player", invSlot) ~= nil
    end
    return false
end

-- Live cursor read -> (cursorItem, cursorBag). Classification reuses ui_frame's PURE
-- Frame.CursorIsBag so both strips answer "is that a bag?" the same way. Permissive
-- when an item cannot be classified yet (server-uncached): we would rather let the
-- client refuse than refuse on the client's behalf.
local function bankCursor()
    if _G.GetCursorInfo then
        local kind, id = _G.GetCursorInfo()
        if kind == nil then return false, false end
        if kind ~= "item" then return true, false end
        local gii = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
        if gii and id then
            local _, _, _, equipLoc = gii(id)
            if equipLoc ~= nil then
                local isBag = (ns.Frame and ns.Frame.CursorIsBag)
                              and ns.Frame.CursorIsBag(kind, equipLoc)
                              or (equipLoc == "INVTYPE_BAG")
                return true, isBag and true or false
            end
        end
        return true, true          -- item on cursor, unclassifiable: permissive
    end
    local has = (_G.CursorHasItem and _G.CursorHasItem()) and true or false
    return has, has
end

local function bankInCombat()
    return (_G.InCombatLockdown and _G.InCombatLockdown()) and true or false
end

-- Live facts for one strip cell -> the resolved pure state.
local function bankCellStateNow(cell)
    local cursorItem, cursorBag = bankCursor()
    return Bank.StripCellState({
        state      = cell._state,
        live       = Bank._live,
        isSelf     = cell._isSelf,
        cursorItem = cursorItem,
        cursorBag  = cursorBag,
        equipped   = bankSlotEquipped(cell._slot),
        inCombat   = bankInCombat(),
    })
end

-- Plain deferred-in-combat notice; same copy shape as the inventory strip's.
function Bank.NotifyBagCombatBlocked()
    if ns and ns.Print then ns:Print("Can't equip or swap bank bags while in combat — try again after combat.") end
    if _G.PlaySound and _G.SOUNDKIT then _G.PlaySound(_G.SOUNDKIT.IG_PLAYER_INVITE_DECLINE or 847) end
end

-- Execute one resolved action. The cursor is NEVER cleared here: a refusal leaves the
-- held item exactly where it was so nothing can go missing.
function Bank.RunStripCellAction(action, cell)
    local slot = cell and cell._slot
    if action == "equip" then
        if slot and _G.PutItemInBag then _G.PutItemInBag(slot) end   -- equip/replace; the client rules on the swap
    elseif action == "pickup" then
        if slot and _G.PickupBagFromSlot then
            if _G.PlaySound and _G.SOUNDKIT then _G.PlaySound(_G.SOUNDKIT.IG_BACKPACK_OPEN or 862) end
            _G.PickupBagFromSlot(slot)
        end
    elseif action == "buy" then
        Bank.BuyNextSlot()
    elseif action == "refuse" then
        if ns and ns.Print then ns:Print("Only a bag can go in a bank bag slot.") end
        if _G.PlaySound and _G.SOUNDKIT then _G.PlaySound(_G.SOUNDKIT.IG_PLAYER_INVITE_DECLINE or 847) end
    elseif action == "blocked-combat" then
        Bank.NotifyBagCombatBlocked()
    end
    -- "none"/nil => inert
end

-- Tooltip for a purchased cell: the equipped bag itself (SetInventoryItem), or the
-- empty-slot invitation, plus the one context instruction. Quiet until hovered.
local function bankCellTooltip(cell)
    local GT = _G.GameTooltip
    if not GT then return end
    local st = bankCellStateNow(cell)
    if st.tooltip == "buy" then
        GT:SetOwner(cell, "ANCHOR_RIGHT")
        GT:ClearLines()
        GT:AddLine("Buy bank bag slot", UI.Color("text"))
        GT:AddLine(moneyString(nextBankSlotCost()), 1, 1, 1)
        GT:Show()
        return
    end
    if not st.tooltip then return end
    GT:SetOwner(cell, "ANCHOR_RIGHT")
    GT:ClearLines()
    local cursorItem, cursorBag = bankCursor()
    if st.tooltip == "bag" then
        if cell._slot and GT.SetInventoryItem then GT:SetInventoryItem("player", cell._slot) end
        if cursorItem and not cursorBag then
            GT:AddLine("Only a bag can go in a bank bag slot", UI.Color("muted"))
        elseif cursorBag then
            GT:AddLine("Click to replace this bank bag", UI.Color("muted"))
        else
            GT:AddLine("Drag out or click to take this bag", UI.Color("muted"))
        end
    else
        GT:SetText("Empty bank bag slot", UI.Color("text"))
        if cursorItem and not cursorBag then
            GT:AddLine("Only a bag can go in a bank bag slot", UI.Color("muted"))
        elseif cursorBag then
            GT:AddLine("Click to put the bag on your cursor here", UI.Color("muted"))
        else
            GT:AddLine("Drag a bag here to equip it", UI.Color("muted"))
        end
    end
    GT:Show()
end

-- Re-evaluate ONLY the two per-cell CUES — the accept halo and the mid-pickup lock
-- desaturation — across the shown cells. Deliberately not a Rebuild: CURSOR_CHANGED and
-- ITEM_LOCK_CHANGED both fire on ordinary item handling all over the UI, and neither
-- changes any bank DATA. Repainting the whole window on them would be a real cost for a
-- texture flip (1.x made the same split: Bag:UpdateLock, not a frame update).
function Bank.RefreshStripAffordance()
    local win = Bank.window
    if not win or not win._stripCells then return end
    for _, cell in ipairs(win._stripCells) do
        if cell.IsShown and cell:IsShown() then
            local st = bankCellStateNow(cell)
            if cell._accept then cell._accept:SetShown(st.acceptHighlight and true or false) end
            if cell._state == "purchased" and cell._icon and cell._icon.SetDesaturated then
                local locked = cell._slot and _G.IsInventoryItemLocked
                               and _G.IsInventoryItemLocked(cell._slot)
                cell._icon:SetDesaturated(locked and true or false)
            end
        end
    end
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
            cell:RegisterForClicks("LeftButtonUp")
            cell:RegisterForDrag("LeftButton")
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
            -- ACCEPT CUE: the additive halo the inventory strip already wears for its
            -- active bag (ui_frame STRIP_GLOW_TEXTURE / _ALPHA), reused here as the
            -- "this cell will take that bag" cue while a container is on the cursor.
            -- Quiet-until-needed: hidden at rest, never standing decoration.
            local accept = cell:CreateTexture(nil, "OVERLAY", nil, -2)
            accept:SetTexture((ns.Frame and ns.Frame.STRIP_GLOW_TEXTURE)
                              or "Interface\\Buttons\\CheckButtonHilight")
            accept:SetBlendMode("ADD")
            accept:SetPoint("TOPLEFT", cell, "TOPLEFT", -2, 2)
            accept:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 2, -2)
            accept:SetAlpha(Bank.ACCEPT_GLOW_ALPHA)
            accept:Hide()
            cell._accept = accept
            local fs = cell:CreateFontString(nil, "OVERLAY")
            fs:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
            fs:SetPoint("CENTER", cell, "CENTER", 0, 0)
            cell._fs = fs
            -- HANDLERS ARE BAKED ONCE, at creation, and dispatch through the PURE
            -- decision (which reads cell._state / cell._isSelf). A cell that is not a
            -- live purchased bag slot resolves to "none" and the handler does nothing —
            -- so a buyable/locked cell, or any cell on a cached or alt view, is inert by
            -- decision rather than by whether some earlier repaint remembered to nil the
            -- script out. (Nilling scripts per state is exactly how the purchased cells
            -- ended up display-only in the first place.)
            cell:SetScript("OnEnter", function(self)
                bankCellTooltip(self)
                if self._accept then
                    self._accept:SetShown(bankCellStateNow(self).acceptHighlight and true or false)
                end
            end)
            cell:SetScript("OnLeave", function(self)
                if _G.GameTooltip then _G.GameTooltip:Hide() end
            end)
            cell:SetScript("OnClick", function(self)
                Bank.RunStripCellAction(bankCellStateNow(self).clickAction, self)
            end)
            cell:SetScript("OnReceiveDrag", function(self)
                Bank.RunStripCellAction(bankCellStateNow(self).dropAction, self)
            end)
            cell:SetScript("OnDragStart", function(self)
                Bank.RunStripCellAction(bankCellStateNow(self).dragAction, self)
            end)
            win._stripCells[i] = cell
        end
        -- Identity the baked handlers read. _isSelf is the SAME pair the strip is shown
        -- under, carried onto the cell so the decision can re-assert it at click time.
        cell._index  = s.index
        cell._cid    = s.cid
        cell._state  = s.state
        cell._isSelf = isSelf and true or false
        cell._slot   = (s.state == "purchased") and bankInvSlot(s.cid) or nil
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", win.strip, "LEFT", x, 0)
        x = x + SIZE + GAP
        cell:SetBackdrop(UI.FLAT_BACKDROP)
        cell._accept:Hide()
        if s.state == "purchased" then
            cell:SetBackdropColor(UI.Color("raised"))
            cell:SetBackdropBorderColor(UI.Color("border"))
            cell._fs:SetText(tostring(s.index))
            cell._fs:SetTextColor(UI.Color("text"))
            -- Show the equipped bank bag's icon (its mapped inventory slot). Falls back
            -- to the index number if the texture can't be resolved.
            local invSlot = cell._slot
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
            -- Lock feedback: a bank bag mid-pickup desaturates (1.x Bag:UpdateLock).
            if invSlot and _G.IsInventoryItemLocked and _G.IsInventoryItemLocked(invSlot) then
                if cell._icon:IsShown() and cell._icon.SetDesaturated then cell._icon:SetDesaturated(true) end
                cell._fs:SetTextColor(UI.Color("faint"))
            end
        elseif s.state == "buyable" then
            cell._icon:Hide(); cell._fs:Show()
            cell:SetBackdropColor(UI.Color("control"))
            cell:SetBackdropBorderColor(UI.Color("bronze"))   -- the one bronze "buy" well
            cell._fs:SetText("+")
            cell._fs:SetTextColor(UI.Color("bronze"))
        else -- locked
            cell:SetBackdropColor(UI.Color("inset"))
            cell:SetBackdropBorderColor(UI.Color("controlBorder"))
            cell._icon:Hide(); cell._fs:Show()
            cell._fs:SetText("")
        end
        cell:Show()
    end
end

----------------------------------------------------------------------
-- Diagnostics (/bags debug bankstrip) — print the LIVE decision for every bank-bag
-- cell, so "the bank window won't let me swap bags" becomes a readout instead of a
-- guess. Sibling of Frame.DebugStrip; guarded + in-game only (needs the built window).
----------------------------------------------------------------------

function Bank.DebugStrip()
    if not (ns and ns.Print) then return end
    local win = Bank.window
    if not win then ns:Print("[bankstrip] window not built — walk up to a banker (or /bags bank)"); return end
    local _, live, isSelf = bankRenderModel()
    local cursorItem, cursorBag = bankCursor()
    ns:Print(string.format("[bankstrip] Bank._live=%s modelLive=%s isSelf=%s purchased=%s/%s inCombat=%s cursorItem=%s cursorBag=%s",
        tostring(Bank._live), tostring(live), tostring(isSelf),
        tostring(numBankBagsPurchased()), tostring(Store.NumBankBagSlots()),
        tostring(bankInCombat()), tostring(cursorItem), tostring(cursorBag)))
    if not (live and isSelf) then
        ns:Print("  NOTE: not the live self view at the bank -> every cell is inert by design.")
    end
    for i, cell in ipairs(win._stripCells or {}) do
        if cell.IsShown and cell:IsShown() then
            local st = bankCellStateNow(cell)
            ns:Print(string.format("  cell%d cid=%s state=%s invSlot=%s equipped=%s | click=%s drop=%s drag=%s accept=%s | handlers onClick=%s onDrag=%s onRecv=%s",
                i, tostring(cell._cid), tostring(cell._state), tostring(cell._slot),
                tostring(bankSlotEquipped(cell._slot)), tostring(st.clickAction),
                tostring(st.dropAction), tostring(st.dragAction), tostring(st.acceptHighlight),
                tostring(cell:GetScript("OnClick") ~= nil), tostring(cell:GetScript("OnDragStart") ~= nil),
                tostring(cell:GetScript("OnReceiveDrag") ~= nil)))
        end
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

    -- (There is no selector FACE to re-sync any more — the gold title below is the label,
    -- and the arrow beside it holds no owner state. The call that used to be here had to be
    -- a COLON call, because ui_owner declares `function frame:Refresh()` and its body
    -- dereferenced self._name / self._pip; a dot call passed self = nil, hard-errored, and
    -- since Bank.Open calls Bank.Rebuild UNPROTECTED it aborted the repaint before the
    -- title, money and grid were ever painted — the bank window came up blank. Refresh is
    -- now guarded at the source as well, so neither form can do that again.)

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

    -- ── SUMMARY PREVIEW (2.0.2) ──────────────────────────────────────────────────
    -- Right-clicking a Nexus-only character's name opens this window on a record that
    -- has no bank containers — and cannot have any, because the Nexus wire payload
    -- carries ONE merged itemCounts map (carried + equipped + the persisted bank and
    -- mail counts, folded by inventory.lua's AggregateCounts). There is no bags-vs-bank
    -- split in the data.
    --
    -- So this shows the SAME summary the inventory window shows, under a caption that
    -- says the split does not exist. The alternative — an empty bank grid — would read
    -- as "this character's bank is empty", which is a claim the payload cannot support
    -- and the one thing worse than saying nothing.
    local summaryOwner = (ns.Owner and ns.Owner.IsSummaryView and ns.Owner.IsSummaryView(viewed))
                         and viewed or nil
    if summaryOwner then
        if win.emptyFS then win.emptyFS:Hide() end
        if not win._summary and ns.Find and ns.Find.CreateSummaryPanel then
            win._summary = ns.Find.CreateSummaryPanel(win.content)
        end
        local nRows = 0
        if win._summary then
            win._summary:ClearAllPoints()
            win._summary:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, 0)
            win._summary:SetPoint("RIGHT", win.content, "RIGHT", 0, 0)
            nRows = win._summary:SetSummary(summaryOwner, { bank = true, sortBy = "name" }) or 0
            win._summary:Show()
        end
        if win._group then win._group:Clear(); if win._group.Hide then win._group:Hide() end end
        local band = Bank.ComputeContentSize(nil, opts).width
        local h = (ns.Find and ns.Find.SummaryHeight and ns.Find.SummaryHeight(nRows)) or 60
        win.content:SetSize(math.max(band, 1), math.max(h, 1))
        win:SetSize(band + Bank.PAD * 2,
                    Bank.TITLE_H + Bank.PAD + Bank.STRIP_H + Bank.VGAP + h + Bank.VGAP
                    + Bank.FOOTER_H + Bank.PAD)
        if win.sortBtn then
            if win.sortBtn.SetEnabled then win.sortBtn:SetEnabled(false) end
            win.sortBtn:SetAlpha(0.4)
        end
        if ns.Search and ns.Search.Reapply then ns.Search.Reapply() end
        return
    elseif win._summary then
        win._summary:Hide()
    end

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

-- =====================================================================
-- BLIZZARD BANK-FRAME OVERRIDE  (2.0.1 regression fix)
--
-- SYMPTOM: walking up to a banker showed Blizzard's default bank window alongside (or
-- instead of) ours. 2.0 replaced the nine FrameXML bag-toggle globals (ui_frame
-- HookBagToggles) but never suppressed the BANK panel, and BANKFRAME_OPENED makes
-- FrameXML call ShowUIPanel(BankFrame) directly — nothing we had replaced was in that path.
--
-- ── WHY NOT JUST Hide() IT ───────────────────────────────────────────────────
-- BankFrame's OnHide script calls CloseBankFrame(), which ends the SERVER's bank session.
-- Hiding the panel would therefore shut the bank the instant we suppressed it, and the
-- player's own bank contents would go read-only under them. This is the trap the whole
-- design is shaped around.
--
-- ── 1.x's PROVEN APPROACH, transcribed ───────────────────────────────────────
-- Daseeki-Bags/core/features/uiOverrides.lua (v1.1.5) does three things and we do the same
-- three, because they run on this exact client in the owner's live 1.x install:
--
--   :19-21  self.Disabled = CreateFrame('Frame', nil, UIParent); Disabled:SetAllPoints();
--           Disabled:Hide()
--             — a permanently HIDDEN host frame.
--   :86-93  hooksecurefunc('ShowUIPanel', function(panel) ...
--             panel.__onhide = panel.__onhide or panel:GetScript('OnHide')
--             panel:SetScript('OnHide', not enabled and panel.__onhide or nil)
--             panel:SetParent(enabled and self.Disabled or PanelParent)  end)
--             — the panel is never hidden. It is RE-PARENTED onto the hidden host, so it
--               renders nothing while remaining shown as far as the panel system and the
--               bank session are concerned; and its OnHide is neutralised while overridden
--               so nothing on this path can fire CloseBankFrame. Both are reversible: when
--               our window is disabled the panel goes back to UIParent with its captured
--               OnHide restored, which is how "turn it off and Blizzard's bank comes back"
--               works without a reload.
--   :95-100 hooksecurefunc('HideUIPanel', ...) — Blizzard closing the panel closes ours.
--
-- ── TAINT ────────────────────────────────────────────────────────────────────
-- hooksecurefunc is the sanctioned non-tainting post-hook, and BankFrame is an ordinary
-- (unprotected) UI panel on Classic Era — SetParent / SetScript on it are not protected
-- operations. This is 1.x's own shape, shipping against 1.15.9.
--
-- Because the panel's OnHide no longer runs CloseBankFrame, closing OUR window is what has
-- to end the session — see Bank.EndBankSession, wired to the window's OnHide.
-- =====================================================================

-- The panels we take over. A table (not a literal) so the pure resolver below is testable
-- and so a future surface (void storage, guild bank) is a one-line addition.
Bank.OVERRIDE_PANELS = { BankFrame = true }

-- Is OUR bank window the one that should appear at a banker? `db.bankWindow`, default ON.
-- Turning it off restores Blizzard's panel AND stops us auto-opening.
function Bank.Enabled()
    local db = Store and Store.db
    if type(db) ~= "table" then return true end
    if db.bankWindow == nil then return true end
    return db.bankWindow and true or false
end

-- PURE: what should happen to a panel the game is about to show?
--   "suppress" — hide it behind our host and neutralise its OnHide (our window is on)
--   "restore"  — put it back on UIParent with its own OnHide (our window is off)
--   nil        — not a panel we touch
function Bank.ResolveOverride(panelName, enabled)
    if not panelName or not Bank.OVERRIDE_PANELS[panelName] then return nil end
    return enabled and "suppress" or "restore"
end

-- The permanently hidden host (1.x's `Disabled` frame). Created once, lazily.
local function hiddenHost()
    if Bank._hiddenHost then return Bank._hiddenHost end
    if not _G.CreateFrame then return nil end
    local h = _G.CreateFrame("Frame", nil, _G.UIParent)
    if h.SetAllPoints then h:SetAllPoints() end
    h:Hide()
    Bank._hiddenHost = h
    return h
end

-- WHERE THE CAPTURED OnHide LIVES (2026-08-12 — the container-click taint fix).
--
-- This used to be `panel.__dsOnHide`, i.e. a field written by insecure code INTO Blizzard's
-- own BankFrame table. That is one table too far. ContainerFrame_Shared.lua:1341 — the line
-- the client blocked when it accused us of calling UseContainerItem — reads `BankFrame`
-- twice on its way to the protected call:
--
--   C_Container.UseContainerItem(..., BankFrame:IsShown() and (BankFrame.selectedTab == 2));
--
-- Our field was never the one that line reads, so this was not the vector that fired (that
-- was the self-test rigs overwriting the GLOBAL — see core.lua's stock-surface banner). But
-- "we write into an object the blocked line reads" is not a position to defend, and the
-- parallel state costs nothing: a weak-keyed side table we own, keyed by panel. Behaviour is
-- identical, including the `false` marker for "captured, and there wasn't one"; the only
-- change is that Blizzard's frame no longer carries a value of ours.
Bank._panelOnHide = setmetatable({}, { __mode = "k" })

-- Apply (or lift) the override on one panel. Idempotent in both directions.
function Bank.ApplyOverride(panel, suppress)
    if not (panel and panel.SetParent and panel.SetScript) then return false end
    -- Capture the panel's OWN OnHide exactly once, before we ever null it. `false` is the
    -- "captured, and there wasn't one" marker so a second capture can never overwrite the
    -- real script with our own nil.
    if Bank._panelOnHide[panel] == nil then
        Bank._panelOnHide[panel] = (panel.GetScript and panel:GetScript("OnHide")) or false
    end
    if suppress then
        local host = hiddenHost()
        if not host then return false end
        panel:SetScript("OnHide", nil)        -- never let this path fire CloseBankFrame
        panel:SetParent(host)                 -- shown, but rendered nowhere
    else
        panel:SetScript("OnHide", Bank._panelOnHide[panel] or nil)
        panel:SetParent(_G.UIParent)
    end
    return true
end

-- What we captured for a panel (nil = never captured, false = captured and there was none).
-- Published so the self-test can assert the capture-once rule without reaching into a
-- Blizzard frame, which is the whole point of moving it.
function Bank.CapturedOnHide(panel) return Bank._panelOnHide[panel] end

-- End the SERVER's bank session. Ours to call now that the panel's own OnHide is muted.
function Bank.EndBankSession()
    if not Bank._live then return false end
    local fn = (_G.C_Bank and _G.C_Bank.CloseBankFrame) or _G.CloseBankFrame
    if not fn then return false end
    fn()
    return true
end

Bank._overrideInstalled = false
function Bank.InstallOverride()
    if Bank._overrideInstalled then return false end
    if not (_G.hooksecurefunc and _G.CreateFrame) then return false end
    Bank._overrideInstalled = true

    _G.hooksecurefunc("ShowUIPanel", function(panel)
        if not (panel and panel.GetName) then return end
        local verdict = Bank.ResolveOverride(panel:GetName(), Bank.Enabled())
        if not verdict then return end
        if ns.SafeCall then ns:SafeCall(Bank.ApplyOverride, panel, verdict == "suppress")
        else Bank.ApplyOverride(panel, verdict == "suppress") end
    end)

    _G.hooksecurefunc("HideUIPanel", function(panel)
        if not (panel and panel.GetName) then return end
        if not Bank.OVERRIDE_PANELS[panel:GetName()] then return end
        if Bank.Enabled() and Bank.IsShown() then Bank.Close() end
    end)

    ns.StockSurface.Record("ShowUIPanel", "securehook",
        "post-hook: reparent BankFrame onto our hidden host so ours is the bank window")
    ns.StockSurface.Record("HideUIPanel", "securehook",
        "post-hook: the client closing the panel closes our window too")
    return true
end

-- Self-registered login wiring (never touches core.lua). Mirrors features.lua.
function Bank.OnLogin()
    if not ns.RegisterEvent then return end
    -- Suppress Blizzard's bank panel before the first BANKFRAME_OPENED can reach it.
    if ns.SafeCall then ns:SafeCall(Bank.InstallOverride) else Bank.InstallOverride() end
    ns:RegisterEvent("BANKFRAME_OPENED", function()
        Bank._live = true
        -- Gated: with our bank window turned off the player gets Blizzard's, and we stay
        -- out of the way entirely (the ShowUIPanel hook has already restored the panel).
        if Bank.Enabled() then
            Bank.Open()             -- open the bank window alongside the inventory window
        end
    end)
    ns:RegisterEvent("BANKFRAME_CLOSED", function()
        Bank._live = false          -- flip to cached; capture.lua already snapshots on close
        Bank.RequestRefresh()       -- repaint read-only; BAGS_CAPTURED will refresh with fresh data
    end)
    -- Repaint when a capture lands (esp. the bank snapshot on open/close).
    if ns.On then ns:On("BAGS_CAPTURED", function() Bank.RequestRefresh() end) end

    -- BAG-SLOT REFRESH (2.0.4). Equipping or swapping a bank bag has to repaint the
    -- strip and the grid, and it must not wait on a capture round-trip: capture.lua
    -- does listen to these two, but it repaints us only INDIRECTLY (RequestCapture ->
    -- BAGS_CAPTURED -> RequestRefresh), and only if the capture is not throttled out.
    -- Listening directly makes the refresh a property of the swap rather than a
    -- side-effect of the snapshot. RequestRefresh coalesces on its own (one C_Timer.After(0)
    -- per frame), so both paths landing in the same frame still paint once.
    --   PLAYERBANKBAGSLOTS_CHANGED — the bank bag equip slots themselves (the swap)
    --   PLAYERBANKSLOTS_CHANGED    — bank main slots (grid contents)
    --   BAG_UPDATE_DELAYED         — coalesced container refresh (new bag's contents)
    for _, evt in ipairs({ "PLAYERBANKBAGSLOTS_CHANGED", "PLAYERBANKSLOTS_CHANGED",
                           "BAG_UPDATE_DELAYED" }) do
        ns:RegisterEvent(evt, function() Bank.RequestRefresh() end)
    end
    -- CUE-ONLY events (no data change, so no Rebuild): the cursor picking a bag up or
    -- putting it down flips the accept halo, and ITEM_LOCK_CHANGED flips the mid-pickup
    -- desaturation. Both are per-cell texture work; see Bank.RefreshStripAffordance.
    for _, evt in ipairs({ "CURSOR_CHANGED", "ITEM_LOCK_CHANGED" }) do
        ns:RegisterEvent(evt, function()
            if Bank.IsShown() then Bank.RefreshStripAffordance() end
        end)
    end
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
    -- HEADER-SELECTOR ROUND: the owner selector left BOTH footers. The constructor the
    -- bank now calls must exist on ns.Frame; without it the bank silently loses its
    -- dropdown arrow and the two title rows diverge — the same class of defect the retired
    -- dressing-helper check guarded, one band up.
    ck(type(F.BuildOwnerHeader) == "function", "the shared owner-header constructor is published")
    ck(F.DressSelectorAsGlyph == nil, "the footer-glyph dressing helper is retired")
    ck(type(F.TitleClickAction) == "function",
        "the shared title-click matrix is published (both windows read it)")
    -- 2.0.1: the shared name zone's right-click is the BANK PREVIEW, not the layout toggle.
    -- The bank window reads the same matrix, so its own name zone opens/closes this window
    -- for whichever character is in view; combined/split stays on the bare titlebar, which
    -- the bank builds for itself (its OnMouseUp forwards to Frame.SetLayout).
    ck(F.TitleClickAction("RightButton") == "bank",
        "the shared name-zone right-click is the bank preview")
    ck(type(F.ToggleViewedBank) == "function",
        "…and the verb behind it is published on the shared surface")
    -- The preview only means anything because this window already renders a CACHED owner.
    ck(type(Bank.HasBankData) == "function",
        "the bank knows whether the viewed owner has stored bank data (the empty state)")
    local footerSet = {}
    for _, n in ipairs(F.FOOTER_CONTROLS or {}) do footerSet[n] = true end
    ck(not footerSet.ownerSelector, "no owner selector in the shared footer roster")
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

----------------------------------------------------------------------
-- BLIZZARD PANEL OVERRIDE (2.0.1 regression). The three properties that make the
-- suppression safe, each pinned against the trap it avoids.
----------------------------------------------------------------------
local function testBankOverride(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedDb = Store.db

    -- The gate.
    Store.db = nil;                  ck(Bank.Enabled() == true,  "no store -> our bank window (default ON)")
    Store.db = {};                   ck(Bank.Enabled() == true,  "unset key -> default ON")
    Store.db = { bankWindow = true };  ck(Bank.Enabled() == true,  "explicit true honored")
    Store.db = { bankWindow = false }; ck(Bank.Enabled() == false, "explicit false honored")

    -- The pure resolver: only BankFrame, and the verdict follows the gate.
    ck(Bank.ResolveOverride("BankFrame", true)  == "suppress", "BankFrame + enabled -> suppress")
    ck(Bank.ResolveOverride("BankFrame", false) == "restore",  "BankFrame + disabled -> restore")
    ck(Bank.ResolveOverride("MerchantFrame", true) == nil, "a panel we do not own -> nil")
    ck(Bank.ResolveOverride(nil, true) == nil, "nil panel name -> nil (nil-safe)")
    ck(Bank.OVERRIDE_PANELS.BankFrame == true, "BankFrame is the panel we take over")

    -- A fake BankFrame carrying the ONE script that makes this dangerous.
    local closed = 0
    local function fakePanel()
        local p = { scripts = {}, parent = "UIParent", hidden = false }
        p.scripts.OnHide = function() closed = closed + 1 end   -- the CloseBankFrame trap
        function p:GetName() return "BankFrame" end
        function p:GetScript(k) return self.scripts[k] end
        function p:SetScript(k, fn) self.scripts[k] = fn end
        function p:SetParent(x) self.parent = x end
        function p:Hide() self.hidden = true end
        return p
    end

    local savedCF, savedUIP = _G.CreateFrame, _G.UIParent
    _G.UIParent = "UIParent"
    _G.CreateFrame = function()
        local f = { shown = true }
        function f:SetAllPoints() end
        function f:Hide() self.shown = false end
        function f:Show() self.shown = true end
        return f
    end
    Bank._hiddenHost = nil

    local panel = fakePanel()
    local origOnHide = panel.scripts.OnHide

    -- SUPPRESS: never hidden, re-parented onto a HIDDEN host, OnHide neutralised.
    ck(Bank.ApplyOverride(panel, true) == true, "suppress applied")
    ck(panel.hidden == false, "the panel is NEVER hidden (Hide() would fire CloseBankFrame)")
    ck(panel.parent ~= "UIParent" and panel.parent == Bank._hiddenHost,
        "…it is re-parented onto the hidden host instead (1.x uiOverrides:93)")
    ck(Bank._hiddenHost.shown == false, "…and that host is hidden, so nothing renders")
    ck(panel.scripts.OnHide == nil, "…and its OnHide is neutralised (1.x uiOverrides:92)")
    ck(closed == 0, "…so suppressing the panel never closed the bank session")

    -- The captured script survives, and a second suppress cannot clobber it with nil.
    Bank.ApplyOverride(panel, true)
    ck(Bank.CapturedOnHide(panel) == origOnHide, "the panel's own OnHide is captured exactly once")
    -- 2026-08-12: and it is captured in OUR table, not in Blizzard's frame. The blocked line
    -- (ContainerFrame_Shared.lua:1341) reads BankFrame; we leave nothing of ours on it.
    ck(rawget(panel, "__dsOnHide") == nil,
       "…and nothing of ours is written onto the Blizzard panel itself")

    -- RESTORE: back to UIParent with its own script — "turn the option off" with no reload.
    ck(Bank.ApplyOverride(panel, false) == true, "restore applied")
    ck(panel.parent == "UIParent", "restored to UIParent")
    ck(panel.scripts.OnHide == origOnHide, "…with its own OnHide back")
    ck(panel.hidden == false, "…and still never hidden by us")

    -- A panel with no OnHide at all round-trips cleanly (the `false` capture marker).
    local bare = fakePanel(); bare.scripts.OnHide = nil
    Bank.ApplyOverride(bare, true)
    ck(Bank.CapturedOnHide(bare) == false, "a panel with no OnHide records the `false` marker")
    Bank.ApplyOverride(bare, false)
    ck(bare.scripts.OnHide == nil, "…and restoring leaves it without one (not with `false`)")

    -- Nil-safety: a malformed panel must not error.
    ck(Bank.ApplyOverride(nil, true) == false, "ApplyOverride(nil) is inert")
    ck(Bank.ApplyOverride({}, true) == false, "a panel with no SetParent is inert")

    -- SESSION END: because the panel's OnHide is muted, ours must call CloseBankFrame —
    -- and only while the bank is actually live, so it can never fire twice.
    local ended = 0
    local savedClose = _G.CloseBankFrame
    _G.CloseBankFrame = function() ended = ended + 1 end
    local savedLive = Bank._live
    Bank._live = false
    ck(Bank.EndBankSession() == false, "not at the bank -> no CloseBankFrame")
    ck(ended == 0, "…and nothing was sent")
    Bank._live = true
    ck(Bank.EndBankSession() == true, "at the bank -> CloseBankFrame")
    ck(ended == 1, "…exactly once")
    Bank._live = false
    Bank.EndBankSession()
    ck(ended == 1, "…and the session-closed handler makes a second call a no-op")
    Bank._live = savedLive
    _G.CloseBankFrame = savedClose

    -- Install is idempotent and headless-inert.
    local savedHook, savedInstalled = _G.hooksecurefunc, Bank._overrideInstalled
    _G.hooksecurefunc = nil
    Bank._overrideInstalled = false
    ck(Bank.InstallOverride() == false, "no hooksecurefunc -> install is a no-op (headless-safe)")
    local hooks = {}
    _G.hooksecurefunc = function(name) hooks[name] = (hooks[name] or 0) + 1 end
    Bank._overrideInstalled = false
    ck(Bank.InstallOverride() == true, "installs when the API is present")
    ck(hooks.ShowUIPanel == 1 and hooks.HideUIPanel == 1, "…hooking both panel entry points")
    ck(Bank.InstallOverride() == false, "…and a second install is a no-op")
    _G.hooksecurefunc, Bank._overrideInstalled = savedHook, savedInstalled

    _G.CreateFrame, _G.UIParent = savedCF, savedUIP
    Bank._hiddenHost = nil
    Store.db = savedDb
end

-- 2.0.2: the BANK PREVIEW of a Nexus-only character.
--
-- THE PAYLOAD FACT this whole case exists to encode: Daseeki-Nexus builds `itemCounts`
-- as ONE merged aggregate (inventory.lua BuildPayload folds carried + equipped +
-- parts.bank + parts.mail through AggregateCounts). The frozen wire contract carries no
-- bags-vs-bank breakdown at all, and cannot — the cold components are stored as counts,
-- not layouts. So the preview shows the SAME item list the inventory window shows, under
-- a caption that SAYS the split does not exist. What it must never do is render an empty
-- bank grid, which would read as "this character's bank is empty" — a claim the data
-- cannot support.
local function testBankSummaryPreview(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local O = ns.Owner
    if not (O and O.SummaryCaption) then
        ck(false, "ui_owner's summary model is absent, so the bank preview cannot be gated")
        return
    end

    local nexusOwner = { nameRealm = "Rin-R", name = "Rin", class = "MAGE",
                         source = "summary", nexus = true, money = 4242, ts = 1700000000,
                         containers = {}, equip = {}, itemCounts = { [6948] = 1, [4306] = 40 } }

    -- Without the branch this owner takes the empty-state path, which is the defect.
    ck(Bank.HasBankData(nexusOwner) == false,
        "a Nexus-only character has no bank containers (so the grid path would say nothing)")
    ck(O.IsSummaryView(nexusOwner) == true, "…and it is therefore a SUMMARY PREVIEW")

    -- The caption is the whole contract: it must name the source, the age, AND the fact.
    local cap = O.SummaryCaption(nexusOwner, 1700000000 + 86400, { bank = true })
    ck(cap:find("Daseeki Nexus", 1, true) ~= nil, "the preview names its source: " .. cap)
    ck(cap:find("updated 1d ago", 1, true) ~= nil, "…and how old the snapshot is")
    ck(cap:find("not separated", 1, true) ~= nil,
        "…and states that bags and bank are NOT separated in synced data")
    -- The inventory window's caption is the same line WITHOUT the bank sentence, so the
    -- two surfaces cannot drift into telling different stories about the same record.
    local invCap = O.SummaryCaption(nexusOwner, 1700000000 + 86400)
    ck(invCap:find("not separated", 1, true) == nil,
        "the inventory caption does not carry the bank sentence")
    ck(cap:sub(1, #invCap) == invCap, "…and the bank caption is that same line, extended")

    -- Both surfaces render the SAME rows (there is only one aggregate to render).
    local resolver = { instant = function() end, info = function(id) return "item" .. id, nil, 1 end }
    local rows = O.SummaryRows(nexusOwner, resolver)
    ck(#rows == 2, "the preview lists every item in the merged aggregate")

    -- Sizing: the preview band is the summary panel's height over the bank chrome.
    if ns.Find and ns.Find.SummaryHeight then
        local h = ns.Find.SummaryHeight(#rows)
        ck(h > 0, "the preview band has a real height")
        local winH = Bank.TITLE_H + Bank.PAD + Bank.STRIP_H + Bank.VGAP + h + Bank.VGAP
                     + Bank.FOOTER_H + Bank.PAD
        ck(winH > h, "…and the window clears its own chrome around it")
    end

    -- A store-sourced summary owner is untouched: still the empty-state bank.
    local meshOwner = { nameRealm = "Old-R", name = "Old", source = "summary",
                        containers = {}, itemCounts = { [1] = 1 } }
    ck(O.IsSummaryView(meshOwner) == false,
        "a Bags-store summary owner keeps the 2.0.1 empty-state bank")
end

----------------------------------------------------------------------
-- BANK BAG SWAP (2.0.4) — the cursor-state decision table.
--
-- This is the suite that would have caught the shipped defect: 2.0.0-2.0.3 rendered a
-- purchased cell's icon and then set its handlers to nil, and nothing asserted that a
-- purchased cell was ever CLICKABLE. Every row below is a state the owner can put the
-- window in; the pure decision answers all of them headless.
----------------------------------------------------------------------
local function testBankBagSwapDecision(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local S = Bank.StripCellState
    -- the live-self-at-the-bank base every interactive row shares
    local function at(t)
        local ctx = { live = true, isSelf = true }
        for k, v in pairs(t) do ctx[k] = v end
        return S(ctx)
    end

    -- ── PURCHASED + EMPTY CURSOR ──────────────────────────────────────────────
    local emptySlot = at({ state = "purchased", equipped = false })
    ck(emptySlot.interactive == true, "purchased cell is interactive (THE 2.0.3 DEFECT)")
    ck(emptySlot.clickAction == "none", "empty purchased slot, empty cursor -> nothing to take")
    ck(emptySlot.dragAction == nil, "…and nothing to drag out")
    ck(emptySlot.tooltip == "empty-slot", "…and it says so on hover")

    local held = at({ state = "purchased", equipped = true })
    ck(held.clickAction == "pickup", "equipped bank bag + empty cursor -> click picks it up")
    ck(held.dragAction == "pickup", "…and dragging picks it up too")
    ck(held.tooltip == "bag", "…with the equipped bag's own tooltip")
    ck(held.acceptHighlight == false, "no accept cue with an empty cursor")

    -- ── PURCHASED + A BAG ON THE CURSOR (the owner's Onyxia-bag case) ─────────
    for _, equipped in ipairs({ false, true }) do
        local c = at({ state = "purchased", equipped = equipped, cursorItem = true, cursorBag = true })
        local where = equipped and "occupied" or "empty"
        ck(c.clickAction == "equip", "bag on cursor -> click equips into the " .. where .. " slot")
        ck(c.dropAction == "equip", "bag on cursor -> drop equips into the " .. where .. " slot")
        ck(c.acceptHighlight == true, "bag on cursor -> the " .. where .. " cell shows the accept cue")
    end

    -- ── PURCHASED + A NON-CONTAINER ON THE CURSOR: REFUSED, NEVER EATEN ──────
    local wrong = at({ state = "purchased", equipped = true, cursorItem = true, cursorBag = false })
    ck(wrong.clickAction == "refuse", "sword on the cursor -> click refuses (never PutItemInBag)")
    ck(wrong.dropAction == "refuse", "sword on the cursor -> drop refuses")
    ck(wrong.acceptHighlight == false, "…and shows no accept cue")
    ck(wrong.dragAction == nil, "…and does not turn into a pickup either")

    -- ── BUYABLE / LOCKED CELLS ARE NOT BAG SLOTS ─────────────────────────────
    local buy = at({ state = "buyable", cursorItem = true, cursorBag = true })
    ck(buy.clickAction == "buy", "the buyable well still buys")
    ck(buy.dropAction == nil and buy.dragAction == nil, "…and takes no bag drop/drag")
    ck(buy.acceptHighlight == false, "…and never lights up as a drop target")
    ck(buy.tooltip == "buy", "…and keeps its cost tooltip")
    for _, ctx in ipairs({ { cursorBag = true, cursorItem = true }, {} }) do
        ctx.state = "locked"
        local lk = at(ctx)
        ck(lk.interactive == false and lk.clickAction == "none", "a locked cell is inert")
        ck(lk.dropAction == nil and lk.dragAction == nil and lk.acceptHighlight == false,
            "…in every direction")
    end

    -- ── CACHED / ALT VIEW: INERT EVEN FOR A PURCHASED CELL ───────────────────
    for _, v in ipairs({ { live = false, isSelf = true }, { live = true, isSelf = false },
                         { live = false, isSelf = false } }) do
        local st = S({ state = "purchased", equipped = true, cursorItem = true, cursorBag = true,
                       live = v.live, isSelf = v.isSelf })
        ck(st.interactive == false, string.format(
            "live=%s isSelf=%s -> purchased cell is inert (never act on a cached/alt view)",
            tostring(v.live), tostring(v.isSelf)))
        ck(st.clickAction == "none" and st.dropAction == nil and st.dragAction == nil
           and st.acceptHighlight == false, "…no click, drop, drag or cue")
    end

    -- ── COMBAT: DEFERRED, NOT ATTEMPTED ──────────────────────────────────────
    local cEquip = at({ state = "purchased", equipped = true, cursorItem = true,
                        cursorBag = true, inCombat = true })
    ck(cEquip.clickAction == "blocked-combat" and cEquip.dropAction == "blocked-combat",
        "combat: equip/swap is deferred with a message, never attempted")
    ck(cEquip.acceptHighlight == false, "combat: no accept cue (it would promise a swap we refuse)")
    local cPick = at({ state = "purchased", equipped = true, inCombat = true })
    ck(cPick.clickAction == "blocked-combat" and cPick.dragAction == "blocked-combat",
        "combat: pickup is deferred too (bag equip is protected in combat)")
    local cBuy = at({ state = "buyable", inCombat = true })
    ck(cBuy.clickAction == "buy", "combat: the buy path is unchanged (BuyNextSlot does its own gate)")

    -- ── Nil-safety: no ctx at all must not error and must be inert. ──────────
    local none = S()
    ck(none.interactive == false and none.clickAction == "none", "no ctx -> inert, no error")
end

-- INVENTORY-SLOT MAPPING: cell index -> container id -> the inventory slot the equip and
-- pickup calls act on. The whole feature is that one chain; if it is off by one the owner
-- swaps the WRONG bag, which is worse than the bug we are fixing.
local function testBankBagInvSlotMapping(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedCC, savedGlobal = _G.C_Container, _G.ContainerIDToInventoryID

    -- The client's real Era mapping: inventoryID = ContainerID + 19 for carried bags
    -- (cid 1 -> 20 == CONTAINER_BAG_1) and it continues straight on through the bank
    -- bags (cid 5 -> 24 under the harness's NUM_BAG_SLOTS=4). We assert the CHAIN, not
    -- the constant: whatever the client returns for that cid is what we act on.
    _G.C_Container = { ContainerIDToInventoryID = function(cid) return cid + 19 end }

    local states = Bank.PurchaseState(3, Store.NumBankBagSlots())
    ck(#states == 7, "harness NUM_BANKBAGSLOTS=7 -> 7 strip cells")
    for i, s in ipairs(states) do
        ck(s.cid == Store.NumBagSlots() + i,
            "cell " .. i .. " maps to cid " .. tostring(Store.NumBagSlots() + i))
        ck(Bank.BagInventorySlot(s.cid) == s.cid + 19,
            "cell " .. i .. " resolves its own inventory slot from its own cid")
    end
    -- Cell 1 is bank bag 1 (cid 5 here), NOT carried bag 1 (cid 1) — the off-by-N guard.
    ck(states[1].cid ~= 1, "strip cell 1 is a BANK bag, never carried bag 1")
    ck(Bank.BagInventorySlot(states[1].cid) ~= Bank.BagInventorySlot(1),
        "…and resolves to a different inventory slot than carried bag 1")

    -- Fallback to the pre-C_Container global, and honest nil when neither exists.
    _G.C_Container = nil
    _G.ContainerIDToInventoryID = function(cid) return cid + 19 end
    ck(Bank.BagInventorySlot(5) == 24, "falls back to the bare ContainerIDToInventoryID global")
    _G.ContainerIDToInventoryID = nil
    ck(Bank.BagInventorySlot(5) == nil, "no client API -> nil, never a guessed slot")
    ck(Bank.BagInventorySlot(nil) == nil, "nil cid -> nil (nil-safe)")
    ck(Bank.BagInventorySlot("5") == nil, "non-number cid -> nil")

    _G.C_Container, _G.ContainerIDToInventoryID = savedCC, savedGlobal
end

-- REFRESH WIRING: a swap that does not repaint looks like a swap that did not happen.
-- Locks the event set Bank.OnLogin subscribes to, and which of them repaint vs. re-cue.
local function testBankRefreshWiring(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedReg, savedOn = ns.RegisterEvent, ns.On
    local seen = {}
    ns.RegisterEvent = function(_, evt, fn) seen[evt] = fn end
    ns.On            = function(_, name, fn) seen["@" .. name] = fn end
    local ok, err = pcall(Bank.OnLogin)
    ns.RegisterEvent, ns.On = savedReg, savedOn
    ck(ok, "Bank.OnLogin ran: " .. tostring(err))

    for _, evt in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
                           "PLAYERBANKBAGSLOTS_CHANGED", "PLAYERBANKSLOTS_CHANGED",
                           "BAG_UPDATE_DELAYED", "CURSOR_CHANGED", "ITEM_LOCK_CHANGED" }) do
        ck(type(seen[evt]) == "function", "Bank.OnLogin subscribes to " .. evt)
    end
    ck(type(seen["@BAGS_CAPTURED"]) == "function", "…and still repaints on BAGS_CAPTURED")

    -- The two cue-only events must NOT queue a full repaint (they fire on ordinary item
    -- handling all over the UI). Window is not shown here, so both are no-ops either way;
    -- the assertion is that neither leaves a queued rebuild behind.
    Bank._refreshQueued = false
    seen["CURSOR_CHANGED"]()
    seen["ITEM_LOCK_CHANGED"]()
    ck(Bank._refreshQueued == false, "CURSOR_CHANGED / ITEM_LOCK_CHANGED are cue-only, no rebuild queued")

    -- …while the three data events do queue one (window closed -> the timer no-ops, but
    -- the request is made, which is the wiring under test).
    for _, evt in ipairs({ "PLAYERBANKBAGSLOTS_CHANGED", "PLAYERBANKSLOTS_CHANGED", "BAG_UPDATE_DELAYED" }) do
        Bank._refreshQueued = false
        local savedTimer = _G.C_Timer
        _G.C_Timer = nil            -- no timer: RequestRefresh fires inline and clears the flag
        local queued = false
        local savedIsShown = Bank.IsShown
        Bank.IsShown = function() queued = true; return false end
        seen[evt]()
        Bank.IsShown = savedIsShown
        _G.C_Timer = savedTimer
        ck(queued == true, evt .. " requests a repaint")
    end
    Bank._refreshQueued = false
end

function Bank.RunSelfTests(verbose)
    local suites = {
        { name = "blizzard panel override", fn = testBankOverride },
        { name = "bank container order",   fn = testBankContainerOrder },
        { name = "money tooltip (1.x)",    fn = testMoneyTooltip },
        { name = "money click (pickup)",   fn = testMoneyClick },
        { name = "title + slot counts",    fn = testBankTitleAndCounts },
        { name = "purchase-state matrix",  fn = testPurchaseStateMatrix },
        { name = "bank bag swap decision", fn = testBankBagSwapDecision },
        { name = "bank bag inv-slot map",  fn = testBankBagInvSlotMapping },
        { name = "bank refresh wiring",    fn = testBankRefreshWiring },
        { name = "cached-view proxy",      fn = testCachedViewProxy },
        { name = "bank entries + sizing",  fn = testBankEntriesAndSizing },
        { name = "footer parity",          fn = testBankFooterParity },
        { name = "nexus summary preview",  fn = testBankSummaryPreview },
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
