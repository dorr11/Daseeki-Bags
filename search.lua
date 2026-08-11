-- Daseeki Bags 2.0 — search.lua
-- The D4 owned search matcher (design D4: simple substring + q:/t:/slot: prefixes,
-- terms AND-ed). Two cleanly separated layers, mirroring the store/ui split:
--
--   PURE core (no WoW API; the harness unit-tests the whole grammar):
--     Search.Tokenize(query)     — query string -> ordered term list
--     Search.ParseQuality(str)   — "epic" / "4" / ">=3" -> op, number
--     Search.Compile(query)      — term list -> a query object with :Match(record, resolver)
--     query:Match(record, resolver) -> matched(bool), pending(bool)
--
--   LIVE controller (in-game only; guarded on _G):
--     Search.SetQuery(text)      — debounced re-filter of the open window
--     Search.Filter() / Reapply  — dim every non-matching item button across BOTH layouts
--
-- Match derivation uses the SAME C_Item info path ui_items.lua uses:
--   * name / quality  — C_Item.GetItemInfo (async; nil until the server caches).
--                       A term needing an unresolved name/quality reports the record
--                       as PENDING (dimmed now, re-filtered on GET_ITEM_INFO_RECEIVED).
--   * type / subtype  — C_Item.GetItemInfoInstant (SYNCHRONOUS from static client
--                       data), so t: never blocks.
--   * equip slot      — C_Item.GetItemInfoInstant itemEquipLoc ("INVTYPE_HEAD" -> "head").
--
-- Empty-slot cells never dim (the controller skips buttons with no data). An empty
-- query restores every button to full brightness.
--
-- Catalog-verified (wow-api-catalog/1.15.9.68808): C_Item.GetItemInfo,
-- C_Item.GetItemInfoInstant, C_Item.RequestLoadItemDataByID; GET_ITEM_INFO_RECEIVED.

local ADDON, ns = ...

local Search = {}
ns.Search = Search

local Store = ns.Store

----------------------------------------------------------------------
-- Quality vocabulary (names + numbers -> ITEM_QUALITY index 0..7)
----------------------------------------------------------------------

local QUALITY_NAMES = {
    poor = 0, junk = 0, gray = 0, grey = 0,
    common = 1, white = 1,
    uncommon = 2, green = 2,
    rare = 3, blue = 3,
    epic = 4, purple = 4,
    legendary = 5, orange = 5,
    artifact = 6,
    heirloom = 7,
}
Search.QUALITY_NAMES = QUALITY_NAMES

----------------------------------------------------------------------
-- PURE: quality value parse — "epic" | "4" | ">=3" | ">3" | "<=2" | "=1"
-- Returns op ("=="|">="|">"|"<="|"<"), value(number) or nil when unrecognized.
----------------------------------------------------------------------

function Search.ParseQuality(str)
    if type(str) ~= "string" then return nil end
    str = str:lower():gsub("%s+", "")
    if str == "" then return nil end
    -- leading comparison operator
    local op = "=="
    local rest = str
    local o2 = str:match("^([<>]=?)")   -- >=, <=, >, <
    if o2 then op = o2; rest = str:sub(#o2 + 1)
    elseif str:sub(1, 1) == "=" then rest = str:sub(2) end
    -- value: a name or a number
    local n = tonumber(rest)
    if n == nil then n = QUALITY_NAMES[rest] end
    if n == nil then return nil end
    return op, n
end

----------------------------------------------------------------------
-- PURE: tokenize a raw query into an ordered term list.
--   bare word      -> { kind = "name", text = <lower> }
--   q:<val>        -> { kind = "quality", op = <op>, value = <n> }
--   t:<text>       -> { kind = "type", text = <lower> }
--   slot:<text>    -> { kind = "slot", text = <lower> }
-- Multiple terms are AND-ed by Match. Unparseable / empty-value tokens are dropped.
----------------------------------------------------------------------

function Search.Tokenize(query)
    local terms = {}
    if type(query) ~= "string" then return terms end
    for tok in query:gmatch("%S+") do
        local low = tok:lower()
        local prefix, value = low:match("^(%a+):(.*)$")
        if prefix == "q" then
            local op, n = Search.ParseQuality(value)
            if op then terms[#terms + 1] = { kind = "quality", op = op, value = n } end
        elseif prefix == "t" then
            if value ~= "" then terms[#terms + 1] = { kind = "type", text = value } end
        elseif prefix == "slot" then
            if value ~= "" then terms[#terms + 1] = { kind = "slot", text = value } end
        elseif prefix == "set" then
            -- Equipment-set membership (Daseeki-Armory integration). A bare `set:` (empty
            -- value) is KEPT — it means "belongs to ANY equipment set"; `set:<name>` matches
            -- a set whose name contains the fragment. Unlike t:/slot:, the empty form is not
            -- dropped because it is a meaningful query.
            terms[#terms + 1] = { kind = "set", text = value }
        else
            -- bare token = a name substring term (prefix-less colons fall here too).
            terms[#terms + 1] = { kind = "name", text = low }
        end
    end
    return terms
end

----------------------------------------------------------------------
-- PURE: derive the searchable fields of a slot record via the injected resolver
-- (resolver = { instant = <GetItemInfoInstant>, info = <GetItemInfo> }).
----------------------------------------------------------------------

-- Normalize an equip-loc token ("INVTYPE_WEAPONMAINHAND") to a lower fragment
-- ("weaponmainhand") for substring matching. Empty/nil -> "".
local function equipFragment(equipLoc)
    if type(equipLoc) ~= "string" or equipLoc == "" then return "" end
    return (equipLoc:lower():gsub("^invtype_", ""))
end
Search._equipFragment = equipFragment

local function derive(record, resolver)
    local d = { quality = record and record.quality }
    if not record or not record.id then return d end
    if resolver and resolver.instant then
        local _, itype, isub, equip = resolver.instant(record.id)
        d.itype = itype and itype:lower() or nil
        d.isub  = isub  and isub:lower()  or nil
        d.equip = equip                          -- raw INVTYPE_ token (may be "")
        d.hasInstant = (itype ~= nil)
    end
    if resolver and resolver.info then
        local name, _, quality = resolver.info(record.id)
        d.name = name and name:lower() or nil
        if d.quality == nil then d.quality = quality end
    end
    -- Equipment-set names (lowercased) this item belongs to, via the injected sets
    -- resolver (Daseeki-Armory). nil => Armory absent / feature inert (set: never matches).
    if resolver and resolver.sets then
        d.sets = resolver.sets(record.id)
    end
    return d
end

----------------------------------------------------------------------
-- PURE: evaluate one term against the derived fields.
-- Returns matched(bool), pending(bool). `pending` = the data this term needs is
-- not yet resolved (so the record can't be judged yet — dim + re-filter later).
----------------------------------------------------------------------

local function cmp(q, op, v)
    if op == ">=" then return q >= v end
    if op == ">"  then return q >  v end
    if op == "<=" then return q <= v end
    if op == "<"  then return q <  v end
    return q == v
end

local function evalTerm(term, d)
    local kind = term.kind
    if kind == "name" then
        if d.name == nil then return false, true end       -- name not cached yet
        return d.name:find(term.text, 1, true) ~= nil, false
    elseif kind == "quality" then
        if d.quality == nil then return false, true end     -- quality not resolved yet
        return cmp(d.quality, term.op, term.value), false
    elseif kind == "type" then
        if d.itype == nil and d.isub == nil then
            -- instant is synchronous for a valid id; nil here means static data not
            -- loaded — treat as pending so a re-filter can settle it.
            return false, true
        end
        local hit = (d.itype and d.itype:find(term.text, 1, true))
                 or (d.isub  and d.isub:find(term.text, 1, true))
        return hit ~= nil, false
    elseif kind == "slot" then
        if d.equip == nil and not d.hasInstant then return false, true end
        local frag = equipFragment(d.equip)
        return frag ~= "" and frag:find(term.text, 1, true) ~= nil, false
    elseif kind == "set" then
        -- Set membership resolves synchronously from Armory's in-memory db (never pending).
        -- nil sets = Armory absent / no data => definitive miss (feature inert, never dims-waits).
        local s = d.sets
        if type(s) ~= "table" then return false, false end
        if term.text == "" then return #s > 0, false end       -- bare set: = ANY set
        for i = 1, #s do
            if type(s[i]) == "string" and s[i]:find(term.text, 1, true) then return true, false end
        end
        return false, false
    end
    return true, false
end

----------------------------------------------------------------------
-- PURE: compile a query string into a reusable query object.
--   query.isEmpty                       — no terms
--   query:Match(record, resolver)       — matched(bool), pending(bool)
--   query.terms                         — the parsed term list (introspection/tests)
----------------------------------------------------------------------

function Search.Compile(query)
    local terms = Search.Tokenize(query)
    local q = { terms = terms, isEmpty = (#terms == 0) }

    function q:Match(record, resolver)
        if self.isEmpty then return true, false end
        if not record or not record.id then return false, false end
        local d = derive(record, resolver)
        local pending = false
        for i = 1, #self.terms do
            local m, p = evalTerm(self.terms[i], d)
            if p then
                pending = true                 -- keep scanning: a later term may hard-fail
            elseif not m then
                return false, false            -- definitive miss; no point waiting
            end
        end
        if pending then return false, true end  -- all resolved terms pass; wait on data
        return true, false
    end

    return q
end

-- =====================================================================
-- LIVE CONTROLLER (in-game only)
-- =====================================================================

-- Read-only Daseeki-Armory consumer: the lowercased names of the equipment sets a
-- base itemID belongs to, or nil when Armory is absent / uninitialised (feature inert).
-- Armory publishes DaseekiArmory:GetSetsContainingItem(itemID) -> array of set names,
-- keyed on base itemID (a number); sets are per-character (its own SVs), so this only
-- ever reflects the LOGGED-IN character — offline/alt owners get no set data, matching
-- the live-only nature of the new/quest markers.
local function armorySets(itemID)
    local A = _G.DaseekiArmory
    if not (A and A.GetSetsContainingItem and A.db and A.db.sets) then return nil end
    local ok, names = pcall(A.GetSetsContainingItem, A, itemID)
    if not ok or type(names) ~= "table" then return nil end
    local low = {}
    for i = 1, #names do low[i] = tostring(names[i]):lower() end
    return low
end
Search._armorySets = armorySets   -- exposed for debugging

-- Injected-live resolver from the game globals (identical path to ui_items).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
        sets    = armorySets,
    }
end

Search._query = Search.Compile("")   -- current compiled query (empty => no dimming)

-- Items whose match is pending; re-filtered when their data arrives.
Search._watch = Search._watch or {}   -- [itemID] = true

local function ensureEventFrame()
    if Search._evt or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(_, _, itemID)
        if Search._watch[itemID] then
            Search._watch[itemID] = nil
            Search.RequestFilter()
        end
    end)
    Search._evt = f
end

-- Walk every live item button across BOTH layouts via the frame's iterator and set
-- each button's dim state. Empty-slot buttons (no data) are always undimmed.
function Search.Filter()
    local Frame = ns.Frame
    if not (Frame and Frame.ForEachButton) then return end
    local q = Search._query
    local resolver = liveResolver()
    Search._watch = {}
    Frame.ForEachButton(function(button)
        if not button.SetDimmed then return end
        local data = button._data
        if not data or not data.id then button:SetDimmed(false); return end
        if q.isEmpty then button:SetDimmed(false); return end
        local matched, pending = q:Match(data, resolver)
        button:SetDimmed(not matched)
        if pending then
            Search._watch[data.id] = true
            -- ── CLASS 9 (2026-08-11): SUBSCRIBE BEFORE THE ASK ───────────────────────
            -- ensureEventFrame() used to run BELOW this loop, after every request had
            -- already gone out. RequestLoadItemDataByID does not always schedule its
            -- answer — for an id the client already holds it dispatches
            -- GET_ITEM_INFO_RECEIVED from inside the request — so on the FIRST filter pass
            -- (the one that builds the frame) every in-call answer was delivered to no
            -- listener at all. `_watch[id]` stayed set, nothing re-filtered, and the cell
            -- kept whatever dim state the cold read gave it until the owner typed again.
            -- Called per pending id rather than once above the loop so the warm path is
            -- untaxed exactly as before: nothing pending, no frame (the gate the old
            -- `if next(Search._watch)` provided). EnsureEventFrame is idempotent.
            ensureEventFrame()
            if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
                _G.C_Item.RequestLoadItemDataByID(data.id)
            end
        end
    end)
end

-- Debounced filter (coalesce as-you-type keystrokes + info-received bursts into one
-- pass per tick), matching the frame's own repaint debounce shape.
Search._filterQueued = false
function Search.RequestFilter()
    if Search._filterQueued then return end
    Search._filterQueued = true
    local fire = function()
        Search._filterQueued = false
        if ns.SafeCall then ns:SafeCall(Search.Filter) else Search.Filter() end
    end
    if _G.C_Timer and _G.C_Timer.After then _G.C_Timer.After(0, fire) else fire() end
end

-- Called by the search box on every text change. Recompiles + re-filters.
function Search.SetQuery(text)
    Search._query = Search.Compile(text or "")
    Search.RequestFilter()
end

function Search.CurrentText() return Search._queryText or "" end

-- Re-apply the active query after a window rebuild repainted the buttons (the
-- frame calls this at the end of Rebuild). No-op when no query is active.
function Search.Reapply()
    if Search._query and not Search._query.isEmpty then Search.RequestFilter() end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "search")
----------------------------------------------------------------------

-- A fake resolver factory: instant/info tables keyed by itemID.
local function fakeResolver(db)
    return {
        instant = function(id)
            local e = db[id]; if not e then return nil end
            return id, e.itype, e.isub, e.equip, e.icon or 1, e.classID, e.subClassID
        end,
        info = function(id)
            local e = db[id]; if not e then return nil end
            -- name/quality are async: nil until `cached` is set on the fixture entry.
            if not e.cached then return nil end
            return e.name, "item:" .. id, e.quality
        end,
        -- Mirrors the live armorySets resolver: lowercased set names for an id, or nil
        -- (fixture entry `sets` is an array of names; absent => nil = Armory-absent path).
        sets = function(id)
            local e = db[id]; if not (e and e.sets) then return nil end
            local low = {}
            for i = 1, #e.sets do low[i] = tostring(e.sets[i]):lower() end
            return low
        end,
    }
end

local function testTokenize(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local t = Search.Tokenize("healing q:epic t:weapon slot:head")
    ck(#t == 4, "four terms parsed")
    ck(t[1].kind == "name" and t[1].text == "healing", "bare -> name term")
    ck(t[2].kind == "quality" and t[2].op == "==" and t[2].value == 4, "q:epic -> quality == 4")
    ck(t[3].kind == "type" and t[3].text == "weapon", "t:weapon -> type term")
    ck(t[4].kind == "slot" and t[4].text == "head", "slot:head -> slot term")
    -- two bare words = two AND-ed name terms; case-insensitive
    local t2 = Search.Tokenize("Greater HEALING")
    ck(#t2 == 2 and t2[1].text == "greater" and t2[2].text == "healing", "two bare words -> two lower name terms")
    -- numeric + operator qualities
    ck(Search.Tokenize("q:4")[1].value == 4, "q:4 numeric")
    ck(Search.Tokenize("q:>=3")[1].op == ">=", "q:>=3 op parsed")
    ck(Search.Tokenize("q:<2")[1].op == "<", "q:<2 op parsed")
    -- empty-value / junk prefixes are dropped
    ck(#Search.Tokenize("t: q:") == 0, "empty-value prefix tokens dropped")
    ck(#Search.Tokenize("") == 0, "empty query -> no terms")
    -- set: membership term — bare form is KEPT (means "any set"), named form carries a fragment
    local ts = Search.Tokenize("set:tank")
    ck(#ts == 1 and ts[1].kind == "set" and ts[1].text == "tank", "set:tank -> set term")
    local tb = Search.Tokenize("set:")
    ck(#tb == 1 and tb[1].kind == "set" and tb[1].text == "", "bare set: kept as any-set term")
end

local function testParseQuality(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local op, v = Search.ParseQuality("epic");  ck(op == "==" and v == 4, "epic -> ==4")
    op, v = Search.ParseQuality("4");            ck(op == "==" and v == 4, "4 -> ==4")
    op, v = Search.ParseQuality(">=3");          ck(op == ">=" and v == 3, ">=3")
    op, v = Search.ParseQuality(">2");           ck(op == ">"  and v == 2, ">2")
    op, v = Search.ParseQuality("<=1");          ck(op == "<=" and v == 1, "<=1")
    op, v = Search.ParseQuality("=5");           ck(op == "==" and v == 5, "=5")
    op, v = Search.ParseQuality("uncommon");     ck(op == "==" and v == 2, "uncommon -> 2")
    ck(Search.ParseQuality("banana") == nil, "unknown name -> nil")
end

local function testMatchMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- fixture item catalog
    local db = {
        [1] = { name = "Greater Healing Potion", quality = 1, itype = "Consumable", isub = "Potion", equip = "", cached = true },
        [2] = { name = "Arcanite Reaper",        quality = 4, itype = "Weapon", isub = "Two-Handed Axes", equip = "INVTYPE_2HWEAPON", cached = true },
        [3] = { name = "Helm of the Lifegiver",  quality = 3, itype = "Armor", isub = "Plate", equip = "INVTYPE_HEAD", cached = true },
        -- captured-quality-only item: quality on the record, name still uncached.
        [4] = { itype = "Weapon", isub = "Swords", equip = "INVTYPE_WEAPONMAINHAND", cached = false },
    }
    local R = fakeResolver(db)
    local function rec(id, q) return { id = id, count = 1, quality = q } end
    local function matched(query, id, q)
        local m = Search.Compile(query):Match(rec(id, q), R); return m
    end
    -- bare name substring, case-insensitive
    ck(matched("healing", 1) == true, "bare 'healing' matches potion")
    ck(matched("HEALING", 1) == true, "case-insensitive name")
    ck(matched("reaper", 1) == false, "'reaper' does not match potion")
    -- AND of two bare words
    ck(matched("greater potion", 1) == true, "both words present -> match")
    ck(matched("greater reaper", 1) == false, "one word absent -> AND fails")
    -- quality name + number + comparators
    ck(matched("q:epic", 2) == true, "q:epic matches epic weapon")
    ck(matched("q:4", 2) == true, "q:4 matches epic")
    ck(matched("q:epic", 3) == false, "q:epic rejects rare")
    ck(matched("q:>=3", 3) == true, "q:>=3 matches rare")
    ck(matched("q:>=3", 1) == false, "q:>=3 rejects common")
    ck(matched("q:<2", 1) == true, "q:<2 matches common")
    -- type / subtype substring (synchronous, no cache needed)
    ck(matched("t:weapon", 2) == true, "t:weapon matches itemType")
    ck(matched("t:axe", 2) == true, "t:axe matches subtype substring")
    ck(matched("t:armor", 2) == false, "t:armor rejects weapon")
    -- slot substring
    ck(matched("slot:head", 3) == true, "slot:head matches head armor")
    ck(matched("slot:head", 2) == false, "slot:head rejects 2h weapon")
    ck(matched("slot:mainhand", 4, 3) == true, "slot:mainhand matches weaponmainhand")
    ck(matched("slot:head", 1) == false, "non-equippable never matches a slot term")
    -- combined AND across kinds
    ck(matched("q:epic t:weapon", 2) == true, "epic AND weapon -> match")
    ck(matched("q:epic t:armor", 2) == false, "epic AND armor -> fail (type)")

    -- pending: item 4 name uncached, but its quality is captured on the record.
    -- A t:/slot: query resolves synchronously; a name query is pending.
    local mT, pT = Search.Compile("t:sword"):Match(rec(4, 3), R)
    ck(mT == true and pT == false, "t: on uncached item resolves via instant (not pending)")
    local mQ, pQ = Search.Compile("q:rare"):Match(rec(4, 3), R)
    ck(mQ == true and pQ == false, "q: uses captured record quality (not pending)")
    local mN, pN = Search.Compile("sword"):Match(rec(4, 3), R)
    ck(mN == false and pN == true, "name term on uncached item -> pending")
    -- but a hard type miss beats a pending name term (no point waiting)
    local mMix, pMix = Search.Compile("sword t:armor"):Match(rec(4, 3), R)
    ck(mMix == false and pMix == false, "definitive type miss short-circuits the pending name")

    -- empty query matches everything, never pending
    local me, pe = Search.Compile(""):Match(rec(1), R)
    ck(me == true and pe == false, "empty query matches all")
    ck(Search.Compile("x"):Match(nil, R) == false, "nil record -> no match")
end

-- set: membership matching (Daseeki-Armory integration, audit §2.8).
local function testSetMatcher(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = {
        [1] = { name = "Tank Shield", quality = 3, itype = "Armor", isub = "Shields",
                equip = "INVTYPE_SHIELD", cached = true, sets = { "Tank Wall", "PvP" } },
        [2] = { name = "DPS Sword",   quality = 3, itype = "Weapon", isub = "Swords",
                equip = "INVTYPE_WEAPONMAINHAND", cached = true, sets = { "Raid DPS" } },
        [3] = { name = "Junk Cloth",  quality = 1, itype = "Armor", isub = "Cloth",
                equip = "INVTYPE_CHEST", cached = true },   -- belongs to NO set (no `sets`)
    }
    local R = fakeResolver(db)
    local function rec(id, q) return { id = id, count = 1, quality = q } end
    local function matched(query, id, q) return (Search.Compile(query):Match(rec(id, q), R)) end

    -- bare set: = belongs to ANY equipment set
    ck(matched("set:", 1) == true,  "bare set: matches an item in a set")
    ck(matched("set:", 2) == true,  "bare set: matches a second set member")
    ck(matched("set:", 3) == false, "bare set: rejects an item in no set")
    -- named set: matches on a case-insensitive name fragment
    ck(matched("set:tank", 1) == true,  "set:tank matches 'Tank Wall'")
    ck(matched("set:pvp", 1) == true,   "set:pvp matches the second set on the item")
    ck(matched("set:raid", 2) == true,  "set:raid matches 'Raid DPS'")
    ck(matched("set:tank", 2) == false, "set:tank rejects a non-tank item")
    ck(matched("set:tank", 3) == false, "set:tank rejects an item in no set")
    -- AND with other kinds
    ck(matched("set:tank t:armor", 1) == true,  "set AND type -> match")
    ck(matched("set:tank t:weapon", 1) == false, "set AND wrong type -> fail")
    -- Armory-absent path: a resolver with NO sets fn => set: is a definitive, non-pending miss
    local noSets = { instant = R.instant, info = R.info }   -- no .sets
    local m, p = Search.Compile("set:"):Match(rec(1), noSets)
    ck(m == false and p == false, "Armory absent -> set: is inert (miss, not pending)")
    local m2, p2 = Search.Compile("set:tank"):Match(rec(1), noSets)
    ck(m2 == false and p2 == false, "Armory absent -> named set: inert too")
end

----------------------------------------------------------------------
-- CLASS 9 — the LIVE filter chain under synchronous in-call dispatch (2026-08-11)
--
-- Search.Filter walks every live button, and for each one it cannot judge it puts the id
-- on the watch and asks the client for the data. The client does not always SCHEDULE the
-- answer: for an id it already holds, GET_ITEM_INFO_RECEIVED is dispatched from INSIDE
-- RequestLoadItemDataByID, so the pass's FIRST ask is also its first echo. Whether that
-- echo is heard depends entirely on whether the listener existed before it.
--
-- The client double below defaults to the UNKIND posture (answer in the call) with the
-- old one kept as a named variant, and the suite runs the same pass both ways plus a red
-- control that rebuilds the shipped ordering exactly.
----------------------------------------------------------------------
local function testLiveFilterInCall(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local savedFrame, savedCI, savedCF = ns.Frame, _G.C_Item, _G.CreateFrame
    local savedWatch, savedEvt, savedQ = Search._watch, Search._evt, Search._query
    local savedQueued, savedTimer = Search._filterQueued, _G.C_Timer

    local CAT = { [11] = { name = "Frostweave", quality = 2, itype = "Trade Goods" },
                  [12] = { name = "Frostmourne", quality = 5, itype = "Weapon" } }

    -- `dispatch` is the posture; `instantWarm` is "the client already holds this id".
    -- `deaf` is the RED CONTROL knob: the number of listeners that existed when the pass
    -- started. While it is set, an in-call echo reaches only those — which is precisely
    -- what "the watch frame is built AFTER the asks" means, with no need to break
    -- CreateFrame and no edit to the file under test.
    local dispatch, warm, asks, frames, dimmed, passes, deaf
    local function fire(id)
        local last = deaf or #frames
        for i = 1, last do
            local f = frames[i]
            if f and f._events["GET_ITEM_INFO_RECEIVED"] and f._onEvent then
                f._onEvent(f, "GET_ITEM_INFO_RECEIVED", id)
            end
        end
    end
    local function world()
        warm, asks, frames, dimmed, passes, deaf = {}, {}, {}, {}, 0, nil
        _G.C_Item = {
            GetItemInfoInstant = function(id)
                local e = CAT[id]; if not e then return nil end
                return id, e.itype, e.itype, "", 7000 + id
            end,
            GetItemInfo = function(id)
                local e = CAT[id]
                if not (e and warm[id]) then return nil end
                return e.name, "item:" .. id, e.quality
            end,
            RequestLoadItemDataByID = function(id)
                asks[id] = (asks[id] or 0) + 1
                if dispatch == "sync" then warm[id] = true; fire(id) end
            end,
        }
        _G.CreateFrame = function()
            local f = { _events = {} }
            function f:RegisterEvent(e) self._events[e] = true end
            function f:SetScript(which, fn) if which == "OnEvent" then self._onEvent = fn end end
            frames[#frames + 1] = f
            return f
        end
        -- Deferrals run inline here: this suite is about ORDERING inside one call, and the
        -- debounce is not what is under test.
        _G.C_Timer = { After = function(_, fn) fn() end }
        ns.Frame = { ForEachButton = function(fn)
            passes = passes + 1
            for _, id in ipairs({ 11, 12 }) do
                fn({ _data = { id = id, count = 1, quality = CAT[id].quality },
                     SetDimmed = function(_, v) dimmed[id] = v end })
            end
        end }
        Search._watch, Search._evt, Search._filterQueued = {}, nil, false
        Search._query = Search.Compile("frostmourne")
    end
    local function watchLeft()
        local n = 0
        for _ in pairs(Search._watch) do n = n + 1 end
        return n
    end

    ------------------------------------------------------------------ GREEN (as shipped)
    dispatch = "sync"; world()
    Search.Filter()
    ck(asks[11] == 1 and asks[12] == 1, "both cold ids were asked for exactly once")
    ck(#frames == 1, "…and ONE listener was built for the answers")
    ck(watchLeft() == 0,
        "GREEN: every in-call answer landed — the watch emptied inside Filter itself (left "
        .. watchLeft() .. ")")
    ck(passes >= 2, "…and the answers re-filtered the grid without further input ("
        .. passes .. " passes)")
    ck(dimmed[12] == false and dimmed[11] == true,
        "…so the matching item ends UNDIMMED and the other dimmed (the visible outcome)")

    ------------------------------------------------------------------ RED CONTROL
    -- The shipped ordering, reproduced: no listener exists while the asks go out.
    dispatch = "sync"; world()
    deaf = 0                                          -- nothing was listening beforehand
    local okRed = pcall(Search.Filter)
    deaf = nil
    ck(okRed, "the red-control pass ran")
    ck(watchLeft() == 2,
        "RED CONTROL: with no listener up when the asks go out, both in-call answers are "
        .. "delivered to nothing and both ids stay on the watch (left " .. watchLeft() .. ")")
    ck(passes == 1, "…the grid is never re-filtered: one pass, and the dim state is the "
        .. "cold one (" .. passes .. " pass)")
    ck(dimmed[12] == true,
        "…so the item the owner searched for stays DIMMED even though the client answered "
        .. "for it inside the very call that asked")

    ------------------------------------------------------------------ THE BLIND SPOT
    -- Same late-listener sequence, async delivery: nothing arrives in the call, the frame
    -- is built afterwards, and the later answer is caught. This posture cannot see it.
    dispatch = "async"; world()
    deaf = 0
    Search.Filter()
    deaf = nil
    ck(watchLeft() == 2, "async premise: nothing answered in the call")
    warm[11], warm[12] = true, true
    fire(11); fire(12)                                -- the answers arrive later, as before
    ck(dimmed[12] == false,
        "…and under async the answer still lands: a sim that delivers after the call "
        .. "returns can never see this defect")

    ns.Frame, _G.C_Item, _G.CreateFrame = savedFrame, savedCI, savedCF
    _G.C_Timer = savedTimer
    Search._watch, Search._evt, Search._query = savedWatch, savedEvt, savedQ
    Search._filterQueued = savedQueued
end

function Search.RunSelfTests(verbose)
    local suites = {
        { name = "tokenize",       fn = testTokenize },
        { name = "parse quality",  fn = testParseQuality },
        { name = "match matrix",   fn = testMatchMatrix },
        { name = "set matcher",    fn = testSetMatcher },
        { name = "class 9: live filter in-call answers", fn = testLiveFilterInCall },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS search/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL search/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("search", Search.RunSelfTests)
end

return Search
