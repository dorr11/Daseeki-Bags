-- Daseeki Bags 2.0 — locks.lua
-- SORT LOCKS: per-character, per-slot "never move this" marks, plus the LOCK CONFIG
-- MODE the owner enters by RIGHT-CLICKING the sort glyph.
--
-- Owner directive (2026-08-03): "right clicking the 'sort' button should allow me to
-- lock bag slots to prevent them from sorting."
--
-- ── WHAT 1.x DID (read as fact from the shipping 1.x tree) ────────────────────────
--   * ENTRY. core/classes/sortButton.lua:OnClick right-clicks into a Blizzard context
--     menu whose LAST entry is L.LockItems ("Lock Item Slots") -> SortButton:OnLocking.
--     OnLocking sets `Addon.lockMode` to a Sushi HelpTip carrying L.ConfigurationMode
--     ("You are now in the client-side sorting configuration mode.|n|nClick item slots
--     to toggle if they should be locked while sorting."), plays two sounds, and fires
--     the LOCKING_TOGGLED signal. A second call releases the tip and clears the flag.
--   * TOGGLING. core/classes/item.lua:114-119 — Item:PostClick, when Addon.lockMode is
--     set, flips `GetBagInfo(bag).locked[slot]` between true and nil. Normal item
--     interaction is suspended because Item:OnEnter (:125) attaches the shared insecure
--     `Item.Dummy` button OVER the secure slot whenever lockMode is on, so the click
--     lands on the dummy (which calls PostClick) and never on the container button.
--   * MARK. item.lua:60-63 creates `IgnoredOverlay`, a full-cell OVERLAY texture
--     (fileID 255353 — the red prohibition sign), shown by UpdateIgnored (:237-240)
--     only while lockMode is on.
--   * STORAGE. GetBagInfo(bag) is `Owners:GetOwner()[bag]` — the character's entry in
--     the account-wide SavedVariable DaseekiBagsAccount. So the real 1.x shape is
--
--         DaseekiBagsAccount[realm][charName][bagId].locked = { [slot] = true, ... }
--
--     i.e. PER-CHARACTER, PER-CONTAINER, PER-SLOT, stored inside the same per-bag
--     record that holds items/size/link. (Cacher:PopulateBag rewrites items/link/size
--     on every bag update but never touches `locked`, which is why it survives.)
--     The OWNER's live file carries exactly this: Whitemane/Poonyx bag 4 slots 15-18,
--     Whitemane/Shalk bag 4 slots 8-16.
--   * SORT. core/api/sorting.lua:109-114 — Sort:GetSpaces skips a locked slot entirely
--     when building the space list, so a locked slot is neither a source (its item is
--     never in `order`) nor a destination (it is never in `slots`).
--
-- ── WHAT 2.0 DOES ────────────────────────────────────────────────────────────────
-- Same semantics, 2.0's shapes:
--   * ENTRY is the right-click ITSELF (no context menu — 2.0 has no menu library, and
--     the owner asked for the right-click to be the gesture). Frame.SortClickAction is
--     the pure seam, mirroring Frame.SearchClickAction's dual-click precedent.
--   * STORAGE is settings-side, not cache-side. 1.x had one SavedVariable, so its locks
--     necessarily rode in the bag cache; 2.0 separates DaseekiBags2DB (settings, small,
--     durable) from DaseekiBags2Data (the churny inventory cache, independently
--     schema-migratable). A lock is CONFIGURATION — the owner's deliberate choice — so
--     it lives in the settings DB, keyed per character exactly as 1.x keyed it:
--
--         DaseekiBags2DB.sortLocks["Name-Realm"][cid][slot] = true
--
--     NO NEW GLOBAL (toc identity gate satisfied: this nests inside an already-declared
--     SavedVariable). Additive: applyDefaults never sees the key, absent = no locks.
--     Empty sub-tables are pruned on unlock so an un-touched character costs nothing.
--   * The MARK is art/icon-lock-slot.tga (authored by dev/gen-bags-glyphs.lua in the
--     suite's stroke family) tinted `danger` — the same read as 1.x's red prohibition
--     sign, in 2.0's dress.
--   * SUSPENSION uses 1.x's proven trick: an insecure catcher frame parented over the
--     secure container button. Ours is per-button and created lazily (ui_items.lua),
--     which removes 1.x's hover race — the catcher is up the moment the mode opens, not
--     the moment the cursor first enters a cell.
--
-- This file is PURE (no WoW API at all). Every function takes its table explicitly or
-- reads Store.db; the mode is a plain boolean with a listener list. The harness drives
-- all of it headless.

local ADDON, ns = ...

local Locks = {}
ns.Locks = Locks

----------------------------------------------------------------------
-- Persistence: DaseekiBags2DB.sortLocks[nameRealm][cid][slot] = true
--
-- All the table plumbing is expressed as PURE functions over an explicit root table so
-- the harness can exercise the exact shape the addon writes without a settings DB.
----------------------------------------------------------------------

Locks.DB_KEY = "sortLocks"

-- Migration marker. DELIBERATELY ITS OWN, not migrate_settings' MARKER: the owner's
-- live DaseekiBags2DB already carries migratedSettingsFrom1x = true from an earlier
-- beta login, so folding the lock import under that marker would mean it could never
-- run for the one person it exists for. Same discipline as every other pass in this
-- addon (non-empty gated, additive, idempotent) — just its own flag.
Locks.MIGRATION_MARKER = "migratedSortLocksFrom1x"

-- Normalise a container id / slot index to the numeric keys the store uses. Returns nil
-- for anything that is not a usable key, so a caller can never write a "3"/3 twin pair.
local function num(v)
    local n = tonumber(v)
    if n == nil then return nil end
    n = math.floor(n)
    return n
end
Locks._num = num

-- PURE: is (cid, slot) locked in this root? `root` is the sortLocks table for ONE
-- character, i.e. { [cid] = { [slot] = true } }.
function Locks.RootIsLocked(root, cid, slot)
    if type(root) ~= "table" then return false end
    local c, s = num(cid), num(slot)
    if c == nil or s == nil then return false end
    local bag = root[c]
    return (type(bag) == "table" and bag[s]) and true or false
end

-- PURE: set/clear (cid, slot) in this root. Returns the new boolean state.
-- Clearing prunes the container sub-table when it empties, so an untouched character
-- never leaves `[4] = {}` litter in SavedVariables.
function Locks.RootSet(root, cid, slot, on)
    if type(root) ~= "table" then return false end
    local c, s = num(cid), num(slot)
    if c == nil or s == nil then return false end
    if on then
        local bag = root[c]
        if type(bag) ~= "table" then bag = {}; root[c] = bag end
        bag[s] = true
        return true
    end
    local bag = root[c]
    if type(bag) == "table" then
        bag[s] = nil
        if next(bag) == nil then root[c] = nil end
    end
    return false
end

-- PURE: flip (cid, slot). Returns the new boolean state.
function Locks.RootToggle(root, cid, slot)
    return Locks.RootSet(root, cid, slot, not Locks.RootIsLocked(root, cid, slot))
end

-- PURE: how many slots are locked in this root (total, and per container when asked).
function Locks.RootCount(root, cid)
    if type(root) ~= "table" then return 0 end
    local n = 0
    if cid ~= nil then
        local bag = root[num(cid)]
        if type(bag) == "table" then for _ in pairs(bag) do n = n + 1 end end
        return n
    end
    for _, bag in pairs(root) do
        if type(bag) == "table" then for _ in pairs(bag) do n = n + 1 end end
    end
    return n
end

-- PURE: drop every lock in this root (in place; the table identity is preserved so a
-- live SavedVariables reference stays valid).
function Locks.RootClear(root)
    if type(root) ~= "table" then return 0 end
    local n = Locks.RootCount(root)
    for k in pairs(root) do root[k] = nil end
    return n
end

----------------------------------------------------------------------
-- Live binding: which character's locks are we reading?
--
-- Sorting only ever operates on the LOGGED-IN character's containers, so the live
-- surface is bound to one key. Set once at login (features.lua / core.lua identity
-- moment); resolved lazily from the same UnitName/GetRealmName pair the rest of the
-- addon canonicalises with (realm spaces stripped — 1.x's SV key convention).
----------------------------------------------------------------------

function Locks.SetCharacter(nameRealm)
    Locks._self = nameRealm
end

function Locks.Character()
    if Locks._self then return Locks._self end
    local name  = (_G.UnitName and _G.UnitName("player")) or nil
    if not name then return nil end
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))
    local Store = ns.Store
    local key = Store and Store.MakeNameRealm(name, realm) or (name .. "-" .. realm)
    Locks._self = key
    return key
end

-- The per-character root inside the settings DB. `create` allocates the chain; without
-- it a character with no locks reads as nil and every accessor answers "not locked"
-- without ever writing to SavedVariables.
function Locks.Root(create)
    local Store = ns.Store
    local db = Store and Store.db
    if type(db) ~= "table" then return nil end
    local key = Locks.Character()
    if not key then return nil end
    local all = db[Locks.DB_KEY]
    if type(all) ~= "table" then
        if not create then return nil end
        all = {}
        db[Locks.DB_KEY] = all
    end
    local root = all[key]
    if type(root) ~= "table" then
        if not create then return nil end
        root = {}
        all[key] = root
    end
    return root
end

function Locks.IsLocked(cid, slot)
    return Locks.RootIsLocked(Locks.Root(false), cid, slot)
end

function Locks.SetLocked(cid, slot, on)
    -- Never allocate the chain just to clear a lock that was never set.
    local root = Locks.Root(on and true or false)
    if not root then return false end
    local state = Locks.RootSet(root, cid, slot, on)
    Locks.Changed()
    return state
end

function Locks.ToggleSlot(cid, slot)
    local root = Locks.Root(true)
    if not root then return false end
    local state = Locks.RootToggle(root, cid, slot)
    Locks.Changed()
    return state
end

function Locks.Count(cid)
    return Locks.RootCount(Locks.Root(false), cid)
end

function Locks.ClearAll()
    local n = Locks.RootClear(Locks.Root(false))
    if n > 0 then Locks.Changed() end
    return n
end

----------------------------------------------------------------------
-- LOCK CONFIG MODE — the state machine
--
-- A pure boolean plus a listener list. UI modules subscribe (ui_frame paints the
-- notice banner, ui_items raises the catchers and the marks); nothing in here touches
-- a frame, so the whole state machine is harness-drivable.
--
-- EXIT ROUTES (all three the owner asked for, plus the safety one):
--   * right-click the sort glyph again        -> Locks.Toggle()
--   * Escape                                   -> Locks.Exit("escape")   (ui_frame)
--   * closing the window                       -> Locks.Exit("closed")   (ui_frame OnHide)
--   * a sort actually starting                 -> Locks.Exit("sorting")  (belt + braces)
-- Every route runs the SAME Exit, so "restore fully on exit" has exactly one
-- implementation and cannot drift between routes.
----------------------------------------------------------------------

Locks._mode = false
Locks._listeners = Locks._listeners or {}

-- Register fn(active, reason). Called on every transition, never on a no-op.
function Locks.OnChange(fn)
    if type(fn) ~= "function" then return end
    Locks._listeners[#Locks._listeners + 1] = fn
end

-- Fired when the lock SET changes while the mode is open (so the marks repaint).
-- Separate from the mode transition: listeners get (active, "locks").
function Locks.Changed()
    if not Locks._mode then return end
    Locks._fire("locks")
end

function Locks._fire(reason)
    local list = Locks._listeners
    for i = 1, #list do
        local ok, err = pcall(list[i], Locks._mode, reason)
        if not ok and ns.SafeCall then
            -- route through the addon's error path without aborting the other listeners
            if _G.geterrorhandler then _G.geterrorhandler()(err) end
        end
    end
end

function Locks.IsActive()
    return Locks._mode and true or false
end

function Locks.Enter(reason)
    if Locks._mode then return false end
    Locks._mode = true
    Locks._fire(reason or "enter")
    return true
end

function Locks.Exit(reason)
    if not Locks._mode then return false end
    Locks._mode = false
    Locks._fire(reason or "exit")
    return true
end

function Locks.Toggle(reason)
    if Locks._mode then return Locks.Exit(reason or "toggle"), false end
    return Locks.Enter(reason or "toggle"), true
end

-- The instructional copy. 1.x's wording, kept verbatim in meaning because it is
-- exactly right; split into a title + body so the 2.0 banner can typeset it in the
-- suite's own voice instead of a yellow Blizzard HelpTip.
Locks.NOTICE_TITLE = "Sort lock configuration"
Locks.NOTICE_BODY  =
    "Click item slots to lock them — locked slots are never moved by a sort. " ..
    "Right-click the sort glyph again (or press Escape) when you are done."

----------------------------------------------------------------------
-- MIGRATION: 1.x locks -> 2.0 sortLocks.  READ-ONLY on the 1.x global.
--
-- Source: DaseekiBagsAccount[realm][charName][cid].locked = { [slot] = true }.
-- Target: db.sortLocks["Name-Realm"][cid][slot] = true.
--
-- House rules, all three:
--   MARKER-GUARDED  — db[Locks.MIGRATION_MARKER]; `force` overrides for tests/self-heal.
--   NON-EMPTY GATED — the marker is written ONLY when at least one real lock was
--                     imported. A 1.x file with no locks at all (or with a `locked`
--                     table whose every entry is nil, which the owner's Zaan actually
--                     has) leaves the marker UNSET, so a machine whose WTF copy arrives
--                     later still imports.
--   ADDITIVE        — a lock already present in 2.0 is counted and left alone; the pass
--                     only ever SETS locks, never clears one. Re-running is therefore a
--                     no-op on content as well as guarded by the marker.
--
-- Realm keys are used verbatim: 1.x already stores them space-stripped, which is the
-- same canonicalisation Store.MakeNameRealm consumers use.
----------------------------------------------------------------------

function Locks.MigrateFrom1x(db, oldAccount, opts)
    opts = opts or {}
    local rep = { skipped = false, ran = false, markerSet = false,
                  imported = 0, alreadySet = 0, characters = 0 }
    if type(db) ~= "table" then
        rep.skipped, rep.reason = true, "no settings db"
        return rep
    end
    if db[Locks.MIGRATION_MARKER] and not opts.force then
        rep.skipped, rep.reason = true, "already migrated"
        return rep
    end
    if type(oldAccount) ~= "table" or next(oldAccount) == nil then
        rep.reason = "no 1.x account data present"
        return rep
    end

    rep.ran = true
    local Store = ns.Store
    local makeKey = (Store and Store.MakeNameRealm)
        or function(n, r) if r and r ~= "" then return n .. "-" .. r end return n end

    local all = db[Locks.DB_KEY]
    if type(all) ~= "table" then all = {}; db[Locks.DB_KEY] = all end

    for realm, chars in pairs(oldAccount) do
        if type(chars) == "table" and type(realm) == "string" then
            for name, oldChar in pairs(chars) do
                if type(oldChar) == "table" and type(name) == "string" then
                    local imported, already = 0, 0
                    local key = makeKey(name, realm)
                    for cid, container in pairs(oldChar) do
                        -- containers are the NUMERIC keys of the char table; every
                        -- string key (money/class/mesh/...) is skipped by this test.
                        if num(cid) ~= nil and type(container) == "table"
                           and type(container.locked) == "table" then
                            for slot, on in pairs(container.locked) do
                                if on and num(slot) ~= nil then
                                    local root = all[key]
                                    if type(root) ~= "table" then root = {}; all[key] = root end
                                    if Locks.RootIsLocked(root, cid, slot) then
                                        already = already + 1
                                    else
                                        Locks.RootSet(root, cid, slot, true)
                                        imported = imported + 1
                                    end
                                end
                            end
                        end
                    end
                    if imported > 0 or already > 0 then
                        rep.characters = rep.characters + 1
                        rep.imported   = rep.imported + imported
                        rep.alreadySet = rep.alreadySet + already
                    end
                end
            end
        end
    end

    -- Non-empty gate. `alreadySet > 0` also counts as a real read: it means the source
    -- WAS present and its locks are already carried (an idempotent re-run under force),
    -- so the marker is legitimately earned.
    if rep.imported == 0 and rep.alreadySet == 0 then
        -- Nothing was allocated for any character, but a defensive prune keeps an empty
        -- sortLocks table from being written for a fresh install.
        if next(all) == nil then db[Locks.DB_KEY] = nil end
        rep.reason = "1.x data present but it holds no locked slots"
        return rep
    end

    db[Locks.MIGRATION_MARKER] = true
    rep.markerSet = true
    return rep
end

-- Live wrapper, called from MigrateSettings.Migrate() at the one migration moment.
function Locks.Migrate()
    local Store = ns.Store
    local db = Store and Store.db
    local rep = Locks.MigrateFrom1x(db, _G.DaseekiBagsAccount)
    if rep.imported > 0 and ns.Print then
        ns:Print(("carried over %d locked sort slot(s) from your 1.x bags (%d character(s))."):
            format(rep.imported, rep.characters))
    end
    return rep
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "locks")
----------------------------------------------------------------------

local function testRootShape(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local root = {}
    ck(Locks.RootIsLocked(root, 4, 15) == false, "fresh root: nothing locked")
    ck(Locks.RootSet(root, 4, 15, true) == true, "set returns the new state")
    ck(Locks.RootIsLocked(root, 4, 15) == true, "set sticks")
    ck(Locks.RootIsLocked(root, 4, 16) == false, "sibling slot unaffected")
    ck(Locks.RootIsLocked(root, 3, 15) == false, "sibling container unaffected")

    -- string keys must resolve to the same numeric cell (no "4"/4 twins)
    ck(Locks.RootIsLocked(root, "4", "15") == true, "string keys resolve to the numeric cell")
    ck(Locks.RootSet(root, "4", "16", true) == true, "string keys write the numeric cell")
    ck(Locks.RootIsLocked(root, 4, 16) == true, "  ...and read back numerically")
    ck(root[4] ~= nil and root["4"] == nil, "no string-keyed twin container")

    ck(Locks.RootCount(root) == 2, "count = 2")
    ck(Locks.RootCount(root, 4) == 2, "per-container count = 2")
    ck(Locks.RootCount(root, 3) == 0, "empty container counts 0")

    -- toggle round-trip + pruning
    ck(Locks.RootToggle(root, 4, 15) == false, "toggle clears")
    ck(Locks.RootToggle(root, 4, 15) == true, "toggle re-sets")
    Locks.RootSet(root, 4, 15, false)
    Locks.RootSet(root, 4, 16, false)
    ck(root[4] == nil, "emptied container is pruned (no SV litter)")
    ck(Locks.RootCount(root) == 0, "count back to 0")

    -- negative container ids (keyring -2, bank -1) are ordinary keys
    ck(Locks.RootSet(root, -2, 1, true) == true, "keyring container accepted")
    ck(Locks.RootIsLocked(root, -2, 1) == true, "keyring lock reads back")
    ck(Locks.RootSet(root, -1, 8, true) == true, "bank container accepted")
    ck(Locks.RootCount(root) == 2, "bank + keyring counted")

    -- garbage in, no crash, no write
    ck(Locks.RootIsLocked(root, nil, 1) == false, "nil cid reads false")
    ck(Locks.RootSet(root, "x", 1, true) == false, "non-numeric cid refuses to write")
    ck(Locks.RootSet(root, 1, "y", true) == false, "non-numeric slot refuses to write")
    ck(Locks.RootIsLocked(nil, 1, 1) == false, "nil root reads false")

    ck(Locks.RootClear(root) == 2, "clear reports what it dropped")
    ck(Locks.RootCount(root) == 0, "clear emptied the root")
end

local function testModeMachine(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- isolate the listener list for the duration of this test
    local saved = Locks._listeners
    Locks._listeners = {}
    local savedMode = Locks._mode
    Locks._mode = false

    local seen = {}
    Locks.OnChange(function(active, reason) seen[#seen + 1] = { active, reason } end)

    ck(Locks.IsActive() == false, "mode starts closed")
    ck(Locks.Exit("noop") == false, "exiting a closed mode is a no-op")
    ck(#seen == 0, "  ...and fires no listener")

    ck(Locks.Enter("test") == true, "enter opens")
    ck(Locks.IsActive() == true, "mode is active")
    ck(#seen == 1 and seen[1][1] == true and seen[1][2] == "test", "enter fired once with its reason")

    ck(Locks.Enter("again") == false, "re-entering an open mode is a no-op")
    ck(#seen == 1, "  ...and fires no listener")

    ck(Locks.Exit("escape") == true, "escape exits")
    ck(Locks.IsActive() == false, "mode is closed")
    ck(#seen == 2 and seen[2][1] == false and seen[2][2] == "escape", "exit fired with its reason")

    -- Toggle is the right-click route: closed -> open -> closed.
    local _, opened = Locks.Toggle("rightclick")
    ck(opened == true and Locks.IsActive() == true, "toggle opens from closed")
    local _, opened2 = Locks.Toggle("rightclick")
    ck(opened2 == false and Locks.IsActive() == false, "toggle closes from open")
    ck(#seen == 4, "two more transitions fired")

    -- Locks.Changed only speaks while the mode is open (it exists to repaint marks).
    local before = #seen
    Locks.Changed()
    ck(#seen == before, "Changed is silent while the mode is closed")
    Locks.Enter("test")
    Locks.Changed()
    ck(#seen == before + 2 and seen[#seen][2] == "locks", "Changed fires 'locks' while open")
    Locks.Exit("cleanup")

    Locks._listeners = saved
    Locks._mode = savedMode
end

-- 1.x-shaped source, faithful to the OWNER's real DaseekiBagsAccount (verified against
-- his WTF file): container ids are numeric keys of the char table, `locked` sits beside
-- items/size/link, and Zaan carries a `locked` table whose entries are all nil.
local function sampleAccount()
    return {
        Whitemane = {
            Poonyx = {
                class = "WARRIOR", money = 12345,
                [0] = { size = 16, items = { "159;2" } },
                [4] = { size = 18, link = "14156", items = {},
                        locked = { [15] = true, [16] = true, [17] = true, [18] = true } },
            },
            Shalk = {
                class = "DRUID", money = 999,
                [4] = { size = 16, link = "14155", items = { "5177" },
                        locked = { [8]=true, [9]=true, [10]=true, [11]=true, [12]=true,
                                   [13]=true, [14]=true, [15]=true, [16]=true } },
            },
            Zaan = {
                class = "MAGE",
                [2] = { size = 16, link = "14155", items = {}, locked = {} },
            },
        },
    }
end

local function testMigration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- 1) EMPTY SOURCE: nothing imported, marker stays UNSET, no key written.
    local db = {}
    local r0 = Locks.MigrateFrom1x(db, nil)
    ck(r0.ran == false and r0.imported == 0, "absent source does not run")
    ck(db[Locks.MIGRATION_MARKER] == nil, "absent source leaves the marker unset")
    ck(db[Locks.DB_KEY] == nil, "absent source writes no sortLocks key")

    -- 1b) SOURCE PRESENT BUT NO LOCKS (the owner's Zaan-only shape): same verdict.
    local dbz = {}
    local rz = Locks.MigrateFrom1x(dbz, { Whitemane = { Zaan = sampleAccount().Whitemane.Zaan } })
    ck(rz.ran == true, "a present source runs")
    ck(rz.imported == 0, "an all-nil `locked` table imports nothing")
    ck(dbz[Locks.MIGRATION_MARKER] == nil, "no-locks source leaves the marker unset")
    ck(dbz[Locks.DB_KEY] == nil, "no-locks source writes no sortLocks key")

    -- 2) NON-EMPTY SOURCE: the owner's real locks land, per character, per container.
    local db2 = {}
    local r = Locks.MigrateFrom1x(db2, sampleAccount())
    ck(r.ran == true and r.skipped == false, "real source ran")
    ck(r.imported == 13, "13 locks imported (Poonyx 4 + Shalk 9)")
    ck(r.characters == 2, "two characters carried locks (Zaan contributed none)")
    ck(r.markerSet == true and db2[Locks.MIGRATION_MARKER] == true, "marker set on a real read")

    local all = db2[Locks.DB_KEY]
    ck(type(all) == "table", "sortLocks written")
    ck(Locks.RootIsLocked(all["Poonyx-Whitemane"], 4, 15), "Poonyx bag 4 slot 15 locked")
    ck(Locks.RootIsLocked(all["Poonyx-Whitemane"], 4, 18), "Poonyx bag 4 slot 18 locked")
    ck(not Locks.RootIsLocked(all["Poonyx-Whitemane"], 4, 14), "Poonyx slot 14 NOT locked")
    ck(not Locks.RootIsLocked(all["Poonyx-Whitemane"], 0, 1), "Poonyx backpack untouched")
    ck(Locks.RootCount(all["Shalk-Whitemane"]) == 9, "Shalk carries 9 locks")
    ck(Locks.RootIsLocked(all["Shalk-Whitemane"], 4, 8), "Shalk bag 4 slot 8 locked")
    ck(all["Zaan-Whitemane"] == nil, "Zaan gets no root at all")

    -- 3) IDEMPOTENT: a second run is marker-skipped and changes nothing.
    local r2 = Locks.MigrateFrom1x(db2, sampleAccount())
    ck(r2.skipped == true and r2.imported == 0, "second run is skipped by the marker")
    ck(Locks.RootCount(all["Poonyx-Whitemane"]) == 4, "Poonyx still has exactly 4")

    -- 3b) FORCED re-run is idempotent on CONTENT too (additive, never double-counts).
    local r3 = Locks.MigrateFrom1x(db2, sampleAccount(), { force = true })
    ck(r3.imported == 0 and r3.alreadySet == 13, "forced re-run imports 0, recognises 13")
    ck(Locks.RootCount(all["Poonyx-Whitemane"]) == 4, "still 4 after the forced re-run")
    ck(Locks.RootCount(all["Shalk-Whitemane"]) == 9, "still 9 after the forced re-run")

    -- 4) ADDITIVE against a 2.0 lock the owner set himself: it survives, and the 1.x
    --    locks are added alongside it. Nothing is ever cleared by this pass.
    local db4 = { [Locks.DB_KEY] = { ["Poonyx-Whitemane"] = { [1] = { [3] = true } } } }
    local r4 = Locks.MigrateFrom1x(db4, sampleAccount())
    ck(r4.imported == 13, "13 imported alongside the pre-existing lock")
    ck(Locks.RootIsLocked(db4[Locks.DB_KEY]["Poonyx-Whitemane"], 1, 3), "pre-existing 2.0 lock survives")
    ck(Locks.RootCount(db4[Locks.DB_KEY]["Poonyx-Whitemane"]) == 5, "Poonyx now 4 + 1")

    -- 5) GARBAGE SOURCE: string-keyed char fields are never mistaken for containers.
    local db5 = {}
    local r5 = Locks.MigrateFrom1x(db5, {
        Whitemane = { Junk = { money = 5, mesh = { itemCounts = { [1] = 2 } },
                               equip = { [16] = "123" } } },
    })
    ck(r5.imported == 0 and db5[Locks.MIGRATION_MARKER] == nil,
       "string-keyed char fields are not containers")
end

-- The whole point of the feature: what the SORT ENGINE does with a locked slot.
-- Proved here against the planner directly (sort.lua carries its own richer cases;
-- this one guards the LOCKS -> Plan handshake specifically).
local function testPlannerHandshake(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local Sort = ns.Sort
    if not Sort or not Sort.Plan then
        fails[#fails + 1] = "ns.Sort.Plan is missing (load order changed?)"
        return
    end
    ck(type(Sort.CellIsFixed) == "function", "sort exposes the fixed-cell predicate")
    ck(Sort.CellIsFixed({ locked = true }) == true, "an in-flight lock fixes a cell")
    ck(Sort.CellIsFixed({ userLocked = true }) == true, "a USER lock fixes a cell")
    ck(Sort.CellIsFixed({}) == false, "a plain cell is free")
end

ns:RegisterSelfTest("locks", function(verbose)
    local fails = {}
    testRootShape(fails)
    testModeMachine(fails)
    testMigration(fails)
    testPlannerHandshake(fails)
    for _, f in ipairs(fails) do ns:Print("  FAIL locks :: " .. f) end
    if #fails == 0 and verbose then
        ns:Print("  PASS locks/root shape")
        ns:Print("  PASS locks/mode state machine")
        ns:Print("  PASS locks/1.x migration")
        ns:Print("  PASS locks/planner handshake")
    end
    return #fails == 0
end)
