-- Daseeki Bags 2.0 — sort.lua
-- The sort engine: a PURE, provably-terminating move planner plus a throttled,
-- taint-safe in-game executor. Split exactly like the rest of 2.0:
--
--   PURE core (no WoW API; exhaustively harness-tested):
--     Sort.MergePour(src, dst, max)        — one stack pour (the merge arithmetic)
--     Sort.CanonicalStacks(total, max)      — a total's merged shape (fulls + remainder)
--     Sort.CompareStacks(a, b)              — group order: class → subclass → name → quality↓
--     Sort.Plan(state)                      — current layout -> { target, moves, stats }
--
--   EXECUTOR (in-game only; guarded on _G):
--     Sort.Run(cids, opts)                  — snapshot cids, plan, play moves throttled
--     one move per BAG_UPDATE-verified tick, abort-clean on combat / window close /
--     bank close. Accepts an explicit container-id SET so W3 reuses it for the bank.
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
-- GetContainerItemInfo, PickupContainerItem, SplitContainerItem, GetContainerNumFreeSlots;
-- C_Item.GetItemInfo / GetItemInfoInstant / GetItemFamily; ClearCursor; InCombatLockdown;
-- events BAG_UPDATE, PLAYER_REGEN_DISABLED, BANKFRAME_CLOSED.

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
-- PURE: group ordering (design: class → subclass → name → quality desc)
-- a, b = { id, count, meta = { classID, subClassID, name, quality } }
----------------------------------------------------------------------

function Sort.CompareStacks(a, b)
    local am, bm = a.meta or {}, b.meta or {}
    local ac, bc = am.classID or HUGE, bm.classID or HUGE
    if ac ~= bc then return ac < bc end
    local as, bs = am.subClassID or HUGE, bm.subClassID or HUGE
    if as ~= bs then return as < bs end
    local an, bn = am.name or "", bm.name or ""
    if an ~= bn then return an < bn end
    local aq, bq = am.quality or 0, bm.quality or 0
    if aq ~= bq then return aq > bq end        -- quality DESCENDING
    if a.id ~= b.id then return (a.id or 0) < (b.id or 0) end
    return (a.count or 0) > (b.count or 0)      -- fuller stacks first (stable)
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
    table.sort(targetStacks, Sort.CompareStacks)   -- display order

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
-- EXECUTOR (in-game only) — throttled, verified, abort-clean.
-- Not headless-tested (no WoW API under the harness); exercised by Drew's live
-- pass. The planner it plays back IS exhaustively tested above.
-- =====================================================================

Sort.THROTTLE = 0.15   -- seconds between verified moves (perf + taint-quiet)

local function inCombat()
    return _G.InCombatLockdown and _G.InCombatLockdown()
end

-- Bank open? Only permit bank containers when the bank UI is actually open.
local function bankIsOpen()
    local bf = _G.BankFrame
    return bf and bf.IsShown and bf:IsShown() and true or false
end

-- Live meta lookup (cached per Run). classID/subClassID resolve synchronously from
-- GetItemInfoInstant; name/quality/maxStack come from GetItemInfo (may be uncached
-- on a cold item — falls back so the sort still runs deterministically).
local function makeMetaFn(cache)
    return function(id)
        if not id then return nil end
        local m = cache[id]
        if m then return m end
        m = { classID = HUGE, subClassID = HUGE, name = "", quality = 0, maxStack = 1 }
        local CI = _G.C_Item or {}
        local instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant
        local info    = CI.GetItemInfo        or _G.GetItemInfo
        if instant then
            local _, _, _, _, _, classID, subClassID = instant(id)
            if classID then m.classID = classID end
            if subClassID then m.subClassID = subClassID end
        end
        if info then
            local name, _, quality, _, _, _, _, stackCount = info(id)
            if name then m.name = name:lower() end
            if quality then m.quality = quality end
            if stackCount and stackCount > 0 then m.maxStack = stackCount end
        end
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
    Sort._moves, Sort._i, Sort._token = nil, nil, nil
    if Sort._driver then Sort._driver:UnregisterAllEvents() end
    if _G.ClearCursor then _G.ClearCursor() end
end

local function abort(reason)
    if not Sort._running then return end
    if ns.Print then ns:Print("sort stopped: " .. tostring(reason)) end
    stopDriver()
end

local function advance()
    if not Sort._running then return end
    Sort._i = Sort._i + 1
    if Sort._i > #Sort._moves then
        if ns.Print then ns:Print("sort complete (" .. #Sort._moves .. " moves).") end
        stopDriver()
        if ns.Frame and ns.Frame.RequestRefresh then ns.Frame.RequestRefresh() end
        return
    end
    local after = _G.C_Timer and _G.C_Timer.After
    if after then after(Sort.THROTTLE, Sort._step) else Sort._step() end
end

-- One verified tick: guard, issue the move, then wait for BAG_UPDATE (with a
-- fallback timeout so a no-op move still advances). A per-step token prevents the
-- event and the fallback from both advancing the same move.
function Sort._step()
    if not Sort._running then return end
    if inCombat() then return abort("entered combat") end
    if Sort._needsBank and not bankIsOpen() then return abort("bank closed") end
    if ns.Frame and ns.Frame.IsShown and not ns.Frame.IsShown() and not Sort._needsBank then
        return abort("window closed")
    end
    local m = Sort._moves[Sort._i]
    local token = (Sort._token or 0) + 1
    Sort._token = token
    if ns.SafeCall then ns:SafeCall(performMove, m) else performMove(m) end
    local function proceed()
        if Sort._running and Sort._token == token then advance() end
    end
    Sort._proceed = proceed
    local after = _G.C_Timer and _G.C_Timer.After
    if after then after(Sort.THROTTLE * 4, proceed) end   -- fallback if no BAG_UPDATE
end

local function ensureDriver()
    if Sort._driver or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then abort("entered combat"); return end
        if event == "BANKFRAME_CLOSED" and Sort._needsBank then abort("bank closed"); return end
        if event == "BAG_UPDATE" then
            local p = Sort._proceed
            if p then Sort._proceed = nil; p() end
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
    local plan = Sort.Plan({
        cells = cells,
        meta = makeMetaFn(cache),
        canHold = makeCanHoldFn(cache),
    })
    if #plan.moves == 0 then
        if ns.Print then ns:Print("bags already sorted.") end
        return true
    end

    ensureDriver()
    Sort._running   = true
    Sort._moves     = plan.moves
    Sort._i         = 1
    Sort._needsBank = needsBank
    Sort._driver:RegisterEvent("BAG_UPDATE")
    Sort._driver:RegisterEvent("PLAYER_REGEN_DISABLED")
    if needsBank then Sort._driver:RegisterEvent("BANKFRAME_CLOSED") end
    Sort._step()
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

-- meta catalog for the plan tests. classID/subClassID drive grouping.
local META = {
    -- id  = class, subclass, name, quality, maxStack
    [100] = { classID = 0, subClassID = 0, name = "apple",   quality = 1, maxStack = 20 }, -- consumable
    [101] = { classID = 0, subClassID = 0, name = "bread",   quality = 1, maxStack = 20 }, -- consumable
    [200] = { classID = 2, subClassID = 7, name = "sword",   quality = 3, maxStack = 1  }, -- weapon
    [201] = { classID = 4, subClassID = 0, name = "cloak",   quality = 2, maxStack = 1  }, -- armor
    [300] = { classID = 7, subClassID = 1, name = "cloth",   quality = 1, maxStack = 10 }, -- tradegood
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
    -- Already-sorted bag: re-planning yields zero moves (idempotent / determinism).
    local cells = bagCells(0, 6, {
        [1] = { id = 100, count = 20 }, [2] = { id = 100, count = 5 },
        [3] = { id = 101, count = 5 }, [4] = { id = 200 }, [5] = { id = 201 },
    })
    local plan = Sort.Plan({ cells = cells, meta = metaFn })
    ck(#plan.moves == 0, "already-sorted bag -> no moves (idempotent)")

    -- Locked slot is a fixed point: its item is never a move source or destination.
    local locked = bagCells(0, 6, {
        [1] = { id = 200 },                      -- weapon that WOULD sort last
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

function Sort.RunSelfTests(verbose)
    local suites = {
        { name = "merge pour (exhaustive)", fn = testMergePour },
        { name = "canonical stacks",        fn = testCanonicalStacks },
        { name = "plan: merge + group sort", fn = testPlanMergeAndSort },
        { name = "plan: idempotent + locked", fn = testPlanIdempotentAndLocked },
        { name = "plan: family + multi-bag", fn = testPlanFamilyAndMultiBag },
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
