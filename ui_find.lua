-- Daseeki Bags 2.0 — ui_find.lua  (W3)
-- The CROSS-CHARACTER FIND WINDOW (parity audit §3.2, GAP #3 full): search every
-- cached owner's stored items at once, grouped by owner, and jump straight to a
-- holder's view with the search applied. This is the signature Daseeki feature the
-- Bagnon-clones lack — "which of my alts has a Songflower?" in one query.
--
-- Reuses search.lua's compiled matcher UNCHANGED (Search.Compile(text):Match(slot,
-- resolver)) so the Find grammar is identical to the in-bag search (name substring +
-- q:/t:/slot: prefixes, AND-ed). The heavy lifting is PURE and headless-tested:
--   Find.Search(owners, query, resolver) -> per-owner grouped results (bank/bags split)
--   Find.BuildItemRows(results, resolver) -> ONE aggregate row per distinct item
--   Find.WindowHeight(rowCount)          -> size-to-content, clamped, then scroll
-- The FRAME layer is a small Ledger window (its own maker's mark) with a search box
-- and a scrolling result list.
--
-- ── DISPLAY ROUND (owner-directed) ────────────────────────────────────────────
-- ITEM 2 — AGGREGATE ROWS. The window used to render one row per (item, owner,
--   location), so ten alts holding a Chronoboon produced ten near-identical rows. It
--   now renders ONE row per distinct ITEM: icon + quality-colored name + the TOTAL
--   across every owner and location. The per-character breakdown did not disappear —
--   it moved to where it belongs, the item tooltip (features.lua's 1.x anatomy), which
--   the row anchors on hover.
-- ITEM 3 — BOUNDARIES. Rows used to be laid straight into a plain frame that clipped
--   nothing, so a long result list drew straight through the window's bottom border.
--   The list is now a ScrollFrame (which clips its scroll child by construction), the
--   window SIZES TO CONTENT up to MAX_ROWS and scrolls past that, and the name column
--   owns everything between the icon and the right-aligned count.
-- ITEM 4 — SUMMARY OWNERS ARE SEARCHED. Find.Search used to visit owner.containers
--   only, so a cross-account SUMMARY owner (mesh / Nexus bridge) contributed nothing
--   BY CONSTRUCTION: the owner searched an item, Find said 1 copy, the tooltip said 2.
--   A summary owner carries an aggregate map (itemCounts: id -> count) with no slots,
--   so its ids are now run through the SAME compiled matcher against a synthetic
--   record { id = <id>, count = <n> } — the matcher only ever reads record.id and
--   resolves name/type/quality from the resolver, so the grammar is identical. A
--   summary hit has no slot location: it contributes to the TOTAL only, and the
--   tooltip's Other Accounts section names who holds it.
--
-- ── DATA-HONESTY ROUND (2.0.5, audit BAG-1 / BAG-2) ──────────────────────────
-- COLD ITEMS. This file used to discard the matcher's `pending` return and register no
--   events at all, so on a fresh login — the one state the feature exists for — every
--   unresolved id scored as a MISS and the window said "No character has a matching item"
--   for an item three alts were holding, forever. It now runs the loop search.lua has
--   always run: hold the pending ids, ask the client, re-run when the answers land, and
--   say "still loading N items" meanwhile. See THE COLD-ITEM CONTRACT below.
--
-- Secure audit: zero protected ops — reads store records, sets view state + the
-- inventory search box (both insecure), Show/Hides its own unprotected window.

local ADDON, ns = ...

local Find = {}
ns.Find = Find

local Store = ns.Store

----------------------------------------------------------------------
-- PURE: search across every owner
--
-- owners  = Store.data.owners shape ([key] = ownerRecord)
-- query   = a compiled query (Search.Compile(text)); Find no-ops on an empty query.
-- resolver= { instant=, info= } (Search's live resolver, or a fake in tests)
-- opts    = { selfKey = <key to sort first> }
-- Returns an array (sorted self-first, then total desc, then name) of:
--   { key, name, class, source, bagsCount, bankCount, summaryCount, total, isSelf,
--     matches      = { { cid, slot, data }, ... },        -- per-slot hits (full owners)
--     summaryHits  = { { id, count }, ... } }             -- aggregate hits (summary owners)
-- Only owners with >=1 match are included.
--
-- SECOND RETURN: `pending` — the sorted itemIDs the matcher could NOT judge because
-- C_Item.GetItemInfo has not answered for them yet (BAG-1). Not a miss: an unanswered
-- question. Discarding it is what made a fresh login say "No character has a matching
-- item" for an item three alts were holding; see THE COLD-ITEM CONTRACT below.
--
-- ITEM 4 (cross-account): a SUMMARY owner has no containers, only owner.itemCounts —
-- the exact shape features.CountItemInOwner falls back to for its tooltip numbers. Its
-- ids are matched with the same compiled query against a synthetic record, so the two
-- surfaces can no longer disagree about who holds what. The containers branch and the
-- itemCounts branch are MUTUALLY EXCLUSIVE (a full owner also mirrors an aggregate
-- itemCounts map; counting both would double every number).
----------------------------------------------------------------------

function Find.Search(owners, query, resolver, opts)
    opts = opts or {}
    local results = {}
    -- Ids the matcher reported PENDING. Held, never scored as a miss (BAG-1).
    local pendingSet, pending = {}, {}
    if type(owners) ~= "table" or not query or query.isEmpty then return results, pending end

    for key, owner in pairs(owners) do
        local containers = owner.containers
        local hasSlots = (type(containers) == "table") and next(containers) ~= nil
        local bags, bank, summary = 0, 0, 0
        local matches, summaryHits = {}, {}

        if hasSlots then
            for cid, c in pairs(containers) do
                local isBank = Store.IsBankContainer(cid)
                local slots = c and c.slots
                if type(slots) == "table" then
                    for slot, rec in pairs(slots) do
                        if rec and rec.id then
                            local matched, isPending = query:Match(rec, resolver)
                            if matched then
                                local n = rec.count or 1
                                if isBank then bank = bank + n else bags = bags + n end
                                matches[#matches + 1] = { cid = cid, slot = slot, data = rec }
                            elseif isPending then
                                pendingSet[rec.id] = true
                            end
                        end
                    end
                end
            end
        elseif type(owner.itemCounts) == "table" then
            -- Aggregate-only owner: no slot, no location — a contribution to the total.
            for id, n in pairs(owner.itemCounts) do
                id, n = tonumber(id), tonumber(n)
                if id and n and n > 0 then
                    local rec = { id = id, count = n }
                    local matched, isPending = query:Match(rec, resolver)
                    if matched then
                        summary = summary + n
                        summaryHits[#summaryHits + 1] = { id = id, count = n }
                    elseif isPending then
                        pendingSet[id] = true
                    end
                end
            end
            -- Deterministic order (pairs over itemCounts is arbitrary).
            table.sort(summaryHits, function(a, b) return a.id < b.id end)
        end

        if #matches > 0 or #summaryHits > 0 then
            results[#results + 1] = {
                key = key, name = owner.name or key, class = owner.class,
                source = owner.source or "summary",
                bagsCount = bags, bankCount = bank, summaryCount = summary,
                total = bags + bank + summary,
                isSelf = (opts.selfKey ~= nil and key == opts.selfKey),
                matches = matches, summaryHits = summaryHits,
            }
        end
    end

    table.sort(results, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        if a.total ~= b.total then return a.total > b.total end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    -- Sorted, because this list drives a RETRY loop and pairs() order differing per
    -- attempt is how a bounded retry becomes a lottery (async class 8).
    for id in pairs(pendingSet) do pending[#pending + 1] = id end
    table.sort(pending)
    return results, pending
end

-- Plain-copy result line: "Poonyx — Bank: 12 · Bags: 40" (only non-zero parts shown).
-- (Retained for callers/tests; the window renders per-ITEM aggregate rows instead.)
function Find.FormatOwnerResult(result)
    local parts = {}
    if (result.bankCount or 0) > 0 then parts[#parts + 1] = "Bank: " .. result.bankCount end
    if (result.bagsCount or 0) > 0 then parts[#parts + 1] = "Bags: " .. result.bagsCount end
    if (result.summaryCount or 0) > 0 then parts[#parts + 1] = "Elsewhere: " .. result.summaryCount end
    if #parts == 0 then parts[1] = "0" end
    return result.name .. " — " .. table.concat(parts, " \194\183 ")   -- \194\183 = middot
end

----------------------------------------------------------------------
-- PURE: the AGGREGATE ROW model (display round, ITEM 2).
--
-- ONE row per distinct ITEM, carrying the TOTAL across every owner and every location:
--   [icon] <qualityColor>Chronoboon Displacer</>                            x63
-- Ten alts each holding one no longer produce ten rows; the per-character breakdown is
-- the item TOOLTIP's job now (features.lua's 1.x anatomy: Total header, same-account
-- rows with location badges, an Other Accounts section), and the row anchors it on hover.
--
--   results  = Find.Search output (already sorted self-first, then total desc, then name)
--   resolver = { instant=<GetItemInfoInstant>, info=<GetItemInfo> }
--
-- Row = { itemID, itemName, quality, icon, total, holders, hasSummary,
--         jumpKey, jumpName }
--   holders    — how many distinct characters hold it (drives the "on N characters" hint)
--   hasSummary — at least one contribution came from a cross-account SUMMARY owner, i.e.
--                the number includes copies whose slots are not browsable here
--   jumpKey    — click-to-jump target: the FIRST holder in the Search order that is a
--                FULL owner (summary owners have no slots to jump to, so a summary-only
--                item has jumpKey == nil and its row click is inert).
--
-- Row ORDER is item name ASCENDING. Deliberately not total-desc: names resolve
-- asynchronously through GetItemInfo while the player is still typing, and a count-
-- ordered list re-shuffles under the cursor every time one lands.
--
-- SECOND RETURN: `pending` — the sorted itemIDs whose NAME did not answer, so the row is
-- carrying an "item:<id>" placeholder. Those rows are flagged `row.pending` and sort
-- AFTER every named row rather than wedging themselves into the alphabet under "i"
-- (BAG-2), and the id list feeds the shared cold-item watch so they repaint when the
-- names land. The comment above knew the names arrive late; this is the listening half.
--
-- A stored record may carry a captured `link`, which DOES contain a name — but wrapped in
-- colour escapes, so `tostring(itemName):lower()` sorts it under "|" rather than under its
-- first letter. Unsortable is unsortable: a row whose plain name has not answered goes to
-- the bottom whichever placeholder it is wearing, and takes its proper place once the real
-- name lands. (This does not touch the MATCHER, which reads the resolver and never the
-- link — which is precisely why a cold search failed even for items with stored links.)
----------------------------------------------------------------------

function Find.BuildItemRows(results, resolver)
    local agg, order = {}, {}
    local pendingSet, pending = {}, {}

    local function identify(id, data)
        local name, quality, icon = nil, data and data.quality, nil
        local isPending = false
        if resolver then
            if resolver.instant then local _, _, _, _, ic = resolver.instant(id); icon = ic end
            if resolver.info then
                local nm, _, q = resolver.info(id)
                name = nm
                if quality == nil then quality = q end
                -- We ASKED and got no answer: pending. With no resolver at all there is
                -- nothing to wait for, so an absent resolver is never reported pending.
                if nm == nil then isPending = true end
            end
        end
        return name, quality, icon, isPending
    end

    local function bucket(id, data)
        local row = agg[id]
        if not row then
            local name, quality, icon, isPending = identify(id, data)
            row = {
                itemID = id, itemName = name or (data and data.link) or ("item:" .. id),
                quality = quality, icon = icon,
                total = 0, holders = 0, hasSummary = false,
                pending = isPending or nil,
                jumpKey = nil, jumpName = nil,
                _seen = {},
            }
            if isPending and not pendingSet[id] then pendingSet[id] = true end
            agg[id] = row
            order[#order + 1] = row
        end
        return row
    end

    for _, res in ipairs(results or {}) do
        local isFull = (res.source == "full")
        for _, mt in ipairs(res.matches or {}) do
            local data = mt.data
            local id = data and data.id
            if id then
                local row = bucket(id, data)
                row.total = row.total + (data.count or 1)
                if not row._seen[res.key] then
                    row._seen[res.key] = true
                    row.holders = row.holders + 1
                end
                -- First FULL holder in the Search order wins the jump target.
                if isFull and not row.jumpKey then
                    row.jumpKey, row.jumpName = res.key, res.name
                end
            end
        end
        for _, hit in ipairs(res.summaryHits or {}) do
            local row = bucket(hit.id, nil)
            row.total = row.total + (hit.count or 0)
            row.hasSummary = true
            if not row._seen[res.key] then
                row._seen[res.key] = true
                row.holders = row.holders + 1
            end
            if isFull and not row.jumpKey then
                row.jumpKey, row.jumpName = res.key, res.name
            end
        end
    end

    for _, row in ipairs(order) do row._seen = nil end
    table.sort(order, function(a, b)
        -- Unresolved names sort LAST (see the header): an "item:22785" placeholder must
        -- not claim a place in the alphabet it will vacate two seconds later.
        local ap, bp = a.pending and 1 or 0, b.pending and 1 or 0
        if ap ~= bp then return ap < bp end
        local an, bn = tostring(a.itemName):lower(), tostring(b.itemName):lower()
        if an ~= bn then return an < bn end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    for id in pairs(pendingSet) do pending[#pending + 1] = id end
    table.sort(pending)
    return order, pending
end

-- The two row columns, as plain testable strings. `qualityHex` is injected so the
-- headless tests can assert the shape; the live render passes a real color escape.
--   left  = "<qualityHex>Chronoboon Displacer|r"
--   right = "x63"   (the count tag is bare "1" -> "x1" is still shown: an aggregate row
--                    of exactly one copy is information, not noise)
function Find.FormatItemRow(row, qualityHex)
    qualityHex = qualityHex or ""
    local nameStr = qualityHex .. (row.itemName or "?") .. (qualityHex ~= "" and "|r" or "")
    return nameStr, "x" .. tostring(row.total or 0)
end

----------------------------------------------------------------------
-- PURE: THE COLD-ITEM CONTRACT  (data-honesty BAG-1 / BAG-2; async class 4 + 5)
--
-- `query:Match(record, resolver)` returns TWO values — matched, and PENDING, true exactly
-- when a name/quality clause could not be evaluated because C_Item.GetItemInfo has not
-- answered for that itemID yet. search.lua:288 and rules2.lua:423 have always consumed
-- the second one. THIS FILE DISCARDED IT, and registered no events at all.
--
-- What that cost, in the one state the feature exists for: on a fresh login your alts'
-- stored itemIDs are precisely the ids the client has never had in a tooltip this
-- session, so GetItemInfo returns nil for most of them, every one of them scored as a
-- MISS, every holder contributed zero matches and was dropped from `results` — and the
-- window said "No character has a matching item" for an item three alts were holding,
-- forever, because nothing ever ran the search again. The signature Daseeki feature
-- failing in exactly the state it is most needed.
--
-- Absence of proof is not absence. A pending item is HELD — not counted as a match (we
-- cannot claim what we cannot read) and not counted as a miss either — the client is
-- asked for it, the search re-runs when the answer lands, and the surface SAYS SO
-- meanwhile: an honest in-progress, never a false emptiness.
--
-- Catalog-verified against interface 11509 / build 1.15.9.68808:
--   C_Item.GetItemInfo, C_Item.GetItemInfoInstant, C_Item.RequestLoadItemDataByID,
--   Event.Item.GetItemInfoReceived  (== GET_ITEM_INFO_RECEIVED {itemID, success}).
----------------------------------------------------------------------

-- THE RE-RUN LADDER. GET_ITEM_INFO_RECEIVED is the primary signal and needs no timer:
-- the ladder is the belt to its braces, for answers that arrive with no event of their
-- own (a dropped request; data that warmed between our read and our ask) and for ids that
-- never answer at all. It is BOUNDED — five rungs, 7.75s — and then the surfaces stop
-- claiming "loading" and state what they actually have. A ladder with no last rung is the
-- same lie in a slower voice.
Find.WATCH_LADDER = { 0.25, 0.5, 1, 2, 4 }

-- Per-id ask ceiling. GET_ITEM_INFO_RECEIVED also fires with success=false for an id the
-- server has no data for; that id stays pending forever, so an unbounded ask/repaint pair
-- would trade a stuck window for an event storm. Three asks per id per query, then we
-- stop asking and let the count say so.
Find.MAX_ASKS = 3

-- PURE: the delay for ladder rung `round` (1-based), or nil past the last rung — which is
-- the ladder's terminal condition and therefore the thing a test can pin.
function Find.LadderDelay(round)
    local n = tonumber(round)
    if not n then return nil end
    return Find.WATCH_LADDER[n]
end

-- PURE: the total time the ladder spans, i.e. how long a surface may say "still loading".
function Find.LadderCeiling()
    local t = 0
    for i = 1, #Find.WATCH_LADDER do t = t + Find.WATCH_LADDER[i] end
    return t
end

-- PURE: the sorted, de-duplicated union of two itemID lists. Sorted for the same class-8
-- reason Find.Search sorts its own: this list drives a retry loop.
function Find.MergeIDs(a, b)
    local seen, out = {}, {}
    local lists = { a, b }
    for li = 1, 2 do
        local list = lists[li]
        if type(list) == "table" then
            for i = 1, #list do
                local id = tonumber(list[i])
                if id and not seen[id] then seen[id] = true; out[#out + 1] = id end
            end
        end
    end
    table.sort(out)
    return out
end

-- PURE: the two lines a cold-item surface is allowed to show about its own certainty.
--   state = { hasQuery = <bool>, rows = <n>, pending = <n>, exhausted = <bool> }
-- Returns emptyText (the no-rows line; nil when rows exist) and statusText (the small
-- "still loading" tag; nil when there is nothing to say).
--
-- THE LOAD-BEARING ROW: rows == 0 with pending > 0 is NOT "no matches". It is "we have
-- not been told yet", and it must read as that. The exhausted form is the honest end of
-- the ladder — it states the miss AND names what went unchecked, rather than quietly
-- folding unknowns into the answer.
function Find.StatusText(state)
    state = state or {}
    local rows      = tonumber(state.rows) or 0
    local pending   = tonumber(state.pending) or 0
    local exhausted = state.exhausted and true or false

    if not state.hasQuery then
        return "Type an item name to search every character.", nil
    end

    local phrase = (pending == 1) and "1 item" or (tostring(pending) .. " items")

    if rows == 0 then
        if pending > 0 and not exhausted then
            return "Still loading item data for " .. phrase ..
                   " \194\183 matches will appear as they arrive.", nil
        end
        if pending > 0 then
            return "No character has a matching item. " .. phrase ..
                   " never sent their data, so they could not be checked.", nil
        end
        return "No character has a matching item.", nil
    end

    if pending > 0 and not exhausted then
        return nil, "still loading " .. phrase .. "\226\128\166"
    end
    if pending > 0 then
        return nil, phrase .. " unchecked"
    end
    return nil, nil
end

----------------------------------------------------------------------
-- PURE: WINDOW GEOMETRY (display round, ITEM 3).
--
-- The beta laid rows into an unclipped frame at a fixed window height, so any result
-- list longer than the window drew straight through the bottom border. The window now
-- sizes to its content between MIN_ROWS and MAX_ROWS and scrolls beyond that (the
-- frame layer parents the rows to a ScrollFrame, which clips by construction).
----------------------------------------------------------------------

Find.WIN_W    = 420   -- wide enough for "Supercharged Chronoboon Displacer" + the count
Find.ROW_H    = 20
Find.CHROME_H = 78    -- titlebar (36) + search box (24) + gap (8) + bottom pad (10)
Find.MIN_ROWS = 3
Find.MAX_ROWS = 14

-- Window height for a result count, clamped to the min/max row band.
function Find.WindowHeight(rowCount)
    local n = rowCount or 0
    if n < Find.MIN_ROWS then n = Find.MIN_ROWS end
    if n > Find.MAX_ROWS then n = Find.MAX_ROWS end
    return Find.CHROME_H + n * Find.ROW_H
end

-- True when the list exceeds the window band and the scroll range is live.
function Find.NeedsScroll(rowCount)
    return (rowCount or 0) > Find.MAX_ROWS
end

-- Scrollable overshoot in pixels (0 when everything fits).
function Find.ScrollRange(rowCount)
    local extra = (rowCount or 0) - Find.MAX_ROWS
    if extra <= 0 then return 0 end
    return extra * Find.ROW_H
end

-- =====================================================================
-- FRAME LAYER (in-game only)
-- =====================================================================

local UI
local WINDOW_NAME = "DaseekiBags2FindWindow"

-- Live resolver (same C_Item path as search.lua / ui_items.lua).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
    }
end

local function classRGB(class)
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    if UI and UI.Color then return UI.Color("text") end
    return 0.925, 0.890, 0.816
end

-- =====================================================================
-- THE SHARED COLD-ITEM WATCH  (BAG-1 + BAG-2)
--
-- ONE watch set, ONE event frame, ONE ladder — serving the Find window AND every summary
-- panel, exactly as the audit's fix note asks. They are the same defect on two surfaces
-- reading the same resolver, so giving them two independent loops would be two chances to
-- fix only one of them next time.
--
-- Surfaces register a repaint closure (Find.AddSurface) and report the ids they could not
-- judge (Find.NotePending). When an answer lands — by event, or by a ladder rung for the
-- answers that arrive without one — every registered surface re-derives from the resolver
-- and repaints itself. Each surface owns its own shownness check, so a closed window
-- costs nothing.
-- =====================================================================

Find._watch     = Find._watch or {}    -- [itemID] = true — asked for, not yet answered
Find._asks      = Find._asks  or {}    -- [itemID] = how many times we have asked (<= MAX_ASKS)
Find._surfaces  = Find._surfaces or {} -- ordered repaint closures (ipairs: class 8)
Find._watchRound     = 0               -- ladder rungs fired this cycle
Find._watchExhausted = false           -- the ladder ran out; stop claiming "loading"
Find._watchTimer     = false           -- a rung is armed

-- Register a surface's repaint. Called once per surface at construction.
function Find.AddSurface(fn)
    if type(fn) ~= "function" then return end
    Find._surfaces[#Find._surfaces + 1] = fn
end

-- New INPUT (a new query, a different owner) restarts the ladder — never the watch set
-- itself: an id already asked for keeps its event subscription, so a late answer still
-- repaints even after the timers have stopped. Events are free; timers are the thing that
-- has to be bounded.
function Find.ResetWatch()
    Find._watchRound, Find._watchExhausted = 0, false
    Find._asks = {}
end

local function askFor(id)
    local n = Find._asks[id] or 0
    if n >= Find.MAX_ASKS then return false end
    Find._asks[id] = n + 1
    local CI = _G.C_Item
    if CI and CI.RequestLoadItemDataByID then CI.RequestLoadItemDataByID(id) end
    return true
end

function Find.EnsureWatchFrame()
    if Find._evt or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(_, _, itemID)
        if Find._watch[itemID] == nil then return end
        Find._watch[itemID] = nil
        Find.RequestRepaint()
    end)
    Find._evt = f
end

-- Debounced repaint of every registered surface: an info-received burst on login is
-- hundreds of events in a handful of frames, and each one must not re-run the search.
Find._repaintQueued = false
function Find.RequestRepaint()
    if Find._repaintQueued then return end
    Find._repaintQueued = true
    local fire = function()
        Find._repaintQueued = false
        if ns.SafeCall then ns:SafeCall(Find.Repaint) else Find.Repaint() end
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, fire) else fire() end
end

function Find.Repaint()
    for i = 1, #Find._surfaces do
        local fn = Find._surfaces[i]
        if ns.SafeCall then ns:SafeCall(fn) else fn() end
    end
end

-- Arm the next ladder rung, or close the cycle out honestly when there is no next rung.
function Find.ArmLadder()
    if Find._watchTimer or Find._watchExhausted then return end
    local delay = Find.LadderDelay(Find._watchRound + 1)
    if not delay then
        -- The bound. One last repaint so every surface swaps its "still loading" line for
        -- the honest "could not be checked" one, and no further timer is scheduled.
        Find._watchExhausted = true
        Find.RequestRepaint()
        return
    end
    Find._watchTimer = true
    local fire = function()
        Find._watchTimer = false
        Find._watchRound = Find._watchRound + 1
        if next(Find._watch) == nil then return end   -- everything answered; the event path did it
        -- Re-ask (within the per-id ceiling) in a DETERMINISTIC order, then repaint: an id
        -- that warmed without firing an event lands here rather than never.
        local ids = {}
        for id in pairs(Find._watch) do ids[#ids + 1] = id end
        table.sort(ids)
        for i = 1, #ids do askFor(ids[i]) end
        Find.RequestRepaint()
        Find.ArmLadder()
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(delay, fire) else fire() end
end

-- A surface reports the ids it could not judge. Idempotent: an id already on the watch is
-- not re-asked here (the ladder owns re-asking), so a warm client that reports nothing
-- pending never creates a frame, never arms a timer, and stays a single pass.
function Find.NotePending(ids)
    if type(ids) ~= "table" or #ids == 0 then return end
    -- ── CLASS 9 (2026-08-11): SUBSCRIBE BEFORE THE FIRST ASK, NOT AFTER ──────────────
    -- This call used to sit BELOW the loop, which is one client call too late.
    -- RequestLoadItemDataByID does not always schedule its answer: for an id the client
    -- already holds it dispatches GET_ITEM_INFO_RECEIVED from INSIDE the request, and
    -- every handler registered in the session runs before the request returns. With the
    -- watch frame built afterwards there was no handler at all, so the answers to the
    -- FIRST pass — the fresh-login pass, the only one that matters — were delivered into
    -- nothing. `_watch[id]` then stayed true for an id that was already warm: the surfaces
    -- kept saying "still loading N items", the ladder burned all its rungs re-asking for
    -- data it had, and the cycle closed out as `_watchExhausted`, i.e. the window ended up
    -- telling the owner "N items never sent their data" about items the client had
    -- answered for before the loop finished. Arming first costs nothing — the frame is
    -- idempotent and the `#ids == 0` return above still keeps the warm path frameless.
    Find.EnsureWatchFrame()
    for i = 1, #ids do
        local id = ids[i]
        if id and Find._watch[id] == nil then
            -- The watch entry is set BEFORE the ask for the same reason (the handler reads
            -- it); the frame is what was missing.
            Find._watch[id] = true
            askFor(id)
        end
    end
    Find.ArmLadder()
end

function Find.Ensure()
    if Find.window then return Find.window end
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end

    local win = _G.CreateFrame("Frame", WINDOW_NAME, _G.UIParent, "BackdropTemplate")
    -- ITEM 3: seeded at the empty-state height; Find.Refresh re-sizes to content.
    win:SetSize(Find.WIN_W, Find.WindowHeight(0))
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:Hide()
    UI.Skin(win, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        -- 1.0 PARITY (opacity): near-solid dark ground (Bags-side alpha; sibling of inventory).
        self:SetBackdropColor(UI.Color("ground", (ns.Frame and ns.Frame.WINDOW_BG_ALPHA) or 0.94))
        self:SetBackdropBorderColor(UI.Color("border"))
    end)
    if UI.PaintLedgerGround then UI.PaintLedgerGround(win) end
    if _G.UISpecialFrames then table.insert(_G.UISpecialFrames, WINDOW_NAME) end

    -- Title bar
    local titleBar = _G.CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT"); titleBar:SetPoint("TOPRIGHT"); titleBar:SetHeight(28)
    titleBar:EnableMouse(true); titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() win:StopMovingOrSizing() end)
    local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
    tbBg:SetPoint("TOPLEFT", 1, -1); tbBg:SetPoint("BOTTOMRIGHT", -1, 0)
    UI.Skin(tbBg, function(self) self:SetColorTexture(UI.Color("panel")) end)
    local mark
    if UI.MakerMark then mark = UI.MakerMark(titleBar, { size = 18 }); mark:SetPoint("LEFT", 8, 0) end
    local title = titleBar:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.ceremonial or UI.fonts.header)
    if mark then title:SetPoint("LEFT", mark, "RIGHT", 8, 0) else title:SetPoint("LEFT", 10, 0) end
    title:SetText("Find")
    local closeBtn = _G.CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(24, 24); closeBtn:SetPoint("RIGHT", -6, 0)
    local cx = closeBtn:CreateFontString(nil, "OVERLAY"); cx:SetFontObject(UI.fonts.body)
    cx:SetPoint("CENTER"); cx:SetText("X")
    closeBtn:SetScript("OnEnter", function() cx:SetFontObject(UI.fonts.danger) end)
    closeBtn:SetScript("OnLeave", function() cx:SetFontObject(UI.fonts.body) end)
    closeBtn:SetScript("OnClick", function() Find.Close() end)

    -- Cold-item status tag (BAG-1): "still loading 37 items…" while the client is still
    -- answering, so a SHORT list is never mistaken for a COMPLETE one. Lives in the title
    -- bar, so it costs the result list no geometry at all.
    local status = titleBar:CreateFontString(nil, "OVERLAY")
    status:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    status:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    status:SetJustifyH("RIGHT")
    UI.Skin(status, function(self) self:SetTextColor(UI.Color("faint")) end)
    status:Hide()
    win.status = status

    -- Search box
    local wrap = UI.FlatFrame(win, "inset", "controlBorder")
    wrap:SetHeight(24)
    wrap:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -36)
    wrap:SetPoint("TOPRIGHT", win, "TOPRIGHT", -10, -36)
    local box = _G.CreateFrame("EditBox", nil, wrap)
    box:SetPoint("TOPLEFT", 6, 0); box:SetPoint("BOTTOMRIGHT", -6, 0)
    box:SetAutoFocus(true)
    box:SetFontObject(UI.fonts.body)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); Find.Close() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnTextChanged", function(self) Find.RequestSearch(self:GetText()) end)
    win.box = box
    local hint = box:CreateFontString(nil, "ARTWORK")
    hint:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    hint:SetPoint("LEFT", box, "LEFT", 0, 0)
    hint:SetText("Search all characters")
    UI.Skin(hint, function(self) self:SetTextColor(UI.Color("faint")) end)
    win.hint = hint

    -- ── Results host (ITEM 3) ────────────────────────────────────────────────
    -- A ScrollFrame, NOT a plain frame: a ScrollFrame clips its scroll child to its own
    -- rect by construction, which is exactly the defect the owner screenshotted (rows
    -- drawn past the bottom border). Its viewport is inset from the backdrop on all
    -- sides so a row can never touch the window edge. The scroll child holds the rows.
    local list = _G.CreateFrame("ScrollFrame", nil, win)
    list:SetPoint("TOPLEFT", wrap, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)
    local content = _G.CreateFrame("Frame", nil, list)
    content:SetSize(Find.WIN_W - 20, 1)
    list:SetScrollChild(content)
    -- Wheel scrolling, clamped to the live range (set per refresh in Find.Refresh).
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        local range = self._range or 0
        if range <= 0 then return end
        local v = (self:GetVerticalScroll() or 0) - delta * Find.ROW_H
        if v < 0 then v = 0 elseif v > range then v = range end
        self:SetVerticalScroll(v)
    end)
    win.list    = list
    win.content = content
    win._rows   = {}

    local empty = content:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(UI.fonts.muted)
    empty:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -2)
    empty:SetPoint("RIGHT", content, "RIGHT", -2, 0)
    empty:SetJustifyH("LEFT")
    win.emptyFS = empty

    win:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
    Find.window = win

    -- Register the window with the shared cold-item watch. Ensure is one-shot (it returns
    -- early once Find.window exists), so this is exactly one surface. A closed window
    -- re-runs nothing.
    Find.AddSurface(function()
        local w = Find.window
        if w and w.IsShown and w:IsShown() then Find.Refresh(nil, true) end
    end)

    return win
end

-- Quality hex ("|cffRRGGBB") for the item name; class hex for the character name.
local function qualityHex(quality)
    local q = quality or 1
    local c = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[q]
    if c and c.hex then return c.hex end
    local r, g, b
    if _G.C_Item and _G.C_Item.GetItemQualityColor then r, g, b = _G.C_Item.GetItemQualityColor(q) end
    if not r then r, g, b = 1, 1, 1 end
    return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end
local function classHex(class)
    local r, g, b = classRGB(class)
    return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end

-- ITEM 3 (truncation): the count column is right-aligned at a fixed width so the NAME
-- column owns everything else. Names longer than that ellipsize instead of clipping
-- mid-word ("(Ba…"): SetWordWrap(false) on a two-point-anchored fontstring gives WoW's
-- native "…" truncation, and the two-point anchor is what makes the width real.
local ICON_W, ICON_GAP, COUNT_W, ROW_PAD = 16, 5, 46, 2

-- ONE item row: [icon] name (quality-colored, ellipsizing) ............ xN
--
-- 2.0.2: lifted out of Find's own pool so the SUMMARY VIEW (a Nexus-only character's
-- aggregate item list, rendered in the inventory and bank windows) draws the same row
-- rather than a near-copy. `parent` is the caller's scroll child; the returned button
-- carries _icon/_label/_count/_hl and the tooltip scripts, and the caller supplies
-- _link before the row is shown. No Find state is touched, so the two consumers pool
-- independently.
function Find.CreateItemRow(parent)
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end
    local row = _G.CreateFrame("Button", nil, parent)
    row:SetHeight(Find.ROW_H)
    local hl = row:CreateTexture(nil, "BACKGROUND"); hl:SetAllPoints(); hl:Hide()
    UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("brand", 0.18)) end)
    row._hl = hl
    -- Row icon: 16px item icon at the left.
    local ic = row:CreateTexture(nil, "ARTWORK"); ic:SetSize(ICON_W, ICON_W)
    ic:SetPoint("LEFT", row, "LEFT", ROW_PAD, 0)
    row._icon = ic
    -- Count column FIRST (right-aligned, fixed width) so the name can anchor against it.
    local ct = row:CreateFontString(nil, "OVERLAY")
    ct:SetFontObject(UI.fonts.numeral or UI.fonts.body)
    ct:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD, 0)
    ct:SetWidth(COUNT_W)
    ct:SetJustifyH("RIGHT")
    UI.Skin(ct, function(self) self:SetTextColor(UI.Color("text")) end)
    row._count = ct
    local nm = row:CreateFontString(nil, "OVERLAY"); nm:SetFontObject(UI.fonts.body)
    nm:SetPoint("LEFT", ic, "RIGHT", ICON_GAP, 0)
    nm:SetPoint("RIGHT", ct, "LEFT", -6, 0)
    nm:SetJustifyH("LEFT"); nm:SetWordWrap(false)
    row._label = nm
    row:SetScript("OnEnter", function(self)
        self._hl:Show()
        -- ITEM 2: the row anchors the REAL item tooltip — which, with the 1.x anatomy
        -- restored in features.lua, is where the per-character breakdown now lives.
        if _G.GameTooltip and self._link then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if _G.GameTooltip.SetHyperlink then _G.GameTooltip:SetHyperlink(self._link) end
            _G.GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self) self._hl:Hide(); if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    return row
end

local function acquireRow(win, i)
    local row = win._rows[i]
    if row then return row end
    row = Find.CreateItemRow(win.content)
    win._rows[i] = row
    return row
end

-- Paint one item row from a { itemID, itemName, quality, icon, count } record. Shared by
-- Find's aggregate rows and the summary view so the two can never drift apart.
function Find.PaintItemRow(row, rec)
    if not (row and rec) then return end
    row._icon:SetTexture(rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row._label:SetText(qualityHex(rec.quality) .. (rec.itemName or "?") .. "|r")
    row._label:SetTextColor(1, 1, 1)   -- the embedded color escape carries the coloring
    row._count:SetText("x" .. tostring(rec.count or rec.total or 0))
    row._link = rec.itemID and ("item:" .. rec.itemID) or nil
end

-- =====================================================================
-- THE SUMMARY PANEL  (2.0.2, owner ask 2b)
--
-- A caption line over a scrolling list of Find-shaped item rows. The inventory window
-- swaps it in for the bag grid when the viewed character is Nexus-only, and the bank
-- window shows the SAME panel (with the bags/bank caveat in its caption) for the
-- right-click bank preview — because the Nexus payload carries ONE merged itemCounts
-- map and no bags/bank split exists to render (see Owner.SummaryCaption's banner).
--
-- Lives here, not in ui_frame/ui_bank, so there is exactly one implementation and it
-- reuses Find.CreateItemRow verbatim. Both hosts resolve it through ns.Find at CALL
-- time, so ui_find.lua loading after them (as the .toc does) is fine.
-- =====================================================================

Find.SUMMARY_CAP_H  = 30    -- caption band (wraps to two lines in the bank's longer form)
Find.SUMMARY_MIN_H  = 60
Find.SUMMARY_MAX_H  = 340

-- PURE: the panel's content height for `rowCount` rows, and its scroll overshoot.
-- Returns height, scrollRange.
function Find.SummaryHeight(rowCount)
    local n = rowCount or 0
    if n < 0 then n = 0 end
    local wanted = Find.SUMMARY_CAP_H + math.max(n, 1) * Find.ROW_H
    if wanted < Find.SUMMARY_MIN_H then return Find.SUMMARY_MIN_H, 0 end
    if wanted > Find.SUMMARY_MAX_H then
        return Find.SUMMARY_MAX_H, wanted - Find.SUMMARY_MAX_H
    end
    return wanted, 0
end

-- Build (or return) a summary panel parented to `parent`. The panel exposes
-- :SetSummary(owner, opts) — opts = { bank = <bool>, sortBy = "name"|"count" } — which
-- repaints the caption + rows and re-sizes itself. The caller anchors and shows it.
function Find.CreateSummaryPanel(parent)
    if not _G.CreateFrame then return nil end
    UI = UI or _G.DaseekiUI
    if not UI then return nil end

    local panel = _G.CreateFrame("Frame", nil, parent)
    panel:SetSize(1, Find.SUMMARY_MIN_H)

    local cap = panel:CreateFontString(nil, "OVERLAY")
    cap:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    cap:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
    cap:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    cap:SetJustifyH("LEFT")
    cap:SetHeight(Find.SUMMARY_CAP_H - 6)
    UI.Skin(cap, function(self) self:SetTextColor(UI.Color("faint")) end)
    panel._caption = cap

    -- A ScrollFrame, so a long list clips to the panel instead of drawing through the
    -- window's bottom border (the same defect ITEM 3 fixed in the Find window).
    local list = _G.CreateFrame("ScrollFrame", nil, panel)
    list:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -Find.SUMMARY_CAP_H)
    list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    local content = _G.CreateFrame("Frame", nil, list)
    content:SetSize(1, 1)
    list:SetScrollChild(content)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        local range = self._range or 0
        if range <= 0 then return end
        local v = (self:GetVerticalScroll() or 0) - delta * Find.ROW_H
        if v < 0 then v = 0 elseif v > range then v = range end
        self:SetVerticalScroll(v)
    end)
    panel._list, panel._content, panel._rows = list, content, {}

    local empty = content:CreateFontString(nil, "OVERLAY")
    empty:SetFontObject(UI.fonts.muted)
    empty:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -2)
    empty:SetPoint("RIGHT", content, "RIGHT", -2, 0)
    empty:SetJustifyH("LEFT")
    empty:Hide()
    panel._empty = empty

    -- BAG-2: `fromWatch` marks a repaint driven by the shared cold-item watch. A
    -- DIFFERENT owner is new input and restarts the ladder; the same owner re-rendered is
    -- not, or the watch would re-arm itself forever.
    function panel:SetSummary(owner, opts, fromWatch)
        opts = opts or {}
        local O = ns.Owner
        if not (O and O.SummaryRows) then return end
        if not fromWatch and self._owner ~= owner then Find.ResetWatch() end
        -- Remembered so the watch can re-render this exact panel when a name lands.
        self._owner, self._opts = owner, opts
        local rows, pending = O.SummaryRows(owner, liveResolver(), { sortBy = opts.sortBy })
        Find.NotePending(pending)
        self._caption:SetText(O.SummaryCaption(owner, nil, {
            bank = opts.bank, pending = #pending, exhausted = Find._watchExhausted }))
        for _, r in ipairs(self._rows) do r:Hide() end
        if #rows == 0 then
            self._empty:SetText(O.SummaryEmptyText(owner))
            self._empty:Show()
        else
            self._empty:Hide()
            local y = 0
            for i, rec in ipairs(rows) do
                local row = self._rows[i]
                if not row then
                    row = Find.CreateItemRow(self._content)
                    self._rows[i] = row
                end
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", self._content, "TOPLEFT", 0, -y)
                row:SetPoint("RIGHT", self._content, "RIGHT", 0, 0)
                Find.PaintItemRow(row, rec)
                row:Show()
                y = y + Find.ROW_H
            end
        end
        local h, range = Find.SummaryHeight(#rows)
        self:SetHeight(h)
        local vw = (self.GetWidth and self:GetWidth()) or 0
        if not vw or vw <= 1 then vw = Find.WIN_W - 20 end
        self._content:SetSize(vw, math.max(1, #rows * Find.ROW_H))
        self._list._range = range
        self._list:SetVerticalScroll(0)
        return #rows
    end

    -- Same shared watch as the Find window (BAG-2's fix note: ONE watch, ONE frame, both
    -- surfaces). The panel repaints itself only while it is shown and holding an owner.
    Find.AddSurface(function()
        if panel._owner and panel.IsShown and panel:IsShown() then
            panel:SetSummary(panel._owner, panel._opts, true)
        end
    end)

    return panel
end

-- Show or hide the title-bar cold-item tag.
local function setStatus(win, text)
    if not (win and win.status) then return end
    if text and text ~= "" then
        win.status:SetText(text); win.status:Show()
    else
        win.status:SetText(""); win.status:Hide()
    end
end

-- Run the search and repaint the result rows.
--
-- `fromWatch` marks a re-run driven by the shared cold-item watch rather than by the
-- owner. Only owner-driven input restarts the ladder; a watch repaint that reset it would
-- be a loop with no bound at all.
function Find.Refresh(text, fromWatch)
    local win = Find.window
    if not win then return end
    text = text or (win.box and win.box:GetText()) or ""
    if win.hint then win.hint:SetShown(text == "") end
    if not fromWatch then Find.ResetWatch() end

    for _, r in ipairs(win._rows) do r:Hide() end

    -- Size the window + reset the scroll for an N-row result (ITEM 3).
    local function fit(n)
        win:SetHeight(Find.WindowHeight(n))
        win.list._range = Find.ScrollRange(n)
        win.list:SetVerticalScroll(0)
        win.content:SetHeight(math.max(1, n * Find.ROW_H))
        -- The viewport width is only real once the window has been laid out; before that
        -- (first Refresh off Find.Open) fall back to the design width, never to 0 — a
        -- zero-width scroll child would collapse every row's two-point anchor.
        local vw = (win.list.GetWidth and win.list:GetWidth()) or 0
        if not vw or vw <= 1 then vw = Find.WIN_W - 20 end
        win.content:SetWidth(vw)
    end

    local query = ns.Search and ns.Search.Compile and ns.Search.Compile(text)
    if not query or query.isEmpty then
        fit(0)
        setStatus(win, nil)
        win.emptyFS:SetText((Find.StatusText({ hasQuery = false })))
        win.emptyFS:Show()
        return
    end

    local data = Store and Store.data
    local selfKey = ns.Owner and ns.Owner.SelfKey and ns.Owner.SelfKey()
    -- ITEM 4: the owner universe is the NEXUS-MERGED view when the bridge is live —
    -- Bags' own owners plus the Nexus store's cross-account SUMMARY owners, newest-wins.
    -- Reading Store.data.owners directly is what made Find blind to the other account
    -- even after the summary branch above existed. Type-guarded; falls back to the store.
    local owners = data and data.owners or {}
    if ns.Nexus and ns.Nexus.Owners then
        local view = ns.Nexus.Owners()
        if type(view) == "table" then owners = view end
    end
    local resolver = liveResolver()
    local results, searchPending = Find.Search(owners, query, resolver, { selfKey = selfKey })

    -- ITEM 2: ONE aggregate row per distinct item — icon, quality-colored name, TOTAL.
    local itemRows, rowPending = Find.BuildItemRows(results, resolver)

    -- BAG-1: consume the matcher's `pending`. Ids we could not judge (no name yet) and
    -- ids we could not NAME (matched on t:/slot:/q: but the label is a placeholder) go to
    -- the one shared watch, which asks the client and repaints every surface when the
    -- answers land.
    local watchIDs = Find.MergeIDs(searchPending, rowPending)
    Find.NotePending(watchIDs)

    local emptyText, statusText = Find.StatusText({
        hasQuery  = true,
        rows      = #itemRows,
        pending   = #watchIDs,
        exhausted = Find._watchExhausted,
    })
    setStatus(win, statusText)

    if #itemRows == 0 then
        -- NOT "no matches" while ids are still unanswered: an absence of proof rendered as
        -- an honest in-progress. StatusText owns which of the three lines this is.
        fit(0)
        win.emptyFS:SetText(emptyText)
        win.emptyFS:Show()
        return
    end
    win.emptyFS:Hide()

    fit(#itemRows)
    local y = 0
    for i, r in ipairs(itemRows) do
        local row = acquireRow(win, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", win.content, "RIGHT", 0, 0)
        row._icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local nameStr, countStr = Find.FormatItemRow(r, qualityHex(r.quality))
        row._label:SetText(nameStr)
        row._label:SetTextColor(1, 1, 1)   -- the embedded color escape carries the coloring
        row._count:SetText(countStr)
        row._link = r.itemID and ("item:" .. r.itemID) or nil
        -- Click-to-jump still targets a browsable holder; a summary-only item has none,
        -- so its row is inert (the tooltip already names who holds it).
        if r.jumpKey then
            row:SetScript("OnClick", function() Find.JumpTo(r.jumpKey, text) end)
            row:Enable()
        else
            row:SetScript("OnClick", nil)
        end
        row:Show()
        y = y + Find.ROW_H
    end
    for i = #itemRows + 1, #win._rows do win._rows[i]:Hide() end
end

Find._searchQueued = false
function Find.RequestSearch(text)
    Find._pendingText = text
    if Find._searchQueued then return end
    Find._searchQueued = true
    local fire = function()
        Find._searchQueued = false
        if ns.SafeCall then ns:SafeCall(Find.Refresh, Find._pendingText) else Find.Refresh(Find._pendingText) end
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, fire) else fire() end
end

-- Jump to a holder: flip the shared view to that owner, open the inventory (and the
-- bank if it has bank data), and apply the query so the matches highlight there.
function Find.JumpTo(ownerKey, text)
    local Frame = ns.Frame
    if Frame and Frame.SetViewedOwner then Frame.SetViewedOwner(ownerKey) end
    if Frame and Frame.Open then Frame.Open() end
    if Frame and Frame.SetSearch then Frame.SetSearch(text or "") end
    local owner = Store and Store.GetOwner and Store.GetOwner(ownerKey)
    if ns.Bank and ns.Bank.Open and ns.Owner and ns.Owner.HasBankData and ns.Owner.HasBankData(owner) then
        ns.Bank.Open()
    end
end

function Find.Open(text)
    local win = Find.Ensure()
    if not win then return end
    win:Show()
    if text and text ~= "" and win.box then win.box:SetText(text) end
    Find.Refresh(win.box and win.box:GetText() or text)
    if win.box then win.box:SetFocus() end
end

function Find.Close()
    if Find.window then Find.window:Hide() end
end

function Find.Toggle(text)
    local win = Find.Ensure()
    if not win then return end
    if win:IsShown() then Find.Close() else Find.Open(text) end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_find")
----------------------------------------------------------------------

-- Fake resolver: name/type from an item db keyed by id (see search.lua's shape).
local function fakeResolver(db)
    return {
        instant = function(id) local e = db[id]; if not e then return nil end
            return id, e.itype, e.isub, e.equip, 1 end,
        info = function(id) local e = db[id]; if not e then return nil end
            return e.name, "item:" .. id, e.quality end,
    }
end

local function testFindAcrossOwners(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [100] = { name = "Songflower Serenade Petal", quality = 1, itype = "Consumable", cached = true },
        [200] = { name = "Arcanite Bar", quality = 3, itype = "Trade Goods", cached = true },
    }
    local R = fakeResolver(db)
    -- Poonyx (self): 40 in bags (cid 0), 12 in bank (cid -1). Also unrelated item 200.
    -- Alt "Zug": 5 in a bank bag (cid 5). "NoPetal": only item 200 -> no match.
    -- Summary "Rex": 99 in its aggregate map — searched as of the display round (ITEM 4).
    local owners = {
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full", containers = {
            [0]  = { slots = { [1] = { id = 100, count = 20 }, [2] = { id = 100, count = 20 },
                               [3] = { id = 200, count = 5 } } },
            [-1] = { slots = { [1] = { id = 100, count = 12 } } },
        } },
        ["Zug-R"] = { name = "Zug", class = "WARRIOR", source = "full", containers = {
            [5] = { slots = { [1] = { id = 100, count = 5 } } },   -- bank bag
        } },
        ["NoPetal-R"] = { name = "NoPetal", class = "ROGUE", source = "full", containers = {
            [0] = { slots = { [1] = { id = 200, count = 3 } } },
        } },
        ["Rex-R"] = { name = "Rex", source = "summary", containers = {}, itemCounts = { [100] = 99 } },
    }

    local q = ns.Search.Compile("songflower")
    local res = Find.Search(owners, q, R, { selfKey = "Poonyx-R" })
    ck(#res == 3, "three holders match 'songflower' (self + Zug + summary Rex), got " .. #res)
    ck(res[1].key == "Poonyx-R" and res[1].isSelf, "self sorts first")
    ck(res[1].bagsCount == 40 and res[1].bankCount == 12 and res[1].total == 52,
        "Poonyx split: 40 bags / 12 bank / 52 total")
    ck(#res[1].matches == 3, "Poonyx has 3 matching stacks (2 bag + 1 bank)")
    local zug, rex
    for _, r in ipairs(res) do
        if r.key == "Zug-R" then zug = r elseif r.key == "Rex-R" then rex = r end
    end
    ck(zug and zug.bankCount == 5 and zug.bagsCount == 0, "Zug: 5 in a bank bag, 0 in bags")
    -- ITEM 4: the summary owner "Rex" holds 99 of item 100 in its aggregate map and is
    -- now a result — it used to be invisible by construction. Its contribution has no
    -- slot location: bagsCount/bankCount stay 0 and summaryCount carries the number.
    ck(rex ~= nil, "the summary owner is searched (ITEM 4)")
    ck(rex and rex.summaryCount == 99 and rex.bagsCount == 0 and rex.bankCount == 0,
        "summary hit contributes to the total with no location")
    ck(res[2].key == "Rex-R", "results still sort self-first, then total desc")
    -- format strings
    ck(Find.FormatOwnerResult(res[1]) == "Poonyx — Bank: 12 \194\183 Bags: 40", "self line format")
    ck(Find.FormatOwnerResult(zug) == "Zug — Bank: 5", "bank-only line omits Bags")
    local bagsOnly = { name = "X", bagsCount = 7, bankCount = 0 }
    ck(Find.FormatOwnerResult(bagsOnly) == "X — Bags: 7", "bags-only line omits Bank")

    -- empty query -> no results
    ck(#Find.Search(owners, ns.Search.Compile(""), R, {}) == 0, "empty query -> no results")
    -- a query nobody matches
    ck(#Find.Search(owners, ns.Search.Compile("thunderfury"), R, {}) == 0, "no holder -> empty")
end

-- ITEM 2 (display round): ONE aggregate row per distinct ITEM, carrying the TOTAL
-- across every owner and location. The per-(item, owner, location) explosion is gone.
local function testFindAggregateRows(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [100] = { name = "Chronoboon Displacer", quality = 1, itype = "Consumable" },
        [101] = { name = "Supercharged Chronoboon Displacer", quality = 1, itype = "Consumable" },
    }
    local R = fakeResolver(db)
    -- Ten alts each holding a stack, plus self holding two stacks in two locations and a
    -- single supercharged one — the owner's exact screenshot shape.
    local owners = {}
    for i = 1, 10 do
        owners["Alt" .. i .. "-R"] = { name = "Alt" .. i, class = "ROGUE", source = "full",
            containers = { [0] = { slots = { [1] = { id = 100, count = 6 } } } } }
    end
    owners["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full", containers = {
        [0]  = { slots = { [1] = { id = 100, count = 2 }, [2] = { id = 101, count = 1 } } },
        [-1] = { slots = { [1] = { id = 100, count = 1 } } },
    } }

    local q = ns.Search.Compile("chronoboon")
    local res = Find.Search(owners, q, R, { selfKey = "Poonyx-R" })
    ck(#res == 11, "eleven holders match, got " .. #res)
    local rows = Find.BuildItemRows(res, R)
    -- The whole point: 11 holders x up-to-2 locations collapses to TWO item rows.
    ck(#rows == 2, "two distinct items -> two rows, got " .. #rows)
    -- Name ascending: "Chronoboon Displacer" before "Supercharged ...".
    ck(rows[1].itemName == "Chronoboon Displacer", "rows sort by item name ascending")
    ck(rows[2].itemName == "Supercharged Chronoboon Displacer", "second row is the supercharged one")
    ck(rows[1].total == 10 * 6 + 2 + 1, "total sums every owner AND both locations, got " .. rows[1].total)
    ck(rows[1].holders == 11, "holder count is distinct characters, got " .. rows[1].holders)
    ck(rows[1].hasSummary == false, "no summary contribution in an all-full result")
    ck(rows[1].jumpKey == "Poonyx-R", "self (first in the Search order) is the jump target")
    ck(rows[1].quality == 1 and rows[1].icon ~= nil, "row carries quality + icon for the render")
    ck(rows[1]._seen == nil, "the holder-dedupe scratch table is cleaned off the row")

    -- Row columns: "<qHex>Name|r" and "xN".
    local nameStr, countStr = Find.FormatItemRow(rows[1], "|cffFFFFFF")
    ck(nameStr == "|cffFFFFFFChronoboon Displacer|r", "name column carries the quality escape, got: " .. nameStr)
    ck(countStr == "x63", "count column is the grand total, got " .. countStr)
    local bare = select(1, Find.FormatItemRow({ itemName = "Hearthstone", total = 1 }))
    ck(bare == "Hearthstone", "no hex -> bare name")
    ck(select(2, Find.FormatItemRow({ itemName = "Hearthstone", total = 1 })) == "x1",
        "a single copy still shows its count")

    -- Unresolved name (GetItemInfo not back yet) falls back to a stable key, never nil.
    local unresolved = Find.BuildItemRows({ { key = "K", name = "K", source = "full",
        matches = { { cid = 0, slot = 1, data = { id = 4242, count = 3 } } }, summaryHits = {} } }, nil)
    ck(#unresolved == 1 and unresolved[1].itemName == "item:4242", "unresolved name falls back to item:<id>")

    ck(#Find.BuildItemRows({}, R) == 0, "no results -> no rows")
    ck(#Find.BuildItemRows(nil, R) == 0, "nil results -> no rows")
end

-- ITEM 4 (display round): SUMMARY owners are searched via their aggregate itemCounts.
-- The owner's proven gap: Find showed 1 copy where the tooltip showed 2, the second on a
-- cross-account summary character. The lock is that a summary holder BOTH appears in the
-- results AND lands in the aggregate total, while a FULL owner (which also mirrors an
-- itemCounts map) is never double-counted.
local function testFindSummaryOwners(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [100] = { name = "Chronoboon Displacer", quality = 1, itype = "Consumable" },
        [200] = { name = "Arcanite Bar", quality = 3, itype = "Trade Goods" },
    }
    local R = fakeResolver(db)
    local owners = {
        -- FULL owner: 1 in bags. Its itemCounts mirror MUST NOT be counted a second time.
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full",
            containers = { [0] = { slots = { [1] = { id = 100, count = 1 } } } },
            itemCounts = { [100] = 1 } },
        -- SUMMARY owner on another account: 1 copy, aggregate only.
        ["Remote-R"] = { name = "Remote", class = "PRIEST", source = "summary",
            containers = {}, itemCounts = { [100] = 1, [200] = 9 } },
    }
    local q = ns.Search.Compile("chronoboon")
    local res = Find.Search(owners, q, R, { selfKey = "Poonyx-R" })
    ck(#res == 2, "the summary owner now shows up as a holder, got " .. #res)

    local full, summary
    for _, r in ipairs(res) do
        if r.key == "Poonyx-R" then full = r elseif r.key == "Remote-R" then summary = r end
    end
    ck(full and full.total == 1, "the full owner is counted ONCE (no itemCounts double-count)")
    ck(full and #full.summaryHits == 0, "a full owner produces no summary hits")
    ck(summary and summary.total == 1 and summary.summaryCount == 1,
        "the summary owner contributes its aggregate")
    ck(summary and summary.bagsCount == 0 and summary.bankCount == 0,
        "a summary hit has NO slot location")
    ck(summary and #summary.summaryHits == 1 and summary.summaryHits[1].id == 100,
        "summary hits carry the matched item id (the non-matching 200 is filtered)")

    -- The aggregate row now reports 2 — the number the tooltip has always shown.
    local rows = Find.BuildItemRows(res, R)
    ck(#rows == 1, "one aggregate row for one distinct item")
    ck(rows[1].total == 2, "cross-account total is 2 (1 local + 1 remote), got " .. tostring(rows[1].total))
    ck(rows[1].holders == 2, "two holders")
    ck(rows[1].hasSummary == true, "row flags that part of the total is cross-account")
    ck(rows[1].jumpKey == "Poonyx-R", "jump target is the FULL holder")

    -- A summary-ONLY item has no browsable holder, so no jump target.
    local res2 = Find.Search(owners, ns.Search.Compile("arcanite"), R, { selfKey = "Poonyx-R" })
    local rows2 = Find.BuildItemRows(res2, R)
    ck(#rows2 == 1 and rows2[1].total == 9, "summary-only item totals 9")
    ck(rows2[1].jumpKey == nil, "summary-only row has no jump target (nothing to browse)")

    -- The grammar still applies to summary ids: a t: term filters them too.
    local res3 = Find.Search(owners, ns.Search.Compile("t:trade"), R, { selfKey = "Poonyx-R" })
    ck(#res3 == 1 and res3[1].key == "Remote-R", "type prefix filters summary ids as well")
end

-- ITEM 3 (display round): the window sizes to content, then scrolls. The defect was
-- rows drawn past the bottom border; this geometry contract is the pure half of the fix
-- (the frame half is the ScrollFrame, which clips its child by construction).
local function testFindWindowGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local H, MIN, MAX, RH = Find.CHROME_H, Find.MIN_ROWS, Find.MAX_ROWS, Find.ROW_H
    ck(Find.WindowHeight(0) == H + MIN * RH, "empty state clamps to the minimum band")
    ck(Find.WindowHeight(1) == H + MIN * RH, "1 row still clamps to the minimum band")
    ck(Find.WindowHeight(MIN + 2) == H + (MIN + 2) * RH, "grows with content between the bounds")
    ck(Find.WindowHeight(MAX) == H + MAX * RH, "exactly MAX rows fits without scrolling")
    ck(Find.WindowHeight(MAX + 50) == H + MAX * RH, "beyond MAX the window stops growing")
    ck(Find.WindowHeight(nil) == H + MIN * RH, "nil row count is the empty state")

    ck(Find.NeedsScroll(MAX) == false, "MAX rows needs no scroll")
    ck(Find.NeedsScroll(MAX + 1) == true, "MAX+1 rows scrolls")
    ck(Find.ScrollRange(MAX) == 0, "no overshoot at MAX")
    ck(Find.ScrollRange(MAX + 3) == 3 * RH, "overshoot is the hidden rows' height")
    ck(Find.ScrollRange(0) == 0, "empty list has no scroll range")
    -- THE REGRESSION LOCK: the visible rows always fit inside the window, at every count.
    for n = 0, MAX + 5 do
        local visible = math.min(n, MAX)
        ck(H + visible * RH <= Find.WindowHeight(n),
            "rows fit inside the window at n=" .. n)
    end
    -- Wide enough for the owner's longest cited name plus the right-aligned count column.
    ck(Find.WIN_W >= 400, "window is wide enough for a long consumable name")
end

-- 2.0.2: the SUMMARY PANEL's geometry, and the shared row machinery it composes from.
-- The panel is the content band of the inventory window (and of the bank preview) for a
-- Nexus-only character, so its height IS that window's height — a pure function, pinned
-- here beside the Find window's own sizing for the same reason.
local function testSummaryPanelGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- The row machinery is SHARED with the summary view rather than reimplemented.
    ck(type(Find.CreateItemRow) == "function", "the item-row factory is published")
    ck(type(Find.PaintItemRow) == "function", "…and so is the painter both consumers use")
    ck(type(Find.CreateSummaryPanel) == "function", "the summary panel factory is published")

    -- Empty and tiny lists still get a real band — a zero-height content frame is the
    -- zero-frame defect the window sizing rules exist to prevent.
    local h0, r0 = Find.SummaryHeight(0)
    ck(h0 >= Find.SUMMARY_MIN_H, "an empty summary still has a visible band (" .. h0 .. ")")
    ck(r0 == 0, "…and nothing to scroll")
    ck(Find.SummaryHeight(-5) == h0, "a negative count is treated as empty")
    ck(Find.SummaryHeight(nil) == h0, "…and so is nil")

    -- It grows with content, monotonically, until the clamp.
    local prev = 0
    for _, n in ipairs({ 1, 3, 8, 14 }) do
        local h = Find.SummaryHeight(n)
        ck(h >= prev, "height is monotone in the row count (n=" .. n .. ")")
        ck(h <= Find.SUMMARY_MAX_H, "…and never past the clamp (n=" .. n .. ")")
        prev = h
    end

    -- Past the clamp it scrolls rather than drawing through the window's bottom border.
    local hBig, rBig = Find.SummaryHeight(400)
    ck(hBig == Find.SUMMARY_MAX_H, "a huge list clamps to the max panel height")
    ck(rBig > 0, "…and the overshoot becomes scroll range")
    ck(rBig == Find.SUMMARY_CAP_H + 400 * Find.ROW_H - Find.SUMMARY_MAX_H,
        "…which is exactly the overshoot")
    ck(Find.SUMMARY_MAX_H >= Find.SUMMARY_CAP_H + 8 * Find.ROW_H,
        "at least 8 rows are visible before scrolling starts")
    -- The caption band must actually reserve room for the bank's two-line caption.
    ck(Find.SUMMARY_CAP_H >= 2 * Find.ROW_H - 12, "the caption band fits a wrapped line")
end

-- BAG-1 (data honesty, async class 4): the COLD-ITEM CONTRACT, pure half.
--
-- The premise is the fresh login: a resolver whose `info` answers nil for every id,
-- because that is literally the client's state — your alts' stored itemIDs are the ones
-- no tooltip has warmed this session. The RED CONTROL is the old chain: it scored every
-- pending item as a miss, so `#results == 0` and the window said "No character has a
-- matching item" about an item three alts were holding. The GREEN is that the same call
-- now HANDS BACK the ids it could not judge, and that the line the window shows for a
-- zero-row result is an in-progress rather than an emptiness.
local function testColdItems(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- The cold client: type/subtype/icon answer (static data, synchronous); name and
    -- quality do not (server-cached, async). This is exactly search.lua's `cached = false`.
    local cold = {
        instant = function(id) return id, "Consumable", "Consumable", "", 5000 + id end,
        info    = function() return nil end,
    }
    local warm = {
        instant = cold.instant,
        info    = function(id) return "Songflower Serenade Petal", "item:" .. id, 1 end,
    }
    local owners = {
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full", containers = {
            [0] = { slots = { [1] = { id = 100, count = 20 } } } } },
        ["Zug-R"] = { name = "Zug", class = "WARRIOR", source = "full", containers = {
            [5] = { slots = { [1] = { id = 101, count = 5 } } } } },
        ["Rex-R"] = { name = "Rex", source = "summary", containers = {}, itemCounts = { [102] = 99 } },
    }
    local q = ns.Search.Compile("songflower")

    ------------------------------------------------------------------ the red control
    local coldRes, coldPending = Find.Search(owners, q, cold, { selfKey = "Poonyx-R" })
    ck(#coldRes == 0,
       "PREMISE (the red control): on a cold client the matcher can judge nothing, so the " ..
       "old chain's result list is EMPTY and the window said 'No character has a matching item'")
    ck(#coldPending == 3,
       "THE FIX: those three ids come back as PENDING rather than vanishing (got " ..
       #coldPending .. ")")
    ck(coldPending[1] == 100 and coldPending[2] == 101 and coldPending[3] == 102,
       "…sorted, and covering BOTH branches — slot owners and the summary owner's aggregate")

    -- And the line the window actually shows for that state is not a denial.
    local emptyCold = Find.StatusText({ hasQuery = true, rows = 0, pending = #coldPending })
    ck(emptyCold:find("Still loading", 1, true) == 1,
       "…and the empty line reads as in-progress, not as emptiness: " .. emptyCold)
    ck(emptyCold:find("No character", 1, true) == nil, "…it does not claim a miss it cannot prove")

    ------------------------------------------------------------------ the green
    local warmRes, warmPending = Find.Search(owners, q, warm, { selfKey = "Poonyx-R" })
    ck(#warmRes == 3, "once the client warms, all three holders appear (got " .. #warmRes .. ")")
    ck(#warmPending == 0, "…with nothing left pending")
    local _, warmStatus = Find.StatusText({ hasQuery = true, rows = 3, pending = 0 })
    ck(warmStatus == nil, "…and a fully-resolved result says nothing about loading")
    -- A warm single pass reports no pending at all, which is what makes NotePending a
    -- no-op and keeps the warm client on ONE pass with no frame and no timer.
    ck(#(select(2, Find.Search(owners, q, warm, {}))) == 0, "a warm search is pending-free, every time")

    ------------------------------------------------------------------ a REAL miss
    -- The honest miss must survive the fix: warm data that simply does not match is still
    -- "No character has a matching item", with no loading language anywhere.
    local missRes, missPending = Find.Search(owners, ns.Search.Compile("thunderfury"), warm, {})
    ck(#missRes == 0 and #missPending == 0, "a warm non-match is a real miss, not a pending one")
    local missText = Find.StatusText({ hasQuery = true, rows = 0, pending = 0 })
    ck(missText == "No character has a matching item.", "…and reads as one: " .. missText)

    ------------------------------------------------------------------ a t: query, cold name
    -- t:/slot: resolve from static data, so a cold item can MATCH while its name is still
    -- a placeholder. The row is held, flagged, sorted last, and its id watched.
    local tRes, tPending = Find.Search(owners, ns.Search.Compile("t:consumable"), cold, {})
    ck(#tRes == 3 and #tPending == 0, "t: matches on synchronous static data, nothing pending")
    local tRows, tRowPending = Find.BuildItemRows(tRes, cold)
    ck(#tRows == 3, "…three rows render")
    ck(#tRowPending == 3, "…but their NAMES are pending, and BuildItemRows says so")
    ck(tRows[1].pending == true and tRows[1].itemName == "item:100",
       "…each unnamed row is flagged, not silently placeholdered")
    ck(tRows[1].icon == 5100, "…while the icon, which is synchronous, is real")

    -- Half warm: named rows keep the alphabet, the placeholder sorts LAST (BAG-2's rule,
    -- shared with Owner.SummaryRows so the two lists cannot drift).
    local half = {
        instant = cold.instant,
        info = function(id)
            if id == 101 then return nil end
            return (id == 100) and "Alpha Elixir" or "Zeta Elixir", "item:" .. id, 1
        end,
    }
    local halfRows, halfPending = Find.BuildItemRows(tRes, half)
    ck(#halfPending == 1 and halfPending[1] == 101, "only the unresolved id is pending")
    ck(halfRows[1].itemName == "Alpha Elixir" and halfRows[2].itemName == "Zeta Elixir",
       "the named rows hold their alphabetical order")
    ck(halfRows[3].itemID == 101 and halfRows[3].pending == true,
       "…and the placeholder sorts last, not under 'i'")
    -- With rows on screen AND ids outstanding, the window tags the shortfall rather than
    -- letting a partial list read as a complete one.
    local pEmpty, pStatus = Find.StatusText({ hasQuery = true, rows = 3, pending = 1 })
    ck(pEmpty == nil, "rows exist, so there is no empty line")
    ck(pStatus == "still loading 1 item\226\128\166", "…and the tag names the shortfall: " .. tostring(pStatus))

    ------------------------------------------------------------------ the bound
    -- The ladder is finite by construction: LadderDelay runs out, and that is the ONLY
    -- terminal condition ArmLadder has. A ladder with no last rung is the same lie slower.
    ck(#Find.WATCH_LADDER >= 3, "the ladder has real rungs (" .. #Find.WATCH_LADDER .. ")")
    for i = 2, #Find.WATCH_LADDER do
        ck(Find.WATCH_LADDER[i] >= Find.WATCH_LADDER[i - 1], "…backing off, not hammering (rung " .. i .. ")")
    end
    ck(Find.LadderDelay(#Find.WATCH_LADDER) ~= nil, "the last rung has a delay")
    ck(Find.LadderDelay(#Find.WATCH_LADDER + 1) == nil, "THE BOUND: there is no rung past the last one")
    ck(Find.LadderDelay(0) == nil and Find.LadderDelay(nil) == nil and Find.LadderDelay("x") == nil,
       "…and junk rounds do not conjure one")
    local ceil = Find.LadderCeiling()
    ck(ceil > 0 and ceil < 60, "the whole ladder spans a sane window (" .. ceil .. "s)")
    ck(Find.MAX_ASKS >= 1 and Find.MAX_ASKS <= 5,
       "…and the per-id ask ceiling is bounded too (an id the server has no data for fires " ..
       "GET_ITEM_INFO_RECEIVED with success=false forever)")

    ------------------------------------------------------------------ the id union
    local u = Find.MergeIDs({ 3, 1, 3 }, { 2, 1 })
    ck(#u == 3, "MergeIDs de-duplicates within and across both lists (got " .. #u .. ")")
    ck(u[1] == 1 and u[2] == 2 and u[3] == 3, "…and returns them SORTED (class 8)")
    ck(#Find.MergeIDs(nil, nil) == 0, "…and tolerates two absent lists")
    ck(#Find.MergeIDs({ 7 }, nil) == 1, "…or one")

    ------------------------------------------------------------------ the three empty lines
    ck((Find.StatusText({ hasQuery = false })):find("Type an item name", 1, true) == 1,
       "no query -> the prompt")
    local exhausted = Find.StatusText({ hasQuery = true, rows = 0, pending = 4, exhausted = true })
    ck(exhausted:find("No character has a matching item.", 1, true) == 1,
       "ladder spent -> the miss is stated…")
    ck(exhausted:find("4 items never sent their data", 1, true) ~= nil,
       "…AND what went unchecked is named, rather than folded into the answer: " .. exhausted)
    ck(exhausted:find("Still loading", 1, true) == nil, "…and it stops claiming to be loading")
    ck((Find.StatusText({ hasQuery = true, rows = 0, pending = 1 })):find("1 item ", 1, true) ~= nil,
       "singular reads '1 item'")
    ck(select(2, Find.StatusText({ hasQuery = true, rows = 2, pending = 2, exhausted = true }))
       == "2 items unchecked", "a partial list past the ladder tags itself as partial")
end

function Find.RunSelfTests(verbose)
    local suites = {
        { name = "find across owners",  fn = testFindAcrossOwners },
        { name = "aggregate item rows", fn = testFindAggregateRows },
        { name = "summary owners",      fn = testFindSummaryOwners },
        { name = "window geometry",     fn = testFindWindowGeometry },
        { name = "summary panel geometry", fn = testSummaryPanelGeometry },
        { name = "cold items",          fn = testColdItems },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_find/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_find/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_find", Find.RunSelfTests)
end

return Find
