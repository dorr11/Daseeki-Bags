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

----------------------------------------------------------------------
-- PURE: owner management (delete cached alt / favorites) — audit 5.2 / 5.5
--
-- Store.RemoveOwner unconditionally nils an owner; the LIVE SELF must never be deletable
-- (its record is re-created on the next capture, and deleting the character you're logged
-- into makes no sense). CanRemove is the pure guard the UI + the RemoveOwner wrapper share.
----------------------------------------------------------------------

-- True only when `key` is a real, non-self owner (so it may be removed from the cache).
function Owner.CanRemove(key, selfKey)
    if type(key) ~= "string" or key == "" then return false end
    if selfKey ~= nil and key == selfKey then return false end   -- never the live self
    return true
end

-- Favorites are a per-settings preference (DaseekiBags2DB.ownerFavorites = { [key]=true }),
-- additive and independent of the cache DB. These pure helpers take the map explicitly; the
-- live wrappers below read/write Store.db.
function Owner.IsFavoriteIn(favorites, key)
    return (type(favorites) == "table" and key ~= nil and favorites[key] == true) and true or false
end

-- Build the ordered owner list for the flyout.
--   owners      = Store.data.owners shape  ([key] = ownerRecord)
--   selfKey     = the logged-in character's "Name-Realm" (Owner.SelfKey())
--   selfAccount = Store.data.selfAccount (own-account grouping; "" when unknown)
--   now         = injectable epoch (defaults Store.Now())
--   favorites   = optional { [key]=true } — favorited owners sort to the TOP (below self)
-- Returns an array of descriptors, ordered self → favorites → own-account → cross-account,
-- then name ascending within each group:
--   { key, name, class, account, source, isSelf, isOwnAccount, isFavorite, ageSeconds, hasBank, rank }
function Owner.BuildOwnerList(owners, selfKey, selfAccount, now, favorites)
    now = now or (Store.Now and Store.Now()) or 0
    local list = {}
    if type(owners) ~= "table" then return list end
    for key, o in pairs(owners) do
        local isSelf = (selfKey ~= nil and key == selfKey)
        local acct   = o.account or ""
        local isOwn  = (not isSelf) and acct ~= "" and selfAccount ~= nil
                       and selfAccount ~= "" and acct == selfAccount
        local isFav  = (not isSelf) and Owner.IsFavoriteIn(favorites, key)
        local age    = (o.ts and o.ts > 0) and (now - o.ts) or nil
        -- rank: self(0) < favorite(1) < own-account(2) < cross-account/summary(3). A favorite
        -- outranks its normal group so starring any owner lifts it just under self.
        local rank
        if isSelf then rank = 0 elseif isFav then rank = 1 elseif isOwn then rank = 2 else rank = 3 end
        list[#list + 1] = {
            key = key, name = o.name or key, class = o.class, account = acct,
            source = o.source or "summary",
            isSelf = isSelf, isOwnAccount = isOwn and true or false,
            isFavorite = isFav and true or false,
            ageSeconds = age, hasBank = Owner.HasBankData(o),
            rank = rank,
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

----------------------------------------------------------------------
-- PURE: the MONEY TOOLTIP model  (1.x core/classes/playerMoney.lua parity)
--
-- 1.x anatomy, verified line-by-line against playerMoney.lua:88-151:
--
--   Money                                    <- SetText(MONEY, 1,1,1) — pure white
--   [12px icon] Charname          1,234g 56s <- class-colored BOTH columns
--   ...                                         (up to 5, PLUS any favorite)
--   [?] Others                      450g 30s <- question-mark icon, NO color args
--                                            <- AddLine(' ') only when `mine` non-empty
--   [A] Other Accounts                       <- account glyph + LIGHTGRAY wrap
--   [12px icon] Altname             221g  4s <- the other-account group, same shape
--   [?] Others                       12g     <- ...with its OWN overflow rollup
--                                            <- AddDoubleLine(' ',' ') + a DRAWN 1px rule
--   Total                         2,893g  2s <- LIGHTGRAY both columns
--
-- Mechanism facts taken from 1.x (behavior only; no code copied):
--   * FILTER  (:96-98) money > 0 AND >= moneyTooltipMinGold * 10000 AND the optional
--             same-faction gate. A filtered-out character contributes to NEITHER the
--             rows NOR the Total.
--   * PARTITION (:99) `owner.meshRemote` — a BOOLEAN on mesh-sourced owners, never an
--             account string. 2.0's exact semantic equivalent is the store's existing
--             `owner.source`: "summary" == imported through the mesh (meshRemote),
--             "full" == locally captured (this account). See Owner.IsOtherAccount.
--   * SORT    (:103-105) money DESC per group. (2.0 adds a name tiebreak so the order
--             is deterministic — 1.x's `sort` is unstable for equal amounts.)
--   * CAP     (:113) `shown < 5 or owner.favorite`, and `shown` increments ONLY on a
--             rendered row. Net effect: the first 5 rows, plus EVERY favorite no matter
--             how far down the list it sits. A favorite can never fall into "Others".
--   * TOTAL   (:122) `total = total + money` sits in the group loop OUTSIDE the
--             shown/overflow branch, so the Total is the sum of every character that
--             PASSED the filter — i.e. exactly the amounts on screen (visible character
--             rows + the "Others" rollups), and never the min-gold-filtered ones.
--   * RULE    (:14-21, :144-147) a blank AddDoubleLine(' ',' ') followed by a real
--             1px (.3,.3,.3) line drawn across the last tooltip line. Always emitted.
--
-- Row kinds: "char" | "others" | "spacer" | "section" | "rule" | "total".
----------------------------------------------------------------------

local OTHERS_LABEL         = "Others"
local OTHER_ACCOUNTS_LABEL = "Other Accounts"

-- Localization hook: v2's flat tree has no locale table yet, so this resolves to the
-- English constants above. When ns.L lands, the labels follow it for free.
local function loc(key, fallback)
    local L = ns.L
    return (type(L) == "table" and L[key]) or fallback
end

-- PURE: 1.x's `meshRemote` boolean, expressed on 2.0's store schema. A "summary" owner
-- is one that only ever arrived through the cross-account mesh (migrate.lua:144), which
-- is precisely the set 1.x tagged meshRemote (meshSync.lua:134). A "full" owner was
-- captured locally on this account (capture.lua:186, migrate.lua:90).
--
-- Why NOT the account string: Store.SetSelfAccount has no live caller anywhere in the
-- tree, so Store.data.selfAccount is permanently "" — and even if it were populated
-- later, every already-captured "full" owner carries account = "" (capture.lua:187) and
-- would misclassify as an other-account character. `source` needs no new persisted
-- state, no migration, and is already correct on live data.
function Owner.IsOtherAccount(char)
    return (type(char) == "table" and char.source == "summary") and true or false
end

-- PURE: the ordered money-tooltip row list.
--   chars = { { key, name, class, account, faction, race, sex, source, favorite, copper }, ... }
--   opts  = { minCopper (default 0, = moneyTooltipMinGold * 10000),
--             maxPerGroup (default 5),
--             sameFactionOnly (bool), selfFaction (this character's faction),
--             isOther (optional predicate; defaults to Owner.IsOtherAccount),
--             favoriteIgnoresMinCopper (bool, default FALSE = 1.x) }
--
-- On favoriteIgnoresMinCopper: in 1.x a favorite pin exempts a character from the
-- 5-ROW CAP only (:113) — the min-gold threshold is a hard pre-filter applied one step
-- earlier (:96-98), so a pinned pauper is still hidden when moneyTooltipMinGold is set.
-- The default here is that verified 1.x behavior. Flip this flag to make the pin win
-- over the threshold as well; it is a one-word change at the single live call site.
function Owner.BuildMoneyReport(chars, opts)
    opts = opts or {}
    local minCopper   = opts.minCopper or 0
    local maxPerGroup = opts.maxPerGroup or 5
    local factionGate = opts.sameFactionOnly and opts.selfFaction and opts.selfFaction ~= ""
    local isOther     = opts.isOther or Owner.IsOtherAccount
    local favPinsMin  = opts.favoriteIgnoresMinCopper and true or false

    -- Filter + partition (1.x :96-99).
    local mine, others = {}, {}
    for _, c in ipairs(chars or {}) do
        -- Same-faction filter: drop opposite-faction characters entirely (rows + total).
        -- Unknown faction (nil) is KEPT — 2.0 never hides gold it cannot prove is
        -- cross-faction. (This is a deliberate, pre-existing divergence from 1.x, which
        -- excludes an unknown faction; it is not part of this defect.)
        if not (factionGate and c.faction ~= nil and c.faction ~= opts.selfFaction) then
            local copper = c.copper or 0
            if copper > 0 and (copper >= minCopper or (favPinsMin and c.favorite)) then
                local row = {
                    kind = "char", key = c.key, name = c.name or "?", class = c.class,
                    account = c.account or "", source = c.source or "summary",
                    faction = c.faction, race = c.race, sex = c.sex,
                    favorite = c.favorite and true or false,
                    copper = copper,
                }
                if isOther(c) then others[#others + 1] = row else mine[#mine + 1] = row end
            end
        end
    end

    -- Sort: money DESC, then name ASC (deterministic tiebreak; 1.x :103-105).
    local function sortGroup(g)
        table.sort(g, function(a, b)
            if a.copper ~= b.copper then return a.copper > b.copper end
            return tostring(a.name):lower() < tostring(b.name):lower()
        end)
    end
    sortGroup(mine); sortGroup(others)

    -- Emit (1.x renderGroup, :109-127). `shown` counts RENDERED rows only, and a
    -- favorite renders regardless of the cap. `total` accumulates AFTER the filter and
    -- for BOTH rendered and rolled-up rows, so Total == the sum of what is on screen.
    local rows, total = {}, 0
    local function emitGroup(g)
        local shown, overflow = 0, 0
        for _, row in ipairs(g) do
            if shown < maxPerGroup or row.favorite then
                rows[#rows + 1] = row
                shown = shown + 1
            else
                overflow = overflow + row.copper
            end
            total = total + row.copper
        end
        if overflow > 0 then
            rows[#rows + 1] = { kind = "others", copper = overflow }
        end
    end

    emitGroup(mine)
    if #others > 0 then
        -- 1.x :131-134 — the separating blank line only when this account had rows.
        if #mine > 0 then rows[#rows + 1] = { kind = "spacer" } end
        rows[#rows + 1] = { kind = "section", label = loc("OtherAccounts", OTHER_ACCOUNTS_LABEL) }
        emitGroup(others)
    end
    -- 1.x :144-149 — the blank line + drawn rule, then the grand total. Always emitted,
    -- even with zero characters (the header/rule/Total footer is the frame of the tip).
    rows[#rows + 1] = { kind = "rule" }
    rows[#rows + 1] = { kind = "total", copper = total }
    return rows
end

----------------------------------------------------------------------
-- PURE: money-row presentation helpers (1.x row format)
----------------------------------------------------------------------

-- Classic Era character-create race sheet + its 4x4 UV grid (male rows, then female),
-- and the faction banners 1.x falls back to when the race is unknown (owners.lua:9-34,
-- :142-152). Coordinates are behavior facts read off the 1.x tree, not copied code.
local RACE_SHEET      = "Interface/Glues/CharacterCreate/UI-CharacterCreate-Races"
local ALLIANCE_BANNER = "Interface/Icons/Inv_BannerPvP_02"
local HORDE_BANNER    = "Interface/Icons/Inv_BannerPvP_01"
local RACE_UV = {
    HUMAN_MALE      = { 0,    0.25, 0,    0.25 },
    DWARF_MALE      = { 0.25, 0.5,  0,    0.25 },
    GNOME_MALE      = { 0.5,  0.75, 0,    0.25 },
    NIGHTELF_MALE   = { 0.75, 1.0,  0,    0.25 },
    TAUREN_MALE     = { 0,    0.25, 0.25, 0.5  },
    SCOURGE_MALE    = { 0.25, 0.5,  0.25, 0.5  },
    TROLL_MALE      = { 0.5,  0.75, 0.25, 0.5  },
    ORC_MALE        = { 0.75, 1.0,  0.25, 0.5  },
    HUMAN_FEMALE    = { 0,    0.25, 0.5,  0.75 },
    DWARF_FEMALE    = { 0.25, 0.5,  0.5,  0.75 },
    GNOME_FEMALE    = { 0.5,  0.75, 0.5,  0.75 },
    NIGHTELF_FEMALE = { 0.75, 1.0,  0.5,  0.75 },
    TAUREN_FEMALE   = { 0,    0.25, 0.75, 1.0  },
    SCOURGE_FEMALE  = { 0.25, 0.5,  0.75, 1.0  },
    TROLL_FEMALE    = { 0.5,  0.75, 0.75, 1.0  },
    ORC_FEMALE      = { 0.75, 1.0,  0.75, 1.0  },
}

-- PURE: race sheet UVs for a stored (race, sex) pair. `race` is UnitRace's FILE tag
-- (capture.lua:53-56 — "Scourge", "NightElf", ...); sex 3 = female, anything else male
-- (1.x owners.lua:145). Returns nil when the race is unknown (-> faction banner).
function Owner.RaceIconUV(race, sex)
    if type(race) ~= "string" or race == "" then return nil end
    local key = (race:upper():gsub("%s+", "")) .. "_" .. (sex == 3 and "FEMALE" or "MALE")
    return RACE_UV[key]
end

-- The 12px row icon markup (1.x playerMoney.lua:115 -> owners.lua:132-153): a race
-- portrait cropped out of the 128x128 race sheet, or the faction banner when the race
-- is unknown. Uses Blizzard's CreateTextureMarkup in-game; hand-builds the identical
-- escape headless so the harness sees the same row shape.
function Owner.IconMarkup(race, sex, faction, size)
    size = size or 12
    local uv  = Owner.RaceIconUV(race, sex)
    local tex = uv and RACE_SHEET
                or ((faction == "Alliance") and ALLIANCE_BANNER or HORDE_BANNER)
    local l, r, t, b
    if uv then l, r, t, b = uv[1], uv[2], uv[3], uv[4] else l, r, t, b = 0, 1, 0, 1 end
    if _G.CreateTextureMarkup then
        return _G.CreateTextureMarkup(tex, 128, 128, size, size, l, r, t, b, 0, 0)
    end
    return string.format("|T%s:%d:%d:0:0:128:128:%d:%d:%d:%d|t",
        tex, size, size, l * 128, r * 128, t * 128, b * 128)
end

-- PURE: thousands separator for the headless coin fallback (in-game this comes from
-- Blizzard's BreakUpLargeNumbers, inside GetMoneyString).
function Owner.GroupDigits(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s
    while true do
        local rep
        out, rep = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if rep == 0 then break end
    end
    return out
end

-- Coin string, 1.x parity: GetMoneyString(copper, true) — coin-icon textures, gold
-- thousands-separated, zero denominations suppressed (playerMoney.lua:114/:149; both
-- the row and the total formatter reduce to this on Era, the 1.x third argument being
-- ignored by the 1.15 signature GetMoneyString(money, separateThousands)).
-- GetCoinTextureString is the intermediate fallback; the last branch mirrors
-- GetMoneyString's own shape so the headless tests assert real behavior.
function Owner.FormatCoins(copper)
    copper = copper or 0
    if _G.GetMoneyString then return _G.GetMoneyString(copper, true) end
    if _G.GetCoinTextureString then return _G.GetCoinTextureString(copper) end
    local g, s, c = Store.MoneyParts(copper)
    local parts = {}
    if g > 0 then parts[#parts + 1] = Owner.GroupDigits(g) .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
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

-- Live favorites map (DaseekiBags2DB.ownerFavorites), lazily created on first star.
local function favoritesMap(create)
    local db = Store and Store.db
    if not db then return nil end
    if type(db.ownerFavorites) ~= "table" then
        if not create then return nil end
        db.ownerFavorites = {}
    end
    return db.ownerFavorites
end

function Owner.IsFavorite(key)
    return Owner.IsFavoriteIn(favoritesMap(false), key)
end

-- Flip a favorite. Returns the new state (true = now favorite). Self is never favorited
-- (it always sorts first anyway) — a no-op that returns false.
function Owner.ToggleFavorite(key)
    if type(key) ~= "string" or key == "" or key == Owner.SelfKey() then return false end
    local fav = favoritesMap(true)
    if not fav then return false end
    if fav[key] then fav[key] = nil; return false end
    fav[key] = true; return true
end

-- Remove a cached owner, guarded so the live self can NEVER be deleted. Also drops any
-- favorite/viewed state pointing at it. Returns true when a removal happened.
function Owner.RemoveOwner(key)
    if not Owner.CanRemove(key, Owner.SelfKey()) then return false end
    if not (Store and Store.RemoveOwner and Store.GetOwner and Store.GetOwner(key)) then return false end
    Store.RemoveOwner(key)
    local fav = favoritesMap(false)
    if fav then fav[key] = nil end
    -- if we were viewing the removed owner, snap the view back to self (live)
    if ns.Frame and ns.Frame.ViewedOwnerKey and ns.Frame.ViewedOwnerKey() == key
       and ns.Frame.SetViewedOwner then
        ns.Frame.SetViewedOwner(nil)
    end
    return true
end

-- Build the descriptor list live from the store.
function Owner.LiveList()
    local data = Store and Store.data
    local owners = data and data.owners or {}
    return Owner.BuildOwnerList(owners, Owner.SelfKey(), data and data.selfAccount, Store.Now(),
        favoritesMap(false))
end

-- Plain confirm before deleting a cached owner (audit 5.5). Uses the FrameXML StaticPopup
-- surface when present; a stripped/headless client without it simply no-ops (fail-safe: no
-- silent delete). The removal itself runs through Owner.RemoveOwner, which self-guards.
local REMOVE_POPUP = "DASEEKIBAGS2_REMOVE_OWNER"
local function confirmRemoveOwner(key, name, onDone)
    if not (_G.StaticPopupDialogs and _G.StaticPopup_Show) then return end
    _G.StaticPopupDialogs[REMOVE_POPUP] = _G.StaticPopupDialogs[REMOVE_POPUP] or {
        text = "Remove %s's cached data? This cannot be undone.",
        button1 = _G.YES or "Yes",
        button2 = _G.NO or "No",
        timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true,
        OnAccept = function(_, data)
            if data and Owner.RemoveOwner(data.key) and data.onDone then data.onDone() end
        end,
    }
    _G.StaticPopup_Show(REMOVE_POPUP, name or key, nil, { key = key, onDone = onDone })
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

        -- Favorite STAR (far right): ★ lit when favorite, ☆ idle otherwise. Toggles the
        -- favorite and re-populates so the row re-sorts to the top. Non-self only (self is
        -- always first); hidden on the self row.
        row._star = _G.CreateFrame("Button", nil, row)
        row._star:SetSize(16, 16)
        row._star:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row._starFS = row._star:CreateFontString(nil, "OVERLAY")
        row._starFS:SetFontObject(UI.fonts.body)
        row._starFS:SetPoint("CENTER", row._star, "CENTER", 0, 0)

        -- DELETE ✕ (left of the star), non-self only. Opens a plain confirm before removing the
        -- cached owner (never the live self — guarded downstream). Danger-tinted on hover.
        row._del = _G.CreateFrame("Button", nil, row)
        row._del:SetSize(16, 16)
        row._del:SetPoint("RIGHT", row._star, "LEFT", -2, 0)
        row._delFS = row._del:CreateFontString(nil, "OVERLAY")
        row._delFS:SetFontObject(UI.fonts.body)
        row._delFS:SetPoint("CENTER", row._del, "CENTER", 0, 0)
        row._delFS:SetText("\195\151")   -- ✕ (U+00D7 multiplication sign)
        row._del:SetScript("OnEnter", function() if row._delFS then row._delFS:SetTextColor(UI.Color("danger")) end end)
        row._del:SetScript("OnLeave", function() if row._delFS then row._delFS:SetTextColor(UI.Color("muted")) end end)

        row._fresh = row:CreateFontString(nil, "OVERLAY")
        row._fresh:SetFontObject(UI.fonts.small)
        row._fresh:SetPoint("RIGHT", row._del, "LEFT", -6, 0)
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

            -- Favorite star: lit ★ when favorite, idle ☆ otherwise. Hidden on the self row.
            if d.isSelf then
                row._star:Hide(); row._del:Hide()
            else
                row._star:Show()
                row._starFS:SetText(d.isFavorite and "\226\152\133" or "\226\152\134")   -- ★ / ☆
                row._starFS:SetTextColor(UI.Color(d.isFavorite and "warn" or "faint"))
                row._star:SetScript("OnClick", function()
                    Owner.ToggleFavorite(d.key)
                    populate()   -- re-sort (favorite rises to the top)
                end)
                -- Delete ✕ → plain confirm, then remove the cached owner (self is never here).
                row._del:Show()
                row._delFS:SetTextColor(UI.Color("muted"))
                row._del:SetScript("OnClick", function()
                    confirmRemoveOwner(d.key, d.name, function()
                        populate()
                        if Owner.RefreshAll then Owner.RefreshAll() end
                    end)
                end)
            end

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

-- =====================================================================
-- MONEY TOOLTIP — live layer
--
-- This section OWNS the cross-character Money tooltip for both windows. ui_frame.lua
-- shipped the first cut of this model (Frame.BuildMoneyReport / Frame.MoneyChars /
-- Frame.RenderMoneyTooltip); the 1.x-parity model lives here instead, and the
-- install block at the bottom of this file re-points Frame.MoneyChars and
-- Frame.RenderMoneyTooltip at it. ui_owner.lua loads AFTER ui_frame.lua in BOTH
-- .tocs and in the harness TOC_ORDER, and both call sites (ui_frame's money-bar
-- OnEnter and ui_bank.lua:231) resolve the function through the ns.Frame table at
-- call time, so the swap is total and needs no edit to either file.
--
-- FOLLOW-UP for the hand-merge: ui_frame.lua's now-unused Frame.BuildMoneyReport
-- (and its self-test) is dead once this lands and should be deleted there, together
-- with the separately-dead Frame.BuildMoneyLines the defect analysis flagged. It is
-- left in place here only because ui_frame.lua is another agent's file this pass.
-- =====================================================================

-- Live per-character money descriptors from the store. Carries everything the 1.x row
-- needs: identity for the 12px icon, `source` for the own/other-account partition, and
-- the favorite flag that exempts a character from the 5-row cap.
function Owner.MoneyChars()
    local out = {}
    local favs = favoritesMap(false)
    if Store and Store.ForEachOwner then
        Store.ForEachOwner(function(key, o)
            out[#out + 1] = {
                key      = key,
                name     = o.name or "?",
                class    = o.class,
                account  = o.account or "",
                source   = o.source or "summary",
                faction  = o.faction,
                race     = o.race,
                sex      = o.sex,
                copper   = o.money or 0,
                favorite = Owner.IsFavoriteIn(favs, key),
            }
        end)
    end
    return out
end

-- 1.x money-row class color (owners.lua:164): honors class-color addons, falls back to
-- plain white for an unknown class (1.x WHITE_FONT_COLOR) rather than the cream token —
-- the money tooltip is a Blizzard-toned surface, not a themed panel.
local function moneyClassRGB(class)
    local c = class and ((_G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS or {})[class])
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- LIGHTGRAY wrap (1.x Money.Gray, playerMoney.lua:11) for the section header + Total.
local function gray(text)
    local col = _G.LIGHTGRAY_FONT_COLOR
    if col and col.WrapTextInColorCode then return col:WrapTextInColorCode(text) end
    return "|cffbbbbbb" .. tostring(text) .. "|r"
end

-- The "Other Accounts" glyph (1.x uses the |A:questlog-questtypeicon-account:0:0|a atlas
-- markup). Atlas markup itself parses on 1.15, but the retail quest-log atlas is not
-- guaranteed present on Era — so resolve it once and fall back to the Battle.net WoW
-- icon, which ships with the Classic client, when the atlas is missing.
local ACCOUNT_ATLAS    = "questlog-questtypeicon-account"
local ACCOUNT_FALLBACK = "|TInterface/FriendsFrame/Battlenet-WoWicon:12:12|t"
local accountGlyphCache
local function accountGlyph()
    if accountGlyphCache then return accountGlyphCache end
    local info = _G.C_Texture and _G.C_Texture.GetAtlasInfo
                 and _G.C_Texture.GetAtlasInfo(ACCOUNT_ATLAS)
    if info and _G.CreateAtlasMarkup then
        accountGlyphCache = _G.CreateAtlasMarkup(ACCOUNT_ATLAS, 0, 0, 0, 0)
    else
        accountGlyphCache = ACCOUNT_FALLBACK
    end
    return accountGlyphCache
end

-- The "Others" rollup icon (1.x playerMoney.lua:125) — native-size question mark.
local OTHERS_ICON = "|TInterface/Icons/INV_Misc_QuestionMark:0:0|t"

-- The 1px horizontal RULE above Total (1.x playerMoney.lua:14-21, :144-147): a real
-- drawn line, not a text separator. Created lazily per tooltip (never at file scope —
-- this file must stay CreateFrame-free at load) and parented to the tooltip so it dies
-- with it. 1.x hides it from the money frame's OnLeave; both of 2.0's OnLeave handlers
-- live in files this pass does not own, so the frame instead self-hides on the
-- tooltip's own OnHide/OnTooltipCleared — strictly more robust (it also cannot survive
-- an item tooltip reusing GameTooltip).
local rules = setmetatable({}, { __mode = "k" })

local function ensureRule(GT)
    local existing = rules[GT]
    if existing then return existing end
    if not _G.CreateFrame then return nil end
    local f = _G.CreateFrame("Frame", nil, GT)
    f:SetHeight(5)
    local line = f:CreateLine()
    line:SetStartPoint("LEFT", 0, -5)
    line:SetEndPoint("RIGHT", 0, -5)
    line:SetColorTexture(0.3, 0.3, 0.3)
    line:SetThickness(1)
    f:Hide()
    rules[GT] = f
    if GT.HookScript then
        local function hide() f:Hide() end
        pcall(GT.HookScript, GT, "OnHide", hide)
        pcall(GT.HookScript, GT, "OnTooltipCleared", hide)
    end
    return f
end

-- Anchor the rule across the tooltip's LAST line (the blank one just added) and show it.
local function showRule(GT)
    local f = ensureRule(GT)
    if not f or not GT.NumLines or not GT.GetName then return end
    local base = GT:GetName()
    local n    = GT:NumLines()
    if not base or not n or n < 1 then return end
    local left, right = _G[base .. "TextLeft" .. n], _G[base .. "TextRight" .. n]
    if not (left and right) then return end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", left, "TOPLEFT")
    f:SetPoint("TOPRIGHT", right, "TOPRIGHT")
    f:Show()
end

-- Render the 1.x-format cross-character Money tooltip into GT. Shared verbatim by the
-- inventory and bank money bars, so the two windows read identically. All content comes
-- from the pure Owner.BuildMoneyReport; this function only formats and draws.
function Owner.RenderMoneyTooltip(GT)
    if not GT then return end
    GT:ClearLines()
    GT:AddLine(_G.MONEY or "Money", 1, 1, 1)   -- 1.x :90 — pure white header

    local db          = Store and Store.db
    local minGold     = (db and db.moneyTooltipMinGold) or 0
    local sameFaction = db and db.moneyTooltipFaction == true
    local selfFaction = (_G.UnitFactionGroup and _G.UnitFactionGroup("player")) or nil

    local rows = Owner.BuildMoneyReport(Owner.MoneyChars(), {
        minCopper       = (minGold or 0) * 10000,
        maxPerGroup     = 5,
        sameFactionOnly = sameFaction,
        selfFaction     = selfFaction,
    })

    for _, row in ipairs(rows) do
        if row.kind == "char" then
            local r, g, b = moneyClassRGB(row.class)
            GT:AddDoubleLine(
                Owner.IconMarkup(row.race, row.sex, row.faction, 12) .. " " .. row.name,
                Owner.FormatCoins(row.copper), r, g, b, r, g, b)
        elseif row.kind == "others" then
            -- 1.x :125 passes NO color args -> default tooltip white, both columns.
            GT:AddDoubleLine(OTHERS_ICON .. " " .. loc("Others", OTHERS_LABEL),
                             Owner.FormatCoins(row.copper))
        elseif row.kind == "spacer" then
            GT:AddLine(" ")
        elseif row.kind == "section" then
            GT:AddLine(accountGlyph() .. " " .. gray(row.label))
        elseif row.kind == "rule" then
            GT:AddDoubleLine(" ", " ")
            showRule(GT)
        elseif row.kind == "total" then
            GT:AddDoubleLine(gray(_G.TOTAL or "Total"), gray(Owner.FormatCoins(row.copper)))
        end
    end
    GT:Show()
end

-- Install over ui_frame's earlier money model (see the section header above).
if ns.Frame then
    ns.Frame.MoneyChars         = Owner.MoneyChars
    ns.Frame.RenderMoneyTooltip = Owner.RenderMoneyTooltip
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
    ck(list[2].rank == 2 and list[3].rank == 2, "own-account rank 2 (favorites occupy rank 1)")
    -- cross-account + summary last (rank 3), alphabetical: Cid then Rex
    ck(list[4].name == "Cid" and not list[4].isOwnAccount, "cross-account Cid fourth")
    ck(list[5].name == "Rex", "summary Rex last")
    ck(list[4].rank == 3 and list[5].rank == 3, "cross-account/summary rank 3")
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
    ck(noAcct[1].isSelf and noAcct[2].rank == 3, "blank selfAccount -> everyone non-self is cross (rank 3)")
end

-- RemoveOwner safety (audit 5.5): the live self is NEVER removable; a cached alt is.
local function testRemoveOwnerSafety(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- pure guard
    ck(Owner.CanRemove("Alt-R", "Self-R") == true, "an alt is removable")
    ck(Owner.CanRemove("Self-R", "Self-R") == false, "the self key is NOT removable")
    ck(Owner.CanRemove(nil, "Self-R") == false, "nil key not removable")
    ck(Owner.CanRemove("", "Self-R") == false, "empty key not removable")
    ck(Owner.CanRemove("Alt-R", nil) == true, "no self key -> alt still removable")

    -- live path against a real store. In the harness, SelfKey() = "Tester-TestRealm".
    _G.DaseekiBags2DB = nil; _G.DaseekiBags2Data = nil; Store.Init()
    local selfKey = Owner.SelfKey()
    Store.EnsureOwner(selfKey)
    Store.EnsureOwner("Alt-TestRealm")
    ck(Store.OwnerCount() == 2, "two owners seeded")
    -- self cannot be removed
    ck(Owner.RemoveOwner(selfKey) == false, "RemoveOwner refuses the live self")
    ck(Store.GetOwner(selfKey) ~= nil, "self owner survives a delete attempt")
    -- an alt is removed
    ck(Owner.RemoveOwner("Alt-TestRealm") == true, "RemoveOwner removes a cached alt")
    ck(Store.GetOwner("Alt-TestRealm") == nil, "alt owner is gone after removal")
    -- removing a non-existent owner is a safe false
    ck(Owner.RemoveOwner("Ghost-Nowhere") == false, "removing an absent owner -> false")

    -- favorites round-trip on the settings DB
    ck(Owner.IsFavorite("Alt-TestRealm") == false, "nothing favorited initially")
    Store.EnsureOwner("Buddy-TestRealm")
    ck(Owner.ToggleFavorite("Buddy-TestRealm") == true, "toggle on -> favorite")
    ck(Owner.IsFavorite("Buddy-TestRealm") == true, "favorite persists")
    ck(Owner.ToggleFavorite("Buddy-TestRealm") == false, "toggle off -> not favorite")
    ck(Owner.IsFavorite("Buddy-TestRealm") == false, "un-favorite persists")
    ck(Owner.ToggleFavorite(selfKey) == false, "self can never be favorited")
end

-- Favorites sort to the top (audit 5.2): a favorited cross-account owner outranks its
-- normal group, landing just under self.
local function testFavoritesSort(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local owners = {
        ["Zed-R"] = { name = "Zed", class = "MAGE",    account = "acctA", source = "full",  ts = 1000, containers = { [0] = {} } },
        ["Amy-R"] = { name = "Amy", class = "PRIEST",  account = "acctA", source = "full",  ts = 900,  containers = { [0] = {} } },
        ["Cid-R"] = { name = "Cid", class = "ROGUE",   account = "acctB", source = "full",  ts = 500,  containers = { [0] = {} } },
        ["Rex-R"] = { name = "Rex", class = "HUNTER",  account = "",      source = "summary", ts = 0,   containers = {} },
    }
    -- No favorites: Zed(self), then own-account Amy, then cross-account Cid, then summary Rex.
    local base = Owner.BuildOwnerList(owners, "Zed-R", "acctA", 1000, nil)
    ck(base[1].key == "Zed-R" and base[2].key == "Amy-R", "no favorites -> self then own-account")
    ck(base[3].key == "Cid-R", "cross-account next without favorites")

    -- Favorite Cid (a cross-account owner) and Rex (a summary owner): both rise above own-account.
    local favs = { ["Cid-R"] = true, ["Rex-R"] = true }
    local list = Owner.BuildOwnerList(owners, "Zed-R", "acctA", 1000, favs)
    ck(list[1].key == "Zed-R" and list[1].rank == 0, "self still first")
    ck(list[2].isFavorite and list[3].isFavorite, "both favorites occupy ranks 2 & 3 rows")
    ck(list[2].rank == 1 and list[3].rank == 1, "favorites share rank 1 (above own-account)")
    -- within the favorite group, alphabetical: Cid before Rex
    ck(list[2].key == "Cid-R" and list[3].key == "Rex-R", "favorites alphabetical among themselves")
    -- the non-favorite own-account Amy now sorts BELOW the favorites
    ck(list[4].key == "Amy-R" and list[4].rank == 2, "own-account Amy drops below favorites")
    -- a favorited SELF is ignored (self is never a favorite; always rank 0)
    local selfFav = Owner.BuildOwnerList(owners, "Zed-R", "acctA", 1000, { ["Zed-R"] = true })
    ck(selfFav[1].key == "Zed-R" and selfFav[1].isFavorite == false, "self ignores a favorite flag")
end

----------------------------------------------------------------------
-- Money tooltip (1.x playerMoney.lua parity) — defect #3
----------------------------------------------------------------------

local G = 10000   -- copper per gold

-- Shared fixture: seven own-account ("full") characters and two cross-account/mesh
-- ("summary") characters, deliberately unsorted, one of them a favorite.
local function moneyFixture()
    return {
        { key = "Amy-R", name = "Amy", class = "PRIEST",  source = "full",    faction = "Horde", race = "Orc",      sex = 3, copper = 120 * G },
        { key = "Rex-R", name = "Rex", class = "HUNTER",  source = "summary", faction = "Horde", race = "Troll",    sex = 2, copper = 200 * G },
        { key = "Zed-R", name = "Zed", class = "MAGE",    source = "full",    faction = "Horde", race = "Scourge",  sex = 2, copper = 500 * G },
        { key = "Fay-R", name = "Fay", class = "DRUID",   source = "full",    faction = "Alliance", race = "NightElf", sex = 3, copper = 5 * G },
        { key = "Bob-R", name = "Bob", class = "WARRIOR", source = "full",    faction = "Horde", race = "Tauren",   sex = 2, copper = 300 * G },
        { key = "Sam-R", name = "Sam", class = "ROGUE",   source = "summary", faction = "Horde", race = "Orc",      sex = 2, copper = 40 * G },
        { key = "Dan-R", name = "Dan", class = "SHAMAN",  source = "full",    faction = "Horde", race = "Troll",    sex = 2, copper = 30 * G },
        { key = "Cid-R", name = "Cid", class = "WARLOCK", source = "full",    faction = "Horde", race = "Orc",      sex = 2, copper = 60 * G },
        { key = "Eve-R", name = "Eve", class = "PALADIN", source = "full",    faction = "Alliance", race = "Human", sex = 3, copper = 10 * G },
    }
end

local function kinds(rows)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.kind end
    return table.concat(out, ",")
end

-- The amount actually PAINTED on screen: every char row plus every "Others" rollup.
local function visibleSum(rows)
    local sum = 0
    for _, r in ipairs(rows) do
        if r.kind == "char" or r.kind == "others" then sum = sum + (r.copper or 0) end
    end
    return sum
end

local function totalOf(rows)
    for _, r in ipairs(rows) do if r.kind == "total" then return r.copper end end
    return nil
end

-- The own-account vs other-account PARTITION mechanism (defect #3 headline): the store's
-- `source` discriminator, not the permanently-empty selfAccount string.
local function testMoneyPartition(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Owner.IsOtherAccount({ source = "summary" }) == true,  "summary source -> other account")
    ck(Owner.IsOtherAccount({ source = "full" }) == false,    "full source -> this account")
    ck(Owner.IsOtherAccount({ source = nil }) == false,       "missing source -> this account")
    ck(Owner.IsOtherAccount(nil) == false,                    "nil char -> not other account")
    -- The account STRING must play no part: every fixture char carries account "" (which
    -- is what capture/migrate actually write), and the section must still render.
    local chars = moneyFixture()
    for _, c in ipairs(chars) do c.account = "" end
    local rows = Owner.BuildMoneyReport(chars, {})
    local sawSection = false
    for _, r in ipairs(rows) do if r.kind == "section" then sawSection = true end end
    ck(sawSection, "Other Accounts section renders with EMPTY account strings on every char")
    -- ...and an explicit predicate override still wins (partition is injectable).
    local none = Owner.BuildMoneyReport(chars, { isOther = function() return false end })
    for _, r in ipairs(none) do ck(r.kind ~= "section", "isOther override suppresses the section") end
end

-- Full 1.x anatomy on the mixed fixture: 5 own rows + rollup, spacer, section header,
-- the other-account rows, the rule, then Total.
local function testMoneyAnatomy(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rows = Owner.BuildMoneyReport(moneyFixture(), {})
    ck(kinds(rows) == "char,char,char,char,char,others,spacer,section,char,char,rule,total",
       "1.x anatomy order (got: " .. kinds(rows) .. ")")
    -- own-account rows, money DESC
    ck(rows[1].name == "Zed" and rows[2].name == "Bob" and rows[3].name == "Amy"
       and rows[4].name == "Cid" and rows[5].name == "Dan", "own rows sorted money DESC")
    ck(rows[6].copper == 15 * G, "own overflow rollup = Eve 10g + Fay 5g")
    ck(rows[8].label == "Other Accounts", "section header label")
    ck(rows[9].name == "Rex" and rows[10].name == "Sam", "other-account rows sorted money DESC")
    ck(rows[9].source == "summary" and rows[10].source == "summary", "section holds only summary chars")
    ck(rows[#rows - 1].kind == "rule" and rows[#rows].kind == "total", "rule sits immediately above Total")
    -- rows carry the identity the 12px icon needs
    ck(rows[1].race == "Scourge" and rows[1].sex == 2, "char row carries race/sex for the icon")

    -- No summary owners -> no spacer, no section (and still rule + total).
    local onlyMine = {}
    for _, c in ipairs(moneyFixture()) do if c.source == "full" then onlyMine[#onlyMine + 1] = c end end
    local r2 = Owner.BuildMoneyReport(onlyMine, {})
    ck(kinds(r2) == "char,char,char,char,char,others,rule,total", "no summary chars -> no section")

    -- ONLY summary owners -> section with NO leading spacer (1.x :131 gates the blank
    -- line on the own-account group being non-empty).
    local onlyOthers = {}
    for _, c in ipairs(moneyFixture()) do if c.source == "summary" then onlyOthers[#onlyOthers + 1] = c end end
    local r3 = Owner.BuildMoneyReport(onlyOthers, {})
    ck(kinds(r3) == "section,char,char,rule,total", "summary-only -> section with no spacer")

    -- Each group gets its OWN rollup (1.x renderGroup is called per group).
    local many = {}
    for i = 1, 7 do many[#many + 1] = { name = "F" .. i, source = "full",    copper = (100 - i) * G } end
    for i = 1, 7 do many[#many + 1] = { name = "S" .. i, source = "summary", copper = (50 - i) * G } end
    local r4 = Owner.BuildMoneyReport(many, {})
    ck(kinds(r4) == "char,char,char,char,char,others,spacer,section,char,char,char,char,char,others,rule,total",
       "two groups -> two Others rollups (got: " .. kinds(r4) .. ")")

    -- Empty input still frames the tooltip (header/rule/Total are always drawn).
    local r5 = Owner.BuildMoneyReport({}, {})
    ck(kinds(r5) == "rule,total" and totalOf(r5) == 0, "no characters -> rule + zero Total")
    ck(kinds(Owner.BuildMoneyReport(nil, nil)) == "rule,total", "nil args are safe")
    -- Zero-gold characters never appear (1.x money > 0).
    local r6 = Owner.BuildMoneyReport({ { name = "Broke", source = "full", copper = 0 } }, {})
    ck(kinds(r6) == "rule,total" and totalOf(r6) == 0, "0 copper char is filtered out")
end

-- The 5-row cap, the favorite exemption from it, and the min-gold display filter.
local function testMoneyCapAndFavorites(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Baseline: Fay (5g, 7th richest) is capped into the rollup.
    local base = Owner.BuildMoneyReport(moneyFixture(), {})
    local sawFay = false
    for _, r in ipairs(base) do if r.name == "Fay" then sawFay = true end end
    ck(not sawFay, "7th-richest char falls into Others without a favorite pin")

    -- Favorited: Fay renders anyway, and the rollup shrinks to just Eve.
    local chars = moneyFixture()
    for _, c in ipairs(chars) do if c.name == "Fay" then c.favorite = true end end
    local fav = Owner.BuildMoneyReport(chars, {})
    ck(kinds(fav) == "char,char,char,char,char,char,others,spacer,section,char,char,rule,total",
       "favorite renders a 6th own-account row (got: " .. kinds(fav) .. ")")
    ck(fav[6].name == "Fay" and fav[6].favorite == true, "the favorite is the extra row, in money order")
    ck(fav[7].copper == 10 * G, "rollup now holds Eve only")
    ck(totalOf(fav) == totalOf(base), "pinning a favorite does not change the Total")

    -- A favorite in the OTHER-ACCOUNTS group is exempt there too.
    local many = {}
    for i = 1, 7 do many[#many + 1] = { name = "S" .. i, source = "summary", copper = (50 - i) * G } end
    many[7].favorite = true                                   -- S7, the poorest
    local r = Owner.BuildMoneyReport(many, {})
    ck(kinds(r) == "section,char,char,char,char,char,char,others,rule,total",
       "favorite exempt from the cap inside Other Accounts (got: " .. kinds(r) .. ")")

    -- maxPerGroup is honored/injectable.
    local cap2 = Owner.BuildMoneyReport(moneyFixture(), { maxPerGroup = 2 })
    ck(kinds(cap2) == "char,char,others,spacer,section,char,char,rule,total", "maxPerGroup = 2")

    -- MIN-GOLD is a hard pre-filter, exactly as in 1.x (:96-98) — it runs BEFORE the
    -- favorite check (:113), so a favorite below the threshold is still hidden. Set
    -- opts.favoriteIgnoresMinCopper to relax that.
    local minChars = moneyFixture()
    for _, c in ipairs(minChars) do if c.name == "Fay" then c.favorite = true end end
    local strict = Owner.BuildMoneyReport(minChars, { minCopper = 50 * G })
    ck(kinds(strict) == "char,char,char,char,spacer,section,char,rule,total",
       "minGold 50g drops Dan/Eve/Fay and Sam (got: " .. kinds(strict) .. ")")
    for _, r2 in ipairs(strict) do ck(r2.name ~= "Fay", "1.x: a favorite below minGold is still filtered") end

    local relaxed = Owner.BuildMoneyReport(minChars, { minCopper = 50 * G, favoriteIgnoresMinCopper = true })
    local sawFav = false
    for _, r2 in ipairs(relaxed) do if r2.name == "Fay" then sawFav = true end end
    ck(sawFav, "favoriteIgnoresMinCopper = true keeps a pinned char below the threshold")
    ck(totalOf(relaxed) == totalOf(strict) + 5 * G, "the relaxed favorite also joins the Total")
end

-- Total math: 1.x accumulates AFTER the money>0 / minGold / faction filter, so the Total
-- always equals the sum of what is on screen (char rows + the Others rollups).
local function testMoneyTotals(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local rows = Owner.BuildMoneyReport(moneyFixture(), {})
    ck(totalOf(rows) == 1265 * G, "unfiltered Total = every character (1265g)")
    ck(totalOf(rows) == visibleSum(rows), "Total == sum of the painted rows")

    -- With minGold set, the filtered-out characters must NOT be in the Total. This is the
    -- defect: the old model accumulated before the filter and would still report 1265g.
    local filt = Owner.BuildMoneyReport(moneyFixture(), { minCopper = 50 * G })
    ck(totalOf(filt) == 1180 * G, "minGold 50g -> Total = 500+300+120+60+200 = 1180g")
    ck(totalOf(filt) ~= 1265 * G, "Total no longer includes min-gold-filtered characters")
    ck(totalOf(filt) == visibleSum(filt), "Total == sum of the painted rows under minGold")

    -- Capped-into-Others gold still counts (1.x accumulates for overflow rows too).
    local capped = Owner.BuildMoneyReport(moneyFixture(), { maxPerGroup = 1 })
    ck(totalOf(capped) == 1265 * G, "rolled-up gold stays in the Total")
    ck(totalOf(capped) == visibleSum(capped), "Total == rows + rollups when capped hard")

    -- Same-faction gate removes rows AND their gold (Fay 5g + Eve 10g are Alliance).
    local horde = Owner.BuildMoneyReport(moneyFixture(),
        { sameFactionOnly = true, selfFaction = "Horde" })
    ck(totalOf(horde) == 1250 * G, "same-faction gate drops Alliance gold from the Total")
    ck(totalOf(horde) == visibleSum(horde), "Total == painted rows under the faction gate")
    -- ...and an unknown (nil) faction is kept — 2.0 never hides gold it cannot prove.
    local unknown = Owner.BuildMoneyReport({ { name = "Ghost", source = "full", copper = 7 * G } },
        { sameFactionOnly = true, selfFaction = "Horde" })
    ck(totalOf(unknown) == 7 * G, "nil faction is kept under the faction gate")
end

-- Row presentation: the 12px race icon markup and the 1.x coin formatter.
local function testMoneyFormatting(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- race sheet UVs (male rows, then female)
    ck(Owner.RaceIconUV("Human", 2)[1] == 0 and Owner.RaceIconUV("Human", 2)[3] == 0, "human male UV")
    ck(Owner.RaceIconUV("Human", 3)[3] == 0.5, "human female drops to the third UV row")
    ck(Owner.RaceIconUV("NightElf", 2)[1] == 0.75, "NightElf tag resolves (no space, upper)")
    ck(Owner.RaceIconUV("Scourge", 3)[1] == 0.25 and Owner.RaceIconUV("Scourge", 3)[3] == 0.75,
       "Scourge female UV")
    ck(Owner.RaceIconUV("Orc", 1) == Owner.RaceIconUV("Orc", 2), "sex 1 (unknown) reads as male")
    ck(Owner.RaceIconUV("Draenei", 2) == nil, "a non-Era race has no UV -> banner fallback")
    ck(Owner.RaceIconUV(nil, 2) == nil and Owner.RaceIconUV("", 2) == nil, "nil/empty race -> nil")

    -- markup: race portrait, else faction banner
    local m = Owner.IconMarkup("Orc", 2, "Horde", 12)
    ck(type(m) == "string" and m:find("UI%-CharacterCreate%-Races") ~= nil, "race icon uses the race sheet")
    ck(m:find(":12:12") ~= nil, "row icon is sized 12x12")
    local ally = Owner.IconMarkup(nil, nil, "Alliance", 12)
    ck(ally:find("Inv_BannerPvP_02") ~= nil, "unknown race + Alliance -> alliance banner")
    local horde = Owner.IconMarkup("Draenei", 2, "Horde", 12)
    ck(horde:find("Inv_BannerPvP_01") ~= nil, "unknown race + Horde -> horde banner")

    -- thousands separator
    ck(Owner.GroupDigits(0) == "0", "0 -> 0")
    ck(Owner.GroupDigits(999) == "999", "999 unchanged")
    ck(Owner.GroupDigits(1204) == "1,204", "1204 -> 1,204")
    ck(Owner.GroupDigits(1234567) == "1,234,567", "1234567 -> 1,234,567")

    -- coin string: gold thousands-separated, zero denominations suppressed (1.x shape)
    ck(Owner.FormatCoins(12345678) == "1,234g 56s 78c", "full coin string, separated")
    ck(Owner.FormatCoins(12340000) == "1,234g", "zero silver+copper suppressed")
    ck(Owner.FormatCoins(5600) == "56s", "gold-less amount")
    ck(Owner.FormatCoins(0) == "0c", "zero renders as 0c, never empty")
    ck(Owner.FormatCoins(nil) == "0c", "nil copper is safe")
end

function Owner.RunSelfTests(verbose)
    local suites = {
        { name = "freshness + badge",   fn = testFreshnessAndBadge },
        { name = "has bank data",       fn = testHasBankData },
        { name = "owner-list ordering", fn = testOwnerListOrdering },
        { name = "remove-owner safety", fn = testRemoveOwnerSafety },
        { name = "favorites sort",      fn = testFavoritesSort },
        { name = "money: partition",    fn = testMoneyPartition },
        { name = "money: 1.x anatomy",  fn = testMoneyAnatomy },
        { name = "money: cap + favorites", fn = testMoneyCapAndFavorites },
        { name = "money: totals math",  fn = testMoneyTotals },
        { name = "money: row format",   fn = testMoneyFormatting },
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
