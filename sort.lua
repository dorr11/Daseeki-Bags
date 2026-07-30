-- Daseeki Bags 2.0 — sort.lua
-- The sort engine: a PURE, provably-terminating move planner plus a throttled,
-- taint-safe in-game executor. Split exactly like the rest of 2.0:
--
--   PURE core (no WoW API; exhaustively harness-tested):
--     Sort.MergePour(src, dst, max)        — one stack pour (the merge arithmetic)
--     Sort.CanonicalStacks(total, max)      — a total's merged shape (fulls + remainder)
--     Sort.CompareStacks(a, b)              — group order (1.x parity): set → class → subclass →
--                                              equip → quality → icon → ilvl → itemID → stackCount, all ↓
--     Sort.Plan(state)                      — current layout -> { target, moves, stats }
--     Sort.PartitionWaves(moves)            — ordered moves -> waves of slot-disjoint moves
--
--   EXECUTOR (in-game only; guarded on _G):
--     Sort.Run(cids, opts)                  — snapshot cids, plan, partition into waves,
--     issue a whole wave of slot-disjoint moves per tick and wait on ITEM_LOCK_CHANGED /
--     GetContainerItemInfo(isLocked) for the touched slots to settle before the next
--     wave (report §3(b): ~1-3s full-bag sort, vs the old one-move-per-BAG_UPDATE tick).
--     Abort-clean on combat / window close / bank close. Accepts an explicit container-id
--     SET so W3 reuses it for the bank. No native sort exists on 1.15.9 (see below).
--
-- ── Why the planner cannot infinite-loop ──────────────────────────────────────
-- Sorting runs in two bounded phases over a fixed set of free (unlocked) cells:
--   Phase I (merge)  pours partial stacks of each item into its canonical shape.
--                    Each pour strictly lowers Σ(stacks − canonicalStacks) ≥ 0 by one,
--                    so it halts in ≤ (freeStacks − canonicalStacks) merges. After it,
--                    the multiset of (itemID, count) equals the target multiset.
--   Phase II (swap)  is selection-sort over a permutation: cell i is filled with its
--                    target stack by one swap with a later cell and never touched again,
--                    so it halts in ≤ (freeCells − 1) swaps.
-- The move list is therefore FINITE and precomputed; the executor plays it back with a
-- strictly increasing index and aborts (never replans) on any drift — so nothing loops.
--
-- Catalog-verified (wow-api-catalog/1.15.9.68808): C_Container.GetContainerNumSlots,
-- GetContainerItemInfo (isLocked field), PickupContainerItem, SplitContainerItem,
-- GetContainerNumFreeSlots; C_Item.GetItemInfo / GetItemInfoInstant / GetItemFamily;
-- ClearCursor; InCombatLockdown; events ITEM_LOCK_CHANGED (Event.Container.ItemLockChanged),
-- PLAYER_REGEN_DISABLED, BANKFRAME_CLOSED. NO native sort exists: functions.txt has no
-- SortBags / SortBankBags / C_Container.Sort* on 1.15.9 (only auction/calendar sorts),
-- so the client planner IS the sort and the wave executor is the perf path (report §3b).

local ADDON, ns = ...

local Sort = {}
ns.Sort = Sort

local Store = ns.Store

local HUGE = 1e9

----------------------------------------------------------------------
-- PURE: stack arithmetic
----------------------------------------------------------------------

-- Pour as much of `src` into `dst` as `maxStack` allows. Returns the residual
-- src and the new dst. dst can only grow (up to max); src only shrinks.
function Sort.MergePour(src, dst, maxStack)
    maxStack = math.max(1, math.floor(maxStack or 1))
    src = math.max(0, src or 0)
    dst = math.max(0, dst or 0)
    local space = maxStack - dst
    if space <= 0 then return src, dst end
    local move = math.min(space, src)
    return src - move, dst + move
end

-- The merged ("stackables merged first") shape of a total: as many full stacks as
-- fit, then a single remainder. total 25 @ max 20 -> {20, 5}; 40 -> {20,20}; 5 -> {5}.
function Sort.CanonicalStacks(total, maxStack)
    total = math.max(0, math.floor(total or 0))
    maxStack = math.max(1, math.floor(maxStack or 1))
    local out = {}
    local fulls = math.floor(total / maxStack)
    for _ = 1, fulls do out[#out + 1] = maxStack end
    local rem = total - fulls * maxStack
    if rem > 0 then out[#out + 1] = rem end
    return out
end

----------------------------------------------------------------------
-- PURE: group ordering — 1.x PARITY.
--
-- This reproduces 1.x's `Sort.Rule` (core/api/sorting.lua): the owner's own fork
-- compares a FIXED chain of keys and, at the first key that differs, returns the
-- one with the GREATER value first — i.e. every key is DESCENDING. The chain:
--
--   set → class → subclass → equip → quality → iconFileID → level → itemID → stackCount   (all ↓)
--
--   set  — 1.x's super-key that splits the bag into three bands (1.x GetSpaces):
--            0 = Consumable/Container  (classID < Enum.ItemClass.Weapon(2))
--            1 = a piece of one of the player's saved equipment sets  (retail only;
--                1.x's BelongsToSet is a NO-OP on Classic Era 1.15.9, our target —
--                so on the live client `set` is binary 0/2, never 1)
--            2 = everything else (weapons, armor, gems, trade goods, quest, misc…)
--          DESC ⇒ band 2 (gear/goods) first, band 1 (set pieces) middle,
--                 band 0 (consumables/containers) LAST.
--   class/subclass — Enum.ItemClass / subclass, DESC (higher class id first).
--   equip          — equipLoc string ("" when not equippable), raw string DESC.
--   quality/level  — item quality and item level, DESC.
--   iconFileID     — groups identical-icon items together, DESC.
--   itemID/stackCount — final deterministic tiebreak, DESC (fuller stack first).
--
-- a, b = { id, count, meta = { set, classID, subClassID, equip, quality,
--          iconFileID, level, name, maxStack } }.  Missing-meta defaults mirror
-- 1.x GetSpaces (class→14, subclass→-1, equip→"", others→0).
--
-- NB: 1.x has NO `name` key and this comparator deliberately keeps it that way —
-- name is carried in meta only for search/UI, never consulted for sort order.
----------------------------------------------------------------------

function Sort.CompareStacks(a, b)
    local am, bm = a.meta or {}, b.meta or {}
    local aset, bset = am.set or 0, bm.set or 0
    if aset ~= bset then return aset > bset end          -- band: gear→set→consumables
    local ac, bc = am.classID or 14, bm.classID or 14
    if ac ~= bc then return ac > bc end                  -- class DESC
    local asc, bsc = am.subClassID or -1, bm.subClassID or -1
    if asc ~= bsc then return asc > bsc end              -- subclass DESC
    local ae, be = am.equip or "", bm.equip or ""
    if ae ~= be then return ae > be end                  -- equipLoc string DESC
    local aq, bq = am.quality or 0, bm.quality or 0
    if aq ~= bq then return aq > bq end                  -- quality DESC
    local ai, bi = am.iconFileID or 0, bm.iconFileID or 0
    if ai ~= bi then return ai > bi end                  -- icon DESC (groups same-icon)
    local al, bl = am.level or 0, bm.level or 0
    if al ~= bl then return al > bl end                  -- item level DESC
    if a.id ~= b.id then return (a.id or 0) > (b.id or 0) end   -- itemID DESC
    return (a.count or 0) > (b.count or 0)               -- fuller stacks first (canonical tail)
end

-- PURE: the reversed-grouping comparator (2.0's `descending` toggle — an ADDITIVE
-- 2.0 extra; 1.x itself has only the one order above). It flips the STRUCTURAL
-- grouping keys (set, class, subclass, equip, icon, level, itemID) so the bands
-- and categories appear in the opposite order, but keeps the within-item tail
-- IDENTICAL to the default — higher quality first, then fuller stack first. Keeping
-- that tail canonical is what makes descending a fixed point under re-planning (it
-- agrees with Phase I's "fill the earliest partial to full"), so re-sorting never
-- oscillates the full/partial stacks.
function Sort.CompareStacksDesc(a, b)
    local am, bm = a.meta or {}, b.meta or {}
    local aset, bset = am.set or 0, bm.set or 0
    if aset ~= bset then return aset < bset end          -- band order reversed
    local ac, bc = am.classID or 14, bm.classID or 14
    if ac ~= bc then return ac < bc end                  -- class ASC (reversed grouping)
    local asc, bsc = am.subClassID or -1, bm.subClassID or -1
    if asc ~= bsc then return asc < bsc end              -- subclass ASC
    local ae, be = am.equip or "", bm.equip or ""
    if ae ~= be then return ae < be end                  -- equipLoc string ASC
    local ai, bi = am.iconFileID or 0, bm.iconFileID or 0
    if ai ~= bi then return ai < bi end                  -- icon ASC
    local al, bl = am.level or 0, bm.level or 0
    if al ~= bl then return al < bl end                  -- item level ASC
    local aq, bq = am.quality or 0, bm.quality or 0
    if aq ~= bq then return aq > bq end                  -- quality: higher first (canonical tail kept)
    if a.id ~= b.id then return (a.id or 0) < (b.id or 0) end   -- itemID ASC (reversed grouping)
    return (a.count or 0) > (b.count or 0)               -- fuller stacks first (canonical tail kept)
end

----------------------------------------------------------------------
-- PURE: the planner
--
-- state = {
--   cells   = { { cid, slot, id|nil, count, quality, locked }, ... },  -- canonical order
--   meta    = function(id) -> { classID, subClassID, name, quality, maxStack } | nil,
--   canHold = function(cid, id) -> bool,   -- optional; default: everything fits
-- }
-- Returns { target = { [cellIndex] = { id, count } }, moves = { ... }, stats = {...} }.
-- Locked cells are fixed points: their items stay, and they are neither sources nor
-- destinations. Move ops:
--   { op = "merge", from = {cid,slot}, to = {cid,slot} }   -- pour same-item stacks
--   { op = "swap",  a = {cid,slot},    b = {cid,slot} }    -- exchange two cells
----------------------------------------------------------------------

function Sort.Plan(state)
    state = state or {}
    local cells   = state.cells or {}
    local meta    = state.meta or function() return nil end
    local canHold = state.canHold or function() return true end

    local moves = {}

    -- free (unlocked) cell indices in canonical order
    local free = {}
    for i, c in ipairs(cells) do
        if not c.locked then free[#free + 1] = i end
    end

    -- working simulation of free-cell contents
    local sim = {}   -- [cellIndex] = { id|nil, count }
    for _, i in ipairs(free) do
        local c = cells[i]
        sim[i] = c.id and { id = c.id, count = c.count or 1 } or { id = nil, count = 0 }
    end

    local function ref(i) return { cid = cells[i].cid, slot = cells[i].slot } end
    local function metaOf(id) return meta(id) end
    local function maxStackOf(id) local m = metaOf(id); return (m and m.maxStack) or 1 end

    -- per-id totals across free cells (deterministic id order)
    local totals, idOrder = {}, {}
    for _, i in ipairs(free) do
        local s = sim[i]
        if s.id then
            if totals[s.id] == nil then idOrder[#idOrder + 1] = s.id; totals[s.id] = 0 end
            totals[s.id] = totals[s.id] + s.count
        end
    end
    table.sort(idOrder)

    ---------------------------------------------------------------
    -- PHASE I — merge each id's partial stacks into the canonical shape
    ---------------------------------------------------------------
    for _, id in ipairs(idOrder) do
        local max = maxStackOf(id)
        if max > 1 then   -- non-stackables (max 1) can never merge
            local acc = nil   -- the current open (non-full, id-bearing) accumulator cell
            for _, i in ipairs(free) do
                if sim[i].id == id and sim[i].count > 0 then
                    if acc == nil then
                        acc = i
                    else
                        local ns2, nd2 = Sort.MergePour(sim[i].count, sim[acc].count, max)
                        if nd2 > sim[acc].count then
                            moves[#moves + 1] = { op = "merge", from = ref(i), to = ref(acc) }
                            sim[i].count, sim[acc].count = ns2, nd2
                            if ns2 == 0 then sim[i].id = nil end
                        end
                        if sim[acc].count >= max then
                            acc = (sim[i].count > 0) and i or nil
                        end
                    end
                end
            end
        end
    end

    ---------------------------------------------------------------
    -- Build the sorted target stacks, then assign them to free cells
    -- (family-aware: most-constrained stacks placed first so a general
    --  item is never starved out of the only bag that can hold it).
    ---------------------------------------------------------------
    local targetStacks = {}
    for _, id in ipairs(idOrder) do
        local counts = Sort.CanonicalStacks(totals[id], maxStackOf(id))
        local m = metaOf(id)
        for _, cnt in ipairs(counts) do
            targetStacks[#targetStacks + 1] = { id = id, count = cnt, meta = m }
        end
    end
    -- Direction toggle: the DEFAULT is 1.x's canonical order (Sort.CompareStacks — the
    -- set→class→subclass→equip→quality→icon→level→id→stack chain, all ↓); descending
    -- REVERSES THE GROUPING (band/class/subclass/equip/icon/level/id) but deliberately KEEPS
    -- the within-item canonical tail — fuller stack first, higher quality first — so descending
    -- still agrees with Phase I (which always fills the earliest partial to full). That keeps
    -- descending a fixed point: re-sorting a desc-sorted bag yields zero moves (no stack
    -- oscillation), matching the determinism the default order already has. Only the group order flips.
    local cmp = state.descending and Sort.CompareStacksDesc or Sort.CompareStacks
    table.sort(targetStacks, cmp)   -- display order (1.x default, reversed grouping when descending)

    -- fit count per stack + constrained-first assignment order
    local fit, order = {}, {}
    for idx, st in ipairs(targetStacks) do
        local c = 0
        for _, i in ipairs(free) do if canHold(cells[i].cid, st.id) then c = c + 1 end end
        fit[idx] = c
        order[idx] = idx
    end
    table.sort(order, function(x, y)
        if fit[x] ~= fit[y] then return fit[x] < fit[y] end
        return x < y   -- targetStacks is already in display order
    end)

    local usedCell, stackAtCell = {}, {}
    for _, idx in ipairs(order) do
        local st = targetStacks[idx]
        for _, i in ipairs(free) do
            if not usedCell[i] and canHold(cells[i].cid, st.id) then
                usedCell[i], stackAtCell[i] = true, st
                break
            end
        end
    end

    local target = {}
    for _, i in ipairs(free) do
        local st = stackAtCell[i]
        target[i] = st and { id = st.id, count = st.count } or { id = nil, count = 0 }
    end

    ---------------------------------------------------------------
    -- PHASE II — selection-sort the (now canonical) stacks into target cells
    ---------------------------------------------------------------
    local function eq(a, b) return a.id == b.id and a.count == b.count end
    local swaps = 0
    for a = 1, #free do
        local i = free[a]
        if not eq(sim[i], target[i]) then
            local foundPos
            for b = a + 1, #free do
                if eq(sim[free[b]], target[i]) then foundPos = b; break end
            end
            if foundPos then
                local j = free[foundPos]
                moves[#moves + 1] = { op = "swap", a = ref(i), b = ref(j) }
                sim[i], sim[j] = sim[j], sim[i]
                swaps = swaps + 1
            end
            -- no match (only reachable under a pathological family constraint):
            -- leave the cell as-is rather than emit an illegal move.
        end
    end

    local merges = #moves - swaps
    return {
        target = target,
        moves  = moves,
        stats  = { merges = merges, swaps = swaps, moves = #moves,
                   stacks = #targetStacks, free = #free },
    }
end

----------------------------------------------------------------------
-- PURE: wave batching (the fast executor's schedule)
--
-- The planner emits an ORDERED move list whose correctness depends on order (Phase I
-- merges, then a selection-sort in Phase II). Playing it back one-move-per-tick with a
-- BAG_UPDATE wait is correct but slow (~0.15s × 100 moves = 15-30s). PartitionWaves
-- groups the SAME ordered list into WAVES of mutually slot-disjoint moves so a whole
-- wave can be issued in one tick without waiting between its moves:
--   * Greedy sequential: walk the moves in order; a move joins the current wave iff
--     none of its slots (source + dest) is already claimed by a move in that wave,
--     else it opens a new wave.
--   * This preserves the planner's order ACROSS waves — a move that conflicts with an
--     earlier one always lands in a LATER wave, so it still runs after it.
--   * Every move WITHIN a wave touches a disjoint slot set, so the moves commute and
--     issuing them together (no inter-move wait) yields the same result as in order.
-- Flattening the waves back therefore reproduces the original move sequence exactly.
----------------------------------------------------------------------

-- The container slots a single move touches (source + destination).
function Sort.MoveSlots(m)
    if m.op == "swap" then return { m.a, m.b } end
    if m.op == "merge" or m.op == "split" then return { m.from, m.to } end
    return {}
end

function Sort.PartitionWaves(moves)
    local waves = {}
    local cur, claimed
    local function key(ref) return ref.cid .. ":" .. ref.slot end
    local function newWave()
        cur = { moves = {}, slots = {} }
        claimed = {}
        waves[#waves + 1] = cur
    end
    for _, m in ipairs(moves or {}) do
        local slots = Sort.MoveSlots(m)
        local conflict = false
        if cur then
            for _, ref in ipairs(slots) do
                if claimed[key(ref)] then conflict = true; break end
            end
        end
        if not cur or conflict then newWave() end
        cur.moves[#cur.moves + 1] = m
        for _, ref in ipairs(slots) do
            claimed[key(ref)] = true
            cur.slots[#cur.slots + 1] = ref
        end
    end
    return waves
end

----------------------------------------------------------------------
-- Container-id set helpers
----------------------------------------------------------------------

-- The carried inventory set the W4 sort button drives: backpack + carried bags,
-- keyring excluded (it is not a sortable general container). W3 passes its own set
-- (bank + bank bags) to the SAME engine — that's the whole point of the id-set arg.
function Sort.CarriedBagIDs()
    local ids = { Store.BACKPACK_CONTAINER }
    for cid = 1, Store.NumBagSlots() do ids[#ids + 1] = cid end
    return ids
end

-- =====================================================================
-- EXECUTOR (in-game only) — WAVE-BATCHED, lock-verified, abort-clean.
--
-- Catalog verdict (wow-api-catalog/1.15.9.68808): Classic Era 1.15.9 has NO native
-- container sort — there is no C_Container.SortBags / SortBags / SortBankBags (grep of
-- functions.txt finds only auction/calendar sorts). So the client-side planner remains
-- the sort, and this executor is the perf path (report §3(b)): issue a whole wave of
-- slot-disjoint moves per tick (Sort.PartitionWaves), then wait on ITEM_LOCK_CHANGED /
-- GetContainerItemInfo(isLocked) for the touched slots to settle before the next wave —
-- instead of one move per BAG_UPDATE tick. Target: a full-bag sort in ~1-3s.
--
-- Not headless-tested (no WoW API under the harness); exercised by Drew's live pass.
-- The planner AND the wave partition it plays back ARE exhaustively tested above.
-- =====================================================================

Sort.WAVE_THROTTLE    = 0.05   -- seconds between waves (~one frame; perf + taint-quiet)
Sort.MAX_SETTLE_POLLS = 40     -- safety valve: force-advance a wave after 40×throttle (~2s)

local function inCombat()
    return _G.InCombatLockdown and _G.InCombatLockdown()
end

-- Bank open? Only permit bank containers when the bank UI is actually open.
local function bankIsOpen()
    local bf = _G.BankFrame
    return bf and bf.IsShown and bf:IsShown() and true or false
end

-- Live meta lookup (cached per Run) — populates the full 1.x parity key set.
-- classID/subClassID/equipLoc/icon resolve synchronously from GetItemInfoInstant;
-- name/quality/itemLevel/maxStack come from GetItemInfo (may be uncached on a cold
-- item — falls back to 1.x's GetSpaces defaults so the sort still runs deterministically).
-- `set` is 1.x's band super-key computed from classID: Consumable/Container (class < 2)
-- => 0 (sorts to the bottom), everything else => 2. 1.x's middle band (1 = player
-- equipment-set piece) comes from BelongsToSet, which is a NO-OP on Classic Era 1.15.9
-- (our target), so the live client only ever produces 0/2 — matching 1.x exactly there.
local WEAPON_CLASS = (_G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Weapon) or 2
local function makeMetaFn(cache)
    return function(id)
        if not id then return nil end
        local m = cache[id]
        if m then return m end
        m = { set = 2, classID = 14, subClassID = -1, equip = "", quality = 0,
              iconFileID = 0, level = 0, name = "", maxStack = 1 }
        local CI = _G.C_Item or {}
        local instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant
        local info    = CI.GetItemInfo        or _G.GetItemInfo
        if instant then
            local _, _, _, itemEquipLoc, icon, classID, subClassID = instant(id)
            if classID then m.classID = classID end
            if subClassID then m.subClassID = subClassID end
            if itemEquipLoc then m.equip = itemEquipLoc end   -- "" when not equippable
            if icon then m.iconFileID = icon end
        end
        if info then
            local name, _, quality, itemLevel, _, _, _, stackCount = info(id)
            if name then m.name = name:lower() end
            if quality then m.quality = quality end
            if itemLevel then m.level = itemLevel end
            if stackCount and stackCount > 0 then m.maxStack = stackCount end
        end
        -- 1.x band: Consumable(0)/Container(1) drop to band 0; the rest stay band 2.
        m.set = (m.classID < WEAPON_CLASS) and 0 or 2
        cache[id] = m
        return m
    end
end

-- Family-aware canHold: general bags (family 0) hold anything; a specialized bag
-- holds an item only when their family bits overlap. Missing APIs => permissive.
local function makeCanHoldFn(cache)
    return function(cid, id)
        if cid == Store.BACKPACK_CONTAINER or cid == Store.BANK_CONTAINER then return true end
        local CC, CI, band = _G.C_Container, _G.C_Item, (_G.bit and _G.bit.band)
        if not (CC and CC.GetContainerNumFreeSlots and CI and CI.GetItemFamily and band) then
            return true
        end
        local bagFamily = cache["_bag" .. cid]
        if bagFamily == nil then
            local _, fam = CC.GetContainerNumFreeSlots(cid)
            bagFamily = fam or 0
            cache["_bag" .. cid] = bagFamily
        end
        if bagFamily == 0 then return true end
        local itemFamily = CI.GetItemFamily(id) or 0
        return band(bagFamily, itemFamily) ~= 0
    end
end

-- Snapshot the given container ids into the planner's cell model (canonical order).
local function snapshot(cids)
    local CC = _G.C_Container
    if not (CC and CC.GetContainerNumSlots and CC.GetContainerItemInfo) then return nil end
    -- rank cids for a stable canonical order (backpack, bags, bank, bank bags)
    local rank = (ns.Items and ns.Items.ContainerRank) or function(c) return c end
    local ordered = {}
    for _, c in ipairs(cids) do ordered[#ordered + 1] = c end
    table.sort(ordered, function(x, y)
        local rx, ry = rank(x), rank(y)
        if rx == ry then return x < y end
        return rx < ry
    end)
    local cells = {}
    for _, cid in ipairs(ordered) do
        local n = CC.GetContainerNumSlots(cid) or 0
        for slot = 1, n do
            local info = CC.GetContainerItemInfo(cid, slot)
            if info and info.itemID then
                cells[#cells + 1] = { cid = cid, slot = slot, id = info.itemID,
                    count = info.stackCount or 1, quality = info.quality,
                    locked = info.isLocked and true or false }
            else
                cells[#cells + 1] = { cid = cid, slot = slot, id = nil, count = 0 }
            end
        end
    end
    return cells
end

-- Perform one planned move via the container pickup/split primitives.
local function performMove(m)
    local CC = _G.C_Container
    if not CC then return end
    if m.op == "swap" then
        CC.PickupContainerItem(m.a.cid, m.a.slot)
        CC.PickupContainerItem(m.b.cid, m.b.slot)
    elseif m.op == "merge" then
        CC.PickupContainerItem(m.from.cid, m.from.slot)
        CC.PickupContainerItem(m.to.cid, m.to.slot)
        -- Same-item merge fills `to` to max and leaves any overflow on the cursor;
        -- drop it back into `from` so the residual matches MergePour's model.
        if _G.CursorHasItem and _G.CursorHasItem() then
            CC.PickupContainerItem(m.from.cid, m.from.slot)
        end
    elseif m.op == "split" then
        if CC.SplitContainerItem then CC.SplitContainerItem(m.from.cid, m.from.slot, m.amount) end
        CC.PickupContainerItem(m.to.cid, m.to.slot)
    end
    if _G.ClearCursor then _G.ClearCursor() end   -- belt-and-suspenders: never leave a held item
end

local function stopDriver()
    Sort._running = false
    Sort._waiting = false
    Sort._waves, Sort._w, Sort._gen, Sort._settlePolls, Sort._moveCount = nil, nil, nil, nil, nil
    if Sort._driver then Sort._driver:UnregisterAllEvents() end
    if _G.ClearCursor then _G.ClearCursor() end
end

local function abort(reason)
    if not Sort._running then return end
    if ns.Print then ns:Print("sort stopped: " .. tostring(reason)) end
    stopDriver()
end

-- Is a specific container slot still locked (mid-move, server not yet confirmed)?
local function slotLocked(cid, slot)
    local CC = _G.C_Container
    if CC and CC.GetContainerItemInfo then
        local info = CC.GetContainerItemInfo(cid, slot)
        return info and info.isLocked and true or false
    end
    return false
end

-- Has every slot a wave touched settled (unlocked)? A no-op wave settles immediately.
local function waveSettled(wave)
    if not wave then return true end
    for _, ref in ipairs(wave.slots) do
        if slotLocked(ref.cid, ref.slot) then return false end
    end
    return true
end

-- Advance to the next wave (or finish). Bumps the generation so any in-flight settle
-- poll for the wave just finished no-ops, and clears the waiting flag so a stray
-- ITEM_LOCK_CHANGED can't double-advance.
local function advanceWave()
    if not Sort._running or not Sort._waiting then return end
    Sort._waiting = false
    Sort._gen = (Sort._gen or 0) + 1
    Sort._w = Sort._w + 1
    if Sort._w > #Sort._waves then
        if ns.Print then ns:Print("sort complete (" .. (Sort._moveCount or 0) .. " moves in " .. #Sort._waves .. " waves).") end
        stopDriver()
        if ns.Frame and ns.Frame.RequestRefresh then ns.Frame.RequestRefresh() end
        return
    end
    local after = _G.C_Timer and _G.C_Timer.After
    if after then after(Sort.WAVE_THROTTLE, Sort._stepWave) else Sort._stepWave() end
end

-- Wait for the current wave's slots to unlock, then advance. Driven by a bounded
-- poll (the safety valve) AND fast-pathed by ITEM_LOCK_CHANGED in the driver.
local function pollSettle(gen)
    if not Sort._running or not Sort._waiting or gen ~= Sort._gen then return end
    if waveSettled(Sort._waves[Sort._w]) then return advanceWave() end
    Sort._settlePolls = (Sort._settlePolls or 0) + 1
    if Sort._settlePolls > Sort.MAX_SETTLE_POLLS then return advanceWave() end   -- don't hang
    local after = _G.C_Timer and _G.C_Timer.After
    if after then after(Sort.WAVE_THROTTLE, function() pollSettle(gen) end) else advanceWave() end
end

-- Issue one whole wave of slot-disjoint moves, then wait for it to settle.
function Sort._stepWave()
    if not Sort._running then return end
    if inCombat() then return abort("entered combat") end
    if Sort._needsBank and not bankIsOpen() then return abort("bank closed") end
    if ns.Frame and ns.Frame.IsShown and not ns.Frame.IsShown() and not Sort._needsBank then
        return abort("window closed")
    end
    local wave = Sort._waves[Sort._w]
    for _, m in ipairs(wave.moves) do
        if ns.SafeCall then ns:SafeCall(performMove, m) else performMove(m) end
    end
    Sort._gen = (Sort._gen or 0) + 1
    Sort._settlePolls = 0
    Sort._waiting = true
    pollSettle(Sort._gen)
end

local function ensureDriver()
    if Sort._driver or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then abort("entered combat"); return end
        if event == "BANKFRAME_CLOSED" and Sort._needsBank then abort("bank closed"); return end
        if event == "ITEM_LOCK_CHANGED" then
            -- Fast path: the moment the current wave's slots are all unlocked, advance
            -- (the poll remains as the bounded fallback). advanceWave() clears _waiting
            -- so a burst of lock events can't skip a wave.
            if Sort._running and Sort._waiting and Sort._waves and waveSettled(Sort._waves[Sort._w]) then
                advanceWave()
            end
        end
    end)
    Sort._driver = f
end

-- Public entry: sort the given container-id set.
--   opts.needsBank  — set true when cids include bank containers (W3); the executor
--                     then also aborts on BANKFRAME_CLOSED and refuses if not at bank.
function Sort.Run(cids, opts)
    opts = opts or {}
    if not _G.C_Container then return false end
    if Sort._running then if ns.Print then ns:Print("a sort is already running.") end; return false end
    if inCombat() then if ns.Print then ns:Print("cannot sort in combat.") end; return false end

    local needsBank = opts.needsBank
    if not needsBank then
        for _, cid in ipairs(cids) do if Store.IsBankContainer(cid) then needsBank = true; break end end
    end
    if needsBank and not bankIsOpen() then
        if ns.Print then ns:Print("open the bank to sort bank containers.") end
        return false
    end

    local cells = snapshot(cids)
    if not cells then return false end

    local cache = {}
    -- Sort direction: opts.descending overrides; else the persisted db.sortDescending
    -- (absent/false => ascending, the canonical order).
    local descending = opts.descending
    if descending == nil then
        local db = Store and Store.db
        descending = (db and db.sortDescending) and true or false
    end
    local plan = Sort.Plan({
        cells = cells,
        meta = makeMetaFn(cache),
        canHold = makeCanHoldFn(cache),
        descending = descending,
    })
    if #plan.moves == 0 then
        if ns.Print then ns:Print("bags already sorted.") end
        return true
    end

    ensureDriver()
    Sort._running    = true
    Sort._waves      = Sort.PartitionWaves(plan.moves)
    Sort._w          = 1
    Sort._gen        = 0
    Sort._waiting    = false
    Sort._moveCount  = #plan.moves
    Sort._needsBank  = needsBank
    Sort._driver:RegisterEvent("ITEM_LOCK_CHANGED")
    Sort._driver:RegisterEvent("PLAYER_REGEN_DISABLED")
    if needsBank then Sort._driver:RegisterEvent("BANKFRAME_CLOSED") end
    Sort._stepWave()
    return true
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "sort")
----------------------------------------------------------------------

-- Apply a planned move list to a mutable cell model (mirrors the executor's effect
-- on real bags) so a test can prove the plan REACHES the target and is legal.
local function applyMoves(cells, moves, maxOf)
    local byRef = {}
    for _, c in ipairs(cells) do byRef[c.cid .. ":" .. c.slot] = c end
    for _, m in ipairs(moves) do
        if m.op == "swap" then
            local a = byRef[m.a.cid .. ":" .. m.a.slot]
            local b = byRef[m.b.cid .. ":" .. m.b.slot]
            a.id, b.id = b.id, a.id
            a.count, b.count = b.count, a.count
        elseif m.op == "merge" then
            local from = byRef[m.from.cid .. ":" .. m.from.slot]
            local to   = byRef[m.to.cid .. ":" .. m.to.slot]
            local ns2, nd2 = Sort.MergePour(from.count, to.count, maxOf(to.id or from.id))
            to.count, from.count = nd2, ns2
            if ns2 == 0 then from.id = nil end
        end
    end
end

local function nonEmptyCounts(cells)
    local list = {}
    for _, c in ipairs(cells) do if c.id then list[#list + 1] = { id = c.id, count = c.count } end end
    return list
end

local function testMergePour(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local s, d = Sort.MergePour(12, 13, 20); ck(s == 5 and d == 20, "12->13 @20 = 5,20")
    s, d = Sort.MergePour(8, 8, 20);         ck(s == 0 and d == 16, "8->8 @20 = 0,16")
    s, d = Sort.MergePour(5, 20, 20);        ck(s == 5 and d == 20, "no room -> unchanged src")
    s, d = Sort.MergePour(1, 1, 1);          ck(s == 1 and d == 1, "non-stackable never merges")
    s, d = Sort.MergePour(20, 0, 20);        ck(s == 0 and d == 20, "fill an empty accumulator")
    -- exhaustive: conservation + bounds for every (src,dst,max) in a grid
    for max = 1, 6 do
        for src = 0, max do
            for dst = 0, max do
                local ns2, nd2 = Sort.MergePour(src, dst, max)
                ck(ns2 + nd2 == src + dst, "conserves total ("..src..","..dst..",@"..max..")")
                ck(nd2 <= max and nd2 >= dst and ns2 >= 0, "dst within [dst,max], src>=0")
            end
        end
    end
end

local function testCanonicalStacks(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function eqarr(a, b) if #a ~= #b then return false end for i = 1, #a do if a[i] ~= b[i] then return false end end return true end
    ck(eqarr(Sort.CanonicalStacks(25, 20), { 20, 5 }), "25@20 -> {20,5}")
    ck(eqarr(Sort.CanonicalStacks(40, 20), { 20, 20 }), "40@20 -> {20,20}")
    ck(eqarr(Sort.CanonicalStacks(5, 20),  { 5 }), "5@20 -> {5}")
    ck(eqarr(Sort.CanonicalStacks(60, 20), { 20, 20, 20 }), "60@20 -> three fulls")
    ck(eqarr(Sort.CanonicalStacks(3, 1),   { 1, 1, 1 }), "non-stackable -> unit stacks")
    ck(eqarr(Sort.CanonicalStacks(0, 20),  {}), "0 -> no stacks")
end

-- meta catalog for the plan tests — carries the full 1.x parity key set.
-- 1.x band `set`: Consumable(class 0)/Container(1) => 0 (sort LAST); all else => 2 (sort FIRST).
local META = {
    -- id  = set, class, subclass, equip,                  quality, icon, level, name,     maxStack
    [100] = { set = 0, classID = 0,  subClassID = 0, equip = "",                     quality = 1, iconFileID = 1001, level = 1,  name = "apple",  maxStack = 20 }, -- consumable
    [101] = { set = 0, classID = 0,  subClassID = 0, equip = "",                     quality = 1, iconFileID = 1002, level = 1,  name = "bread",  maxStack = 20 }, -- consumable
    [200] = { set = 2, classID = 2,  subClassID = 7, equip = "INVTYPE_WEAPONMAINHAND", quality = 3, iconFileID = 2001, level = 60, name = "sword",  maxStack = 1  }, -- weapon
    [201] = { set = 2, classID = 4,  subClassID = 1, equip = "INVTYPE_CLOAK",         quality = 2, iconFileID = 2002, level = 55, name = "cloak",  maxStack = 1  }, -- armor
    [300] = { set = 2, classID = 7,  subClassID = 5, equip = "",                     quality = 1, iconFileID = 3001, level = 0,  name = "cloth",  maxStack = 10 }, -- tradegood
    [400] = { set = 2, classID = 9,  subClassID = 0, equip = "",                     quality = 1, iconFileID = 4001, level = 0,  name = "recipe", maxStack = 1  }, -- recipe
    [500] = { set = 2, classID = 12, subClassID = 0, equip = "",                     quality = 1, iconFileID = 5001, level = 0,  name = "quest",  maxStack = 1  }, -- quest item
}
local function metaFn(id) return META[id] end
local function maxOf(id) local m = META[id]; return (m and m.maxStack) or 1 end

local function bagCells(cid, slots, contents)
    -- contents = { [slot] = { id, count, locked } }
    local cells = {}
    for slot = 1, slots do
        local e = contents[slot]
        if e then cells[#cells + 1] = { cid = cid, slot = slot, id = e.id, count = e.count or 1, locked = e.locked }
        else cells[#cells + 1] = { cid = cid, slot = slot, id = nil, count = 0 } end
    end
    return cells
end

local function testPlanMergeAndSort(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- A messy backpack: scattered partial stacks + mixed item classes.
    local cells = bagCells(0, 8, {
        [1] = { id = 200 },              -- sword (weapon)
        [2] = { id = 100, count = 13 },  -- apple partial
        [3] = { id = 300, count = 4 },   -- cloth partial
        [4] = { id = 100, count = 12 },  -- apple partial (13+12=25 -> {20,5})
        [5] = { id = 201 },              -- cloak (armor)
        [6] = { id = 300, count = 8 },   -- cloth partial (4+8=12 -> {10,2})
        [7] = { id = 101, count = 5 },   -- bread
    })
    local plan = Sort.Plan({ cells = cells, meta = metaFn })
    ck(#plan.moves > 0, "messy bag needs moves")
    ck(plan.stats.moves <= plan.stats.free, "move count bounded by free-cell count")

    -- Apply the plan to a copy and verify it REACHES the target exactly.
    local copy = bagCells(0, 8, {
        [1] = { id = 200 }, [2] = { id = 100, count = 13 }, [3] = { id = 300, count = 4 },
        [4] = { id = 100, count = 12 }, [5] = { id = 201 }, [6] = { id = 300, count = 8 },
        [7] = { id = 101, count = 5 },
    })
    applyMoves(copy, plan.moves, maxOf)
    for i = 1, #copy do
        local want = plan.target[i]
        ck(copy[i].id == want.id, "cell " .. i .. " id matches target (" .. tostring(copy[i].id) .. " vs " .. tostring(want.id) .. ")")
        local haveCount = copy[i].id and copy[i].count or 0
        ck(haveCount == (want.count or 0), "cell " .. i .. " count matches target")
    end

    -- The realized order is canonically sorted (class → subclass → name → quality↓).
    local seq = {}
    for i = 1, #copy do if copy[i].id then seq[#seq + 1] = copy[i] end end
    local sortedOK = true
    for i = 2, #seq do
        local a = { id = seq[i-1].id, count = seq[i-1].count, meta = META[seq[i-1].id] }
        local b = { id = seq[i].id,   count = seq[i].count,   meta = META[seq[i].id] }
        if Sort.CompareStacks(b, a) then sortedOK = false end   -- b should not precede a
    end
    ck(sortedOK, "realized layout is in canonical group order")

    -- 1.x PARITY: the exact realized id sequence. Gear band first by class↓
    -- (cloth c7 → cloak c4 → sword c2), then the consumable band (bread → apple),
    -- with each stackable in {full, remainder} order (cloth {10,2}, apple {20,5}).
    local ids = {}
    for _, c in ipairs(seq) do ids[#ids + 1] = c.id end
    local want1x = { 300, 300, 201, 200, 101, 100, 100 }
    local orderOK = (#ids == #want1x)
    for i = 1, #want1x do if ids[i] ~= want1x[i] then orderOK = false end end
    ck(orderOK, "realized id order matches 1.x (gear by class↓, consumables last)")

    -- Apples merged to canonical {20,5}; cloth to {10,2}. Count them in the result.
    local appleStacks, clothStacks = {}, {}
    for _, c in ipairs(seq) do
        if c.id == 100 then appleStacks[#appleStacks + 1] = c.count end
        if c.id == 300 then clothStacks[#clothStacks + 1] = c.count end
    end
    table.sort(appleStacks, function(a, b) return a > b end)
    table.sort(clothStacks, function(a, b) return a > b end)
    ck(appleStacks[1] == 20 and appleStacks[2] == 5, "apples merged to {20,5}")
    ck(clothStacks[1] == 10 and clothStacks[2] == 2, "cloth merged to {10,2}")
end

local function testPlanIdempotentAndLocked(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Already-sorted bag (in 1.x order: gear band first by class↓, consumables band
    -- last): re-planning yields zero moves (idempotent / determinism).
    --   201 cloak(class4) → 200 sword(class2) → 101 bread → 100 apple{20,5}
    local cells = bagCells(0, 6, {
        [1] = { id = 201 }, [2] = { id = 200 },
        [3] = { id = 101, count = 5 }, [4] = { id = 100, count = 20 }, [5] = { id = 100, count = 5 },
    })
    local plan = Sort.Plan({ cells = cells, meta = metaFn })
    ck(#plan.moves == 0, "already-sorted bag -> no moves (idempotent)")

    -- Locked slot is a fixed point: its item is never a move source or destination.
    local locked = bagCells(0, 6, {
        [1] = { id = 200 },                      -- weapon (sorts to the front in 1.x order)
        [2] = { id = 100, count = 5, locked = true },  -- LOCKED apple stays put
        [3] = { id = 101, count = 5 },
    })
    local lp = Sort.Plan({ cells = locked, meta = metaFn })
    for _, m in ipairs(lp.moves) do
        local touchesLocked =
            (m.op == "swap" and ((m.a.slot == 2) or (m.b.slot == 2)))
            or (m.op == "merge" and ((m.from.slot == 2) or (m.to.slot == 2)))
        ck(not touchesLocked, "no move touches the locked slot 2")
    end
    -- The locked apple is absent from the target map (slot 2 not a free cell).
    ck(lp.target[2] == nil, "locked cell not a placement target")
end

local function testPlanFamilyAndMultiBag(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Two containers: general backpack (0) + a "soul bag" (1) that only holds id 200.
    local cells = {}
    for _, c in ipairs(bagCells(0, 4, { [1] = { id = 300, count = 6 }, [2] = { id = 200 } })) do cells[#cells+1]=c end
    for _, c in ipairs(bagCells(1, 2, { [1] = { id = 200 } })) do cells[#cells+1]=c end
    local function canHold(cid, id)
        if cid == 1 then return id == 200 end   -- soul bag: only "swords"
        return true
    end
    local plan = Sort.Plan({ cells = cells, meta = metaFn, canHold = canHold })
    -- Apply + verify: no id 300 ever lands in the restricted bag (cid 1).
    local copy = {}
    for _, c in ipairs(bagCells(0, 4, { [1] = { id = 300, count = 6 }, [2] = { id = 200 } })) do copy[#copy+1]=c end
    for _, c in ipairs(bagCells(1, 2, { [1] = { id = 200 } })) do copy[#copy+1]=c end
    applyMoves(copy, plan.moves, maxOf)
    for _, c in ipairs(copy) do
        if c.cid == 1 and c.id then ck(c.id == 200, "restricted bag holds only allowed item") end
    end
    -- multiset conservation: same items after sorting
    local before = { [200] = 0, [300] = 0 }
    before[200] = 2; before[300] = 6
    local after = { [200] = 0, [300] = 0 }
    for _, c in ipairs(copy) do if c.id then after[c.id] = (after[c.id] or 0) + c.count end end
    ck(after[200] == before[200] and after[300] == before[300], "item totals conserved across the sort")
end

-- 1.x PARITY (the headline of this change): a realistic mixed bag must land in the
-- EXACT order 1.x produced — the `set` band splits consumables to the bottom, and the
-- gear/goods band is ordered by class DESCENDING (quest → recipe → tradegood → armor →
-- weapon), the reverse of old-2.0's ascending-by-class. This is the assertion the owner
-- cares about ("consumables/trade/gear grouped the way 1.x grouped them").
local function testPlan1xOrder(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- A deliberately shuffled mixed bag spanning five item classes + a consumable pair.
    local seed = {
        [1] = { id = 100, count = 5 },  -- apple    (consumable, class 0, band 0)
        [2] = { id = 500 },             -- quest    (class 12,   band 2)
        [3] = { id = 300, count = 6 },  -- cloth    (tradegood,  class 7, band 2)
        [4] = { id = 200 },             -- sword    (weapon,     class 2, band 2)
        [5] = { id = 101, count = 5 },  -- bread    (consumable, class 0, band 0)
        [6] = { id = 400 },             -- recipe   (class 9,    band 2)
        [7] = { id = 201 },             -- cloak    (armor,      class 4, band 2)
    }
    local cells = bagCells(0, 12, seed)
    local plan  = Sort.Plan({ cells = cells, meta = metaFn })
    local copy  = bagCells(0, 12, seed)
    applyMoves(copy, plan.moves, maxOf)

    local ids = {}
    for i = 1, #copy do if copy[i].id then ids[#ids + 1] = copy[i].id end end
    -- band 2 by class DESC: quest(12) recipe(9) cloth(7) cloak(4) sword(2); then band 0: bread, apple
    local want = { 500, 400, 300, 201, 200, 101, 100 }
    local ok = (#ids == #want)
    for i = 1, #want do if ids[i] ~= want[i] then ok = false end end
    if not ok then
        local got = table.concat(ids, ",")
        ck(false, "mixed bag lands in 1.x order (want 500,400,300,201,200,101,100; got " .. got .. ")")
    else
        ck(true, "mixed bag lands in 1.x order")
    end

    -- Prove the divergence from OLD 2.0 explicitly: consumables are LAST now, not first.
    ck(ids[#ids] == 100 and ids[#ids - 1] == 101, "consumables sort to the BOTTOM (1.x), not the top")
    ck(ids[1] == 500, "highest-class item (quest) leads the gear/goods band")
end

-- WAVE PARTITION (report §3b harness ask): no two moves in a wave share a slot; the
-- partition preserves the planner's move order; it conserves every move; and applying
-- the wave-flattened order reaches the same target the linear plan does.
local function testPartitionWaves(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function sw(a1, a2, b1, b2) return { op = "swap", a = { cid = a1, slot = a2 }, b = { cid = b1, slot = b2 } } end
    -- Invariant: within every wave, all touched slots are distinct.
    local function noCollision(waves)
        for _, wv in ipairs(waves) do
            local seen = {}
            for _, ref in ipairs(wv.slots) do
                local k = ref.cid .. ":" .. ref.slot
                if seen[k] then return false end
                seen[k] = true
            end
        end
        return true
    end
    local function flatten(waves)
        local out = {}
        for _, wv in ipairs(waves) do for _, m in ipairs(wv.moves) do out[#out + 1] = m end end
        return out
    end

    -- Three fully-disjoint swaps collapse into ONE wave.
    local disjoint = { sw(0, 1, 0, 2), sw(0, 3, 0, 4), sw(0, 5, 0, 6) }
    local wd = Sort.PartitionWaves(disjoint)
    ck(#wd == 1, "3 slot-disjoint swaps collapse to a single wave")
    ck(#wd[1].moves == 3, "the wave holds all three moves")
    ck(noCollision(wd), "disjoint wave has no internal slot collision")

    -- A chain where each swap shares a slot with the previous -> a wave each, in order.
    local chain = { sw(0, 1, 0, 2), sw(0, 2, 0, 3), sw(0, 3, 0, 4) }
    local wc = Sort.PartitionWaves(chain)
    ck(#wc == 3, "each move shares a slot with the previous -> 3 waves")
    ck(noCollision(wc), "chained partition collision-free")
    local flatC = flatten(wc)
    local order = (#flatC == #chain)
    for i = 1, #flatC do if flatC[i] ~= chain[i] then order = false end end
    ck(order, "wave flattening preserves the original move order")

    -- Mixed: a conflict opens a new wave; a trailing disjoint move joins that new wave.
    local mixed = { sw(0, 1, 0, 2), sw(0, 3, 0, 4), sw(0, 2, 0, 5), sw(0, 6, 0, 7) }
    local wm = Sort.PartitionWaves(mixed)
    ck(#wm == 2, "conflict opens wave 2; trailing disjoint move joins wave 2")
    ck(noCollision(wm), "mixed partition collision-free")

    -- Against a REAL plan: collision-free, move-conserving, and reaches the same target.
    local seed = {
        [1] = { id = 200 }, [2] = { id = 100, count = 13 }, [3] = { id = 300, count = 4 },
        [4] = { id = 100, count = 12 }, [5] = { id = 201 }, [6] = { id = 300, count = 8 },
        [7] = { id = 101, count = 5 },
    }
    local plan = Sort.Plan({ cells = bagCells(0, 8, seed), meta = metaFn })
    local wp = Sort.PartitionWaves(plan.moves)
    ck(noCollision(wp), "real plan partitions into collision-free waves")
    local flatP = flatten(wp)
    ck(#flatP == #plan.moves, "wave partition conserves every planned move")
    local copy = bagCells(0, 8, seed)
    applyMoves(copy, flatP, maxOf)
    local reached = true
    for i = 1, #copy do
        local want = plan.target[i]
        if copy[i].id ~= want.id then reached = false end
        local haveCount = copy[i].id and copy[i].count or 0
        if haveCount ~= (want.count or 0) then reached = false end
    end
    ck(reached, "applying the wave-flattened order reaches the plan target exactly")

    -- Degenerate inputs: empty list -> no waves; a merge partitions on from/to slots.
    ck(#Sort.PartitionWaves({}) == 0, "empty move list -> zero waves")
    local mg = { { op = "merge", from = { cid = 0, slot = 1 }, to = { cid = 0, slot = 2 } },
                 { op = "merge", from = { cid = 0, slot = 2 }, to = { cid = 0, slot = 3 } } }
    local wg = Sort.PartitionWaves(mg)
    ck(#wg == 2 and noCollision(wg), "merges sharing slot 2 split into 2 collision-free waves")
end

-- Sort DIRECTION (audit §6.3): descending must reverse the canonical display order exactly
-- while still fully merging + canonicalising the contents (same multiset, reversed layout).
local function testPlanDirection(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function realizedSeq(descending)
        local start = {
            [1] = { id = 200 },              -- sword (weapon, class 2)
            [2] = { id = 100, count = 13 },  -- apple (consumable, class 0)
            [3] = { id = 300, count = 4 },   -- cloth (tradegood, class 7)
            [4] = { id = 100, count = 12 },  -- apple partial -> merges to {20,5}
            [5] = { id = 201 },              -- cloak (armor, class 4)
        }
        local cells = bagCells(0, 8, start)
        local plan = Sort.Plan({ cells = cells, meta = metaFn, descending = descending })
        local copy = bagCells(0, 8, start)
        applyMoves(copy, plan.moves, maxOf)
        local seq = {}
        for i = 1, #copy do if copy[i].id then seq[#seq + 1] = copy[i] end end
        return seq
    end

    local asc  = realizedSeq(false)
    local desc = realizedSeq(true)
    ck(#asc == #desc, "same number of stacks regardless of direction")

    -- DEFAULT (1.x order): gear band first by class↓ — tradegood(7) leads, consumable
    -- band (class 0) trails. (Bag has classes 0, 2, 4, 7.)
    ck(META[asc[1].id].classID == 7, "default (1.x): tradegood (class 7) group first")
    ck(META[asc[#asc].id].classID == 0, "default (1.x): consumable (class 0) group last")
    -- DESCENDING toggle REVERSES the grouping: consumable(0) first, tradegood(7) last.
    ck(META[desc[1].id].classID == 0, "descending: consumable (class 0) group first (reversed)")
    ck(META[desc[#desc].id].classID == 7, "descending: tradegood (class 7) group last (reversed)")

    -- within-item tail is KEPT canonical in BOTH directions: the fuller apple stack precedes
    -- the partial one whichever way we sort (this is what keeps descending a fixed point).
    local function appleOrder(seq)
        local out = {}
        for _, c in ipairs(seq) do if c.id == 100 then out[#out + 1] = c.count end end
        return out
    end
    local ascA, descA = appleOrder(asc), appleOrder(desc)
    ck(ascA[1] == 20 and ascA[2] == 5, "ascending apples: fuller {20} before partial {5}")
    ck(descA[1] == 20 and descA[2] == 5, "descending apples: fuller {20} STILL before partial {5} (canonical tail)")

    -- descending is DETERMINISTIC / idempotent: re-planning a desc-sorted bag -> zero moves.
    local sortedDesc = {}
    for i, c in ipairs(desc) do sortedDesc[i] = { cid = 0, slot = i, id = c.id, count = c.count } end
    for i = #desc + 1, 8 do sortedDesc[i] = { cid = 0, slot = i, id = nil, count = 0 } end
    local rp = Sort.Plan({ cells = sortedDesc, meta = metaFn, descending = true })
    ck(#rp.moves == 0, "re-planning a desc-sorted bag descending -> no moves (fixed point)")
end

function Sort.RunSelfTests(verbose)
    local suites = {
        { name = "merge pour (exhaustive)", fn = testMergePour },
        { name = "canonical stacks",        fn = testCanonicalStacks },
        { name = "plan: merge + group sort", fn = testPlanMergeAndSort },
        { name = "plan: 1.x order parity",   fn = testPlan1xOrder },
        { name = "plan: idempotent + locked", fn = testPlanIdempotentAndLocked },
        { name = "plan: family + multi-bag", fn = testPlanFamilyAndMultiBag },
        { name = "plan: direction inversion", fn = testPlanDirection },
        { name = "wave partition",          fn = testPartitionWaves },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS sort/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL sort/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("sort", Sort.RunSelfTests)
end

return Sort
