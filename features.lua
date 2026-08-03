-- Daseeki Bags 2.0 — features.lua
-- Behaviour-parity features that hang off the store + window without touching the
-- item grid or the secure button model: cross-character tooltip counts, event
-- auto-display, and Alt-click flash-find. All three restore explicit D1-KEEP / 1.x
-- behaviours the parity audit flagged as GAPs (§7.1, §1.5, §2.10 / §3.2-partial).
--
-- ── Purity split ──────────────────────────────────────────────────────────────
-- The load-bearing logic is PURE (no WoW API): the per-owner count math, the
-- event->action matrix, and the link-name extractor. The headless harness drives
-- all three from fixtures. Every live hook is guarded (CreateFrame / GameTooltip /
-- hooksecurefunc absent => the file loads and self-tests run, hooks just no-op).
--
-- ── Catalog evidence (WoW Classic Era 1.15.9.68808) ───────────────────────────
--   Tooltip hook: the modern retail TooltipDataProcessor / AddTooltipPostCall is
--     NOT in the catalog (retail-only) — the supported surface on 1.15 is the
--     script hook GameTooltip:HookScript("OnTooltipSetItem", fn); the FrameXML
--     handler GameTooltip_OnTooltipSetItem is catalog-present (globals.txt:4745).
--     The hovered item id comes from GameTooltip:GetItem() -> name,link then
--     GetItemInfoInstant(link) -> itemID (globals.txt:5161; C_Item variant 1594).
--   Auto-display events (events.txt, SCREAMING_SNAKE forms of the namespaced
--     entries): MERCHANT_SHOW / MERCHANT_CLOSED (Event.MerchantFrame.*),
--     BANKFRAME_OPENED / BANKFRAME_CLOSED (Event.Bank.*),
--     MAIL_SHOW / MAIL_CLOSED (Event.MailInfo.*),
--     PLAYER_REGEN_DISABLED (Event.Unit.PlayerRegenDisabled).
--   Alt-click: HandleModifiedItemClick(link) (globals.txt:5930 — every modified
--     item click, bag items included, routes through it) and SetItemRef
--     (globals.txt:7544 — chat hyperlink clicks); post-hooked via hooksecurefunc
--     (globals.txt:5988); modifier read with IsAltKeyDown (globals.txt:6064).
--   Secure audit: this file performs ZERO protected ops. Auto-display calls only
--     Frame.Open/Close, which Show/Hide our own UNPROTECTED window (always allowed
--     in combat); the hooks are post-hooks that read state and set a fontstring /
--     an editbox. No SetAttribute/Show/Hide/SetPoint on any secure button.

local ADDON, ns = ...

local Features = {}
ns.Features = Features

local Store = ns.Store

----------------------------------------------------------------------
-- Self identity (mirrors capture.selfNameRealm; guarded/headless-safe)
----------------------------------------------------------------------

local function selfKey()
    local name  = (_G.UnitName and _G.UnitName("player")) or nil
    if not name then return nil end
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))
    return Store.MakeNameRealm(name, realm)
end

----------------------------------------------------------------------
-- The owners universe the cross-character counts read.
--
-- With Daseeki-Nexus present and its Inventory module holding data, nexus.lua
-- returns a merged view: Bags' own owners plus the Nexus store's SUMMARY owners,
-- newest-wins per character. Without it — or with any bridge guard unmet — this is
-- Store.data.owners itself, the same table this file read before the bridge existed.
-- Type-guarded so a missing/half-loaded bridge degrades to standalone-local.
----------------------------------------------------------------------

local function ownersView()
    if ns.Nexus and ns.Nexus.Owners then
        local view = ns.Nexus.Owners()
        if type(view) == "table" then return view end
    end
    local data = Store and Store.data
    return (type(data) == "table" and type(data.owners) == "table") and data.owners or nil
end
Features._OwnersView = ownersView   -- exposed for the self-tests / debugging

----------------------------------------------------------------------
-- ════════════ GAP #1 (audit §7.1) — cross-character tooltip counts ═══════════
--
-- PURE core: count an itemID across every stored owner, honoring per-container
-- identity so a full owner gets an exact carried-vs-bank split while a summary
-- (remote/mesh) owner reports only its aggregate. Gated live by showItemCounts.
--
-- "Every stored owner" is ownersView() above: the Nexus-merged universe when the
-- bridge is active, Bags' own store otherwise. The PURE core is unchanged either
-- way — a Nexus-sourced owner is just another summary record, and summary records
-- are exactly what this function has always folded in via owner.itemCounts.
----------------------------------------------------------------------

-- Count `itemID` within a single owner. Full owners (per-slot containers) return
-- an exact split { carried, bank, total, exact=true }; summary owners (no
-- containers, only an aggregate itemCounts map) return { total, exact=false }.
-- Returns nil when the owner holds none of the item.
function Features.CountItemInOwner(owner, itemID)
    if type(owner) ~= "table" or not itemID then return nil end
    local containers = owner.containers
    if type(containers) == "table" and next(containers) ~= nil then
        local carried, bank = 0, 0
        for cid, c in pairs(containers) do
            local isBank = Store.IsBankContainer(cid)
            local slots = c and c.slots
            if type(slots) == "table" then
                for _, slot in pairs(slots) do
                    if slot.id == itemID then
                        local n = slot.count or 1
                        if isBank then bank = bank + n else carried = carried + n end
                    end
                end
            end
        end
        if type(owner.equip) == "table" then
            for _, e in pairs(owner.equip) do
                if e.id == itemID then carried = carried + (e.count or 1) end  -- equipped => "on hand"
            end
        end
        local total = carried + bank
        if total == 0 then return nil end
        return { carried = carried, bank = bank, total = total, exact = true }
    end
    -- summary owner: aggregate only (bank/carried unknowable)
    local agg = owner.itemCounts and owner.itemCounts[itemID]
    if agg and agg > 0 then
        return { carried = nil, bank = nil, total = agg, exact = false }
    end
    return nil
end

-- Build ordered display lines for an itemID across `owners` (map [key]=owner,
-- Store.data.owners shape). `viewerKey` sorts the viewer's own char first.
-- Returns an array of { key, name, class, account, carried, bank, total, exact, isSelf }.
function Features.BuildCountLines(owners, itemID, viewerKey)
    local lines = {}
    if type(owners) ~= "table" then return lines end
    for key, owner in pairs(owners) do
        local c = Features.CountItemInOwner(owner, itemID)
        if c then
            lines[#lines + 1] = {
                key = key, name = owner.name or key, class = owner.class,
                account = owner.account or "",
                carried = c.carried, bank = c.bank, total = c.total, exact = c.exact,
                isSelf = (viewerKey ~= nil and key == viewerKey),
            }
        end
    end
    -- deterministic order: self first, then total desc, then name asc.
    table.sort(lines, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        if a.total ~= b.total then return a.total > b.total end
        return tostring(a.name) < tostring(b.name)
    end)
    return lines
end

-- Plain-copy left/right text for one holder line (§6): "Poonyx" / "40 · Bank 12"
-- when the split is known, else "Poonyx" / "52". No persona, no color here (the
-- live layer class-colors the name).
function Features.FormatCountLine(line)
    local right
    if line.exact and line.bank and line.bank > 0 then
        right = tostring(line.carried) .. " \194\183 Bank " .. tostring(line.bank)  -- \194\183 = middot
    else
        right = tostring(line.total)
    end
    return line.name, right
end

-- Grand total across the built lines (only meaningful with >1 holder).
function Features.SumCountLines(lines)
    local t = 0
    for _, ln in ipairs(lines) do t = t + (ln.total or 0) end
    return t
end

----------------------------------------------------------------------
-- Live tooltip hook (guarded)
----------------------------------------------------------------------

local function classColor(class)
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.925, 0.890, 0.816   -- cream fallback (#ECE3D0)
end

local function creamRGB()
    local UI = _G.DaseekiUI
    if UI and UI.Color then return UI.Color("text") end
    return 0.925, 0.890, 0.816
end

-- Append the count block to a tooltip that has just been populated for an item.
local function appendCounts(tt)
    if type(tt) ~= "table" and type(tt) ~= "userdata" then return end
    if tt.__dbCountsShown then return end                     -- one block per populate
    local db = Store and Store.db
    if not db or db.showItemCounts == false then return end   -- D1 setting gate (default ON)
    local getItem = tt.GetItem
    if not getItem then return end
    local _, link = getItem(tt)
    if not link then return end
    local itemID = _G.GetItemInfoInstant and _G.GetItemInfoInstant(link)
    if not itemID then return end
    local owners = ownersView()
    if not owners then return end

    local lines = Features.BuildCountLines(owners, itemID, selfKey())
    if #lines == 0 then return end
    tt.__dbCountsShown = true

    if tt.AddLine then tt:AddLine(" ") end
    for _, ln in ipairs(lines) do
        local lname, rval = Features.FormatCountLine(ln)
        local nr, ng, nb = classColor(ln.class)
        local vr, vg, vb = creamRGB()
        if tt.AddDoubleLine then tt:AddDoubleLine(lname, rval, nr, ng, nb, vr, vg, vb) end
    end
    if #lines > 1 and tt.AddDoubleLine then
        local vr, vg, vb = creamRGB()
        tt:AddDoubleLine("All characters", tostring(Features.SumCountLines(lines)), vr, vg, vb, vr, vg, vb)
    end
    if tt.Show then tt:Show() end   -- re-fit to the added rows
end
Features._appendCounts = appendCounts   -- exposed for debugging

function Features.HookTooltip()
    if Features._tipHooked then return end
    if not _G.GameTooltip then return end
    Features._tipHooked = true
    local tips = { _G.GameTooltip, _G.ItemRefTooltip, _G.ShoppingTooltip1, _G.ShoppingTooltip2 }
    for _, tt in ipairs(tips) do
        if tt and tt.HookScript then
            tt:HookScript("OnTooltipSetItem", function(self)
                if ns.SafeCall then ns:SafeCall(appendCounts, self) else appendCounts(self) end
            end)
            -- reset the guard whenever the tooltip is cleared/reused for a new item.
            tt:HookScript("OnTooltipCleared", function(self) self.__dbCountsShown = nil end)
            tt:HookScript("OnHide",           function(self) self.__dbCountsShown = nil end)
        end
    end
end

----------------------------------------------------------------------
-- ════════════ GAP #4 (audit §1.5) — auto-display at events ═══════════════════
--
-- PURE event->action matrix. Default ON semantics: a setting that is absent or
-- true enables the trigger; only an explicit false disables it (additive-safe).
----------------------------------------------------------------------

-- Each open event pairs with a close event of the same setting so a close only
-- hides what we auto-opened (never the user's own window). Catalog-verified against
-- wow-api-catalog/1.15.9.68808 (systemized Event.* forms):
--   MERCHANT_SHOW/CLOSED (Event.MerchantFrame.*), BANKFRAME_OPENED/CLOSED (Event.Bank.*),
--   MAIL_SHOW/CLOSED (Event.MailInfo.*), AUCTION_HOUSE_SHOW/CLOSED (Event.AuctionHouse.*),
--   TRADE_SHOW/CLOSED (Event.TradeInfo.*), TRADE_SKILL_SHOW/CLOSE (Event.TradeSkillUI.*;
--   note the close form is TRADE_SKILL_CLOSE — no "D"), PLAYER_REGEN_DISABLED (combat).
-- Deliberately NOT wired (catalog verdicts):
--   * Gem SOCKETING — SOCKET_INFO_UPDATE/CLOSE ARE catalogued (Event.ItemSocketInfo.*) but
--     gem sockets are a TBC+ gameplay feature absent from Classic Era, so the trigger would
--     never fire; wiring it would only add a dead toggle. Skipped.
--   * WORLD MAP close — no WORLD_MAP_OPEN/CLOSE/UPDATE event exists on 1.15 at all (ABSENT);
--     the Era map has no open/close signal to hang an auto-close on. Skipped.
--   * VEHICLE close — UNIT_ENTERED_VEHICLE etc. ARE catalogued (Event.Vehicle.*) but vehicles
--     do not exist in Classic Era gameplay, so the events never fire. Skipped.
Features.DISPLAY_MATRIX = {
    MERCHANT_SHOW         = { setting = "merchant",    action = "open"  },
    MERCHANT_CLOSED       = { setting = "merchant",    action = "close" },
    BANKFRAME_OPENED      = { setting = "bank",        action = "open"  },
    BANKFRAME_CLOSED      = { setting = "bank",        action = "close" },
    MAIL_SHOW             = { setting = "mail",        action = "open"  },
    MAIL_CLOSED           = { setting = "mail",        action = "close" },
    AUCTION_HOUSE_SHOW    = { setting = "auction",     action = "open"  },
    AUCTION_HOUSE_CLOSED  = { setting = "auction",     action = "close" },
    TRADE_SHOW            = { setting = "trade",       action = "open"  },
    TRADE_CLOSED          = { setting = "trade",       action = "close" },
    TRADE_SKILL_SHOW      = { setting = "craft",       action = "open"  },
    TRADE_SKILL_CLOSE     = { setting = "craft",       action = "close" },
    PLAYER_REGEN_DISABLED = { setting = "combatClose", action = "close" },
}

-- Resolve an event to "open" | "close" | nil, gated by the autoDisplay settings.
function Features.ResolveDisplayAction(event, settings)
    local m = Features.DISPLAY_MATRIX[event]
    if not m then return nil end
    settings = settings or {}
    if settings[m.setting] == false then return nil end   -- absent/true => enabled
    return m.action
end

-- Additive defaults for the auto-display toggle set (all ON, matching 1.x).
function Features.ApplyDefaults(db)
    if type(db) ~= "table" then return db end
    if type(db.autoDisplay) ~= "table" then db.autoDisplay = {} end
    local ad = db.autoDisplay
    if ad.merchant    == nil then ad.merchant    = true end
    if ad.bank        == nil then ad.bank        = true end
    if ad.mail        == nil then ad.mail        = true end
    if ad.auction     == nil then ad.auction     = true end
    if ad.trade       == nil then ad.trade       = true end
    if ad.craft       == nil then ad.craft       = true end
    if ad.combatClose == nil then ad.combatClose = true end
    return db
end

-- Live event handler. Tracks whether WE auto-opened the window so a
-- merchant/bank/mail close only hides what we opened (never the user's own open
-- window); combat-close always hides a shown window.
Features._autoOpened = false
function Features.OnDisplayEvent(event)
    local Frame = ns.Frame
    if not Frame then return end
    local db = Store and Store.db
    local action = Features.ResolveDisplayAction(event, db and db.autoDisplay)
    if not action then return end
    local shown = Frame.IsShown and Frame.IsShown()
    if action == "open" then
        if not shown then
            Features._autoOpened = true
            if Frame.Open then Frame.Open() end
        end
    else -- close
        if event == "PLAYER_REGEN_DISABLED" then
            if shown and Frame.Close then Frame.Close() end        -- combat: always hide
            Features._autoOpened = false
        elseif Features._autoOpened then
            Features._autoOpened = false
            if shown and Frame.Close then Frame.Close() end        -- close only what we opened
        end
    end
end

function Features.HookDisplayEvents()
    if Features._dispHooked then return end
    if not ns.RegisterEvent then return end
    Features._dispHooked = true
    for event in pairs(Features.DISPLAY_MATRIX) do
        ns:RegisterEvent(event, function(evt)
            if ns.SafeCall then ns:SafeCall(Features.OnDisplayEvent, evt) else Features.OnDisplayEvent(evt) end
        end)
    end
end

----------------------------------------------------------------------
-- ════════════ GAP #3 (partial, audit §2.10) — Alt-click flash-find ═══════════
--
-- Alt-clicking an item link in chat, or Alt-clicking a bag item, drops that
-- item's name into the search box — the "flash" is the existing search-dim doing
-- its job (non-matches recede). The full cross-character FIND WINDOW (audit §3.2)
-- stays W3 scope; this is only the name->search wiring.
----------------------------------------------------------------------

-- PURE: pull the display name out of a WoW hyperlink's "[Name]" segment.
function Features.ItemNameFromLink(src)
    if type(src) ~= "string" then return nil end
    local name = src:match("%[(.-)%]")
    if name and name ~= "" then return name end
    return nil
end

-- Live: on an Alt-click that carries an item link, set the search box (only when
-- our window is open, so we never hijack Alt-click globally).
function Features.OnAltClickLink(src)
    if not (_G.IsAltKeyDown and _G.IsAltKeyDown()) then return end
    if type(src) ~= "string" or not src:find("item:", 1, true) then return end
    local Frame = ns.Frame
    if not Frame or not (Frame.IsShown and Frame.IsShown()) then return end
    local name = Features.ItemNameFromLink(src)
    if not name then return end
    if Frame.SetSearch then Frame.SetSearch(name) end
end

function Features.HookAltClick()
    if Features._altHooked then return end
    if not _G.hooksecurefunc then return end
    Features._altHooked = true
    if _G.HandleModifiedItemClick then
        _G.hooksecurefunc("HandleModifiedItemClick", function(link)
            if ns.SafeCall then ns:SafeCall(Features.OnAltClickLink, link) else Features.OnAltClickLink(link) end
        end)
    end
    if _G.SetItemRef then
        -- SetItemRef(link, text, button, chatFrame): `text` is the bracketed link.
        _G.hooksecurefunc("SetItemRef", function(link, text, button)
            if button and button ~= "LeftButton" then return end
            local src = text or link
            if ns.SafeCall then ns:SafeCall(Features.OnAltClickLink, src) else Features.OnAltClickLink(src) end
        end)
    end
end

----------------------------------------------------------------------
-- Wiring (self-registered on the core bus; never touches core.lua)
----------------------------------------------------------------------

function Features.OnLogin()
    Features.HookTooltip()
    Features.HookDisplayEvents()
    Features.HookAltClick()
end

if ns.On then
    ns:On("STORE_READY", function() Features.ApplyDefaults(Store and Store.db) end)
    ns:On("LOGIN", function()
        if ns.SafeCall then ns:SafeCall(Features.OnLogin) else Features.OnLogin() end
    end)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "features")
----------------------------------------------------------------------

local function testCountLines(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Full owner: 40 carried (20+20 backpack, cid 0) + 12 in a bank bag (cid 5).
    local A = {
        name = "Poonyx", class = "MAGE", account = "acctA",
        containers = {
            [0] = { slots = { [1] = { id = 100, count = 20 }, [2] = { id = 100, count = 20 },
                              [3] = { id = 6948, count = 1 } } },
            [5] = { slots = { [1] = { id = 100, count = 12 } } },   -- bankbag (5 -> bankbag)
        },
        equip = {},
        itemCounts = { [100] = 52, [6948] = 1 },
    }
    -- Summary owner: aggregate only, no containers.
    local B = { name = "Alt", class = "WARRIOR", account = "acctB",
                containers = {}, itemCounts = { [100] = 7 } }
    local owners = { ["Poonyx-R"] = A, ["Alt-R"] = B }

    local ca = Features.CountItemInOwner(A, 100)
    ck(ca.carried == 40 and ca.bank == 12 and ca.total == 52 and ca.exact == true,
        "full owner exact split: 40 carried / 12 bank / 52 total")
    local cb = Features.CountItemInOwner(B, 100)
    ck(cb.total == 7 and cb.exact == false and cb.bank == nil, "summary owner: aggregate only")
    ck(Features.CountItemInOwner(A, 999) == nil, "item the owner lacks -> nil")

    local lines = Features.BuildCountLines(owners, 100, "Poonyx-R")
    ck(#lines == 2, "two holders for item 100")
    ck(lines[1].isSelf and lines[1].name == "Poonyx", "viewer's own char sorts first")
    local lname, rval = Features.FormatCountLine(lines[1])
    ck(lname == "Poonyx" and rval == "40 \194\183 Bank 12", "carried+bank plain copy")
    local _, rval2 = Features.FormatCountLine(lines[2])
    ck(rval2 == "7", "summary line formats as a plain total")
    ck(Features.SumCountLines(lines) == 59, "grand total 52+7")
    ck(#Features.BuildCountLines(owners, 12345, "Poonyx-R") == 0, "absent item -> no lines")
    -- equipped items count toward carried
    local E = { name = "Eq", containers = { [0] = { slots = {} } }, equip = { [1] = { id = 200, count = 1 } } }
    local ce = Features.CountItemInOwner(E, 200)
    ck(ce and ce.carried == 1 and ce.total == 1, "equipped item counts on-hand")
end

local function testDisplayMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local S = {}   -- all defaults (absent => enabled)
    ck(Features.ResolveDisplayAction("MERCHANT_SHOW", S) == "open",  "merchant show -> open")
    ck(Features.ResolveDisplayAction("MERCHANT_CLOSED", S) == "close", "merchant closed -> close")
    ck(Features.ResolveDisplayAction("BANKFRAME_OPENED", S) == "open",  "bank opened -> open")
    ck(Features.ResolveDisplayAction("BANKFRAME_CLOSED", S) == "close", "bank closed -> close")
    ck(Features.ResolveDisplayAction("MAIL_SHOW", S) == "open",  "mail show -> open")
    ck(Features.ResolveDisplayAction("MAIL_CLOSED", S) == "close", "mail closed -> close")
    ck(Features.ResolveDisplayAction("PLAYER_REGEN_DISABLED", S) == "close", "combat -> close")
    ck(Features.ResolveDisplayAction("SOMETHING_ELSE", S) == nil, "non-trigger event -> nil")
    ck(Features.ResolveDisplayAction("MAIL_SHOW", nil) == "open", "nil settings default ON")
    -- extended trigger set (audit §1.5 residual): AH / trade / tradeskill (crafting)
    ck(Features.ResolveDisplayAction("AUCTION_HOUSE_SHOW", S) == "open",   "AH show -> open")
    ck(Features.ResolveDisplayAction("AUCTION_HOUSE_CLOSED", S) == "close", "AH closed -> close")
    ck(Features.ResolveDisplayAction("TRADE_SHOW", S) == "open",           "trade show -> open")
    ck(Features.ResolveDisplayAction("TRADE_CLOSED", S) == "close",        "trade closed -> close")
    ck(Features.ResolveDisplayAction("TRADE_SKILL_SHOW", S) == "open",     "tradeskill show -> open")
    ck(Features.ResolveDisplayAction("TRADE_SKILL_CLOSE", S) == "close",   "tradeskill close -> close (note: CLOSE, no D)")
    -- verdict-absent events must never resolve to an action (skipped by design)
    ck(Features.ResolveDisplayAction("SOCKET_INFO_UPDATE", S) == nil, "socket not wired (dormant on Era)")
    ck(Features.ResolveDisplayAction("WORLD_MAP_OPEN", S) == nil,     "world-map not wired (no such event on 1.15)")
    ck(Features.ResolveDisplayAction("UNIT_ENTERED_VEHICLE", S) == nil, "vehicle not wired (dormant on Era)")
    -- explicit off
    ck(Features.ResolveDisplayAction("MERCHANT_SHOW", { merchant = false }) == nil, "merchant off -> nil")
    ck(Features.ResolveDisplayAction("AUCTION_HOUSE_SHOW", { auction = false }) == nil, "auction off -> nil")
    ck(Features.ResolveDisplayAction("TRADE_SKILL_SHOW", { craft = false }) == nil, "craft off -> nil")
    ck(Features.ResolveDisplayAction("PLAYER_REGEN_DISABLED", { combatClose = false }) == nil, "combat off -> nil")
    -- every close event pairs with an open of the same setting (matrix symmetry)
    local opens, closes = {}, {}
    for evt, m in pairs(Features.DISPLAY_MATRIX) do
        if m.action == "open" then opens[m.setting] = true elseif m.action == "close" then closes[m.setting] = true end
    end
    ck(opens.merchant and opens.bank and opens.mail and opens.auction and opens.trade and opens.craft,
        "open triggers for merchant/bank/mail/auction/trade/craft")
    ck(closes.merchant and closes.bank and closes.mail and closes.auction and closes.trade and closes.craft
        and closes.combatClose, "close triggers present for all settings")
end

local function testDefaultsAdditive(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {}
    Features.ApplyDefaults(db)
    ck(db.autoDisplay.merchant == true and db.autoDisplay.bank == true
        and db.autoDisplay.mail == true and db.autoDisplay.auction == true
        and db.autoDisplay.trade == true and db.autoDisplay.craft == true
        and db.autoDisplay.combatClose == true,
        "auto-display defaults all ON (merchant/bank/mail/auction/trade/craft/combat)")
    local pre = { autoDisplay = { merchant = false } }
    Features.ApplyDefaults(pre)
    ck(pre.autoDisplay.merchant == false, "existing merchant=false preserved")
    ck(pre.autoDisplay.bank == true and pre.autoDisplay.mail == true, "missing sub-keys filled")
    ck(Features.ApplyDefaults(nil) == nil, "nil db is a safe no-op")
end

local function testNameExtraction(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Features.ItemNameFromLink("|cffffffff|Hitem:6948:0:0:0|h[Hearthstone]|h|r") == "Hearthstone",
        "extract name from a full item hyperlink")
    ck(Features.ItemNameFromLink("[Arcane Powder]") == "Arcane Powder", "extract from a bare bracket")
    ck(Features.ItemNameFromLink("no brackets here") == nil, "no bracket -> nil")
    ck(Features.ItemNameFromLink("") == nil, "empty -> nil")
    ck(Features.ItemNameFromLink(nil) == nil, "nil -> nil")
    ck(Features.ItemNameFromLink(42) == nil, "non-string -> nil")
    -- OnAltClickLink is inert without a live IsAltKeyDown / shown window (headless).
    local okCall = pcall(Features.OnAltClickLink, "|Hitem:6948|h[Hearthstone]|h")
    ck(okCall, "OnAltClickLink is a safe no-op headless")
end

-- W2 (Nexus Inventory bridge): where the cross-character counts get their owners.
local function testNexusCountSourcing(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedNexus, savedData = _G.DaseekiNexusData, Store.data
    local function invalidate() if ns.Nexus then ns.Nexus.Invalidate() end end

    Store.data = { owners = {
        ["Me-R"] = { nameRealm = "Me-R", name = "Me", class = "MAGE", account = "",
                     source = "full", ts = 1700000000,
                     containers = { [0] = { slots = { [1] = { id = 100, count = 5 } } } },
                     equip = {}, itemCounts = { [100] = 5 } },
    } }

    -- Standalone: the accessor hands back the store's OWN table (no copy at all).
    _G.DaseekiNexusData = nil
    invalidate()
    local view = Features._OwnersView()
    ck(view == Store.data.owners, "no Nexus -> counts read Store.data.owners itself")
    ck(#Features.BuildCountLines(view, 100, "Me-R") == 1, "standalone: one holder")

    -- Bridged: a Nexus summary owner contributes its aggregate count.
    _G.DaseekiNexusData = { inventory = { schema = 1, owners = {
        ["Remote-R"] = { rev = 3, updatedAt = 1700000900,
                         data = { key = "Remote-R", class = "PRIEST", money = 42,
                                  itemCounts = { [100] = 7 }, ts = 1700000800 } },
    } } }
    invalidate()
    local bridged = Features._OwnersView()
    ck(bridged ~= Store.data.owners, "with Nexus -> a merged view")
    local lines = Features.BuildCountLines(bridged, 100, "Me-R")
    ck(#lines == 2, "the Nexus-sourced character appears in the tooltip counts")
    ck(lines[1].isSelf and lines[1].name == "Me", "the viewer still sorts first")
    local remote
    for _, ln in ipairs(lines) do if ln.name == "Remote" then remote = ln end end
    ck(remote ~= nil and remote.total == 7 and remote.exact == false,
        "a Nexus owner reports its aggregate, with no carried/bank split")
    ck(Features.SumCountLines(lines) == 12, "grand total 5 (local) + 7 (Nexus)")
    ck(Store.data.owners["Remote-R"] == nil, "nothing was written into the Bags store")

    -- appendCounts must stay a safe no-op headless with the bridge active.
    ck(pcall(Features._appendCounts, {}), "appendCounts is inert on a tooltip-less table")

    _G.DaseekiNexusData, Store.data = savedNexus, savedData
    invalidate()
end

function Features.RunSelfTests(verbose)
    local suites = {
        { name = "count lines",       fn = testCountLines },
        { name = "display matrix",    fn = testDisplayMatrix },
        { name = "defaults additive", fn = testDefaultsAdditive },
        { name = "name extraction",   fn = testNameExtraction },
        { name = "nexus count sourcing", fn = testNexusCountSourcing },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS features/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL features/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("features", Features.RunSelfTests)
end

return Features
