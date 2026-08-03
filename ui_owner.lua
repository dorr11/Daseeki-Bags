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

-- PURE: the COMPRESSED freshness label — the character MENU's age column (header-selector
-- round, owner directive 2: "instead of 'Updated 5d ago' just put '5d'").
--
-- FreshnessLabel above is unchanged and still the long form; it is what the BANK window's
-- titlebar stamp reads (ui_bank Rebuild), where the sentence is the whole point — that
-- stamp is a standing caption on an offline view, not a column header. In the menu the
-- word "Updated" repeats on every one of up to ~30 rows and the word "ago" repeats after
-- it, so the only glyphs that ever differ are the number and the unit. Dropping the two
-- constant words takes the column from 104px to 44 and the whole menu 60px narrower.
--
-- The two NON-age states keep their words, because they are not durations and a bare
-- token cannot say them: self reads "Online" (it is the live character, not a snapshot)
-- and a never-captured owner reads "No data". Both fit the 44px column at the micro size.
-- Sub-minute compresses to "now" rather than "0m", which would read as a stopped clock.
function Owner.AgeLabel(ageSeconds, isSelf)
    if isSelf then return "Online" end
    if not ageSeconds or ageSeconds < 0 then return "No data" end
    if ageSeconds < 60    then return "now" end
    if ageSeconds < 3600  then return string.format("%dm", math.floor(ageSeconds / 60)) end
    if ageSeconds < 86400 then return string.format("%dh", math.floor(ageSeconds / 3600)) end
    return string.format("%dd", math.floor(ageSeconds / 86400))
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
-- PURE: the SELECTOR MENU LAYOUT  (display round, ITEM 6)
--
-- The beta drew the flyout rows by chaining anchors off each other — badge anchored to
-- the name's RIGHT, freshness anchored to the delete button's LEFT, and the NAME itself
-- with no width at all. With a long character name (or a long "Updated 12d ago") the
-- chain simply ran the columns THROUGH each other: name, FULL/SUMMARY tag, age, the
-- remove ✕ and the star all drew on top of one another.
--
-- The fix is real COLUMNS: fixed x-offsets and fixed widths, computed once per populate
-- from the widest name actually in the list, with the menu widening to fit. The name
-- column is clamped so one absurd name cannot push the age column off the menu; a name
-- past the clamp ellipsizes (SetWordWrap(false) on a width-constrained fontstring).
--
--   [8][pip 6][6][ NAME (class color, clamped) ][8][ TAG ][8][AGE][8][✕][2][★][8]
--
-- The AGE column is the compressed one (Owner.AgeLabel — "5d", not "Updated 5d ago"),
-- which is what let it drop from 104px to 44; the two CONTROL columns went the other way,
-- 16 -> 18, because the favourite star is now a drawn glyph rather than a font character
-- and needed the extra pixels to read. Net: the menu is ~56px narrower than the footer
-- round shipped.
--
-- Metadata (tag + age) drops to the small/micro font in muted ink so a ~30-row menu
-- reads as one scannable column of NAMES with quiet annotations, not five competing
-- text runs. Rows past MENU_MAX_H scroll (the frame layer parents them to a ScrollFrame).
----------------------------------------------------------------------

Owner.MENU = {
    PAD_L    = 8,    -- left inset to the seal pip
    PIP      = 6,
    PIP_GAP  = 6,
    NAME_MIN = 90,   -- the name column never collapses below this
    NAME_MAX = 190,  -- …nor grows past it (a long name ellipsizes instead)
    COL_GAP  = 8,
    BADGE_W  = 58,   -- fits "SUMMARY" at the micro-label size
    AGE_W    = 44,   -- fits the compressed "27d" / "Online" / "No data" (Owner.AgeLabel)
    CTRL_W   = 18,   -- the ✕ and the ★ (18, not 16: the star is drawn art now — see below)
    CTRL_GAP = 2,
    PAD_R    = 8,
    ROW_H    = 22,
    ROW_GAP  = 2,
}
Owner.MENU_MAX_H = 420   -- ~17 rows before the list starts scrolling

-- PURE: the column geometry for a menu whose widest name measures `nameWidth` px.
-- Returns { nameW, x = { pip, name, badge, age }, width } — every x is an offset from
-- the row's LEFT edge, and `width` is the menu width those columns require.
function Owner.MenuLayout(nameWidth)
    local M = Owner.MENU
    local nameW = tonumber(nameWidth) or 0
    if nameW < M.NAME_MIN then nameW = M.NAME_MIN end
    if nameW > M.NAME_MAX then nameW = M.NAME_MAX end
    local x = {}
    x.pip   = M.PAD_L
    x.name  = x.pip + M.PIP + M.PIP_GAP
    x.badge = x.name + nameW + M.COL_GAP
    x.age   = x.badge + M.BADGE_W + M.COL_GAP
    local width = x.age + M.AGE_W + M.COL_GAP
                + M.CTRL_W + M.CTRL_GAP + M.CTRL_W + M.PAD_R
    return { nameW = nameW, x = x, width = width,
             badgeW = M.BADGE_W, ageW = M.AGE_W, ctrlW = M.CTRL_W }
end

-- PURE: which way the owner flyout opens off its face button.
--
-- HISTORY, because both directions are live decisions and neither is a default:
--   * The selector originally lived in the TITLE row, where the only sane direction is
--     DOWN — the menu hangs over the window it belongs to.
--   * The footer round moved it to the bottom-left corner, where a downward drop would
--     have opened BELOW the window and off the bottom of the screen for anyone whose bags
--     sit low. `grow = "up"` anchors the menu's BOTTOM edge to the button's TOP instead.
--   * The header-selector round moved it BACK to the title row (as the arrow beside the
--     character name), so both windows pass "down" again. The upward growth was a
--     bottom-corner necessity and nothing else; it is kept because it is the correct
--     answer for any future bottom-anchored face, and because it costs one branch.
--
-- Returns point, relPoint, x, y — the four arguments the frame layer feeds SetPoint.
-- Anything other than "up" reads as the original downward drop, so an unset/garbage
-- value can never change an existing call site's behaviour.
function Owner.MenuAnchor(grow)
    if grow == "up" then return "BOTTOMLEFT", "TOPLEFT", 0, 2 end
    return "TOPLEFT", "BOTTOMLEFT", 0, -2
end

-- PURE: the menu's content height for `rowCount` rows, and whether it must scroll.
-- Returns height, needsScroll, scrollRange.
function Owner.MenuHeight(rowCount)
    local M = Owner.MENU
    local n = rowCount or 0
    if n < 0 then n = 0 end
    local content = n * (M.ROW_H + M.ROW_GAP) + M.ROW_GAP
    if content <= Owner.MENU_MAX_H then return content, false, 0 end
    return Owner.MENU_MAX_H, true, content - Owner.MENU_MAX_H
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

-- Where this file finds the addon's own glyph art. Resolved at CALL time off ns.Frame so
-- the two files cannot disagree about the folder, with the literal path as the fallback
-- for a load order (or a stripped tree) where ui_frame is not there.
local function artPath()
    return (ns.Frame and ns.Frame.ART)
           or ("Interface\\AddOns\\" .. tostring(ADDON) .. "\\art\\")
end

-- The header form's footprint: a square that holds the drawn caret beside the title text.
Owner.ARROW_W = 16

-- Create an owner selector — the face that opens the character menu. TWO FORMS:
--
--   HEADER (opts.arrowOnly = true) — the shipping form. A bare dropdown CARET drawn
--     beside the window's gold character NAME, with NO mouse of its own: the window owns
--     one hit area covering the name AND the arrow together and drives this widget through
--     frame:Toggle(anchor). That is deliberate. If the arrow took its own clicks it would
--     be a second mouse-enabled child overlapping the title's hit area at the same frame
--     level, and which of the two got a given click would come down to creation order.
--     One hit area, one answer. (See Frame.TitleClickAction for what each button means.)
--
--   STANDALONE (default) — the original 150px button: seal pip, class-coloured name and a
--     caret, in its own control-filled frame. No live caller since the header round; it is
--     the general form of the widget and the one any future non-title placement would use.
--
--   opts = { onSelect = function(key) ... end, width = <n>, menuGrow = "up"|"down",
--            arrowOnly = <bool> }
-- `menuGrow` is the flyout's direction (see Owner.MenuAnchor); it defaults to the
-- historic downward drop, so an omitted value is exactly the old behaviour.
-- Returns a frame with :Refresh() (re-syncs the face to the current view), :Toggle(anchor)
-- (open/close the menu against `anchor`, defaulting to the widget itself) and
-- :SetHot(bool) (drive the hover tint from the window's hit area, header form).
function Owner.CreateSelector(parent, opts)
    opts = opts or {}
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end

    local arrowOnly = opts.arrowOnly and true or false
    local width  = opts.width or (arrowOnly and Owner.ARROW_W or 150)
    local height = arrowOnly and Owner.ARROW_W or 22
    local frame = _G.CreateFrame("Frame", nil, parent)
    frame:SetSize(width, height)

    local btn, pip, nameFS
    if arrowOnly then
        -- The caret is DRAWN ART, not the text "v" the standalone form used: the suite's
        -- picked faces carry no dropdown glyph, and a lowercase v beside a proper noun
        -- reads as part of the name. `muted` at rest, `accent` while the window's title
        -- hit area is hovered (SetHot), matching every other control in the row.
        local caretTex = frame:CreateTexture(nil, "OVERLAY")
        caretTex:SetAllPoints(frame)
        caretTex:SetTexture(artPath() .. "icon-caret-down")
        UI.Skin(caretTex, function(self)
            self:SetVertexColor(UI.Color(frame._hot and "accent" or "muted"))
        end)
        frame._caret = caretTex
        function frame:SetHot(hot)
            self._hot = hot and true or nil
            if self._caret then self._caret:SetVertexColor(UI.Color(self._hot and "accent" or "muted")) end
        end
    else
        -- The face button (current owner + caret), quiet control fill, crimson hover.
        btn = _G.CreateFrame("Button", nil, frame, "BackdropTemplate")
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
        pip = btn:CreateTexture(nil, "OVERLAY")
        pip:SetSize(6, 6)
        pip:SetPoint("LEFT", btn, "LEFT", 6, 0)

        nameFS = btn:CreateFontString(nil, "OVERLAY")
        nameFS:SetFontObject(UI.fonts.body)
        nameFS:SetPoint("LEFT", pip, "RIGHT", 5, 0)
        nameFS:SetPoint("RIGHT", btn, "RIGHT", -22, 0)   -- clears the caret's 16px + inset
        nameFS:SetJustifyH("LEFT")
        nameFS:SetWordWrap(false)

        -- Parented to the BUTTON, not the outer frame: the button carries the backdrop, so
        -- a caret drawn on the frame behind it would be painted over by the control fill.
        local caret = btn:CreateTexture(nil, "OVERLAY")
        caret:SetSize(Owner.ARROW_W, Owner.ARROW_W)
        caret:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
        caret:SetTexture(artPath() .. "icon-caret-down")
        UI.Skin(caret, function(self) self:SetVertexColor(UI.Color("muted")) end)
    end

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

        -- ITEM 6: a ~30-owner menu is taller than most screens, so the rows live in a
        -- ScrollFrame (which also clips them to the panel, so no row can draw over the
        -- backdrop edge). The scroll range is set per populate from Owner.MenuHeight.
        local scroll = _G.CreateFrame("ScrollFrame", nil, popup)
        scroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -2)
        scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -2, 2)
        local content = _G.CreateFrame("Frame", nil, scroll)
        content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local range = self._range or 0
            if range <= 0 then return end
            local v = (self:GetVerticalScroll() or 0) - delta * (Owner.MENU.ROW_H + Owner.MENU.ROW_GAP)
            if v < 0 then v = 0 elseif v > range then v = range end
            self:SetVerticalScroll(v)
        end)
        popup._scroll, popup._content = scroll, content

        closer = _G.CreateFrame("Button", nil, _G.UIParent)
        closer:SetFrameStrata("FULLSCREEN_DIALOG")
        closer:SetAllPoints(_G.UIParent)
        closer:Hide()
        closer:SetScript("OnClick", function() popup:Hide() end)
        popup:SetScript("OnHide", function() closer:Hide() end)
    end

    -- Pool one register row. Every column is anchored to the row's LEFT at a fixed
    -- offset with a fixed width (ITEM 6) — the old anchor CHAIN is what let the columns
    -- pile onto each other. Offsets/widths come from Owner.MenuLayout at populate time.
    local function acquireRow(i)
        local row = popup._rows[i]
        if row then return row end
        row = _G.CreateFrame("Button", nil, popup._content)
        row:SetHeight(Owner.MENU.ROW_H)
        local rh = row:CreateTexture(nil, "BACKGROUND")
        rh:SetAllPoints(); rh:Hide()
        UI.Skin(rh, function(self) self:SetColorTexture(UI.Color("brand", 0.20)) end)
        row._hl = rh
        -- A quieter standing wash marks the row currently being VIEWED, so "(viewing)"
        -- no longer has to eat the name column to say so.
        local cur = row:CreateTexture(nil, "BACKGROUND")
        cur:SetAllPoints(); cur:Hide()
        UI.Skin(cur, function(self) self:SetColorTexture(UI.Color("brand", 0.10)) end)
        row._cur = cur

        row._pip = row:CreateTexture(nil, "OVERLAY")
        row._pip:SetSize(Owner.MENU.PIP, Owner.MENU.PIP)

        -- NAME — class-colored, width-clamped, ellipsizing. The one loud thing in a row.
        row._name = row:CreateFontString(nil, "OVERLAY")
        row._name:SetFontObject(UI.fonts.body)
        row._name:SetJustifyH("LEFT")
        row._name:SetWordWrap(false)

        -- TAG (FULL / SUMMARY) and AGE — metadata, so both drop to the micro-label face
        -- in muted ink. They are annotations on the name, not competing headlines.
        row._badge = row:CreateFontString(nil, "OVERLAY")
        row._badge:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
        row._badge:SetJustifyH("LEFT")
        row._badge:SetWordWrap(false)

        row._fresh = row:CreateFontString(nil, "OVERLAY")
        row._fresh:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
        row._fresh:SetJustifyH("RIGHT")
        row._fresh:SetWordWrap(false)

        -- Favorite STAR (far right): a filled star when favorite, a star OUTLINE when not.
        -- Toggles the favorite and re-populates so the row re-sorts to the top. Non-self
        -- only (self is always first); hidden on the self row.
        --
        -- DRAWN ART, not a font character (header-selector round, owner directive 3). This
        -- pair used to be the text ★ (U+2605) / ☆ (U+2606); neither codepoint exists in the
        -- suite's shipped default face NOR in the WoW built-ins the Core font picker
        -- offers, so the client drew its missing-glyph box and the unlit state read as "a
        -- meaningless hollow box". That is not a size or colour problem — no font setting
        -- can render a glyph the font does not contain — so the control moved onto the same
        -- art pipeline the window's other glyphs already use (dev/gen-bags-glyphs.lua).
        -- The textures are white-on-transparent, so the STATE is still carried by the tint.
        row._star = _G.CreateFrame("Button", nil, row)
        row._star:SetSize(Owner.MENU.CTRL_W, Owner.MENU.CTRL_W)
        row._star:SetPoint("RIGHT", row, "RIGHT", -Owner.MENU.PAD_R, 0)
        row._starTex = row._star:CreateTexture(nil, "OVERLAY")
        row._starTex:SetAllPoints(row._star)
        row._star:SetScript("OnEnter", function(self)
            if self._tex then self._tex:SetVertexColor(UI.Color("warn")) end
        end)
        row._star:SetScript("OnLeave", function(self)
            if self._tex then self._tex:SetVertexColor(UI.Color(self._lit and "warn" or "muted")) end
        end)
        row._star._tex = row._starTex

        -- DELETE ✕ (left of the star), non-self only. Opens a plain confirm before removing the
        -- cached owner (never the live self — guarded downstream). Danger-tinted on hover.
        row._del = _G.CreateFrame("Button", nil, row)
        row._del:SetSize(Owner.MENU.CTRL_W, Owner.MENU.CTRL_W)
        row._del:SetPoint("RIGHT", row._star, "LEFT", -Owner.MENU.CTRL_GAP, 0)
        row._delFS = row._del:CreateFontString(nil, "OVERLAY")
        row._delFS:SetFontObject(UI.fonts.body)
        row._delFS:SetPoint("CENTER", row._del, "CENTER", 0, 0)
        row._delFS:SetText("\195\151")   -- ✕ (U+00D7 multiplication sign)
        row._del:SetScript("OnEnter", function() if row._delFS then row._delFS:SetTextColor(UI.Color("danger")) end end)
        row._del:SetScript("OnLeave", function() if row._delFS then row._delFS:SetTextColor(UI.Color("muted")) end end)

        row:SetScript("OnEnter", function(self) self._hl:Show() end)
        row:SetScript("OnLeave", function(self) self._hl:Hide() end)
        popup._rows[i] = row
        return row
    end

    -- Lay a row's columns out for the computed geometry (ITEM 6).
    local function placeRow(row, L)
        local M = Owner.MENU
        row._pip:ClearAllPoints()
        row._pip:SetPoint("LEFT", row, "LEFT", L.x.pip, 0)
        row._name:ClearAllPoints()
        row._name:SetPoint("LEFT", row, "LEFT", L.x.name, 0)
        row._name:SetWidth(L.nameW)
        row._badge:ClearAllPoints()
        row._badge:SetPoint("LEFT", row, "LEFT", L.x.badge, 0)
        row._badge:SetWidth(L.badgeW)
        row._fresh:ClearAllPoints()
        row._fresh:SetPoint("LEFT", row, "LEFT", L.x.age, 0)
        row._fresh:SetWidth(L.ageW)
        row._star:ClearAllPoints()
        row._star:SetPoint("RIGHT", row, "RIGHT", -M.PAD_R, 0)
        row._del:ClearAllPoints()
        row._del:SetPoint("RIGHT", row._star, "LEFT", -M.CTRL_GAP, 0)
    end

    local function populate()
        local list = Owner.LiveList()
        local curKey = viewedKey()
        local M = Owner.MENU

        -- PASS 1 — fill the text and MEASURE the widest name, so the menu widens to fit
        -- its content instead of guessing a width and letting the columns collide.
        local widest = 0
        for i, d in ipairs(list) do
            local row = acquireRow(i)
            row._name:SetWidth(0)                 -- unconstrained while measuring
            row._name:SetText(d.name or d.key)
            row._name:SetTextColor(classRGB(d.class))
            row._badge:SetText(Owner.SourceBadge(d.source):upper())
            row._badge:SetTextColor(UI.Color(d.source == "full" and "bronze" or "faint"))
            row._fresh:SetText(Owner.AgeLabel(d.ageSeconds, d.isSelf))
            row._fresh:SetTextColor(UI.Color(d.isSelf and "ok" or "muted"))
            local w = (row._name.GetStringWidth and row._name:GetStringWidth()) or 0
            if w > widest then widest = w end
        end

        local L = Owner.MenuLayout(widest + 2)          -- +2 so the clamp isn't hit by a hair
        local rowW = math.max(L.width, width + 40)      -- never narrower than the face button

        -- PASS 2 — place the columns and stack the rows.
        local y = M.ROW_GAP
        local shown = 0
        for i, d in ipairs(list) do
            local row = popup._rows[i]
            placeRow(row, L)
            row:SetWidth(rowW - 4)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", popup._content, "TOPLEFT", 0, -y)
            -- Seal pip: brand = the row you are VIEWING, ok = your live self when it is
            -- not the viewed row, idle = every other cached owner.
            local tone = (d.key == curKey) and "brand" or (d.isSelf and "ok" or "idle")
            row._pip:SetColorTexture(UI.Color(tone))
            row._cur:SetShown(d.key == curKey)
            row:SetScript("OnClick", function()
                popup:Hide()
                if opts.onSelect then opts.onSelect(d.key) end
            end)

            -- Favorite star: the FILLED glyph in gold when favorite, the OUTLINE in muted
            -- ink when not. Hidden on the self row.
            if d.isSelf then
                row._star:Hide(); row._del:Hide()
            else
                row._star:Show()
                row._star._lit = d.isFavorite and true or nil
                row._starTex:SetTexture(artPath() ..
                    (d.isFavorite and "icon-star" or "icon-star-outline"))
                -- `muted`, not `faint`: the unlit state is a real outline now and has to be
                -- SEEN to be clickable — faint is the ink for text a row is de-emphasising,
                -- not for the affordance that turns the row's own sort order on.
                row._starTex:SetVertexColor(UI.Color(d.isFavorite and "warn" or "muted"))
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
            y = y + M.ROW_H + M.ROW_GAP
            shown = i
        end
        for i = shown + 1, #popup._rows do popup._rows[i]:Hide() end

        local panelH, _, range = Owner.MenuHeight(#list)
        popup._content:SetSize(rowW - 4, math.max(1, y))
        popup._scroll._range = range
        popup._scroll:SetVerticalScroll(0)
        popup:SetSize(rowW, panelH + 4)
    end

    -- Open/close the flyout against `anchor` (default: this widget). Exposed as a METHOD
    -- because the header form has no mouse of its own — the window's title hit area calls
    -- sel:Toggle(hitArea) so the menu lines up with the NAME the user clicked, not with the
    -- 16px arrow at the end of it.
    function frame:Toggle(anchor)
        if popup and popup:IsShown() then popup:Hide(); return end
        if not popup then buildPopup() end
        populate()
        popup:ClearAllPoints()
        -- Direction is the CALLER's call (opts.menuGrow), because only the caller knows
        -- where on its window the selector sits — a bottom-anchored face opens upward, a
        -- title-row face (both windows, since the header round) opens downward.
        -- Owner.MenuAnchor is pure so the choice is harness-locked.
        local p, rp, ax, ay = Owner.MenuAnchor(opts.menuGrow)
        popup:SetPoint(p, anchor or self, rp, ax, ay)
        closer:Show()
        popup:Show()
    end
    function frame:MenuShown() return (popup and popup:IsShown()) and true or false end
    function frame:CloseMenu() if popup then popup:Hide() end end

    if btn then btn:SetScript("OnClick", function() frame:Toggle() end) end

    -- Re-sync the face to the current view. The header form has no face of its own (the
    -- window's own gold title IS the label, repainted by that window's Rebuild), so every
    -- part is guarded and this reduces to a no-op there rather than erroring on a nil.
    function frame:Refresh()
        if not (self._name and self._pip) then return end
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

-- Live per-character money descriptors. Carries everything the 1.x row needs: identity
-- for the 12px icon, `source` for the own/other-account partition, and the favorite
-- flag that exempts a character from the 5-row cap.
--
-- SOURCE (W2, Nexus Inventory bridge): the owner universe comes from ns.Nexus.Owners()
-- when the Daseeki-Nexus Inventory store is present and populated — Bags' own owners
-- plus that store's SUMMARY owners, merged newest-wins per character (see nexus.lua's
-- precedence header). That is precisely the "Other Accounts" group this tooltip renders,
-- since Owner.IsOtherAccount partitions on source == "summary". With no Nexus, or with
-- the bridge inactive for any reason, the accessor hands back Store.data.owners itself
-- and this function behaves exactly as it did standalone. Type-guarded, and the
-- Store.ForEachOwner path is kept as the fallback so a missing bridge cannot blank the
-- money tooltip.
function Owner.MoneyChars()
    local out = {}
    local favs = favoritesMap(false)
    local function add(key, o)
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
    end
    if ns.Nexus and ns.Nexus.Owners then
        local view = ns.Nexus.Owners()
        if type(view) == "table" then
            for key, o in pairs(view) do
                if type(o) == "table" then add(key, o) end
            end
            return out
        end
    end
    if Store and Store.ForEachOwner then
        Store.ForEachOwner(add)
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

-- HEADER-SELECTOR ROUND, owner directive 2: the MENU's age column is the bare relative
-- age. Pinned here because the long form still exists three lines up (the bank's titlebar
-- stamp reads it), so "which label does the menu use" is exactly the kind of thing a later
-- round re-crosses by accident.
local function testAgeLabel(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- The owner's own examples, verbatim.
    ck(Owner.AgeLabel(5 * 86400, false)  == "5d",  "5 days -> 5d")
    ck(Owner.AgeLabel(3600, false)       == "1h",  "1 hour -> 1h")
    ck(Owner.AgeLabel(4 * 60, false)     == "4m",  "4 minutes -> 4m")
    ck(Owner.AgeLabel(27 * 86400, false) == "27d", "27 days -> 27d")
    -- The word "Updated" and the word "ago" are gone from every age string.
    for _, secs in ipairs({ 90, 3600, 7200, 86400, 259200, 30 * 86400 }) do
        local s = Owner.AgeLabel(secs, false)
        ck(not s:find("Updated"), "age " .. secs .. "s carries no 'Updated' (" .. s .. ")")
        ck(not s:find("ago"),     "age " .. secs .. "s carries no 'ago' (" .. s .. ")")
    end
    -- Boundaries: each unit turns over at exactly the next unit's first second.
    ck(Owner.AgeLabel(59, false)    == "now", "<1m -> now (never '0m')")
    ck(Owner.AgeLabel(60, false)    == "1m",  "60s is the first minute")
    ck(Owner.AgeLabel(3599, false)  == "59m", "the last minute before an hour")
    ck(Owner.AgeLabel(86399, false) == "23h", "the last hour before a day")
    ck(Owner.AgeLabel(86400, false) == "1d",  "86400s is the first day")
    -- The two NON-age states keep their words (they are not durations).
    ck(Owner.AgeLabel(nil, true)    == "Online",  "self -> Online")
    ck(Owner.AgeLabel(999999, true) == "Online",  "self ignores age")
    ck(Owner.AgeLabel(nil, false)   == "No data", "no age -> No data")
    ck(Owner.AgeLabel(-1, false)    == "No data", "a negative age -> No data")
    -- The long form is UNTOUCHED — the bank stamp still reads a sentence.
    ck(Owner.FreshnessLabel(5 * 86400, false) == "Updated 5d ago",
        "the long form is still the long form (bank titlebar stamp)")
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
    -- freshness rendering of the built descriptors, as the MENU actually draws them
    ck(Owner.AgeLabel(list[1].ageSeconds, list[1].isSelf) == "Online", "self row -> Online")
    ck(Owner.AgeLabel(list[4].ageSeconds, list[4].isSelf) == "8m", "Cid 500s -> 8m")
    -- empty / nil guards
    ck(#Owner.BuildOwnerList(nil, "X", "a", 1) == 0, "nil owners -> empty list")
    -- no selfAccount => nobody is "own account" (all non-self are rank 2)
    local noAcct = Owner.BuildOwnerList(owners, "Zed-R", "", 1000)
    ck(noAcct[1].isSelf and noAcct[2].rank == 3, "blank selfAccount -> everyone non-self is cross (rank 3)")
end

-- RemoveOwner safety (audit 5.5): the live self is NEVER removable; a cached alt is.
-- ITEM 6 (display round): the selector menu's COLUMN geometry. The defect was every
-- column drawing on top of the others; the regression lock is that the columns never
-- overlap at ANY name width, and that the menu widens to fit its content.
local function testMenuLayout(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local M = Owner.MENU

    -- No two columns overlap, at any measured name width (including absurd ones).
    for _, w in ipairs({ 0, 10, M.NAME_MIN, 120, M.NAME_MAX, 400, 4000 }) do
        local L = Owner.MenuLayout(w)
        ck(L.x.pip + M.PIP <= L.x.name, "w=" .. w .. ": pip clears the name column")
        ck(L.x.name + L.nameW <= L.x.badge, "w=" .. w .. ": name clears the tag column")
        ck(L.x.badge + L.badgeW <= L.x.age, "w=" .. w .. ": tag clears the age column")
        ck(L.x.age + L.ageW + M.COL_GAP + 2 * M.CTRL_W + M.CTRL_GAP + M.PAD_R <= L.width,
            "w=" .. w .. ": age clears the ✕/★ controls inside the menu width")
    end

    -- The name column CLAMPS both ways: it never collapses, and one absurd name cannot
    -- push the age column off the menu (it ellipsizes instead).
    ck(Owner.MenuLayout(0).nameW == M.NAME_MIN, "empty name -> the minimum column")
    ck(Owner.MenuLayout(nil).nameW == M.NAME_MIN, "nil name width -> the minimum column")
    ck(Owner.MenuLayout(4000).nameW == M.NAME_MAX, "an absurd name clamps to the maximum")
    ck(Owner.MenuLayout(M.NAME_MIN + 20).nameW == M.NAME_MIN + 20, "in-band widths pass through")

    -- The MENU WIDENS to fit content (the owner's "widen the menu" ask), monotonically.
    ck(Owner.MenuLayout(M.NAME_MAX).width > Owner.MenuLayout(M.NAME_MIN).width,
        "a longer name widens the menu")
    ck(Owner.MenuLayout(4000).width == Owner.MenuLayout(M.NAME_MAX).width,
        "…but only up to the clamp")

    -- ~30 rows must stay scannable: they scroll rather than running off the screen.
    local h30, scroll30, range30 = Owner.MenuHeight(30)
    ck(h30 == Owner.MENU_MAX_H, "a 30-row menu clamps to the max panel height")
    ck(scroll30 == true, "…and scrolls")
    ck(range30 == 30 * (M.ROW_H + M.ROW_GAP) + M.ROW_GAP - Owner.MENU_MAX_H,
        "scroll range is the overshoot")
    local h5, scroll5, range5 = Owner.MenuHeight(5)
    ck(h5 == 5 * (M.ROW_H + M.ROW_GAP) + M.ROW_GAP, "a short menu sizes to its rows")
    ck(scroll5 == false and range5 == 0, "a short menu does not scroll")
    local h0 = Owner.MenuHeight(0)
    ck(h0 == M.ROW_GAP, "an empty menu collapses to its padding")
    ck(Owner.MenuHeight(-3) == M.ROW_GAP, "a negative count is treated as empty")
    -- The clamp must admit a useful number of rows before scrolling kicks in.
    ck(Owner.MENU_MAX_H >= 10 * (M.ROW_H + M.ROW_GAP), "at least 10 rows are visible at once")

    -- HEADER-SELECTOR ROUND: the age column compressed (Owner.AgeLabel), so the whole menu
    -- got NARROWER. Pinned as a number because "the menu can get narrower" was an explicit
    -- owner ask and nothing else in the layout would fail if the column silently grew back.
    ck(M.AGE_W == 44, "the age column is the compressed width (44), got " .. tostring(M.AGE_W))
    ck(Owner.MenuLayout(M.NAME_MAX).width < 400,
        "a full-width menu stays under 400px, got " .. Owner.MenuLayout(M.NAME_MAX).width)
    -- The star is drawn art now and needs more room than a font character did.
    ck(M.CTRL_W == 18, "the ✕/★ control columns are 18px, got " .. tostring(M.CTRL_W))
    -- The header form's footprint is declared, so the two windows anchor the same square.
    ck(Owner.ARROW_W == 16, "the header dropdown arrow is a 16px square")

    -- BOTH growth directions stay live. The footer round needed "up" (a bottom-left face
    -- whose menu would otherwise open below the screen edge); the header round put the
    -- face back in the title row and needs "down" again. Locked because a silent revert
    -- either way reads in-game as "the owner menu is gone".
    local p, rp, ax, ay = Owner.MenuAnchor("up")
    ck(p == "BOTTOMLEFT" and rp == "TOPLEFT", "grow=up anchors the menu's bottom to the button's top")
    ck(ax == 0 and ay == 2, "…with a 2px lift off the button")
    local dp, drp, dx, dy = Owner.MenuAnchor("down")
    ck(dp == "TOPLEFT" and drp == "BOTTOMLEFT" and dx == 0 and dy == -2,
        "grow=down is the historic downward drop")
    ck(select(1, Owner.MenuAnchor(nil)) == "TOPLEFT", "an unset direction stays the old downward drop")
    ck(select(1, Owner.MenuAnchor("sideways")) == "TOPLEFT", "an unknown direction falls back to down")
end

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

-- W2 (Nexus Inventory bridge): the money tooltip's owner universe.
-- Nexus PRESENT -> its owners appear under "Other Accounts" and in the Total.
-- Nexus ABSENT  -> the tooltip is byte-for-byte the standalone one.
local function testNexusMoneySourcing(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local G = 10000
    local savedNexus, savedData, savedDB = _G.DaseekiNexusData, Store.data, Store.db

    local function invalidate() if ns.Nexus then ns.Nexus.Invalidate() end end
    local function kinds(rows)
        local t = {} for i, r in ipairs(rows) do t[i] = r.kind end return table.concat(t, ",")
    end
    local function rowFor(rows, name)
        for _, r in ipairs(rows) do if r.kind == "char" and r.name == name then return r end end
    end
    local function totalOf(rows)
        for _, r in ipairs(rows) do if r.kind == "total" then return r.copper end end
    end

    Store.db   = {}
    Store.data = { owners = {
        ["Me-R"]  = { nameRealm = "Me-R", name = "Me", class = "MAGE", account = "",
                      source = "full", faction = "Horde", money = 100 * G, ts = 1700000000,
                      containers = {}, equip = {}, itemCounts = {} },
        ["Old-R"] = { nameRealm = "Old-R", name = "Old", class = "ROGUE", account = "",
                      source = "summary", faction = "Horde", money = 5 * G, ts = 1700001000,
                      containers = {}, equip = {}, itemCounts = {} },
    } }

    -- 1) STANDALONE: no Nexus at all.
    _G.DaseekiNexusData = nil
    invalidate()
    local rows = Owner.BuildMoneyReport(Owner.MoneyChars())
    ck(rowFor(rows, "Me") ~= nil and rowFor(rows, "Old") ~= nil, "standalone: both stored owners render")
    ck(rowFor(rows, "Peer") == nil, "standalone: nothing invented")
    ck(totalOf(rows) == 105 * G, "standalone: total is the store's own money")
    ck(kinds(rows):find("section"), "standalone: the summary owner still makes an Other Accounts section")

    -- 2) BRIDGED: Nexus adds a peer AND carries a fresher copy of the stale summary.
    _G.DaseekiNexusData = { inventory = { schema = 1, owners = {
        ["Peer-R"] = { rev = 2, updatedAt = 1700009000,
                       data = { key = "Peer-R", class = "WARLOCK", faction = "Horde",
                                money = 50 * G, itemCounts = {}, ts = 1700008000 } },
        ["Old-R"]  = { rev = 9, updatedAt = 1700009000,
                       data = { key = "Old-R", class = "ROGUE", faction = "Horde",
                                money = 60 * G, itemCounts = {}, ts = 1700008000 } },
        ["Me-R"]   = { rev = 9, updatedAt = 1700009000,
                       data = { key = "Me-R", class = "MAGE", faction = "Horde",
                                money = 1, itemCounts = {}, ts = 1700009999 } },
    } } }
    invalidate()
    local bridged = Owner.BuildMoneyReport(Owner.MoneyChars())
    ck(rowFor(bridged, "Peer") ~= nil, "bridged: the Nexus-only character appears")
    ck(rowFor(bridged, "Peer").source == "summary", "bridged: it partitions into Other Accounts")
    ck(rowFor(bridged, "Old").copper == 60 * G, "bridged: the fresher Nexus copy replaces the stale summary")
    ck(rowFor(bridged, "Me").copper == 100 * G,
        "bridged: the LOCAL full character keeps its own money even against a newer Nexus entry")
    ck(totalOf(bridged) == (100 + 60 + 50) * G, "bridged: each character counted exactly once")

    -- 3) The store was never written by any of it.
    ck(Store.data.owners["Peer-R"] == nil, "the Nexus owner was not persisted into the Bags store")
    ck(Store.data.owners["Old-R"].money == 5 * G, "the Bags record itself is untouched on disk")

    -- 4) Removing Nexus restores the standalone tooltip exactly.
    _G.DaseekiNexusData = nil
    invalidate()
    ck(totalOf(Owner.BuildMoneyReport(Owner.MoneyChars())) == 105 * G,
        "removing Nexus returns the standalone total immediately")

    _G.DaseekiNexusData, Store.data, Store.db = savedNexus, savedData, savedDB
    invalidate()
end

function Owner.RunSelfTests(verbose)
    local suites = {
        { name = "freshness + badge",   fn = testFreshnessAndBadge },
        { name = "menu age column",     fn = testAgeLabel },
        { name = "has bank data",       fn = testHasBankData },
        { name = "owner-list ordering", fn = testOwnerListOrdering },
        { name = "menu column layout",  fn = testMenuLayout },
        { name = "remove-owner safety", fn = testRemoveOwnerSafety },
        { name = "favorites sort",      fn = testFavoritesSort },
        { name = "money: partition",    fn = testMoneyPartition },
        { name = "money: 1.x anatomy",  fn = testMoneyAnatomy },
        { name = "money: cap + favorites", fn = testMoneyCapAndFavorites },
        { name = "money: totals math",  fn = testMoneyTotals },
        { name = "money: row format",   fn = testMoneyFormatting },
        { name = "money: nexus sourcing", fn = testNexusMoneySourcing },
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
