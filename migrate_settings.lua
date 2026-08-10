-- Daseeki Bags 2.0 — migrate_settings.lua
-- One-time, READ-ONLY, marker-guarded conversion of the 1.x SETTINGS global
-- (DaseekiBagsSets) into the 2.0 settings DB, plus a best-effort conversion of the
-- 1.x custom rules into rules2 saved-search categories.
-- ROLLOUT_CONTINUITY_AUDIT NW-1. The 1.x global is NEVER written.
--
-- Sibling of migrate.lua, which converts the DATA globals (owners/bags/gold). Kept
-- separate because this is a different source, a different marker, and a different
-- failure mode: migrate.lua losing a character is catastrophic, this file getting a
-- mapping wrong is a cosmetic setting the owner can change back in one click. Both
-- run at the SAME migration moment — migrate.Migrate() calls MigrateSettings.Migrate()
-- right after the owner pass.
--
-- ── The three rules this pass obeys ───────────────────────────────────────────────
--
-- 1. CONSERVATIVE MAPPING. Only 1.x keys with a TRUE live 2.0 equivalent are mapped.
--    1.x carried a large appearance surface (skins, slot colors, glow alphas, frame
--    strata/alpha/scale, per-frame profiles, named profiles, mesh credentials) that
--    2.0 either does not have or expresses differently; guessing an equivalent would
--    produce a window the owner did not ask for. Unmapped keys are simply left behind,
--    and the report says which.
--
-- 2. USER-CHOSE GUARDS. A value the owner has already set in 2.0 is never overwritten.
--    "Already set" is decided the way the rest of this addon decides it (the house
--    pattern the audit names: Nexus match-by-value heals, Bags densityUserChose):
--      * key absent          -> take the 1.x value
--      * key == 2.0 default  -> take the 1.x value (it is a shipped default, not intent)
--      * key == 1.x value    -> nothing to do, counted as already carried
--      * anything else       -> LEAVE IT, that is a deliberate 2.0 choice
--    plus the explicit markers: db.densityUserChose vetoes columns/gap outright.
--
-- 3. NON-EMPTY GATE + MARKER DISCIPLINE (AT-RISK-1c, same law as migrate.lua). The
--    marker is written only when the source was really present and really read. An
--    absent or unrecognisable DaseekiBagsSets leaves the marker unset so a source that
--    appears on a later login still imports.
--
-- ── 1.x source shape (facts, read from the shipping 1.x tree) ─────────────────────
--   DaseekiBagsSets = {
--     global   = { inventory = <frame profile>, bank = ..., vault = ..., guild = ... },
--     profiles = { [realm] = { [charName] = { inventory = <frame profile>, ... } } },
--     customRules = { { title=, search= | macro=, icon= }, ... },   -- array
--     countItems=, moneyTooltipFaction=, moneyTooltipMinGold=,
--     display = { banker=, merchant=, mailInfo=, auctioneer=, tradePartner=, crafting=, ... },
--     glowQuality=, ... (plus appearance keys with no 2.0 equivalent)
--   }
--   A <frame profile> carries: columns, itemScale, spacing, bagBreak, money, and a
--   large appearance set. The effective profile for a character is its per-character
--   entry when one exists, otherwise the global one (1.x's own precedence).

local ADDON, ns = ...

local MigrateSettings = {}
ns.MigrateSettings = MigrateSettings

MigrateSettings.MARKER = "migratedSettingsFrom1x"

----------------------------------------------------------------------
-- 2.0 shipped defaults, read live from the modules that own them so this file can
-- never drift from them. Fallbacks match the shipped constants for the headless case
-- where a UI module is absent.
----------------------------------------------------------------------

function MigrateSettings.Defaults()
    local F = ns.Frame
    local I = ns.Items
    return {
        columns             = (F and F.DEFAULT_COLUMNS)    or 11,
        buttonSize          = (F and F.DEFAULT_BUTTONSIZE) or 37,
        gap                 = (F and F.DEFAULT_GAP)        or 2,
        layout              = "combined",
        showMoney           = true,
        showItemCounts      = true,
        qualityBorders      = true,
        moneyTooltipFaction = false,
        moneyTooltipMinGold = 0,
        -- Equipment-set teal: OFF by default (1.x's own set branch is inert on Era —
        -- ItemSearch-1.3/API.lua:145-146). See ui_items.lua's slotIsSet note.
        setMarkers          = false,
        -- New-item glow sheet: ON by default, which is 1.x's own shipped glowNew.
        newItemMarkers      = true,
        -- Slot appearance defaults are the OWNER'S live 1.x profile values, owned by
        -- ui_items so this file can never drift from them.
        slotBackground      = (I and I.DEFAULT_SLOT_BACKGROUND) or 6,
        slotAlpha           = (I and I.DEFAULT_SLOT_ALPHA)      or 0.29,
    }
end

-- Slider ranges from the 2.0 options page; a 1.x value outside them is clamped rather
-- than dropped, so an extreme old setting still lands somewhere usable.
local LIMITS = {
    columns             = { 6, 20 },
    buttonSize          = { 28, 48 },
    gap                 = { 0, 10 },
    moneyTooltipMinGold = { 0, 1000 },
}

local function clampInt(key, v)
    if type(v) ~= "number" then return nil end
    v = math.floor(v + 0.5)
    local lim = LIMITS[key]
    if lim then
        if v < lim[1] then v = lim[1] end
        if v > lim[2] then v = lim[2] end
    end
    return v
end

local function asBool(v)
    if v == nil then return nil end
    return v and true or false
end

----------------------------------------------------------------------
-- Source selection: 1.x's own profile precedence (per-character, else global).
----------------------------------------------------------------------

function MigrateSettings.PickInventoryProfile(sets, name, realm)
    if type(sets) ~= "table" then return nil, "none" end
    local profiles = sets.profiles
    if type(profiles) == "table" and name and realm then
        local byRealm = profiles[realm]
        local prof = type(byRealm) == "table" and byRealm[name] or nil
        if type(prof) == "table" and type(prof.inventory) == "table" then
            return prof.inventory, "character"
        end
    end
    local global = sets.global
    if type(global) == "table" and type(global.inventory) == "table" then
        return global.inventory, "global"
    end
    return nil, "none"
end

----------------------------------------------------------------------
-- Settings mapping
----------------------------------------------------------------------

-- 1.x display.<key> -> 2.0 autoDisplay.<key>. Both sides default to ON, so only an
-- explicit 1.x false is worth carrying; anything else is already the 2.0 behaviour.
-- 1.x's remaining display entries (voidStorageBanker, transmogrifier, socketing,
-- scrappingMachine, soulbind, ...) address interactions Classic Era does not have.
local AUTO_DISPLAY_MAP = {
    { "banker",       "bank"     },
    { "merchant",     "merchant" },
    { "mailInfo",     "mail"     },
    { "auctioneer",   "auction"  },
    { "tradePartner", "trade"    },
    { "crafting",     "craft"    },
}

-- Map the 1.x settings that have a true 2.0 equivalent onto `db`.
--   opts = { name=<char>, realm=<space-stripped realm> }
-- Returns a report; `db` is the only table written.
function MigrateSettings.MapSettings(db, sets, opts)
    opts = opts or {}
    local rep = {
        source = "none", considered = 0,
        applied = {}, matched = {}, kept = {}, unavailable = {},
    }
    if type(db) ~= "table" or type(sets) ~= "table" then return rep end

    local DEF = MigrateSettings.Defaults()

    -- The one write helper. Every user-chose guard lives here.
    local function put(target, key, value, default)
        if value == nil then return end
        rep.considered = rep.considered + 1
        local cur = target[key]
        if cur == value then
            rep.matched[#rep.matched + 1] = key
        elseif cur == nil or cur == default then
            target[key] = value
            rep.applied[#rep.applied + 1] = key
        else
            rep.kept[#rep.kept + 1] = key
        end
    end

    local inv, source = MigrateSettings.PickInventoryProfile(sets, opts.name, opts.realm)
    rep.source = source

    if inv then
        -- Grid density. densityUserChose is the explicit "the owner moved these
        -- sliders" marker written by options.lua; it vetoes both keys outright.
        if not db.densityUserChose then
            local before = #rep.applied

            put(db, "columns", clampInt("columns", inv.columns), DEF.columns)

            -- 1.x sized item buttons with a SCALE multiplier over the same 37px Classic
            -- cell 2.0 uses as its default; 2.0 stores the pixel size directly.
            if type(inv.itemScale) == "number" then
                put(db, "buttonSize", clampInt("buttonSize", DEF.buttonSize * inv.itemScale), DEF.buttonSize)
            end

            put(db, "gap", clampInt("gap", inv.spacing), DEF.gap)

            -- A grid density that came from the owner's own 1.x configuration IS a
            -- deliberate choice, so claim the marker: without it, a 1.x layout that
            -- happens to sit on the pre-parity 4/12 pair would be silently re-defaulted
            -- by Frame.MigrateDensity on the very same login.
            if #rep.applied > before then db.densityUserChose = true end
        else
            -- The marker is written by the Columns and Cell-gap sliders, but the veto
            -- covers button size too: an owner who deliberately configured the 2.0 grid
            -- should not have any part of it re-sized from a 1.x file.
            rep.kept[#rep.kept + 1] = "columns (density user-chosen)"
            rep.kept[#rep.kept + 1] = "buttonSize (density user-chosen)"
            rep.kept[#rep.kept + 1] = "gap (density user-chosen)"
        end

        -- Layout paradigm. 1.x drew one grid and could insert a row break between bags:
        -- 0 = never, 1 = only where the bag family changes, 2 = always. "Always" is the
        -- setting that says "show me my bags apart", which is 2.0's split layout; the
        -- other two are 2.0's combined grid.
        if type(inv.bagBreak) == "number" then
            put(db, "layout", (inv.bagBreak >= 2) and "split" or "combined", DEF.layout)
        end

        -- Money bar on the bag window.
        put(db, "showMoney", asBool(inv.money), DEF.showMoney)
    end

    -- Cross-character item counts in tooltips.
    put(db, "showItemCounts", asBool(sets.countItems), DEF.showItemCounts)

    -- Quality colouring of item slots (1.x drew it as a glow, 2.0 as a border; the
    -- toggle means the same thing to the owner). 1.x's remaining per-cue switches
    -- (glowQuest / glowUnusable / glowPoor) and its glowAlpha have no 2.0 equivalent:
    -- 2.0 has a minimum-quality floor instead, which is a different control, so it is
    -- deliberately left at its own default.
    put(db, "qualityBorders", asBool(sets.glowQuality), DEF.qualityBorders)

    -- BAG-7: glowNew DOES have a 2.0 equivalent, and this row is new because the earlier
    -- reading of the 1.x tree concluded (wrongly) that there was no new-item cue to map.
    -- 1.x core/api/settings.lua:35 ships `glowNew = true` with a checkbox at
    -- config/panels/slotOptions.lua:67, and it gates the same thing 2.0's newItemMarkers
    -- gates: the new-item glow sheet. Unlike glowSets below, this branch is fully live on
    -- Classic Era (it reads C_NewItems, not ItemSearch), so a stored value is a real
    -- preference and carries.
    put(db, "newItemMarkers", asBool(sets.glowNew), DEF.newItemMarkers)

    -- 1.x glowSets is DELIBERATELY NOT MIGRATED onto 2.0's setMarkers. On Classic Era
    -- 1.x's set branch is inert unless ItemRack is loaded (ItemSearch-1.3/API.lua:145-146
    -- binds BelongsToSet to a no-op), so a stored `glowSets = true` records "I never
    -- touched this switch", not "I want my bag repainted teal". Carrying it would turn a
    -- cue the source install could not draw into one the destination install can — which
    -- is exactly the regression this round fixes. 2.0's setMarkers stays off until the
    -- owner asks for it on the options page.
    rep.unavailable[#rep.unavailable + 1] = "glowSets (1.x set branch is inert on Era)"

    -- SLOT APPEARANCE — the three keys 1.x keeps directly on `sets` (its own
    -- SHARED_PROFILE_KEYS, core/api/settings.lua:145). 2.0's shipped defaults are already
    -- the owner's live values, so this normally matches rather than applies; it exists so
    -- ANY 1.x profile (a different character, a re-imported file) lands intact.
    if type(sets.slotBackground) == "number" and ns.Items
        and (ns.Items.SLOT_BACKGROUNDS[sets.slotBackground] ~= nil or sets.slotBackground == 1) then
        put(db, "slotBackground", math.floor(sets.slotBackground), DEF.slotBackground)
    end
    if type(sets.slotAlpha) == "number" then
        put(db, "slotAlpha", math.max(0, math.min(1, sets.slotAlpha)), DEF.slotAlpha)
    end
    do
        local c = sets.slotBorderColor
        if type(c) == "table" and type(c[1]) == "number"
            and type(c[2]) == "number" and type(c[3]) == "number" then
            -- A colour is a table, so `put`'s identity compare can never match or be
            -- "still at the default"; write it only when 2.0 has no value of its own.
            if db.slotBorderColor == nil then
                db.slotBorderColor = { c[1], c[2], c[3], type(c[4]) == "number" and c[4] or 1 }
                rep.applied[#rep.applied + 1] = "slotBorderColor"
                rep.considered = rep.considered + 1
            else
                rep.kept[#rep.kept + 1] = "slotBorderColor"
            end
        end
    end

    -- Money tooltip: identical key names and identical meaning on both sides.
    put(db, "moneyTooltipFaction", asBool(sets.moneyTooltipFaction), DEF.moneyTooltipFaction)
    put(db, "moneyTooltipMinGold", clampInt("moneyTooltipMinGold", sets.moneyTooltipMinGold), DEF.moneyTooltipMinGold)

    -- Auto-open interactions: carry the explicit OFFs.
    if type(sets.display) == "table" then
        if type(db.autoDisplay) ~= "table" then db.autoDisplay = {} end
        for _, pair in ipairs(AUTO_DISPLAY_MAP) do
            local old, new = pair[1], pair[2]
            if sets.display[old] == false then
                put(db.autoDisplay, new, false, true)
            end
        end
    end

    return rep
end

----------------------------------------------------------------------
-- Custom rules -> rules2 categories
--
-- A 1.x custom rule is either a SEARCH rule (a query string in the 1.x search grammar)
-- or a MACRO rule (arbitrary Lua evaluated per item). A 2.0 category IS a saved search
-- query, so search rules can convert and macro rules cannot — those are counted and
-- reported, never silently dropped.
--
-- Grammar differences that decide what is convertible:
--   * 1.x separators: "&" or the word "and"; "|" or the word "or"; whitespace inside a
--     phrase is also AND. 1.x splits on AND FIRST, so a mixed query reads as
--     AND-of-ORs. 2.0 reads a comma-separated list of clauses as OR-of-ANDs. Pure-AND
--     and pure-OR queries mean the same thing in both, mixed ones do not, so mixed
--     queries are skipped rather than silently re-associated.
--   * A tag applies to the whole phrase it starts, in both grammars' spirit; each
--     tagged word is emitted as its own 2.0 term.
--   * Filters with a 2.0 equivalent: type (t/type), quality (q/quality/rarity),
--     equip slot (s/slot), name (n/name), equipment set (set).
--     Filters without one: tooltip text, item level, required level, expansion, and
--     the bind keywords. Any of those, plus negation "!"/"~" and grouping, skips.
--   * A bare word is a name substring in 2.0. In 1.x a bare word also tried the
--     quality and type vocabularies, so a bare quality word ("epic") almost always
--     means the quality, and is emitted as q:epic. That is the one deliberate
--     approximation in this converter.
--   * A comma is an ordinary character in 1.x and a clause separator in 2.0, so a
--     query containing one is skipped rather than silently re-cut.
----------------------------------------------------------------------

local TAG_MAP = {
    t = "t", type = "t",
    q = "q", quality = "q", rarity = "q",
    s = "slot", slot = "slot",
    n = "", name = "",          -- "" = emit as a bare name substring
    set = "set",
}

local UNSUPPORTED_TAGS = {
    tt = true, tip = true, tooltip = true,
    l = true, lvl = true, ilvl = true, level = true,
    r = true, req = true, rl = true, reqlvl = true,
    e = true, expac = true, expansion = true,
}

-- 1.x bind-state keywords, matched as bare words. 2.0 stores no bind state.
local UNSUPPORTED_BAREWORDS = { bop = true, boe = true, bou = true }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function qualityWord(w)
    local S = ns.Search
    return S and S.QUALITY_NAMES and S.QUALITY_NAMES[w] ~= nil
end

local function qualityValueOK(v)
    local S = ns.Search
    if not (S and S.ParseQuality) then return false end
    return S.ParseQuality(v) ~= nil
end

-- One 1.x phrase -> a list of 2.0 terms, or nil + reason.
local function convertPhrase(phrase)
    phrase = trim(phrase)
    if phrase == "" then return nil, "empty clause" end

    local tokens = {}
    local tag, rest = phrase:match("^(%a+):%s*(.*)$")
    if tag then
        local mapped = TAG_MAP[tag]
        if mapped == nil then
            if UNSUPPORTED_TAGS[tag] then
                return nil, "filter '" .. tag .. ":' has no 2.0 equivalent"
            end
            return nil, "unknown filter '" .. tag .. ":'"
        end
        rest = trim(rest)
        if rest == "" then
            -- A bare "set:" is meaningful in 2.0 (belongs to ANY equipment set).
            if mapped == "set" then return { "set:" } end
            return nil, "filter '" .. tag .. ":' with no value"
        end
        for w in rest:gmatch("%S+") do
            if mapped == "q" then
                if not qualityValueOK(w) then
                    return nil, "quality value '" .. w .. "' has no 2.0 equivalent"
                end
                tokens[#tokens + 1] = "q:" .. w
            elseif mapped == "" then
                tokens[#tokens + 1] = w
            else
                tokens[#tokens + 1] = mapped .. ":" .. w
            end
        end
    else
        for w in phrase:gmatch("%S+") do
            if w:match("^[<>=]") then
                return nil, "comparison '" .. w .. "' without a filter"
            elseif UNSUPPORTED_BAREWORDS[w] then
                return nil, "'" .. w .. "' has no 2.0 equivalent"
            elseif qualityWord(w) then
                tokens[#tokens + 1] = "q:" .. w
            else
                tokens[#tokens + 1] = w
            end
        end
    end

    if #tokens == 0 then return nil, "no usable terms" end
    return tokens
end

-- A whole 1.x query -> a 2.0 category query, or nil + reason.
function MigrateSettings.ConvertQuery(query)
    if type(query) ~= "string" then return nil, "not a search rule" end
    local s = trim(query:lower())
    if s == "" then return nil, "empty query" end
    if s:find("[!~]") then return nil, "negation has no 2.0 equivalent" end
    if s:find("[()]") then return nil, "grouping has no 2.0 equivalent" end
    if s:find(",", 1, true) then return nil, "contains a comma, which 2.0 reads as a clause break" end
    if not (ns.Search and ns.Search.ParseQuality) then return nil, "search grammar unavailable" end

    -- Normalise the word forms of the separators onto their symbols.
    s = " " .. s .. " "
    s = s:gsub("%s+and%s+", " & "):gsub("%s+or%s+", " | ")

    local hasAnd = s:find("&", 1, true) ~= nil
    local hasOr  = s:find("|", 1, true) ~= nil
    if hasAnd and hasOr then
        return nil, "mixes and/or, which the two grammars group differently"
    end

    local clauses = {}
    if hasOr then
        -- OR: every phrase becomes its own 2.0 clause.
        for phrase in s:gmatch("[^|]+") do
            if trim(phrase) ~= "" then
                local tokens, why = convertPhrase(phrase)
                if not tokens then return nil, why end
                clauses[#clauses + 1] = table.concat(tokens, " ")
            end
        end
        if #clauses == 0 then return nil, "no usable terms" end
        return table.concat(clauses, ", ")
    end

    -- AND (or a single phrase): everything AND-s into one clause.
    local all = {}
    for phrase in s:gmatch("[^&]+") do
        if trim(phrase) ~= "" then
            local tokens, why = convertPhrase(phrase)
            if not tokens then return nil, why end
            for _, t in ipairs(tokens) do all[#all + 1] = t end
        end
    end
    if #all == 0 then return nil, "no usable terms" end
    return table.concat(all, " ")
end

-- Convert the whole customRules array. Pure: returns the category records to add and
-- the skip list; writes nothing.
function MigrateSettings.ConvertRules(sets)
    local out = { categories = {}, skipped = {} }
    if type(sets) ~= "table" or type(sets.customRules) ~= "table" then return out end

    for i, rule in ipairs(sets.customRules) do
        if type(rule) == "table" then
            local name = type(rule.title) == "string" and trim(rule.title) or ""
            if name == "" then name = "Imported rule " .. i end

            if type(rule.search) ~= "string" then
                out.skipped[#out.skipped + 1] = {
                    name = name,
                    reason = (rule.macro ~= nil)
                        and "macro rule (a 2.0 category is a saved search, not code)"
                        or  "no search query on the rule",
                }
            else
                local query, why = MigrateSettings.ConvertQuery(rule.search)
                if query then
                    out.categories[#out.categories + 1] =
                        { name = name, query = query, enabled = true }
                else
                    out.skipped[#out.skipped + 1] = { name = name, reason = why }
                end
            end
        end
    end
    return out
end

-- Install converted rules into db.categories.
--
-- Ordering matters because rules2 is first-match-wins: imported categories go ABOVE
-- the seeded defaults when this pass is what created the list (otherwise a "Herbs"
-- import would be swallowed whole by the seeded "Trade Goods" and read as broken).
-- When the list already existed it is the owner's own ordering, so imports are
-- appended and nothing is reordered.
--
-- The master toggle db.categoriesEnabled is deliberately NOT flipped: 2.0 opens the
-- combined view as one flat grid by design, and the audit's own rule is that a
-- migration must not override a shipped decision. The chat notice tells the owner the
-- categories are there.
function MigrateSettings.ImportCategories(db, sets)
    local rep = { imported = 0, skipped = 0, duplicates = 0, reasons = {}, seeded = false }
    if type(db) ~= "table" then return rep end

    local converted = MigrateSettings.ConvertRules(sets)
    rep.skipped = #converted.skipped
    for _, s in ipairs(converted.skipped) do rep.reasons[#rep.reasons + 1] = s end
    if #converted.categories == 0 then return rep end

    if type(db.categories) ~= "table" then
        db.categories = (ns.Rules and ns.Rules.DefaultCategories and ns.Rules.DefaultCategories()) or {}
        rep.seeded = true
    end

    -- Idempotency belt (the marker is the braces): never add the same name+query twice.
    local seen = {}
    for _, c in ipairs(db.categories) do
        if type(c) == "table" then seen[tostring(c.name) .. "\0" .. tostring(c.query)] = true end
    end

    local fresh = {}
    for _, c in ipairs(converted.categories) do
        local key = c.name .. "\0" .. c.query
        if seen[key] then
            rep.duplicates = rep.duplicates + 1
        else
            seen[key] = true
            fresh[#fresh + 1] = c
        end
    end

    for i, c in ipairs(fresh) do
        if rep.seeded then
            table.insert(db.categories, i, c)
        else
            db.categories[#db.categories + 1] = c
        end
        rep.imported = rep.imported + 1
    end

    -- The list now reflects a real choice of the owner's, so the R3 one-time
    -- default-flip must never touch it.
    if rep.imported > 0 then db.categoriesUserChose = true end
    return rep
end

----------------------------------------------------------------------
-- The pass.
--   db   : DaseekiBags2DB (the only table written)
--   sets : DaseekiBagsSets (never written)
--   opts : { name=, realm=, force=<bool> }
----------------------------------------------------------------------

function MigrateSettings.Run(db, sets, opts)
    opts = opts or {}
    if type(db) ~= "table" then
        return { skipped = true, ran = false, reason = "no settings db" }
    end
    if db[MigrateSettings.MARKER] and not opts.force then
        return { skipped = true, ran = false, reason = "already migrated" }
    end

    local rep = { skipped = false, ran = false, markerSet = false }

    -- Non-empty gate: an absent or empty source is not a migration, it is a fresh
    -- install. Return BEFORE the marker so a later source still imports.
    if type(sets) ~= "table" or next(sets) == nil then
        rep.reason = "no 1.x settings present"
        rep.settings = { source = "none", considered = 0, applied = {}, matched = {}, kept = {} }
        rep.rules = { imported = 0, skipped = 0, duplicates = 0, reasons = {} }
        return rep
    end

    rep.ran      = true
    rep.settings = MigrateSettings.MapSettings(db, sets, opts)
    rep.rules    = MigrateSettings.ImportCategories(db, sets)
    rep.appliedCount = #rep.settings.applied
    rep.matchedCount = #rep.settings.matched
    rep.keptCount    = #rep.settings.kept

    -- Marker discipline: only when the source really was read. "Read" means we found
    -- at least one recognisable 1.x setting or at least one convertible rule — a
    -- DaseekiBagsSets holding nothing this version understands leaves the marker unset.
    if rep.settings.considered == 0 and rep.rules.imported == 0 and rep.rules.skipped == 0 then
        rep.reason = "1.x settings present but nothing recognisable in them"
        return rep
    end

    db[MigrateSettings.MARKER] = true
    rep.markerSet = true
    return rep
end

----------------------------------------------------------------------
-- Live wrapper. Called by migrate.Migrate() at the migration moment.
----------------------------------------------------------------------

function MigrateSettings.Migrate()
    local Store = ns.Store
    local db = Store and Store.db
    if type(db) ~= "table" then return { skipped = true, ran = false, reason = "store not ready" } end

    -- Character key, canonicalised the way the rest of the addon does (1.x stripped
    -- spaces out of realm names in its SavedVariables keys).
    local name, realm
    if _G.UnitName then name = _G.UnitName("player") end
    if _G.GetRealmName then realm = ((_G.GetRealmName() or ""):gsub("%s+", "")) end

    local rep = MigrateSettings.Run(db, _G.DaseekiBagsSets, { name = name, realm = realm })

    -- ── SORT LOCKS (locks.lua) ────────────────────────────────────────────────────
    -- Runs HERE because its TARGET is this file's target — DaseekiBags2DB, the settings
    -- global — even though its SOURCE is DaseekiBagsAccount (1.x kept locks in the bag
    -- cache because 1.x had only one SavedVariable to keep them in; 2.0 files them as
    -- the configuration they are). So it rides the settings pass, and the settings pass
    -- is what the migration moment already calls.
    --
    -- ITS OWN MARKER, deliberately, NOT MigrateSettings.MARKER. The owner's live
    -- DaseekiBags2DB already carries migratedSettingsFrom1x = true from an earlier beta
    -- login, so a lock import folded under that flag could never run for him — the one
    -- person whose 1.x file actually holds locks. Separate source shape, separate
    -- marker, same three house rules (marker-guarded / non-empty gated / additive).
    if ns.Locks and ns.Locks.Migrate then
        rep.locks = ns.Locks.Migrate()
    end

    if rep.ran and ns.Print then
        local carried = (rep.appliedCount or 0) + (rep.matchedCount or 0)
        if carried > 0 or rep.rules.imported > 0 then
            ns:Print(("carried over %d setting(s) from your 1.x configuration."):format(carried))
        end
        if rep.rules.imported > 0 then
            ns:Print(("%d custom rule(s) became categories — switch Categories on in the " ..
                      "options to use them."):format(rep.rules.imported))
        end
        if rep.rules.skipped > 0 then
            ns:Print(("%d custom rule(s) could not be converted (they use filters a 2.0 " ..
                      "category cannot express); your 1.x copy of them is untouched."):format(rep.rules.skipped))
        end
    end
    return rep
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "migrate_settings")
----------------------------------------------------------------------

-- A 1.x-shaped source. Values are the SHIPPED 1.x defaults except where a test needs
-- a difference; structure is faithful to the real global.
local function sampleSets(overrides)
    local s = {
        global = {
            inventory = {
                columns = 10, itemScale = 1, spacing = 2, bagBreak = 1,
                money = true, enabled = true, alpha = 1, scale = 1,
                strata = "HIGH", x = -50, y = 100, point = "BOTTOMRIGHT",
                rules = { sidebar = { "all", "normal", "trade" } },
            },
            bank = { columns = 14, itemScale = 1, spacing = 2 },
        },
        profiles = {},
        customRules = {},
        countItems = true, countCurrency = true,
        moneyTooltipFaction = false, moneyTooltipMinGold = 0,
        glowQuality = true, glowNew = true, glowPoor = true, glowAlpha = 0.5,
        colorSlots = true,
        display = { banker = true, merchant = true, mailInfo = true,
                    auctioneer = true, tradePartner = true, crafting = true },
    }
    if overrides then for k, v in pairs(overrides) do s[k] = v end end
    return s
end

local function freshDB()
    return { settingsVersion = 1, layout = "combined", showMoney = true, showItemCounts = true }
end

local function has(list, key)
    for _, v in ipairs(list) do if v == key then return true end end
    return false
end

-- The owner's real shape: a 1.x config whose grid already equals the 2.0 defaults
-- (columns 11, cell pitch 37 + 2). Covered in both DB states, because the grid keys are
-- only defaulted at LOGIN (Frame.ApplyDefaults) whereas this pass runs at ADDON_LOADED:
--   * a first-cutover DB has them nil     -> the 1.x value is written
--   * a beta DB already has them defaulted -> recognised as matching, nothing written
local function testMatchingConfig(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local DEF = MigrateSettings.Defaults()
    local sets = sampleSets()
    sets.global.inventory.columns = DEF.columns   -- 11: the owner's real 1.x column count
    sets.global.inventory.spacing = DEF.gap       -- 2:  the 1.0 cell pitch 37 + 2

    -- 1) Fresh cutover DB: keys absent, so the 1.x values land (identical values, but
    --    written rather than assumed -- the pass never relies on another module's
    --    defaults having run first).
    local db = freshDB()
    local rep = MigrateSettings.Run(db, sets, { name = "Puuchoco", realm = "Whitemane" })
    ck(rep.ran == true, "ran against a real source")
    ck(rep.settings.source == "global", "fell back to the global profile")
    ck(has(rep.settings.applied, "columns"), "columns written on a fresh db")
    ck(db.columns == DEF.columns and db.gap == DEF.gap, "and match the owner's 1.x grid")
    ck(db.densityUserChose == true, "a 1.x grid claims the density marker")
    ck(rep.markerSet == true and db[MigrateSettings.MARKER] == true, "marker set on a real read")
    ck(MigrateSettings.Run(db, sets, {}).skipped == true, "second run skipped by the marker")

    -- 2) Already-defaulted DB: identical values, so nothing is written at all.
    local db2 = freshDB()
    db2.columns    = DEF.columns
    db2.gap        = DEF.gap
    db2.buttonSize = DEF.buttonSize
    local rep2 = MigrateSettings.Run(db2, sets, { name = "Puuchoco", realm = "Whitemane" })
    ck(has(rep2.settings.matched, "columns"), "columns recognised as already matching")
    ck(has(rep2.settings.matched, "gap"), "gap recognised as already matching")
    ck(has(rep2.settings.matched, "buttonSize"), "buttonSize recognised as already matching")
    ck(not has(rep2.settings.applied, "columns") and not has(rep2.settings.applied, "gap")
        and not has(rep2.settings.applied, "buttonSize"),
        "no grid key written when the 1.x config already agrees")
    ck(db2.densityUserChose == nil, "no grid write means no density marker claimed")
    ck(rep2.markerSet == true, "a no-change pass still completes (the source WAS read)")
end

-- A 1.x config that differs everywhere: every mapped key lands, clamped and converted.
local function testFullMapping(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = freshDB()
    local sets = sampleSets()
    local inv = sets.global.inventory
    inv.columns   = 14
    inv.itemScale = 1.2       -- 37 * 1.2 = 44.4 -> 44
    inv.spacing   = 5
    inv.bagBreak  = 2         -- ALWAYS -> split
    inv.money     = false
    sets.countItems          = false
    sets.glowQuality         = false
    sets.glowNew             = false
    sets.moneyTooltipFaction = true
    sets.moneyTooltipMinGold = 50
    sets.display.merchant    = false
    sets.display.mailInfo    = false

    local rep = MigrateSettings.Run(db, sets, { name = "Puuchoco", realm = "Whitemane" })
    ck(db.columns == 14, "columns carried")
    ck(db.buttonSize == 44, "itemScale 1.2 -> 44px button")
    ck(db.gap == 5, "spacing -> gap")
    ck(db.layout == "split", "bagBreak ALWAYS -> split layout")
    ck(db.showMoney == false, "money bar off carried")
    ck(db.showItemCounts == false, "countItems -> showItemCounts")
    ck(db.qualityBorders == false, "glowQuality -> qualityBorders")
    ck(db.newItemMarkers == false, "glowNew -> newItemMarkers (BAG-7: 1.x DOES have this cue)")
    ck(db.moneyTooltipFaction == true, "moneyTooltipFaction carried 1:1")
    ck(db.moneyTooltipMinGold == 50, "moneyTooltipMinGold carried 1:1")
    ck(db.autoDisplay.merchant == false, "display.merchant off -> autoDisplay.merchant off")
    ck(db.autoDisplay.mail == false, "display.mailInfo off -> autoDisplay.mail off")
    ck(db.autoDisplay.bank == nil, "an ON 1.x display key writes nothing (already the default)")
    ck(db.densityUserChose == true, "grid values from 1.x claim the density marker")
    ck(rep.appliedCount >= 9, "every mapped key reported as applied")

    -- bagBreak 0/1 stay combined.
    local db2 = freshDB()
    local s2 = sampleSets(); s2.global.inventory.bagBreak = 0
    MigrateSettings.Run(db2, s2, {})
    ck(db2.layout == "combined", "bagBreak NEVER -> combined")
end

-- Clamps: an out-of-range 1.x value lands inside the 2.0 slider range.
local function testClamps(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local db = freshDB()
    local sets = sampleSets()
    sets.global.inventory.columns   = 40    -- above the 20 max
    sets.global.inventory.itemScale = 0.3   -- 37 * 0.3 = 11.1, below the 28 min
    sets.global.inventory.spacing   = 99    -- above the 10 max
    sets.moneyTooltipMinGold        = 99999 -- above the 1000 max
    MigrateSettings.Run(db, sets, {})
    ck(db.columns == 20, "columns clamped to 20")
    ck(db.buttonSize == 28, "buttonSize clamped to 28")
    ck(db.gap == 10, "gap clamped to 10")
    ck(db.moneyTooltipMinGold == 1000, "minGold clamped to 1000")
end

-- User-chose guards: a deliberate 2.0 value is never overwritten.
local function testUserChoseGuards(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local DEF = MigrateSettings.Defaults()
    local sets = sampleSets()
    sets.global.inventory.columns = 14
    sets.global.inventory.spacing = 5
    sets.global.inventory.money   = false
    sets.countItems               = false

    -- 1) A non-default 2.0 value = intent. Left alone.
    local db = freshDB()
    db.columns = 9                      -- neither nil nor the 2.0 default
    db.showItemCounts = true            -- equals the default -> heals
    local rep = MigrateSettings.Run(db, sets, {})
    ck(db.columns == 9, "a user-set column count survives the migration")
    ck(has(rep.settings.kept, "columns"), "and is reported as kept")
    ck(db.showItemCounts == false, "a value still at the 2.0 default heals from 1.x")

    -- 2) The explicit density marker vetoes both grid keys even at default values.
    local db2 = freshDB()
    db2.densityUserChose = true
    db2.columns = DEF.columns
    db2.gap     = DEF.gap
    MigrateSettings.Run(db2, sets, {})
    ck(db2.columns == DEF.columns and db2.gap == DEF.gap, "densityUserChose vetoes columns/gap")
    ck(db2.showMoney == false, "non-grid keys still migrate under the density veto")
end

-- Per-character 1.x profile wins over the global one (1.x's own precedence).
local function testProfilePrecedence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local sets = sampleSets()
    sets.global.inventory.columns = 8
    sets.profiles = { ["Whitemane"] = { ["Puuchoco"] = { inventory = { columns = 16 } } } }

    local db = freshDB()
    local rep = MigrateSettings.Run(db, sets, { name = "Puuchoco", realm = "Whitemane" })
    ck(rep.settings.source == "character", "per-character profile selected")
    ck(db.columns == 16, "per-character columns used")

    -- A different character on the same realm falls back to global.
    local db2 = freshDB()
    local rep2 = MigrateSettings.Run(db2, sets, { name = "Shalk", realm = "Whitemane" })
    ck(rep2.settings.source == "global", "unknown character falls back to global")
    ck(db2.columns == 8, "global columns used")
end

-- Non-empty gate + late-appearing source + read-only guarantee.
local function testGateAndReadOnly(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local db = freshDB()
    local rep = MigrateSettings.Run(db, nil, {})
    ck(rep.ran == false and rep.markerSet == false, "absent source: no run, no marker")
    ck(db[MigrateSettings.MARKER] == nil, "marker left unset")

    MigrateSettings.Run(db, {}, {})
    ck(db[MigrateSettings.MARKER] == nil, "empty source table: still unset")

    -- Present but holding nothing this version understands.
    MigrateSettings.Run(db, { skinColors = { 1, 1, 1 } }, {})
    ck(db[MigrateSettings.MARKER] == nil, "unrecognisable source: still unset")

    -- The source turns up later and imports.
    local sets = sampleSets()
    sets.global.inventory.columns = 14
    local rep2 = MigrateSettings.Run(db, sets, {})
    ck(rep2.ran == true and rep2.markerSet == true, "late-appearing source imports")
    ck(db.columns == 14, "and its values land")

    -- Read-only: the source is untouched by a full pass, categories included.
    local src = sampleSets()
    src.customRules = { { title = "Herbs", search = "t:trade herb" } }
    local before = src.global.inventory.columns
    MigrateSettings.Run(freshDB(), src, {})
    ck(src.global.inventory.columns == before, "source profile not mutated")
    ck(src.customRules[1].search == "t:trade herb", "source rule not mutated")
    ck(src.customRules[1].query == nil, "no 2.0 field written onto the source rule")
end

-- The query converter, case by case.
local function testQueryConversion(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local C = MigrateSettings.ConvertQuery

    -- Convertible.
    ck(C("t:armor") == "t:armor", "type tag passes through")
    ck(C("q:epic") == "q:epic", "quality name")
    ck(C("q:>=3") == "q:>=3", "quality comparator")
    ck(C("quality:rare") == "q:rare", "quality alias -> q:")
    ck(C("rarity:rare") == "q:rare", "rarity alias -> q:")
    ck(C("type:consumable") == "t:consumable", "type alias -> t:")
    ck(C("s:head") == "slot:head", "slot alias -> slot:")
    ck(C("slot:head") == "slot:head", "slot tag")
    ck(C("n:crystal") == "crystal", "name tag -> bare substring")
    ck(C("Silver Bar") == "silver bar", "bare words lower-cased, AND-ed in one clause")
    ck(C("t:trade & q:rare") == "t:trade q:rare", "& -> one AND clause")
    ck(C("t:trade and q:rare") == "t:trade q:rare", "the word 'and' is the same separator")
    ck(C("t:armor | t:weapon") == "t:armor, t:weapon", "| -> comma-separated clauses")
    ck(C("t:armor or t:weapon") == "t:armor, t:weapon", "the word 'or' is the same separator")
    ck(C("epic") == "q:epic", "a bare quality word reads as the quality")
    ck(C("t:armor cloth") == "t:armor t:cloth", "a tag covers every word of its phrase")
    ck(C("set:") == "set:", "bare set: kept (belongs to any equipment set)")

    -- Not convertible: each returns nil and says why.
    local function why(q)
        local r, reason = C(q)
        return r == nil and type(reason) == "string" and reason ~= ""
    end
    ck(why("!t:armor"), "negation refused")
    ck(why("~junk"), "the other negation form refused")
    ck(why("(a | b) & c"), "grouping refused")
    ck(why("t:armor & q:rare | t:weapon"), "mixed and/or refused")
    ck(why("tt:soulbound"), "tooltip filter refused")
    ck(why("ilvl:>60"), "item-level filter refused")
    ck(why("r:60"), "required-level filter refused")
    ck(why("e:1"), "expansion filter refused")
    ck(why("bop"), "bind keyword refused")
    ck(why("q:mythic"), "an unknown quality word refused")
    ck(why("t:"), "a tag with no value refused")
    ck(why("herbs, flasks"), "a comma refused (it means clause break in 2.0)")
    ck(why(""), "empty query refused")
    ck(why(nil), "nil query refused")
    ck(why(42), "non-string query refused")

    -- Every converted query must be something the 2.0 engines actually parse.
    if ns.Search and ns.Search.Tokenize then
        local terms = ns.Search.Tokenize(C("t:trade & q:rare"))
        ck(#terms == 2, "converted AND query tokenizes to 2 terms")
        ck(terms[1].kind == "type" and terms[2].kind == "quality", "term kinds survive")
    end
    if ns.Rules and ns.Rules.CompileCategory then
        local compiled = ns.Rules.CompileCategory(C("t:armor | t:weapon"))
        ck(compiled ~= nil, "converted OR query compiles as a category")
    end
end

-- Rule import: ordering, counting, idempotency.
local function testRuleImport(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local sets = sampleSets()
    sets.customRules = {
        { title = "Herbs",    search = "t:trade herb" },
        { title = "Epics",    search = "q:epic" },
        { title = "Gear",     search = "t:armor | t:weapon" },
        { title = "Old Junk", macro  = "return quality == 0" },   -- macro: cannot convert
        { title = "Soulbound", search = "tt:soulbound" },         -- tooltip: cannot convert
        { search = "cloth" },                                      -- unnamed
    }

    local db = freshDB()
    local rep = MigrateSettings.Run(db, sets, {})
    ck(rep.rules.imported == 4, "four search rules converted")
    ck(rep.rules.skipped == 2, "the macro rule and the tooltip rule are skipped")
    ck(#rep.rules.reasons == 2, "each skip carries a reason")
    ck(type(db.categories) == "table", "categories list exists")

    -- Imports lead the list when this pass seeded it (first-match-wins protection).
    ck(rep.rules.seeded == true, "the list was seeded by this pass")
    ck(db.categories[1].name == "Herbs", "imports inserted above the seeded defaults")
    ck(db.categories[1].query == "t:trade t:herb", "and carry the converted query")
    ck(db.categories[3].query == "t:armor, t:weapon", "OR rule became a two-clause category")
    ck(db.categories[4].name == "Imported rule 6", "an untitled rule gets a stable name")
    ck(db.categories[5].name == "Junk", "the seeded defaults still follow, in order")
    ck(db.categoriesUserChose == true, "an import counts as a deliberate category choice")
    ck(db.categoriesEnabled == nil, "the master toggle is NOT flipped by the migration")

    -- An existing (owner-curated) list is appended to, never reordered.
    local db2 = freshDB()
    db2.categories = { { name = "Mine", query = "t:trade", enabled = true } }
    local rep2 = MigrateSettings.Run(db2, sets, {})
    ck(rep2.rules.seeded == false, "an existing list is not re-seeded")
    ck(db2.categories[1].name == "Mine", "the owner's first category stays first")
    ck(db2.categories[2].name == "Herbs", "imports appended after it")

    -- Idempotent under a forced re-run: nothing duplicates.
    local n = #db2.categories
    local rep3 = MigrateSettings.Run(db2, sets, { force = true })
    ck(#db2.categories == n, "a forced re-run adds nothing")
    ck(rep3.rules.duplicates == 4, "and reports them as already present")

    -- No custom rules at all: no categories touched, settings still migrate.
    local db3 = freshDB()
    local plain = sampleSets()
    local rep4 = MigrateSettings.Run(db3, plain, {})
    ck(rep4.rules.imported == 0 and rep4.rules.skipped == 0, "no rules, no imports")
    ck(db3.categories == nil, "an empty rule list never seeds the category list")
    ck(rep4.markerSet == true, "settings alone are enough to complete the pass")
end

-- THE CUTOVER CASE THAT ACTUALLY MATTERS FOR THE OWNER.
--
-- His live DaseekiBags2DB already carries migratedSettingsFrom1x = true from an earlier
-- beta login, so the settings pass is marker-SKIPPED on every future login. If the sort
-- locks rode that marker they would never import for him. This asserts the wiring the
-- other way round: a skipped settings pass STILL runs the lock import, because the lock
-- import owns its own marker.
local function testLockImportWiring(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local Locks = ns.Locks
    if not Locks then fails[#fails + 1] = "ns.Locks missing (load order changed?)"; return end

    local Store = ns.Store
    local savedDB, savedSets, savedAccount = Store.db, _G.DaseekiBagsSets, _G.DaseekiBagsAccount

    local db = freshDB()
    db[MigrateSettings.MARKER] = true          -- the owner's real state
    Store.db = db
    _G.DaseekiBagsSets = sampleSets()
    _G.DaseekiBagsAccount = {
        Whitemane = { Poonyx = { [4] = { size = 18, link = "14156",
                                         locked = { [15] = true, [16] = true } } } },
    }

    local rep = MigrateSettings.Migrate()
    ck(rep.skipped == true, "the settings pass itself is marker-skipped (owner's state)")
    ck(type(rep.locks) == "table", "the settings pass still ran the lock import")
    ck(rep.locks.imported == 2, "and it imported the 1.x locks (got "
        .. tostring(rep.locks and rep.locks.imported) .. ")")
    ck(db[Locks.MIGRATION_MARKER] == true, "the lock import set ITS OWN marker")
    ck(db[Locks.DB_KEY] and Locks.RootIsLocked(db[Locks.DB_KEY]["Poonyx-Whitemane"], 4, 15),
       "the locks landed in the settings DB under the character key")

    -- ...and a second login does not re-import.
    local rep2 = MigrateSettings.Migrate()
    ck(rep2.locks.skipped == true, "second login skips the lock import")

    -- READ-ONLY: the 1.x source is untouched by the pass.
    ck(_G.DaseekiBagsAccount.Whitemane.Poonyx[4].locked[15] == true,
       "the 1.x source still holds its own locks (read-only)")

    Store.db, _G.DaseekiBagsSets, _G.DaseekiBagsAccount = savedDB, savedSets, savedAccount
end

function MigrateSettings.RunSelfTests(verbose)
    local suites = {
        { name = "config already matching 2.0", fn = testMatchingConfig },
        { name = "full key mapping",            fn = testFullMapping },
        { name = "range clamps",                fn = testClamps },
        { name = "user-chose guards",           fn = testUserChoseGuards },
        { name = "profile precedence",          fn = testProfilePrecedence },
        { name = "non-empty gate + read-only",  fn = testGateAndReadOnly },
        { name = "1.x query conversion",        fn = testQueryConversion },
        { name = "custom rule import",          fn = testRuleImport },
        { name = "sort-lock import wiring",     fn = testLockImportWiring },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS migrate_settings/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL migrate_settings/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("migrate_settings", MigrateSettings.RunSelfTests)
end

return MigrateSettings
