-- Daseeki Bags 2.0 — capture.lua
-- Live inventory scan for THIS character on the WoW Classic Era 1.15 event
-- surface, written into the store's owner record. Every API touched here is
-- catalog-verified against wow-api-catalog/1.15.9.68808:
--
--   C_Container.GetContainerNumSlots(cid)                 -> numSlots
--   C_Container.GetContainerItemInfo(cid, slot)           -> ContainerItemInfo
--         (struct: .itemID .stackCount .quality .hyperlink .isBound ...)
--   C_Container.GetContainerItemLink(cid, slot)           -> itemLink (fallback)
--   C_Container.ContainerIDToInventoryID(cid)             -> inventoryID (bag's slot)
--   GetInventoryItemLink("player", invID)                 -> the bag item link
--   GetMoney()                                            -> copper
--
-- Events (all present in the catalog, SCREAMING_SNAKE forms):
--   BAG_UPDATE, BAG_UPDATE_DELAYED, PLAYERBANKSLOTS_CHANGED,
--   PLAYERBANKBAGSLOTS_CHANGED, BANKFRAME_OPENED, BANKFRAME_CLOSED, PLAYER_MONEY
-- The keyring has no dedicated event on Era: it updates through BAG_UPDATE with
-- bagID == KEYRING_CONTAINER (-2).
--
-- 2.0.5 additions, all catalog-verified against the same 1.15.9.68808 dump:
--   Event.Container.ItemLockChanged      -> ITEM_LOCK_CHANGED (bagOrSlotIndex, opt slotIndex)
--   Event.PaperDollInfo.PlayerEquipmentChanged
--                                        -> PLAYER_EQUIPMENT_CHANGED (equipmentSlot, hasCurrent)
--   Event.Unit.UnitInventoryChanged      -> UNIT_INVENTORY_CHANGED (unitTarget)
-- plus GetTime / InCombatLockdown (globals.txt) for the settle clock and the trace's
-- combat flag. See the SETTLE-AWARE CAPTURE banner further down for WHY.
--
-- Bank rule: bank containers are only READABLE while the bank frame is open, so
-- we gate bank scanning on a BANKFRAME_OPENED..CLOSED window and otherwise leave
-- the last-seen bank snapshot untouched (its per-container ts goes stale — that
-- is the intended "as last parked" behaviour).
--
-- The heavy lifting lives in PURE functions (BuildSlot / ScanContainer /
-- BuildSnapshot) that take an injected `api` table, so the headless harness can
-- drive a full scan with a fake container API — no live globals required.

local ADDON, ns = ...

local Capture = {}
ns.Capture = Capture

local Store = ns.Store

----------------------------------------------------------------------
-- Identity helpers (live)
----------------------------------------------------------------------

local function selfNameRealm()
    local name  = (_G.UnitName and _G.UnitName("player")) or "Unknown"
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))   -- SV realm keys are space-stripped in 1.x
    return Store.MakeNameRealm(name, realm), name, realm
end

local function liveIdentity()
    local ident = {}
    if _G.UnitClass then
        local _, tag = _G.UnitClass("player")
        ident.class = tag
    end
    if _G.UnitRace then
        local _, tag = _G.UnitRace("player")
        ident.race = tag
    end
    if _G.UnitSex     then ident.sex     = _G.UnitSex("player") end
    if _G.UnitFactionGroup then ident.faction = _G.UnitFactionGroup("player") end
    if _G.UnitLevel   then ident.level   = _G.UnitLevel("player") end
    return ident
end

----------------------------------------------------------------------
-- PURE scan core (api-injected; unit-testable headless)
--
-- `api` shape (every field a function; all optional except numSlots/itemInfo):
--   api.numSlots(cid)          -> numSlots (0/nil => empty/absent container)
--   api.itemInfo(cid, slot)    -> { itemID, stackCount, quality, hyperlink } | nil
--   api.bagLink(cid)           -> string link of the bag item in this slot | nil
--   api.bagFamily(cid)         -> number bag family bitmask | nil
----------------------------------------------------------------------

-- Turn one ContainerItemInfo-style struct into a store slot, or nil if empty.
function Capture.BuildSlot(info)
    if type(info) ~= "table" then return nil end
    local id = info.itemID
    if not id then return nil end
    return Store.NewSlot(id, info.stackCount or 1, info.quality, info.hyperlink)
end

-- Scan a single container into a fresh store container table (nil if the
-- container does not exist for this character, e.g. an unowned bag slot).
--
-- `stats` (optional, mutated) accumulates SCAN-TIME facts the snapshot itself cannot
-- carry, because they are transient and must never be persisted: stats.locked counts
-- slots the client reported isLocked DURING this scan. A non-zero count is the signal
-- that we read the bags mid-flight — see Capture.ArmSettle.
function Capture.ScanContainer(cid, api, stats)
    local n = api.numSlots and api.numSlots(cid)
    if not n or n <= 0 then
        -- A zero-size result means "no bag here". We still return an empty
        -- container for real storage ids (backpack/bank/keyring) so their
        -- emptiness is recorded; for unowned bag slots we return nil.
        local class = Store.ContainerClass(cid)
        if class == "bag" or class == "bankbag" then return nil end
        n = n or 0
    end
    local link   = api.bagLink   and api.bagLink(cid)   or nil
    local family = api.bagFamily and api.bagFamily(cid) or nil
    local c = Store.NewContainer(n, link, family)
    for slot = 1, n do
        local info = api.itemInfo and api.itemInfo(cid, slot)
        if stats and type(info) == "table" and info.isLocked then
            stats.locked = (stats.locked or 0) + 1
        end
        local slotRec = Capture.BuildSlot(info)
        if slotRec then c.slots[slot] = slotRec end
    end
    return c
end

-- The full list of container ids to scan for a given scope.
--   scope.bank == true   -> include bank main (-1) and bank bags
--   always                -> backpack (0), carried bags (1..N), keyring (-2)
function Capture.ContainerIDs(scope)
    local ids = { Store.BACKPACK_CONTAINER }
    for i = 1, Store.NumBagSlots() do ids[#ids + 1] = i end
    ids[#ids + 1] = Store.KEYRING_CONTAINER
    if scope and scope.bank then
        ids[#ids + 1] = Store.BANK_CONTAINER
        local first = Store.NumBagSlots() + 1
        local last  = Store.NumBagSlots() + Store.NumBankBagSlots()
        for i = first, last do ids[#ids + 1] = i end
    end
    return ids
end

-- Build a complete snapshot into `owner` using `api`. Bank containers are only
-- touched when scope.bank is set (frame open), so a normal carried-bag update
-- never clobbers the parked bank snapshot. `now` is injectable for tests.
-- Returns counts { containers, slots, locked } — `locked` being the number of slots the
-- client reported mid-flight during THIS scan (see ScanContainer's `stats`).
function Capture.BuildSnapshot(owner, api, scope, now)
    now = now or Store.Now()
    local nContainers, nSlots = 0, 0
    local stats = { locked = 0 }
    for _, cid in ipairs(Capture.ContainerIDs(scope)) do
        local c = Capture.ScanContainer(cid, api, stats)
        if c then
            Store.PutContainer(owner, cid, c, now)
            nContainers = nContainers + 1
            for _ in pairs(c.slots) do nSlots = nSlots + 1 end
        end
    end
    Store.RecomputeItemCounts(owner)
    Store.BumpRevision(owner, now)
    return { containers = nContainers, slots = nSlots, locked = stats.locked }
end

----------------------------------------------------------------------
-- Live API binding (C_Container) — only built in-game
----------------------------------------------------------------------

local function liveAPI()
    local CC = _G.C_Container
    if not CC then return nil end
    return {
        numSlots = CC.GetContainerNumSlots,
        itemInfo = function(cid, slot)
            -- GetContainerItemInfo returns a ContainerItemInfo struct on 1.15.
            local info = CC.GetContainerItemInfo and CC.GetContainerItemInfo(cid, slot)
            if type(info) == "table" then return info end
            return nil
        end,
        bagLink = function(cid)
            if cid <= 0 then return nil end   -- backpack/bank/keyring have no bag item
            if not CC.ContainerIDToInventoryID or not _G.GetInventoryItemLink then
                return nil
            end
            local invID = CC.ContainerIDToInventoryID(cid)
            if not invID then return nil end
            return _G.GetInventoryItemLink("player", invID)
        end,
        bagFamily = function(cid)
            if cid <= 0 then return nil end
            local _, fam = CC.GetContainerNumFreeSlots and CC.GetContainerNumFreeSlots(cid)
            return fam
        end,
    }
end

----------------------------------------------------------------------
-- SETTLE-AWARE CAPTURE  (2.0.5) — the in-combat equip-swap stale-cell defect
--
-- OWNER REPORT: "if i click something in my bags to equip it in combat, the icon of
-- that bag slot isn't getting updated. i equipped my shield while in combat but the
-- icon in my bag for my OH weapon was still my shield."
--
-- 2.0.4's repaint chain was:
--     BAG_UPDATE / BAG_UPDATE_DELAYED -> RequestCapture (coalesced to the NEXT FRAME)
--       -> Capture -> ns:Fire("BAGS_CAPTURED") -> Frame.RequestRefresh -> Rebuild
-- with no combat gate anywhere in it. What it did NOT have is any notion of SETTLEMENT,
-- and that is the whole defect.
--
-- ── THE CLIENT FACT (proven twice already, this repo) ────────────────────────────
-- 2.0.3's sort convergence work established it and wrote it down at sort.lua's
-- releasePred: "the lock releases on ITEM_LOCK_CHANGED; the slot's CONTENTS are
-- rewritten later". Between those two instants the slot reads UNLOCKED and shows its
-- PRE-SWAP contents. 2.0.2's executor retired predictions there and re-issued moves it
-- had already landed; the 2.0.3 fix was to retire on CONTENT, not on the lock.
--
-- Capture had the same blind spot in a different shape. A next-frame capture triggered by
-- the swap's opening BAG_UPDATE reads the bag slot BEFORE the client has published the
-- item that landed in it — so the store is written with the shield still sitting in the
-- off-hand's bag slot. If nothing re-fires BAG_UPDATE after the contents actually land,
-- that stale snapshot is the last word: the cell reads "shield" until some unrelated bag
-- event happens minutes later. Nothing in 2.0.4 could heal it, because the ONE signal
-- that does arrive at the settle — ITEM_LOCK_CHANGED — was wired only to
-- Frame.RequestRefresh (ui_frame.lua:2787), which REPAINTS FROM THE STALE STORE.
--
-- 1.x CONTRAST (core/api/events.lua, deleted at the 2.0 cutover): 1.x queued bags on
-- BAG_UPDATE and then ran `Delay(0.08, 'UpdateBags')` — a mutex delay RESTARTED by every
-- later bag event, so its re-read happened 80ms after the burst went quiet, i.e. after
-- the contents landed. It also painted each cell straight from the live container API
-- rather than from a persisted snapshot. Both properties made it accidentally immune.
-- 2.0's C_Timer.After(0) coalescer is faster and strictly worse here.
--
-- ── THE FIX ─────────────────────────────────────────────────────────────────────
--  1. REGISTER THE MISSING SIGNALS. ITEM_LOCK_CHANGED (the true settle cue — a lock
--     RELEASE on a bag slot), PLAYER_EQUIPMENT_CHANGED and UNIT_INVENTORY_CHANGED
--     ("player") now RE-REQUEST A CAPTURE, not merely a repaint. Cheap: RequestCapture is
--     already coalesced to one scan per frame, and sort.lua stubs it out wholesale for the
--     duration of a run (its beginQuiet), so a sort's lock storm costs nothing here.
--
--  2. SETTLE-AWARE, WITHOUT WAITING. A capture never blocks. Instead every equipment-ish
--     signal ARMS A LADDER of short follow-up re-requests (SETTLE_LADDER), and any scan
--     that saw a locked slot re-arms it. That is the same shape as sort.lua's PredSettled
--     and Conduit's awaitSettlement, scoped down to "ask again shortly" rather than "hold
--     a decision open" — capture has no decision to hold, it just needs a later look.
--     Bounded by construction: the ladder is a fixed 3 entries, re-arming is refused while
--     one is in flight, and each rung is one already-coalesced RequestCapture.
--
--     REJECTED ALTERNATIVE, recorded so it is not retried: inferring settlement from a
--     BAG_UPDATE_DELAYED "the burst is over" stamp. sort.lua measured that exact idea and
--     it REINTRODUCED the bug it was meant to fix (232 executed moves for a 72-move plan),
--     because bag updates arrive per landing change, not once per burst. Capture's ladder
--     deliberately does not try to be clever about which signal means "done"; it re-reads
--     three times over 0.6s and lets the last read win.
----------------------------------------------------------------------

Capture._bankOpen    = false   -- BANKFRAME_OPENED..CLOSED window
Capture._captureQueued = false

-- Follow-up re-read offsets, seconds after the arming signal. Three rungs over 0.6s:
-- long enough to outlast a normal server round-trip, short enough that the owner never
-- sees the stale cell as anything but a flicker. Each rung is one coalesced RequestCapture
-- (~5 containers x ~16 GetContainerItemInfo calls), and the ladder only exists at all
-- while an equipment-ish signal is in play.
Capture.SETTLE_LADDER = { 0.10, 0.30, 0.60 }

-- Consecutive ladders one stuck slot may provoke. A slot the client never unlocks (a
-- dropped move, a server that stopped answering) would otherwise re-arm forever and cost a
-- full bag scan every 0.6s for the rest of the session. Same reasoning as sort.lua's
-- LOCK_TTL: observed state is the authority, but pathology needs a ceiling. The budget is
-- reset by any clean scan and by every fresh user action, so it can only bound a genuinely
-- stuck bag — ~3s of retries.
Capture.SETTLE_MAX_CHAIN = 5

Capture._settleArmed = false
Capture._settleChain = 0

-- Monotonic seconds. GetTime() in-game; os.clock() headless (harness / simulator).
-- Same idiom as sort.lua's nowSeconds — deliberately duplicated rather than reached
-- across files, so capture.lua stays loadable with or without sort.lua.
-- (`os` is absent from the WoW Lua sandbox, and unlike sort.lua's copy this one is reached
-- on every equipment signal rather than only inside a sort, so it degrades to 0 rather
-- than indexing a nil global if GetTime ever went missing.)
local function mono()
    if _G.GetTime then return _G.GetTime() end
    if os and os.clock then return os.clock() end
    return 0
end
Capture._mono = mono

local function after(delay, fn)
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(delay, fn) else fn() end
end

-- Arm the follow-up ladder. Refused while one is already draining, so a burst of twenty
-- ITEM_LOCK_CHANGEDs costs exactly one ladder. Re-armable the moment the last rung fires,
-- which is what lets a still-locked scan keep asking.
function Capture.ArmSettle()
    if Capture._settleArmed then return end
    if (Capture._settleChain or 0) >= Capture.SETTLE_MAX_CHAIN then return end
    Capture._settleChain = (Capture._settleChain or 0) + 1
    Capture._settleArmed = true
    local remaining = #Capture.SETTLE_LADDER
    for i = 1, #Capture.SETTLE_LADDER do
        after(Capture.SETTLE_LADDER[i], function()
            remaining = remaining - 1
            if remaining <= 0 then Capture._settleArmed = false end
            Capture.RequestCapture()
        end)
    end
end

----------------------------------------------------------------------
-- THE EQUIP TRACE RING  (2.0.5) — DaseekiBags2DB.equipTrace
--
-- House doctrine after the 2.0.2/2.0.3 sort rounds: a defect that is a SILENT behavioural
-- report (no Lua error, the cell simply does not change) gets a persisted trace, so the
-- next report is answered from the owner's own WTF file instead of another guess-and-ship
-- loop. This is sortLog's sibling and follows the same three rules:
--
--   FLAT      every field is a scalar. A SavedVariables dump is one `{ ... }` per capture
--             that any parser reads line-wise, and a field added later cannot reshape the
--             records already written.
--   BOUNDED   a plain 1..n array, oldest first, capped at Capture.TRACE_CAP; appending past
--             the cap drops index 1 and shifts.
--   ADDITIVE  the key is created LAZILY, only when something is actually recorded, so a
--             character that never equips anything writes no new SavedVariables key at all.
--
-- WHAT IS RECORDED: every capture that happens inside an EQUIP WINDOW — opened by an
-- equipment-ish signal, closed when the settle ladder has drained with nothing locked, or
-- TRACE_WINDOW seconds later, whichever comes first. That is ~4 records per equip.
--
--   ts           epoch seconds (Store.Now)
--   version      ns.VERSION, so a mixed log is still attributable
--   trigger      the signal that OPENED this window ("PLAYER_EQUIPMENT_CHANGED", ...)
--   seq          the signal sequence OBSERVED in this window, compact and in order:
--                ILC=ITEM_LOCK_CHANGED  PEC=PLAYER_EQUIPMENT_CHANGED
--                UIC=UNIT_INVENTORY_CHANGED  BU=BAG_UPDATE  BUD=BAG_UPDATE_DELAYED
--                PBS/PBB=bank slot events  PM=PLAYER_MONEY
--   combat       InCombatLockdown() at capture time — the owner's case is `true`
--   pass         which capture inside this window (1 = the coalesced next-frame one,
--                2..4 = settle-ladder rungs)
--   sinceMs      ms from the window opening to this capture
--   lockedSlots  slots reading isLocked during THIS scan (mid-flight evidence)
--   changed      slots whose itemID differs from the PREVIOUS snapshot. Stack-count-only
--                changes are deliberately not counted: the equip story is about identity.
--   cid/slot     the FIRST changed slot (meaningful only when changed > 0; cid 0 is the
--                backpack and is a legitimate value, so `changed` is the guard, not cid)
--   preID/postID that slot's itemID before and after this capture
--   equipSlot    the PLAYER_EQUIPMENT_CHANGED inventory slot for this window (17 = off
--                hand), 0 when the window was not opened by one
--   followUp     did this pass arm another look (i.e. did it see the bags mid-flight)
--   paint        what the grid last DID with a snapshot: "repaint" (in-combat data-only
--                repaint), "layout" (full relayout), "defer" (structural change refused in
--                combat, queued for PLAYER_REGEN_ENABLED) or "idle" (nothing drawn yet).
--                This is the half of the chain that lives in ui_items.lua; without it a
--                trace cannot tell "we captured stale" from "we captured fine and the cell
--                was never redrawn", which are two different bugs with the same symptom.
----------------------------------------------------------------------

Capture.TRACE_CAP    = 60    -- ~15 equips of history
Capture.TRACE_WINDOW = 10    -- seconds an equip window may stay open
Capture.SEQ_MAX      = 16    -- signal tokens kept per window (the rest are dropped)

-- The declared field order — also the parse contract, and what the printer walks.
Capture.TRACE_FIELDS = {
    "ts", "version", "trigger", "seq", "combat", "pass", "sinceMs",
    "lockedSlots", "changed", "cid", "slot", "preID", "postID",
    "equipSlot", "followUp", "paint",
}

-- Signals that OPEN a window. BAG_UPDATE and friends are recorded into an open window but
-- never open one: otherwise every loot, vendor sale and quest turn-in would write trace
-- records, and the ring would never hold the equip we were asked about.
Capture.WINDOW_OPENERS = {
    ITEM_LOCK_CHANGED       = true,
    PLAYER_EQUIPMENT_CHANGED = true,
    UNIT_INVENTORY_CHANGED  = true,
}

local SEQ_TOKEN = {
    ITEM_LOCK_CHANGED          = "ILC",
    PLAYER_EQUIPMENT_CHANGED   = "PEC",
    UNIT_INVENTORY_CHANGED     = "UIC",
    BAG_UPDATE                 = "BU",
    BAG_UPDATE_DELAYED         = "BUD",
    PLAYERBANKSLOTS_CHANGED    = "PBS",
    PLAYERBANKBAGSLOTS_CHANGED = "PBB",
    PLAYER_MONEY               = "PM",
}
Capture.SEQ_TOKEN = SEQ_TOKEN

local function tnum(v) local n = tonumber(v); return n and math.floor(n + 0.5) or 0 end

-- Coerce anything into a complete, flat record. EVERY declared field is present and of its
-- declared type, so a malformed caller can never write a half record into the SV.
function Capture.NewTraceRecord(r)
    r = (type(r) == "table") and r or {}
    return {
        ts          = tnum(r.ts),
        version     = (type(r.version) == "string") and r.version or tostring(ns.VERSION or "?"),
        trigger     = (type(r.trigger) == "string") and r.trigger or "",
        seq         = (type(r.seq) == "string") and r.seq or "",
        combat      = r.combat and true or false,
        pass        = tnum(r.pass),
        sinceMs     = tnum(r.sinceMs),
        lockedSlots = tnum(r.lockedSlots),
        changed     = tnum(r.changed),
        cid         = tnum(r.cid),
        slot        = tnum(r.slot),
        preID       = tnum(r.preID),
        postID      = tnum(r.postID),
        equipSlot   = tnum(r.equipSlot),
        followUp    = r.followUp and true or false,
        paint       = (type(r.paint) == "string") and r.paint or "idle",
    }
end

-- The live buffer (array, oldest first). `create` allocates it on the settings DB.
-- Returns nil when there is no DB to hold it — the caller must degrade, never error.
function Capture.TraceBuffer(db, create)
    db = db or (Store and Store.db)
    if type(db) ~= "table" then return nil end
    if type(db.equipTrace) ~= "table" then
        if not create then return nil end
        db.equipTrace = {}
    end
    return db.equipTrace
end

function Capture.TraceAppend(db, rec, cap)
    local buf = Capture.TraceBuffer(db, true)
    if not buf then return nil end
    cap = tonumber(cap) or Capture.TRACE_CAP
    if cap < 1 then cap = 1 end
    local stored = Capture.NewTraceRecord(rec)
    buf[#buf + 1] = stored
    -- A while-loop, not a single remove: a cap LOWERED between releases must still converge
    -- on the first append rather than leaking one stale record per equip.
    while #buf > cap do table.remove(buf, 1) end
    return stored
end

-- Newest-first copy for the reader. Never hands out the live table.
function Capture.TraceRecords(db)
    local buf = Capture.TraceBuffer(db, false)
    local out = {}
    if not buf then return out end
    for i = #buf, 1, -1 do
        if type(buf[i]) == "table" then out[#out + 1] = buf[i] end
    end
    return out
end

function Capture.TraceCount(db)
    local buf = Capture.TraceBuffer(db, false)
    return buf and #buf or 0
end

-- Empty the buffer IN PLACE (the SV table identity survives, so nothing holding a
-- reference to it is left pointing at a corpse).
function Capture.TraceClear(db)
    local buf = Capture.TraceBuffer(db, false)
    if not buf then return 0 end
    local n = #buf
    for i = n, 1, -1 do buf[i] = nil end
    return n
end

-- One record -> one line, in TRACE_FIELDS order. Pure, so the harness pins the format.
function Capture.FormatTraceRecord(rec)
    local parts = {}
    for _, f in ipairs(Capture.TRACE_FIELDS) do
        local v = rec[f]
        if type(v) == "boolean" then v = v and "yes" or "no" end
        parts[#parts + 1] = f .. "=" .. tostring(v)
    end
    return table.concat(parts, " ")
end

-- `/bags debug equiptrace [clear]` — print the ring, newest first.
function Capture.PrintTrace(arg)
    if not ns.Print then return end
    arg = (type(arg) == "string") and arg:lower():match("^%s*(%S*)") or ""
    if arg == "clear" then
        local n = Capture.TraceClear()
        ns:Print("equip trace cleared (" .. n .. " record(s)).")
        return
    end
    local recs = Capture.TraceRecords()
    if #recs == 0 then
        ns:Print("equip trace is empty — equip something from your bags and it fills. " ..
                 "(/bags debug equiptrace clear empties it.)")
        return
    end
    ns:Print("equip trace — " .. #recs .. " capture(s), newest first:")
    for i = 1, #recs do
        ns:Print("  " .. Capture.FormatTraceRecord(recs[i]))
    end
end

----------------------------------------------------------------------
-- Equip window bookkeeping
----------------------------------------------------------------------

Capture._win = nil   -- { open, trigger, seq = {}, pass, equipSlot }

-- Record one observed signal. Opens a window when the signal is an opener and none is
-- live (or the live one has aged out). Costs one table append while a window is open and
-- nothing at all otherwise.
function Capture.NoteSignal(evt, a1)
    local w = Capture._win
    local nowM = mono()
    if w and (nowM - w.open) > Capture.TRACE_WINDOW then w, Capture._win = nil, nil end
    if not w then
        if not Capture.WINDOW_OPENERS[evt] then return nil end
        w = { open = nowM, trigger = evt, seq = {}, pass = 0, equipSlot = 0 }
        Capture._win = w
    end
    if #w.seq < Capture.SEQ_MAX then w.seq[#w.seq + 1] = SEQ_TOKEN[evt] or evt end
    if evt == "PLAYER_EQUIPMENT_CHANGED" and tonumber(a1) then w.equipSlot = tonumber(a1) end
    return w
end

-- itemID by packed (cid, slot) for every container in scope. cid is small and signed
-- (-2..11) and slots never reach 1000, so cid*1000 + slot is a unique, decodable key for
-- negative cids too (floor(-1997/1000) == -2, slot 3).
local function slotMap(owner, ids)
    local m = {}
    for _, cid in ipairs(ids) do
        local c = Store.GetContainer(owner, cid)
        if c then
            for slot, s in pairs(c.slots) do m[cid * 1000 + slot] = s.id end
        end
    end
    return m
end

-- Diff two slot maps. Returns count, and the LOWEST-keyed changed slot decomposed — a
-- deterministic pick, so two runs over the same swap write the same record.
local function diffSlots(pre, post)
    local n, bestKey = 0, nil
    for k, id in pairs(post) do
        if pre[k] ~= id then
            n = n + 1
            if not bestKey or k < bestKey then bestKey = k end
        end
    end
    for k in pairs(pre) do
        if post[k] == nil then
            n = n + 1
            if not bestKey or k < bestKey then bestKey = k end
        end
    end
    if not bestKey then return 0, 0, 0, 0, 0 end
    local cid  = math.floor(bestKey / 1000)
    local slot = bestKey - cid * 1000
    return n, cid, slot, pre[bestKey] or 0, post[bestKey] or 0
end
Capture._diffSlots = diffSlots
Capture._slotMap   = slotMap

-- Perform one live capture into the store. No-ops headless (no C_Container).
function Capture.Capture()
    if not Store.data then return end
    local api = liveAPI()
    if not api then return end

    local nameRealm, name, realm = selfNameRealm()
    local owner = Store.EnsureOwner(nameRealm, name, realm)
    owner.source  = "full"
    owner.account = Store.data.selfAccount or ""

    Store.SetIdentity(owner, liveIdentity())
    if _G.GetMoney then Store.SetMoney(owner, _G.GetMoney()) end

    Capture.CaptureEquip(owner)

    local scope = { bank = Capture._bankOpen }
    -- The pre-scan slot map is built ONLY inside an equip window: outside one it is dead
    -- weight on every loot event, and inside one it is the only way to say what the swap
    -- actually did to the cell the owner is looking at.
    local w   = Capture._win
    local ids = w and Capture.ContainerIDs(scope) or nil
    local pre = w and slotMap(owner, ids) or nil

    local counts = Capture.BuildSnapshot(owner, api, scope)

    -- Mid-flight read: the client is still holding at least one slot, so what we just wrote
    -- may be pre-swap. Ask again shortly. (Never blocks; the snapshot we took stands until
    -- a later one replaces it, exactly as before.)
    local sawLocked = (counts.locked or 0) > 0
    if sawLocked then Capture.ArmSettle() else Capture._settleChain = 0 end

    if w then Capture.TraceCapture(w, owner, pre, ids, counts, sawLocked) end

    if ns.Fire then ns:Fire("BAGS_CAPTURED", nameRealm, owner) end
end

-- Append this capture to the equip trace, and close the window when the story is over:
-- the settle ladder has drained AND nothing read locked. Bounded either way by the
-- TRACE_WINDOW age check in NoteSignal.
function Capture.TraceCapture(w, owner, pre, ids, counts, sawLocked)
    w.pass = w.pass + 1
    local post = slotMap(owner, ids)
    local n, cid, slot, preID, postID = diffSlots(pre or {}, post)
    local paint = (ns.Items and type(ns.Items.LastPaintMode) == "function"
                   and ns.Items.LastPaintMode()) or "idle"
    Capture.TraceAppend(nil, {
        ts          = Store.Now(),
        version     = tostring(ns.VERSION or "?"),
        trigger     = w.trigger,
        seq         = table.concat(w.seq, ">"),
        combat      = (_G.InCombatLockdown and _G.InCombatLockdown()) and true or false,
        pass        = w.pass,
        sinceMs     = (mono() - w.open) * 1000,
        lockedSlots = counts.locked or 0,
        changed     = n,
        cid         = cid,
        slot        = slot,
        preID       = preID,
        postID      = postID,
        equipSlot   = w.equipSlot,
        followUp    = sawLocked or Capture._settleArmed or false,
        paint       = paint,
    })
    if not Capture._settleArmed and not sawLocked then Capture._win = nil end
end

-- Snapshot equipped items (appearance-relevant). Best-effort; guarded.
function Capture.CaptureEquip(owner)
    if not _G.GetInventoryItemID then return end
    owner.equip = {}
    -- Classic equipment slots 1..19 (INVSLOT_FIRST_EQUIPPED..LAST). We probe
    -- the stable range; absent slots simply return nil.
    for invSlot = 1, 19 do
        local id = _G.GetInventoryItemID("player", invSlot)
        if id then
            local count = (_G.GetInventoryItemCount and _G.GetInventoryItemCount("player", invSlot)) or 1
            owner.equip[invSlot] = { id = id, count = count }
        end
    end
end

-- Coalesce bursty bag events into one capture on the next frame tick.
function Capture.RequestCapture()
    if Capture._captureQueued then return end
    Capture._captureQueued = true
    local fire = function()
        Capture._captureQueued = false
        if ns.SafeCall then ns:SafeCall(Capture.Capture) else Capture.Capture() end
    end
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, fire)
    else
        fire()
    end
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

-- The events that re-request a capture. Split into two rosters because they differ in ONE
-- property — whether the signal may OPEN an equip-trace window and arm the settle ladder —
-- and because a self-test can then assert the roster instead of trusting the wiring.
Capture.BAG_EVENTS = {
    "BAG_UPDATE_DELAYED",         -- primary carried-bag refresh (coalesced by Blizzard)
    "BAG_UPDATE",                 -- also carries keyring (bagID -2)
    "PLAYER_MONEY",               -- gold changed
    "PLAYERBANKSLOTS_CHANGED",    -- bank main slots
    "PLAYERBANKBAGSLOTS_CHANGED", -- bank bag slots
}

-- 2.0.5. The three signals an equip swap actually emits, and which 2.0.4 was deaf to.
-- ITEM_LOCK_CHANGED is the load-bearing one: a lock RELEASE on a bag slot is the client
-- saying "this slot is done moving", and it is the only signal guaranteed to arrive when
-- the swap's own BAG_UPDATE landed too early to see the result. ui_frame.lua has listened
-- to it since 2.0.0 — but only to REPAINT, which redraws the stale store. It has to reach
-- the SCAN.
Capture.EQUIP_EVENTS = {
    "ITEM_LOCK_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED",
    "UNIT_INVENTORY_CHANGED",
}

function Capture.OnLogin()
    for _, evt in ipairs(Capture.BAG_EVENTS) do
        if ns.RegisterEvent then
            ns:RegisterEvent(evt, function(e)
                Capture.NoteSignal(e or evt)
                Capture.RequestCapture()
            end)
        end
    end
    for _, evt in ipairs(Capture.EQUIP_EVENTS) do
        if ns.RegisterEvent then
            ns:RegisterEvent(evt, function(e, a1)
                -- UNIT_INVENTORY_CHANGED fires for every unit we have info on; only the
                -- player's own inventory can change our bags.
                if (e or evt) == "UNIT_INVENTORY_CHANGED" and a1 ~= nil and a1 ~= "player" then
                    return
                end
                Capture.NoteSignal(e or evt, a1)
                -- A fresh user action always gets a fresh retry budget: the chain cap
                -- exists to bound ONE stuck slot, not to run out mid-session.
                Capture._settleChain = 0
                Capture.ArmSettle()
                Capture.RequestCapture()
            end)
        end
    end
    -- Bank window gating: open enables bank scanning, close disables it after a
    -- final capture so the just-seen bank state is stored.
    if ns.RegisterEvent then
        ns:RegisterEvent("BANKFRAME_OPENED", function()
            Capture._bankOpen = true
            Capture.RequestCapture()
        end)
        ns:RegisterEvent("BANKFRAME_CLOSED", function()
            Capture.RequestCapture()      -- capture the final state while still readable
            Capture._bankOpen = false
        end)
    end
    -- First snapshot once the world is up.
    Capture.RequestCapture()
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "capture") — driven by a fake container API
----------------------------------------------------------------------

-- Build a fake api from a plain fixture:
--   fixture[cid] = { size = N, link = <str>, family = <n>, items = { [slot] = {itemID, stackCount, quality, hyperlink} } }
-- A cid absent from the fixture reports numSlots 0 (unowned bag slot / empty).
local function fakeAPI(fixture)
    return {
        numSlots = function(cid)
            local c = fixture[cid]
            return c and c.size or 0
        end,
        itemInfo = function(cid, slot)
            local c = fixture[cid]
            return c and c.items and c.items[slot] or nil
        end,
        bagLink   = function(cid) local c = fixture[cid]; return c and c.link end,
        bagFamily = function(cid) local c = fixture[cid]; return c and c.family end,
    }
end

local function testBuildSlot(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Capture.BuildSlot(nil) == nil, "nil info -> nil slot")
    ck(Capture.BuildSlot({}) == nil, "empty struct (no itemID) -> nil")
    local s = Capture.BuildSlot({ itemID = 22157, stackCount = 5, quality = 3, hyperlink = "item:22157" })
    ck(s and s.id == 22157 and s.count == 5 and s.quality == 3 and s.link == "item:22157",
        "full struct -> populated slot")
    local s2 = Capture.BuildSlot({ itemID = 6948 })   -- stackCount absent
    ck(s2.count == 1, "missing stackCount defaults to 1")
end

local function testScanContainer(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local fix = {
        [0]  = { size = 16, items = { [1] = { itemID = 6948, stackCount = 1, quality = 1 },
                                      [5] = { itemID = 22157, stackCount = 20, quality = 3 } } },
        [1]  = { size = 14, link = "item:14046", family = 0 },  -- an empty carried bag
    }
    local api = fakeAPI(fix)
    local c0 = Capture.ScanContainer(0, api)
    ck(c0.size == 16, "backpack size 16")
    ck(c0.slots[1].id == 6948 and c0.slots[5].count == 20, "sparse slots captured")
    ck(c0.slots[2] == nil, "empty slots stay nil")
    local c1 = Capture.ScanContainer(1, api)
    ck(c1.link == "item:14046" and c1.size == 14, "bag link + size captured")
    ck(next(c1.slots) == nil, "empty bag has no slots")
    -- Unowned bag slot (not in fixture) -> nil for a bag id.
    ck(Capture.ScanContainer(4, api) == nil, "unowned bag slot -> nil container")
    -- Backpack always returns a container even when empty.
    local empty = Capture.ScanContainer(0, fakeAPI({}))
    ck(empty ~= nil and next(empty.slots) == nil, "empty backpack still stored")
end

local function testSnapshotBankGating(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    _G.DaseekiBags2Data = nil; Store.Init()
    local fix = {
        [0]  = { size = 16, items = { [1] = { itemID = 6948, stackCount = 1 } } },
        [1]  = { size = 14, link = "item:14046",
                 items = { [1] = { itemID = 22157, stackCount = 20 } } },
        [-2] = { size = 12, items = { [1] = { itemID = 5175, stackCount = 1 } } }, -- keyring
        [-1] = { size = 24, items = { [1] = { itemID = 4306, stackCount = 20 } } }, -- bank main
        [5]  = { size = 16, link = "item:14156",
                 items = { [1] = { itemID = 4338, stackCount = 8 } } },             -- bank bag
    }
    local api = fakeAPI(fix)
    local o = Store.EnsureOwner("Tester-TestRealm")

    -- Carried-only scope: bank containers must NOT be written.
    Capture.BuildSnapshot(o, api, { bank = false }, 100)
    ck(Store.GetContainer(o, 0) ~= nil, "backpack captured")
    ck(Store.GetContainer(o, -2) ~= nil, "keyring captured (carried scope)")
    ck(Store.GetContainer(o, -1) == nil, "bank NOT captured without bank scope")
    ck(Store.GetContainer(o, 5) == nil, "bank bag NOT captured without bank scope")
    local revAfterFirst = o.rev
    ck(revAfterFirst == 1, "revision bumped once")

    -- Bank scope: now bank containers appear, carried stay.
    Capture.BuildSnapshot(o, api, { bank = true }, 200)
    ck(Store.GetContainer(o, -1) ~= nil, "bank captured with bank scope")
    ck(Store.GetContainer(o, 5) ~= nil, "bank bag captured with bank scope")
    ck(Store.ContainerAge(o, -1, 260) == 60, "bank container ts stamped at scan time")
    ck(o.rev == 2, "revision bumped to 2")

    -- itemCounts aggregate across everything scanned.
    ck(o.itemCounts[22157] == 20 and o.itemCounts[4306] == 20 and o.itemCounts[4338] == 8,
        "itemCounts aggregate carried + bank")
end

----------------------------------------------------------------------
-- THE IN-COMBAT EQUIP-SWAP SIMULATOR  (suite "equip-refresh")
--
-- A locking bag client with a scripted event timeline, driving the REAL chain:
-- our registered handlers -> Capture.NoteSignal / ArmSettle / RequestCapture ->
-- Capture.Capture -> Store -> Frame.BuildCombinedEntries (the cell model).
-- Nothing is stubbed between the event and the cell except the client itself.
--
-- The four PROFILES are the orders a 1.15 client can plausibly emit for one equip swap.
-- The load-bearing client fact they differ on is the one 2.0.3 proved for the sort
-- executor: the lock RELEASES before the contents are rewritten, so "unlocked" is not
-- "settled" and an event that fires at the release still reads the PRE-swap item.
--
--   bagupdate-before-settle  BAG_UPDATE fires with the swap's opening lock, the release
--                            follows, and the contents land AFTER both — with no further
--                            bag event. The next-frame capture reads pre-swap and nothing
--                            ever asks again. This is the profile that reproduces.
--   settle-signal-only       no BAG_UPDATE at all: only ITEM_LOCK_CHANGED,
--                            PLAYER_EQUIPMENT_CHANGED and UNIT_INVENTORY_CHANGED. 2.0.4
--                            never captured once. Also reproduces.
--   delayed-deferred         as the first, but a BAG_UPDATE_DELAYED lands after the
--                            contents do. CONTROL: 2.0.4 heals this one on its own, which
--                            is what proves the rig is not simply rejecting everything.
--   burst-at-settle          the happy path — the bag event arrives at the instant the
--                            contents are published. Both chains heal it.
--
-- Every profile is run TWICE: once against the shipping chain, and once against a LEGACY
-- MUTANT that registers only the 2.0.4 bag events and no-ops the settle ladder. The mutant
-- must FAIL exactly the two reproducing profiles — a permanent red-to-green record, and a
-- gate that turns red if anyone quietly deletes the new registrations again.
--
-- THE FIXTURE IS THE OWNER'S REPORT: a shield sits in backpack slot 3, he clicks it in
-- combat, the shield goes to the off-hand (inventory slot 17) and the off-hand weapon
-- lands in slot 3. The cell must end up reading the WEAPON.
----------------------------------------------------------------------

local SHIELD, OHWEAPON = 90001, 90002
local SWAP_CID, SWAP_SLOT = 0, 3

local function newSim()
    local S = { clock = 0, timers = {}, seq = 0, handlers = {}, combat = true }
    S.bags = {
        [0]  = { size = 16, items = {
                    [1] = { itemID = 6948,   stackCount = 1 },
                    [3] = { itemID = SHIELD, stackCount = 1 },
                    [7] = { itemID = 22157,  stackCount = 20 } } },
        [1]  = { size = 14, link = "item:14046", items = {} },
        [-2] = { size = 12, items = {} },
    }

    function S:set(cid, slot, itemID)
        local c = self.bags[cid]
        if not itemID then c.items[slot] = nil; return end
        local cur = c.items[slot] or {}
        cur.itemID, cur.stackCount = itemID, cur.stackCount or 1
        c.items[slot] = cur
    end
    function S:lock(cid, slot, on)
        local it = self.bags[cid] and self.bags[cid].items[slot]
        if it then it.isLocked = on and true or nil end
    end
    function S:fire(evt, ...)
        local list = self.handlers[evt]
        if not list then return end
        for i = 1, #list do list[i](evt, ...) end
    end
    -- Run every timer due at or before clock+dt, earliest first, then park the clock at
    -- the target. A timer that schedules another timer is picked up in the same sweep.
    function S:advance(dt)
        local target = self.clock + dt
        while true do
            local best, bi
            for i = 1, #self.timers do
                local t = self.timers[i]
                if t.at <= target and (not best or t.at < best.at or
                                       (t.at == best.at and t.seq < best.seq)) then
                    best, bi = t, i
                end
            end
            if not best then break end
            table.remove(self.timers, bi)
            if best.at > self.clock then self.clock = best.at end
            best.fn()
        end
        self.clock = target
    end
    return S
end

-- Every global the sim replaces. An explicit LIST, not a saved-values table: the harness
-- leaves most of these absent (no C_Container is how it forces capture's live path to
-- no-op), so a `for k, v in pairs(saved)` restore silently skips every one whose original
-- value was nil and leaves the sim's client installed for the whole rest of the run. That
-- exact mistake left InCombatLockdown() returning true and turned an unrelated ui_frame
-- suite red; the list is the fix.
local SIM_GLOBALS = { "C_Container", "C_Timer", "GetTime", "GetMoney",
                      "GetInventoryItemID", "GetInventoryItemLink", "InCombatLockdown" }

-- Install the sim as the live client. Returns a restore function.
local function installSim(S, legacy)
    local saved = {}
    for _, k in ipairs(SIM_GLOBALS) do saved[k] = _G[k] end
    local savedRegister, savedArm = ns.RegisterEvent, Capture.ArmSettle
    _G.C_Container = {
        GetContainerNumSlots = function(cid)
            if cid == 0 then S.scans = (S.scans or 0) + 1 end   -- one per full snapshot
            local c = S.bags[cid]; return c and c.size or 0
        end,
        GetContainerItemInfo = function(cid, slot)
            local c = S.bags[cid]; return c and c.items[slot] or nil
        end,
        ContainerIDToInventoryID = function(cid) return 19 + cid end,
        GetContainerNumFreeSlots = function() return 0, 0 end,
    }
    _G.C_Timer = { After = function(delay, fn)
        S.seq = S.seq + 1
        S.timers[#S.timers + 1] = { at = S.clock + (tonumber(delay) or 0), fn = fn, seq = S.seq }
    end }
    _G.GetTime              = function() return S.clock end
    _G.GetMoney             = function() return 12345 end
    _G.GetInventoryItemID   = function() return nil end
    _G.GetInventoryItemLink = function() return nil end
    _G.InCombatLockdown     = function() return S.combat end

    -- Collect OUR real handlers rather than core's frame (headless has no event frame).
    ns.RegisterEvent = function(_, evt, fn)
        S.handlers[evt] = S.handlers[evt] or {}
        S.handlers[evt][#S.handlers[evt] + 1] = fn
    end
    -- THE MUTANT: 2.0.4's chain exactly — bag events only, no settle ladder.
    if legacy then
        Capture.EQUIP_EVENTS_SAVED = Capture.EQUIP_EVENTS
        Capture.EQUIP_EVENTS = {}
        Capture.ArmSettle = function() end
    end

    return function()
        if legacy then
            Capture.EQUIP_EVENTS = Capture.EQUIP_EVENTS_SAVED
            Capture.EQUIP_EVENTS_SAVED = nil
        end
        for _, k in ipairs(SIM_GLOBALS) do _G[k] = saved[k] end
        ns.RegisterEvent, Capture.ArmSettle = savedRegister, savedArm
    end
end

-- profile(S) -> array of { at = seconds, fn = function(S) }
local PROFILES = {
    {
        name = "bagupdate-before-settle", healsOn2_0_4 = false,
        steps = {
            { at = 0.00, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, true)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
                S:fire("BAG_UPDATE", SWAP_CID)
            end },
            { at = 0.05, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, false)          -- lock RELEASED...
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
                S:fire("PLAYER_EQUIPMENT_CHANGED", 17, true)
            end },
            { at = 0.09, fn = function(S)
                S:set(SWAP_CID, SWAP_SLOT, OHWEAPON)        -- ...contents land, silently
            end },
        },
    },
    {
        name = "settle-signal-only", healsOn2_0_4 = false,
        steps = {
            { at = 0.00, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, true)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
            end },
            { at = 0.05, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, false)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
                S:fire("PLAYER_EQUIPMENT_CHANGED", 17, true)
                S:fire("UNIT_INVENTORY_CHANGED", "player")
            end },
            { at = 0.09, fn = function(S) S:set(SWAP_CID, SWAP_SLOT, OHWEAPON) end },
        },
    },
    {
        name = "delayed-deferred", healsOn2_0_4 = true,
        steps = {
            { at = 0.00, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, true)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
                S:fire("BAG_UPDATE", SWAP_CID)
            end },
            { at = 0.05, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, false)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
            end },
            { at = 0.09, fn = function(S) S:set(SWAP_CID, SWAP_SLOT, OHWEAPON) end },
            { at = 0.14, fn = function(S) S:fire("BAG_UPDATE_DELAYED") end },
        },
    },
    {
        name = "burst-at-settle", healsOn2_0_4 = true,
        steps = {
            { at = 0.00, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, true)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
            end },
            { at = 0.06, fn = function(S)
                S:lock(SWAP_CID, SWAP_SLOT, false)
                S:set(SWAP_CID, SWAP_SLOT, OHWEAPON)
                S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
                S:fire("BAG_UPDATE", SWAP_CID)
                S:fire("PLAYER_EQUIPMENT_CHANGED", 17, true)
            end },
        },
    },
}
Capture._PROFILES = PROFILES

-- Drive one profile end to end. Returns the final cell itemID (from the CELL MODEL, not
-- the raw store) plus the store's own answer and the trace records written.
local function runProfile(profile, legacy, tail)
    _G.DaseekiBags2Data, _G.DaseekiBags2DB = nil, nil
    Store.Init()
    Capture._win, Capture._settleArmed, Capture._captureQueued = nil, false, false
    Capture._settleChain = 0

    local S = newSim()
    local restore = installSim(S, legacy)
    local ok, err = pcall(function()
        Capture.OnLogin()          -- registers the real handlers + takes the first snapshot
        S:advance(0.01)            -- let the login capture's After(0) run
        for _, step in ipairs(profile.steps) do
            S:advance(math.max(0, step.at - S.clock))
            step.fn(S)
        end
        S:advance(tail or 3.0)     -- quiet tail: anything that was going to heal has healed
    end)
    restore()
    if not ok then error(err, 0) end

    local owner = Store.GetOwner(Store.MakeNameRealm("Tester", "TestRealm"))
    local c     = owner and Store.GetContainer(owner, SWAP_CID)
    local stored = c and c.slots[SWAP_SLOT] and c.slots[SWAP_SLOT].id or nil

    -- The CELL as the grid would build it — the paint-path rule-out (#4): a changed
    -- snapshot must reach the cell model, or capture being right would not matter.
    local cell
    if ns.Frame and ns.Frame.BuildCombinedEntries and owner then
        for _, e in ipairs(ns.Frame.BuildCombinedEntries(owner, { showKeyring = true, columns = 12 })) do
            if e.cid == SWAP_CID and e.slot == SWAP_SLOT then cell = e.data and e.data.id or nil end
        end
    end
    return { stored = stored, cell = cell, trace = Capture.TraceRecords(), sim = S }
end

local function testProfileMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    for _, p in ipairs(PROFILES) do
        local r = runProfile(p, false)
        ck(r.stored == OHWEAPON, p.name ..
            ": the store holds the OFF-HAND WEAPON after the swap (got " ..
            tostring(r.stored) .. ", shield is " .. SHIELD .. ")")
        ck(r.cell == OHWEAPON, p.name ..
            ": the CELL MODEL for backpack slot 3 reads the weapon (got " .. tostring(r.cell) .. ")")
    end
end

-- A slot the client NEVER unlocks. The settle ladder must not turn that into a full bag
-- scan every 0.6s for the rest of the session — the pathological case sort.lua bounds with
-- LOCK_TTL and this one bounds with SETTLE_MAX_CHAIN.
local STUCK = {
    name = "stuck-slot", healsOn2_0_4 = false,
    steps = {
        { at = 0.00, fn = function(S)
            S:lock(SWAP_CID, SWAP_SLOT, true)
            S:fire("ITEM_LOCK_CHANGED", SWAP_CID, SWAP_SLOT)
            S:fire("BAG_UPDATE", SWAP_CID)
        end },
    },
}

local function testStuckSlotCeiling(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local r = runProfile(STUCK, false, 60.0)   -- a full minute of simulated time
    local ceiling = 2 + Capture.SETTLE_MAX_CHAIN * #Capture.SETTLE_LADDER
    ck(r.sim.scans <= ceiling, string.format(
        "a permanently locked slot costs at most %d scans, not one every 0.6s forever " ..
        "(got %d over 60 simulated seconds)", ceiling, r.sim.scans))
    ck(r.sim.scans >= 4, "…but it DID keep asking for a while (got " .. r.sim.scans .. ")")
end

local function testLegacyMutant(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local reproduced = {}
    for _, p in ipairs(PROFILES) do
        local r = runProfile(p, true)
        local healed = (r.stored == OHWEAPON)
        if not healed then reproduced[#reproduced + 1] = p.name end
        Capture._MUTANT_REPORT = (Capture._MUTANT_REPORT or "") ..
            (Capture._MUTANT_REPORT and " | " or "") .. p.name ..
            "=" .. (healed and "healed" or "STALE")
        ck(healed == p.healsOn2_0_4, string.format(
            "MUTANT (2.0.4 chain) %s: expected %s, got %s — if this flipped, either the " ..
            "profile changed or the fix leaked into the mutant",
            p.name, p.healsOn2_0_4 and "healed" or "STALE", healed and "healed" or "STALE"))
    end
    ck(#reproduced == 2, "exactly two profiles reproduce the owner's stale cell on the " ..
        "2.0.4 chain (got " .. #reproduced .. ": " .. table.concat(reproduced, ", ") .. ")")
end

local function testTraceRing(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ------------------------------------------------------------------ shape
    local rec, n = Capture.NewTraceRecord({ ts = 5, trigger = "PLAYER_EQUIPMENT_CHANGED" }), 0
    for _ in pairs(rec) do n = n + 1 end
    ck(n == #Capture.TRACE_FIELDS, string.format(
        "a record holds exactly the %d declared fields (got %d)", #Capture.TRACE_FIELDS, n))
    local junk = Capture.NewTraceRecord(nil)
    ck(junk.trigger == "" and junk.seq == "" and junk.paint == "idle",
        "absent strings default rather than reaching the file as nil")
    ck(junk.combat == false and junk.followUp == false, "absent booleans are false, never nil")
    ck(Capture.NewTraceRecord({ trigger = 42 }).trigger == "", "a non-string trigger is dropped")

    ------------------------------------------------------------------ additive SV
    local db = { showMoney = true }
    Capture.TraceAppend(db, { ts = 1 })
    local keys = {}
    for k in pairs(db) do keys[#keys + 1] = k end
    table.sort(keys)
    ck(#keys == 2 and keys[1] == "equipTrace" and keys[2] == "showMoney",
        "the trace writes exactly ONE new settings key, `equipTrace` (got: " ..
        table.concat(keys, ",") .. ")")
    ck(Capture.TraceBuffer({}, false) == nil, "no buffer is allocated for a plain read")

    ------------------------------------------------------------------ ring + read + clear
    local db2 = {}
    for i = 1, 8 do Capture.TraceAppend(db2, { ts = i }, 5) end
    ck(#db2.equipTrace == 5, "the buffer is capped (got " .. #db2.equipTrace .. " of 5)")
    ck(db2.equipTrace[1].ts == 4 and db2.equipTrace[5].ts == 8,
        "it is a RING: oldest-first, the first 3 dropped")
    Capture.TraceAppend(db2, { ts = 99 }, 2)
    ck(#db2.equipTrace == 2, "a lowered cap converges in one append")
    local recs = Capture.TraceRecords(db2)
    ck(#recs == 2 and recs[1].ts == 99, "TraceRecords hands back NEWEST first")
    ck(recs ~= db2.equipTrace, "…as a copy; the live SV table is never handed out")
    local live = db2.equipTrace
    ck(Capture.TraceClear(db2) == 2 and #db2.equipTrace == 0 and db2.equipTrace == live,
        "clear empties IN PLACE and reports the count")
    ck(Capture.TraceClear({}) == 0, "clearing an absent trace is a no-op, not an error")

    ------------------------------------------------------------------ build stamp + format
    ck(Capture.NewTraceRecord({}).version == tostring(ns.VERSION),
        "every record is stamped with the build that wrote it")
    local line = Capture.FormatTraceRecord(Capture.NewTraceRecord({ ts = 7, combat = true }))
    ck(line:find("ts=7", 1, true) and line:find("combat=yes", 1, true),
        "the printed line walks TRACE_FIELDS and renders booleans readably")

    ------------------------------------------------------------------ the owner's scenario
    local r = runProfile(PROFILES[1], false)
    ck(#r.trace > 0, "the owner's profile writes trace records")
    local sawSwap, sawCombat, sawLocked = false, false, false
    for _, t in ipairs(r.trace) do
        if t.changed > 0 and t.cid == SWAP_CID and t.slot == SWAP_SLOT
           and t.preID == SHIELD and t.postID == OHWEAPON then sawSwap = true end
        if t.combat then sawCombat = true end
        if t.lockedSlots > 0 then sawLocked = true end
    end
    ck(sawSwap, "one record states the swap in full: cid 0 slot 3, shield -> weapon")
    ck(sawCombat, "…and records that it happened in combat")
    ck(sawLocked, "…and that an earlier pass read the slot mid-flight (locked)")
    ck(r.trace[1].equipSlot == 17, "the paperdoll slot (17 = off hand) is carried through")
    ck(r.trace[1].seq:find("ILC", 1, true) ~= nil, "the observed signal sequence is recorded")
    ck(#r.trace <= 6, "the window is bounded — one equip cannot flood the ring (got " ..
        #r.trace .. ")")
end

-- The combat paint gate, pinned without a client.
local function testCombatPaintGate(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local I = ns.Items
    if not (I and I.LayoutSig) then fails[#fails + 1] = "ui_items did not publish LayoutSig"; return end

    local owner = { source = "full" }   -- IsLive keys off the self nameRealm; cached here
    local A = { { owner = owner, cid = 0, slot = 1, data = { id = SHIELD } },
                { owner = owner, cid = 0, slot = 2, data = nil } }
    local B = { { owner = owner, cid = 0, slot = 1, data = { id = OHWEAPON } },
                { owner = owner, cid = 0, slot = 2, data = nil } }
    ck(I.LayoutSig(A, 12, 37, 4) == I.LayoutSig(B, 12, 37, 4),
        "a DATA-ONLY change (shield -> weapon in the same cell) is the SAME structure")
    local C = { A[1] }
    ck(I.LayoutSig(A, 12, 37, 4) ~= I.LayoutSig(C, 12, 37, 4), "a cell count change is structural")
    ck(I.LayoutSig(A, 12, 37, 4) ~= I.LayoutSig(A, 11, 37, 4), "a column change is structural")
    local D = { { owner = owner, cid = 1, slot = 1, data = { id = SHIELD } }, A[2] }
    ck(I.LayoutSig(A, 12, 37, 4) ~= I.LayoutSig(D, 12, 37, 4), "a (cid, slot) change is structural")

    local sigA, sigC = I.LayoutSig(A, 12, 37, 4), I.LayoutSig(C, 12, 37, 4)
    ck(I.CombatLayoutMode(sigA, sigA, 2, 2) == "repaint",
        "same structure + enough buttons -> REPAINT in combat (this is the owner's case)")
    ck(I.CombatLayoutMode(nil, sigA, 2, 2) == "defer",
        "nothing drawn yet -> defer (there is nothing to repaint)")
    ck(I.CombatLayoutMode(sigA, sigC, 1, 1) == "defer", "a structural change still defers")
    ck(I.CombatLayoutMode(sigA, sigA, 1, 2) == "defer",
        "a missing button defers rather than silently skipping a cell")
    ck(type(I.LastPaintMode()) == "string", "the paint mode is published for the equip trace")

    ------------------------------------------------------------------------------------
    -- DRIVE IT. The rule above is a decision; this is the grid actually obeying it. A
    -- synthetic group with two already-built buttons takes the changed entries IN COMBAT
    -- and the cell that changed must end up holding the new item, with no frame op
    -- attempted on any button (a real one is a protected secure-template frame).
    ------------------------------------------------------------------------------------
    if not I._layoutGroup then fails[#fails + 1] = "ui_items did not export _layoutGroup"; return end
    local savedCombat, savedSelf = _G.InCombatLockdown, I._self
    local frameOps = {}
    local function stubButton()
        local b = { _live = true }
        b._dsRepaint = function(self) self._painted = (self._painted or 0) + 1 end
        for _, op in ipairs({ "Show", "Hide", "SetParent", "ClearAllPoints", "SetPoint",
                              "SetSize", "SetID" }) do
            b[op] = function() frameOps[#frameOps + 1] = op end
        end
        return b
    end
    local live = { source = "full", nameRealm = "Tester-TestRealm" }
    I.SetSelf("Tester-TestRealm")
    _G.InCombatLockdown = function() return true end

    local pre  = { { owner = live, cid = 0, slot = 3, data = { id = SHIELD } },
                   { owner = live, cid = 0, slot = 4, data = nil } }
    local post = { { owner = live, cid = 0, slot = 3, data = { id = OHWEAPON } },
                   { owner = live, cid = 0, slot = 4, data = nil } }
    local G = { _columns = 12, _size = 37, _gap = 4,
                _buttons = { stubButton(), stubButton() }, _holders = {} }
    G._sig = I.LayoutSig(pre, 12, 37, 4, nil)   -- premise: `pre` is what is on screen

    I._layoutGroup(G, post)
    ck(I.LastPaintMode() == "repaint", "an in-combat data-only change REPAINTS (got " ..
        tostring(I.LastPaintMode()) .. ")")
    ck(G._buttons[1]._data and G._buttons[1]._data.id == OHWEAPON,
        "…and the changed cell now holds the off-hand weapon, in combat")
    ck((G._buttons[1]._painted or 0) == 1 and (G._buttons[2]._painted or 0) == 1,
        "…every cell repainted exactly once")
    ck(#frameOps == 0, "…and NOT ONE frame op was attempted on a protected button (got: " ..
        table.concat(frameOps, ",") .. ")")
    ck(G._pendingEntries == nil, "…and nothing was left queued for PLAYER_REGEN_ENABLED")

    -- A STRUCTURAL change in combat must still defer — the half of the old gate that was
    -- always right, and the reason this is a narrowing and not a removal.
    local shorter = { post[1] }
    I._layoutGroup(G, shorter)
    ck(I.LastPaintMode() == "defer", "a structural change in combat still defers")
    ck(G._pendingEntries == shorter, "…queued for PLAYER_REGEN_ENABLED, as before")
    ck(#frameOps == 0, "…still touching no frame in combat")

    _G.InCombatLockdown, I._self, I._lastPaint = savedCombat, savedSelf, "idle"
end

-- The event roster. This is the regression guard for the actual defect: 2.0.4 was deaf to
-- all three of these, and a future refactor that drops one puts the bug straight back.
local function testEventRoster(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local want = { ITEM_LOCK_CHANGED = true, PLAYER_EQUIPMENT_CHANGED = true,
                   UNIT_INVENTORY_CHANGED = true }
    local got = {}
    for _, e in ipairs(Capture.EQUIP_EVENTS) do got[e] = true end
    for e in pairs(want) do ck(got[e], "capture must re-scan on " .. e .. " (it does not)") end
    for e in pairs(got) do ck(want[e], "unexpected equip event registered: " .. tostring(e)) end
    ck(#Capture.BAG_EVENTS == 5, "the 2.0.4 bag-event roster is unchanged (5 events)")

    -- A window only opens on an equipment-ish signal, so ordinary looting writes no trace.
    Capture._win = nil
    ck(Capture.NoteSignal("BAG_UPDATE") == nil, "BAG_UPDATE alone never opens an equip window")
    ck(Capture._win == nil, "…and leaves no window behind")
    local w = Capture.NoteSignal("PLAYER_EQUIPMENT_CHANGED", 17)
    ck(w ~= nil and w.equipSlot == 17, "PLAYER_EQUIPMENT_CHANGED opens one and keeps the slot")
    Capture.NoteSignal("BAG_UPDATE")
    ck(#w.seq == 2 and w.seq[2] == "BU", "…and bag events are then recorded INTO it, in order")
    for _ = 1, 40 do Capture.NoteSignal("BAG_UPDATE") end
    ck(#w.seq == Capture.SEQ_MAX, "the sequence is bounded at SEQ_MAX (got " .. #w.seq .. ")")
    Capture._win = nil
end

function Capture.RunEquipTests(verbose)
    Capture._MUTANT_REPORT = nil
    local suites = {
        { name = "event roster",           fn = testEventRoster },
        { name = "profile matrix",         fn = testProfileMatrix },
        { name = "2.0.4 mutation gate",    fn = testLegacyMutant },
        { name = "stuck-slot ceiling",     fn = testStuckSlotCeiling },
        { name = "combat paint gate",      fn = testCombatPaintGate },
        { name = "equip trace ring",       fn = testTraceRing },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS equip-refresh/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL equip-refresh/" .. suite.name .. " :: " .. f) end end
        end
    end
    if verbose and ns and ns.Print then
        -- The red-to-green record, printed every run: which client orders the 2.0.4 chain
        -- could not heal, and a sample of what the owner's /bags debug equiptrace looks like.
        if Capture._MUTANT_REPORT then
            ns:Print("  equip-refresh: 2.0.4 chain -> " .. Capture._MUTANT_REPORT)
        end
        local r = runProfile(PROFILES[1], false)
        local shown = r.trace[1]
        for _, t in ipairs(r.trace) do if t.changed > 0 then shown = t; break end end
        if shown then
            ns:Print("  equip-refresh: " .. #r.trace .. " record(s); the pass that saw the swap -> " ..
                     Capture.FormatTraceRecord(shown))
        end
    end
    -- Leave the globals as the rest of the run expects them.
    _G.DaseekiBags2Data, _G.DaseekiBags2DB = nil, nil
    Store.Init()
    return allPass
end

function Capture.RunSelfTests(verbose)
    local suites = {
        { name = "build slot",     fn = testBuildSlot },
        { name = "scan container", fn = testScanContainer },
        { name = "snapshot + bank gating", fn = testSnapshotBankGating },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS capture/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL capture/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("capture", Capture.RunSelfTests)
    ns:RegisterSelfTest("equip-refresh", Capture.RunEquipTests)
end

return Capture
