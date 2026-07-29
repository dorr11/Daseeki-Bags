-- Daseeki Bags 2.0 — rules2.lua
-- The SIMPLIFIED custom-categories engine (BAGS2_PARITY_AUDIT §6.4-6.5, GAP #2 —
-- a D1-KEEP promise: "custom categories/rules (simplified)"). NOT 1.x's full
-- macro/rule engine — a category is literally a saved SEARCH QUERY, reusing the
-- search.lua matcher grammar wholesale. Two cleanly separated layers, mirroring
-- store/search:
--
--   PURE core (no WoW API; the harness unit-tests the whole model):
--     Rules.CompileCategory(query)   — query string -> compiled { :Match(rec,res,ctx) }
--     Rules.CompileList(cats)        — [{name,query,enabled}] -> compiled category list
--     Rules.BuildSections(entries, compiled, ctx) — entry list -> ordered sections
--     Rules.DefaultCategories()      — the seeded default list (fresh tables)
--     Rules.ApplyDefaults(db)        — additive DB defaults (feature ON, seed list)
--     list-edit ops: MoveUp / MoveDown / Add / Delete / Rename / SetQuery /
--                    SetEnabled / RestoreDefaults / CountMatches  (all pure)
--
--   LIVE glue (in-game only; guarded on _G):
--     Rules.SectionsForRender(entries) — reads the live DB, compiles, builds ctx
--                     with the live resolver + a pending-watch, returns sections.
--     GET_ITEM_INFO_RECEIVED watch     — re-paints when a pending item's data lands
--                     (identical shape to search.lua's re-filter).
--
-- ── Grammar (a superset of search.lua's, WITHOUT touching search.lua) ──────────
-- A category query is one string, evaluated as OR-of-clauses / AND-within-a-clause:
--   * commas split CLAUSES; a category matches if ANY clause matches (the only
--     OR in the model). This lets one "Equipment" category reproduce 1.x's
--     combined Armor+Weapon bin ("t:armor, t:weapon") that the AND-only search
--     grammar (D4) cannot express in a single clause.
--   * within a clause, everything is search.lua's grammar verbatim (name
--     substrings, q:/t:/slot: prefixes, quality names+numbers+comparators — all
--     AND-ed), PLUS two barewords search does not special-case:
--       "junk" — quality == 0 (poor / vendor trash)
--       "new"  — recently-acquired items (via an injected isNew provider; grammar-
--                ready but INERT until the new-item GAP §2.4 ships a provider —
--                so no default category depends on it).
-- Empty query (blank) matches everything (a match-all clause); the engine never
-- seeds one — the "Everything else" remainder is synthesized automatically.
--
-- ── Sections model ────────────────────────────────────────────────────────────
-- BuildSections walks the SAME combined entry list ui_frame builds (per-container
-- identity preserved on every entry — D3 law), and buckets each OCCUPIED slot into
-- the first ENABLED category whose query matches (first-match-wins, top-down).
-- Unmatched occupied slots fall into a synthesized "Everything else" terminal
-- section (always last of the occupied sections, guarantees NO item is ever
-- hidden even if the user deletes every category). Empty slots collect into an
-- optional trailing "Free space" section (drop-target cells) so native drag-to-
-- place still works in category mode. Empty sections collapse (are omitted).
-- Section order = category order.

local ADDON, ns = ...

local Rules = {}
ns.Rules = Rules

local Store  = ns.Store
local Search = ns.Search   -- may be nil at file-scope depending on load order; re-read live

-- Section keys for the two synthesized terminal buckets.
Rules.ELSE_KEY = "__else__"
Rules.FREE_KEY = "__free__"
Rules.ELSE_NAME = "Everything else"
Rules.FREE_NAME = "Free space"

----------------------------------------------------------------------
-- Default categories (design: sensible, editable/deletable seed list).
--
-- Order is priority (first-match-wins): Junk first so poor-quality gear lands in
-- Junk rather than masquerading as equipment; the rest in a natural reading order.
-- "Equipment" uses the comma-OR to reproduce 1.x's combined Armor+Weapon bin.
-- "Everything else" is NOT seeded — it is the automatic terminal remainder.
----------------------------------------------------------------------

function Rules.DefaultCategories()
    return {
        { name = "Junk",        query = "junk",         enabled = true },
        { name = "Consumables", query = "t:consumable", enabled = true },
        { name = "Trade Goods", query = "t:trade",      enabled = true },
        { name = "Quest",       query = "t:quest",      enabled = true },
        { name = "Equipment",   query = "t:armor, t:weapon", enabled = true },
    }
end

----------------------------------------------------------------------
-- Additive DB defaults (Core-independent; applied on STORE_READY).
--   db.categoriesEnabled — master feature toggle, default ON (design point 2).
--   db.categories        — the ordered editable list, seeded on first run only
--                          (an empty list is a valid user choice, never re-seeded).
----------------------------------------------------------------------

function Rules.ApplyDefaults(db)
    if type(db) ~= "table" then return end
    if db.categoriesEnabled == nil then db.categoriesEnabled = true end
    if db.categories == nil then db.categories = Rules.DefaultCategories() end
    return db
end

-- Master toggle read (absent => ON, matching ApplyDefaults).
function Rules.Enabled(db)
    if type(db) ~= "table" then return true end
    return db.categoriesEnabled ~= false
end

----------------------------------------------------------------------
-- PURE: compile one category query into a matcher.
--   compiled.isEmpty                  — blank query (matches everything)
--   compiled:Match(record, res, ctx)  — matched(bool), pending(bool)
--   compiled.clauses                  — parsed clause list (introspection/tests)
----------------------------------------------------------------------

-- Split a clause's tokens into { junk=bool, new=bool } specials and a residual
-- search subquery string (everything search.lua already understands).
local function splitSpecials(clauseStr)
    local specials = {}
    local rest = {}
    for tok in clauseStr:gmatch("%S+") do
        local low = tok:lower()
        if low == "junk" then specials.junk = true
        elseif low == "new" then specials.new = true
        else rest[#rest + 1] = tok end
    end
    return specials, table.concat(rest, " ")
end

-- Resolve an item's quality: the captured per-slot quality first (synchronous for
-- live self items — capture stores it), else the async GetItemInfo quality.
-- Returns quality(number) or nil (nil => not yet resolved => pending).
local function resolveQuality(record, resolver)
    if record and record.quality ~= nil then return record.quality end
    if resolver and resolver.info and record and record.id then
        local _, _, q = resolver.info(record.id)
        return q
    end
    return nil
end

function Rules.CompileCategory(query)
    query = type(query) == "string" and query or ""
    local S = ns.Search or Search
    local clauses = {}
    local anyContent = false
    for clauseStr in (query .. ","):gmatch("([^,]*),") do
        local specials, rest = splitSpecials(clauseStr)
        local sub = S and S.Compile(rest) or { isEmpty = true, Match = function() return true, false end }
        local hasContent = specials.junk or specials.new or (not sub.isEmpty)
        if hasContent then anyContent = true end
        clauses[#clauses + 1] = { specials = specials, sub = sub, isEmpty = not hasContent }
    end
    if #clauses == 0 then clauses[1] = { specials = {}, sub = { isEmpty = true }, isEmpty = true } end

    local compiled = { raw = query, clauses = clauses, isEmpty = not anyContent }

    -- Evaluate ONE clause: specials AND search-subquery. Returns matched, pending.
    local function matchClause(clause, record, resolver, ctx)
        if clause.isEmpty then return true, false end   -- blank clause => matches all
        local pending = false
        if clause.specials.junk then
            local q = resolveQuality(record, resolver)
            if q == nil then pending = true
            elseif q ~= 0 then return false, false end
        end
        if clause.specials.new then
            local isNew = ctx and ctx.isNew and ctx.isNew(record)
            if not isNew then return false, false end     -- "new" is synchronous
        end
        if clause.sub and not clause.sub.isEmpty then
            local m, p = clause.sub:Match(record, resolver)
            if p then pending = true
            elseif not m then return false, false end
        end
        if pending then return false, true end
        return true, false
    end

    -- OR across clauses: a hard match on ANY clause wins; else pending if any
    -- clause is still pending; else a definitive miss.
    function compiled:Match(record, resolver, ctx)
        if self.isEmpty then return true, false end
        if not record or not record.id then return false, false end
        local pending = false
        for i = 1, #self.clauses do
            local m, p = matchClause(self.clauses[i], record, resolver, ctx)
            if m then return true, false end
            if p then pending = true end
        end
        if pending then return false, true end
        return false, false
    end

    return compiled
end

----------------------------------------------------------------------
-- PURE: compile a whole category list. Skips malformed rows defensively.
--   returns [{ name, key, enabled, q = compiledCategory }]
----------------------------------------------------------------------

function Rules.CompileList(cats)
    local out = {}
    if type(cats) ~= "table" then return out end
    for i = 1, #cats do
        local c = cats[i]
        if type(c) == "table" then
            out[#out + 1] = {
                name    = c.name or ("Category " .. i),
                key     = "cat" .. i,
                enabled = c.enabled ~= false,
                q       = Rules.CompileCategory(c.query or ""),
            }
        end
    end
    return out
end

----------------------------------------------------------------------
-- PURE: bucket a combined entry list into ordered sections.
--   entries  = { { owner, cid, slot, data|nil }, ... }  (ui_frame's combined list)
--   compiled = Rules.CompileList(...) output
--   ctx      = { resolver = {instant,info}, isNew = fn, watch = {}|nil,
--               includeFree = bool (default true), elseName, freeName }
-- Returns ordered sections { { name, key, entries = {...}, count } }, empties
-- omitted (collapse). Section order = category order, then Everything else, then
-- Free space. Pending item ids (data needed but not yet cached) are recorded in
-- ctx.watch when supplied.
----------------------------------------------------------------------

function Rules.BuildSections(entries, compiled, ctx)
    ctx = ctx or {}
    local resolver    = ctx.resolver
    local includeFree = ctx.includeFree ~= false
    local watch       = ctx.watch
    local buckets = {}                 -- key -> entries array
    local function bucket(key)
        local b = buckets[key]
        if not b then b = {}; buckets[key] = b end
        return b
    end

    for i = 1, #entries do
        local e = entries[i]
        if not e.data then
            if includeFree then bucket(Rules.FREE_KEY)[#bucket(Rules.FREE_KEY) + 1] = e end
        else
            local placed = false
            local sawPending = false
            for c = 1, #compiled do
                local cat = compiled[c]
                if cat.enabled then
                    local m, p = cat.q:Match(e.data, resolver, ctx)
                    if m then
                        local b = bucket(cat.key); b[#b + 1] = e
                        placed = true
                        break
                    elseif p then
                        sawPending = true
                    end
                end
            end
            if not placed then
                local b = bucket(Rules.ELSE_KEY); b[#b + 1] = e
                if sawPending and watch and e.data.id then watch[e.data.id] = true end
            end
        end
    end

    -- Emit in category order, then the two terminal buckets. Empty => collapsed.
    local sections = {}
    for c = 1, #compiled do
        local cat = compiled[c]
        if cat.enabled then
            local b = buckets[cat.key]
            if b and #b > 0 then
                sections[#sections + 1] = { name = cat.name, key = cat.key, entries = b, count = #b }
            end
        end
    end
    local elseB = buckets[Rules.ELSE_KEY]
    if elseB and #elseB > 0 then
        sections[#sections + 1] = { name = ctx.elseName or Rules.ELSE_NAME, key = Rules.ELSE_KEY, entries = elseB, count = #elseB }
    end
    local freeB = buckets[Rules.FREE_KEY]
    if includeFree and freeB and #freeB > 0 then
        sections[#sections + 1] = { name = ctx.freeName or Rules.FREE_NAME, key = Rules.FREE_KEY, entries = freeB, count = #freeB }
    end
    return sections
end

----------------------------------------------------------------------
-- PURE: live "matches N items" count for the editor (occupied entries only).
----------------------------------------------------------------------

function Rules.CountMatches(compiledCat, entries, ctx)
    ctx = ctx or {}
    local n = 0
    for i = 1, #entries do
        local e = entries[i]
        if e.data then
            local m = compiledCat:Match(e.data, ctx.resolver, ctx)
            if m then n = n + 1 end
        end
    end
    return n
end

----------------------------------------------------------------------
-- PURE: list-edit operations (the editor's logic, unit-tested headless).
-- All mutate the array in place and return a small result the editor uses to
-- keep its selection/undo sane. Bounds are clamped (no error on edge ops).
----------------------------------------------------------------------

local function validIndex(list, i)
    return type(list) == "table" and type(i) == "number" and i >= 1 and i <= #list
end

-- Swap i with i-1. Returns the moved item's NEW index (== i when it couldn't move).
function Rules.MoveUp(list, i)
    if not validIndex(list, i) or i == 1 then return i end
    list[i], list[i - 1] = list[i - 1], list[i]
    return i - 1
end

-- Swap i with i+1. Returns the moved item's NEW index (== i when it couldn't move).
function Rules.MoveDown(list, i)
    if not validIndex(list, i) or i == #list then return i end
    list[i], list[i + 1] = list[i + 1], list[i]
    return i + 1
end

-- Append a new category. Returns the new record and its index.
function Rules.Add(list, name, query)
    if type(list) ~= "table" then return nil end
    local c = { name = name or "New Category", query = query or "", enabled = true }
    list[#list + 1] = c
    return c, #list
end

-- Remove index i. Returns the removed record (or nil).
function Rules.Delete(list, i)
    if not validIndex(list, i) then return nil end
    return table.remove(list, i)
end

function Rules.Rename(list, i, name)
    if not validIndex(list, i) then return false end
    list[i].name = name or list[i].name
    return true
end

function Rules.SetQuery(list, i, query)
    if not validIndex(list, i) then return false end
    list[i].query = query or ""
    return true
end

function Rules.SetEnabled(list, i, on)
    if not validIndex(list, i) then return false end
    list[i].enabled = on and true or false
    return true
end

-- Reset the DB's category list back to the shipped defaults. Returns the list.
function Rules.RestoreDefaults(db)
    if type(db) ~= "table" then return nil end
    db.categories = Rules.DefaultCategories()
    db.categoriesEnabled = true
    return db.categories
end

-- =====================================================================
-- LIVE glue (in-game only)
-- =====================================================================

-- Injected-live resolver from the game globals (identical path to ui_items/search).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
    }
end

-- Optional "new item" provider hook — inert until §2.4 ships one (ns.NewItems).
local function liveIsNew(record)
    if ns.NewItems and ns.NewItems.IsNew then return ns.NewItems.IsNew(record) and true or false end
    return false
end

Rules._watch = Rules._watch or {}     -- [itemID] = true (categorization-pending items)

local function ensureEventFrame()
    if Rules._evt or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(_, _, itemID)
        if Rules._watch[itemID] then
            Rules._watch[itemID] = nil
            if ns.Frame and ns.Frame.RequestRefresh then ns.Frame.RequestRefresh() end
            if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then _G.C_Item.RequestLoadItemDataByID(itemID) end
        end
    end)
    Rules._evt = f
end

-- Live entrypoint the frame calls: read the DB, compile, bucket the given combined
-- entry list into render sections, arming the pending re-paint. `includeFree`
-- defaults true (drop-target cells for native placement).
function Rules.SectionsForRender(entries, includeFree)
    local db = Store and Store.db
    local cats = (db and db.categories) or Rules.DefaultCategories()
    local compiled = Rules.CompileList(cats)
    Rules._watch = {}
    local ctx = {
        resolver    = liveResolver(),
        isNew       = liveIsNew,
        watch       = Rules._watch,
        includeFree = includeFree ~= false,
    }
    local sections = Rules.BuildSections(entries, compiled, ctx)
    if next(Rules._watch) then
        ensureEventFrame()
        if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
            for id in pairs(Rules._watch) do _G.C_Item.RequestLoadItemDataByID(id) end
        end
    end
    return sections
end

-- Live wrapper for the editor's "matches N" count against the viewed owner's bags.
function Rules.LiveCountMatches(query, entries)
    local compiled = Rules.CompileCategory(query)
    return Rules.CountMatches(compiled, entries, { resolver = liveResolver(), isNew = liveIsNew })
end

-- Apply defaults the moment the store is ready (Core-independent), like options.lua.
if ns.On then
    ns:On("STORE_READY", function()
        Rules.ApplyDefaults(Store and Store.db)
    end)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "rules2")
----------------------------------------------------------------------

-- Fake resolver factory (same shape search.lua's tests use).
local function fakeResolver(db)
    return {
        instant = function(id)
            local e = db[id]; if not e then return nil end
            return id, e.itype, e.isub, e.equip, e.icon or 1, e.classID, e.subClassID
        end,
        info = function(id)
            local e = db[id]; if not e then return nil end
            if not e.cached then return nil end
            return e.name, "item:" .. id, e.quality
        end,
    }
end

-- Item catalog shared by the matcher + section tests.
local function catalogDB()
    return {
        [1] = { name = "Greater Healing Potion", quality = 1, itype = "Consumable", isub = "Potion", equip = "", cached = true },
        [2] = { name = "Arcanite Reaper",        quality = 4, itype = "Weapon", isub = "Two-Handed Axes", equip = "INVTYPE_2HWEAPON", cached = true },
        [3] = { name = "Helm of the Lifegiver",  quality = 3, itype = "Armor", isub = "Plate", equip = "INVTYPE_HEAD", cached = true },
        [4] = { name = "Broken Fang",            quality = 0, itype = "Miscellaneous", isub = "Junk", equip = "", cached = true },
        [5] = { name = "Copper Bar",             quality = 1, itype = "Trade Goods", isub = "Metal & Stone", equip = "", cached = true },
        [6] = { name = "Chipped Bear Tooth",     quality = 1, itype = "Quest", isub = "Quest", equip = "", cached = true },
        -- uncached-name gray sword: quality captured on the record, name still async.
        [7] = { itype = "Weapon", isub = "Swords", equip = "INVTYPE_WEAPONMAINHAND", cached = false },
    }
end

local function rec(id, q) return { id = id, count = 1, quality = q } end

local function testCompileAndMatch(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local R = fakeResolver(catalogDB())
    local function matched(query, id, q)
        return (Rules.CompileCategory(query)):Match(rec(id, q), R)
    end
    -- reuse of the search grammar (delegated) --------------------------------
    ck(matched("t:consumable", 1) == true,  "t:consumable matches potion (search grammar)")
    ck(matched("t:weapon", 2) == true,       "t:weapon matches axe")
    ck(matched("t:armor", 2) == false,       "t:armor rejects weapon")
    ck(matched("q:>=3", 3) == true,          "q:>=3 comparator delegated to search")
    ck(matched("healing", 1) == true,        "bare name substring delegated to search")
    -- specials ---------------------------------------------------------------
    ck(matched("junk", 4) == true,           "junk special matches quality-0 item")
    ck(matched("junk", 1) == false,          "junk special rejects common item")
    -- 'junk' is a special, NOT a name substring (item 4 name has no 'junk' word,
    -- yet it matches on quality; a common item never matches even if named 'junk')
    ck(matched("junk", 3) == false,          "junk rejects a rare helm")
    -- 'new' special is inert without a provider (ctx.isNew false) -> never matches
    ck(matched("new", 2) == false,           "new special inert without provider")
    -- and honours an injected provider
    local mNew = (Rules.CompileCategory("new")):Match(rec(2, 4), R, { isNew = function() return true end })
    ck(mNew == true, "new special matches when isNew provider returns true")
    -- comma = OR across clauses ---------------------------------------------
    ck(matched("t:armor, t:weapon", 2) == true, "OR clause: weapon matches equipment")
    ck(matched("t:armor, t:weapon", 3) == true, "OR clause: armor matches equipment")
    ck(matched("t:armor, t:weapon", 1) == false, "OR clause: potion is neither")
    -- AND still holds WITHIN a clause
    ck(matched("q:epic t:weapon", 2) == true,  "AND within clause: epic weapon")
    ck(matched("q:epic t:weapon", 3) == false, "AND within clause: rare helm fails epic")
    -- empty query matches everything
    ck(matched("", 1) == true,  "empty query matches all")
    ck(Rules.CompileCategory("").isEmpty == true, "empty query compiles isEmpty")
    ck(Rules.CompileCategory("t:weapon").isEmpty == false, "non-empty query not isEmpty")
    -- pending: gray sword name uncached, but junk uses captured quality (sync)
    local mJ, pJ = (Rules.CompileCategory("junk")):Match(rec(7, 0), R)
    ck(mJ == true and pJ == false, "junk uses captured record quality (not pending)")
    local mN, pN = (Rules.CompileCategory("sword")):Match(rec(7, 0), R)
    ck(mN == false and pN == true, "name clause on uncached item -> pending")
end

local function testBuildSections(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local R = fakeResolver(catalogDB())
    -- a combined entry list across two containers, incl. empty slots. cid preserved.
    local entries = {
        { owner = {}, cid = 0, slot = 1, data = rec(1, 1) },   -- potion   -> Consumables
        { owner = {}, cid = 0, slot = 2, data = nil          }, -- empty    -> Free space
        { owner = {}, cid = 0, slot = 3, data = rec(2, 4) },   -- axe      -> Equipment
        { owner = {}, cid = 1, slot = 1, data = rec(3, 3) },   -- helm     -> Equipment
        { owner = {}, cid = 1, slot = 2, data = rec(4, 0) },   -- junk     -> Junk
        { owner = {}, cid = 1, slot = 3, data = rec(5, 1) },   -- copper   -> Trade Goods
        { owner = {}, cid = 1, slot = 4, data = nil          }, -- empty    -> Free space
        { owner = {}, cid = 1, slot = 5, data = rec(99, 1) },  -- unknown  -> Everything else
    }
    local compiled = Rules.CompileList(Rules.DefaultCategories())
    local sections = Rules.BuildSections(entries, compiled, { resolver = R })

    -- default order: Junk, Consumables, Trade Goods, Quest(empty->collapsed),
    -- Equipment, then Everything else, then Free space. Quest collapses.
    local byName = {}
    for i, s in ipairs(sections) do byName[s.name] = { idx = i, count = s.count } end
    ck(byName["Junk"] and byName["Junk"].count == 1, "Junk section has the gray item")
    ck(byName["Consumables"] and byName["Consumables"].count == 1, "Consumables has the potion")
    ck(byName["Trade Goods"] and byName["Trade Goods"].count == 1, "Trade Goods has the copper bar")
    ck(byName["Quest"] == nil, "empty Quest section collapsed (omitted)")
    ck(byName["Equipment"] and byName["Equipment"].count == 2, "Equipment (OR) caught axe + helm")
    ck(byName["Everything else"] and byName["Everything else"].count == 1, "unknown item -> Everything else")
    ck(byName["Free space"] and byName["Free space"].count == 2, "two empty slots -> Free space")

    -- Section ORDER == category order, terminals last.
    ck(byName["Junk"].idx < byName["Consumables"].idx, "Junk before Consumables (category order)")
    ck(byName["Consumables"].idx < byName["Trade Goods"].idx, "Consumables before Trade Goods")
    ck(byName["Trade Goods"].idx < byName["Equipment"].idx, "Trade Goods before Equipment (Quest collapsed between)")
    ck(byName["Everything else"].idx == #sections - 1, "Everything else is penultimate (before Free space)")
    ck(byName["Free space"].idx == #sections, "Free space is last")

    -- per-container identity survives categorization (mixed cids in one section)
    local eq = sections[byName["Equipment"].idx]
    local cids = {}
    for _, e in ipairs(eq.entries) do cids[e.cid] = true end
    ck(cids[0] and cids[1], "Equipment section carries entries from BOTH containers (cid preserved)")

    -- includeFree=false drops the Free space section (no empty cells)
    local noFree = Rules.BuildSections(entries, compiled, { resolver = R, includeFree = false })
    for _, s in ipairs(noFree) do ck(s.key ~= Rules.FREE_KEY, "includeFree=false omits Free space") end
end

local function testFirstMatchWins(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local R = fakeResolver(catalogDB())
    -- A gray (quality 0) WEAPON (item 7) — Junk is first, Equipment later. With the
    -- default order (Junk first) it must land in Junk, not Equipment.
    local entries = { { owner = {}, cid = 0, slot = 1, data = rec(7, 0) } }
    local compiled = Rules.CompileList(Rules.DefaultCategories())
    local sec = Rules.BuildSections(entries, compiled, { resolver = R })
    ck(#sec == 1 and sec[1].name == "Junk", "gray weapon -> Junk (first-match-wins, Junk precedes Equipment)")

    -- Flip the order: Equipment first, Junk later -> same item now lands in Equipment.
    local flipped = {
        { name = "Equipment", query = "t:armor, t:weapon", enabled = true },
        { name = "Junk",      query = "junk",              enabled = true },
    }
    local sec2 = Rules.BuildSections(entries, Rules.CompileList(flipped), { resolver = R })
    ck(#sec2 == 1 and sec2[1].name == "Equipment", "same item -> Equipment when Equipment ordered first")

    -- A DISABLED category is skipped entirely (item falls through to Everything else).
    local disabled = { { name = "Junk", query = "junk", enabled = false } }
    local sec3 = Rules.BuildSections(entries, Rules.CompileList(disabled), { resolver = R })
    ck(#sec3 == 1 and sec3[1].key == Rules.ELSE_KEY, "disabled category skipped -> Everything else")
end

local function testListOps(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local list = Rules.DefaultCategories()
    local n0 = #list
    ck(list[1].name == "Junk", "default[1] = Junk")
    -- MoveDown Junk -> index 2, and MoveUp brings it back
    ck(Rules.MoveDown(list, 1) == 2, "MoveDown returns new index 2")
    ck(list[2].name == "Junk", "Junk now at index 2")
    ck(list[1].name == "Consumables", "Consumables bubbled to 1")
    ck(Rules.MoveUp(list, 2) == 1, "MoveUp returns new index 1")
    ck(list[1].name == "Junk", "Junk restored to 1")
    -- edge clamps (no move, index unchanged)
    ck(Rules.MoveUp(list, 1) == 1, "MoveUp at top is a no-op")
    ck(Rules.MoveDown(list, #list) == #list, "MoveDown at bottom is a no-op")
    -- Add / Rename / SetQuery / SetEnabled / Delete
    local c, idx = Rules.Add(list, "Gems", "t:gem")
    ck(idx == n0 + 1 and c.name == "Gems" and c.query == "t:gem" and c.enabled == true, "Add appends enabled category")
    ck(Rules.Rename(list, idx, "Jewels") and list[idx].name == "Jewels", "Rename changes name")
    ck(Rules.SetQuery(list, idx, "t:gem, t:jewel") and list[idx].query == "t:gem, t:jewel", "SetQuery changes query")
    ck(Rules.SetEnabled(list, idx, false) and list[idx].enabled == false, "SetEnabled disables")
    local removed = Rules.Delete(list, idx)
    ck(removed and removed.name == "Jewels" and #list == n0, "Delete removes the added row")
    -- out-of-range guards
    ck(Rules.MoveUp(list, 99) == 99, "MoveUp out-of-range is a safe no-op")
    ck(Rules.Delete(list, 0) == nil, "Delete out-of-range returns nil")
    ck(Rules.Rename(list, 99, "x") == false, "Rename out-of-range returns false")
end

local function testDefaultsAndCount(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- ApplyDefaults is additive: feature ON + seeded list, never clobbering choices.
    local db = {}
    Rules.ApplyDefaults(db)
    ck(db.categoriesEnabled == true, "categoriesEnabled default ON")
    ck(type(db.categories) == "table" and #db.categories == 5, "seeded 5 default categories")
    local off = { categoriesEnabled = false, categories = {} }
    Rules.ApplyDefaults(off)
    ck(off.categoriesEnabled == false, "explicit categoriesEnabled=false preserved")
    ck(#off.categories == 0, "explicit empty category list NOT re-seeded (a valid choice)")
    ck(Rules.Enabled({}) == true, "Enabled: absent => ON")
    ck(Rules.Enabled({ categoriesEnabled = false }) == false, "Enabled: explicit false")
    -- RestoreDefaults re-seeds
    Rules.RestoreDefaults(off)
    ck(#off.categories == 5 and off.categoriesEnabled == true, "RestoreDefaults re-seeds list + turns feature on")

    -- CountMatches (live editor readout) over a small bag.
    local R = fakeResolver(catalogDB())
    local entries = {
        { data = rec(1, 1) }, { data = rec(2, 4) }, { data = rec(3, 3) },
        { data = nil }, { data = rec(4, 0) },
    }
    local nEquip = Rules.CountMatches(Rules.CompileCategory("t:armor, t:weapon"), entries, { resolver = R })
    ck(nEquip == 2, "CountMatches: 2 equipment items (axe + helm), empty slot ignored")
    local nJunk = Rules.CountMatches(Rules.CompileCategory("junk"), entries, { resolver = R })
    ck(nJunk == 1, "CountMatches: 1 junk item")
end

-- PRE-EXISTING DB (defect #3 regression lock): a DaseekiBags2DB created BEFORE rules2
-- shipped has NEITHER categoriesEnabled NOR categories. The STORE_READY ApplyDefaults
-- hook must fill BOTH on that existing table (it is additive, not first-run-gated), and
-- the combined entry list must then bucket into real sections. (The owner's live miss was
-- upstream of this — rules2.lua was absent from the beta's Daseeki-Bags2.toc, so the
-- engine never loaded and ns.Rules was nil; this case locks the model itself.)
local function testPreExistingDB(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- An existing settings DB with unrelated keys but none of the categories keys.
    local db = { layout = "combined", columns = 12, qualityBorders = true }
    ck(db.categoriesEnabled == nil and db.categories == nil, "fixture: pre-rules2 DB lacks both keys")

    Rules.ApplyDefaults(db)
    ck(db.categoriesEnabled == true, "ApplyDefaults filled categoriesEnabled=true on the EXISTING db")
    ck(type(db.categories) == "table" and #db.categories == 5, "ApplyDefaults seeded the 5 default categories")
    ck(Rules.Enabled(db) == true, "feature now reads ON (combined view will render sections)")

    -- The unrelated pre-existing keys are untouched (additive, never clobbers).
    ck(db.layout == "combined" and db.columns == 12 and db.qualityBorders == true, "existing keys preserved")

    -- End-to-end: a combined entry list now buckets into named sections (not a flat grid).
    local R = fakeResolver(catalogDB())
    local entries = {
        { owner = {}, cid = 0, slot = 1, data = rec(1, 1) },   -- potion -> Consumables
        { owner = {}, cid = 0, slot = 2, data = rec(4, 0) },   -- junk   -> Junk
        { owner = {}, cid = 0, slot = 3, data = rec(2, 4) },   -- axe    -> Equipment
        { owner = {}, cid = 0, slot = 4, data = nil          }, -- empty  -> Free space
    }
    local sections = Rules.BuildSections(entries, Rules.CompileList(db.categories), { resolver = R })
    local names = {}
    for _, s in ipairs(sections) do names[s.name] = s.count end
    ck(names["Junk"] == 1 and names["Consumables"] == 1 and names["Equipment"] == 1,
        "existing DB now yields category sections (Junk/Consumables/Equipment)")
    ck(#sections >= 3, "sections built (not a flat grid), got " .. #sections)
end

function Rules.RunSelfTests(verbose)
    local suites = {
        { name = "compile + match",   fn = testCompileAndMatch },
        { name = "build sections",    fn = testBuildSections },
        { name = "first-match-wins",  fn = testFirstMatchWins },
        { name = "list ops",          fn = testListOps },
        { name = "defaults + count",  fn = testDefaultsAndCount },
        { name = "pre-existing db",   fn = testPreExistingDB },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS rules2/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL rules2/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("rules2", Rules.RunSelfTests)
end

return Rules
