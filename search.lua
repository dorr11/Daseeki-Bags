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

-- Injected-live resolver from the game globals (identical path to ui_items).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
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
            if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
                _G.C_Item.RequestLoadItemDataByID(data.id)
            end
        end
    end)
    if next(Search._watch) then ensureEventFrame() end
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

function Search.RunSelfTests(verbose)
    local suites = {
        { name = "tokenize",       fn = testTokenize },
        { name = "parse quality",  fn = testParseQuality },
        { name = "match matrix",   fn = testMatchMatrix },
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
