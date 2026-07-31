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
                -- open = cells still holding a PARTIAL stack of this id, in free order
                local open = {}
                for _, i in ipairs(free) do
                    local s = sim[i]
                    if s.id == id and s.count > 0 and s.count < max then open[#open + 1] = i end
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
--      Predictions are dropped the moment reality can be observed (slot seen unlocked, or
--      ITEM_LOCK_CHANGED reports it clear), and expire on `Sort.LOCK_TTL` regardless — so
--      a FAILED or dropped move self-corrects on the very next tick.
--   3. Re-PLAN from scratch (the planner is a documented fixed point, so this converges).
--   4. Issue WAVE 1 ONLY of the dependency partition. Wave-1 moves depend on no earlier
--      move, so each is valid against the state we just observed — never against a
--      hypothetical post-plan state. Later waves are simply left for a later tick, by
--      which time their dependencies have settled and they have become wave 1.
--   5. Return immediately. NEVER wait for the server.
-- Termination: converged when a plan with NO outstanding predictions yields zero moves.
-- Bounded by a move budget (`MAX_MOVE_FACTOR`), an idle-tick cap and a hard tick cap;
-- every one of those aborts cleanly through the same path as combat / bank / window.
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

Sort.TICK               = 0.05   -- flat cadence; never waits on a server round-trip
Sort.MAX_MOVES_PER_TICK = 24     -- cap the burst so the client never drops requests
Sort.MAX_TICKS          = 200    -- hard wall (~10s) — safety valve, never hit normally
Sort.MAX_IDLE_TICKS     = 40     -- ~2s with nothing issuable (slots stuck locked) => abort
Sort.MAX_MOVE_FACTOR    = 4      -- issued-move budget = factor × initial plan + MOVE_SLACK
Sort.MOVE_SLACK         = 32
Sort.LOCK_TTL           = 3.00   -- backstop only: a slot locked THIS long is pathological
Sort.QUIET_REFRESH      = 0.20   -- 5 Hz grid heartbeat while the refresh storm is muted

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
-- clobbered. A `Sort.QUIET_REFRESH` heartbeat still repaints the grid at ~5 Hz so the
-- sort stays visible, and the restore does one full capture + rebuild unconditionally.
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

-- ~5 Hz repaint through the ORIGINAL refresh fn so the user watches the sort happen.
local function quietHeartbeat(now)
    local q = Sort._quiet
    if not (q and q.frameFn) then return end
    if now - (Sort._lastRefresh or 0) < Sort.QUIET_REFRESH then return end
    Sort._lastRefresh = now
    q.refreshes = q.refreshes + 1
    if ns.SafeCall then ns:SafeCall(q.frameFn) else q.frameFn() end
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

local function stopDriver()
    Sort._running = false
    Sort._cids, Sort._pred, Sort._meta, Sort._canHold, Sort._cache = nil, nil, nil, nil, nil
    Sort._ticks, Sort._idle, Sort._budget, Sort._lastIssued = nil, nil, nil, nil
    Sort._tickGen = (Sort._tickGen or 0) + 1   -- invalidate any queued tick
    if Sort._driver then Sort._driver:UnregisterAllEvents() end
    if _G.ClearCursor then _G.ClearCursor() end
    endQuiet()
end

-- Human-readable tail shared by the completion and abort prints. `_rounds` counts the
-- ticks that actually issued moves — the direct analogue of the old wave counter, and
-- the number the defect analysis asks the owner to read off a live sort.
local function runStats()
    local elapsed = nowSeconds() - (Sort._start or nowSeconds())
    return string.format("%d moves in %d waves, %.2fs",
        Sort._moveCount or 0, Sort._rounds or 0, elapsed)
end

local function abort(reason)
    if not Sort._running then return end
    local stats = runStats()
    stopDriver()
    if ns.Print then ns:Print("sort stopped: " .. tostring(reason) .. " (" .. stats .. ").") end
end

local function finish()
    if not Sort._running then return end
    local stats = runStats()
    stopDriver()
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

-- Drop a prediction once reality is observable for that slot. Called from the tick's
-- overlay and (same-frame fast path) from ITEM_LOCK_CHANGED.
--
-- The lock state is the authority, NOT the clock: as long as the client still reports the
-- slot locked the move is genuinely in flight, however slow the server is, and the
-- prediction must stand — expiring it on a timer would hand the planner the stale
-- pre-move contents and restart the churn the overlay exists to prevent. The TTL is only
-- a backstop for a slot that stays locked pathologically long; a slot that is NOT locked
-- is settled (or the move never happened), and reality wins immediately either way —
-- which is exactly how a rejected or dropped move self-corrects.
local function releasePred(key, now)
    local p = Sort._pred[key]
    if not p then return end
    if not slotLocked(p.cid, p.slot) then
        Sort._pred[key] = nil
    elseif now - p.at >= Sort.LOCK_TTL then
        Sort._pred[key] = nil
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
local function issueWave1(plan, cells, now)
    local wave = Sort.PartitionWaves(plan.moves)[1]
    if not wave then return 0 end
    local byKey = {}
    for _, c in ipairs(cells) do byKey[slotKey(c.cid, c.slot)] = c end
    local maxStackOf = function(id)
        local m = id and Sort._meta(id)
        return (m and m.maxStack) or 1
    end
    local issued = 0
    for _, m in ipairs(wave.moves) do
        if issued >= Sort.MAX_MOVES_PER_TICK then break end
        if (Sort._moveCount or 0) >= (Sort._budget or 0) then break end
        local slots = Sort.MoveSlots(m)
        -- Defensive re-check against LIVE locks: the planner already excludes locked
        -- cells, this only catches a lock that appeared between snapshot and issue.
        local blocked = false
        for _, r in ipairs(slots) do
            if Sort._pred[refKey(r)] or slotLocked(r.cid, r.slot) then blocked = true; break end
        end
        if not blocked then
            if ns.SafeCall then ns:SafeCall(performMove, m) else performMove(m) end
            predictMove(m, byKey, maxStackOf, now)
            issued = issued + 1
            Sort._moveCount = (Sort._moveCount or 0) + 1
        end
        -- A blocked wave-1 move is simply deferred; every other move in wave 1 is
        -- slot-disjoint from it, so skipping it cannot invalidate any of them.
    end
    return issued
end

-- Schedule the next round. Generation-guarded so an ITEM_LOCK_CHANGED "kick" can pull the
-- next round forward without ever running two rounds for one slot: bumping _tickGen
-- makes every already-queued callback a no-op.
local function scheduleTick(delay)
    Sort._tickGen = (Sort._tickGen or 0) + 1
    local gen = Sort._tickGen
    local fn = function()
        if Sort._running and gen == Sort._tickGen then Sort._tick() end
    end
    local after = _G.C_Timer and _G.C_Timer.After
    if after then after(delay or Sort.TICK, fn) else fn() end
end

-- One optimistic round: snapshot -> overlay predictions -> re-plan -> issue wave 1.
function Sort._tick()
    if not Sort._running then return end

    -- Abort guards first, exactly as before (polled AND event-driven).
    if inCombat() then return abort("entered combat") end
    if Sort._needsBank and not bankIsOpen() then return abort("bank closed") end
    if ns.Frame and ns.Frame.IsShown and not ns.Frame.IsShown() and not Sort._needsBank then
        return abort("window closed")
    end

    Sort._ticks = (Sort._ticks or 0) + 1
    if Sort._ticks > Sort.MAX_TICKS then return abort("time budget exceeded") end

    local now = nowSeconds()
    local cells = snapshot(Sort._cids)
    if not cells then return abort("containers unavailable") end
    overlayPredictions(cells, now)

    local plan = Sort.Plan({
        cells = cells, meta = Sort._meta, canHold = Sort._canHold, descending = Sort._desc,
    })

    local issued = 0
    if #plan.moves == 0 then
        -- Converged only when the plan is clean AND nothing of ours is still in flight,
        -- i.e. the zero-move verdict was reached on fully OBSERVED state.
        if not predOutstanding() then return finish() end
    else
        if (Sort._moveCount or 0) >= (Sort._budget or 0) then
            return abort("not converging (move budget spent)")
        end
        issued = issueWave1(plan, cells, now)
        if issued > 0 then Sort._rounds = (Sort._rounds or 0) + 1 end
    end

    Sort._lastIssued = issued
    if issued > 0 then
        Sort._idle = 0
    else
        Sort._idle = (Sort._idle or 0) + 1
        if Sort._idle > Sort.MAX_IDLE_TICKS then
            return abort("stalled (slots stayed locked)")
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
        if event == "ITEM_LOCK_CHANGED" then
            -- Use the (bag, slot) payload the event already carries to release exactly
            -- that prediction the moment the server confirms — no full re-scan, and the
            -- dependent moves become issuable on the very next tick.
            if not (Sort._running and Sort._pred) then return end
            if a == nil or b == nil then return end
            local k = slotKey(a, b)
            if not Sort._pred[k] then return end
            releasePred(k, nowSeconds())
            -- If the last round had nothing issuable, this confirmation may have just
            -- unblocked something — pull the next round forward instead of burning the
            -- remainder of the 0.05s tick. This is what keeps the total at the raw
            -- dependency-depth x round-trip floor with no tick quantization on top.
            if Sort._pred[k] == nil and (Sort._lastIssued or 0) == 0 then
                scheduleTick(0)
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
    local plan = Sort.Plan({ cells = cells, meta = meta, canHold = canHold, descending = descending })
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
    Sort._desc      = descending
    Sort._pred      = {}
    Sort._needsBank = needsBank
    Sort._ticks     = 0
    Sort._rounds    = 0
    Sort._idle      = 0
    Sort._moveCount = 0
    -- Convergence budget: a healthy run issues ~#plan.moves; anything wildly past that
    -- means we are thrashing, so abort rather than churn the owner's bags.
    Sort._budget    = #plan.moves * Sort.MAX_MOVE_FACTOR + Sort.MOVE_SLACK
    Sort._start     = nowSeconds()
    Sort._lastRefresh = Sort._start

    Sort._driver:RegisterEvent("ITEM_LOCK_CHANGED")
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
--                        dropRate, seed }
local function makeSimulator(opts)
    opts = opts or {}
    local S = {
        clock    = 0,
        latency  = opts.latency or 0,
        jitter   = opts.jitter or 0,
        dropRate = opts.dropRate or 0,
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
        stats    = { pickups = 0, drops = 0, rejected = 0, applied = 0 },
        saved    = {},
    }
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
    -- server-side application of a queued mutation
    ------------------------------------------------------------------
    local function settleDelay()
        local j = (S.jitter > 0) and (S.rng() * S.jitter) or 0
        return S.latency + j
    end

    -- The round-trip landing: publish server truth into the visible view for the slots
    -- this move touched, unlock them, and fire ITEM_LOCK_CHANGED with its (bag, slot).
    local function commit(touched)
        S.after(settleDelay(), function()
            for _, k in ipairs(touched) do
                local cid, slot = unkey(k)
                local bag = S.bags[cid]
                if bag then
                    local t = bag.truth[slot]
                    bag.slots[slot] = t and { id = t.id, count = t.count } or nil
                end
            end
            S.stats.applied = S.stats.applied + 1
            for _, k in ipairs(touched) do S.locked[k] = nil end
            for _, k in ipairs(touched) do
                local cid, slot = unkey(k)
                S.fire("ITEM_LOCK_CHANGED", cid, slot)
            end
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

    function C_Container.PickupContainerItem(cid, slot)
        local bag = S.bags[cid]
        if not bag or slot < 1 or slot > bag.n then return end
        local k = key(cid, slot)
        if S.held == nil then
            ----------------------------------------------------- pick up
            -- Client-side only: no server state changes until the DROP.
            if S.locked[k] then S.stats.rejected = S.stats.rejected + 1; return end
            local it = bag.truth[slot]
            if not it then return end
            S.held, S.holdKey = { id = it.id, count = it.count }, k
            -- Nothing has left the slot yet: server truth still holds this item, so a
            -- ClearCursor from here is a pure no-op.
            S.heldDetached = false
            S.stats.pickups = S.stats.pickups + 1
            return
        end
        ----------------------------------------------------------- drop
        S.stats.drops = S.stats.drops + 1
        -- A locked destination is refused by the client (unless it is where the held
        -- item came from — that is the "put the merge residual back" case).
        if S.locked[k] and k ~= S.holdKey then S.stats.rejected = S.stats.rejected + 1; return end
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

    ------------------------------------------------------------------
    -- install / restore the global surface
    ------------------------------------------------------------------
    local GLOBALS = { "C_Container", "C_Timer", "C_Item", "bit", "ClearCursor",
                      "CursorHasItem", "InCombatLockdown", "GetTime", "CreateFrame",
                      "BankFrame", "Enum" }

    function S:install()
        for _, g in ipairs(GLOBALS) do S.saved[g] = _G[g] end
        _G.C_Container = C_Container
        _G.C_Timer = { After = function(d, fn) S.after(d, fn) end }
        _G.GetTime = function() return S.clock end
        _G.InCombatLockdown = function() return S.combat end
        _G.CursorHasItem = function() return S.held ~= nil end
        -- Dropping the cursor returns the held item to the slot it came from (the live
        -- client's behaviour for a container item), so nothing can ever be destroyed by
        -- the executor's belt-and-suspenders ClearCursor().
        _G.ClearCursor = function()
            if not S.held then S.holdKey = nil; return end
            local k, held, detached = S.holdKey, S.held, S.heldDetached
            S.held, S.holdKey, S.heldDetached = nil, nil, false
            -- Picked up but never dropped (or the drop was refused): server truth never
            -- lost the item, so putting the cursor down changes nothing.
            if not detached then return end
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
                            commit({ key(c2, s2) })
                            return
                        end
                    end
                end
            end
            S.locked[k] = true
            commit({ k })
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
            -- target keeps it within a few percent (merges can re-split across rounds).
            ck(issued <= #plan0.moves * 1.3 + 4, tag .. string.format(
                ": issued %d moves for a %d-move plan (no churn)", issued, #plan0.moves))

            -- The cost model: one server round-trip per DEPENDENCY ROUND, with no
            -- settle-poll and no throttle stacked on top. The old executor paid
            -- waves x (latency + 0.05 + quantization) with waves ~2.5-3.5x this depth.
            local bound = (depth + 5) * (latency + latency * 0.4 + Sort.TICK)
            ck(S.clock <= bound, tag .. string.format(
                ": %.2fs simulated vs %.2fs bound (%d dependency rounds)", S.clock, bound, depth))
            if latency <= 0.10 then
                ck(S.clock < 1.5, tag .. string.format(
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
        { name = "converge: plan prefix",    fn = testPlanPrefixConvergence },
        { name = "converge: executor latency", fn = testExecutorLatency },
        { name = "converge: lock failures",  fn = testExecutorLockFailures },
        { name = "converge: mid-sort change", fn = testExecutorMidSortChange },
        { name = "converge: guard-rails",    fn = testExecutorGuardRails },
        { name = "converge: report + quiet",  fn = testExecutorReporting },
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
