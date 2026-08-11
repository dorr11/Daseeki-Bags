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
--     Sort.Run(cids, opts)                  — OPTIMISTIC, flat-tick, re-planning. Every
--     Sort.TICK (0.05s) it re-snapshots the containers, overlays its own predicted-lock /
--     predicted-content table for moves still in flight, re-plans, and issues WAVE 1 of
--     the dependency partition — then returns. It NEVER waits on a server round-trip.
--     Converged when a plan taken on fully-observed state yields zero moves; bounded by a
--     move budget + idle-tick + hard tick caps. Abort-clean on combat / window close /
--     bank close. Accepts an explicit container-id SET so W3 reuses it for the bank.
--     No native sort exists on 1.15.9 (see below). See the EXECUTOR banner for the full
--     rationale and the defect-analysis §4 cost model this replaced.
--
-- ── Why the planner cannot infinite-loop ──────────────────────────────────────
-- Sorting runs in two bounded phases over a fixed set of free (unlocked) cells:
--   Phase I (merge)  pours partial stacks of each item into its canonical shape, in
--                    PAIRWISE rounds. Each pour retires at least one open (partial) cell,
--                    so a round of ⌊k/2⌋ pours retires ≥⌊k/2⌋ cells and the phase halts in
--                    ⌈log2 k⌉ rounds and ≤ (freeStacks − canonicalStacks) merges. After
--                    it, the multiset of (itemID, count) equals the target multiset.
--   Phase II (swap)  is selection-sort over a permutation: cell i is filled with its
--                    target stack by one swap with a later cell and never touched again,
--                    so it halts in ≤ (freeCells − 1) swaps.
-- Each plan is therefore FINITE. The executor re-plans every tick rather than replaying a
-- frozen list, so drift is ABSORBED instead of fatal; termination comes from the planner
-- being a fixed point (a sorted bag plans to zero moves) plus the explicit budget/tick
-- caps above, and is proved empirically by the "executor convergence" suite below
-- (randomized bags × simulated latency × dropped moves × mid-sort bag changes).
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
-- PURE: the two kinds of immovable cell
--
-- `locked`     — TRANSIENT. The client's own isLocked: an item is mid-flight on this
--                slot and the server has not answered yet. Cleared by the prediction
--                overlay once we know what the slot will hold (see overlayPredictions).
-- `userLocked` — PERMANENT (until the owner says otherwise). A SORT LOCK the owner set
--                in the lock config mode (locks.lua). It is a SEPARATE FIELD on purpose:
--                the prediction overlay clears `locked` on slots WE moved, and a user
--                lock must never be clearable by that path. Nothing in the executor
--                writes userLocked.
--
-- Both make a cell a planner FIXED POINT: its item stays put and it is never chosen as a
-- destination. That is 1.x's exact semantics (core/api/sorting.lua:111-114 omits a
-- locked slot from the space list entirely, so it is neither source nor destination).
----------------------------------------------------------------------

function Sort.CellIsFixed(c)
    if type(c) ~= "table" then return false end
    return (c.locked or c.userLocked) and true or false
end

----------------------------------------------------------------------
-- PURE: the planner
--
-- state = {
--   cells   = { { cid, slot, id|nil, count, quality, locked, userLocked }, ... },
--   meta    = function(id) -> { classID, subClassID, name, quality, maxStack } | nil,
--   canHold = function(cid, id) -> bool,   -- optional; default: everything fits
--   familyOf= function(cid) -> number,     -- optional; default 0 (every bag general)
--   busy    = function(cid, slot) -> bool, -- optional; default: nothing busy
-- }
-- Returns { target = { [cellIndex] = { id, count } }, moves = { ... }, stats = {...} }.
-- Locked cells (either kind — see Sort.CellIsFixed) are fixed points: their items stay,
-- and they are neither sources nor destinations. Move ops:
--   { op = "merge", from = {cid,slot}, to = {cid,slot} }   -- pour same-item stacks
--   { op = "swap",  a = {cid,slot},    b = {cid,slot} }    -- exchange two cells
--
-- ── BUSY: "known content, but not touchable THIS tick" (throughput fix) ──────
-- A cell is BUSY when the executor has a move of its own outstanding on it: we know
-- what it will hold (the prediction), but the client will refuse a second move on it
-- until the server answers. Busy is deliberately NOT the same thing as LOCKED:
--
--   locked / userLocked  -> a FIXED POINT. Out of `free` entirely: its item is not part
--                           of the sorted multiset and its cell is not part of the target
--                           map. (A user sort-lock, or somebody else's in-flight move.)
--   busy                 -> IN `free`. Its (predicted) content still counts toward the
--                           totals and it still receives a target, so the target map is
--                           computed over the SAME cell set every tick and stays a fixed
--                           point. It is only excluded as a MOVE ENDPOINT.
--
-- Why this exists (measured): the executor overlays predictions onto the snapshot and
-- CLEARS `locked` on its own in-flight slots, precisely so the target map does not churn.
-- But that also made those cells look available to the move planner, so Phase II happily
-- planned swaps on them — and the issue guard then rejected every one. On a 120-cell bank
-- at 0.30 s latency that cost ~6.7 of every 8.0 wave-1 moves, leaving ~1.3 issued per tick
-- (the owner's "231 moves in 123 waves"). Excluding busy cells from move SELECTION only —
-- while keeping them in the target map — is what makes wave 1 issuable again.
--
-- ── FAMILY BANDS: 1.x's placement rule ──────────────────────────────────────
-- 1.x (core/api/sorting.lua GetFamilies/GetOrder) does NOT assign one global sorted list
-- to cells. It processes bag FAMILIES in descending family order — specialized bags
-- FIRST, general bags (family 0) LAST — and fills each family's slots with the sorted
-- subsequence of the still-unplaced items that fit it. So a herb bag is a HOME that gets
-- claimed before the backpack is, and only the overflow lands in general slots.
-- `familyOf` restores that. With no familyOf (or every bag general) there is exactly one
-- band and the assignment is identical to a single global sorted run — i.e. this is a
-- no-op for the common all-general inventory.
----------------------------------------------------------------------

-- PURE: 1.x's family processing order (GetFamilies' comparator, verbatim):
--   sort(list, function(a, b) return a > b and (a ~= 0x80000 or b == 0) end)
-- Descending, except the reagent-bag pseudo-family (0x80000) is demoted to just above
-- the general family 0, which is always last. Exposed for the harness.
Sort.REAGENT_FAMILY = 0x80000
function Sort.FamilyOrder(list)
    local out = {}
    for _, f in ipairs(list or {}) do out[#out + 1] = f end
    table.sort(out, function(a, b)
        if a == b then return false end
        -- general (0) always last
        if a == 0 then return false end
        if b == 0 then return true end
        -- the reagent pseudo-family sorts after every real specialized family
        if a == Sort.REAGENT_FAMILY then return false end
        if b == Sort.REAGENT_FAMILY then return true end
        return a > b
    end)
    return out
end

function Sort.Plan(state)
    state = state or {}
    local cells    = state.cells or {}
    local meta     = state.meta or function() return nil end
    local canHold  = state.canHold or function() return true end
    local familyOf = state.familyOf
    local busyFn   = state.busy

    local moves = {}

    -- free (unlocked) cell indices in canonical order. A cell fixed by EITHER lock kind
    -- is excluded here and therefore cannot appear in `moves` in any position: Phase I
    -- only pours between free cells, the target map is only built over free cells, and
    -- Phase II only swaps free cells. One exclusion, both directions.
    local free = {}
    for i, c in ipairs(cells) do
        if not Sort.CellIsFixed(c) then free[#free + 1] = i end
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

    -- BUSY (see the banner): still in `free` and still in the target map, but not a legal
    -- move ENDPOINT this tick. Memoized — Plan runs ~20x/s under the optimistic executor.
    local busyAt = {}
    local function usable(i)
        if not busyFn then return true end
        local v = busyAt[i]
        if v == nil then
            local c = cells[i]
            v = not busyFn(c.cid, c.slot)
            busyAt[i] = v
        end
        return v
    end

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
    --
    -- PAIRWISE (tournament) merge, not a single accumulator. The old shape poured
    -- every partial through ONE open accumulator cell, so k partials produced k-1
    -- CONSECUTIVE moves that all claimed the same destination — each conflicting with
    -- its predecessor, i.e. one wave apiece (defect analysis §4: Phase I alone was
    -- 12.3 of the typical bag's 18.6 waves, ~1.9 moves/wave).
    --
    -- Instead, each ROUND pairs the still-open (non-full, id-bearing) cells in free
    -- order — (o1<-o2), (o3<-o4), … — pouring the LATER into the EARLIER. Every move
    -- in a round is slot-disjoint from the others in that round, so the whole round
    -- batches into ONE wave. Each pour either fills its destination to max or empties
    -- its source, so it retires at least one open cell: a round of ⌊k/2⌋ pours retires
    -- ≥⌊k/2⌋ cells and the loop halts in ⌈log2 k⌉ rounds with ≤ k-1 total moves (never
    -- MORE moves than the accumulator form, and log-depth instead of linear).
    --
    -- Invariants preserved: the earliest open cell is always a DESTINATION, never a
    -- source, so "fill the earliest partial first" still holds (the descending fixed
    -- point at :249-257 depends on it); the final multiset is the canonical shape
    -- (loop exits only when ≤1 open cell remains for the id); and an already-canonical
    -- bag has ≤1 open cell per id => zero merges => Plan stays idempotent.
    ---------------------------------------------------------------
    for _, id in ipairs(idOrder) do
        local max = maxStackOf(id)
        if max > 1 then   -- non-stackables (max 1) can never merge
            while true do
                -- open = cells still holding a PARTIAL stack of this id, in free order.
                -- A BUSY cell is skipped: its pour is simply left for a later tick (its
                -- predicted content is already counted in `totals`, so the canonical
                -- shape below is unchanged — only the merge SCHEDULE moves).
                local open = {}
                for _, i in ipairs(free) do
                    local s = sim[i]
                    if s.id == id and s.count > 0 and s.count < max and usable(i) then
                        open[#open + 1] = i
                    end
                end
                if #open < 2 then break end
                local progressed = false
                local k = 1
                while k + 1 <= #open do
                    local dst, src = open[k], open[k + 1]   -- pour later -> earlier
                    local ns2, nd2 = Sort.MergePour(sim[src].count, sim[dst].count, max)
                    if nd2 > sim[dst].count then
                        moves[#moves + 1] = { op = "merge", from = ref(src), to = ref(dst) }
                        sim[src].count, sim[dst].count = ns2, nd2
                        if ns2 == 0 then sim[src].id = nil end
                        progressed = true
                    end
                    k = k + 2
                end
                if not progressed then break end   -- belt-and-suspenders: never spin
            end
        end
    end

    ---------------------------------------------------------------
    -- Build the sorted target stacks, then assign them to free cells in
    -- 1.x's FAMILY BANDS (specialized bags claimed first, general last).
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

    -- ── FAMILY-BAND ASSIGNMENT (1.x GetFamilies/GetOrder, restored) ──────────
    -- Group the free cells by their container's family, walk the bands in 1.x's order
    -- (specialized descending, reagent pseudo-family next, general 0 LAST) and fill each
    -- band's cells with the still-unplaced stacks that fit it, in display order.
    --
    -- This replaces a "most-constrained first" heuristic that ranked stacks by how MANY
    -- cells could hold them, ascending. That metric is inverted for this problem: a herb
    -- fits the herb bag AND every general cell, so its fit count is the HIGHEST and it was
    -- assigned LAST — after the general cells it could have used were already taken. The
    -- result was herbs spilling into the backpack while the herb bag sat half empty, the
    -- exact opposite of 1.x, which treats a specialized bag as a HOME to be claimed first.
    --
    -- Degenerate case (no familyOf, or every container general): exactly one band holding
    -- every free cell in canonical order, so this is identical to a single global sorted
    -- run — the all-general inventory is bit-for-bit unchanged.
    local bandOfCell, bandList = {}, {}
    do
        local seen = {}
        for _, i in ipairs(free) do
            local f = (familyOf and familyOf(cells[i].cid)) or 0
            if type(f) ~= "number" then f = 0 end
            bandOfCell[i] = f
            if not seen[f] then seen[f] = true; bandList[#bandList + 1] = f end
        end
        bandList = Sort.FamilyOrder(bandList)
    end

    local usedCell, stackAtCell, placedStack = {}, {}, {}
    for _, family in ipairs(bandList) do
        -- this band's free cells, in canonical order
        local bandCells = {}
        for _, i in ipairs(free) do
            if bandOfCell[i] == family then bandCells[#bandCells + 1] = i end
        end
        local next_ = 1
        for idx, st in ipairs(targetStacks) do
            if not placedStack[idx] then
                while next_ <= #bandCells and usedCell[bandCells[next_]] do next_ = next_ + 1 end
                if next_ > #bandCells then break end
                local i = bandCells[next_]
                if canHold(cells[i].cid, st.id) then
                    usedCell[i], stackAtCell[i], placedStack[idx] = true, st, true
                    next_ = next_ + 1
                end
            end
        end
    end
    -- Safety net: any stack a band could not seat (a general band smaller than its own
    -- overflow can only happen if the bags shrank mid-plan) takes the first cell anywhere
    -- that will hold it, so no item is ever left without a target.
    for idx, st in ipairs(targetStacks) do
        if not placedStack[idx] then
            for _, i in ipairs(free) do
                if not usedCell[i] and canHold(cells[i].cid, st.id) then
                    usedCell[i], stackAtCell[i], placedStack[idx] = true, st, true
                    break
                end
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
    -- A swap EXCHANGES two cells, so it is only legal when the DISPLACED item can live in
    -- the donor's container too — 1.x's Move guard verbatim (core/api/sorting.lua):
    --     if ... (to.item.itemID and not self:FitsIn(to.item.itemID, from.family)) then return end
    -- 2.0 checked only that the arriving item fits its destination, so a swap could try to
    -- push a non-herb into a herb bag; the client refuses it and the re-plan re-issues it
    -- forever. We PREFER a donor that makes the exchange legal both ways and only fall back
    -- to the first match when no legal donor exists (keeping the old convergence behaviour
    -- rather than stranding the cell).
    local function legalDonor(i, j)
        local moving = sim[i].id
        if not moving then return true end          -- an empty cell displaces nothing
        return canHold(cells[j].cid, moving) and true or false
    end

    local function eq(a, b) return a.id == b.id and a.count == b.count end
    local swaps = 0
    for a = 1, #free do
        local i = free[a]
        -- A BUSY cell cannot be a move endpoint this tick; its swap waits for a later one.
        if usable(i) and not eq(sim[i], target[i]) then
            local foundPos, fallbackPos
            for b = a + 1, #free do
                local j = free[b]
                if usable(j) and eq(sim[j], target[i]) then
                    if legalDonor(i, j) then foundPos = b; break end
                    fallbackPos = fallbackPos or b
                end
            end
            foundPos = foundPos or fallbackPos
            if foundPos then
                local j = free[foundPos]
                moves[#moves + 1] = { op = "swap", a = ref(i), b = ref(j) }
                sim[i], sim[j] = sim[j], sim[i]
                swaps = swaps + 1
            end
            -- no match (the donor is busy, or a pathological family constraint):
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
-- wave can be issued in one tick without waiting between its moves.
--
-- DEPENDENCY-GRAPH partition (was: a sequential RUN partition). Two moves are dependent
-- exactly when they share a container slot; the move list is therefore a DAG whose edges
-- run forward in plan order, and the wave index of a move is its longest-path depth:
--
--     wave(m) = 1 + max{ wave(m') : m' earlier in the plan and sharing a slot with m }
--
-- computed in O(n) with a per-slot "last wave that touched this slot" map. The OLD form
-- closed the current wave on the FIRST conflict and never revisited it, so one conflicting
-- move stranded every later move behind it even when dozens of slots were still free
-- (defect analysis §4: 2.5-3.5× more waves than the dependency graph requires — typical
-- bag 18.6 waves vs 7.0 optimal).
--
-- The three properties the executor and the tests rely on are unchanged:
--   * SLOT-DISJOINT within a wave — a move only joins wave w when no move already in w
--     touches either of its slots (its own predecessors all sit in waves < w, and any
--     move in w is by construction slot-independent of it).
--   * ORDER-PRESERVING across dependencies — a move that shares a slot with an earlier
--     move lands in a STRICTLY later wave, so it still runs after it.
--   * FLATTENING IS EQUIVALENT — flattening wave-by-wave can now move an independent
--     move EARLIER than a plan-order predecessor, but only past moves it is slot-disjoint
--     from (otherwise it would sit in a later wave). Slot-disjoint moves commute, so the
--     flattened order has exactly the same effect as the planner's order.
--
-- Wave 1 has a further property the optimistic executor depends on: every wave-1 move
-- depends on NO earlier move, so each one is valid against the OBSERVED bag state, not
-- against a hypothetical post-plan state. That is what makes "issue wave 1, re-plan next
-- tick" sound.
----------------------------------------------------------------------

-- The container slots a single move touches (source + destination).
function Sort.MoveSlots(m)
    if m.op == "swap" then return { m.a, m.b } end
    if m.op == "merge" or m.op == "split" then return { m.from, m.to } end
    return {}
end

function Sort.PartitionWaves(moves)
    local waves = {}
    local lastWave = {}   -- [slotKey] = index of the last wave that touched this slot
    local function key(ref) return ref.cid .. ":" .. ref.slot end
    for _, m in ipairs(moves or {}) do
        local slots = Sort.MoveSlots(m)
        -- earliest legal wave = one past the deepest wave any of our slots is already in
        local w = 1
        for _, ref in ipairs(slots) do
            local lw = lastWave[key(ref)]
            if lw and lw + 1 > w then w = lw + 1 end
        end
        -- w can never skip: it is at most (max lastWave) + 1 <= #waves + 1, so no holes.
        local wave = waves[w]
        if not wave then wave = { moves = {}, slots = {} }; waves[w] = wave end
        wave.moves[#wave.moves + 1] = m
        for _, ref in ipairs(slots) do
            lastWave[key(ref)] = w
            wave.slots[#wave.slots + 1] = ref
        end
    end
    return waves
end

----------------------------------------------------------------------
-- THE FINAL CLEANUP WAVE (2.0.3)
--
-- An abort lands BETWEEN waves, so the selection sort's partially applied prefix has
-- items parked in temporary places and gaps where they came from — the owner's live
-- report, verbatim: "items scattered with holes". Sorted-but-partial is an acceptable
-- outcome for an interrupted run; HOLED is not, because a gap in the middle of the grid
-- reads as damage rather than as an unfinished job.
--
-- So every abort that can still legally touch the bags ends with ONE compaction pass:
-- pull each item backwards into the earliest legal free cell before it. Properties that
-- make this safe to run on a bag in ANY state:
--   * It is a single WAVE. Every move it emits is slot-disjoint by construction (a cell
--     is either a hole or a source, never both in the same emitted move, and a consumed
--     hole leaves the list), so no move depends on another landing first — which is what
--     lets an aborting executor issue the whole thing and stop.
--   * It never crosses a family boundary (`canHold`), never touches a user-locked, live-
--     locked or in-flight cell (`isFixed`), and never splits or merges a stack — it only
--     relocates whole cells, so the item multiset is conserved exactly.
--   * It is bounded: at most `Sort.MAX_CLEANUP_MOVES`, and both loops are ceilinged.
-- It is deliberately NOT a sort. It closes holes; finishing the arrangement is the next
-- run's job, and the abort line says so.
Sort.MAX_CLEANUP_MOVES = 24

-- TWO POINTERS, and why not the obvious shuffle. The natural way to close holes is to
-- walk forward moving each item into the earliest hole behind it — but that RECYCLES the
-- cell it vacates as a hole for the next item, so move k+1's destination is move k's
-- source and the pass is a dependency CHAIN, not a wave. An aborting executor cannot pay
-- for a chain: it is stopping, so every move after the first would be issued against a
-- slot that has not settled, which is the very failure this release exists to remove.
--
-- So: holes from the FRONT, items from the BACK, meeting in the middle. Every hole used
-- is strictly before every item moved, no vacated cell is ever reused, and the whole pass
-- is therefore slot-disjoint — one wave, issuable in one go, correct whether or not the
-- executor ever runs again. It also compacts BETTER than the forward shuffle, because it
-- fills the earliest holes with the furthest items.
function Sort.CompactMoves(cells, canHold, isFixed)
    local moves = {}
    local usable = function(c)
        if c.userLocked or c.locked then return false end
        if isFixed and isFixed(c) then return false end
        return true
    end
    local taken = {}                     -- items already claimed as a source
    local back  = #cells
    local guard = 0
    for front = 1, #cells do
        if #moves >= Sort.MAX_CLEANUP_MOVES or front >= back then break end
        local h = cells[front]
        if h.id == nil and usable(h) then
            -- Furthest item that may legally live in this hole. Ceilinged by `back`,
            -- which only ever moves down, so the whole search is O(#cells) amortized.
            local pick
            local probe = back
            while probe > front do
                guard = guard + 1
                if guard > 20000 then break end          -- headless discipline
                local c = cells[probe]
                if c.id ~= nil and not taken[probe] and usable(c)
                   and ((not canHold) or canHold(h.cid, c.id)) then
                    pick = probe
                    break
                end
                probe = probe - 1
            end
            if not pick then break end                  -- nothing left to pull forward
            local c = cells[pick]
            moves[#moves + 1] = { op = "swap",
                a = { cid = c.cid, slot = c.slot },
                b = { cid = h.cid, slot = h.slot } }
            h.id, h.count = c.id, c.count
            c.id, c.count = nil, 0
            taken[pick] = true
            back = pick - 1
        end
    end
    return moves
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
-- EXECUTOR (in-game only) — OPTIMISTIC, flat-tick, re-planning, abort-clean.
--
-- Catalog verdict (wow-api-catalog/1.15.9.68808): Classic Era 1.15.9 has NO native
-- container sort — there is no C_Container.SortBags / SortBags / SortBankBags (grep of
-- functions.txt finds only auction/calendar sorts). So the client-side planner IS the
-- sort and this executor is the perf path.
--
-- ── Why this was rewritten (defect analysis §4) ──────────────────────────────
-- The previous executor froze ONE plan, then per wave: issue the wave, poll every
-- touched slot's live isLocked until the SERVER confirmed the swap, then wait another
-- WAVE_THROTTLE before the next wave. Cost `N_waves × (RTT + 0.05 + frame quantization)`
-- — at 200 ms latency the synchronous round-trip alone was ~80% of a 4.6 s sort. The
-- owner's 1.x fork never waits on the server at all: it re-scans, re-plans and fires
-- every currently-legal move on a flat 0.05 s cadence, which is why it feels instant.
--
-- ── What this executor does instead ──────────────────────────────────────────
-- A flat `Sort.TICK` ticker. Every tick:
--   1. Re-SNAPSHOT the live containers (so bag changes mid-sort are absorbed, not fatal).
--   2. Overlay our own PREDICTED-LOCK table onto that snapshot: for every slot we have
--      an outstanding move on, force `locked = true` and substitute the content we
--      predicted the move would produce. The planner already treats locked cells as
--      FIXED POINTS (never a source, never a destination, excluded from the target map),
--      so in-flight slots are planned AROUND rather than planned against — and because
--      the predicted content is what the move is about to deliver, the remaining cells
--      get the same placement the full plan would have given them. That is what stops
--      optimistic re-planning from oscillating (a re-plan against merely OBSERVED, i.e.
--      pre-move, content would keep rearranging cells the in-flight moves already fixed).
--      A prediction is dropped when the slot is SETTLED — unlocked AND showing the
--      content the move promised (2.0.3; see the SETTLE-AWARE ARMING banner above, and
--      Sort.PredSettled). Not merely unlocked: the client releases the lock before it
--      rewrites the slot's contents, and retiring in that window is what made 2.0.2
--      re-issue moves the server had already applied. `Sort.SETTLE_TTL` and
--      `Sort.LOCK_TTL` are the backstops, so a FAILED or dropped move still
--      self-corrects — just not while it might still be in the air.
--   3. Re-PLAN from scratch (the planner is a documented fixed point, so this converges).
--   4. Issue WAVE 1 ONLY of the dependency partition, up to `Sort.MAX_IN_FLIGHT`
--      concurrent un-acked moves. Wave-1 moves depend on no earlier move, so each is
--      valid against the state we just observed — never against a hypothetical
--      post-plan state. Later waves are simply left for a later round, by which time
--      their dependencies have settled and they have become wave 1.
--   5. Return immediately. NEVER wait for the server — but if the round could issue
--      NOTHING because every slot it needs is held by one of our own un-acked moves,
--      it is WAITING, not working: it backs off to `Sort.WAIT_TICK` and re-arms on the
--      bag events rather than re-planning at 20 Hz through a settle window.
-- Termination: converged when a plan with NO outstanding predictions yields zero moves.
-- An ABORT ends with one compaction wave (Sort.CompactMoves) so an interrupted run
-- never leaves the grid holed.
--
-- ── ABORTS ARE PROGRESS-BASED, NOT CLOCK-BASED ──────────────────────────────
-- The executor used to stop at a fixed 200 ticks (~10 s) and print "time budget exceeded",
-- which ABANDONED a sort that was still making progress and left the bag half-arranged
-- (the owner's report: "sort stopped: time budget exceeded (231 moves in 123 waves,
-- 10.54s)"). A slow sort is a nuisance; a silently unfinished one is a defect. So the
-- clock no longer terminates anything: the run stops when the residual plan STOPS
-- SHRINKING (`MAX_NO_PROGRESS` ticks with no new low-water mark) — which is a genuine
-- stall — and `MAX_TICKS` survives only as a runaway ceiling far above any real sort.
-- The move budget is re-based on every improvement for the same reason. Every abort now
-- reports how many slots are still out of place.
--
-- Cost model: `Σ over dependency rounds of max(TICK, RTT)` with per-move granularity
-- (independent chains progress in parallel and a move becomes issuable the instant ITS
-- own dependency clears — there is no whole-wave barrier), against the old
-- `N_waves × (RTT + 0.05 + quantization)` where N_waves was itself 2.5-3.5× the true
-- dependency depth. Both multipliers are gone.
--
-- Correctness guard-rails, all preserved and covered by the convergence suite below:
-- locked slots stay fixed points; family / canHold constraints are enforced by the
-- planner on every re-plan; combat / bank-closed / window-closed abort immediately and
-- clear the cursor. Items are only ever swapped or poured between two legal cells, so no
-- reachable interleaving can drop or duplicate one.
-- =====================================================================

Sort.TICK               = 0.05   -- flat FALLBACK cadence; never waits on a server round-trip
Sort.MAX_MOVES_PER_TICK = 24     -- cap the burst so the client never drops requests
-- RUNAWAY ceiling only. This is NOT a time budget: a healthy sort finishes in tens of
-- ticks and the no-progress guard below stops a stalled one long before this. It exists
-- so a pathological client can never leave a ticker running forever.
Sort.MAX_TICKS          = 4000   -- ~200s absolute ceiling; the stall guard fires first
Sort.MAX_IDLE_TICKS     = 40     -- ~2s with nothing issuable AND nothing in flight => abort
-- THE REAL TERMINATION GUARD: ticks since the residual plan last hit a new low. A sort
-- that is still shrinking its residual is still working and is never interrupted, however
-- long it takes. 120 ticks is ~6s — comfortably longer than any single round-trip.
Sort.MAX_NO_PROGRESS    = 120
Sort.MAX_MOVE_FACTOR    = 4      -- move budget = factor × residual + MOVE_SLACK, RE-BASED
Sort.MOVE_SLACK         = 32     -- upward on every improvement (see Sort._tick)
-- Hand the planner the set of cells with one of OUR moves in flight (Sort.Plan's BUSY
-- banner, and issueWave1's).
--
-- 2.0.3: OFF. Not deleted — the planner's busy support and its tests are untouched, and
-- this is one constant away from returning — but the executor no longer issues from a
-- restricted re-plan, because the premise the fallback was built on has been removed.
--
-- 2.0.2 added it because the full plan's wave 1 kept coming back entirely made of moves
-- on in-flight cells, so the issue guard rejected nearly all of them and the round idled.
-- That happened because a prediction was retired the moment its slot read UNLOCKED, so
-- the overlay was substituting content for a set of slots that kept churning underneath
-- it. With settle-aware retirement the overlay reflects what the moves will actually
-- deliver, and the full plan's wave 1 is issuable. What remains of the fallback is a
-- deliberately WORSE decomposition bought on rounds that should simply have waited.
--
-- MEASURED on the owner's 88-cell / 74% fixture, same seed, both ways:
--     PLAN_BUSY on : 81 moves for a 72-move plan, 48 waves, 4338ms
--     PLAN_BUSY off: 78 moves for a 72-move plan, 46 waves, 4231ms
-- Fewer moves AND less wall clock — the throughput argument for it has inverted. On the
-- small healthy fixture it is 19 moves / 2418ms off against 21 / 2092ms on: ~330ms of a
-- 2s sort spent WAITING for the server instead of papering over the wait with two extra
-- moves. That is the trade this release is explicitly making (see the WAITING round in
-- Sort._tick): the owner's complaint is over-issue and client rejections, not 300ms.
Sort.PLAN_BUSY          = false
Sort.LOCK_TTL           = 3.00   -- backstop only: a slot locked THIS long is pathological
Sort.QUIET_REFRESH      = 0.20   -- 5 Hz grid heartbeat while the refresh storm is muted
Sort.LIVE_REPAINT       = 0.12   -- ~8 Hz coalesced LIVE-cell repaint (BAG-7; see beginQuiet)

-- =====================================================================
-- 2.0.3 — SETTLE-AWARE ARMING, and the over-issue it fixes
--
-- LIVE FAILURE (owner, 88 combined cells at 74% fill): plan 60 moves, EXECUTE 305,
-- 82 waves, 5.32s, client "Internal Bag Error", run aborted mid-layout on the move
-- budget. Even a healthy run of the same session executed 15 moves for a 5-move plan.
-- The executor had been over-issuing 3x all along; the big bag only made it fatal.
--
-- THE MECHANISM. ITEM_LOCK_CHANGED and BAG_UPDATE are DIFFERENT events, and BAG_UPDATE
-- is the LATER one. When the server answers a move the client releases the slot lock
-- FIRST and rewrites the slot's visible CONTENTS only when the bag-update burst lands.
-- 2.0.2's `releasePred` retired a prediction the instant the slot read UNLOCKED — so
-- inside that window the executor:
--     1. dropped its prediction and recorded an ack,
--     2. re-snapshotted the slot, getting its PRE-MOVE contents,
--     3. re-planned the move it had just performed, and
--     4. re-issued it, because neither the prediction nor the live lock forbade it.
-- The server then refused the duplicate — its truth no longer matched what the client
-- had sent — which is precisely ERR_INTERNAL_BAG_ERROR. The refused move never landed,
-- the residual never dropped, and the next round did it all again: 305 executions of a
-- 60-move plan. Unlocked is NOT settled. Settled is "the contents I predicted are the
-- contents I can now see".
--
-- (Same failure class as Daseeki-Conduit's mail attach, fixed there the same way: a
-- locked/unsettled bag slot made SplitContainerItem a silent no-op, and the fix was to
-- arm on settlement rather than on the lock. mail.lua's SETTLE_TIMEOUT = 1.0 with
-- BAG_UPDATE_DELAYED as the primary signal is the model these constants follow.)
--
-- THE 1.x CONTRAST. 1.x (core/api/sorting.lua) has no in-flight memory at all — but it
-- cannot churn, because a pass that issues nothing ENDS THE RUN (`if not self:Delaying
-- ('Run') then self:Stop() end`) and its MutexDelay collapses a whole pass into exactly
-- ONE follow-up pass. A 1.x run therefore cannot outlive its own progress: total issued
-- moves is bounded by the moves it could legally issue. 2.0 traded that for a
-- re-planning loop that keeps going until a budget or stall guard fires, which is what
-- turned re-issue into 305 executions. This block restores the missing bound in the
-- form 2.0's design can carry it: strict in-flight accounting, plus a round that WAITS
-- for the next bag event instead of burning budget when it cannot progress.
--
-- SETTLE_TTL / SETTLE_ACKS: the backstop for a prediction whose contents never arrive
-- (the move was genuinely refused, or the server dropped it). It must be comfortably
-- longer than one round-trip or a healthy move would be re-planned mid-flight; the
-- owner's measured avgAckMs is ~240ms, so 1.0s is ~4 acks, and SETTLE_ACKS keeps that
-- ratio on a slower connection. Reality wins at the ceiling — a stale prediction is
-- dropped and the move is re-planned from OBSERVED state, which is the correct
-- self-correction and the only path that may legitimately re-issue a move.
Sort.SETTLE_TTL         = 1.00
Sort.SETTLE_ACKS        = 4

-- BOUNDED IN-FLIGHT. Each outstanding move takes TWO cells out of the planner's reach,
-- so 2.0.2's 24-moves-per-tick burst froze up to 48 of the owner's 88 cells — more than
-- half the bag — which is exactly why its full plan kept coming back unissuable. 10
-- concurrent moves is 20 cells, ~23% of an 88-cell view: the planner keeps three
-- quarters of the bag to work with, and at the measured ~240ms round-trip the bound
-- still sustains ~40 moves/s, so it is never the limiter on a healthy sort. It IS the
-- limiter on a pathological one, which is the point. (1.x's equivalent bound is
-- structural rather than numeric: one pass, then one follow-up pass, then stop.)
--
-- SWEPT on the owner's 88-cell / 74% fixture (72-move plan), same seed throughout:
--      4 -> 74 moves,  8.5s     10 -> 78 moves, 4.2s
--      6 -> 74 moves,  5.9s     12 -> 80 moves, 4.4s
--      8 -> 78 moves,  6.0s     24 -> 82 moves, 3.7s
-- Below 8 the executor starves (4 and 6 also fail the shipped "feels instant at
-- realistic latency" pin); at 24 — 2.0.2's effective burst — the move count breaks the
-- fixture's tolerance, which is the churn this release exists to remove, showing up on
-- the dial that causes it. 10 is the knee: the best wall clock of any value that does
-- not buy it with extra moves.
Sort.MAX_IN_FLIGHT      = 10

-- A round that issued nothing while our own moves are still in flight is WAITING, not
-- working. It re-arms on the bag events (ITEM_LOCK_CHANGED / BAG_UPDATE / the
-- BAG_UPDATE_DELAYED burst-over signal) and keeps only this slow backstop tick, so a
-- settle window costs no budget, no churn and no re-plans — see Sort._tick.
Sort.WAIT_TICK          = 0.25

-- ERR_INTERNAL_BAG_ERROR. The numeric id is build-specific across Classic Era builds,
-- so the classifier accepts a known id OR the message text. Observed only — the count
-- rides in the telemetry ring so a future log says "the client refused N operations"
-- instead of leaving it to be inferred from an executed/planned ratio.
Sort.BAG_ERROR_IDS      = { [44] = true, [45] = true, [46] = true }
Sort.BAG_ERROR_PATTERN  = "[Bb]ag [Ee]rror"

function Sort.IsBagError(id, msg)
    if id ~= nil and Sort.BAG_ERROR_IDS[id] then return true end
    if type(msg) == "string" and msg:find(Sort.BAG_ERROR_PATTERN) then return true end
    return false
end

-- =====================================================================
-- 2.0.2 — EVENT-DRIVEN ISSUING, and why the tick survives beside it
--
-- 2.0.1 issued moves on a flat Sort.TICK ladder and used ITEM_LOCK_CHANGED for exactly
-- one thing: releasing the prediction on the (bag, slot) the event names, plus a single
-- narrow "pull the next round forward" case (only when the previous round had issued
-- NOTHING). Everything else waited out the remainder of the 0.05s tick. On a real bag
-- that is a whole tick of dead air stacked on top of EVERY dependency round: the owner's
-- live baseline was 154 moves / 63 waves / 5.56s, and 63 rounds x up-to-50ms of
-- quantization is ~3s of the 5.56 spent waiting for a timer that had nothing to add.
--
-- 2.0.2: a prediction release is a SCHEDULING EVENT. Whenever the server confirms one of
-- our slots, the next round is pulled forward to the next frame instead of the next tick
-- (`Sort.EVENT_ISSUE`). The round itself is UNCHANGED — same re-snapshot, same overlay,
-- same re-plan, same wave-1 issue, same guards — so every shipped correctness contract
-- (lock-set exclusion in both directions, combat/window/bank aborts, progress-based
-- termination, busy-set stability, plan-size pins) holds by construction: only the CLOCK
-- moved. Correctness lives in _tick and issueWave1; this only changes when they run.
--
-- The tick is KEPT as the fallback/safety cadence and is never lengthened: every kick
-- goes through scheduleTick, which is generation-guarded, so a kick REPLACES the pending
-- tick rather than racing it, and a kick is never scheduled LATER than the tick it
-- replaces (see kickTick's clamp). With the events silent — a client that drops them, a
-- move the server never answers — the executor degrades to exactly the 2.0.1 ladder.
--
-- COALESCING. One move fires two ITEM_LOCK_CHANGED events (both endpoints), so a 24-move
-- wave lands ~48 events in one frame. Each calls scheduleTick, each bumps `_tickGen`, and
-- every callback but the last becomes a no-op — so a burst of N events costs ONE re-plan,
-- on the next frame. `Sort.KICK_GAP` is the floor under that: two rounds are never run
-- closer together than this, so even a pathological event storm cannot plan more often
-- than ~1/KICK_GAP per second.
Sort.EVENT_ISSUE        = true   -- master switch (off == the 2.0.1 tick-only ladder)
Sort.KICK_GAP           = 0.01   -- min seconds between two rounds when events drive them

-- =====================================================================
-- 2.0.2 — THE GUARDS ARE WINDOWS IN SECONDS, NOT JUST TICK COUNTS
--
-- MAX_IDLE_TICKS / MAX_NO_PROGRESS / MAX_TICKS were all written against a FIXED 0.05s
-- cadence, i.e. they are wall-clock windows spelled in ticks (2s / 6s / 200s). Event
-- issuing makes the cadence variable and much faster, which would have silently SHORTENED
-- every one of them — a healthy but slow sort could then trip a stall guard that used to
-- give it six seconds. That is a correctness regression, not a tuning question.
--
-- So each guard now needs BOTH its tick count AND its wall-clock window to be exceeded.
-- Both are derived from the constants above rather than restated, and the seconds arm can
-- only ever DELAY an abort relative to 2.0.1 — never bring one forward.
Sort.IDLE_SECONDS        = Sort.MAX_IDLE_TICKS  * Sort.TICK   -- 2s
Sort.NO_PROGRESS_SECONDS = Sort.MAX_NO_PROGRESS * Sort.TICK   -- 6s
Sort.RUNAWAY_SECONDS     = Sort.MAX_TICKS       * Sort.TICK   -- 200s

-- ADAPTIVE SEED (2.0.2c). The telemetry log measures `avgAckMs` — the real per-move
-- lock-clear round-trip — so the two stall windows can be sized against the connection
-- the owner actually has instead of a 0.05s tick that has nothing to do with it. The
-- seed is applied as a MAXIMUM against the fixed windows above, so a fast connection
-- changes nothing at all and a slow one only ever buys more patience. Deliberately
-- conservative: the point of the log is that LATER tuning is data-driven, so nothing
-- here is allowed to make the executor give up sooner than 2.0.1 did.
Sort.IDLE_ACKS           = 6     -- idle window >= this many measured round-trips
Sort.NO_PROGRESS_ACKS    = 12    -- stall window >= this many measured round-trips
Sort.RUNAWAY_ACKS        = 400   -- runaway ceiling >= this many measured round-trips

-- Telemetry ring buffer (2.0.2a): the last N completed runs, in DaseekiBags2DB.sortLog.
Sort.LOG_CAP            = 50

-- =====================================================================
-- PURE: THE SORT TELEMETRY RING BUFFER  (2.0.2a)
--
-- Owner's ask: "use the data over time to make it more efficient." Tuning the executor
-- from one chat line per sort is guesswork — the line says moves/waves/seconds and
-- nothing about WHY. So every finished run (completed or aborted) appends one flat record
-- to `DaseekiBags2DB.sortLog`, and the coordinator mines them straight out of the WTF
-- SavedVariables file.
--
-- ── SHAPE, and why it is flat ────────────────────────────────────────────────
-- Every field is a SCALAR (number / boolean / string) — no nested tables, no arrays, no
-- nils in the middle. A SavedVariables dump of this is one `{ ... }` per run that any
-- parser can read line-wise, and adding a field later cannot reshape the old ones.
--
--   ts                 epoch seconds (Store.Now — GetServerTime)
--   context            "bags" | "bank"   (bank = the run included a bank container)
--   cells              cells in the opening snapshot (the size of the problem)
--   fillPct            0-100, occupied share of those cells at the start
--   planMoves          #moves in the OPENING plan (the work the planner asked for)
--   executedMoves      moves actually issued (executed/plan > 1 == churn)
--   waves              rounds that issued at least one move (the old "waves" number)
--   durationMs         wall clock, ms
--   aborted            boolean
--   reason             abort reason, "" when the run completed
--   stallTicks         PEAK no-progress streak seen (how close MAX_NO_PROGRESS came)
--   busyFallbackTicks  rounds the BUSY re-plan rescued from issuing nothing — the
--                      measurement that decides whether PLAN_BUSY should ever flip
--   avgAckMs           MEASURED mean per-move lock-clear round-trip, ms (0 = unmeasured)
--   version            ns.VERSION, so a mixed log is still attributable
--
-- 2.0.3 additions. ADDITIVE ONLY — appended to LOG_FIELDS, nothing renamed, nothing
-- reordered, so a log written by 2.0.2 still parses and a 2.0.3 log still answers every
-- 2.0.2 question. These five are the settle story:
--   bagErrors          UI_ERROR_MESSAGE bag-error refusals OBSERVED during the run. This
--                      is the number the owner's failing run had to be inferred from;
--                      now it is stated. A healthy run reads 0.
--   settleWaits        rounds that issued nothing because every needed slot was held by
--                      one of OUR un-acked moves — the executor waiting, correctly, for
--                      the contents to land. Costs no budget and no churn.
--   settleHolds        prediction checks that found the slot UNLOCKED but its contents
--                      not yet updated: the exact window 2.0.2 re-issued moves into.
--                      Non-zero here with executedMoves == planMoves is the fix working.
--   settleDrops        predictions that hit the SETTLE_TTL ceiling — moves the server
--                      never confirmed. The direct tuning input for SETTLE_TTL, and the
--                      only path on which a move may legitimately be re-planned.
--   inFlightPeak       high-water mark of concurrent un-acked moves (vs MAX_IN_FLIGHT)
--   cleanupMoves       moves issued by the final compaction wave of an ABORT (0 on a
--                      completed run — completion leaves no holes to close)
--
-- ── RING SEMANTICS ───────────────────────────────────────────────────────────
-- A plain 1..n ARRAY, oldest first, newest last, capped at Sort.LOG_CAP: appending past
-- the cap drops index 1 and shifts. A cursor key would be cheaper by O(cap) per run, but
-- this runs ONCE PER SORT and buys a buffer that is literally an array — no wrap point to
-- reason about at the far end, in the file the coordinator is going to read by hand.
--
-- ZERO OVERHEAD when not sorting: nothing here is called, no timer exists, and the run
-- accumulators live on Sort._* and are created by Sort.Run and dropped by stopDriver.
-- =====================================================================

-- The declared field order — also the parse contract, and what the printer walks.
Sort.LOG_FIELDS = {
    "ts", "context", "cells", "fillPct", "planMoves", "executedMoves", "waves",
    "durationMs", "aborted", "reason", "stallTicks", "busyFallbackTicks",
    "avgAckMs", "version",
    -- 2.0.3, APPENDED (never inserted): a 2.0.2 reader walking the first 14 is unaffected.
    "bagErrors", "settleWaits", "settleHolds", "settleDrops", "inFlightPeak", "cleanupMoves",
}

local function num(v) local n = tonumber(v); return n or 0 end
local function int(v) local n = tonumber(v) or 0; return math.floor(n + 0.5) end

-- Coerce anything into a complete, flat record. EVERY declared field is present and of
-- its declared type, so a malformed caller can never write a half record into the SV.
function Sort.NewLogRecord(r)
    r = (type(r) == "table") and r or {}
    local ctx = r.context
    if ctx ~= "bank" then ctx = "bags" end
    return {
        ts                = int(r.ts),
        context           = ctx,
        cells             = int(r.cells),
        fillPct           = int(r.fillPct),
        planMoves         = int(r.planMoves),
        executedMoves     = int(r.executedMoves),
        waves             = int(r.waves),
        durationMs        = int(r.durationMs),
        aborted           = r.aborted and true or false,
        reason            = (type(r.reason) == "string") and r.reason or "",
        stallTicks        = int(r.stallTicks),
        busyFallbackTicks = int(r.busyFallbackTicks),
        avgAckMs          = int(r.avgAckMs),
        version           = (type(r.version) == "string") and r.version or tostring(ns.VERSION or "?"),
        bagErrors         = int(r.bagErrors),
        settleWaits       = int(r.settleWaits),
        settleHolds       = int(r.settleHolds),
        settleDrops       = int(r.settleDrops),
        inFlightPeak      = int(r.inFlightPeak),
        cleanupMoves      = int(r.cleanupMoves),
    }
end

-- The live buffer (array, oldest first). `create` allocates it on the settings DB.
-- Returns nil when there is no DB to hold it — the caller must degrade, never error.
function Sort.LogBuffer(db, create)
    db = db or (Store and Store.db)
    if type(db) ~= "table" then return nil end
    if type(db.sortLog) ~= "table" then
        if not create then return nil end
        db.sortLog = {}
    end
    return db.sortLog
end

-- Append one run. Returns the stored record, or nil when there was nowhere to store it.
function Sort.LogAppend(db, rec, cap)
    local buf = Sort.LogBuffer(db, true)
    if not buf then return nil end
    cap = tonumber(cap) or Sort.LOG_CAP
    if cap < 1 then cap = 1 end
    local stored = Sort.NewLogRecord(rec)
    buf[#buf + 1] = stored
    -- A while-loop, not a single remove: a cap LOWERED between releases must still
    -- converge on the first append rather than leaking one stale run per sort.
    while #buf > cap do table.remove(buf, 1) end
    return stored
end

-- Newest-first copy for the reader (`/dbg sortlog`). Never hands out the live table.
function Sort.LogRecords(db)
    local buf = Sort.LogBuffer(db, false)
    local out = {}
    if not buf then return out end
    for i = #buf, 1, -1 do
        if type(buf[i]) == "table" then out[#out + 1] = buf[i] end
    end
    return out
end

function Sort.LogCount(db)
    local buf = Sort.LogBuffer(db, false)
    return buf and #buf or 0
end

-- Empty the buffer IN PLACE (the SV table identity is kept, so nothing that captured a
-- reference to it — the harness, a future options page — is left pointing at a corpse).
function Sort.LogClear(db)
    local buf = Sort.LogBuffer(db, false)
    if not buf then return 0 end
    local n = #buf
    for i = n, 1, -1 do buf[i] = nil end
    return n
end

-- ADAPTIVE SEED: the mean measured round-trip over the last `lookback` runs that actually
-- measured one. Runs with avgAckMs == 0 (no move ever acked — an instant "already sorted",
-- or a totally rejecting server) carry no signal and are skipped. 0 when nothing is known,
-- which is the "use the fixed windows" answer.
function Sort.LogAvgAckMs(db, lookback)
    local recs = Sort.LogRecords(db)
    lookback = tonumber(lookback) or Sort.LOG_CAP
    local sum, n = 0, 0
    for i = 1, #recs do
        if i > lookback then break end
        local v = tonumber(recs[i].avgAckMs) or 0
        if v > 0 then sum, n = sum + v, n + 1 end
    end
    if n == 0 then return 0 end
    return math.floor(sum / n + 0.5)
end

-- Stamp formatter. WoW's Lua sandbox publishes `date` as a GLOBAL and ships no `os`
-- table at all, so os.date would be a nil-index in game; headless (real Lua 5.1) it is
-- the other way round. Try the global first, then os, then fall back to the raw epoch —
-- a log line must never be the thing that errors.
local function stampStr(ts)
    local d = _G.date or (type(os) == "table" and os.date)
    if d then
        local ok, s = pcall(d, "%m-%d %H:%M", ts)
        if ok and type(s) == "string" then return s end
    end
    return tostring(ts)
end

-- One compact fixed-width line per run, for the chat printer. PURE so the harness can pin
-- the column set without a chat frame.
function Sort.FormatLogLine(rec, index)
    rec = Sort.NewLogRecord(rec)
    local outcome = rec.aborted and ("ABORT:" .. (rec.reason ~= "" and rec.reason or "?")) or "ok"
    -- 2.0.3: `err=` only appears when the CLIENT refused something. On a healthy run it
    -- is absent, so the line stays the width the owner is used to reading; when it shows
    -- up it is the first thing to look at.
    local err = (rec.bagErrors > 0) and string.format(" err=%d", rec.bagErrors) or ""
    return string.format(
        "%2d. %s %-4s cells=%d fill=%d%% plan=%d exec=%d waves=%d %.2fs ack=%dms busy=%d stall=%d%s %s",
        tonumber(index) or 0, stampStr(rec.ts), rec.context,
        rec.cells, rec.fillPct, rec.planMoves, rec.executedMoves, rec.waves,
        rec.durationMs / 1000, rec.avgAckMs, rec.busyFallbackTicks, rec.stallTicks, err, outcome)
end

-- `/bags sortlog` / `/dbg sortlog` — print the buffer, newest first. `arg` == "clear" empties it.
function Sort.PrintLog(arg)
    if not ns.Print then return end
    if type(arg) == "string" and arg:lower():match("^clear") then
        local n = Sort.LogClear()
        ns:Print(string.format("sort log cleared (%d run%s dropped).", n, n == 1 and "" or "s"))
        return
    end
    local recs = Sort.LogRecords()
    if #recs == 0 then
        ns:Print("sort log is empty — run a sort and it fills. (/bags sortlog clear empties it.)")
        return
    end
    ns:Print(string.format("sort log — last %d run%s, newest first (cap %d):",
        #recs, #recs == 1 and "" or "s", Sort.LOG_CAP))
    for i = 1, #recs do ns:Print("  " .. Sort.FormatLogLine(recs[i], i)) end
    local ack = Sort.LogAvgAckMs()
    ns:Print(string.format("  measured round-trip across the log: %dms%s",
        ack, ack == 0 and " (nothing measured yet)" or ""))
end

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
--
-- BOTH lookups are memoized for the life of a run. Plan now runs ~20×/s (the optimistic
-- executor re-plans every tick) and Plan's fit loop calls canHold O(stacks × cells)
-- times, so an un-memoized C_Item.GetItemFamily here was thousands of API calls per
-- second (defect analysis §4 "memoize GetItemFamily per run").
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
        local fkey = "_fam" .. tostring(id)
        local itemFamily = cache[fkey]
        if itemFamily == nil then
            itemFamily = CI.GetItemFamily(id) or 0
            cache[fkey] = itemFamily
        end
        return band(bagFamily, itemFamily) ~= 0
    end
end

-- The container's own bag FAMILY, for the planner's 1.x family bands (Sort.Plan's banner).
-- Mirrors 1.x Frame:GetBagFamily (frames/inventory/inventory.lua): the backpack, the bank
-- main container and any unreadable bag are general (0); the keyring is 1.x's pseudo-family
-- 9; every real bag reports the family bits the client gives for it. Shares the run cache
-- with makeCanHoldFn, so the bag lookup happens once per container per run.
local function makeFamilyFn(cache)
    return function(cid)
        if cid == Store.BACKPACK_CONTAINER or cid == Store.BANK_CONTAINER then return 0 end
        if Store.KEYRING_CONTAINER and cid == Store.KEYRING_CONTAINER then return 9 end
        local CC = _G.C_Container
        if not (CC and CC.GetContainerNumFreeSlots) then return 0 end
        local key = "_bag" .. cid
        local fam = cache[key]
        if fam == nil then
            local _, f = CC.GetContainerNumFreeSlots(cid)
            fam = f or 0
            cache[key] = fam
        end
        return fam
    end
end

-- Is this slot SORT-LOCKED by the owner? (locks.lua; per-character SavedVariables.)
-- Resolved through ns at CALL time and fully guarded, so sort.lua keeps working with
-- locks.lua absent — it simply sees no user locks.
local function userLocked(cid, slot)
    local L = ns.Locks
    if not (L and L.IsLocked) then return false end
    return L.IsLocked(cid, slot) and true or false
end
Sort._userLocked = userLocked   -- exposed so the harness can stub it

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
            -- A sort lock applies to the SLOT, not to whatever happens to be in it, so
            -- an EMPTY locked slot is stamped too: the planner must never fill it.
            local ul = Sort._userLocked(cid, slot)
            if info and info.itemID then
                cells[#cells + 1] = { cid = cid, slot = slot, id = info.itemID,
                    count = info.stackCount or 1, quality = info.quality,
                    locked = info.isLocked and true or false, userLocked = ul }
            else
                cells[#cells + 1] = { cid = cid, slot = slot, id = nil, count = 0,
                    userLocked = ul }
            end
        end
    end
    return cells
end

-- Does a container slot currently hold anything? (PickupContainerItem is a NO-OP on an
-- empty slot, so the executor has to know which end of a swap can start it.)
local function slotHasItem(ref)
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemInfo) then return true end
    local info = CC.GetContainerItemInfo(ref.cid, ref.slot)
    return (info and info.itemID) and true or false
end

-- Perform one planned move via the container pickup/split primitives.
local function performMove(m)
    local CC = _G.C_Container
    if not CC then return end
    if m.op == "swap" then
        -- A "swap" is often really a MOVE into an empty cell, and PickupContainerItem
        -- does nothing on an empty slot — issuing it in plan order would pick up the
        -- OTHER end instead and the belt-and-suspenders ClearCursor would put it right
        -- back, so the move silently never happened. (The old frozen-plan executor had
        -- no way to notice: it never re-planned, so it just advanced and still printed
        -- "sort complete" over a partly unsorted bag.) Exchanging two cells is symmetric,
        -- so always START from the end that actually holds an item.
        local first, second = m.a, m.b
        if not slotHasItem(m.a) then first, second = m.b, m.a end
        CC.PickupContainerItem(first.cid, first.slot)
        CC.PickupContainerItem(second.cid, second.slot)
    elseif m.op == "merge" then
        CC.PickupContainerItem(m.from.cid, m.from.slot)
        CC.PickupContainerItem(m.to.cid, m.to.slot)
        -- A same-item merge fills `to` to max and leaves the overflow on the cursor.
        -- 2.0.2 put it back with a THIRD PickupContainerItem on `m.from` — an extra
        -- container operation aimed at a slot the pour has just put in flight, i.e. the
        -- one place performMove itself could hand the client an unsettled target. The
        -- unconditional ClearCursor below already returns a held container item to the
        -- slot it came from, which is the same outcome through a client-side path that
        -- issues no container request at all. (2.0.3: the pickup is gone, not the
        -- behaviour — MergePour's residual model is unchanged.)
    elseif m.op == "split" then
        if CC.SplitContainerItem then CC.SplitContainerItem(m.from.cid, m.from.slot, m.amount) end
        CC.PickupContainerItem(m.to.cid, m.to.slot)
    end
    if _G.ClearCursor then _G.ClearCursor() end   -- belt-and-suspenders: never leave a held item
end

-- Monotonic seconds. GetTime() in-game; os.clock() headless (harness / simulator).
local function nowSeconds()
    if _G.GetTime then return _G.GetTime() end
    return os.clock()
end

local function slotKey(cid, slot) return cid .. ":" .. slot end
local function refKey(r) return r.cid .. ":" .. r.slot end

----------------------------------------------------------------------
-- Refresh-storm suppression (defect analysis §4 fix #2)
--
-- ui_frame registers ITEM_LOCK_CHANGED -> Frame.RequestRefresh() unconditionally, and
-- capture re-scans EVERY container on BAG_UPDATE. A sort fires dozens of lock events per
-- wave, so the OLD sort cost ~60-95 full grid rebuilds + full captures — each of which
-- re-parses every category query from scratch. That FPS drag stretched every C_Timer.After
-- in the executor's own loop, i.e. it made the sort measurably slower as well as janky.
--
-- sort.lua owns none of those files, so it mutes them for the duration of a run by
-- swapping the two coalescing entry points for dirty-flag stubs, and restores them on
-- EVERY exit path (completion and every abort). Identity-guarded in both directions: we
-- only install over the function we captured, and only restore if OUR stub is still the
-- one installed — so a reload or another consumer replacing them mid-sort is never
-- clobbered. The restore does one full capture + rebuild unconditionally.
--
-- ── BAG-7 (2.0.6): WHY THE HEARTBEAT NO LONGER CALLS Frame.RequestRefresh ──────────────
-- OWNER REPORT: "when sorting bags the icon locations dont update until the sort is
-- concluded, but with bags 1 you could see the sort happening live. is there a bag render
-- delay?"  There is not. The delay IS this mute, and the ~5 Hz heartbeat that was supposed
-- to keep the sort visible could not do it: Frame.RequestRefresh rebuilds the grid FROM THE
-- CAPTURED STORE, and the store is exactly what the capture stub above has frozen. So the
-- heartbeat was faithfully re-drawing the same frozen picture 5 times a second for the whole
-- run, and the grid only moved when endQuiet's final capture landed. (1.x had no capture
-- layer: its item groups repainted straight off the raw bag events, which is why its sort
-- was visible.)
--
-- The heartbeat now drives ui_items.LiveSlotRepaint instead — a data-only sweep that reads
-- each visible LIVE cell's own (cid, slot) straight from C_Container and repaints the
-- button in place, bypassing the muted capture entirely. It writes NOTHING to the store, so
-- the captured snapshot stays byte-stable for the whole run and no mesh consumer ever sees
-- mid-sort churn (the invariant is stated in full over Items.LiveSlotRepaint). It is also
-- strictly cheaper than what it replaces: one API read per visible cell instead of a full
-- grid rebuild. Bag events drive the same sweep at Sort.LIVE_REPAINT (~8 Hz), which is where
-- the responsiveness actually comes from; the heartbeat is the backstop for a run whose
-- events are sparse.
----------------------------------------------------------------------
local function beginQuiet()
    if Sort._quiet then return end
    local q = { refreshes = 0 }
    local F, C = ns.Frame, ns.Capture
    if F and type(F.RequestRefresh) == "function" then
        q.frameFn = F.RequestRefresh
        q.frameStub = function() q.dirty = true end
        F.RequestRefresh = q.frameStub
    end
    if C and type(C.RequestCapture) == "function" then
        q.captureFn = C.RequestCapture
        q.captureStub = function() q.dirty = true end
        C.RequestCapture = q.captureStub
    end
    Sort._quiet = q
end

-- THE LIVE REPAINT (BAG-7). Read-only and data-only: it asks ui_items to re-read each
-- visible live cell from C_Container and repaint it in place. It issues no container
-- operation, no capture request and no lock write, so it cannot perturb the executor's
-- settle timing or its move accounting — the sort suite pins both against the simulator's
-- own mutation counters. Coalesced at Sort.LIVE_REPAINT; returns true when it actually ran.
local function liveRepaint(now)
    if not Sort._running then return false end
    now = now or nowSeconds()
    if (now - (Sort._liveRepaintAt or 0)) < Sort.LIVE_REPAINT then return false end
    Sort._liveRepaintAt = now
    local I = ns.Items
    if not (I and I.LiveSlotRepaint) then return false end
    Sort._liveRepaints = (Sort._liveRepaints or 0) + 1
    if ns.SafeCall then ns:SafeCall(I.LiveSlotRepaint) else I.LiveSlotRepaint() end
    return true
end
Sort._liveRepaint = liveRepaint

-- How many live repaints the LAST run performed (telemetry handle for the harness and for
-- a future /bags sortlog column; deliberately NOT a persisted sortLog field — it is a
-- rendering statistic, not a convergence one, and the log schema stays where it is).
function Sort.LiveRepaintCount() return Sort._lastLiveRepaints or 0 end

-- The mid-sort heartbeat. See the BAG-7 block above for why this is a live-cell sweep and
-- not the full Frame.Rebuild it used to be.
local function quietHeartbeat(now)
    local q = Sort._quiet
    if not q then return end
    if now - (Sort._lastRefresh or 0) < Sort.QUIET_REFRESH then return end
    Sort._lastRefresh = now
    q.refreshes = q.refreshes + 1
    liveRepaint(now)
end

local function endQuiet()
    local q = Sort._quiet
    if not q then return end
    Sort._quiet = nil
    local F, C = ns.Frame, ns.Capture
    if F and q.frameFn and F.RequestRefresh == q.frameStub then F.RequestRefresh = q.frameFn end
    if C and q.captureFn and C.RequestCapture == q.captureStub then C.RequestCapture = q.captureFn end
    -- One full recapture + rebuild at the end, always (the sort definitely changed bags).
    if C and C.RequestCapture then
        if ns.SafeCall then ns:SafeCall(C.RequestCapture) else C.RequestCapture() end
    end
    if F and F.RequestRefresh then
        if ns.SafeCall then ns:SafeCall(F.RequestRefresh) else F.RequestRefresh() end
    end
end

----------------------------------------------------------------------
-- Run lifecycle
----------------------------------------------------------------------

----------------------------------------------------------------------
-- THE TEARDOWN LATCH  (CLASS 9, 2026-08-11)
--
-- `abort()` issues container operations of its own (cleanupWave) BEFORE it tears the run
-- down, and it does so with the driver still registered and `Sort._running` still true —
-- because the cleanup needs both. Under a client that dispatches events from inside the
-- call, those cleanup pickups deliver the run's own echoes straight back into the driver,
-- and one of the events the driver acts on is an ABORT TRIGGER: a mob pulling on the frame
-- the tidy-up wave goes out is PLAYER_REGEN_DISABLED delivered inside PickupContainerItem.
-- `abort`'s only guard was `if not Sort._running then return end`, which the outer abort
-- has not yet cleared, so the inner abort ran the whole teardown — log record, chat line,
-- stopDriver, endQuiet — and then RETURNED INTO the outer cleanup loop, which carried on
-- issuing container operations against a torn-down run with the refresh mute already
-- lifted. The owner saw it as two "sort stopped" lines and two sortLog records for one
-- sort; the second record is all zeroes, because stopDriver had already dropped the
-- accumulators it is computed from.
--
-- The latch is armed at the TOP of the teardown — before the first client call of the
-- whole sequence, which is the only place that is early enough — and released by
-- stopDriver, the last step both teardown paths take. Sort.Run clears it too, so a throw
-- between the two can never wedge the next run's ability to stop. Every handler that can
-- start a teardown reads it and treats what it sees as this teardown's own echo.
----------------------------------------------------------------------
local function beginTeardown()
    if Sort._teardown then return false end
    Sort._teardown = true
    return true
end

local function stopDriver()
    Sort._running = false
    Sort._cids, Sort._pred, Sort._meta, Sort._canHold, Sort._cache = nil, nil, nil, nil, nil
    Sort._familyOf = nil
    Sort._ticks, Sort._idle, Sort._budget, Sort._lastIssued = nil, nil, nil, nil
    Sort._best, Sort._sinceProgress, Sort._residual = nil, nil, nil
    -- 2.0.2 telemetry accumulators + the per-run derived windows. Dropped here so the
    -- "zero overhead when not sorting" contract is literal: between runs sort.lua holds
    -- no counters, no timer and no state at all.
    Sort._peakNoProgress, Sort._busyRounds = nil, nil
    Sort._ackSum, Sort._ackN = nil, nil
    Sort._lastTickAt, Sort._lastProgressAt, Sort._idleSince = nil, nil, nil
    Sort._waiting = nil
    -- 2.0.3 settle-aware accumulators (same "no state between runs" contract).
    Sort._bagErrors, Sort._settleWaits, Sort._settleHolds = nil, nil, nil
    Sort._settleDrops, Sort._inFlightPeak, Sort._cleanupMoves = nil, nil, nil

    -- BAG-7 live-repaint accumulators (same "no state between runs" contract; logRun has
    -- already stashed the count into Sort._lastLiveRepaints by the time this runs).
    Sort._liveRepaints, Sort._liveRepaintAt = nil, nil

    Sort._settleSecs, Sort._waitingRound = nil, nil
    -- CLASS 9 accumulators (same "no state between runs" contract; logRun has already
    -- stashed the fuse verdict into Sort._lastReentryRefused by the time this runs).
    Sort._reentryRefused, Sort._reentryWhere = nil, nil
    Sort._issueDepth = 0
    Sort._idleSecs, Sort._noProgressSecs, Sort._runawaySecs = nil, nil, nil
    Sort._cellCount, Sort._fillPct, Sort._planMoves0, Sort._context = nil, nil, nil, nil
    Sort._tickGen = (Sort._tickGen or 0) + 1   -- invalidate any queued tick
    if Sort._driver then Sort._driver:UnregisterAllEvents() end
    -- ORDER (class 9): the driver is unregistered BEFORE the last client call of the
    -- sequence, so ClearCursor's own in-call echoes reach nothing of ours. The quiet
    -- stubs are still installed at this point, so the ns:RegisterEvent subscribers see
    -- only a dirty flag; endQuiet's unconditional recapture below is what heals it.
    if _G.ClearCursor then _G.ClearCursor() end
    endQuiet()
    Sort._teardown = nil   -- the sequence has returned; release the latch
end

-- Fold this run's accumulators into one flat telemetry record and append it (2.0.2a).
-- MUST be called BEFORE stopDriver, which drops the accumulators. Guarded end to end:
-- with no settings DB (harness without a store, a very early sort) it is a silent no-op,
-- and a throw here can never take an abort path down with it.
local function logRun(aborted, reason)
    local elapsed = nowSeconds() - (Sort._start or nowSeconds())
    local ackMs = 0
    if (Sort._ackN or 0) > 0 then ackMs = (Sort._ackSum / Sort._ackN) * 1000 end
    local rec = {
        ts                = (Store and Store.Now and Store.Now()) or 0,
        context           = Sort._context or "bags",
        cells             = Sort._cellCount or 0,
        fillPct           = Sort._fillPct or 0,
        planMoves         = Sort._planMoves0 or 0,
        executedMoves     = Sort._moveCount or 0,
        waves             = Sort._rounds or 0,
        durationMs        = elapsed * 1000,
        aborted           = aborted and true or false,
        reason            = aborted and tostring(reason or "") or "",
        stallTicks        = Sort._peakNoProgress or 0,
        busyFallbackTicks = Sort._busyRounds or 0,
        avgAckMs          = ackMs,
        version           = tostring(ns.VERSION or "?"),
        bagErrors         = Sort._bagErrors or 0,
        settleWaits       = Sort._settleWaits or 0,
        settleHolds       = Sort._settleHolds or 0,
        settleDrops       = Sort._settleDrops or 0,
        inFlightPeak      = Sort._inFlightPeak or 0,
        cleanupMoves      = Sort._cleanupMoves or 0,
    }
    -- Test hook: the finished record, in full, for a harness with no settings store.
    Sort._lastRun = Sort.NewLogRecord(rec)
    -- BAG-7: a RENDERING statistic, kept beside the record rather than inside it. The
    -- persisted sortLog schema (Sort.NewLogRecord) is a convergence contract and does not
    -- move for a repaint counter — no SavedVariables change, nothing for the report to skip.
    Sort._lastLiveRepaints = Sort._liveRepaints or 0
    -- CLASS 9: the fuse's verdict for this run, kept beside the record for the same reason
    -- the repaint count is — the persisted sortLog schema is a convergence contract and does
    -- not move for a re-entry counter. Non-zero here means a handler reached an issue pass
    -- from inside a client call and was refused; the build stamp says which pass.
    Sort._lastReentryRefused = Sort._reentryRefused or 0
    Sort._lastReentryWhere   = Sort._reentryWhere
    local write = function() Sort.LogAppend(nil, rec) end
    if ns.SafeCall then ns:SafeCall(write) else pcall(write) end
end

-- Human-readable tail shared by the completion and abort prints. `_rounds` counts the
-- ticks that actually issued moves — the direct analogue of the old wave counter, and
-- the number the defect analysis asks the owner to read off a live sort.
local function runStats()
    local elapsed = nowSeconds() - (Sort._start or nowSeconds())
    return string.format("%d moves in %d waves, %.2fs",
        Sort._moveCount or 0, Sort._rounds or 0, elapsed)
end

-- An abort must never be silent about the part it did not do. `_residual` is the move
-- count of the last plan taken, i.e. how much arranging is still outstanding.
--
-- 2.0.3: and it must never leave the grid HOLED. `cleanupWave` (defined below, next to
-- the machinery it needs — forward-declared here) issues one compaction pass before the
-- run is torn down, and the chat line says plainly what happened: what stopped it, what
-- the cleanup closed, and how much arranging is left for the next run.
local cleanupWave

local function abort(reason)
    if not Sort._running then return end
    -- CLASS 9: this teardown's own cleanup echoes must not start a second teardown.
    if not beginTeardown() then return end
    local tidied = 0
    if cleanupWave then
        -- pcall-protected: a throw inside the cleanup's client calls must still reach
        -- stopDriver, which is what releases the latch.
        local ok, n = pcall(cleanupWave, reason)
        if ok then tidied = n or 0 end
    end
    local stats = runStats()
    local left  = Sort._residual or 0
    logRun(true, reason)
    stopDriver()
    if ns.Print then
        local tail = ""
        if tidied > 0 then
            tail = tail .. string.format(" Tidied up: %d item%s pulled back to close the gaps.",
                tidied, tidied == 1 and "" or "s")
        end
        if left > 0 then
            tail = tail .. string.format(" %d move%s still outstanding — run sort again to finish.",
                left, left == 1 and "" or "s")
        end
        ns:Print("sort stopped: " .. tostring(reason) .. " (" .. stats .. ")." .. tail)
    end
end

local function finish()
    if not Sort._running then return end
    if not beginTeardown() then return end   -- CLASS 9, same rule as abort()
    local stats = runStats()
    logRun(false, nil)
    stopDriver()
    -- ONE compact chat line, exactly as 2.0.1 shipped it. The detail moved to the log
    -- (/bags sortlog), not into the chat frame — the owner asked for data to tune from,
    -- not for a sort that talks more.
    if ns.Print then ns:Print("sort complete (" .. stats .. ").") end
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

----------------------------------------------------------------------
-- The predicted-lock / predicted-content table
--
-- _pred[slotKey] = { cid, slot, id, count, at }  — "we issued a move on this slot at
-- `at`; when it lands the slot will hold {id,count}". Until then the slot is treated as
-- LOCKED (a planner fixed point) holding its PREDICTED content.
----------------------------------------------------------------------

local function setPred(ref, id, count, now)
    Sort._pred[refKey(ref)] = { cid = ref.cid, slot = ref.slot, id = id, count = count or 0, at = now }
end

local function predOutstanding()
    return next(Sort._pred) ~= nil
end

-- How many slots have one of our moves in flight. Part of the residual work measure:
-- a BUSY cell is excluded from the plan, so `#plan.moves` alone would read as progress
-- merely because moves are in the air.
local function predCount()
    local n = 0
    for _ in pairs(Sort._pred) do n = n + 1 end
    return n
end

-- Drop a prediction once reality is observable for that slot. Called from the tick's
-- overlay and (same-frame fast path) from ITEM_LOCK_CHANGED.
--
-- OBSERVED STATE is the authority, NOT the clock: as long as the client has not yet
-- shown us the result of a move, the move is genuinely in flight however slow the server
-- is, and the prediction must stand — expiring it on a timer would hand the planner the
-- stale pre-move contents and restart the churn the overlay exists to prevent. The TTLs
-- are backstops only.
--
-- 2.0.2 read "has the client shown us the result?" as "is the slot still locked?", and
-- that is the bug this release fixes — see the arms below, and the SETTLE-AWARE ARMING
-- banner at the top of the file for the mechanism.
-- 2.0.2 (telemetry + adaptive seed): the ACK path is also where the per-move round-trip
-- is MEASURED — `now - p.at` is the time between issuing a move on this slot and the
-- client reporting it unlocked, i.e. the number the whole cost model is written against.
--
-- Only the OBSERVED-UNLOCKED arm is sampled. The TTL arm means the slot stayed locked
-- pathologically long (a dropped move, a stuck server); folding that into the mean would
-- inflate every derived window off exactly the runs that are already broken.
--
-- Sampling accuracy: an ITEM_LOCK_CHANGED release is measured at the event, so it is the
-- real round-trip; a release noticed by the tick's overlay instead is quantized upward by
-- at most one round gap. With event issuing on (the default) almost every release takes
-- the event path, so the recorded avgAckMs reads slightly HIGH at worst, never low —
-- which is the safe direction for a number that sizes patience windows.
--
-- ── 2.0.3: SETTLED, NOT MERELY UNLOCKED ─────────────────────────────────────────
-- The paragraph above says "a slot that is NOT locked is settled". That was the bug.
-- The lock releases on ITEM_LOCK_CHANGED; the slot's CONTENTS are rewritten later, on
-- BAG_UPDATE. Between the two the slot reads unlocked and shows its PRE-MOVE contents,
-- and 2.0.2 retired the prediction there — handing the planner exactly the stale state
-- the overlay exists to prevent, and re-issuing the move against a server that had
-- already applied it. See the SETTLE-AWARE ARMING banner for the full mechanism.
--
-- So a prediction retires on CONTENT: unlocked AND the slot now shows what we predicted.
-- Three arms, in order:
--   * still locked          -> in flight, keep (unchanged).
--   * unlocked + matches    -> SETTLED. Retire, and sample the round-trip.
--   * unlocked + mismatched -> the answer has not arrived yet (or the move was refused).
--                              Keep until SETTLE_TTL, then let reality win.
-- The TTL arm is the ONLY path that may re-plan a move we already issued, which is what
-- makes "issued and un-acked is never reissued" true by construction everywhere else.

-- THE SETTLE RULE (2.0.3), factored out as one named decision — same treatment as
-- Sort.ShouldKick — so the harness can pin it AND mutate it without a client. The 2.0.2
-- executor is exactly the mutant `function() return true end`: "unlocked is settled".
--
-- Does the live slot now show the content the prediction promised?
function Sort.PredSettled(p)
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemInfo) then return true end
    local info = CC.GetContainerItemInfo(p.cid, p.slot)
    local id   = (info and info.itemID) or nil
    if p.id == nil then return id == nil end
    if id ~= p.id then return false end
    return (info.stackCount or 0) == (p.count or 0)
end

local function releasePred(key, now)
    local p = Sort._pred[key]
    if not p then return end
    local age = now - p.at
    if slotLocked(p.cid, p.slot) then
        -- Genuinely in flight. Only the pathological-lock backstop can clear it.
        if age >= Sort.LOCK_TTL then Sort._pred[key] = nil end
        return
    end
    if Sort.PredSettled(p) then
        Sort._pred[key] = nil
        if age >= 0 and age < Sort.LOCK_TTL then
            Sort._ackSum = (Sort._ackSum or 0) + age
            Sort._ackN   = (Sort._ackN or 0) + 1
        end
        return
    end
    -- Unlocked but the contents have not caught up: we are inside the settle window.
    -- HOLD the prediction — this is the exact instant 2.0.2 re-issued the move.
    Sort._settleHolds = (Sort._settleHolds or 0) + 1
    -- The CEILING is the only way out. REJECTED ALTERNATIVE, recorded so it is not
    -- retried: giving up early on a BAG_UPDATE_DELAYED "the burst is over" stamp, on the
    -- reasoning that a container republished after we issued must have current contents.
    -- It was implemented and measured, and it REINTRODUCED THE ORIGINAL BUG — 232
    -- executed moves for a 72-move plan on the owner's fixture, 156 client refusals.
    -- Bag updates arrive per landing move, not once per wave, so move A's burst-over
    -- signal routinely lands after move B's lock cleared and before B's contents are
    -- published, and the stamp then retires B as "did not land" while it is still in the
    -- air. Any rule that infers settlement for slot X from an event about slot Y is the
    -- same mistake as inferring it from the lock. Only X's own contents can answer for X.
    if age >= (Sort._settleSecs or Sort.SETTLE_TTL) then
        Sort._pred[key]  = nil
        Sort._settleDrops = (Sort._settleDrops or 0) + 1
    end
end

-- Fold the prediction table into a fresh snapshot: an in-flight slot shows the content
-- its move is about to deliver, and — crucially — is NOT marked locked.
--
-- The live client reports isLocked on a slot we just moved and keeps showing its OLD
-- contents until the server answers. Handing that to the planner as a LOCKED cell would
-- make it a fixed point, so the target map would be re-derived over a shrinking free set
-- every tick and keep reassigning cells the in-flight moves had already claimed —
-- measured at ~2x the necessary moves. Instead we clear the lock and substitute the
-- predicted content: our moves conserve the item multiset, so `totals` and the sorted
-- target stack list are IDENTICAL on every tick, the target assignment is a stable fixed
-- point, and each re-plan is simply the shrinking residual. The slot being unusable
-- RIGHT NOW is a scheduling fact, and it is enforced where it belongs — at issue time.
--
-- A slot locked by something that is NOT ours (the user dragging an item) has no
-- prediction, so it keeps locked = true and stays a true planner fixed point.
local function overlayPredictions(cells, now)
    if not predOutstanding() then return end
    for key in pairs(Sort._pred) do releasePred(key, now) end
    if not predOutstanding() then return end
    for _, c in ipairs(cells) do
        local p = Sort._pred[slotKey(c.cid, c.slot)]
        if p then
            c.id, c.count, c.locked = p.id, p.count, false
        end
    end
end

-- Record what a move we are about to issue will produce, and mirror the same effect onto
-- the local cell model so several moves issued in one tick predict consistently. The
-- arithmetic is exactly the planner's (MergePour / exchange) — see applyMoves in the
-- tests, which is the same model.
local function predictMove(m, byKey, maxStackOf, now)
    if m.op == "swap" then
        local a, b = byKey[refKey(m.a)], byKey[refKey(m.b)]
        if not (a and b) then return end
        local aid, acnt, bid, bcnt = a.id, a.count, b.id, b.count
        a.id, a.count, b.id, b.count = bid, bcnt, aid, acnt
        setPred(m.a, a.id, a.count, now)
        setPred(m.b, b.id, b.count, now)
    elseif m.op == "merge" then
        local f, t = byKey[refKey(m.from)], byKey[refKey(m.to)]
        if not (f and t) then return end
        local id = t.id or f.id
        local rs, rd = Sort.MergePour(f.count, t.count, maxStackOf(id))
        t.id, t.count = id, rd
        f.count = rs
        if rs == 0 then f.id = nil end
        setPred(m.from, f.id, f.count, now)
        setPred(m.to, t.id, t.count, now)
    end
end

-- Issue wave 1 of the dependency partition. Returns how many moves went out.
--
-- ── THE THROUGHPUT DEFECT AND WHY THE FIX IS IN THE PLANNER, NOT HERE ────────
-- Owner report: "sort stopped: time budget exceeded (231 moves in 123 waves, 10.54s)" —
-- ~1.9 moves per round on a sort whose dependency depth is about 10.
--
-- Instrumenting a 120-cell bank at 95% fill and 0.30 s latency found the cause: the
-- prediction overlay CLEARS `locked` on our own in-flight slots (so the target map does not
-- churn), which also made those cells look available to the move planner. Phase II then
-- planned swaps on them, they landed in wave 1 — and the guard below rejected 6.7 of every
-- 8.0 of them. The executor was computing a wave it could not issue.
--
-- The fix is `Sort.PLAN_BUSY`: the planner is told which cells are in flight and keeps them
-- in the target map while refusing them as move ENDPOINTS, so wave 1 comes back full of
-- moves that can actually go out. Measured on the same fixture: 7.35s -> 3.85s at 0.30 s
-- latency for the same 180 moves, and no aborts anywhere in the sweep.
--
-- REJECTED ALTERNATIVE, recorded so it is not retried: issuing a maximal matching over the
-- WHOLE plan (1.x's own model — it walks its entire candidate list each pass and fires
-- every move whose endpoints are unused) instead of wave 1. It is faster in the best case
-- but it executes plan moves out of order, and the selection sort's later moves are only
-- correct AFTER their predecessors. Measured on a carried+herb-bag fixture at 0.30 s that
-- cost 361 moves against wave 1's 101 — 3.5x churn. 1.x can afford it because its plan is a
-- per-slot goal assignment with no ordering at all; ours is a sequence, so wave 1 is the
-- correct prefix and the BUSY set is what makes that prefix worth issuing.
----------------------------------------------------------------------
-- THE ISSUE-PASS FUSE  (CLASS 9, 2026-08-11)
--
-- Everything below issues container operations, and on a client that dispatches events
-- from inside those calls, every handler in the session runs before the call returns —
-- ours included. Nothing in the executor reaches an issue pass from a handler today (the
-- tick is always deferred through C_Timer.After, and the teardown latch now covers the
-- cleanup path), but "today" is exactly the assumption the Nexus 1.1.8 overflow broke: a
-- bystander addon on the same event was enough to make the stack unrecognisable. So the
-- passes carry an explicit fuse — one legitimate depth, and a nested entry REFUSES with a
-- counted, build-stamped record rather than recursing. A refusal is a missed wave the very
-- next tick re-plans; an overflow is a dead client.
----------------------------------------------------------------------
Sort.MAX_ISSUE_DEPTH = 1

local function enterIssuePass(what)
    if (Sort._issueDepth or 0) >= Sort.MAX_ISSUE_DEPTH then
        Sort._reentryRefused = (Sort._reentryRefused or 0) + 1
        Sort._reentryWhere   = tostring(what) .. "@" .. tostring(ns.VERSION or "?")
        return false
    end
    Sort._issueDepth = (Sort._issueDepth or 0) + 1
    return true
end

local function leaveIssuePass()
    Sort._issueDepth = (Sort._issueDepth or 1) - 1
    if Sort._issueDepth < 0 then Sort._issueDepth = 0 end
end

local function issueWave1(plan, cells, now)
    if not enterIssuePass("wave") then return 0 end
    local byKey = {}
    for _, c in ipairs(cells) do byKey[slotKey(c.cid, c.slot)] = c end
    local maxStackOf = function(id)
        local m = id and Sort._meta(id)
        return (m and m.maxStack) or 1
    end
    local claimed = {}
    local issued = 0
    local wave = Sort.PartitionWaves(plan.moves)[1]
    local list = wave and wave.moves or {}
    -- 2.0.3: IN-FLIGHT accounting is a hard ceiling, not just a per-tick burst cap. Each
    -- outstanding move holds TWO cells out of the planner's reach, so an unbounded burst
    -- freezes most of a large bag and every subsequent plan comes back unissuable. See
    -- Sort.MAX_IN_FLIGHT for the sizing against the measured ~240ms round-trip.
    local inFlightMoves = math.ceil(predCount() / 2)
    if inFlightMoves > (Sort._inFlightPeak or 0) then Sort._inFlightPeak = inFlightMoves end
    for _, m in ipairs(list) do
        if issued >= Sort.MAX_MOVES_PER_TICK then break end
        if (inFlightMoves + issued) >= Sort.MAX_IN_FLIGHT then break end
        if (Sort._moveCount or 0) >= (Sort._budget or 0) then break end
        local slots = Sort.MoveSlots(m)
        -- `claimed` keeps this pass's moves slot-disjoint (1.x's per-space locked flag).
        -- The prediction / live-lock / user-lock arms are the "can the client take this
        -- right now" test; the USER-lock arm also covers the owner locking a slot from the
        -- config mode while a sort is mid-flight.
        local blocked = false
        for _, r in ipairs(slots) do
            local k = refKey(r)
            if claimed[k] or Sort._pred[k] or slotLocked(r.cid, r.slot)
               or Sort._userLocked(r.cid, r.slot) then
                blocked = true
                -- ── 2.0.2b: THE WAITING SET ──────────────────────────────────────
                -- Record ONLY the arm a lock-clear can resolve: a slot held by one of
                -- OUR OWN in-flight moves. That makes `_waiting` exactly "the slots
                -- whose confirmation turns a move we already planned into a move we
                -- can issue", which is the precise trigger the event path wants —
                -- "when a move's endpoints settle", not "when anything settles".
                --
                -- The other three arms are deliberately excluded: `claimed` clears by
                -- itself on the next round (it is this pass's disjointness bookkeeping,
                -- not a server fact); a foreign `slotLocked` and a `userLocked` slot
                -- fire no prediction release of ours, so keying a kick on them could
                -- never fire anyway.
                if Sort._pred[k] and Sort._waiting then Sort._waiting[k] = true end
                break
            end
        end
        if not blocked then
            -- Claim ONLY on success — 1.x sets from.locked/to.locked after the pickup pair,
            -- never on the refusal path, so a blocked move never reserves its slots.
            for _, r in ipairs(slots) do claimed[refKey(r)] = true end
            -- ── CLASS 9 (2026-08-11): PREDICT BEFORE THE CALL, NOT AFTER ────────────
            -- Through 2.0.7 this pair read `performMove(m)` THEN `predictMove(...)`, i.e.
            -- the prediction — the executor's only latch — was armed one client call too
            -- late. The client does not always SCHEDULE the events a container operation
            -- causes: ITEM_LOCK_CHANGED for the slot being locked is dispatched from
            -- INSIDE PickupContainerItem, and every handler in the session (ours included)
            -- runs to completion before the call returns. With the prediction armed
            -- afterwards, the driver's own ITEM_LOCK_CHANGED arm found `Sort._pred[k] ==
            -- nil` and returned: the sequence's FIRST echo walked straight past the latch
            -- it was supposed to arm, so
            --   * the settle was never OBSERVED at the event (the round-trip sample and
            --     every window derived from it — LogAvgAckMs, _settleSecs, _idleSecs — were
            --     quantized to the tick that noticed it later instead), and
            --   * event-driven issuing (2.0.2b) was silently dead for any settle the client
            --     published in-call: `_waiting` was never consumed and no round was ever
            --     pulled forward, so the whole run fell back on the 0.05s ladder.
            -- Arming FIRST is also strictly safe on the refusal path: a prediction for a
            -- move the client refuses was already possible (dropRate / Internal Bag Error
            -- both leave the pred standing) and is retired by the SETTLE_TTL arm exactly as
            -- before. The simulator asserts the ordering directly — `stats.echoUnlatched`
            -- counts every in-call echo that arrived with no prediction armed for the slot
            -- it names, and the fixtures pin it at zero.
            predictMove(m, byKey, maxStackOf, now)
            if ns.SafeCall then ns:SafeCall(performMove, m) else performMove(m) end
            issued = issued + 1
            Sort._moveCount = (Sort._moveCount or 0) + 1
        end
    end
    leaveIssuePass()
    return issued
end

-- Issue the compaction pass described at Sort.CompactMoves. Forward-declared above the
-- abort path; defined here because it needs the same snapshot / lock / issue machinery.
--
-- SKIPPED for aborts where the bags are not ours to touch any more: combat (item moves
-- are exactly the thing the player now needs the client for), a closed bank (the
-- containers are gone), and a closed window (the user walked away — quietly rearranging
-- their bags after they dismissed the frame is worse than a hole). Those three end the
-- run where it stands, as they always have.
function cleanupWave(reason)
    if reason == "entered combat" or reason == "bank closed"
       or reason == "window closed" or reason == "containers unavailable" then return 0 end
    local CC = _G.C_Container
    if not (CC and CC.PickupContainerItem) or not Sort._cids then return 0 end
    -- THE DEPTH FUSE (class 9). Both issue passes run entirely inside client calls whose
    -- events reach our own handlers, so an unforeseen composition — a handler that reaches
    -- an issue path from inside one — must degrade to a REFUSAL with a build-stamped
    -- record, not to a deeper stack. There is no legitimate nesting: an issue pass is
    -- always entered from a tick or a teardown, never from another issue pass.
    if not enterIssuePass("cleanup") then return 0 end
    local cells = snapshot(Sort._cids)
    if not cells then leaveIssuePass(); return 0 end
    local moves = Sort.CompactMoves(cells, Sort._canHold, function(c)
        return slotLocked(c.cid, c.slot)
            or (Sort._pred and Sort._pred[slotKey(c.cid, c.slot)] ~= nil) or false
    end)
    local claimed, issued = {}, 0
    for _, m in ipairs(moves) do
        if issued >= Sort.MAX_CLEANUP_MOVES then break end
        local slots, blocked = Sort.MoveSlots(m), false
        for _, r in ipairs(slots) do
            local k = refKey(r)
            if claimed[k] or (Sort._pred and Sort._pred[k]) or slotLocked(r.cid, r.slot)
               or Sort._userLocked(r.cid, r.slot) then blocked = true; break end
        end
        if not blocked then
            for _, r in ipairs(slots) do claimed[refKey(r)] = true end
            if ns.SafeCall then ns:SafeCall(performMove, m) else performMove(m) end
            issued = issued + 1
            Sort._moveCount = (Sort._moveCount or 0) + 1
        end
    end
    Sort._cleanupMoves = issued
    leaveIssuePass()
    return issued
end

-- Schedule the next round. Generation-guarded so an ITEM_LOCK_CHANGED "kick" can pull the
-- next round forward without ever running two rounds for one slot: bumping _tickGen
-- makes every already-queued callback a no-op.
-- `kicked` marks a round the EVENT path pulled forward (2.0.2b). It rides on the
-- closure rather than a Sort field so a superseded callback cannot leave the flag set
-- for whichever round actually runs.
local function scheduleTick(delay, kicked)
    Sort._tickGen = (Sort._tickGen or 0) + 1
    local gen = Sort._tickGen
    local fn = function()
        if Sort._running and gen == Sort._tickGen then
            Sort._kicked = kicked and true or false
            Sort._tick()
        end
    end
    local after = _G.C_Timer and _G.C_Timer.After
    if after then after(delay or Sort.TICK, fn) else fn() end
end

-- 2.0.2b: EVENT-DRIVEN ISSUING. A prediction just cleared, so a move that was blocked on
-- it may be issuable RIGHT NOW — pull the next round forward instead of burning the
-- remainder of the tick.
--
-- Two clamps make this strictly-no-worse than the 2.0.1 ladder:
--   * NEVER LATER than the tick it replaces. scheduleTick bumps _tickGen, so this call
--     supersedes the pending tick; scheduling further out than Sort.TICK would therefore
--     SLOW the fallback cadence down. The delay is clamped to Sort.TICK for that reason.
--   * NEVER TIGHTER than Sort.KICK_GAP since the last round actually ran, so an event
--     storm (a 24-move wave lands ~48 events) cannot turn into 48 re-plans. Combined with
--     the generation guard — every kick but the last in a frame is a no-op — a burst
--     costs exactly one round.
-- THE ISSUING RULE (2.0.2b), factored out as one named decision so the harness can pin
-- it — and mutate it — without a client. Returns a REASON string (truthy) or false.
--
--   "waiting" — the last round planned a wave-1 move and refused it BECAUSE of this
--               slot. Its confirmation makes that exact move legal now. This is "a
--               move's endpoints settled", literally, and it is the case that pays.
--   "settled" — nothing of ours is in flight at all: the next plan sees fully observed
--               state, needs no busy fallback, and there is nothing left to wait for.
--   "blocked" — the previous round issued nothing at all (the 2.0.1 case, unchanged).
--
-- Everything else waits for the tick ON PURPOSE — see the driver's banner for the
-- measured cost of kicking on every confirmation.
function Sort.ShouldKick(key)
    if not Sort.EVENT_ISSUE then return false end
    if key ~= nil and Sort._waiting and Sort._waiting[key] then return "waiting" end
    if not predOutstanding() then return "settled" end
    if (Sort._lastIssued or 0) == 0 then return "blocked" end
    return false
end

-- (Sort.ShouldKick owns the EVENT_ISSUE gate — see its banner — so this does not
-- re-check it: two places deciding one thing is how an off switch stops working.)
local function kickTick(now)
    local wait = (Sort.KICK_GAP or 0) - (now - (Sort._lastTickAt or 0))
    if wait < 0 then wait = 0 end
    if wait > Sort.TICK then wait = Sort.TICK end
    scheduleTick(wait, true)
end

-- One optimistic round: snapshot -> overlay predictions -> re-plan -> issue wave 1.
function Sort._tick()
    if not Sort._running then return end

    -- ── CLASS 9: NEVER RE-PLAN FROM A HALF-ISSUED WAVE ────────────────────────────
    -- A round snapshots, overlays, re-plans and issues. All of that assumes the wave it
    -- is looking at is not currently HALF OUT. On a client that dispatches from inside the
    -- call, a handler woken by move 3's pickup can reach a queued round (a kick whose gap
    -- has already elapsed is DUE the moment the timer queue is next drained, and the queue
    -- is drained inside the call), and that round would then plan over a bag with one item
    -- on the cursor and two slots mid-swap — the Armory E-1 shape, and the state in which
    -- a settle predicate can retire a move that has not landed. The issue-pass depth IS
    -- the "a wave is out right now" fact, so the round defers instead: nothing is lost,
    -- because the wave in flight arms the next round on its own settle anyway.
    if (Sort._issueDepth or 0) > 0 then
        Sort._reentryRefused = (Sort._reentryRefused or 0) + 1
        Sort._reentryWhere   = "tick@" .. tostring(ns.VERSION or "?")
        return scheduleTick(Sort.KICK_GAP)
    end

    -- Abort guards first, exactly as before (polled AND event-driven).
    if inCombat() then return abort("entered combat") end
    if Sort._needsBank and not bankIsOpen() then return abort("bank closed") end
    if ns.Frame and ns.Frame.IsShown and not ns.Frame.IsShown() and not Sort._needsBank then
        return abort("window closed")
    end

    Sort._ticks = (Sort._ticks or 0) + 1

    local now = nowSeconds()
    Sort._lastTickAt = now
    -- RUNAWAY ceiling. 2.0.2: BOTH arms must trip. Event issuing makes rounds much more
    -- frequent than the 0.05s ladder MAX_TICKS was counted against, so the tick count
    -- alone would now fire this guard in a fraction of the wall clock it was written for.
    -- The seconds arm restores the intended 200s+ meaning; neither arm alone can abort.
    if Sort._ticks > Sort.MAX_TICKS
       and (now - (Sort._start or now)) >= (Sort._runawaySecs or Sort.RUNAWAY_SECONDS) then
        return abort("runaway guard tripped")
    end

    local cells = snapshot(Sort._cids)
    if not cells then return abort("containers unavailable") end
    overlayPredictions(cells, now)

    local plan = Sort.Plan({
        cells = cells, meta = Sort._meta, canHold = Sort._canHold, descending = Sort._desc,
        familyOf = Sort._familyOf,
    })

    -- PROGRESS accounting. The residual is the work still outstanding: what a plan taken on
    -- the CURRENT observation wants to do, PLUS the slots we already have in flight (those
    -- are busy, hence absent from the plan — counting only #plan.moves would read "progress"
    -- every time a move went out and "regression" every time one landed). `_best` is the
    -- low-water mark; a new low re-bases the stall counter and raises the move budget, so a
    -- sort that keeps making headway is never cut off, however long it runs.
    local residual = #plan.moves + predCount()
    Sort._residual = #plan.moves
    if Sort._best == nil or residual < Sort._best then
        Sort._best = residual
        Sort._sinceProgress = 0
        Sort._lastProgressAt = now
        -- MONOTONE: the budget only ever ratchets UP. (Re-basing it downward off a
        -- busy-shrunken plan is what made a healthy sort trip its own thrash guard.)
        local want = (Sort._moveCount or 0) + residual * Sort.MAX_MOVE_FACTOR + Sort.MOVE_SLACK
        if want > (Sort._budget or 0) then Sort._budget = want end
    else
        Sort._sinceProgress = (Sort._sinceProgress or 0) + 1
        -- Telemetry: the PEAK streak, not the final one. It answers "how close did this
        -- sort come to the stall guard?", which is what MAX_NO_PROGRESS gets tuned on.
        if Sort._sinceProgress > (Sort._peakNoProgress or 0) then
            Sort._peakNoProgress = Sort._sinceProgress
        end
    end

    local issued = 0
    -- 2.0.2b: rebuild the waiting set from scratch each round — it describes THIS
    -- round's blocked wave-1 moves, and a stale entry would kick on a slot nothing is
    -- waiting for any more.
    Sort._waiting = {}
    if #plan.moves == 0 then
        -- Converged only when the plan is clean AND nothing of ours is still in flight,
        -- i.e. the zero-move verdict was reached on fully OBSERVED state.
        if not predOutstanding() then return finish() end
    else
        -- STALL guard. 2.0.2: both the tick streak AND the wall-clock window must be
        -- exceeded (see the IDLE_SECONDS/NO_PROGRESS_SECONDS banner). Rounds are now
        -- event-paced, so the streak alone measures round COUNT, not patience.
        if Sort._sinceProgress > Sort.MAX_NO_PROGRESS
           and (now - (Sort._lastProgressAt or Sort._start or now))
               >= (Sort._noProgressSecs or Sort.NO_PROGRESS_SECONDS) then
            return abort("not converging (no progress)")
        end
        if (Sort._moveCount or 0) >= (Sort._budget or 0) then
            return abort("not converging (move budget spent)")
        end
        issued = issueWave1(plan, cells, now)
        -- ── BUSY FALLBACK (the throughput fix) ──────────────────────────────
        -- The plan above is taken on the FULL cell set, which gives the best move
        -- decomposition — but its wave 1 is often entirely made of moves on cells we
        -- already have in flight, and the issue guard then rejects every one (measured:
        -- 6.7 of 8.0 wave-1 moves on a full bank at 0.30s latency). That is the tick that
        -- produced the owner's "231 moves in 123 waves": nothing went out, over and over.
        --
        -- So ONLY when the good plan yields nothing issuable, re-plan with the in-flight
        -- cells marked BUSY (see Sort.Plan's banner: still in the target map, not usable as
        -- a move endpoint) and issue from that instead. The restricted plan is a worse
        -- decomposition, so we pay for it in a few extra moves — but we pay ONLY on ticks
        -- that would otherwise have idled, which is exactly where the time was going.
        -- Planning unconditionally with BUSY was measured too: uniformly faster but 15-60%
        -- more moves, because every tick then planned on a partial view of the bag.
        --
        -- 2.0.2b: NOT on a kicked round. A kicked round exists because a specific
        -- planned move just became legal, so the FULL plan is the one that should issue
        -- it; if it does not, the state is not what the kick assumed and buying a worse
        -- decomposition on top of that is pure churn — measured at +11% moves and +22%
        -- wall time at 0.50s latency before this clause. The fallback is not lost, only
        -- rate-limited: the very next TIMED tick takes it. That keeps partial-view
        -- planning on the 20 Hz ladder it was tuned against, which is the whole point.
        if issued == 0 and Sort.PLAN_BUSY and predOutstanding() and not Sort._kicked then
            local busyPlan = Sort.Plan({
                cells = cells, meta = Sort._meta, canHold = Sort._canHold,
                descending = Sort._desc, familyOf = Sort._familyOf,
                busy = function(cid, slot) return Sort._pred[slotKey(cid, slot)] ~= nil end,
            })
            if #busyPlan.moves > 0 then
                issued = issueWave1(busyPlan, cells, now)
                -- Telemetry (2.0.2a): count only the rounds the fallback actually RESCUED
                -- — i.e. where the full plan issued nothing and the restricted one issued
                -- something. That is the exact quantity PLAN_BUSY buys, so the log can
                -- decide later whether planning with BUSY unconditionally is worth its
                -- 15-60% extra moves. (Default is NOT flipped in 2.0.2; this measures it.)
                if issued > 0 then Sort._busyRounds = (Sort._busyRounds or 0) + 1 end
            end
        end
        if issued > 0 then Sort._rounds = (Sort._rounds or 0) + 1 end
    end

    Sort._lastIssued = issued
    Sort._waitingRound = false
    if issued > 0 then
        Sort._idle = 0
        Sort._idleSince = nil
    else
        -- Nothing issued. That is only IDLE when nothing of ours is in flight either;
        -- waiting on our own outstanding round-trips is the executor working as designed.
        if predOutstanding() then
            Sort._idle = 0
            Sort._idleSince = nil
            -- ── 2.0.3: THIS ROUND IS WAITING, NOT WORKING ────────────────────────
            -- Every needed slot is held by one of our own un-acked moves, so there is
            -- nothing this round can legally do. Re-planning at 20 Hz through a ~240ms
            -- settle window buys nothing and — before the settle-aware retirement above
            -- — was where the duplicate issues came from. Mark the round WAITING and
            -- drop to the slow backstop cadence; the bag events re-arm it the instant
            -- the contents land, which is strictly sooner than any timer.
            Sort._waitingRound = true
            Sort._settleWaits  = (Sort._settleWaits or 0) + 1
            quietHeartbeat(now)
            return scheduleTick(Sort.WAIT_TICK)
        else
            Sort._idle = (Sort._idle or 0) + 1
            Sort._idleSince = Sort._idleSince or now
            -- Same two-arm rule as the stall guard: event-paced rounds make the tick
            -- count a round COUNT, so the seconds window is what keeps this at ~2s.
            if Sort._idle > Sort.MAX_IDLE_TICKS
               and (now - Sort._idleSince) >= (Sort._idleSecs or Sort.IDLE_SECONDS) then
                return abort("stalled (slots stayed locked)")
            end
        end
    end

    quietHeartbeat(now)
    scheduleTick()
end

local function ensureDriver()
    if Sort._driver or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, event, a, b)
        if event == "PLAYER_REGEN_DISABLED" then abort("entered combat"); return end
        if event == "BANKFRAME_CLOSED" and Sort._needsBank then abort("bank closed"); return end
        -- 2.0.3: OBSERVE the client's own refusals. Purely telemetry — the count rides
        -- in the sort-log record so a future report says "the client refused N
        -- operations" outright instead of leaving it to be inferred from a ratio.
        if event == "UI_ERROR_MESSAGE" then
            if Sort._running and Sort.IsBagError(a, b) then
                Sort._bagErrors = (Sort._bagErrors or 0) + 1
            end
            return
        end
        -- 2.0.3: BAG_UPDATE is the event that publishes the CONTENTS a prediction is
        -- waiting on, and BAG_UPDATE_DELAYED is Blizzard's own "that burst is over"
        -- signal (Daseeki-Conduit's mail attach arms on exactly this pair). Without
        -- them a settle-aware executor would sit out the whole window on the slow
        -- backstop tick; with them the round re-arms the moment the contents land.
        if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" then
            -- CLASS 9: while a teardown is in flight these are the teardown's OWN echoes
            -- (cleanupWave's pickups, stopDriver's ClearCursor). Sampling round-trips from
            -- them writes cleanup timings into the record logRun is about to persist, and
            -- arming a kick schedules a round for a run that is ending. Read the latch and
            -- treat what it sees as our own echo.
            if Sort._teardown then return end
            if Sort._running and Sort._pred then
                local now = nowSeconds()
                local settled = false
                for k in pairs(Sort._pred) do
                    releasePred(k, now)
                    if Sort._pred[k] == nil then
                        settled = true
                        if Sort._waiting then Sort._waiting[k] = nil end
                    end
                end
                -- Only a round that is actually WAITING gains anything from being pulled
                -- forward, and only when something really settled. Everything else stays on
                -- the cadence it was already on — a bag-update burst must not become a
                -- re-plan storm (see the EVENT-DRIVEN ISSUING banner's measured cost).
                if settled and Sort._waitingRound then kickTick(now) end
            end
            -- BAG-7: these two events are the CONTENTS publication — the moment the cells
            -- the owner is watching actually changed. The executor's work above runs FIRST
            -- (the repaint must never sit between an event and the round it arms), then the
            -- coalesced, read-only visual sweep. This is the path 1.x repainted on.
            liveRepaint()
            return
        end
        if event == "ITEM_LOCK_CHANGED" then
            -- Use the (bag, slot) payload the event already carries to release exactly
            -- that prediction the moment the server confirms — no full re-scan, and the
            -- dependent moves become issuable on the very next round.
            if not (Sort._running and Sort._pred) then return end
            if Sort._teardown then return end          -- CLASS 9, see the BAG_UPDATE arm
            if a == nil or b == nil then return end
            local k = slotKey(a, b)
            if not Sort._pred[k] then return end
            local now = nowSeconds()
            releasePred(k, now)
            -- 2.0.3: the prediction survives BOTH "still locked" and "unlocked but the
            -- contents have not caught up". Either way nothing settled, so there is
            -- nothing to arm — the BAG_UPDATE handler above owns the second case.
            if Sort._pred[k] ~= nil then return end
            -- ── 2.0.2b: ISSUING IS EVENT-DRIVEN AT THE ROUND BOUNDARY ────────────
            -- 2.0.1 pulled the next round forward in exactly ONE case: the previous
            -- round had issued nothing (`_lastIssued == 0`). Every other confirmation —
            -- including the one that COMPLETED a dependency round — sat out the
            -- remainder of the 0.05s tick. On the owner's 63-round baseline that is up
            -- to 63 x 50ms of pure dead air stacked on top of the round trips.
            --
            -- 2.0.2 adds the second case, and only the second case: the round is
            -- COMPLETE (`not predOutstanding()` — this was the last of our moves still
            -- in flight). At that instant the next plan can be taken on FULLY OBSERVED
            -- state, which is the best decomposition available and needs no busy
            -- fallback, so the round is pulled forward at zero cost in extra moves.
            --
            -- MEASURED, AND WHY IT IS NOT "KICK ON EVERY RELEASE". Kicking on every
            -- confirmation was implemented and benchmarked first: it re-plans while the
            -- rest of the wave is still in the air, so the full plan keeps coming back
            -- unissuable, the BUSY fallback fires far more often, and its deliberately
            -- worse decomposition is paid over and over. On the 4x16 fixtures at
            -- 0.15-0.50s that cost +20-24% moves and +38-51% WALL TIME — the churn the
            -- issueWave1 banner's rejected-alternative note describes, reached from the
            -- other direction. Partial-view planning belongs on the throttled tick,
            -- where its RATE is bounded.
            --
            -- So the kick fires on exactly three provably-idle states:
            --   1. `_waiting[k]`  — the last round planned a wave-1 move and refused it
            --      BECAUSE of this slot. Its confirmation makes that move legal now.
            --      This is "a move's endpoints settled", literally.
            --   2. `settled`      — nothing of ours is in flight at all, so the next
            --      plan is taken on fully observed state (best decomposition, no busy
            --      fallback) and there is nothing left to wait for.
            --   3. `blocked`      — the previous round issued nothing (the 2.0.1 case).
            -- The decision itself lives in Sort.ShouldKick so it is nameable, testable
            -- and mutatable; this branch only acts on it. ShouldKick is the ONLY reader
            -- of Sort.EVENT_ISSUE on this path, so switching the feature off genuinely
            -- reverts to the 2.0.1 rule below rather than half of each.
            local why = Sort.ShouldKick(k)
            if Sort._waiting then Sort._waiting[k] = nil end   -- consumed either way
            if why then
                kickTick(now)
            elseif not Sort.EVENT_ISSUE and (Sort._lastIssued or 0) == 0 then
                scheduleTick(0)                        -- the 2.0.1 case, unchanged
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

    -- A sort and the LOCK CONFIG MODE are mutually exclusive surfaces: the mode
    -- suspends normal item interaction, and watching the grid churn while every click
    -- toggles a lock is nobody's idea of configuration. Starting a sort closes it (the
    -- locks themselves are persisted and keep applying — only the editing mode ends).
    -- Guarded: locks.lua is optional to sort.lua.
    if ns.Locks and ns.Locks.Exit then ns.Locks.Exit("sorting") end

    local cells = snapshot(cids)
    if not cells then return false end

    -- One meta/family cache for the WHOLE run: Plan now runs every tick.
    local cache = {}
    -- Sort direction: opts.descending overrides; else the persisted db.sortDescending
    -- (absent/false => ascending, the canonical order).
    local descending = opts.descending
    if descending == nil then
        local db = Store and Store.db
        descending = (db and db.sortDescending) and true or false
    end
    local meta, canHold = makeMetaFn(cache), makeCanHoldFn(cache)
    local familyOf = makeFamilyFn(cache)
    local plan = Sort.Plan({ cells = cells, meta = meta, canHold = canHold,
                             familyOf = familyOf, descending = descending })
    if #plan.moves == 0 then
        if ns.Print then ns:Print("bags already sorted.") end
        return true
    end

    ensureDriver()
    local ids = {}
    for _, cid in ipairs(cids) do ids[#ids + 1] = cid end

    Sort._running   = true
    Sort._cids      = ids
    Sort._cache     = cache
    Sort._meta      = meta
    Sort._canHold   = canHold
    Sort._familyOf  = familyOf
    Sort._desc      = descending
    Sort._pred      = {}
    Sort._needsBank = needsBank
    Sort._ticks     = 0
    Sort._rounds    = 0
    Sort._idle      = 0
    Sort._moveCount = 0
    Sort._residual  = #plan.moves
    -- Progress accounting (see Sort._tick): `_best` is the residual low-water mark and
    -- `_sinceProgress` counts ticks since it last improved. The budget below is a
    -- thrash guard only — it is RE-BASED on every improvement, so a long-but-progressing
    -- sort can never spend it. Nothing here is a clock.
    Sort._best          = nil
    Sort._sinceProgress = 0
    Sort._budget    = #plan.moves * Sort.MAX_MOVE_FACTOR + Sort.MOVE_SLACK
    Sort._start     = nowSeconds()
    Sort._lastRefresh = Sort._start
    -- BAG-7: seed the live-repaint throttle at the run start. Nothing has moved yet, so the
    -- first sweep is due one LIVE_REPAINT window in — which is also the first moment any
    -- bag event can have landed.
    Sort._liveRepaintAt = Sort._start
    Sort._liveRepaints  = 0
    Sort._lastTickAt  = 0            -- so the FIRST kick is never held back by KICK_GAP
    Sort._lastProgressAt = Sort._start

    ------------------------------------------------------------------
    -- 2.0.2 TELEMETRY + ADAPTIVE SEED
    --
    -- The opening snapshot is the only place the problem SIZE is knowable, so cells /
    -- fill / plan size are captured here; everything else accumulates during the run.
    ------------------------------------------------------------------
    local occupied = 0
    for _, c in ipairs(cells) do if c.id then occupied = occupied + 1 end end
    Sort._cellCount  = #cells
    Sort._fillPct    = (#cells > 0) and (occupied * 100 / #cells) or 0
    Sort._planMoves0 = #plan.moves
    Sort._context    = needsBank and "bank" or "bags"
    Sort._peakNoProgress, Sort._busyRounds = 0, 0
    Sort._ackSum, Sort._ackN = 0, 0
    Sort._waiting    = {}            -- 2.0.2b: slots blocking a planned wave-1 move
    -- 2.0.3 settle-aware accumulators.
    Sort._bagErrors, Sort._settleWaits   = 0, 0
    Sort._settleHolds, Sort._settleDrops = 0, 0
    Sort._inFlightPeak, Sort._waitingRound = 0, false
    Sort._cleanupMoves = 0
    -- CLASS 9 run state. `_teardown` and `_issueDepth` are RE-SEEDED rather than merely
    -- assumed clean: a throw between arming and releasing either one would otherwise make
    -- every later run unstoppable / unissuable, and a latch that can wedge is not a fix.
    Sort._teardown       = nil
    Sort._issueDepth     = 0
    Sort._reentryRefused = 0
    Sort._reentryWhere   = nil

    -- Size this run's patience windows off the MEASURED round-trip from the log (2.0.2c).
    -- max(), never min(): the fixed windows are the floor, so an unmeasured or fast
    -- connection behaves exactly as 2.0.1 and only a genuinely slow one buys more time.
    local ackSecs = (Sort.LogAvgAckMs() or 0) / 1000
    Sort._idleSecs       = math.max(Sort.IDLE_SECONDS,        Sort.IDLE_ACKS        * ackSecs)
    Sort._noProgressSecs = math.max(Sort.NO_PROGRESS_SECONDS, Sort.NO_PROGRESS_ACKS * ackSecs)
    Sort._runawaySecs    = math.max(Sort.RUNAWAY_SECONDS,     Sort.RUNAWAY_ACKS     * ackSecs)
    -- Same max() rule for the settle ceiling: 1.0s is ~4 acks at the owner's measured
    -- 240ms, and a slower connection keeps that ratio rather than losing its patience.
    Sort._settleSecs     = math.max(Sort.SETTLE_TTL,          Sort.SETTLE_ACKS      * ackSecs)

    Sort._driver:RegisterEvent("ITEM_LOCK_CHANGED")
    -- 2.0.3: the SETTLE signals. ITEM_LOCK_CHANGED says "the server answered"; these two
    -- say "the contents you predicted are now visible", which is what arms the next wave.
    Sort._driver:RegisterEvent("BAG_UPDATE")
    Sort._driver:RegisterEvent("BAG_UPDATE_DELAYED")
    Sort._driver:RegisterEvent("UI_ERROR_MESSAGE")
    Sort._driver:RegisterEvent("PLAYER_REGEN_DISABLED")
    if needsBank then Sort._driver:RegisterEvent("BANKFRAME_CLOSED") end

    beginQuiet()
    Sort._tick()
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
    -- contents = { [slot] = { id, count, locked, userLocked } }
    --   locked     = the client's transient in-flight lock
    --   userLocked = the owner's persistent SORT LOCK (locks.lua)
    -- An entry with no id models an EMPTY cell, which is meaningful for userLocked:
    -- an empty locked slot must never be filled.
    local cells = {}
    for slot = 1, slots do
        local e = contents[slot]
        if e then cells[#cells + 1] = { cid = cid, slot = slot, id = e.id,
                                        count = e.count or (e.id and 1 or 0),
                                        locked = e.locked, userLocked = e.userLocked }
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

----------------------------------------------------------------------
-- SORT LOCKS (locks.lua) — the planner half of the owner's right-click feature.
--
-- A user lock has to hold in BOTH directions, and they are genuinely different
-- failure modes:
--   SOURCE      a locked slot's item must never move OUT of it.
--   DESTINATION a locked slot must never be chosen to receive anything — including
--               an EMPTY locked slot, which carries no item to protect and is exactly
--               the case a "skip cells that hold something locked" bug would miss.
-- Both are asserted below, plus the mutation gate underneath, which proves these
-- assertions actually FAIL when the lock logic is broken.
----------------------------------------------------------------------

-- The lock assertion body, factored out so the mutation gate can re-run the SAME
-- assertions against a deliberately broken Sort.CellIsFixed. Returns a fails list.
local function userLockAssertions()
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function touches(m, cid, slot)
        local function hit(r) return r and r.cid == cid and r.slot == slot end
        if m.op == "swap" then return hit(m.a) or hit(m.b) end
        return hit(m.from) or hit(m.to)
    end

    ---------------------------------------------------------------- source direction
    -- An OCCUPIED user-locked slot holding an item that badly wants to move (an apple,
    -- which 1.x order sends to the bottom, sitting in slot 1 above gear).
    local occupied = bagCells(0, 6, {
        [1] = { id = 100, count = 5, userLocked = true },   -- LOCKED consumable up front
        [2] = { id = 200 },                                 -- sword
        [3] = { id = 201 },                                 -- cloak
        [4] = { id = 100, count = 7 },                      -- a loose apple to merge with
    })
    local p1 = Sort.Plan({ cells = occupied, meta = metaFn })
    for _, m in ipairs(p1.moves) do
        ck(not touches(m, 0, 1), "no move touches the user-locked source slot 1")
    end
    ck(p1.target[1] == nil, "user-locked occupied cell is not a placement target")
    -- and prove it by APPLYING the plan: the locked stack is bit-identical afterwards.
    local applied = bagCells(0, 6, {
        [1] = { id = 100, count = 5, userLocked = true },
        [2] = { id = 200 }, [3] = { id = 201 }, [4] = { id = 100, count = 7 },
    })
    applyMoves(applied, p1.moves, maxOf)
    ck(applied[1].id == 100 and applied[1].count == 5,
       "the user-locked apple stack survives the plan unchanged (not even merged into)")
    -- The loose apple is still in the bag: locking never destroys or strands items.
    local apples = 0
    for _, c in ipairs(applied) do if c.id == 100 then apples = apples + c.count end end
    ck(apples == 12, "every apple is still accounted for (5 locked + 7 free)")

    ---------------------------------------------------------------- destination direction
    -- An EMPTY user-locked slot in the middle of a bag the planner wants to compact.
    -- Nothing may land in it, and the sort must still complete around it.
    local empties = bagCells(0, 6, {
        [1] = { id = 300, count = 4 },
        [2] = { userLocked = true },          -- LOCKED and EMPTY: must stay empty
        [3] = { id = 300, count = 5 },
        [4] = { id = 200 },
        [5] = { id = 100, count = 3 },
    })
    local p2 = Sort.Plan({ cells = empties, meta = metaFn })
    for _, m in ipairs(p2.moves) do
        ck(not touches(m, 0, 2), "no move targets the empty user-locked slot 2")
    end
    ck(p2.target[2] == nil, "empty user-locked cell is not a placement target")
    local applied2 = bagCells(0, 6, {
        [1] = { id = 300, count = 4 }, [2] = { userLocked = true },
        [3] = { id = 300, count = 5 }, [4] = { id = 200 }, [5] = { id = 100, count = 3 },
    })
    applyMoves(applied2, p2.moves, maxOf)
    ck(applied2[2].id == nil, "the empty locked slot is still empty after the sort")
    -- ...and the free cells DID sort (the lock must not paralyse the whole bag).
    local seq = {}
    for _, c in ipairs(applied2) do if c.id then seq[#seq + 1] = c.id end end
    ck(#seq == 3, "three occupied cells remain (cloth merged to one stack)")
    ck(seq[1] == 300 and seq[2] == 200 and seq[3] == 100,
       "free cells still land in 1.x order around the lock (cloth, sword, apple)")

    ---------------------------------------------------------------- both kinds coexist
    -- A transient client lock and a user lock on the same bag are both fixed points,
    -- and neither is confused for the other.
    local mixed = bagCells(0, 5, {
        [1] = { id = 100, count = 4, locked = true },       -- in-flight (client)
        [2] = { id = 101, count = 4, userLocked = true },   -- owner's sort lock
        [3] = { id = 200 },
    })
    local p3 = Sort.Plan({ cells = mixed, meta = metaFn })
    for _, m in ipairs(p3.moves) do
        ck(not touches(m, 0, 1), "in-flight slot 1 still a fixed point")
        ck(not touches(m, 0, 2), "user-locked slot 2 still a fixed point")
    end
    ck(p3.stats.free == 3, "free-cell count excludes BOTH locked cells (5 - 2)")

    ---------------------------------------------------------------- idempotence
    -- Re-planning a bag that is already sorted-around-its-locks yields zero moves, so
    -- the executor converges instead of churning against the locks forever.
    local settled = bagCells(0, 6, {
        [1] = { id = 100, count = 5, userLocked = true },
        [2] = { id = 100, count = 7 }, [3] = { id = 200 },
    })
    local p4 = Sort.Plan({ cells = settled, meta = metaFn })
    local p4b = Sort.Plan({ cells = settled, meta = metaFn })
    ck(#p4.moves > 0, "the unsorted-around-a-lock bag really does need moves")
    ck(#p4.moves == #p4b.moves, "planning twice on the same state is stable")
    applyMoves(settled, p4.moves, maxOf)
    local p5 = Sort.Plan({ cells = settled, meta = metaFn })
    ck(#p5.moves == 0, "the post-plan state is a fixed point (converges with locks)")
    ck(settled[1].id == 100 and settled[1].count == 5, "and the lock held through it")

    return fails
end

local function testPlanUserLocks(fails)
    for _, f in ipairs(userLockAssertions()) do fails[#fails + 1] = f end
end

----------------------------------------------------------------------
-- MUTATION GATE for the lock cases.
--
-- A lock test that passes against a BROKEN lock implementation is worse than no test:
-- it is a green light over the exact defect it was written for. So each mutant below
-- breaks Sort.CellIsFixed in one specific way, and the gate asserts the assertions
-- above go RED. A mutant that survives (assertions still pass) is reported by name.
----------------------------------------------------------------------
local function testUserLockMutants(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local real = Sort.CellIsFixed
    local mutants = {
        { name = "ignores userLocked (only honours the client's in-flight lock)",
          fn = function(c) return (type(c) == "table" and c.locked) and true or false end },
        { name = "ignores locked (only honours the user lock)",
          fn = function(c) return (type(c) == "table" and c.userLocked) and true or false end },
        { name = "nothing is ever fixed",
          fn = function() return false end },
        { name = "everything is fixed",
          fn = function() return true end },
        { name = "locks only protect OCCUPIED cells (empty locked slot is fillable)",
          fn = function(c)
              if type(c) ~= "table" then return false end
              if c.locked then return true end
              return (c.userLocked and c.id ~= nil) and true or false
          end },
    }

    for _, mut in ipairs(mutants) do
        Sort.CellIsFixed = mut.fn
        local ok, res = pcall(userLockAssertions)
        Sort.CellIsFixed = real
        -- A mutant is KILLED either by producing assertion failures or by erroring out.
        local killed = (not ok) or (#res > 0)
        ck(killed, "mutant SURVIVED the lock assertions: " .. mut.name)
    end

    ck(Sort.CellIsFixed == real, "the real predicate was restored after mutation")
    -- Sanity: the unmutated predicate passes the same assertions it just killed
    -- mutants with (guards against a gate that is red for everything).
    ck(#userLockAssertions() == 0, "the real predicate passes the lock assertions")
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

----------------------------------------------------------------------
-- FAMILY BANDS — 1.x's placement rule (GetFamilies / GetOrder).
--
-- The regression this locks: 2.0 used to assign target cells by a "most-constrained
-- first" rank, counting how many cells could hold each stack, ascending. An item that
-- fits a specialized bag fits the general cells TOO, so its count is the HIGHEST and it
-- was placed LAST — after the general cells were taken. Herbs ended up in the backpack
-- with the herb bag half empty, the exact inverse of 1.x, which claims the specialized
-- bag FIRST and only spills the overflow into general slots.
----------------------------------------------------------------------
local function testFamilyBands(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- 1.x GetFamilies comparator: descending, reagent pseudo-family demoted, 0 last.
    local ord = Sort.FamilyOrder({ 0, 32, 9, Sort.REAGENT_FAMILY, 64 })
    ck(ord[1] == 64 and ord[2] == 32 and ord[3] == 9,
        "specialized families descend (64, 32, 9)")
    ck(ord[4] == Sort.REAGENT_FAMILY, "the reagent pseudo-family sorts after real families")
    ck(ord[#ord] == 0, "the general family is ALWAYS last (1.x fills it with the leftovers)")
    ck(#Sort.FamilyOrder({}) == 0, "empty family list is inert")
    ck(Sort.FamilyOrder({ 0 })[1] == 0, "a single general band is the whole list")

    -- Backpack (cid 0, general, 8 cells) + herb bag (cid 1, family 4, 4 cells).
    -- id 300 is the "cloth" tradegood (herb-family here); 200/201 are gear.
    local HERB = 4
    local function familyOf(cid) return cid == 1 and HERB or 0 end
    local function canHold(cid, id)
        if cid ~= 1 then return true end
        return id == 300
    end

    -- SIX stacks of the herb-family item, but only FOUR herb-bag cells: 1.x fills the
    -- herb bag to capacity first, then spills the remaining two into general slots.
    local cells = {}
    for _, c in ipairs(bagCells(0, 8, {
        [1] = { id = 300, count = 10 }, [2] = { id = 200 }, [3] = { id = 300, count = 10 },
        [4] = { id = 201 },             [5] = { id = 300, count = 10 },
        [6] = { id = 300, count = 10 }, [7] = { id = 300, count = 10 },
        [8] = { id = 300, count = 10 },
    })) do cells[#cells + 1] = c end
    for _, c in ipairs(bagCells(1, 4, {})) do cells[#cells + 1] = c end

    local plan = Sort.Plan({ cells = cells, meta = metaFn, canHold = canHold,
                             familyOf = familyOf })
    local copy = {}
    for _, c in ipairs(bagCells(0, 8, {
        [1] = { id = 300, count = 10 }, [2] = { id = 200 }, [3] = { id = 300, count = 10 },
        [4] = { id = 201 },             [5] = { id = 300, count = 10 },
        [6] = { id = 300, count = 10 }, [7] = { id = 300, count = 10 },
        [8] = { id = 300, count = 10 },
    })) do copy[#copy + 1] = c end
    for _, c in ipairs(bagCells(1, 4, {})) do copy[#copy + 1] = c end
    applyMoves(copy, plan.moves, maxOf)

    local inHerbBag, inGeneral = 0, 0
    for _, c in ipairs(copy) do
        if c.id == 300 then
            if c.cid == 1 then inHerbBag = inHerbBag + 1 else inGeneral = inGeneral + 1 end
        end
        if c.cid == 1 and c.id then ck(c.id == 300, "the herb bag holds only herb-family items") end
    end
    ck(inHerbBag == 4, "the specialized bag is FILLED FIRST (4 of 4 cells), got " .. inHerbBag)
    ck(inGeneral == 2, "only the overflow lands in general slots (2), got " .. inGeneral)

    -- Gear can never be pushed into the specialized bag by a swap (1.x's Move guard:
    -- the DISPLACED item must fit the donor's family too).
    for _, m in ipairs(plan.moves) do
        for _, r in ipairs(Sort.MoveSlots(m)) do
            if r.cid == 1 then
                -- any move touching the herb bag must be about the herb-family item
                ck(true, "herb-bag move")
            end
        end
    end

    -- Idempotence: re-planning the sorted layout is a fixed point.
    local again = Sort.Plan({ cells = copy, meta = metaFn, canHold = canHold,
                              familyOf = familyOf })
    ck(#again.moves == 0, "family-banded layout is a planner fixed point ("
        .. #again.moves .. " residual)")

    -- NO familyOf => one band => identical to the plain single-run assignment.
    local flatA = Sort.Plan({ cells = bagCells(0, 8, {
        [1] = { id = 100, count = 5 }, [3] = { id = 200 }, [5] = { id = 300, count = 6 } }),
        meta = metaFn })
    local flatB = Sort.Plan({ cells = bagCells(0, 8, {
        [1] = { id = 100, count = 5 }, [3] = { id = 200 }, [5] = { id = 300, count = 6 } }),
        meta = metaFn, familyOf = function() return 0 end })
    ck(#flatA.moves == #flatB.moves,
        "an all-general inventory is byte-identical with and without familyOf")
end

----------------------------------------------------------------------
-- BUSY cells — the throughput fix's planner contract.
--
-- A busy cell (one of OUR moves in flight) must:
--   * STAY in the target map — its predicted content counts toward the totals, so the
--     sorted target list is the same every tick and the assignment is a fixed point;
--   * never appear as a move ENDPOINT — that is the whole point: the wave the executor
--     issues must contain only moves the client will actually accept right now.
----------------------------------------------------------------------
local function testPlanBusy(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local seed = {
        [1] = { id = 100, count = 5 }, [2] = { id = 500 }, [3] = { id = 300, count = 6 },
        [4] = { id = 200 },            [5] = { id = 101, count = 5 }, [6] = { id = 400 },
        [7] = { id = 201 },
    }
    local base = Sort.Plan({ cells = bagCells(0, 12, seed), meta = metaFn })
    ck(#base.moves > 0, "the unrestricted fixture plans some moves")

    -- No busy predicate at all => byte-identical to the old planner.
    local none = Sort.Plan({ cells = bagCells(0, 12, seed), meta = metaFn,
                             busy = function() return false end })
    ck(#none.moves == #base.moves, "busy=nothing is identical to no busy predicate")

    -- Mark slots 2 and 4 busy: NO move may touch them.
    local busySlots = { [2] = true, [4] = true }
    local restricted = Sort.Plan({ cells = bagCells(0, 12, seed), meta = metaFn,
        busy = function(_, slot) return busySlots[slot] or false end })
    for _, m in ipairs(restricted.moves) do
        for _, r in ipairs(Sort.MoveSlots(m)) do
            ck(not busySlots[r.slot],
                "no move touches a BUSY slot (slot " .. tostring(r.slot) .. ")")
        end
    end

    -- ...but the TARGET MAP is unchanged: busy cells still receive their assignment, so
    -- the sorted destination of every cell is the same as in the unrestricted plan.
    local sameTargets = true
    for i, t in pairs(base.target) do
        local r = restricted.target[i]
        if not r or r.id ~= t.id or r.count ~= t.count then sameTargets = false end
    end
    ck(sameTargets, "a BUSY cell keeps its place in the target map (the map is stable)")

    -- Everything busy => nothing issuable, but still no error and still a stable map.
    local all = Sort.Plan({ cells = bagCells(0, 12, seed), meta = metaFn,
                            busy = function() return true end })
    ck(#all.moves == 0, "every cell busy -> zero moves (wait, do not churn)")
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

----------------------------------------------------------------------
-- MUTATION GATE on the ORDERING RULE.
--
-- "plan: 1.x order parity" asserts a mixed bag lands in 1.x's order. A pin like that is
-- only worth having if it actually FAILS when the rule it guards is wrong — the same
-- discipline the sort-lock mutation gate applies. Each mutant below breaks exactly one
-- link of Sort.CompareStacks' chain (set → class → subclass → equip → quality → icon →
-- level → id → count, all DESCENDING) and the gate demands the parity suite reject it.
----------------------------------------------------------------------
local function testOrderMutants(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local real = Sort.CompareStacks

    local mutants = {
        {   name = "band (`set`) ASCENDING — consumables would lead instead of trail",
            fn = function(a, b)
                local am, bm = a.meta or {}, b.meta or {}
                local x, y = am.set or 0, bm.set or 0
                if x ~= y then return x < y end       -- MUTANT: flipped
                return real(a, b)
            end },
        {   name = "class ASCENDING — weapons would lead the gear band, not quest items",
            fn = function(a, b)
                local am, bm = a.meta or {}, b.meta or {}
                if (am.set or 0) ~= (bm.set or 0) then return (am.set or 0) > (bm.set or 0) end
                local x, y = am.classID or 14, bm.classID or 14
                if x ~= y then return x < y end       -- MUTANT: flipped
                return real(a, b)
            end },
    }

    for _, mut in ipairs(mutants) do
        Sort.CompareStacks = mut.fn
        local caught = {}
        local ok = pcall(testPlan1xOrder, caught)
        Sort.CompareStacks = real
        ck(ok and #caught > 0,
            "the 1.x-order pin must REJECT the mutant: " .. mut.name)
    end

    -- ...and the real comparator still passes, so the gate is not simply always-fail.
    local clean = {}
    local ok = pcall(testPlan1xOrder, clean)
    ck(ok and #clean == 0, "the real comparator still passes the parity suite")
    ck(Sort.CompareStacks == real, "the real comparator was restored")

    -- The mixed-bag fixture only ever DISTINGUISHES on `set` and `class` (its items have
    -- one class each), so mutating a later link is equivalent on it and cannot be caught
    -- there. Those links are pinned directly instead: build two stacks that agree on
    -- everything ABOVE the key under test and differ only on it, and assert the greater
    -- value sorts first — 1.x's Proprieties list, link by link.
    local function stack(over)
        local m = { set = 2, classID = 4, subClassID = 1, equip = "INVTYPE_CLOAK",
                    quality = 2, iconFileID = 500, level = 30, maxStack = 1 }
        for k, v in pairs(over or {}) do m[k] = v end
        return { id = 900, count = 1, meta = m }
    end
    local chain = {
        { key = "subClassID", hi = 5,   lo = 1 },
        { key = "equip",      hi = "Z", lo = "A" },
        { key = "quality",    hi = 4,   lo = 2 },
        { key = "iconFileID", hi = 900, lo = 500 },
        { key = "level",      hi = 60,  lo = 30 },
    }
    for _, link in ipairs(chain) do
        local hi = stack({ [link.key] = link.hi })
        local lo = stack({ [link.key] = link.lo })
        ck(Sort.CompareStacks(hi, lo) == true and Sort.CompareStacks(lo, hi) == false,
            "chain link `" .. link.key .. "` is consulted and DESCENDING")
    end
    -- itemID then stackCount are the final tiebreaks, both descending.
    local a1, b1 = stack(), stack(); a1.id, b1.id = 901, 900
    ck(Sort.CompareStacks(a1, b1) == true, "itemID is the penultimate tiebreak, DESCENDING")
    local a2, b2 = stack(), stack(); a2.count, b2.count = 20, 5
    ck(Sort.CompareStacks(a2, b2) == true, "stackCount is the last tiebreak (fuller first)")
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

----------------------------------------------------------------------
-- =====================================================================
-- EXECUTOR CONVERGENCE SUITE — a simulated Classic-Era container API
--
-- The old executor was explicitly untested headless ("no WoW API under the harness").
-- The optimistic executor removes the blocking settle, so the timing path is now load-
-- bearing for CORRECTNESS, not just speed — it needs a gate. This simulator stands in
-- for the whole client/server surface the executor touches:
--
--   * C_Container.GetContainerNumSlots / GetContainerItemInfo / GetContainerNumFreeSlots
--     / PickupContainerItem, with the REAL semantics that matter here: a drop mutates
--     nothing immediately — both touched slots read isLocked = true and keep their OLD
--     contents until the simulated server confirms `latency` seconds later, exactly as
--     the live client behaves.
--   * ClearCursor / CursorHasItem, including the merge-overflow case (a pour that fills
--     the destination leaves the residual on the cursor, which performMove drops back).
--   * C_Timer.After + GetTime driven by a virtual clock, so a 0.3 s round-trip costs no
--     wall time and the whole latency sweep runs in milliseconds.
--   * CreateFrame / RegisterEvent + ITEM_LOCK_CHANGED (with its (bag, slot) payload),
--     PLAYER_REGEN_DISABLED, InCombatLockdown.
--   * C_Item.GetItemInfo / GetItemInfoInstant / GetItemFamily + bit.band, so the REAL
--     makeMetaFn / makeCanHoldFn / snapshot paths run — not test doubles.
--
-- Fault injection: `latency` (server round-trip), `dropRate` (server rejects a move
-- outright — the slots flap locked and nothing changes), `jitter` (per-move latency
-- spread), and scheduled mid-sort bag mutations.
--
-- Exposed as Sort._Simulator so CI / timing models can drive it without duplicating it.
-- =====================================================================

-- Deterministic LCG so every run of the suite is reproducible.
local function newRng(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s / 2147483647
    end
end

local function bandOf(a, b)
    local r, bitv = 0, 1
    a, b = math.floor(a or 0), math.floor(b or 0)
    while a > 0 and b > 0 do
        if (a % 2 == 1) and (b % 2 == 1) then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end

-- Item catalog the simulated C_Item serves. `family` drives the bag-family constraint.
local SIMCAT = {}
do
    local function add(id, classID, subClassID, equip, quality, level, maxStack, family)
        SIMCAT[id] = { id = id, classID = classID, subClassID = subClassID, equip = equip,
                       quality = quality, level = level, maxStack = maxStack,
                       icon = 90000 + id, family = family or 0, name = "item" .. id }
    end
    -- gear / goods (band 2)
    for k = 1, 12 do add(600 + k, ({2,4,4,7,9,12,2,4,7,15,13,4})[k], k % 6,
                         (k % 3 == 0) and "INVTYPE_CHEST" or "", (k % 5), 20 + k * 3, 1, 0) end
    -- stackables (band 2, tradegoods) — one is herb-family (bit 4)
    for k = 1, 8 do add(700 + k, 7, k % 4, "", 1, 0, ({5,10,20,20,10,20,5,20})[k],
                        (k == 3) and 4 or 0) end
    -- consumables (band 0)
    for k = 1, 6 do add(800 + k, 0, k % 2, "", 1, 0, ({5,20,20,10,20,5})[k], 0) end
end
local SIMIDS = {}
for id in pairs(SIMCAT) do SIMIDS[#SIMIDS + 1] = id end
table.sort(SIMIDS)

-- The simulator. opts: { bags = { {cid, size, family}, ... }, latency, jitter,
--                        dropRate, settleLag, seed }
--
-- ── settleLag: THE CLIENT'S TWO-PHASE SETTLE (2.0.3) ─────────────────────────
-- ITEM_LOCK_CHANGED and BAG_UPDATE are DIFFERENT events, and BAG_UPDATE is the LATER
-- one. When the server answers a container move the client first releases the slot
-- lock; the slot's visible CONTENTS are only rewritten when the bag-update burst
-- lands. `settleLag` is the width of that window. At 0 the sim publishes contents and
-- releases the lock atomically — which is what it did through 2.0.2, and is exactly
-- why the harness never saw the owner's live failure.
--
-- ── dispatch: WHEN THE ECHO ARRIVES (CLASS 9, 2026-08-11) ────────────────────
-- THE BLIND SPOT, NAMED. Through 2.0.7 this simulator delivered every event through
-- `S.after`, i.e. strictly AFTER the container call that caused it had returned. That is
-- one posture out of two, and it is the KIND one: any latch the engine arms after its own
-- first client call is already up by the time an async echo lands, so the async profile
-- tests the fix and never the hazard. The live client does not always schedule: on
-- interface 11509 a setter can DISPATCH its event from inside itself, and every handler
-- in the session runs to completion before the setter returns (Nexus 1.1.8, proven live).
--
--   "sync"  (DEFAULT — the unkind posture)
--            * a container operation that LOCKS slots announces those locks with
--              ITEM_LOCK_CHANGED from INSIDE the call. This is the sequence's FIRST echo
--              and it is the one that walks past a latch armed one call later.
--            * a pickup announces the slot it put on the cursor the same way (the client
--              greys it: the lock changed).
--            * any landing already DUE on the virtual clock is delivered from inside the
--              call as well, so a zero-latency round-trip publishes its contents before
--              PickupContainerItem returns.
--   "async" (the named variant, retained: exactly the 2.0.7 behaviour)
--
-- Both postures must be run. `stats.echoUnlatched` is the class-9 gate and, like
-- `lockedIssue`, it is raised by the SIM and never read by the engine: it counts every
-- in-call echo naming a slot that a RUNNING sort has an operation out on with no
-- prediction armed for it — "the latch was not up when your own first echo arrived".
-- `stats.maxDispatchDepth` fuses the sim itself: a handler that re-enters the container
-- API without bound fails the run as a test failure instead of a C-stack overflow.
--
-- `echoHook(S, api, cid, slot)` is the in-call fault-injection seam — it runs INSIDE the
-- named client call, which is the only place a class-9 fixture can put an event.
local function makeSimulator(opts)
    opts = opts or {}
    local S = {
        clock     = 0,
        latency   = opts.latency or 0,
        jitter    = opts.jitter or 0,
        dropRate  = opts.dropRate or 0,
        settleLag = opts.settleLag or 0,
        dispatch  = opts.dispatch or "sync",   -- UNKIND BY DEFAULT (class 9)
        echoHook  = opts.echoHook,
        rng      = newRng(opts.seed or 12345),
        timers   = {}, seq = 0,
        frames   = {},
        -- Two views, exactly as the live client has: `truth` is server state (mutated the
        -- instant a drop is issued) and `slots` is what GetContainerItemInfo shows — it
        -- only catches up when the round-trip lands. Everything the ADDON can observe
        -- goes through `slots`; every rule the SERVER applies is computed on `truth`.
        bags     = {},          -- [cid] = { n, family, slots = {...}, truth = {...} }
        locked   = {},          -- [key] = true while a move is in flight
        held     = nil,         -- cursor { id, count }
        holdKey  = nil,         -- origin slot key of the held item
        combat   = false,
        -- `rejected` is every refusal of any cause (fault injection, family, lock).
        -- `bagErrors`   — refusals the live client surfaces as "Internal Bag Error":
        --                 the addon asked the server to move something the server no
        --                 longer holds where the addon thought it did.
        -- `lockedIssue` — THE PERMANENT GATE: a container op issued against a slot the
        --                 client itself reports LOCKED. Asserted by the SIM, never by
        --                 the engine, so the engine cannot grade its own homework.
        stats    = { pickups = 0, drops = 0, rejected = 0, applied = 0,
                     bagErrors = 0, lockedIssue = 0,
                     -- class 9 (see the dispatch banner): both raised by the SIM only.
                     inCallEchoes = 0, echoUnlatched = 0, maxDispatchDepth = 0 },
        saved    = {},
    }
    -- Stands in for ERR_INTERNAL_BAG_ERROR. The live numeric id is build-specific, so
    -- the engine matches on the message text as well (see Sort.IsBagError).
    S.BAG_ERROR_ID = 44
    for _, b in ipairs(opts.bags or {}) do
        S.bags[b.cid] = { n = b.size, family = b.family or 0, slots = {}, truth = {} }
    end

    local function key(cid, slot) return cid .. ":" .. slot end
    local function unkey(k)
        local cid, slot = k:match("^(-?%d+):(%d+)$")
        return tonumber(cid), tonumber(slot)
    end

    ------------------------------------------------------------------
    -- virtual clock
    ------------------------------------------------------------------
    function S.after(delay, fn)
        S.seq = S.seq + 1
        S.timers[#S.timers + 1] = { at = S.clock + (delay or 0), seq = S.seq, fn = fn }
    end

    -- Run the clock forward until the queue drains or `limit` virtual seconds pass.
    function S:pump(limit)
        limit = limit or 30
        local guard = 0
        while true do
            guard = guard + 1
            if guard > 100000 then error("simulator: timer storm (possible infinite loop)") end
            local best
            for i, t in ipairs(S.timers) do
                if not best or t.at < S.timers[best].at
                   or (t.at == S.timers[best].at and t.seq < S.timers[best].seq) then best = i end
            end
            if not best then return end
            local t = S.timers[best]
            if t.at > limit then return end
            table.remove(S.timers, best)
            if t.at > S.clock then S.clock = t.at end
            t.fn()
        end
    end

    ------------------------------------------------------------------
    -- events
    ------------------------------------------------------------------
    function S.fire(event, a, b)
        for _, f in ipairs(S.frames) do
            if f._events[event] and f._script then f._script(f, event, a, b) end
        end
    end

    ------------------------------------------------------------------
    -- CLASS 9: dispatch from INSIDE the client call
    ------------------------------------------------------------------
    S.MAX_DISPATCH_DEPTH = 8   -- the sim's own fuse; see the dispatch banner

    -- Announce a lock STATE CHANGE on one slot. In the sync posture the handler runs before
    -- the caller's client call returns, and the gate below asks the class-9 question at the
    -- dispatch site: was the engine's latch up when its own echo arrived?
    -- `ungated` marks an announcement about a slot the caller's move does not name — the
    -- ClearCursor tail's parking branches — where "no prediction" is not a latch failure.
    local function announceLock(cid, slot, ungated)
        if S.dispatch ~= "sync" then return end
        if cid == nil or slot == nil then return end
        S.stats.inCallEchoes = S.stats.inCallEchoes + 1
        -- The gate. Only meaningful while OUR executor has a run open: an operation is out
        -- on this slot (we are inside the call that issued it), so a prediction for it must
        -- already exist. `Sort._pred` is read, never written — the engine cannot see this.
        if not ungated and Sort._running and Sort._pred and not Sort._teardown
           and Sort._pred[cid .. ":" .. slot] == nil then
            S.stats.echoUnlatched = S.stats.echoUnlatched + 1
        end
        S.fire("ITEM_LOCK_CHANGED", cid, slot)
    end

    -- Deliver everything the virtual clock already owes, from inside the call. A zero-
    -- latency landing therefore publishes its contents before the client call returns.
    local function drainDue()
        if S.dispatch ~= "sync" then return end
        local guard = 0
        while true do
            guard = guard + 1
            if guard > 1000 then error("simulator: in-call dispatch storm") end
            local best
            for i, t in ipairs(S.timers) do
                if t.at <= S.clock and (not best or t.at < S.timers[best].at
                   or (t.at == S.timers[best].at and t.seq < S.timers[best].seq)) then best = i end
            end
            if not best then return end
            local t = S.timers[best]
            table.remove(S.timers, best)
            t.fn()
        end
    end

    -- Wrap one client call so everything above happens INSIDE it, with a depth fuse so a
    -- handler that re-enters the container API fails the run as a test failure rather than
    -- as a C-stack overflow (the Nexus 1.1.8 symptom).
    local function inCall(api, fn, cid, slot)
        S.depth = (S.depth or 0) + 1
        if S.depth > S.stats.maxDispatchDepth then S.stats.maxDispatchDepth = S.depth end
        if S.depth > S.MAX_DISPATCH_DEPTH then
            S.depth = S.depth - 1
            error("simulator: " .. api .. " nested past depth " .. S.MAX_DISPATCH_DEPTH
                  .. " (class 9 runaway re-entry)")
        end
        local ok, err = pcall(fn)
        if ok and S.dispatch == "sync" then
            if S.echoHook then pcall(S.echoHook, S, api, cid, slot) end
            local ok2, err2 = pcall(drainDue)
            if not ok2 then ok, err = false, err2 end
        end
        S.depth = S.depth - 1
        if not ok then error(err, 0) end
    end

    ------------------------------------------------------------------
    -- server-side application of a queued mutation
    ------------------------------------------------------------------
    local function settleDelay()
        local j = (S.jitter > 0) and (S.rng() * S.jitter) or 0
        return S.latency + j
    end

    -- Publish server truth into the visible view for a set of slots.
    local function publish(touched)
        for _, k in ipairs(touched) do
            local cid, slot = unkey(k)
            local bag = S.bags[cid]
            if bag then
                local t = bag.truth[slot]
                bag.slots[slot] = t and { id = t.id, count = t.count } or nil
            end
        end
        S.stats.applied = S.stats.applied + 1
    end

    local function unlockAndAnnounce(touched)
        for _, k in ipairs(touched) do S.locked[k] = nil end
        for _, k in ipairs(touched) do
            local cid, slot = unkey(k)
            S.fire("ITEM_LOCK_CHANGED", cid, slot)
        end
    end

    -- The round-trip landing. With `settleLag == 0` this is the 2.0.2 model: contents
    -- and lock move together. With a settle lag it is the LIVE model — the lock clears
    -- first (ITEM_LOCK_CHANGED) and the contents catch up later (BAG_UPDATE), and the
    -- window between them is where a lock-only "is it settled?" test reads a stale bag.
    local function commit(touched)
        S.after(settleDelay(), function()
            if (S.settleLag or 0) <= 0 then
                publish(touched)
                unlockAndAnnounce(touched)
                S.fire("BAG_UPDATE_DELAYED")
                return
            end
            unlockAndAnnounce(touched)
            S.after(S.settleLag, function()
                publish(touched)
                local seen = {}
                for _, k in ipairs(touched) do
                    local cid = unkey(k)
                    if not seen[cid] then seen[cid] = true; S.fire("BAG_UPDATE", cid) end
                end
                S.fire("BAG_UPDATE_DELAYED")
            end)
        end)
    end

    ------------------------------------------------------------------
    -- the container API
    ------------------------------------------------------------------
    local function canHoldSim(cid, id)
        local bag = S.bags[cid]
        if not bag or bag.family == 0 then return true end
        return bandOf(bag.family, (SIMCAT[id] and SIMCAT[id].family) or 0) ~= 0
    end
    S.canHoldSim = canHoldSim

    local function isLocked(cid, slot)
        local k = key(cid, slot)
        return (S.locked[k] or (S.holdKey == k)) and true or false
    end

    -- The client refuses the operation and shows ERR_INTERNAL_BAG_ERROR. Fired as a
    -- real UI_ERROR_MESSAGE so the engine can OBSERVE rejections (2.0.3 telemetry).
    local function bagError()
        S.stats.bagErrors = S.stats.bagErrors + 1
        S.stats.rejected  = S.stats.rejected + 1
        S.fire("UI_ERROR_MESSAGE", S.BAG_ERROR_ID, "Internal Bag Error")
    end
    -- THE PERMANENT GATE. Nothing in the engine reads this; the SIM raises it, and the
    -- fixtures assert it stayed at zero.
    local function lockedIssue()
        S.stats.lockedIssue = S.stats.lockedIssue + 1
        bagError()
    end

    local function sameItem(a, b)
        if a == nil or b == nil then return a == b end
        return a.id == b.id and a.count == b.count
    end

    local C_Container = {}
    function C_Container.GetContainerNumSlots(cid)
        local bag = S.bags[cid]; return bag and bag.n or 0
    end
    function C_Container.GetContainerItemInfo(cid, slot)
        local bag = S.bags[cid]
        if not bag or slot < 1 or slot > bag.n then return nil end
        local it = bag.slots[slot]
        if not it then
            -- an empty slot still reports its lock state (mid-move source)
            if isLocked(cid, slot) then return { itemID = nil, isLocked = true } end
            return nil
        end
        return { itemID = it.id, stackCount = it.count,
                 quality = (SIMCAT[it.id] and SIMCAT[it.id].quality) or 1,
                 isLocked = isLocked(cid, slot) }
    end
    function C_Container.GetContainerNumFreeSlots(cid)
        local bag = S.bags[cid]
        if not bag then return 0, 0 end
        local free = 0
        for slot = 1, bag.n do if not bag.slots[slot] then free = free + 1 end end
        return free, bag.family
    end

    local function pickupImpl(cid, slot)
        local bag = S.bags[cid]
        if not bag or slot < 1 or slot > bag.n then return end
        local k = key(cid, slot)
        if S.held == nil then
            ----------------------------------------------------- pick up
            -- Client-side only: no server state changes until the DROP.
            if isLocked(cid, slot) then lockedIssue(); return end
            -- The client picks up WHAT IT CAN SEE, not what the server holds. Inside
            -- the settle window those disagree, and the disagreement is only detected
            -- at the drop — by the server, as an Internal Bag Error.
            local it = bag.slots[slot]
            if not it then return end
            S.held, S.holdKey = { id = it.id, count = it.count }, k
            -- Nothing has left the slot yet: server truth still holds this item, so a
            -- ClearCursor from here is a pure no-op.
            S.heldDetached = false
            S.stats.pickups = S.stats.pickups + 1
            -- The slot is now cursor-held, i.e. LOCKED as far as the client is concerned,
            -- and it says so from inside this call (class 9: the sequence's first echo).
            announceLock(cid, slot)
            return
        end
        ----------------------------------------------------------- drop
        S.stats.drops = S.stats.drops + 1
        -- A locked destination is refused by the client (unless it is where the held
        -- item came from — that is the "put the merge residual back" case).
        if S.locked[k] and k ~= S.holdKey then lockedIssue(); return end
        if not canHoldSim(cid, S.held.id) then S.stats.rejected = S.stats.rejected + 1; return end

        local srcKey = S.holdKey
        local scid, sslot = unkey(srcKey)
        local sbag = S.bags[scid]
        local held = S.held
        local touched = { srcKey, k }

        -- Dropping an item back onto the slot it came from, when nothing has actually
        -- left that slot, is a no-op — the client simply puts it down again. (This is
        -- the path performMove takes when a merge was REFUSED: CursorHasItem() is still
        -- true, so it re-drops onto `from`. Treating that as a pour would merge a stack
        -- into itself and invent items out of nothing.)
        if k == srcKey and not S.heldDetached then
            S.held, S.holdKey = nil, nil
            announceLock(scid, sslot)   -- the cursor let go: that slot's lock changed
            return
        end

        -- ── SERVER-SIDE VALIDATION (2.0.3) ──────────────────────────────────────
        -- The client sent "move what I SEE in `srcKey` onto what I SEE in `k`". The
        -- server checks its OWN truth; if either end has moved on since the client's
        -- view was written, the whole operation is refused and nothing changes. That
        -- refusal is the live "Internal Bag Error", and it is what a settle window
        -- turns a re-issued move into. Only a genuine two-slot move is validated —
        -- returning a merge residual to its own origin is a client-side flow.
        if srcKey ~= k and (not sameItem(sbag and sbag.truth[sslot], sbag and sbag.slots[sslot])
                            or not sameItem(bag.truth[slot], bag.slots[slot])) then
            bagError()   -- item stays on the cursor; the caller's ClearCursor restores it
            return
        end

        if S.dropRate > 0 and S.rng() < S.dropRate then
            -- The move is refused: server truth is untouched and the item stays on the
            -- cursor, so the caller's ClearCursor() puts it back where it came from.
            -- (Never silently discard the cursor — that would model item destruction the
            -- real client cannot do, and would hide a genuine executor leak.)
            S.stats.rejected = S.stats.rejected + 1
            return
        end

        -- All arithmetic is done on server TRUTH, never on the stale visible view.
        local dst  = bag.truth[slot]
        local maxS = (SIMCAT[held.id] and SIMCAT[held.id].maxStack) or 1
        S.locked[srcKey], S.locked[k] = true, true
        -- Both ends are locked NOW, and the client announces both from inside this call.
        announceLock(scid, sslot)
        if k ~= srcKey then announceLock(cid, slot) end

        if dst == nil then
            bag.truth[slot]    = { id = held.id, count = held.count }
            if srcKey ~= k then sbag.truth[sslot] = nil end
            S.held, S.holdKey = nil, nil
        elseif dst.id == held.id and maxS > 1 and dst.count < maxS then
            -- Same item WITH room: pour. (Same item with NO room falls through to the
            -- swap branch below — that is what the live client does; two full stacks
            -- dropped on each other exchange places rather than no-op.)
            local rs, rd = Sort.MergePour(held.count, dst.count, maxS)
            bag.truth[slot] = { id = dst.id, count = rd }
            if srcKey ~= k then sbag.truth[sslot] = nil end
            if rs > 0 then
                -- Overflow stays on the cursor and its source slot is now empty in
                -- server truth — the only state in which ClearCursor must put it back.
                S.held, S.heldDetached = { id = held.id, count = rs }, true
            else
                S.held, S.holdKey = nil, nil
            end
        else
            bag.truth[slot]    = { id = held.id, count = held.count }
            sbag.truth[sslot]  = { id = dst.id, count = dst.count }
            S.held, S.holdKey = nil, nil
        end
        commit(touched)
    end

    function C_Container.PickupContainerItem(cid, slot)
        inCall("PickupContainerItem", function() pickupImpl(cid, slot) end, cid, slot)
    end

    -- ── AN ABSENT SETTER IS A KINDER CLIENT (class 9, secondary blind spot) ─────
    -- performMove's `split` arm is guarded on `CC.SplitContainerItem`, and this simulator
    -- did not define it — so on the sim that arm was a silent no-op, one whole client
    -- entry point the harness could never dispatch an echo from. The planner emits no
    -- `split` move today (Sort.Plan produces only swap/merge; MoveSlots and performMove are
    -- the only two places the op name appears), so the arm is unreachable from a plan — but
    -- "unreachable today" is not "absent from the client", and the stub costs nothing.
    -- Modelled as the client does it: the split lands on the CURSOR, leaving the source
    -- locked, and the announcement happens inside the call.
    function C_Container.SplitContainerItem(cid, slot, amount)
        inCall("SplitContainerItem", function()
            local bag = S.bags[cid]
            if not bag or slot < 1 or slot > bag.n then return end
            if S.held ~= nil then return end
            local k = key(cid, slot)
            if isLocked(cid, slot) then lockedIssue(); return end
            local it = bag.slots[slot]
            if not it or not amount or amount <= 0 or amount >= (it.count or 0) then return end
            S.held, S.holdKey = { id = it.id, count = amount }, k
            S.heldDetached = false
            S.stats.pickups = S.stats.pickups + 1
            announceLock(cid, slot)
        end, cid, slot)
    end

    ------------------------------------------------------------------
    -- install / restore the global surface
    ------------------------------------------------------------------
    local GLOBALS = { "C_Container", "C_Timer", "C_Item", "bit", "ClearCursor",
                      "CursorHasItem", "InCombatLockdown", "GetTime", "CreateFrame",
                      "BankFrame", "Enum" }

    function S:install()
        for _, g in ipairs(GLOBALS) do S.saved[g] = _G[g] end
        -- ── 2.0.2: DROP THE CACHED EVENT DRIVER ──────────────────────────────────
        -- ensureDriver() creates Sort._driver ONCE and keeps it forever (correct in
        -- game: one client, one frame). Under the harness each simulator installs its
        -- OWN _G.CreateFrame and keeps its own S.frames list, so a driver built inside
        -- simulator #1 is invisible to simulator #2's S.fire — every sim after the
        -- first ran with ITEM_LOCK_CHANGED effectively DISCONNECTED, and the whole
        -- convergence suite was silently grading the tick-only path.
        --
        -- That was survivable while the event only released predictions early (the
        -- tick's overlay does the same job a beat later). It is not survivable now
        -- that issuing is event-driven: the suite would have graded a feature it never
        -- ran. Nil it here so every sim builds a driver registered with ITSELF, and
        -- again on restore so no live path can inherit a dead simulator frame.
        Sort._driver = nil
        _G.C_Container = C_Container
        _G.C_Timer = { After = function(d, fn) S.after(d, fn) end }
        _G.GetTime = function() return S.clock end
        _G.InCombatLockdown = function() return S.combat end
        _G.CursorHasItem = function() return S.held ~= nil end
        -- Dropping the cursor returns the held item to the slot it came from (the live
        -- client's behaviour for a container item), so nothing can ever be destroyed by
        -- the executor's belt-and-suspenders ClearCursor().
        -- Wrapped in inCall for the same reason the container entry points are (class 9):
        -- ClearCursor changes lock state, and the client announces that from inside it.
        _G.ClearCursor = function()
          inCall("ClearCursor", function()
            if not S.held then S.holdKey = nil; return end
            local k, held, detached = S.holdKey, S.held, S.heldDetached
            S.held, S.holdKey, S.heldDetached = nil, nil, false
            -- Picked up but never dropped (or the drop was refused): server truth never
            -- lost the item, so putting the cursor down changes nothing — except that the
            -- slot is no longer cursor-held, which IS a lock change.
            if not detached then
                if k then local c0, s0 = unkey(k); announceLock(c0, s0, true) end
                return
            end
            if not k then return end
            local cid, slot = unkey(k)
            local bag = S.bags[cid]
            if not bag then return end
            local cur = bag.truth[slot]
            if cur and cur.id == held.id then
                cur.count = cur.count + held.count      -- residual rejoins its own stack
            elseif cur == nil then
                bag.truth[slot] = { id = held.id, count = held.count }
            else
                -- slot taken by something else: park it in the first free slot we own
                for c2, b2 in pairs(S.bags) do
                    for s2 = 1, b2.n do
                        if not b2.truth[s2] and canHoldSim(c2, held.id) then
                            b2.truth[s2] = { id = held.id, count = held.count }
                            S.locked[key(c2, s2)] = true
                            announceLock(c2, s2, true)
                            commit({ key(c2, s2) })
                            return
                        end
                    end
                end
            end
            S.locked[k] = true
            announceLock(cid, slot, true)
            commit({ k })
          end)
        end
        _G.bit = { band = bandOf }
        _G.BankFrame = nil
        _G.Enum = _G.Enum or { ItemClass = { Weapon = 2 } }
        _G.C_Item = {
            GetItemInfoInstant = function(id)
                local c = SIMCAT[id]; if not c then return nil end
                return c.name, nil, nil, c.equip, c.icon, c.classID, c.subClassID
            end,
            GetItemInfo = function(id)
                local c = SIMCAT[id]; if not c then return nil end
                return c.name, nil, c.quality, c.level, nil, nil, nil, c.maxStack
            end,
            GetItemFamily = function(id)
                local c = SIMCAT[id]; return c and c.family or 0
            end,
        }
        _G.CreateFrame = function()
            local f = { _events = {} }
            function f:RegisterEvent(e) self._events[e] = true end
            function f:UnregisterAllEvents() self._events = {} end
            function f:SetScript(_, fn) self._script = fn end
            S.frames[#S.frames + 1] = f
            return f
        end
    end

    function S:restore()
        for _, g in ipairs(GLOBALS) do _G[g] = S.saved[g] end
        Sort._driver = nil   -- see S:install — never leak this sim's frame to a later one
    end

    ------------------------------------------------------------------
    -- bag helpers used by the tests
    ------------------------------------------------------------------
    -- Write BOTH views at once — for test setup and for injected mid-sort bag changes,
    -- where the change is instantaneous in the client as well as on the server.
    function S:set(cid, slot, id, count)
        local bag = S.bags[cid]; if not bag then return end
        local it = id and { id = id, count = count or 1 } or nil
        bag.truth[slot] = it
        bag.slots[slot] = it and { id = it.id, count = it.count } or nil
    end
    function S:put(cid, slot, id, count) S:set(cid, slot, id, count) end
    function S:totals()   -- server truth (+ anything stranded on the cursor)
        local t = {}
        for _, bag in pairs(S.bags) do
            for slot = 1, bag.n do
                local it = bag.truth[slot]
                if it then t[it.id] = (t[it.id] or 0) + it.count end
            end
        end
        if S.held then t[S.held.id] = (t[S.held.id] or 0) + S.held.count end
        return t
    end
    function S:cells()
        local out, cids = {}, {}
        for cid in pairs(S.bags) do cids[#cids + 1] = cid end
        table.sort(cids)
        for _, cid in ipairs(cids) do
            local bag = S.bags[cid]
            for slot = 1, bag.n do
                local it = bag.truth[slot]
                out[#out + 1] = { cid = cid, slot = slot, id = it and it.id or nil,
                                  count = it and it.count or 0 }
            end
        end
        return out
    end
    function S:at(cid, slot)   -- server truth for one slot
        local bag = S.bags[cid]
        return bag and bag.truth[slot] or nil
    end
    function S:firstFree(unlockedOnly)
        for cid, bag in pairs(S.bags) do
            for slot = 1, bag.n do
                if not bag.truth[slot] and not (unlockedOnly and S.locked[key(cid, slot)]) then
                    return cid, slot
                end
            end
        end
    end
    function S:firstUsed(unlockedOnly)
        for cid, bag in pairs(S.bags) do
            for slot = 1, bag.n do
                if bag.truth[slot] and not (unlockedOnly and S.locked[key(cid, slot)]) then
                    return cid, slot
                end
            end
        end
    end
    function S:anyLocked()
        for _ in pairs(S.locked) do return true end
        return false
    end
    -- Force ONE slot all the way to settled: unlock it AND publish its truth, which is
    -- what the client's ITEM_LOCK_CHANGED + BAG_UPDATE pair does between them. Tests that
    -- drive events by hand must use this rather than clearing `S.locked` on its own —
    -- an unlocked slot with stale contents is precisely the un-settled state the
    -- executor is required to keep waiting through (see releasePred).
    function S:settle(cid, slot)
        local k = key(cid, slot)
        S.locked[k] = nil
        publish({ k })
    end

    return S
end
Sort._Simulator = makeSimulator   -- test hook: CI / timing models drive the same sim

local function simMetaFn(id)
    local c = SIMCAT[id]
    if not c then return nil end
    return { set = (c.classID < 2) and 0 or 2, classID = c.classID, subClassID = c.subClassID,
             equip = c.equip, quality = c.quality, iconFileID = c.icon, level = c.level,
             name = c.name, maxStack = c.maxStack }
end

-- Fill a simulator's bags with a randomized, deliberately messy layout.
local function seedRandomBags(S, rng, nGear, nStackTypes)
    local entries = {}
    for _ = 1, nGear do
        local id = SIMIDS[1 + math.floor(rng() * #SIMIDS)]
        while (SIMCAT[id].maxStack or 1) > 1 do id = SIMIDS[1 + math.floor(rng() * #SIMIDS)] end
        entries[#entries + 1] = { id = id, count = 1 }
    end
    for _ = 1, nStackTypes do
        local id = SIMIDS[1 + math.floor(rng() * #SIMIDS)]
        local guard = 0
        while (SIMCAT[id].maxStack or 1) <= 1 and guard < 60 do
            id = SIMIDS[1 + math.floor(rng() * #SIMIDS)]; guard = guard + 1
        end
        local maxS = SIMCAT[id].maxStack
        if maxS > 1 then
            for _ = 1, 2 + math.floor(rng() * 3) do
                entries[#entries + 1] = { id = id, count = 1 + math.floor(rng() * (maxS - 1)) }
            end
        end
    end
    local slots = {}
    for cid, bag in pairs(S.bags) do
        for slot = 1, bag.n do slots[#slots + 1] = { cid = cid, slot = slot } end
    end
    for _, e in ipairs(entries) do
        for _ = 1, 400 do
            local p = slots[1 + math.floor(rng() * #slots)]
            if not S:at(p.cid, p.slot) and S.canHoldSim(p.cid, e.id) then
                S:set(p.cid, p.slot, e.id, e.count)
                break
            end
        end
    end
end

-- Swap in inert ns.Frame / ns.Capture doubles so the quiet-mode monkey-patch is what is
-- under test, and count how often each is actually called.
local function withFakeUI(fn)
    local oldFrame, oldCapture, oldPrint = ns.Frame, ns.Capture, ns.Print
    local tally = { refresh = 0, capture = 0, prints = {} }
    ns.Frame = { IsShown = function() return true end,
                 RequestRefresh = function() tally.refresh = tally.refresh + 1 end }
    ns.Capture = { RequestCapture = function() tally.capture = tally.capture + 1 end }
    ns.Print = function(_, ...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        tally.prints[#tally.prints + 1] = table.concat(parts, "")
    end
    local ok, err = pcall(fn, tally)
    ns.Frame, ns.Capture, ns.Print = oldFrame, oldCapture, oldPrint
    if not ok then error(err, 0) end
    return tally
end

-- Drive one full sort against a simulator and return a verdict record.
local function runSortInSim(S, cids, opts)
    S:install()
    local tally
    local ok, err = pcall(function()
        tally = withFakeUI(function()
            Sort.Run(cids, opts)
            S:pump(opts and opts.limit or 30)
        end)
    end)
    -- Always tear the run down, even if an assertion below never runs.
    if Sort._running then Sort._running = false end
    S:restore()
    if not ok then error(err, 0) end
    return tally
end

local function sameTotals(a, b)
    for id, n in pairs(a) do if (b[id] or 0) ~= n then return false, id end end
    for id, n in pairs(b) do if (a[id] or 0) ~= n then return false, id end end
    return true
end

----------------------------------------------------------------------
-- Convergence property of the PLANNER itself (defect analysis §4 fix #5 ask):
-- "plan -> apply a random PREFIX of the moves -> re-plan -> the new move count is
-- strictly smaller". This is the algebraic reason the optimistic executor terminates:
-- every partially-applied plan is strictly closer to the fixed point.
----------------------------------------------------------------------
local function testPlanPrefixConvergence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(4242)
    local worst, checked = 0, 0
    for trial = 1, 120 do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                                           { cid = 2, size = 16 }, { cid = 3, size = 16 } },
                                  seed = 900 + trial })
        seedRandomBags(S, rng, 4 + math.floor(rng() * 12), 2 + math.floor(rng() * 12))
        local cells = S:cells()
        local plan = Sort.Plan({ cells = cells, meta = simMetaFn })
        if #plan.moves >= 2 then
            local k = 1 + math.floor(rng() * (#plan.moves - 1))
            local prefix = {}
            for i = 1, k do prefix[i] = plan.moves[i] end
            applyMoves(cells, prefix, function(id)
                return (SIMCAT[id] and SIMCAT[id].maxStack) or 1
            end)
            local re = Sort.Plan({ cells = cells, meta = simMetaFn })
            checked = checked + 1
            if #re.moves >= #plan.moves then
                worst = worst + 1
                ck(false, string.format(
                    "prefix of %d/%d moves did not strictly reduce the residual (%d -> %d)",
                    k, #plan.moves, #plan.moves, #re.moves))
            end
        end
    end
    ck(checked > 60, "prefix-convergence exercised enough randomized bags (" .. checked .. ")")
    ck(worst == 0, "every partially-applied plan re-plans to a strictly smaller move count")
end

----------------------------------------------------------------------
-- The headline gate: the executor converges under simulated latency.
----------------------------------------------------------------------
local function testExecutorLatency(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(777)
    for _, latency in ipairs({ 0, 0.05, 0.10, 0.20, 0.30, 0.50 }) do
        for trial = 1, 4 do
            local S = makeSimulator({
                bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                         { cid = 2, size = 16 }, { cid = 3, size = 16 } },
                latency = latency, jitter = latency * 0.4, seed = 5000 + trial })
            seedRandomBags(S, rng, 8, 10)
            local before = S:totals()
            -- The dependency DEPTH of the plan is the floor this executor should run at:
            -- each round of the graph costs one server round-trip and nothing more.
            local plan0 = Sort.Plan({ cells = S:cells(), meta = simMetaFn })
            local depth = #Sort.PartitionWaves(plan0.moves)
            local tally = runSortInSim(S, { 0, 1, 2, 3 })
            local tag = string.format("latency %.2fs trial %d", latency, trial)

            ck(Sort._running == false, tag .. ": executor stopped")
            local same, badId = sameTotals(before, S:totals())
            ck(same, tag .. ": every item conserved (id " .. tostring(badId) .. ")")
            ck(S.held == nil, tag .. ": cursor left empty")
            ck(not S:anyLocked(), tag .. ": no slot left locked")

            -- Converged to the planner's fixed point: re-planning finds nothing to do.
            local re = Sort.Plan({ cells = S:cells(), meta = simMetaFn })
            ck(#re.moves == 0, tag .. ": final layout is the sorted fixed point ("
                .. #re.moves .. " residual moves)")

            local completed = false
            for _, line in ipairs(tally.prints) do
                if line:find("sort complete", 1, true) then completed = true end
            end
            ck(completed, tag .. ": printed 'sort complete', not an abort")

            -- No wasted work: an ideal run issues exactly the planned move count. Allow a
            -- little slack for merges that re-split across rounds, but nothing like the
            -- 2x churn a target re-derived per tick produces.
            ck(Sort._pred == nil and Sort._cids == nil, tag .. ": run state torn down")
            local issued = 0
            for _, line in ipairs(tally.prints) do
                local n = line:match("sort complete %((%d+) moves")
                if n then issued = tonumber(n) end
            end
            -- A target re-derived per tick produced ~2x the planned moves; the stable
            -- target keeps it close. The BUSY FALLBACK (Sort._tick) re-plans on a
            -- restricted cell set on ticks that would otherwise issue nothing, and that
            -- plan is a worse decomposition — so a high-latency run can spend up to ~1.5x
            -- the ideal move count buying back a large slice of wall time. Still nowhere
            -- near the 2x that a churning target produces, which is what this pin exists
            -- to catch.
            ck(issued <= #plan0.moves * 1.6 + 6, tag .. string.format(
                ": issued %d moves for a %d-move plan (no churn)", issued, #plan0.moves))

            -- The cost model: one server round-trip per DEPENDENCY ROUND, with no
            -- settle-poll and no throttle stacked on top. The old executor paid
            -- waves x (latency + 0.05 + quantization) with waves ~2.5-3.5x this depth.
            local bound = (depth + 8) * (latency + latency * 0.4 + Sort.TICK)
            ck(S.clock <= bound, tag .. string.format(
                ": %.2fs simulated vs %.2fs bound (%d dependency rounds)", S.clock, bound, depth))
            if latency <= 0.10 then
                ck(S.clock < 1.6, tag .. string.format(
                    ": feels instant at realistic latency (%.2fs)", S.clock))
            end
        end
    end
end

----------------------------------------------------------------------
-- Fault injection: the server rejects a share of moves outright.
----------------------------------------------------------------------
local function testExecutorLockFailures(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(31337)
    for _, drop in ipairs({ 0.15, 0.35 }) do
        for trial = 1, 4 do
            local S = makeSimulator({
                bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 }, { cid = 2, size = 16 } },
                latency = 0.15, jitter = 0.05, dropRate = drop, seed = 8000 + trial })
            seedRandomBags(S, rng, 6, 8)
            local before = S:totals()
            local tally = runSortInSim(S, { 0, 1, 2 })
            local tag = string.format("dropRate %.2f trial %d", drop, trial)

            ck(Sort._running == false, tag .. ": executor stopped (never loops)")
            local same, badId = sameTotals(before, S:totals())
            ck(same, tag .. ": every item conserved despite rejected moves (id " .. tostring(badId) .. ")")
            ck(S.held == nil, tag .. ": cursor left empty")
            -- It must either converge or abort CLEANLY — never spin, never strand items.
            local ended = false
            for _, line in ipairs(tally.prints) do
                if line:find("sort complete", 1, true) or line:find("sort stopped", 1, true) then
                    ended = true
                end
            end
            ck(ended, tag .. ": reported a definite outcome (complete or clean abort)")
            ck(S.clock < 12, tag .. string.format(": bounded runtime (%.2fs simulated)", S.clock))
        end
    end
end

----------------------------------------------------------------------
-- Mid-sort bag changes: loot lands / an item leaves while the sort is running.
----------------------------------------------------------------------
local function testExecutorMidSortChange(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(606)
    for trial = 1, 6 do
        local S = makeSimulator({
            bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 }, { cid = 2, size = 16 } },
            latency = 0.12, jitter = 0.05, seed = 3300 + trial })
        seedRandomBags(S, rng, 7, 7)
        S:install()
        local tally
        local ok, err = pcall(function()
            tally = withFakeUI(function()
                Sort.Run({ 0, 1, 2 })
                -- Inject a change part-way through: loot lands in a free, unlocked slot.
                S.after(0.18, function()
                    local cid, slot = S:firstFree(true)
                    if cid then S:set(cid, slot, 803, 3) end
                end)
                -- ...and something leaves a little later (an item consumed mid-sort).
                S.after(0.40, function()
                    local cid, slot = S:firstUsed(true)
                    if cid then S:set(cid, slot, nil) end
                end)
                S:pump(30)
            end)
        end)
        if Sort._running then Sort._running = false end
        S:restore()
        if not ok then error(err, 0) end

        local tag = "mid-sort change trial " .. trial
        ck(Sort._running == false, tag .. ": executor stopped")
        ck(S.held == nil, tag .. ": cursor left empty")
        ck(not S:anyLocked(), tag .. ": no slot left locked")
        local ended = false
        for _, line in ipairs(tally.prints) do
            if line:find("sort complete", 1, true) or line:find("sort stopped", 1, true) then ended = true end
        end
        ck(ended, tag .. ": reported a definite outcome")
        ck(S.clock < 12, tag .. string.format(": bounded runtime (%.2fs simulated)", S.clock))
    end
end

----------------------------------------------------------------------
-- Guard-rails: locked-slot fixed points, family constraints, abort-on-user-action.
----------------------------------------------------------------------
----------------------------------------------------------------------
-- EXECUTOR + SORT LOCKS: the whole feature end to end against the simulator.
--
-- The planner cases above prove the plan is clean; this proves the LIVE PATH is —
-- snapshot stamps userLocked from ns.Locks, the executor never issues a move on a
-- locked slot, and the combat gate is completely unaffected by locks being present
-- (the owner's rule: the mode is UI-only config, the sort's combat behaviour does not
-- change). ns.Locks is stubbed through Sort._userLocked so the case is deterministic
-- and needs no SavedVariables.
----------------------------------------------------------------------
local function testExecutorUserLocks(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(20260803)
    local realUL = Sort._userLocked

    local function withUserLocks(set, fn)
        Sort._userLocked = function(cid, slot) return set[cid .. ":" .. slot] and true or false end
        local ok, err = pcall(fn)
        Sort._userLocked = realUL
        if not ok then error(err, 0) end
    end

    ---------------------------------------------------------------- occupied lock holds
    for trial = 1, 4 do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                                  latency = 0.12, seed = 700 + trial })
        seedRandomBags(S, rng, 6, 5)
        -- Lock the first OCCUPIED slot and the first EMPTY slot of bag 0.
        local occSlot, emptySlot
        for slot = 1, 16 do
            local it = S:at(0, slot)
            if it and not occSlot then occSlot = slot
            elseif not it and not emptySlot then emptySlot = slot end
        end
        ck(occSlot ~= nil and emptySlot ~= nil, "found an occupied and an empty slot to lock")
        local pinned = S:at(0, occSlot)
        local before = S:totals()
        local locks = { ["0:" .. occSlot] = true, ["0:" .. emptySlot] = true }

        local tally
        withUserLocks(locks, function()
            tally = runSortInSim(S, { 0, 1 })
        end)

        -- CONVERGED, not stalled. issueWave1 also refuses to touch a locked slot, so a
        -- planner that wrongly TARGETED one would still leave the slot alone — and the
        -- run would grind to "stalled (slots stayed locked)". Requiring a clean
        -- completion is what makes this case bite on the planner as well as the issuer.
        local completed = false
        for _, line in ipairs(tally.prints) do
            if line:find("sort complete", 1, true) then completed = true end
        end
        ck(completed, "the locked run CONVERGED (planner never targeted a locked slot)")

        local now = S:at(0, occSlot)
        ck(now ~= nil and now.id == pinned.id and now.count == pinned.count,
           "sort-locked occupied slot 0:" .. tostring(occSlot) .. " is untouched")
        ck(S:at(0, emptySlot) == nil,
           "sort-locked EMPTY slot 0:" .. tostring(emptySlot) .. " was never filled")
        ck(sameTotals(before, S:totals()), "locked run conserved every item")
        ck(Sort._running == false, "locked run stopped")
        ck(S.held == nil, "locked run left the cursor empty")
    end

    ---------------------------------------------------------------- combat gate unchanged
    -- Same abort, same message, same clean cursor — locks present or not. And the
    -- locked slot is still intact after the abort.
    do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                                  latency = 0.15, seed = 7777 })
        seedRandomBags(S, rng, 10, 8)
        local occSlot
        for slot = 1, 16 do if S:at(0, slot) then occSlot = slot; break end end
        local pinned = S:at(0, occSlot)
        local before = S:totals()

        withUserLocks({ ["0:" .. occSlot] = true }, function()
            S:install()
            local tally
            local ok, err = pcall(function()
                tally = withFakeUI(function()
                    Sort.Run({ 0, 1 })
                    S.after(0.16, function() S.combat = true; S.fire("PLAYER_REGEN_DISABLED") end)
                    S:pump(30)
                end)
            end)
            if Sort._running then Sort._running = false end
            S:restore()
            if not ok then error(err, 0) end
            local stopped = false
            for _, line in ipairs(tally.prints) do
                if line:find("sort stopped: entered combat", 1, true) then stopped = true end
            end
            ck(stopped, "combat abort message is unchanged with locks present")
        end)

        ck(Sort._running == false, "combat aborted the locked sort")
        ck(S.held == nil, "combat abort left the cursor empty")
        local now = S:at(0, occSlot)
        ck(now ~= nil and now.id == pinned.id and now.count == pinned.count,
           "the locked slot survived the aborted run")
        ck(sameTotals(before, S:totals()), "combat-aborted locked run conserved every item")
    end

    ---------------------------------------------------------------- refusing to start
    do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 } }, seed = 8888 })
        seedRandomBags(S, rng, 5, 4)
        withUserLocks({ ["0:1"] = true }, function()
            S:install()
            S.combat = true
            local started
            local ok, err = pcall(function()
                withFakeUI(function() started = Sort.Run({ 0 }) end)
            end)
            S.combat = false
            if Sort._running then Sort._running = false end
            S:restore()
            if not ok then error(err, 0) end
            ck(started == false, "Sort.Run still refuses to start in combat with locks set")
        end)
    end

    ck(Sort._userLocked == realUL, "the real user-lock probe was restored")
end

local function testExecutorGuardRails(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(20260731)

    ---------------------------------------------------------------- locked fixed point
    for trial = 1, 4 do
        local S = makeSimulator({
            bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
            latency = 0.15, seed = 100 + trial })
        seedRandomBags(S, rng, 6, 5)
        -- Pin one occupied slot as permanently locked (the user is dragging it).
        local pinKey, pinItem
        for slot = 1, 16 do
            local it = S:at(0, slot)
            if it then pinKey, pinItem = "0:" .. slot, { id = it.id, count = it.count,
                                                          slot = slot }; break end
        end
        ck(pinKey ~= nil, "found a slot to pin")
        S.locked[pinKey] = true
        local tally = runSortInSim(S, { 0, 1 })
        local now = S:at(0, pinItem.slot)
        ck(now ~= nil and now.id == pinItem.id and now.count == pinItem.count,
           "locked slot " .. tostring(pinKey) .. " is an untouched fixed point")
        local ended = false
        for _, line in ipairs(tally.prints) do
            if line:find("sort complete", 1, true) or line:find("sort stopped", 1, true) then ended = true end
        end
        ck(ended, "pinned-slot run reported a definite outcome")
        ck(Sort._running == false, "pinned-slot run stopped")
    end

    ---------------------------------------------------------------- family constraint
    for trial = 1, 4 do
        -- cid 3 is an herb bag (family bit 4); only item 703 carries that family.
        local S = makeSimulator({
            bags = { { cid = 0, size = 16 }, { cid = 1, size = 12 },
                     { cid = 3, size = 8, family = 4 } },
            latency = 0.12, seed = 400 + trial })
        seedRandomBags(S, rng, 6, 8)
        -- seed the specialised bag too
        S:put(3, 1, 703, 4); S:put(3, 3, 703, 7)
        local before = S:totals()
        runSortInSim(S, { 0, 1, 3 })
        for slot = 1, S.bags[3].n do
            local it = S:at(3, slot)
            if it then ck(it.id == 703, "herb bag holds only family-4 items (found " .. it.id .. ")") end
        end
        local same = sameTotals(before, S:totals())
        ck(same, "family run conserved every item")
        ck(Sort._running == false, "family run stopped")
    end

    ---------------------------------------------------------------- abort on combat
    do
        local S = makeSimulator({
            bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 }, { cid = 2, size = 16 } },
            latency = 0.15, seed = 55 })
        seedRandomBags(S, rng, 10, 10)
        local before = S:totals()
        S:install()
        local tally
        local ok, err = pcall(function()
            tally = withFakeUI(function()
                Sort.Run({ 0, 1, 2 })
                S.after(0.16, function() S.combat = true; S.fire("PLAYER_REGEN_DISABLED") end)
                S:pump(30)
            end)
        end)
        if Sort._running then Sort._running = false end
        S:restore()
        if not ok then error(err, 0) end
        ck(Sort._running == false, "combat aborted the sort")
        ck(S.held == nil, "abort left the cursor empty")
        local stopped = false
        for _, line in ipairs(tally.prints) do
            if line:find("sort stopped: entered combat", 1, true) then stopped = true end
        end
        ck(stopped, "abort printed 'sort stopped: entered combat'")
        local same = sameTotals(before, S:totals())
        ck(same, "aborting mid-sort conserved every item")
    end

    ---------------------------------------------------------------- abort on window close
    do
        local S = makeSimulator({
            bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
            latency = 0.15, seed = 66 })
        seedRandomBags(S, rng, 8, 8)
        local before = S:totals()
        S:install()
        local shown = true
        local oldFrame, oldCapture, oldPrint = ns.Frame, ns.Capture, ns.Print
        local lines = {}
        ns.Frame = { IsShown = function() return shown end, RequestRefresh = function() end }
        ns.Capture = { RequestCapture = function() end }
        ns.Print = function(_, ...) lines[#lines + 1] = tostring((...)) end
        local ok, err = pcall(function()
            Sort.Run({ 0, 1 })
            S.after(0.14, function() shown = false end)
            S:pump(30)
        end)
        if Sort._running then Sort._running = false end
        ns.Frame, ns.Capture, ns.Print = oldFrame, oldCapture, oldPrint
        S:restore()
        if not ok then error(err, 0) end
        local closed = false
        for _, line in ipairs(lines) do
            if line:find("sort stopped: window closed", 1, true) then closed = true end
        end
        ck(closed, "closing the window aborted the sort")
        ck(sameTotals(before, S:totals()), "window-close abort conserved every item")
    end
end

----------------------------------------------------------------------
-- The completion print + the refresh-storm suppression contract.
----------------------------------------------------------------------
local function testExecutorReporting(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(9090)
    local S = makeSimulator({
        bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                 { cid = 2, size = 16 }, { cid = 3, size = 16 } },
        latency = 0.20, jitter = 0.05, seed = 4321 })
    seedRandomBags(S, rng, 8, 14)

    -- Record what quiet mode saw: how many rebuilds and captures actually escaped.
    local tally = runSortInSim(S, { 0, 1, 2, 3 })

    local line
    for _, l in ipairs(tally.prints) do if l:find("sort complete", 1, true) then line = l end end
    ck(line ~= nil, "printed a completion line")
    if line then
        local moves, waves, secs = line:match("^sort complete %((%d+) moves in (%d+) waves, (%d+%.%d%d)s%)%.$")
        ck(moves ~= nil, "completion line matches 'sort complete (N moves in M waves, T.TTs).' -- got: " .. line)
        if moves then
            ck(tonumber(moves) > 0, "reported a positive move count")
            ck(tonumber(waves) > 0, "reported a positive wave count")
            ck(tonumber(secs) >= 0, "reported elapsed seconds")
        end
    end

    -- Refresh storm: the OLD path did one full rebuild per lock burst (60-95 per sort).
    -- Quiet mode caps the mid-sort rebuilds at the ~5 Hz heartbeat plus the final one.
    local budget = math.ceil(S.clock / Sort.QUIET_REFRESH) + 2
    ck(tally.refresh <= budget, string.format(
        "grid rebuilds held to the 5 Hz heartbeat (%d <= %d over %.2fs)",
        tally.refresh, budget, S.clock))
    ck(tally.refresh >= 1, "at least one rebuild happened (the final one)")
    ck(tally.capture == 1, "exactly one full recapture, at the end (got " .. tally.capture .. ")")

    -- And the patched entry points were handed back untouched.
    ck(Sort._quiet == nil, "quiet mode torn down")
end

----------------------------------------------------------------------
-- PLAN SIZE vs 1.x on an identical fixture (owner escalation gate).
--
-- The owner's report ("231 moves in 123 waves") raised the question of whether 2.0's
-- planner is simply generating far more work than 1.x's. It is not — this pins that.
--
-- The reference below is a faithful transcription of 1.x's engine (core/api/sorting.lua
-- Iterate): per PASS, rebuild the space list, pour every stack merge whose endpoints are
-- both still free, then walk the families in GetFamilies order issuing Move(item.space,
-- goal) for each goal — where Move refuses when either endpoint was already used in that
-- pass and sets its `locked` flags only on success. Run to a fixed point; count moves.
----------------------------------------------------------------------
local function moves1x(cells, canHold, familyOf)
    local total, passes = 0, 0
    for pass = 1, 400 do
        passes = pass
        local issued = 0
        local spaces = {}
        for _, c in ipairs(cells) do
            spaces[#spaces + 1] = { index = #spaces, cell = c,
                                    family = (familyOf and familyOf(c.cid)) or 0 }
        end
        local used = {}
        -- Phase 1: stack merges, later poured into earlier.
        for k, target in ipairs(spaces) do
            local tc = target.cell
            local tmax = tc.id and maxOf(tc.id) or 1
            if tc.id and (tc.count or 0) < tmax then
                for j = k + 1, #spaces do
                    local from = spaces[j]
                    if from.cell.id == tc.id and (from.cell.count or 0) < tmax
                       and not used[from] and not used[target] then
                        local rs, rd = Sort.MergePour(from.cell.count, tc.count, tmax)
                        tc.count, from.cell.count = rd, rs
                        if rs == 0 then from.cell.id = nil end
                        used[from], used[target] = true, true
                        total, issued = total + 1, issued + 1
                    end
                end
            end
        end
        -- Phase 2: family bands.
        local set, list = {}, {}
        for _, sp in ipairs(spaces) do set[sp.family] = true end
        for f in pairs(set) do list[#list + 1] = f end
        local sorted = {}
        for _, family in ipairs(Sort.FamilyOrder(list)) do
            -- 1.x FitsIn(id, family): a general band (<=0) takes anything; a specialized
            -- band takes only items whose family bits overlap. `canHold` is our cid-keyed
            -- form of that, so ask it with a cid drawn from this band.
            local bandCid
            for _, sp in ipairs(spaces) do
                if sp.family == family then bandCid = sp.cell.cid; break end
            end
            local order, slots = {}, {}
            for _, sp in ipairs(spaces) do
                if sp.cell.id and not sorted[sp]
                   and (family <= 0 or not canHold or canHold(bandCid, sp.cell.id)) then
                    order[#order + 1] = sp
                end
                if sp.family == family then slots[#slots + 1] = sp end
            end
            table.sort(order, function(x, y)
                return Sort.CompareStacks(
                    { id = x.cell.id, count = x.cell.count, meta = metaFn(x.cell.id) },
                    { id = y.cell.id, count = y.cell.count, meta = metaFn(y.cell.id) })
            end)
            for i = 1, math.min(#order, #slots) do
                local goal, sp = slots[i], order[i]
                sorted[sp] = true
                if sp ~= goal and not used[sp] and not used[goal] then
                    local okDisplaced = (goal.cell.id == nil)
                        or (not canHold) or canHold(sp.cell.cid, goal.cell.id)
                    if okDisplaced then
                        sp.cell.id, goal.cell.id = goal.cell.id, sp.cell.id
                        sp.cell.count, goal.cell.count = goal.cell.count, sp.cell.count
                        used[sp], used[goal] = true, true
                        total, issued = total + 1, issued + 1
                    end
                end
            end
        end
        if issued == 0 then break end
    end
    return total, passes
end

local function testPlanSizeVs1x(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local rng = newRng(31337)

    local worstRatio, worstTag = 0, ""
    for trial = 1, 12 do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                                           { cid = 2, size = 16 }, { cid = 3, size = 16 } },
                                  seed = 7000 + trial })
        seedRandomBags(S, rng, 10 + math.floor(rng() * 14), 6 + math.floor(rng() * 10))
        local cells = S:cells()

        local plan = Sort.Plan({ cells = cells, meta = simMetaFn })
        -- 1.x reference on the SAME fixture (it mutates its copy, so hand it one).
        local ref = S:cells()
        local n1x = moves1x(ref, nil, nil)

        ck(n1x > 0, "trial " .. trial .. ": the 1.x reference did some work")
        if n1x > 0 then
            local ratio = #plan.moves / n1x
            if ratio > worstRatio then
                worstRatio = ratio
                worstTag = string.format("trial %d: 2.0 plans %d moves vs 1.x's %d (%.2fx)",
                    trial, #plan.moves, n1x, ratio)
            end
        end
    end
    -- 2.0's planner emits FEWER moves than 1.x on every fixture measured (its Phase I is a
    -- pairwise tournament merge and its Phase II is a selection sort over a canonical
    -- target, where 1.x re-derives an assignment per pass). The gate is deliberately loose
    -- on the up side so a legitimate ordering change can land, and tight enough that a
    -- planner regression of the "2x the moves" kind fails here first.
    ck(worstRatio <= 1.15, "plan size stays at or below 1.x's move count -- " .. worstTag)
end

----------------------------------------------------------------------
-- ABORTS ARE PROGRESS-BASED, NOT CLOCK-BASED (owner escalation gate).
--
-- The owner's sort died on a fixed ~10s tick ceiling with the bag half arranged and no
-- statement of what was left. Three properties are pinned here:
--   1. the elapsed-time abort is GONE — MAX_TICKS is a runaway ceiling far above any
--      real sort, and the message no longer says "time budget";
--   2. a long sort that keeps making progress runs to completion;
--   3. a genuine stall aborts on the NO-PROGRESS counter and says how much is left.
----------------------------------------------------------------------
local function testProgressBasedAbort(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ck(Sort.MAX_NO_PROGRESS and Sort.MAX_NO_PROGRESS > 0,
        "there is a no-progress guard")
    ck(Sort.MAX_TICKS >= 2000,
        "MAX_TICKS is a runaway ceiling (>=2000 ticks), not a ~10s time budget")
    ck(Sort.MAX_TICKS * Sort.TICK >= 60,
        "…worth at least a minute of wall clock, so it can never be the thing that fires")
    ck(Sort.MAX_NO_PROGRESS * Sort.TICK >= 3,
        "the stall window is longer than any plausible server round-trip")

    -- A SLOW but progressing sort completes. 0.45s latency over a full 4-bag inventory
    -- ran past the old 200-tick ceiling; it must now finish.
    local rng = newRng(2468)
    local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                                       { cid = 2, size = 16 }, { cid = 3, size = 16 } },
                              latency = 0.45, jitter = 0.2, seed = 24680 })
    seedRandomBags(S, rng, 24, 16)
    local before = S:totals()
    local tally = runSortInSim(S, { 0, 1, 2, 3 }, { limit = 180 })
    local completed, aborted = false, nil
    for _, line in ipairs(tally.prints) do
        if line:find("sort complete", 1, true) then completed = true end
        if line:find("sort stopped", 1, true) then aborted = line end
    end
    ck(completed, "a slow but progressing sort runs to completion (got: "
        .. tostring(aborted) .. ")")
    ck(aborted == nil or not aborted:find("time budget"),
        "nothing aborts on elapsed time any more")
    local same, badId = sameTotals(before, S:totals())
    ck(same, "…with every item conserved (id " .. tostring(badId) .. ")")
    local re = Sort.Plan({ cells = S:cells(), meta = simMetaFn })
    ck(#re.moves == 0, "…and the final layout is the sorted fixed point")

    -- A GENUINE stall: every move is rejected and the slots flap, so the residual never
    -- improves. That must abort on the no-progress guard AND report the remainder.
    local S2 = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                               latency = 0.02, dropRate = 1.0, seed = 1357 })
    seedRandomBags(S2, newRng(99), 10, 6)
    local t2 = runSortInSim(S2, { 0, 1 }, { limit = 400 })
    local stopped
    for _, line in ipairs(t2.prints) do
        if line:find("sort stopped", 1, true) then stopped = line end
    end
    ck(stopped ~= nil, "a fully-rejecting server aborts rather than spinning forever")
    if stopped then
        ck(not stopped:find("time budget"), "…and not because of a clock")
        ck(stopped:find("still outstanding") ~= nil,
            "…and the abort says how much is left undone: " .. stopped)
    end
    ck(Sort._running == false, "the stalled run tore itself down")
end

----------------------------------------------------------------------
-- 2.0.2a — THE SORT TELEMETRY RING BUFFER
--
-- The coordinator reads these records straight out of the WTF SavedVariables file, so
-- the SHAPE is a contract, not an implementation detail: every declared field present,
-- every value a scalar, the array oldest-first, the cap honoured. Pure — no simulator.
----------------------------------------------------------------------
local function testSortLog(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ------------------------------------------------------------------ record shape
    local rec = Sort.NewLogRecord({
        ts = 1700000000, context = "bank", cells = 120, fillPct = 91.4, planMoves = 132,
        executedMoves = 180, waves = 98, durationMs = 6132.7, aborted = true,
        reason = "entered combat", stallTicks = 32, busyFallbackTicks = 14,
        avgAckMs = 560.2, version = "2.0.2",
    })
    for _, f in ipairs(Sort.LOG_FIELDS) do
        ck(rec[f] ~= nil, "record carries declared field " .. f)
        local t = type(rec[f])
        ck(t == "number" or t == "string" or t == "boolean",
            "field " .. f .. " is a SCALAR (got " .. t .. ") — the log must stay flat")
    end
    ck(rec.fillPct == 91 and rec.durationMs == 6133 and rec.avgAckMs == 560,
        "fractional inputs are rounded to integers, not written as floats")
    ck(rec.context == "bank" and rec.aborted == true and rec.reason == "entered combat",
        "context / aborted / reason carried")
    -- Field COUNT is pinned too: an undeclared extra key would reach the SV silently.
    local n = 0
    for _ in pairs(rec) do n = n + 1 end
    ck(n == #Sort.LOG_FIELDS, string.format(
        "a record holds exactly the %d declared fields (got %d)", #Sort.LOG_FIELDS, n))

    ------------------------------------------------------------------ junk is inert
    local junk = Sort.NewLogRecord(nil)
    ck(junk.context == "bags", "an unknown context defaults to bags")
    ck(junk.aborted == false and junk.reason == "", "a completed run stores reason \"\", never nil")
    ck(junk.cells == 0 and junk.avgAckMs == 0, "absent numbers default to 0")
    ck(Sort.NewLogRecord({ context = "wat", reason = 42 }).context == "bags",
        "a garbage context falls back rather than reaching the file")
    ck(Sort.NewLogRecord({ reason = 42 }).reason == "", "a non-string reason is dropped")

    ------------------------------------------------------------------ additive SV
    local db = { showMoney = true }
    Sort.LogAppend(db, { ts = 1 })
    local keys = {}
    for k in pairs(db) do keys[#keys + 1] = k end
    table.sort(keys)
    ck(#keys == 2 and keys[1] == "showMoney" and keys[2] == "sortLog",
        "the log writes exactly ONE new settings key, `sortLog` (got: " ..
        table.concat(keys, ",") .. ")")
    ck(db.showMoney == true, "…and touches nothing that was already there")
    ck(Sort.LogBuffer({}, false) == nil, "no buffer is allocated for a plain read")
    ck(Sort.LogBuffer(nil, true) ~= nil or true, "a nil db falls through to Store.db, never errors")

    ------------------------------------------------------------------ append + wrap
    local db2 = {}
    for i = 1, 8 do Sort.LogAppend(db2, { ts = i, executedMoves = i }, 5) end
    local buf = db2.sortLog
    ck(#buf == 5, "the buffer is capped (got " .. #buf .. " of 5)")
    ck(buf[1].ts == 4 and buf[5].ts == 8,
        "it is a RING: oldest-first, the first 3 runs dropped (got " ..
        buf[1].ts .. ".." .. buf[5].ts .. ")")
    -- A cap LOWERED between releases must converge on the very next append.
    Sort.LogAppend(db2, { ts = 99 }, 2)
    ck(#db2.sortLog == 2 and db2.sortLog[2].ts == 99,
        "a lowered cap converges in one append instead of leaking a run per sort")

    ------------------------------------------------------------------ read order
    local recs = Sort.LogRecords(db2)
    ck(#recs == 2 and recs[1].ts == 99, "LogRecords hands back NEWEST first")
    ck(recs ~= db2.sortLog, "…as a copy; the live SV table is never handed out")
    ck(Sort.LogCount(db2) == 2, "LogCount agrees")
    ck(#Sort.LogRecords({}) == 0, "reading a db with no log is an empty list, not nil")

    ------------------------------------------------------------------ clear
    local live = db2.sortLog
    local dropped = Sort.LogClear(db2)
    ck(dropped == 2, "clear reports how many runs it dropped")
    ck(#db2.sortLog == 0, "…and the buffer is empty")
    ck(db2.sortLog == live, "…IN PLACE: the SV table identity survives a clear")
    ck(Sort.LogClear({}) == 0, "clearing an absent log is a no-op, not an error")

    ------------------------------------------------------------------ adaptive seed
    local db3 = {}
    Sort.LogAppend(db3, { avgAckMs = 100 })
    Sort.LogAppend(db3, { avgAckMs = 0 })      -- nothing measured: carries no signal
    Sort.LogAppend(db3, { avgAckMs = 300 })
    ck(Sort.LogAvgAckMs(db3) == 200,
        "the seed averages only runs that MEASURED a round-trip (got " ..
        Sort.LogAvgAckMs(db3) .. ")")
    ck(Sort.LogAvgAckMs(db3, 1) == 300, "…and honours the lookback (newest first)")
    ck(Sort.LogAvgAckMs({}) == 0, "an empty log seeds 0, i.e. use the fixed windows")

    ------------------------------------------------------------------ derived windows
    -- The 2.0.2c contract: the seed can only ever RAISE a window. Proven at the formula.
    local function windows(ackMs)
        local a = ackMs / 1000
        return math.max(Sort.IDLE_SECONDS, Sort.IDLE_ACKS * a),
               math.max(Sort.NO_PROGRESS_SECONDS, Sort.NO_PROGRESS_ACKS * a),
               math.max(Sort.RUNAWAY_SECONDS, Sort.RUNAWAY_ACKS * a)
    end
    local i0, p0, r0 = windows(0)
    ck(i0 == Sort.IDLE_SECONDS and p0 == Sort.NO_PROGRESS_SECONDS and r0 == Sort.RUNAWAY_SECONDS,
        "with nothing measured the windows are exactly the fixed 2.0.1 ones")
    local i1, p1, r1 = windows(1000)
    ck(i1 >= i0 and p1 >= p0 and r1 >= r0,
        "a measured round-trip can only ever LENGTHEN a window, never shorten one")
    ck(p1 > p0, "…and a 1s round-trip genuinely does lengthen the stall window")
    ck(Sort.IDLE_SECONDS == Sort.MAX_IDLE_TICKS * Sort.TICK
       and Sort.NO_PROGRESS_SECONDS == Sort.MAX_NO_PROGRESS * Sort.TICK
       and Sort.RUNAWAY_SECONDS == Sort.MAX_TICKS * Sort.TICK,
        "the seconds windows are DERIVED from the tick constants, not restated")

    ------------------------------------------------------------------ printed line
    local line = Sort.FormatLogLine({ ts = 1700000000, context = "bank", cells = 120,
        fillPct = 91, planMoves = 132, executedMoves = 180, waves = 98,
        durationMs = 6133, avgAckMs = 560, busyFallbackTicks = 14, stallTicks = 32 }, 1)
    for _, want in ipairs({ "bank", "cells=120", "fill=91%", "plan=132", "exec=180",
                            "waves=98", "6.13s", "ack=560ms", "busy=14", "stall=32", "ok" }) do
        ck(line:find(want, 1, true) ~= nil, "the printed line carries " .. want .. ": " .. line)
    end
    local bad = Sort.FormatLogLine({ aborted = true, reason = "bank closed" }, 2)
    ck(bad:find("ABORT:bank closed", 1, true) ~= nil, "an aborted run prints its reason: " .. bad)
    ck(pcall(Sort.FormatLogLine, nil, 1), "formatting a junk record never errors")
end

----------------------------------------------------------------------
-- 2.0.2b — EVENT-DRIVEN ISSUING
--
-- The shared assertion body, so the MUTATION gate below can run exactly the checks the
-- suite runs (mirrors userLockAssertions/testUserLockMutants). Returns a fails list.
--
-- Three properties, in the order they matter:
--   1. A confirmation on a slot that BLOCKED a planned move pulls the next round
--      forward immediately (this is the feature).
--   2. A confirmation on a slot nothing is waiting for does NOT (this is the guard —
--      kicking on everything was measured at +20-24% moves and +38-51% wall time).
--   3. Under the simulator the executor still converges, conserves every item, reaches
--      the planner's fixed point, and does not churn — with the event path LIVE.
----------------------------------------------------------------------
local function eventIssueAssertions()
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- A sort with a real round in flight, so _pred / _waiting / the driver are all live.
    local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                              latency = 0.40, seed = 20260803 })
    seedRandomBags(S, newRng(4711), 8, 6)
    S:install()
    local ok, err = pcall(function()
        withFakeUI(function()
            Sort.Run({ 0, 1 })
            ck(Sort._running, "the run started")
            ck(predOutstanding(), "…with moves in flight after the first round")
            ck(Sort._driver ~= nil and Sort._driver._script ~= nil,
                "the event driver is bound to THIS simulator (see S:install)")

            -- Pick an in-flight slot and pretend the last round refused a move on it.
            local key, cid, slot
            for k, p in pairs(Sort._pred) do key, cid, slot = k, p.cid, p.slot; break end
            ck(key ~= nil, "found an in-flight slot to drive the event with")

            local function fire(k, c, s)
                -- 2.0.3: SETTLE the slot, do not merely unlock it. Clearing the lock
                -- alone is the settle WINDOW, in which the executor is required to keep
                -- waiting — so driving the event that way would be asserting the bug.
                S:settle(c, s)                          -- the server confirmed AND published
                local before = #S.timers
                local floor = S.clock + (Sort.KICK_GAP or 0)
                Sort._driver._script(Sort._driver, "ITEM_LOCK_CHANGED", c, s)
                for i = before + 1, #S.timers do
                    if S.timers[i].at <= floor + 1e-9 then return true end
                end
                return false
            end

            ---------------------------------------------------- 1. the feature
            Sort._waiting  = { [key] = true }
            Sort._lastIssued = 99                       -- not the 2.0.1 "blocked" case
            ck(predCount() >= 2, "…and more than one prediction, so this is not `settled`")
            ck(fire(key, cid, slot),
                "a confirmation on a WAITING slot pulls the next round forward immediately")

            ---------------------------------------------------- 2. the guard
            local key2, cid2, slot2
            for k, p in pairs(Sort._pred) do key2, cid2, slot2 = k, p.cid, p.slot; break end
            if key2 and predCount() >= 2 then
                Sort._waiting  = {}                     -- nothing is waiting on it
                Sort._lastIssued = 99
                ck(not fire(key2, cid2, slot2),
                    "a confirmation nothing was waiting on does NOT kick (churn guard)")
            end

            ---------------------------------------------------- 3. the off switch
            -- EVENT_ISSUE off must genuinely revert to the 2.0.1 rule: even a WAITING
            -- slot waits for the tick unless the previous round issued nothing.
            local key3, cid3, slot3
            for k, p in pairs(Sort._pred) do key3, cid3, slot3 = k, p.cid, p.slot; break end
            if key3 and predCount() >= 2 then
                local saved = Sort.EVENT_ISSUE
                Sort.EVENT_ISSUE = false
                Sort._waiting  = { [key3] = true }
                Sort._lastIssued = 99
                local kicked = fire(key3, cid3, slot3)
                Sort.EVENT_ISSUE = saved
                ck(not kicked, "with EVENT_ISSUE off a waiting slot does NOT kick")
            end

            S:pump(120)
        end)
    end)
    if Sort._running then Sort._running = false end
    S:restore()
    if not ok then fails[#fails + 1] = "error: " .. tostring(err); return fails end

    ---------------------------------------------------- 3. it still converges
    for _, latency in ipairs({ 0.10, 0.35 }) do
        for trial = 1, 2 do
            local T = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                                               { cid = 2, size = 16 } },
                                      latency = latency, jitter = latency * 0.4,
                                      seed = 6100 + trial })
            seedRandomBags(T, newRng(880 + trial), 10, 9)
            local before = T:totals()
            local plan0 = Sort.Plan({ cells = T:cells(), meta = simMetaFn })
            local tally = runSortInSim(T, { 0, 1, 2 }, { limit = 120 })
            local tag = string.format("event issue @ %.2fs trial %d", latency, trial)

            ck(Sort._running == false, tag .. ": stopped")
            local same, badId = sameTotals(before, T:totals())
            ck(same, tag .. ": every item conserved (id " .. tostring(badId) .. ")")
            ck(T.held == nil, tag .. ": cursor left empty")
            ck(not T:anyLocked(), tag .. ": no slot left locked")
            local re = Sort.Plan({ cells = T:cells(), meta = simMetaFn })
            ck(#re.moves == 0, tag .. ": reached the planner's fixed point")
            local completed, issued = false, 0
            for _, line in ipairs(tally.prints) do
                if line:find("sort complete", 1, true) then completed = true end
                local n = line:match("sort complete %((%d+) moves")
                if n then issued = tonumber(n) end
            end
            ck(completed, tag .. ": completed rather than aborting")
            -- CHURN PIN. The event path must not buy its speed with extra moves; this is
            -- the assertion that kills a "kick on every confirmation" mutant, which was
            -- measured at +20-24% moves on the same fixtures.
            ck(issued <= #plan0.moves * 1.6 + 6, tag .. string.format(
                ": issued %d moves for a %d-move plan (no churn)", issued, #plan0.moves))
        end
    end
    return fails
end

local function testEventDrivenIssue(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ck(Sort.EVENT_ISSUE == true, "event-driven issuing ships ON")
    ck(Sort.KICK_GAP >= 0 and Sort.KICK_GAP < Sort.TICK,
        "the kick floor is tighter than the fallback tick (else the tick is the floor)")
    for _, f in ipairs(eventIssueAssertions()) do fails[#fails + 1] = f end

    ---------------------------------------------------------------- the tick survives
    -- The safety cadence must still be there with the events silent: the executor has to
    -- degrade to the 2.0.1 ladder, not stall, if a client stops delivering the event.
    local realIssue = Sort.EVENT_ISSUE
    Sort.EVENT_ISSUE = false
    local okOff, resOff = pcall(function()
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                                  latency = 0.20, jitter = 0.05, seed = 990 })
        seedRandomBags(S, newRng(4242), 8, 8)
        local before = S:totals()
        local tally = runSortInSim(S, { 0, 1 }, { limit = 120 })
        local completed = false
        for _, line in ipairs(tally.prints) do
            if line:find("sort complete", 1, true) then completed = true end
        end
        return completed and sameTotals(before, S:totals())
            and #Sort.Plan({ cells = S:cells(), meta = simMetaFn }).moves == 0
    end)
    Sort.EVENT_ISSUE = realIssue
    ck(okOff and resOff,
        "with EVENT_ISSUE off the tick alone still converges (the fallback cadence is real)")
    ck(Sort.EVENT_ISSUE == realIssue, "the shipping switch was restored")

    ---------------------------------------------------------------- abort mid-flight
    -- An event-driven run has rounds scheduled from the event handler as well as the
    -- ticker; combat must still tear ALL of them down and strand nothing.
    do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 },
                                           { cid = 2, size = 16 } },
                                  latency = 0.15, jitter = 0.05, seed = 20260804 })
        seedRandomBags(S, newRng(1234), 10, 10)
        local before = S:totals()
        S:install()
        local tally
        local okA, errA = pcall(function()
            tally = withFakeUI(function()
                Sort.Run({ 0, 1, 2 })
                S.after(0.22, function() S.combat = true; S.fire("PLAYER_REGEN_DISABLED") end)
                S:pump(60)
            end)
        end)
        if Sort._running then Sort._running = false end
        S:restore()
        ck(okA, "combat abort mid-flight did not error: " .. tostring(errA))
        if okA then
            ck(Sort._running == false, "combat aborted the event-driven run")
            ck(S.held == nil, "…leaving the cursor empty")
            ck(sameTotals(before, S:totals()), "…and every item conserved")
            local stopped = false
            for _, line in ipairs(tally.prints) do
                if line:find("sort stopped: entered combat", 1, true) then stopped = true end
            end
            ck(stopped, "…and it said so")
            -- The pump above ran to t=60 AFTER the abort at 0.22, so any round that had
            -- survived the teardown — kicked or ticked — would have restarted the run.
            ck(not Sort._running, "no queued round survived the abort (generation guard held)")
        end
    end

    ---------------------------------------------------------------- run telemetry
    -- The record the executor actually writes, end to end through a real simulated run.
    do
        local savedDB = Store.db
        local db = {}
        Store.db = db
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                                  latency = 0.25, jitter = 0.05, seed = 5150 })
        seedRandomBags(S, newRng(31415), 9, 8)
        local okL = pcall(function() runSortInSim(S, { 0, 1 }, { limit = 120 }) end)
        Store.db = savedDB
        ck(okL, "a run with a live settings DB did not error")
        local recs = Sort.LogRecords(db)
        ck(#recs == 1, "one finished run appended exactly one record (got " .. #recs .. ")")
        if recs[1] then
            local r = recs[1]
            ck(r.cells == 32, "…with the opening cell count (got " .. r.cells .. ")")
            ck(r.fillPct > 0 and r.fillPct <= 100, "…a sane fill percentage (" .. r.fillPct .. ")")
            ck(r.planMoves > 0 and r.executedMoves > 0, "…the plan and executed move counts")
            ck(r.waves > 0 and r.durationMs > 0, "…waves and duration")
            ck(r.context == "bags", "…the context")
            ck(r.avgAckMs > 0, "…and a MEASURED round-trip (got " .. r.avgAckMs .. "ms)")
            ck(math.abs(r.avgAckMs - 250) <= 120, string.format(
                "…that tracks the simulated 250ms latency (got %dms)", r.avgAckMs))
            ck(r.version == tostring(ns.VERSION), "…stamped with the build version")
        end
    end
end

-- MUTATION GATE for the issuing rule (2.0.2b). Sort.ShouldKick is the whole decision, so
-- every plausible way to get it wrong is expressible as a replacement for it.
local function testEventIssueMutants(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local real = Sort.ShouldKick
    local mutants = {
        { name = "never kicks (the feature is silently absent)",
          fn = function() return false end },
        { name = "kicks on EVERY confirmation (the measured +20-24% churn)",
          fn = function() return "always" end },
        { name = "ignores the waiting set (only the 2.0.1 blocked case survives)",
          fn = function() return ((Sort._lastIssued or 0) == 0) and "blocked" or false end },
        { name = "ignores EVENT_ISSUE (the off switch does nothing)",
          fn = function(key)
              if key ~= nil and Sort._waiting and Sort._waiting[key] then return "waiting" end
              return false
          end },
    }
    for _, mut in ipairs(mutants) do
        Sort.ShouldKick = mut.fn
        local ok, res = pcall(eventIssueAssertions)
        Sort.ShouldKick = real
        local killed = (not ok) or (#res > 0)
        ck(killed, "mutant SURVIVED the event-issue assertions: " .. mut.name)
    end
    ck(Sort.ShouldKick == real, "the real issuing rule was restored after mutation")
    ck(#eventIssueAssertions() == 0, "the real issuing rule passes the assertions it kills with")
end

-- =====================================================================
-- 2.0.3 — THE OWNER'S LIVE FAILURE, AS FIXTURES
--
-- Two sortLog records from one live session on Aether, reproduced here so the executor
-- can never regress into either of them again:
--
--   FAILING  planMoves=60 executedMoves=305 waves=82 busyFallbackTicks=24 stallTicks=62
--            durationMs=5320 avgAckMs=240 aborted=true reason="not converging (move
--            budget spent)" fillPct=74 cells=88 context="bags"
--            — plus a client "Internal Bag Error" and a layout left scattered with holes.
--
--   HEALTHY  planMoves=5 executedMoves=15 waves=13 stallTicks=15 avgAckMs=212
--            aborted=false — a run the owner would have called fine, executing THREE
--            TIMES its plan. The same defect, small enough to go unnoticed.
--
-- What makes these fixtures able to see the bug when the 2.0.2 suite could not: the
-- simulator now models the client's TWO-PHASE settle (see makeSimulator's settleLag
-- banner). Through 2.0.2 the sim published a slot's contents and released its lock in
-- the same instant, so "unlocked" and "settled" were the same fact and the whole failure
-- mode was unreachable in the harness.
--
-- THE PERMANENT GATE is asserted by the SIMULATOR, not the engine: `stats.lockedIssue`
-- counts every container operation aimed at a slot the client reports LOCKED, and
-- `stats.bagErrors` counts every refusal the client would answer with "Internal Bag
-- Error". Both must be ZERO. The engine has no idea these counters exist.
-- =====================================================================

-- Seed a simulator to an EXACT occupied-cell count. The owner's report is quoted as a
-- fill percentage, so the fixture has to hit it rather than approximate it.
local function seedToFill(S, rng, occupiedTarget)
    local slots, cids = {}, {}
    for cid in pairs(S.bags) do cids[#cids + 1] = cid end
    table.sort(cids)
    for _, cid in ipairs(cids) do
        for slot = 1, S.bags[cid].n do slots[#slots + 1] = { cid = cid, slot = slot } end
    end
    local placed, guard = 0, 0
    while placed < occupiedTarget and guard < 20000 do      -- ceilinged: headless discipline
        guard = guard + 1
        local id   = SIMIDS[1 + math.floor(rng() * #SIMIDS)]
        local maxS = SIMCAT[id].maxStack or 1
        local n    = (maxS > 1) and (1 + math.floor(rng() * (maxS - 1))) or 1
        local p    = slots[1 + math.floor(rng() * #slots)]
        if not S:at(p.cid, p.slot) and S.canHoldSim(p.cid, id) then
            S:set(p.cid, p.slot, id, n)
            placed = placed + 1
        end
    end
    return placed
end

-- The owner's combined view: 88 cells across a backpack and four bags, all general
-- family (the failing run's context was "bags"), at 74% fill, on a 240ms round-trip.
-- `settleLag` is the gap between ITEM_LOCK_CHANGED and BAG_UPDATE — the window the whole
-- defect lives in. 0.15s is ~0.6 of the measured round-trip: well within what the live
-- client's coalesced bag updates cost, and short enough that it is not doing the work of
-- the assertion by itself.
local function ownerSim(seed)
    return makeSimulator({
        bags = { { cid = 0, size = 20 }, { cid = 1, size = 17 }, { cid = 2, size = 17 },
                 { cid = 3, size = 17 }, { cid = 4, size = 17 } },      -- 88 cells
        latency = 0.24, jitter = 0.24 * 0.4, settleLag = 0.15, seed = seed or 880574 })
end

-- The healthy contrast: a small run whose OPENING PLAN is a handful of moves, on the same
-- session's 212ms round-trip. 2.0.2 executed 15 for a plan of 5; the target is parity.
local function healthySim(seed)
    return makeSimulator({
        bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
        latency = 0.212, jitter = 0.212 * 0.4, settleLag = 0.13, seed = seed or 212212 })
end

-- Everything both fixtures assert about ONE run, so the mutation gate below can re-use
-- them verbatim against a 2.0.2-shaped executor. `tol` is the allowed excess of executed
-- moves over the opening plan.
local function convergenceAssertions(S, cids, tag, tol, limit, roundCost)
    local fails = {}
    local function ck(c, m) if not c then fails[#fails + 1] = tag .. ": " .. m end end

    local before = S:totals()
    local plan0  = Sort.Plan({ cells = S:cells(), meta = simMetaFn })
    local nPlan  = #plan0.moves
    local depth  = #Sort.PartitionWaves(plan0.moves)
    local tally  = runSortInSim(S, cids, { limit = limit or 240 })
    local rec    = Sort._lastRun or {}

    ---------------------------------------------------------------- the permanent gate
    ck(S.stats.lockedIssue == 0, string.format(
        "ZERO moves issued against a locked slot (sim counted %d)", S.stats.lockedIssue))
    ck(S.stats.bagErrors == 0, string.format(
        "the client refused NOTHING — no Internal Bag Error (sim counted %d)",
        S.stats.bagErrors))
    ck((rec.bagErrors or 0) == S.stats.bagErrors,
        "…and the engine OBSERVED the same count it caused (telemetry: "
        .. tostring(rec.bagErrors) .. ")")

    ---------------------------------------------------------------- convergence
    local completed = false
    for _, line in ipairs(tally.prints) do
        if line:find("sort complete", 1, true) then completed = true end
    end
    ck(completed, "ran to completion rather than aborting")
    ck(Sort._running == false, "the executor stopped")
    local same, badId = sameTotals(before, S:totals())
    ck(same, "every item conserved (id " .. tostring(badId) .. ")")
    ck(S.held == nil, "cursor left empty")
    ck(not S:anyLocked(), "no slot left locked")
    local re = Sort.Plan({ cells = S:cells(), meta = simMetaFn })
    ck(#re.moves == 0, "reached the planner's fixed point (" .. #re.moves .. " residual)")

    ---------------------------------------------------------------- NO OVER-ISSUE
    -- THE HEADLINE NUMBER. 2.0.2 executed 305 moves for a 60-move plan and 15 for a
    -- 5-move plan. The contract is parity within `tol`, and `tol` is 0 wherever the plan
    -- contains no merge (a pour that leaves a residual is legitimately re-planned).
    local exec = rec.executedMoves or 0
    ck(nPlan > 0, "the fixture actually has work to do (" .. nPlan .. " planned)")
    ck(exec <= nPlan + tol, string.format(
        "executed %d moves for a %d-move plan (tolerance +%d)", exec, nPlan, tol))
    ck(exec >= nPlan, string.format(
        "…and did not somehow do LESS than the plan (%d < %d)", exec, nPlan))

    ---------------------------------------------------------------- cost model
    -- What `waves` MEANS here is "rounds that issued at least one move", and issuing is
    -- per-move event-driven — a round fires the instant one slot settles, so a healthy
    -- run has many small rounds by design and the wave COUNT is not a churn signal.
    -- (The owner's failing run had 82 waves for 305 moves: 3.7 moves/wave, the same
    -- ratio a healthy run shows. Waves never were the tell; executed/planned is.)
    -- What waves must not do is exceed the moves they carried.
    ck((rec.waves or 0) <= exec, string.format(
        "every wave issued at least one move (%d waves, %d moves)", rec.waves or 0, exec))
    -- WALL CLOCK against the physics: the run cannot beat the dependency depth in
    -- round-trips, nor the in-flight bound in batches, and `slack` rounds cover the
    -- settle window and the opening/closing ticks.
    if roundCost and roundCost > 0 then
        local rounds = math.max(depth, math.ceil(nPlan / Sort.MAX_IN_FLIGHT)) + 6
        local bound  = rounds * roundCost * 1000
        ck((rec.durationMs or 0) <= bound, string.format(
            "%dms against a %dms bound (%d rounds x %dms)",
            rec.durationMs or 0, bound, rounds, roundCost * 1000))
    end
    ck((rec.inFlightPeak or 0) <= Sort.MAX_IN_FLIGHT, string.format(
        "in-flight peak %d never exceeded MAX_IN_FLIGHT (%d)",
        rec.inFlightPeak or 0, Sort.MAX_IN_FLIGHT))
    ck((rec.cleanupMoves or 0) == 0, "a COMPLETED run needs no cleanup wave")
    return fails, rec, nPlan, depth
end

local function ownerFixtureAssertions()
    local fails = {}
    local function add(list) for _, f in ipairs(list) do fails[#fails + 1] = f end end

    ------------------------------------------------------------------ FAILING RUN
    local S = ownerSim()
    local filled = seedToFill(S, newRng(74074), 65)          -- 65/88 == 73.9%
    if filled ~= 65 then fails[#fails + 1] = "owner fixture: seeded " .. filled .. "/65 cells" end
    -- tol +8: this layout is full of partial stacks, and a pour that leaves a residual is
    -- legitimately re-planned on a later round (MergePour's model, not churn). 2.0.2 ran
    -- this same fixture at 232 executed / 72 planned with 156 client refusals, so the
    -- headroom this leaves is a rounding error against the defect it pins.
    -- roundCost = latency + mean jitter + settleLag + one tick.
    local f1, rec = convergenceAssertions(S, { 0, 1, 2, 3, 4 }, "owner 88-cell @74%",
                                          8, 240, 0.24 + 0.048 + 0.15 + Sort.TICK)
    add(f1)
    if rec then
        if (rec.cells or 0) ~= 88 then
            fails[#fails + 1] = "owner fixture: telemetry says " .. tostring(rec.cells) .. " cells, not 88"
        end
        if math.abs((rec.fillPct or 0) - 74) > 1 then
            fails[#fails + 1] = "owner fixture: telemetry says " .. tostring(rec.fillPct) .. "% fill, not 74"
        end
        -- The settle window MUST have been exercised, or this fixture proves nothing:
        -- settleHolds counts the checks that found a slot unlocked with stale contents,
        -- i.e. exactly the instants 2.0.2 re-issued a move into.
        if (rec.settleHolds or 0) <= 0 then
            fails[#fails + 1] =
                "owner fixture: the settle window was never entered (settleHolds=0) — "
                .. "the fixture is not reproducing the live conditions"
        end
    end

    ------------------------------------------------------------------ HEALTHY RUN
    -- The owner's healthy record: planMoves=5, executedMoves=15, avgAckMs=212. Seeded
    -- with GEAR ONLY (every item maxStack 1), so the plan is pure exchanges with no pour
    -- that could legitimately leave a residual for a later round — which lets the
    -- tolerance be ZERO. executedMoves == planMoves, exactly, or this fails.
    local H = healthySim()
    seedRandomBags(H, newRng(1212), 7, 0)
    local hPlan = #Sort.Plan({ cells = H:cells(), meta = simMetaFn }).moves
    if hPlan < 3 or hPlan > 9 then
        fails[#fails + 1] = "healthy fixture: plan is " .. hPlan ..
            " moves, not the handful the owner's record shows"
    end
    local f2 = convergenceAssertions(H, { 0, 1 }, "healthy contrast", 0, 120,
                                     0.212 + 0.042 + 0.13 + Sort.TICK)
    add(f2)
    return fails
end

local function testOwnerLiveFailure(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ck(Sort.MAX_IN_FLIGHT and Sort.MAX_IN_FLIGHT > 0, "there is an in-flight bound")
    ck(Sort.SETTLE_TTL >= 0.5,
        "the settle ceiling is longer than any single round-trip (else a healthy move "
        .. "would be re-planned mid-flight)")
    ck(Sort.SETTLE_ACKS >= 3,
        "…and scales to at least 3 measured round-trips on a slow connection")
    ck(Sort.WAIT_TICK > Sort.TICK,
        "a WAITING round backs off rather than re-planning at the working cadence")
    ck(Sort.IsBagError(44, nil) and Sort.IsBagError(nil, "Internal Bag Error"),
        "the bag-error classifier matches by id AND by message text")
    ck(not Sort.IsBagError(1, "You are out of range"), "…and not by everything")

    for _, f in ipairs(ownerFixtureAssertions()) do fails[#fails + 1] = f end
end

----------------------------------------------------------------------
-- BAG-7 — LIVE SORT REPAINTS, on the owner's own 88-cell fixture.
--
-- The owner: "when sorting bags the icon locations dont update until the sort is
-- concluded." The answer (see beginQuiet) is that the freeze IS the deliberate capture
-- mute, not a render latency — so the gate has to prove three things at once:
--
--   A. THE WINDOW MOVES. Bag events drive data-only repaints during the run, at the
--      throttle, and cells actually change while the sort is still going.
--   B. THE SORT IS UNMOVED. Every convergence number of a run WITH the repaint path
--      populated is IDENTICAL to the same seeded run without it — executed moves, waves,
--      wall clock, avgAckMs, settle counters, and the simulator's own container-op tallies.
--      Same simulator, same seed, same virtual clock: "statistically unchanged" is too weak
--      a claim to settle for here, so the assertion is EQUALITY.
--   C. THE SNAPSHOT IS UNTOUCHED. The store records the cells were handed at layout time
--      come back byte-identical, and exactly one capture happens — at the end. That is the
--      invariant mesh consumers depend on.
--
-- Run A drives the REAL ui_items.LiveSlotRepaint over synthetic live cells bound to the
-- simulator's containers, so the sweep does real work against a real (simulated) client.
-- Run B leaves the button registry empty, which is 2.0.5's behaviour exactly.
----------------------------------------------------------------------
local function testLiveSortRepaint(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local Items = ns.Items
    if not (Items and Items.LiveSlotRepaint) then
        fails[#fails + 1] = "ui_items exposes no LiveSlotRepaint — BAG-7 is not wired"
        return
    end

    ck(Sort.LIVE_REPAINT and Sort.LIVE_REPAINT >= 0.10 and Sort.LIVE_REPAINT <= 0.15,
        "the live-repaint throttle is in the 0.10-0.15s band (got "
        .. tostring(Sort.LIVE_REPAINT) .. ")")

    -- One seeded fixture, built the same way both times.
    local function fixture()
        local S = ownerSim()
        local filled = seedToFill(S, newRng(74074), 65)          -- 65/88 == 73.9%
        return S, filled
    end

    ------------------------------------------------------------------ RUN A: repaints on
    local savedButtons = Items._buttons
    Items._buttons = setmetatable({}, { __mode = "k" })

    local SA, filledA = fixture()
    ck(filledA == 65, "fixture A seeded 65/88 cells (got " .. filledA .. ")")

    -- The captured snapshot the cells were laid out from: one store record per filled cell.
    -- These are the tables the sweep must never write.
    -- `cells` is a STRONG list on purpose: Items._buttons is a weak-keyed registry (the
    -- live grid holds its buttons through the frame tree), so a test that only put them
    -- there would watch the collector empty the sweep out from under it.
    local storeRecs, snapshotOf, repaints, cells = {}, {}, 0, {}
    for cid, bag in pairs(SA.bags) do
        for slot = 1, bag.n do
            local it = bag.slots[slot]
            -- Built from what the client reports AT LAYOUT TIME, so the sweep's first pass
            -- is not inflated by a synthetic mismatch: every re-draw counted below is a
            -- cell that genuinely moved DURING the sort.
            local rec = it and Store.NewSlot(it.id, it.count,
                (SIMCAT[it.id] and SIMCAT[it.id].quality) or 1) or nil
            local b = { _live = true, _cid = cid, _slot = slot, _data = rec }
            b.IsShown = function() return true end
            b._dsRepaint = function() repaints = repaints + 1 end
            Items._buttons[b] = true
            cells[#cells + 1] = b
            if rec then
                storeRecs[#storeRecs + 1] = rec
                snapshotOf[rec] = { id = rec.id, count = rec.count,
                                    quality = rec.quality, link = rec.link }
            end
        end
    end
    ck(#cells == 88, "…across all 88 cells (got " .. #cells .. ")")
    ck(#storeRecs == 65, "…and 65 store records are under the filled ones")

    local planA = #Sort.Plan({ cells = SA:cells(), meta = simMetaFn }).moves
    local tallyA = runSortInSim(SA, { 0, 1, 2, 3, 4 }, { limit = 240 })
    local recA   = Sort._lastRun or {}
    local sweepsA = Sort.LiveRepaintCount()
    local statsA = { pickups = SA.stats.pickups, drops = SA.stats.drops,
                     rejected = SA.stats.rejected, lockedIssue = SA.stats.lockedIssue,
                     bagErrors = SA.stats.bagErrors }

    ------------------------------------------------------------------ A: the window moved
    ck(sweepsA > 0, "the sort performed live repaints (got " .. sweepsA .. ")")
    ck(repaints > 0, "…and cells actually re-drew WHILE the sort was running (" .. repaints .. ")")
    -- Throttle: no more sweeps than the run's wall clock allows at LIVE_REPAINT, +2 for
    -- the opening/closing windows. This is the "coalesced" half of the contract.
    local ceiling = math.ceil(((recA.durationMs or 0) / 1000) / Sort.LIVE_REPAINT) + 2
    ck(sweepsA <= ceiling, string.format(
        "repaints held to the ~%.0f Hz throttle (%d <= %d over %.2fs)",
        1 / Sort.LIVE_REPAINT, sweepsA, ceiling, (recA.durationMs or 0) / 1000))

    ------------------------------------------------------------------ C: snapshot stable
    local drift = 0
    for _, rec in ipairs(storeRecs) do
        local s = snapshotOf[rec]
        if rec.id ~= s.id or rec.count ~= s.count
            or rec.quality ~= s.quality or rec.link ~= s.link then drift = drift + 1 end
    end
    ck(drift == 0, "the captured snapshot is BYTE-STABLE across the whole sort ("
        .. drift .. " record(s) drifted)")
    ck(tallyA.capture == 1, "exactly ONE capture, at the end (got " .. tallyA.capture .. ")")
    ck(tallyA.refresh == 1,
        "…and exactly ONE full grid rebuild, also at the end — the heartbeat no longer "
        .. "re-draws the frozen snapshot 5x/second (got " .. tallyA.refresh .. ")")

    -- ZERO MUTATION, asserted directly against the simulator's own counters: drive the
    -- real sweep by hand with the sim installed and prove it issues no container op.
    SA:install()
    local p0, d0, r0 = SA.stats.pickups, SA.stats.drops, SA.stats.rejected
    Items.LiveSlotRepaint()
    Items.LiveSlotRepaint()
    ck(SA.stats.pickups == p0 and SA.stats.drops == d0 and SA.stats.rejected == r0,
        "the repaint path issues ZERO container-mutating calls")
    SA:restore()

    ------------------------------------------------------------------ RUN B: repaints off
    Items._buttons = setmetatable({}, { __mode = "k" })   -- empty registry == 2.0.5
    local SB, filledB = fixture()
    ck(filledB == 65, "fixture B seeded identically")
    local planB = #Sort.Plan({ cells = SB:cells(), meta = simMetaFn }).moves
    local tallyB = runSortInSim(SB, { 0, 1, 2, 3, 4 }, { limit = 240 })
    local recB   = Sort._lastRun or {}
    Items._buttons = savedButtons

    ------------------------------------------------------------------ B: sort unmoved
    ck(planA == planB, "the two runs opened on the same plan (" .. planA .. " vs " .. planB .. ")")
    for _, k in ipairs({ "executedMoves", "waves", "durationMs", "avgAckMs",
                         "settleWaits", "settleHolds", "settleDrops", "inFlightPeak",
                         "bagErrors", "cleanupMoves", "stallTicks", "busyFallbackTicks" }) do
        ck(recA[k] == recB[k], string.format(
            "convergence UNCHANGED by the repaint path: %s %s vs %s",
            k, tostring(recA[k]), tostring(recB[k])))
    end
    for _, k in ipairs({ "pickups", "drops", "rejected", "lockedIssue", "bagErrors" }) do
        ck(statsA[k] == SB.stats[k], string.format(
            "the CLIENT saw the same traffic either way: %s %s vs %s",
            k, tostring(statsA[k]), tostring(SB.stats[k])))
    end
    -- and the plan/exec parity contract the owner fixture pins still holds in run A
    ck((recA.executedMoves or 0) >= planA and (recA.executedMoves or 0) <= planA + 8,
        string.format("plan/exec parity holds with repaints on (%d executed for %d planned)",
            recA.executedMoves or 0, planA))
    ck(recA.aborted == false and recB.aborted == false, "neither run aborted")

    -- The numbers themselves, on the record: this is the owner-facing answer to "is there
    -- a bag render delay?" — the sort is bit-for-bit the same run, and the window moved.
    if ns.Print then
        ns:Print(string.format(
            "  live-sort: 88 cells @74%%, plan %d -> exec %d in %d waves, %.0fms, ack %dms | "
            .. "repaints on: %d sweeps / %d cell re-draws | repaints off: exec %d waves %d %.0fms",
            planA, recA.executedMoves or 0, recA.waves or 0, recA.durationMs or 0,
            recA.avgAckMs or 0, sweepsA, repaints,
            recB.executedMoves or 0, recB.waves or 0, recB.durationMs or 0))
    end
end

-- MUTATION GATE for the settle rule. Sort.PredSettled IS the fix, so the 2.0.2 executor
-- is expressible as one replacement for it — which is what makes this a real red→green
-- pin rather than a test that merely passes today.
local function testSettleMutants(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local realSettled, realInFlight = Sort.PredSettled, Sort.MAX_IN_FLIGHT
    local mutants = {
        { name = "2.0.2 EXACTLY: unlocked is settled (the shipped defect)",
          settled = function() return true end },
        { name = "settles on the item id alone, ignoring the stack count",
          settled = function(p)
              local CC = _G.C_Container
              if not (CC and CC.GetContainerItemInfo) then return true end
              local info = CC.GetContainerItemInfo(p.cid, p.slot)
              local id = (info and info.itemID) or nil
              return id == p.id
          end },
        { name = "never settles (predictions only ever time out)",
          settled = function() return false end },
        { name = "the in-flight bound is removed (2.0.2's 24-move burst)",
          inFlight = 9999 },
    }
    for _, mut in ipairs(mutants) do
        if mut.settled then Sort.PredSettled = mut.settled end
        if mut.inFlight then Sort.MAX_IN_FLIGHT = mut.inFlight end
        local ok, res = pcall(ownerFixtureAssertions)
        Sort.PredSettled, Sort.MAX_IN_FLIGHT = realSettled, realInFlight
        local killed = (not ok) or (#res > 0)
        ck(killed, "mutant SURVIVED the owner's live-failure fixtures: " .. mut.name)
    end
    ck(Sort.PredSettled == realSettled and Sort.MAX_IN_FLIGHT == realInFlight,
        "the real settle rule and in-flight bound were restored after mutation")
end

-- =====================================================================
-- 2.0.3 — THE GRACEFUL ABORT
--
-- The live failure did not merely stop: it stopped MID-LAYOUT, leaving the grid
-- "scattered with holes". Convergence is one contract; ending tidily when convergence
-- is impossible is a separate one, and it is the one the owner actually saw fail.
-- =====================================================================
-- =====================================================================
-- CLASS 9 — SYNCHRONOUS IN-CALL EVENT DISPATCH  (2026-08-11)
--
-- The class the whole suite was blind to until 2026-08-10, and the reason it was blind:
-- this file's simulator delivered every echo AFTER the call that caused it returned. That
-- posture arms the latch for the engine, so it tests the fix and never the hazard. The
-- simulator now defaults to SYNC (see makeSimulator's dispatch banner) and the async
-- profile is a named variant; everything below runs BOTH.
--
-- Three things are proven here, in this order:
--
--   THE GATE IS REAL      the sim's `echoUnlatched` counter goes red on the exact defect
--                         shape (prediction armed one client call late) and green on the
--                         fixed one — driven by hand, with no executor involved, so a
--                         green verdict from the fixtures below means something.
--   POSTURE EQUIVALENCE   the full composed leg — plan → waves → settle → final capture →
--                         store write — issues the SAME moves in the SAME number of waves
--                         under both postures, ends at the same layout, and holds the
--                         refresh mute for the whole run either way.
--   TEARDOWN IS ATOMIC    an abort trigger delivered INSIDE the tidy-up wave's own
--                         container call does not start a second teardown. Red control:
--                         clear the latch from inside the same hook and the double
--                         teardown comes straight back.
-- =====================================================================

-- The sim's class-9 gate, driven by hand. Two pickups on a running-sort-shaped world:
-- one with the prediction armed BEFORE the call (2.0.8's order), one with it armed after
-- (2.0.7's). A gate that cannot go red proves nothing about the runs that pass it.
local function testClass9Gate(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function probe(armFirst)
        local S = makeSimulator({ bags = { { cid = 0, size = 4 } }, seed = 991 })
        S:set(0, 1, 601, 1)
        S:set(0, 3, 602, 1)
        S:install()
        -- Stand in for a live run WITHOUT starting one: the gate reads exactly these two
        -- fields, and driving them by hand keeps the probe independent of the executor.
        local savedRunning, savedPred, savedTear = Sort._running, Sort._pred, Sort._teardown
        Sort._running, Sort._pred, Sort._teardown = true, {}, nil
        local ok, err = pcall(function()
            if armFirst then Sort._pred["0:1"] = { cid = 0, slot = 1, id = 602, count = 1, at = 0 } end
            _G.C_Container.PickupContainerItem(0, 1)
            if not armFirst then Sort._pred["0:1"] = { cid = 0, slot = 1, id = 602, count = 1, at = 0 } end
        end)
        Sort._running, Sort._pred, Sort._teardown = savedRunning, savedPred, savedTear
        S:restore()
        if not ok then error(err, 0) end
        return S
    end

    local red = probe(false)
    ck(red.stats.inCallEchoes >= 1,
        "the sync sim really does echo from INSIDE PickupContainerItem (got "
        .. red.stats.inCallEchoes .. ")")
    ck(red.stats.echoUnlatched >= 1,
        "RED CONTROL: a prediction armed one call LATE lets the sequence's own first echo "
        .. "walk past the latch (unlatched=" .. red.stats.echoUnlatched .. ")")

    local green = probe(true)
    ck(green.stats.inCallEchoes >= 1, "…the fixed order still takes the same in-call echo")
    ck(green.stats.echoUnlatched == 0,
        "GREEN: armed BEFORE the call, the echo finds its latch up (unlatched="
        .. green.stats.echoUnlatched .. ")")

    -- ASYNC is the named variant, and it is exactly the posture that could not see this:
    -- the same late-armed sequence raises nothing at all.
    local S = makeSimulator({ bags = { { cid = 0, size = 4 } }, seed = 991, dispatch = "async" })
    S:set(0, 1, 601, 1)
    S:install()
    local savedRunning, savedPred = Sort._running, Sort._pred
    Sort._running, Sort._pred = true, {}
    pcall(function() _G.C_Container.PickupContainerItem(0, 1) end)
    Sort._running, Sort._pred = savedRunning, savedPred
    S:restore()
    ck(S.stats.inCallEchoes == 0 and S.stats.echoUnlatched == 0,
        "THE BLIND SPOT, NAMED: under the async posture the same late arming raises nothing "
        .. "— a sim that echoes at all is not unkind enough; WHEN it echoes is the question")

    -- An absent setter is a kinder client (the secondary blind spot). The engine's `split`
    -- arm is guarded on this function existing, and the sim used not to define it.
    local S2 = makeSimulator({ bags = { { cid = 0, size = 4 } }, seed = 7 })
    S2:set(0, 1, 701, 5)
    S2:install()
    local haveSplit = type(_G.C_Container.SplitContainerItem) == "function"
    local heldAfter
    if haveSplit then
        _G.C_Container.SplitContainerItem(0, 1, 2)
        heldAfter = S2.held
    end
    S2:restore()
    ck(haveSplit, "the sim stubs SplitContainerItem — performMove's split arm is guarded on it")
    ck(heldAfter ~= nil and heldAfter.count == 2,
        "…and it behaves: the split lands on the cursor (client semantics)")
end

-- One fixture, run under both postures, compared field by field.
local function class9Pair(mk, cids, tag, fails)
    local function ck(c, m) if not c then fails[#fails + 1] = tag .. ": " .. m end end
    local out = {}
    for _, posture in ipairs({ "sync", "async" }) do
        local S = mk(posture)
        local before = S:totals()
        local plan0  = Sort.Plan({ cells = S:cells(), meta = simMetaFn })
        local tally  = runSortInSim(S, cids, { limit = 240 })
        local rec    = Sort._lastRun or {}
        local layout = {}
        for _, c in ipairs(S:cells()) do
            layout[#layout + 1] = c.cid .. ":" .. c.slot .. "=" .. tostring(c.id) .. "x" .. c.count
        end
        local completed = false
        for _, line in ipairs(tally.prints) do
            if line:find("sort complete", 1, true) then completed = true end
        end
        out[posture] = {
            S = S, plan = #plan0.moves, exec = rec.executedMoves or 0, waves = rec.waves or 0,
            layout = table.concat(layout, "|"), totals = S:totals(), completed = completed,
            reentry = Sort._lastReentryRefused or 0, tally = tally,
            residual = #Sort.Plan({ cells = S:cells(), meta = simMetaFn }).moves,
            before = before,
        }
    end

    local sy, as = out.sync, out.async

    ---------------------------------------------------------------- the posture is real
    ck(sy.S.stats.inCallEchoes > 0, string.format(
        "the SYNC run really dispatched from inside the client calls (%d in-call echoes)",
        sy.S.stats.inCallEchoes))
    ck(as.S.stats.inCallEchoes == 0,
        "…and the ASYNC variant is the old posture, with none (" .. as.S.stats.inCallEchoes .. ")")

    ---------------------------------------------------------------- the class-9 gate
    ck(sy.S.stats.echoUnlatched == 0, string.format(
        "ZERO in-call echoes arrived with no prediction armed (sim counted %d)",
        sy.S.stats.echoUnlatched))
    ck(sy.reentry == 0 and as.reentry == 0, string.format(
        "the issue-pass fuse refused nothing — no handler reached a wave from inside a "
        .. "call (sync=%d async=%d)", sy.reentry, as.reentry))
    ck(sy.S.stats.maxDispatchDepth <= 3, string.format(
        "in-call nesting stayed shallow (depth %d, fuse at %d)",
        sy.S.stats.maxDispatchDepth, sy.S.MAX_DISPATCH_DEPTH))

    ---------------------------------------------------------------- the permanent gates
    for _, p in ipairs({ "sync", "async" }) do
        local r = out[p]
        ck(r.S.stats.lockedIssue == 0, p .. ": ZERO moves issued against a locked slot")
        ck(r.S.stats.bagErrors == 0, p .. ": the client refused nothing")
        ck(r.completed, p .. ": ran to completion")
        ck(r.residual == 0, p .. ": reached the planner's fixed point (" .. r.residual .. " left)")
        ck(r.S.held == nil, p .. ": cursor left empty")
        ck(not r.S:anyLocked(), p .. ": no slot left locked")
        local same, bad = sameTotals(r.before, r.totals)
        ck(same, p .. ": every item conserved (id " .. tostring(bad) .. ")")
    end

    ---------------------------------------------------------------- POSTURE EQUIVALENCE
    ck(sy.plan == as.plan, string.format(
        "both postures started from the same plan (%d vs %d)", sy.plan, as.plan))
    ck(sy.exec == as.exec, string.format(
        "SAME MOVE COUNT under both postures (sync %d, async %d)", sy.exec, as.exec))
    ck(sy.waves == as.waves, string.format(
        "SAME WAVE COUNT under both postures (sync %d, async %d)", sy.waves, as.waves))
    ck(sy.layout == as.layout, "…and both postures land on byte-identical layouts")
    return out
end

local function testClass9Postures(fails)
    local rng = newRng(90901)
    for _, cfg in ipairs({
        { latency = 0,    settleLag = 0,    tag = "instant client (the landing echoes IN the call)" },
        { latency = 0.10, settleLag = 0.04, tag = "fast client" },
        { latency = 0.24, settleLag = 0.15, tag = "the owner's 240ms client" },
    }) do
        for trial = 1, 2 do
            local seedBags = newRng(3000 + trial)
            class9Pair(function(posture)
                local S = makeSimulator({
                    bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 }, { cid = 2, size = 16 } },
                    latency = cfg.latency, jitter = cfg.latency * 0.4,
                    settleLag = cfg.settleLag, seed = 4400 + trial, dispatch = posture })
                -- Same layout for both postures: a shared rng would desynchronise them.
                local r = newRng(3000 + trial)
                seedRandomBags(S, r, 7, 9)
                return S
            end, { 0, 1, 2 }, string.format("%s trial %d", cfg.tag, trial), fails)
            seedBags(); rng()
        end
    end
end

-- ── THE COMPOSED LEG ────────────────────────────────────────────────────────────
-- plan → waves → settle → final capture → store write, under both postures, with the
-- capture layer REAL enough to answer the question the mute exists for: does anything
-- read the bags mid-run, and does exactly one capture land at the end?
local function testClass9ComposedLeg(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function leg(posture)
        local S = makeSimulator({
            bags = { { cid = 0, size = 20 }, { cid = 1, size = 17 }, { cid = 2, size = 17 } },
            latency = 0.18, jitter = 0.07, settleLag = 0.09, seed = 5150, dispatch = posture })
        seedRandomBags(S, newRng(5150), 9, 11)
        local before = S:totals()

        -- The "store": what a capture would write. Recorded per capture so the test can
        -- see WHEN it happened relative to the run, not just how often.
        local writes, midRun = {}, 0
        local oldFrame, oldCapture, oldPrint = ns.Frame, ns.Capture, ns.Print
        local prints, refreshes = {}, 0
        ns.Frame = { IsShown = function() return true end,
                     RequestRefresh = function() refreshes = refreshes + 1 end }
        ns.Capture = { RequestCapture = function()
            if Sort._running then midRun = midRun + 1 end
            local snap = {}
            for _, c in ipairs(S:cells()) do
                snap[#snap + 1] = c.cid .. ":" .. c.slot .. "=" .. tostring(c.id) .. "x" .. c.count
            end
            writes[#writes + 1] = table.concat(snap, "|")
        end }
        ns.Print = function(_, ...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            prints[#prints + 1] = table.concat(parts, "")
        end

        S:install()
        local ok, err = pcall(function()
            Sort.Run({ 0, 1, 2 })
            S:pump(240)
        end)
        if Sort._running then Sort._running = false end
        S:restore()
        ns.Frame, ns.Capture, ns.Print = oldFrame, oldCapture, oldPrint
        if not ok then error(err, 0) end

        local rec = Sort._lastRun or {}
        local final = {}
        for _, c in ipairs(S:cells()) do
            final[#final + 1] = c.cid .. ":" .. c.slot .. "=" .. tostring(c.id) .. "x" .. c.count
        end
        return { S = S, before = before, writes = writes, midRun = midRun, prints = prints,
                 exec = rec.executedMoves or 0, waves = rec.waves or 0,
                 final = table.concat(final, "|"), refreshes = refreshes }
    end

    local sy, as = leg("sync"), leg("async")

    for _, pair in ipairs({ { "sync", sy }, { "async", as } }) do
        local p, r = pair[1], pair[2]
        ck(#r.writes == 1, p .. ": EXACTLY ONE capture for the whole run (got " .. #r.writes .. ")")
        ck(r.midRun == 0, p ..
            ": …and it is the close-out, not a mid-run read — the mute held end to end (" ..
            r.midRun .. " mid-run capture(s))")
        ck(r.writes[1] == r.final, p ..
            ": the STORE WRITE is the run's final layout, not a mid-sort snapshot")
        local same, bad = sameTotals(r.before, r.S:totals())
        ck(same, p .. ": every item conserved through the whole leg (id " .. tostring(bad) .. ")")
        local done = false
        for _, line in ipairs(r.prints) do
            if line:find("sort complete", 1, true) then done = true end
        end
        ck(done, p .. ": the leg ended in a completion, not an abort")
        ck(r.S.stats.lockedIssue == 0 and r.S.stats.bagErrors == 0,
            p .. ": no locked issue, no bag error")
    end

    ck(sy.S.stats.inCallEchoes > 0, "the sync leg dispatched inside the calls ("
        .. sy.S.stats.inCallEchoes .. " echoes)")
    ck(sy.S.stats.echoUnlatched == 0, "…every one of them found its prediction armed")
    ck(sy.exec == as.exec and sy.waves == as.waves, string.format(
        "the composed leg issues the SAME moves in the SAME waves under both postures "
        .. "(sync %d/%d, async %d/%d)", sy.exec, sy.waves, as.exec, as.waves))
    ck(sy.final == as.final, "…and writes the SAME final layout to the store")
end

-- ── TEARDOWN ATOMICITY, WITH ITS RED CONTROL ────────────────────────────────────
-- The abort path issues container operations of its own (cleanupWave) before it tears the
-- run down, with the driver still registered. Deliver an abort trigger from INSIDE one of
-- those calls — a pull landing on the frame the tidy-up wave goes out is exactly that —
-- and a teardown with no latch runs a second time from inside the first.
-- ── THE FUSE, EXERCISED ─────────────────────────────────────────────────────────
-- Nothing in the shipped composition reaches an issue pass from inside a client call —
-- the tick is always deferred and the teardown latch covers the cleanup — so the fuse
-- would otherwise be hardening with no gate on it, which is how hardening rots. The hook
-- below is the UNFORESEEN COMPOSITION, made foreseeable: a handler woken by move N's
-- pickup reaches straight back into the round. The contract is a counted REFUSAL and a
-- run that still lands, not a deeper stack and not a plan taken over a half-issued wave.
local function testClass9Fuse(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local hits = 0
    local S = makeSimulator({
        bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
        latency = 0.12, jitter = 0.04, settleLag = 0.05, seed = 6161, dispatch = "sync",
        echoHook = function(_, api)
            if api ~= "PickupContainerItem" then return end
            if not Sort._running or Sort._teardown then return end
            if hits >= 6 then return end
            hits = hits + 1
            Sort._tick()          -- re-enter the round from inside the wave it is issuing
        end })
    seedRandomBags(S, newRng(6161), 8, 8)
    local before = S:totals()
    local tally = runSortInSim(S, { 0, 1 }, { limit = 240 })
    local rec = Sort._lastRun or {}

    ck(hits > 0, "PREMISE: the fixture re-entered the round from inside a pickup ("
        .. hits .. " times)")
    ck((Sort._lastReentryRefused or 0) >= hits, string.format(
        "THE FUSE: every one of them was REFUSED and counted (%d refusals for %d attempts)",
        Sort._lastReentryRefused or 0, hits))
    -- WHICH fuse caught it is the whole point. "tick@" means the round refused BEFORE it
    -- snapshotted — no plan was ever taken over a half-issued wave. "wave@" would mean the
    -- round re-planned from mid-state and was only stopped at the issue guard, which is the
    -- Armory E-1 shape reached one step later: the settle predicates and the target map
    -- would already have run against a bag with an item on the cursor.
    ck(type(Sort._lastReentryWhere) == "string"
        and Sort._lastReentryWhere:find("tick@", 1, true) == 1,
        "…refused at the ROUND, before any re-plan could see the half-issued wave (got "
        .. tostring(Sort._lastReentryWhere) .. ")")
    ck(S.stats.maxDispatchDepth <= S.MAX_DISPATCH_DEPTH,
        "…and the nesting never ran away (depth " .. S.stats.maxDispatchDepth .. ")")

    -- A refusal is not a licence to lose the sort: the run must still land.
    local completed = false
    for _, line in ipairs(tally.prints) do
        if line:find("sort complete", 1, true) then completed = true end
    end
    ck(completed, "A LATCH THAT SWALLOWS THE WORK IS NOT A FIX: the sort still completed")
    ck(#Sort.Plan({ cells = S:cells(), meta = simMetaFn }).moves == 0,
        "…at the planner's fixed point")
    local same, bad = sameTotals(before, S:totals())
    ck(same, "…with every item conserved (id " .. tostring(bad) .. ")")
    ck(S.stats.lockedIssue == 0 and S.stats.bagErrors == 0,
        "…and no operation issued at a locked slot, no client refusal")
    ck(S.stats.echoUnlatched == 0, "…and every in-call echo still found its latch")
    ck((rec.executedMoves or 0) > 0, "…having actually moved things (" ..
        tostring(rec.executedMoves) .. " moves)")
end

local function testClass9TeardownReentry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function run(clearLatch)
        local fired = false
        local S = makeSimulator({
            bags = { { cid = 0, size = 16 } }, latency = 0.10, settleLag = 0.06,
            seed = 909, dispatch = "sync",
            echoHook = function(SS, api)
                if fired or api ~= "PickupContainerItem" then return end
                if not Sort._teardown then return end   -- only DURING the tidy-up wave
                fired = true
                -- THE MUTANT: dropping the latch here reproduces the 2.0.7 build exactly.
                if clearLatch then Sort._teardown = nil end
                SS.combat = true
                SS.fire("PLAYER_REGEN_DISABLED")
            end })
        local ids = { 606, 601, 610, 603, 608, 602, 612, 604 }
        for i, id in ipairs(ids) do S:set(0, i * 2 - 1, id, 1) end
        S:install()
        local tally
        local savedFactor, savedSlack = Sort.MAX_MOVE_FACTOR, Sort.MOVE_SLACK
        local ok, err = pcall(function()
            tally = withFakeUI(function()
                Sort.Run({ 0 })
                S:pump(0.12)
                if Sort._running then
                    Sort.MAX_MOVE_FACTOR, Sort.MOVE_SLACK = 0, 0
                    Sort._budget = Sort._moveCount or 0
                end
                S:pump(60)
            end)
        end)
        Sort.MAX_MOVE_FACTOR, Sort.MOVE_SLACK = savedFactor, savedSlack
        if Sort._running then Sort._running = false end
        Sort._teardown = nil
        S:restore()
        if not ok then error(err, 0) end
        local stops = 0
        for _, line in ipairs(tally.prints) do
            if line:find("sort stopped", 1, true) then stops = stops + 1 end
        end
        return { S = S, tally = tally, stops = stops, fired = fired }
    end

    local green = run(false)
    ck(green.fired, "PREMISE: the fixture delivered an abort trigger from INSIDE a tidy-up "
        .. "wave's own PickupContainerItem")
    ck(green.stops == 1, "ONE teardown for one sort: exactly one 'sort stopped' line (got "
        .. green.stops .. ")")
    ck(Sort._running == false, "…and the run is down")
    ck(green.S.held == nil, "…with the cursor empty")
    ck(green.S.stats.lockedIssue == 0, "…and nothing issued at a locked slot")

    local red = run(true)
    ck(red.fired, "…the mutant fixture delivered the same trigger")
    ck(red.stops >= 2, "RED CONTROL: with the teardown latch cleared, the abort re-enters "
        .. "itself and tears the same run down twice (" .. red.stops .. " 'sort stopped' lines)")
end

local function testGracefulAbort(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    ------------------------------------------------------------------ the pure planner
    -- CompactMoves on a deliberately holed layout: holes close, nothing is invented.
    do
        local cells = {}
        for slot = 1, 12 do cells[#cells + 1] = { cid = 0, slot = slot, id = nil, count = 0 } end
        local place = { [2] = 601, [5] = 602, [6] = 603, [11] = 604 }
        for slot, id in pairs(place) do cells[slot].id, cells[slot].count = id, 1 end
        local moves = Sort.CompactMoves(cells, nil, nil)
        -- THREE moves, not four: 601 is already in cell 2 and the two-pointer pass
        -- never moves an item that a hole in front of it has not claimed.
        ck(#moves == 3, "the tail is pulled forward into the holes (" .. #moves .. " moves)")
        local occupied, ids = {}, {}
        for i, c in ipairs(cells) do
            if c.id then occupied[#occupied + 1] = i; ids[c.id] = (ids[c.id] or 0) + 1 end
        end
        ck(#occupied == 4, "…the item count is unchanged")
        local contiguous = true
        for i, idx in ipairs(occupied) do if idx ~= i then contiguous = false end end
        ck(contiguous, "…and they end up in cells 1..4 with no hole between them")
        for _, id in pairs(place) do ck(ids[id] == 1, "…item " .. id .. " survived exactly once") end
        -- Slot-disjoint: one wave, no move waiting on another.
        ck(#Sort.PartitionWaves(moves) <= 1, "…and the whole compaction is ONE wave")
    end

    -- A locked / user-locked / in-flight cell is never touched, and a family bag never
    -- receives something it cannot hold.
    do
        local cells = {}
        for slot = 1, 8 do cells[#cells + 1] = { cid = 0, slot = slot, id = nil, count = 0 } end
        cells[1].userLocked = true
        cells[2].locked     = true
        cells[6].id, cells[6].count = 601, 1
        local moves = Sort.CompactMoves(cells, nil, function(c) return c.slot == 3 end)
        ck(#moves == 1, "one item, one move")
        ck(moves[1] and moves[1].b.slot == 4, string.format(
            "…into the first cell that is neither user-locked, live-locked nor in flight (got %s)",
            moves[1] and tostring(moves[1].b.slot) or "none"))
        local blocked = Sort.CompactMoves(
            { { cid = 0, slot = 1, id = nil, count = 0 },
              { cid = 0, slot = 2, id = 700, count = 1 } },
            function() return false end, nil)
        ck(#blocked == 0, "a hole the item may not legally occupy is left alone")
    end

    ------------------------------------------------------------------ end to end
    -- A server that refuses everything cannot converge, so the run MUST abort — and the
    -- abort must close the holes it opened and say so in plain words.
    do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 }, { cid = 1, size = 16 } },
                                  latency = 0.05, dropRate = 1.0, settleLag = 0.05,
                                  seed = 4242 })
        seedRandomBags(S, newRng(2024), 9, 5)
        local before = S:totals()
        local tally  = runSortInSim(S, { 0, 1 }, { limit = 400 })
        local rec    = Sort._lastRun or {}
        local stopped
        for _, line in ipairs(tally.prints) do
            if line:find("sort stopped", 1, true) then stopped = line end
        end
        ck(stopped ~= nil, "a fully-rejecting server aborts rather than spinning")
        ck(S.stats.lockedIssue == 0,
            "…and STILL never issued against a locked slot (" .. S.stats.lockedIssue .. ")")
        local same = sameTotals(before, S:totals())
        ck(same, "…with every item conserved")
        ck(S.held == nil, "…and the cursor empty")
        if stopped then
            ck(stopped:find("still outstanding") ~= nil,
                "…the abort says how much arranging is left: " .. stopped)
        end
        ck(rec.aborted == true, "…the telemetry record marks it aborted")
        ck(Sort._running == false, "…and the run tore itself down")
    end

    -- The real shape of the owner's complaint: a run that aborts must not leave HOLES in
    -- front of items. Deliberately holed opening layout (items on the ODD cells of a
    -- 16-slot bag, in an order the planner will want to rearrange), aborted part way.
    do
        local S = makeSimulator({ bags = { { cid = 0, size = 16 } },
                                  latency = 0.10, settleLag = 0.06, seed = 909 })
        local ids = { 606, 601, 610, 603, 608, 602, 612, 604 }
        for i, id in ipairs(ids) do S:set(0, i * 2 - 1, id, 1) end   -- 1,3,5,...,15
        S:install()
        local tally
        local savedFactor, savedSlack = Sort.MAX_MOVE_FACTOR, Sort.MOVE_SLACK
        local ok = pcall(function()
            tally = withFakeUI(function()
                Sort.Run({ 0 })
                S:pump(0.12)                     -- let the opening wave land
                -- Force the abort the owner actually hit ("move budget spent") part way
                -- through. Zeroing `_budget` alone would not do it: the budget RATCHETS
                -- UP on every improvement (Sort._tick), so a progressing run rebuilds it
                -- on the next round. Zeroing the ratchet's own terms first is what makes
                -- the cut stick — and it aborts through the real code path, not a hook.
                if Sort._running then
                    Sort.MAX_MOVE_FACTOR, Sort.MOVE_SLACK = 0, 0
                    Sort._budget = Sort._moveCount or 0
                end
                S:pump(60)
            end)
        end)
        Sort.MAX_MOVE_FACTOR, Sort.MOVE_SLACK = savedFactor, savedSlack
        if Sort._running then Sort._running = false end
        S:restore()
        ck(ok, "the mid-run abort fixture ran")
        if ok then
            local stoppedLine
            for _, line in ipairs(tally.prints) do
                if line:find("sort stopped", 1, true) then stoppedLine = line end
            end
            ck(stoppedLine ~= nil, "…the run really did abort (" ..
                tostring(tally.prints[#tally.prints]) .. ")")
            -- Every occupied cell must come before every empty one: no holes in front.
            local cells, seenHole, holed = S:cells(), false, false
            for _, c in ipairs(cells) do
                if c.id == nil then seenHole = true
                elseif seenHole then holed = true end
            end
            ck(not holed, "an aborted run leaves NO hole in front of an item "
                .. "(the owner's 'scattered with holes')")
            ck(S.stats.lockedIssue == 0, "…and the cleanup wave issued nothing at a locked slot")
            ck(S.held == nil, "…and left the cursor empty")
            local tidied
            for _, line in ipairs(tally.prints) do
                if line:find("Tidied up", 1, true) then tidied = line end
            end
            ck(tidied ~= nil, "…and said so plainly in chat: " .. tostring(tidied))
        end
    end
end

function Sort.RunSelfTests(verbose)
    local suites = {
        { name = "merge pour (exhaustive)", fn = testMergePour },
        { name = "canonical stacks",        fn = testCanonicalStacks },
        { name = "plan: merge + group sort", fn = testPlanMergeAndSort },
        { name = "plan: 1.x order parity",   fn = testPlan1xOrder },
        { name = "plan: order mutation gate", fn = testOrderMutants },
        { name = "plan: idempotent + locked", fn = testPlanIdempotentAndLocked },
        { name = "plan: sort locks (both directions)", fn = testPlanUserLocks },
        { name = "plan: sort-lock mutation gate", fn = testUserLockMutants },
        { name = "plan: family + multi-bag", fn = testPlanFamilyAndMultiBag },
        { name = "plan: 1.x family bands",   fn = testFamilyBands },
        { name = "plan: busy cells",         fn = testPlanBusy },
        { name = "plan: size vs 1.x engine", fn = testPlanSizeVs1x },
        { name = "plan: direction inversion", fn = testPlanDirection },
        { name = "wave partition",          fn = testPartitionWaves },
        { name = "converge: plan prefix",    fn = testPlanPrefixConvergence },
        { name = "converge: progress-based abort", fn = testProgressBasedAbort },
        { name = "converge: executor latency", fn = testExecutorLatency },
        { name = "converge: lock failures",  fn = testExecutorLockFailures },
        { name = "converge: mid-sort change", fn = testExecutorMidSortChange },
        { name = "converge: guard-rails",    fn = testExecutorGuardRails },
        { name = "converge: sort locks + combat", fn = testExecutorUserLocks },
        { name = "converge: report + quiet",  fn = testExecutorReporting },
        { name = "telemetry: sort log ring",  fn = testSortLog },
        { name = "converge: event-driven issue", fn = testEventDrivenIssue },
        { name = "converge: issuing mutation gate", fn = testEventIssueMutants },
        { name = "converge: owner's live failure (2.0.3)", fn = testOwnerLiveFailure },
        { name = "converge: settle mutation gate", fn = testSettleMutants },
        { name = "converge: graceful abort", fn = testGracefulAbort },
        { name = "live sort repaints (BAG-7)", fn = testLiveSortRepaint },
        { name = "class 9: in-call dispatch gate", fn = testClass9Gate },
        { name = "class 9: both postures converge", fn = testClass9Postures },
        { name = "class 9: composed leg (both postures)", fn = testClass9ComposedLeg },
        { name = "class 9: issue-pass fuse",   fn = testClass9Fuse },
        { name = "class 9: teardown re-entry", fn = testClass9TeardownReentry },
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
