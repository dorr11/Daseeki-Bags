-- Daseeki Bags 2.0 â€” ui_items.lua
-- The item button + grid group. Two layers, cleanly separated so the whole data
-- side is headless-testable and the render/interaction side stays thin:
--
--   PURE core (no WoW API; unit-tested by the harness):
--     Items.ContainerRank / cidInScope     â€” canonical container ordering + scope
--     Items.BuildGroups / Items.BuildEntries â€” turn a store owner into the entry lists
--                                              the frame agent consumes (per-container
--                                              grouping AND combined flatten)
--     Items.GridMetrics / Items.SlotPosition â€” grid math (cols/rows/self-size/xy)
--     Items.FlowClass / SplitRuns / RunLayout / RunSlotPosition â€” the 1.0 keyring
--                                              ROW-BREAK: the flat list is split into
--                                              runs at the bag-family boundary and each
--                                              later run restarts at column 0
--     Items.MarkerArt                       â€” the per-slot marker ART contract
--                                              (quest bang glyph / round token pips)
--     Items.ResolveVisual                   â€” icon/quality/name derivation with the
--                                              nil-quality (migrated) -> pending path
--     Items.DimValues / Items.FormatCachedAge
--
--   FRAME layer (in-game only; every WoW API call guarded on _G):
--     Items.CreateButton -> B:SetSlot / B:SetEmpty / B:Clear / B:SetDimmed
--     Items.CreateGroup  -> G:SetGrid / G:SetRunSplit / G:ShowSlots / G:Clear
--                           (self-sizing, never 0)
--
-- Interface contract (shared with the sibling ui_frame.lua):
--   entries = array of { owner=<ownerRec>, cid=<containerID>, slot=<n>, data=<slot|nil> }
--
-- LIVE slots (owner == the logged-in character): buttons inherit the game's
-- ContainerFrameItemButtonTemplate and are parented to a per-container holder frame
-- carrying holder:SetID(cid); with button:SetID(slot) the template's OWN default
-- secure/combat-correct handlers (pickup / place / split / use / real-slot tooltip)
-- operate on the right (bag, slot) with zero behavior re-implemented â€” the public
-- Blizzard template contract, not transcribed addon code. Structural (re)builds are
-- deferred out of combat (secure frames are protected).
-- OFFLINE / REMOTE owners: render-only ItemButtonTemplate buttons â€” icon/count/quality
-- from cached data, hyperlink tooltip + "cached Xd ago", clicks inert (shift-link only).
--
-- Every API is catalog-verified against wow-api-catalog/1.15.9.68808:
--   C_Item.GetItemInfoInstant (icon, always resolvable), C_Item.GetItemInfo (name/quality,
--   async), C_Item.RequestLoadItemDataByID; Event.Item.GetItemInfoReceived
--   (== GET_ITEM_INFO_RECEIVED {itemID, success}); C_Container.GetContainerItemCooldown
--   / GetContainerItemQuestInfo; SetItemButtonTexture/Count/Desaturated; CooldownFrame_Set.

local ADDON, ns = ...

local Items = {}
ns.Items = Items

local Store = ns.Store

----------------------------------------------------------------------
-- Grid defaults (Classic bag cell is 37px; tune via G:SetGrid)
----------------------------------------------------------------------

Items.DEFAULT_SIZE    = 37
Items.DEFAULT_GAP     = 2    -- 1.0 cell pitch 39 = 37 + 2 (skin\defaults spacing=2)
Items.DEFAULT_COLUMNS = 11   -- 1.0 inventory density (owner DaseekiBagsSets columns=11)
Items.MIN_CELL        = 30   -- 720p floor (C): below this the 1px quality edge + count numeral degrade together
Items.HEADER_HEIGHT   = 16   -- split-mode per-bag header band (sits ABOVE the grid)
Items.PLACEHOLDER_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- ====================================================================================
-- THE CELL SUBSTRATE â€” transcribed from 1.x AND from the OWNER'S LIVE 1.x PROFILE.
--
-- 1.x draws NOTHING of its own BEHIND a cell (core/classes/item.lua:51-52 hides the
-- template NormalTexture and creates no replacement). An empty slot is expressed by
-- setting the ICON to a chosen bag-slot art at a chosen opacity, and EVERY cell â€” filled
-- or empty â€” is framed by a 2px `SlotBorder` backdrop edge:
--
--   Daseeki-Bags/core/classes/item.lua:12-19   Item.Backgrounds (the slotBackground enum)
--   Daseeki-Bags/core/classes/item.lua:65-71   SlotBorder = 2px WHITE8X8 backdrop EDGE
--   Daseeki-Bags/core/classes/item.lua:156-167 bg = Backgrounds[sets.slotBackground];
--                                              icon:SetAlpha(hasItem and 1 or slotAlpha)
--   Daseeki-Bags/core/classes/item.lua:171-174 SlotBorder:SetBackdropBorderColor(
--                                              unpack(sets.slotBorderColor))  -- ALL cells
--
-- THE PARITY ROUND GOT THE VALUES FROM THE WRONG PLACE. It read skin/defaults.lua's
-- GlobalDefaults (slotBackground = 2 "the bevelled backpack art", slotAlpha = 1,
-- slotBorderColor = {1,1,1,0} "invisible") and shipped those. The owner does not run the
-- defaults â€” he deliberately changed all three, years ago, and asked for them back
-- verbatim: "can we also update the background of the item slots to match that of bags 1?
-- this was something i deliberately implemented in bags 1. the darkened, slightly opaque
-- background is easier on the eyes."
--
-- HIS LIVE VALUES (read-only, DaseekiBagsSets in his WTF SavedVariables; identical in
-- accounts #1, #2 and #3, and re-asserted in every one of his named profiles):
--
--   slotBackground  = 6      -- Backgrounds[6] -> icon:SetAtlas('MountJournalIcons-Horde')
--                            --   (his Alliance profile is 5, the Alliance crest; both are
--                            --   a faction emblem, NOT the bevelled backpack slot art)
--   slotAlpha       = 0.29   -- the empty-cell icon at 29%: a faint tint over a dark cell
--   slotBorderColor = {0.207843, 0, 0.023529, 0.59}   -- a near-black maroon 2px edge at
--                            --   59% on EVERY cell (his Alliance profile: a navy variant)
--
-- Rendered, that is exactly the screenshot he sent: near-black cells carrying a faint
-- tint, each one framed by a quiet dark edge â€” not 2.0's loud, fully-opaque bevel. These
-- are therefore the SHIPPED 2.0 DEFAULTS, and each is a live setting (db.slotBackground /
-- db.slotAlpha / db.slotBorderColor) so the choice stays his.
--
-- SCOPE, checked against 1.x and reproduced exactly:
--   * slotBackground + slotAlpha apply to EMPTY cells only (item.lua:157-167 branches on
--     hasItem; a filled cell always gets its item icon at full alpha).
--   * slotBorderColor applies to EVERY cell (item.lua:171-174 runs unconditionally, after
--     the hasItem branch has closed).
--
-- What stays retired: the `inset`/`raised` colour RECT 2.0 used to draw inset 1px inside
-- every button. 1.x has no filled substrate in any state; that rect is what turned the
-- grid into a lattice of hard-edged squares with a visible gutter.
-- ====================================================================================

-- 1.x's Item.Backgrounds enum (core/classes/item.lua:12-19), Classic-Era subset. A string
-- entry is a texture path; a table entry names an ATLAS (1.x expresses those two as a
-- string vs a function, which is the same distinction). Index 3 is Modern/retail-only and
-- index 1 is 'no art at all' in Era (LAYOUT_STYLE_MODERN is false), so both are absent.
Items.SLOT_BACKGROUNDS = {
    [2] = "Interface\\PaperDoll\\UI-Backpack-EmptySlot",   -- item.lua:14 (1.x's own default)
    [4] = "Interface\\Icons\\INV_Misc_Head_Lion_01",       -- item.lua:16
    [5] = { atlas = "MountJournalIcons-Alliance" },        -- item.lua:17
    [6] = { atlas = "MountJournalIcons-Horde" },           -- item.lua:18
}
-- Ordered, labelled choice list for the options page (1 = NONE, exactly as 1.x's own
-- frameOptions.lua:158-165 choice widget offers it).
Items.SLOT_BACKGROUND_CHOICES = {
    { value = 1, text = "None"     },
    { value = 2, text = "Classic"  },
    { value = 4, text = "Lion"     },
    { value = 5, text = "Alliance" },
    { value = 6, text = "Horde"    },
}

Items.DEFAULT_SLOT_BACKGROUND   = 6      -- owner profile DaseekiBagsSets.slotBackground
Items.DEFAULT_SLOT_ALPHA        = 0.29   -- owner profile DaseekiBagsSets.slotAlpha
Items.DEFAULT_SLOT_BORDER_COLOR = { 0.207843, 0, 0.023529, 0.59 }  -- owner profile
Items.SLOT_BORDER_PX            = 2      -- 1.x item.lua:69  edgeSize = 2

-- Back-compat aliases: 1.x's Backgrounds[2] art and 1.x's OWN default alpha. Retained
-- because older call sites/tests name them; the live cell reads SlotBackgroundArt/SlotAlpha.
Items.EMPTY_SLOT_TEXTURE = Items.SLOT_BACKGROUNDS[2]
Items.EMPTY_SLOT_ALPHA   = 1

-- PURE: resolve a slotBackground enum value to its art descriptor.
-- Returns nil for "no art" (enum 1, or any value 1.x has no Era entry for).
function Items.SlotBackgroundArt(which)
    local n = tonumber(which)
    if n == nil then n = Items.DEFAULT_SLOT_BACKGROUND end
    return Items.SLOT_BACKGROUNDS[n]
end

-- LIVE: the owner's three cell-substrate settings, each defaulting to his 1.x profile
-- value when the key is absent (additive â€” no SavedVariables write happens here).
local function storeDb()
    return (ns.Store and ns.Store.db) or nil
end

function Items.SlotBackground()
    local db = storeDb()
    local v = db and db.slotBackground
    if type(v) == "number" and Items.SLOT_BACKGROUNDS[v] ~= nil then return v end
    if v == 1 then return 1 end        -- explicit "None" is a valid choice, not a fallback
    return Items.DEFAULT_SLOT_BACKGROUND
end

-- Opacity of the EMPTY cell's art (1.x item.lua:167 `slotAlpha`). Clamped to 0..1.
function Items.SlotAlpha()
    local db = storeDb()
    local v = db and db.slotAlpha
    if type(v) ~= "number" then return Items.DEFAULT_SLOT_ALPHA end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- r, g, b, a for the 2px per-cell edge every cell carries (1.x item.lua:171-174).
-- A stored value must be a 3- or 4-element numeric list; anything else falls back.
function Items.SlotBorderColor()
    local db = storeDb()
    local c = db and db.slotBorderColor
    local d = Items.DEFAULT_SLOT_BORDER_COLOR
    if type(c) ~= "table" or type(c[1]) ~= "number"
        or type(c[2]) ~= "number" or type(c[3]) ~= "number" then
        return d[1], d[2], d[3], d[4]
    end
    local a = c[4]
    if type(a) ~= "number" then a = 1 end
    return c[1], c[2], c[3], a
end

----------------------------------------------------------------------
-- MARKER ART (defect #2: the corner markers were literal SetColorTexture squares)
--
-- Every marker is ADDON-OWNED art. It has to be: _killTemplateArt hides the template's
-- own NewItemTexture / IconQuestTexture / JunkIcon and re-hides them on every repaint
-- and on the SetItemButtonTexture/Quality hooks, so anything drawn into a native region
-- is erased on the next paint. Our regions are created by ensureDress and are not in the
-- kill registry, so they survive.
--
--   QUEST â€” the real bang glyph, 1.x-faithful. 1.x fact (core/classes/item.lua:39-47):
--     QuestBang IS the template's IconQuestTexture region and is painted with the
--     FrameXML constant TEXTURE_ITEM_QUEST_BANG. We reference the SAME constant from our
--     own region (with the literal Era path as a guard so a nil constant can never leave
--     an untextured object), anchored over the whole cell like the native region â€” so the
--     glyph lands exactly where 1.x puts it. WHEN it shows is now 1.x-exact too: the bang
--     is reserved for quest STARTERS only, and an ordinary quest item gets the gold border
--     tint instead (see Items.QuestFlags).
--   NEW / SET â€” token-tinted pips, but round: a WHITE8X8 fill clipped by our shipped
--     circular stencil (art/dot-mask.tga). Same size and same tokens as before; only the
--     SHAPE changes (hard square -> anti-aliased dot). Masking degrades to the old square
--     if CreateMaskTexture is unavailable, never to an invisible marker.
----------------------------------------------------------------------

Items.TEX_WHITE    = "Interface\\Buttons\\WHITE8X8"
-- Shipped stencil, addressed through the LIVE addon folder name (ADDON is the folder), so
-- the path is correct whether the install is Daseeki-Bags or the Daseeki-Bags2 beta.
Items.TEX_DOT_MASK = "Interface\\AddOns\\" .. tostring(ADDON) .. "\\art\\dot-mask"
-- Era path behind TEXTURE_ITEM_QUEST_BANG; used only if the FrameXML constant is missing.
Items.TEX_QUEST_BANG = "Interface\\ContainerFrame\\UI-Icon-QuestBang"

function Items.QuestBangTexture()
    return _G.TEXTURE_ITEM_QUEST_BANG or Items.TEX_QUEST_BANG
end

-- PURE: split C_Container.GetContainerItemQuestInfo's answer into the two 1.x facts.
-- Returns `isQuest, isStarter`.
--
-- 1.x rule, read as fact from its Item:GetQuestInfo (frames/inventory/item.lua):
--     return info.isQuestItem, (info.questID and not info.isActive)
-- ...consumed by UpdateBorder as `quest, bang`. So the DISTINGUISHING FIELD PAIR is
-- questID + isActive, NOT isQuestItem:
--   * isStarter (the bang) == the item carries a questID that is NOT yet active â€” i.e.
--     right-clicking it STARTS that quest. `isActive` true means the quest is already in
--     the log, so the item is just an objective and the bang is withheld.
--   * isQuest (the gold border) == isQuestItem â€” every quest item, starter or not.
-- 1.x paints the bang ONLY for a starter (`QuestBang:SetShown(bang)`) and tints the border
-- for `(glowQuest and quest) or bang`, so a starter gets BOTH glyph and tint. glowQuest
-- defaults ON in 1.x and 2.0 has no equivalent per-cue toggle, so it is treated as on â€”
-- no new setting, no SavedVariables change.
--
-- A starter is reported as a quest item too, so a starter whose isQuestItem is somehow
-- false still returns isQuest = true: the tint can never go missing under the glyph.
function Items.QuestFlags(info)
    if type(info) ~= "table" then return false, false end
    local isStarter = (info.questID and not info.isActive) and true or false
    local isQuest   = (info.isQuestItem or isStarter) and true or false
    return isQuest, isStarter
end

-- PURE: the art contract for one per-slot marker.  kind = "quest" | "new" | "set".
-- Returns { texture, mask, token, sizeRatio, anchor, glyph } or nil for an unknown kind.
-- Harness-locked: a marker may never again be a raw color fill (texture is always a real
-- path), and every non-glyph pip must carry a shape mask.
function Items.MarkerArt(kind)
    if kind == "quest" then
        -- Native glyph: no token tint (1.x shows the bang in its own gold), full-cell
        -- footprint = the native IconQuestTexture geometry 1.x paints.
        return { texture = Items.QuestBangTexture(), mask = nil, token = nil,
                 sizeRatio = 1, anchor = "CELL", glyph = true }
    elseif kind == "new" then
        return { texture = Items.TEX_WHITE, mask = Items.TEX_DOT_MASK, token = "brand",
                 sizeRatio = 0.24, anchor = "TOPRIGHT", glyph = false }
    end
    -- CELL PARITY: the "set" pip spec is RETIRED. 1.x expresses equipment-set membership as
    -- a teal branch of the glow chain (item.lua:201-202), not as a corner mark, so there is
    -- no art to declare. Borders.SetRGB carries the cue.
    return nil
end

-- Human labels per container class for the split-view bag header (fallback when the
-- bag item's real name is not resolvable from a link).
local CLASS_LABEL = {
    backpack = "Backpack", bag = "Bag", keyring = "Keyring",
    bank = "Bank", bankbag = "Bank Bag", unknown = "Items",
}

----------------------------------------------------------------------
-- PURE: container ordering + scope
----------------------------------------------------------------------

-- Canonical render order across containers (both combined flatten and split groups
-- sort by this): backpack, carried bags 1..N, keyring, bank main, bank bags.
function Items.ContainerRank(cid)
    local class = Store.ContainerClass(cid)
    if class == "backpack" then return 0 end
    if class == "bag"      then return tonumber(cid) or 900 end        -- 1..N
    if class == "keyring"  then return 50 end
    if class == "bank"     then return 100 end
    if class == "bankbag"  then return 100 + (tonumber(cid) or 800) end -- 100+id
    return 999
end

-- Scope maps a container CLASS to inclusion. `scope` is a preset string or a
-- predicate fn(cid)->bool; nil / "all" = everything.
local SCOPE_CLASSES = {
    bags    = { backpack = true, bag = true },
    carried = { backpack = true, bag = true, keyring = true },
    keyring = { keyring = true },
    bank    = { bank = true, bankbag = true },
}

local function cidInScope(cid, scope)
    if type(scope) == "function" then return scope(cid) and true or false end
    if scope == nil or scope == "all" then return true end
    local set = SCOPE_CLASSES[scope]
    if not set then return true end
    return set[Store.ContainerClass(cid)] and true or false
end
Items._cidInScope = cidInScope   -- exposed for self-tests

----------------------------------------------------------------------
-- PURE: entry-list building from a store owner
----------------------------------------------------------------------

-- Per-container grouping (split-bag-groups layout). Returns an array of
--   { cid, class, size, entries = { {owner,cid,slot,data}, ... } }   (empty slots
-- have data = nil), sorted by ContainerRank. `opts.scope` filters containers.
function Items.BuildGroups(owner, opts)
    opts = opts or {}
    local groups = {}
    if owner and owner.containers then
        for cid, c in pairs(owner.containers) do
            if cidInScope(cid, opts.scope) then
                local size = c.size or 0
                local entries = {}
                local slots = c.slots or {}
                for slot = 1, size do
                    entries[slot] = { owner = owner, cid = cid, slot = slot, data = slots[slot] }
                end
                groups[#groups + 1] = {
                    cid = cid, class = Store.ContainerClass(cid), size = size, entries = entries,
                }
            end
        end
    end
    table.sort(groups, function(a, b)
        local ra, rb = Items.ContainerRank(a.cid), Items.ContainerRank(b.cid)
        if ra == rb then return tostring(a.cid) < tostring(b.cid) end
        return ra < rb
    end)
    return groups
end

-- Combined flatten layout: the same entries, one flat array in container order then
-- slot order. The frame agent uses this for the combined view and BuildGroups for split.
function Items.BuildEntries(owner, opts)
    local flat = {}
    for _, g in ipairs(Items.BuildGroups(owner, opts)) do
        for _, e in ipairs(g.entries) do
            flat[#flat + 1] = e
        end
    end
    return flat
end

----------------------------------------------------------------------
-- PURE: grid math (self-size, never zero)
----------------------------------------------------------------------

-- Metrics for laying N cells in `columns` columns of `size` px with `gap` px between.
-- Width uses the number of columns actually populated (min(columns, N)) so a short
-- run hugs its content; height uses the full row count.
function Items.GridMetrics(n, columns, size, gap)
    columns = math.max(1, columns or Items.DEFAULT_COLUMNS)
    size    = size or Items.DEFAULT_SIZE
    gap     = gap or Items.DEFAULT_GAP
    n = math.max(0, n or 0)
    local cols = math.min(columns, math.max(n, 1))
    local rows = (n > 0) and math.ceil(n / columns) or 0
    local width  = cols * size + math.max(0, cols - 1) * gap
    local height = (rows > 0) and (rows * size + (rows - 1) * gap) or 0
    return { cols = cols, rows = rows, width = width, height = height }
end

-- Top-left (x, y) offset of the 1-based cell `index` within the grid. y is negative
-- (WoW anchors grow downward from TOPLEFT).
function Items.SlotPosition(index, columns, size, gap)
    columns = math.max(1, columns or Items.DEFAULT_COLUMNS)
    size    = size or Items.DEFAULT_SIZE
    gap     = gap or Items.DEFAULT_GAP
    local i = (index or 1) - 1
    local col = i % columns
    local row = math.floor(i / columns)
    return col * (size + gap), -(row * (size + gap))
end

----------------------------------------------------------------------
-- PURE: RUN SPLITTING (1.0 keyring row-break parity)
--
-- 1.x never flows the keyring into the running row. The keyring is its own bag
-- FAMILY (frames/inventory/inventory.lua family 9; normal bags + backpack are 0), and
-- core/classes/itemGroup.lua records a BREAK at every family boundary, then resets the
-- column to 0 and drops y by `breakSpace` (1.3 rows â€” one normal row plus a ~0.3-row
-- gap) when it crosses one. So the keys start a FRESH ROW with a small gap above,
-- still inside the same single button array â€” no separate frame, no header.
--
-- v2's combined view is one flat cid-ordered entry list (kept exactly as-is â€” the
-- entry list is the click-identity contract). The break therefore lives HERE, where
-- positions are assigned: the flat list is split into RUNS at the flow-class boundary
-- and each run after the first starts at column 0 of a new row, `RUN_GAP` px lower.
----------------------------------------------------------------------

-- Extra vertical space above a run that follows another (on top of the normal row gap).
-- 1.x fact: breakSpace 1.3 rows => 0.3 of a row-pitch of extra air. At the 2.0 default
-- pitch (37 cell + 2 gap = 39) that is 0.3 * 39 = 11.7px, so 12.
Items.RUN_GAP = 12

-- Layout FLOW CLASS of a container: "keyring" or "generic".
-- Derived from the cid CLASS (Store.ContainerClass), NEVER from a captured `family`
-- field â€” capture never stores one for cid <= 0, so a naive family read returns nil,
-- collapses the keyring back into the main run and silently restores the defect.
-- (1.x also breaks for quiver/soul/herb special bags; Era carries none by default and
-- v2 captures no family, so those stay generic until a family fact exists to read.)
function Items.FlowClass(cid)
    return (Store.ContainerClass(cid) == "keyring") and "keyring" or "generic"
end

-- Split a flat entry list into maximal runs of one flow class, in list order.
-- Returns { { from = <1-based flat index of the run's first cell>, n = <cells>,
--             class = <flow class> }, ... }.  Empty list -> {}.
function Items.SplitRuns(entries)
    local runs, cur = {}, nil
    entries = entries or {}
    for i = 1, #entries do
        local cls = Items.FlowClass(entries[i] and entries[i].cid)
        if cur and cur.class == cls then
            cur.n = cur.n + 1
        else
            cur = { from = i, n = 1, class = cls }
            runs[#runs + 1] = cur
        end
    end
    return runs
end

-- Stack runs into one grid. Run 1 starts at (0, 0); every later run starts at COLUMN 0
-- of a fresh row, separated from the run above by the normal row gap PLUS `runGap`.
-- Returns { rows, height, width, runs = { { from, n, class, y } } } where `y` is the
-- run's top offset (<= 0). Pure: the renderer and the window size math both use it.
function Items.RunLayout(runs, columns, size, gap, runGap)
    columns = math.max(1, columns or Items.DEFAULT_COLUMNS)
    size    = size or Items.DEFAULT_SIZE
    gap     = gap or Items.DEFAULT_GAP
    runGap  = runGap or Items.RUN_GAP
    local out = { runs = {}, rows = 0, height = 0, width = 0 }
    local y = 0
    for i, r in ipairs(runs or {}) do
        if i > 1 then y = y - gap - runGap end
        local m = Items.GridMetrics(r.n, columns, size, gap)
        out.runs[i] = { from = r.from, n = r.n, class = r.class, y = y }
        out.rows  = out.rows + m.rows
        if m.width > out.width then out.width = m.width end
        y = y - m.height
    end
    out.height = -y
    return out
end

-- (x, y) of the flat cell `index` inside a run-split layout `L` (from RunLayout).
-- An index outside every run falls back to the plain flat grid position.
function Items.RunSlotPosition(L, index, columns, size, gap)
    local rs = L and L.runs
    if rs then
        for i = 1, #rs do
            local r = rs[i]
            if index >= r.from and index < r.from + r.n then
                local x, y = Items.SlotPosition(index - r.from + 1, columns, size, gap)
                return x, y + r.y
            end
        end
    end
    return Items.SlotPosition(index, columns, size, gap)
end

----------------------------------------------------------------------
-- PURE: icon / quality / name resolution
----------------------------------------------------------------------

-- Derive what a button needs to render from a store slot `data`, using an injected
-- `resolver = { instant = <GetItemInfoInstant>, info = <GetItemInfo> }`:
--   * icon  â€” from GetItemInfoInstant, which resolves from static data for ANY valid
--             itemID even when the item is server-uncached (so migrated slots, which
--             cache no icon, still get one immediately).
--   * quality/name â€” captured quality wins; else GetItemInfo (server-cached). When
--             quality is still unresolvable the slot is `pending` (placeholder now,
--             repaint on GET_ITEM_INFO_RECEIVED).
-- Returns { id, count, icon, quality, name, link, pending } or nil for an empty slot.
function Items.ResolveVisual(data, resolver)
    if not data or not data.id then return nil end
    local v = { id = data.id, count = data.count or 1, link = data.link, quality = data.quality }

    if resolver and resolver.instant then
        local _, _, _, _, icon = resolver.instant(data.id)
        v.icon = icon
    end
    if resolver and resolver.info then
        local name, link, quality = resolver.info(data.id)
        v.name = name
        if v.link == nil then v.link = link end
        if v.quality == nil then v.quality = quality end
    end
    v.name = v.name or data.link
    v.pending = (v.quality == nil)
    return v
end

----------------------------------------------------------------------
-- PURE: dim state + cached-age formatting
----------------------------------------------------------------------

-- Search-dim (W4) reads this: returns alpha, desaturate for a dim flag.
function Items.DimValues(dimmed)
    if dimmed then return Items.DIM_ALPHA, true end
    return 1.0, false
end

-- Dress alpha for the whole slot dress (icon + quality edge + state markers + count).
-- The dim-cascade fix: search-dim recedes the ENTIRE dress together, not just the icon.
-- CELL PARITY: 0.3, not 0.25 â€” 1.x core/classes/item.lua:233 `self:SetAlpha(matches and 1
-- or 0.3)` on the whole button. (DimValues below is the older two-value form and tracks it.)
Items.DIM_ALPHA = 0.3
function Items.DressAlpha(dimmed)
    return dimmed and Items.DIM_ALPHA or 1.0
end

-- Cell-size floor (720p, C): clamp the button cell so a laptop user can't shrink cells
-- into illegibility (the 1px quality edge and the count numeral fail together below ~30px).
-- Columns is the lever for fitting more, not shrinking cells.
function Items.ClampCell(size)
    size = size or Items.DEFAULT_SIZE
    if size < Items.MIN_CELL then return Items.MIN_CELL end
    return size
end

-- PURE: two-layer STATE resolver (Layer 2). Given a slot's live facts, decide the icon
-- treatment (mutually exclusive) and the corner markers (independent), with precedence:
--   icon:  dimmed  >  normal          (CELL PARITY: junk no longer greys the icon)
--   markers: new-item wax dot + quest tab show ONLY when NOT dimmed
--
-- CELL-PARITY CHANGES vs the previous round, both transcribed from 1.x:
--   * JUNK NO LONGER DESATURATES. 1.x leaves a poor item's icon at full colour
--     (item.lua:170 `self.icon:SetVertexColor(1,1,1)`; the only SetDesaturated calls are
--     the LOCKED state :179 and the SEARCH miss :234) and expresses junk with the
--     template's JunkIcon coin instead (item.lua:222). Greyscaling a third of a Classic
--     bag is the "hard to view" half of the owner's report; `junkCoin` replaces it.
--   * THE SET CUE IS A BORDER, NOT A PIP. 1.x item.lua:201-202 routes equipment-set
--     membership through the SAME glow chain as everything else (teal .2/1/.8), between
--     the unusable red and the rarity colour. `setBorder` replaces `showSetMark`, so a
--     set item carries ONE cue like every other cell instead of a cue plus a corner pip.
-- 1.0-PARITY change (glowUnusable): UNUSABLE no longer greys the icon â€” 1.x kept the icon
-- FULL-COLOR and drew a RED BORDER instead (RED_FONT_COLOR). So unusable now yields
-- redBorder=true (drawn by borders.Apply, winning over the quality edge on that cell) while
-- the icon stays normal. `unusableTint` is retired (kept false for back-compat readers).
-- 1.x QUEST SPLIT: `isQuest` (any quest item) and `isQuestStarter` (a quest STARTER) drive
-- two different cues, exactly as 1.x does â€” the bang glyph is reserved for starters
-- (showQuestTab), while every quest item takes the gold border tint (questBorder). The
-- tint is 1.x's FIRST border branch, so it wins over the unusable red and the quality
-- edge; redBorder is therefore suppressed on a quest cell so the two never fight.
--   ctx = { quality=<n|nil>, dimmed=<bool>, isNew=<bool>, isQuest=<bool>,
--           isQuestStarter=<bool>, isUnusable=<bool>, isSet=<bool> }
-- returns { icon, iconDesat, redBorder, questBorder, setBorder, junkCoin, unusableTint,
--           showNewDot, showQuestTab, showSetMark, dressAlpha }.
-- `showSetMark` is retained at `false` for back-compat readers; the set cue is `setBorder`.
function Items.ResolveState(ctx)
    ctx = ctx or {}
    local dimmed = ctx.dimmed and true or false
    local unusable = ctx.isUnusable and true or false
    -- A starter is always a quest item, even if the caller only set the starter flag.
    local starter = ctx.isQuestStarter and true or false
    local quest   = (ctx.isQuest or starter) and true or false
    local set     = ctx.isSet and true or false
    -- EMPTY cell: the caller says so explicitly, or (back-compat with every existing
    -- caller) a nil quality on a cell that was not declared filled.
    local emptySlot = ctx.emptySlot
    if emptySlot == nil then emptySlot = (ctx.quality == nil and ctx.filled ~= true) end
    emptySlot = emptySlot and true or false
    -- 1.x icon treatment: full colour unless the SEARCH miss dims it. Junk is not a
    -- treatment (item.lua:170 restores vertex colour on every update).
    local icon = dimmed and "dimmed" or "normal"
    local questBorder = (quest and not dimmed)
    local redBorder   = (unusable and not dimmed and not questBorder)
    return {
        icon         = icon,
        iconDesat    = dimmed,                   -- ONLY the search dim (1.x item.lua:234)
        -- 1.0 glowQuest: gold border, 1.x's first branch â€” it wins over the unusable red.
        questBorder  = questBorder,
        -- 1.0 glowUnusable: red border, icon full-color. Yields to the quest gold.
        redBorder    = redBorder,
        -- 1.0 glowSets: teal border, below the unusable red and above the rarity colour.
        setBorder    = (set and not dimmed and not questBorder and not redBorder),
        -- 1.0 glowPoor: the template's vendor-coin overlay on a poor item that HAS value
        -- (item.lua:222 `quality == 0 and not info.hasNoValue`). The caller supplies
        -- hasNoValue; an unknown (cached/offline) value reads as "has value", exactly as
        -- 1.x's nil-valued cached info does.
        junkCoin     = (ctx.quality == 0 and not ctx.hasNoValue and not dimmed) and true or false,
        unusableTint = false,                    -- retired (1.x kept the icon full-color)
        showNewDot   = (ctx.isNew and not dimmed) and true or false,
        -- 1.x reserves the bang glyph for quest STARTERS; ordinary quest items get the tint.
        showQuestTab = (starter and not dimmed) and true or false,
        showSetMark  = false,                    -- retired: the set cue is setBorder (1.x)
        dressAlpha   = Items.DressAlpha(dimmed),
        -- 1.x item.lua:167 â€” the icon's OWN alpha, independent of the search dim: 1 on a
        -- filled cell, the profile's slotAlpha on an empty one. _applyDress multiplies the
        -- two, exactly as 1.x's icon alpha and button alpha multiply on screen.
        emptySlot    = emptySlot,
        iconAlpha    = emptySlot and Items.SlotAlpha() or 1,
    }
end

-- =====================================================================
-- PURE: class equip PROFICIENCY (clean-room; restores the 1.x glowUnusable rule)
--
-- ROOT CAUSE this replaces: the beta's slotIsUnusable read C_Item.IsUsableItem,
-- which for armor/weapons answers "can I right-click USE this now" â€” it returns
-- FALSE for equippable gear the character can wear, so nearly ALL gear desaturated
-- ("grey washed"). 1.x drove glowUnusable from Unfit-1.0 (class weapon/armor
-- PROFICIENCY via GetItemInfoInstant), never IsUsableItem. This restores that real
-- rule fresh: an item washes ONLY when the CHARACTER CLASS can never equip its
-- weapon/armor subclass (or, per the owner ask, when it is below its required
-- level). Item classes that are neither Weapon nor Armor (consumables, trade
-- goods, quest, reagentsâ€¦) never enter this path â€” they can't be "unequippable".
--
-- Numeric Enum.ItemClass / Enum.ItemWeaponSubclass / Enum.ItemArmorSubclass values
-- (Classic Era 1.15) so the logic is pure (no live Enum global); the frame layer
-- feeds classID/subclassID/equipLoc from GetItemInfoInstant, which resolves from
-- static data for any valid itemID immediately (stable on the first paint).
-- =====================================================================

Items.ITEMCLASS_WEAPON = 2
Items.ITEMCLASS_ARMOR  = 4

-- weapon subclass ids (Classic)
local W = { AXE1H=0, AXE2H=1, BOW=2, GUN=3, MACE1H=4, MACE2H=5, POLEARM=6,
            SWORD1H=7, SWORD2H=8, WARGLAIVE=9, STAFF=10, FIST=13, DAGGER=15,
            THROWN=16, CROSSBOW=18, WAND=19 }
-- armor subclass ids (Classic)
local A = { CLOTH=1, LEATHER=2, MAIL=3, PLATE=4, SHIELD=6 }

local function set(...)
    local t = {}
    for _, v in ipairs({ ... }) do t[v] = true end
    return t
end

-- Per Classic-Era class: the weapon + armor subclasses it can NEVER equip, and
-- cannotDual (an OFFHAND-ONLY weapon is then unusable). Mirrors the 1.x Unfit tables
-- for the nine Era classes (no DK/DH/Evoker/Monk exist in Era). cannotDual reflects
-- the vanilla rule: only Warrior/Rogue/Hunter can dual-wield (trained skill).
Items.PROFICIENCY = {
    WARRIOR = { weapon = set(W.WARGLAIVE, W.WAND), armor = set(), cannotDual = false },
    PALADIN = { weapon = set(W.BOW, W.GUN, W.WARGLAIVE, W.STAFF, W.FIST, W.DAGGER, W.THROWN, W.CROSSBOW, W.WAND), armor = set(), cannotDual = true },
    HUNTER  = { weapon = set(W.MACE1H, W.MACE2H, W.WARGLAIVE, W.THROWN, W.WAND), armor = set(A.PLATE, A.SHIELD), cannotDual = false },
    ROGUE   = { weapon = set(W.AXE2H, W.MACE2H, W.POLEARM, W.SWORD2H, W.WARGLAIVE, W.STAFF, W.WAND), armor = set(A.MAIL, A.PLATE, A.SHIELD), cannotDual = false },
    PRIEST  = { weapon = set(W.AXE1H, W.AXE2H, W.BOW, W.GUN, W.MACE2H, W.POLEARM, W.SWORD1H, W.SWORD2H, W.WARGLAIVE, W.FIST, W.THROWN, W.CROSSBOW), armor = set(A.LEATHER, A.MAIL, A.PLATE, A.SHIELD), cannotDual = true },
    MAGE    = { weapon = set(W.AXE1H, W.AXE2H, W.BOW, W.GUN, W.MACE1H, W.MACE2H, W.POLEARM, W.SWORD2H, W.WARGLAIVE, W.FIST, W.THROWN, W.CROSSBOW), armor = set(A.LEATHER, A.MAIL, A.PLATE, A.SHIELD), cannotDual = true },
    WARLOCK = { weapon = set(W.AXE1H, W.AXE2H, W.BOW, W.GUN, W.MACE1H, W.MACE2H, W.POLEARM, W.SWORD2H, W.WARGLAIVE, W.FIST, W.THROWN, W.CROSSBOW), armor = set(A.LEATHER, A.MAIL, A.PLATE, A.SHIELD), cannotDual = true },
    DRUID   = { weapon = set(W.AXE1H, W.AXE2H, W.BOW, W.GUN, W.SWORD1H, W.SWORD2H, W.WARGLAIVE, W.THROWN, W.CROSSBOW, W.WAND), armor = set(A.MAIL, A.PLATE, A.SHIELD), cannotDual = true },
    SHAMAN  = { weapon = set(W.BOW, W.GUN, W.POLEARM, W.SWORD1H, W.SWORD2H, W.WARGLAIVE, W.THROWN, W.CROSSBOW, W.WAND), armor = set(A.PLATE), cannotDual = true },
}

-- Pure: can this class token NEVER equip this item? classID/subclassID/equipLoc come
-- from GetItemInfoInstant. equipLoc "" (not equippable) or a non-weapon/armor class
-- => usable (false). Unknown class token => never wash (safety).
function Items.ClassCannotEquip(classToken, classID, subclassID, equipLoc)
    local prof = classToken and Items.PROFICIENCY[classToken]
    if not prof then return false end
    if not equipLoc or equipLoc == "" then return false end     -- not equippable => usable
    if classID == Items.ITEMCLASS_WEAPON then
        if prof.weapon[subclassID] then return true end
        if equipLoc == "INVTYPE_WEAPONOFFHAND" and prof.cannotDual then return true end
        return false
    elseif classID == Items.ITEMCLASS_ARMOR then
        return prof.armor[subclassID] and true or false
    end
    return false                                                 -- neither weapon nor armor
end

-- Pure: additive per owner ask â€” an EQUIPPABLE item whose required level exceeds the
-- character level reads unusable (native "requires level N"). Bags/ammo/non-equippable
-- are exempt; an unknown (server-uncached) minLevel never washes (re-evaluated on the
-- pending repaint once GetItemInfo resolves).
Items.NONLEVEL_EQUIPLOC = { INVTYPE_BAG = true, INVTYPE_AMMO = true }
function Items.IsBelowLevel(equipLoc, minLevel, playerLevel)
    if not equipLoc or equipLoc == "" then return false end
    if Items.NONLEVEL_EQUIPLOC[equipLoc] then return false end
    if not minLevel or minLevel <= 1 then return false end
    if not playerLevel then return false end
    return playerLevel < minLevel
end

-- "cached 3d ago" tooltip line from an age in seconds (nil for a fresh/unknown age).
function Items.FormatCachedAge(seconds)
    if not seconds or seconds < 0 then return nil end
    if seconds < 60    then return "cached just now" end
    if seconds < 3600  then return string.format("cached %dm ago", math.floor(seconds / 60)) end
    if seconds < 86400 then return string.format("cached %dh ago", math.floor(seconds / 3600)) end
    return string.format("cached %dd ago", math.floor(seconds / 86400))
end

-- =====================================================================
-- FRAME LAYER (in-game only)
-- =====================================================================

-- Self identity (which owner's bags are the live, interactive ones). Set at login
-- via Items.SetSelf; derived lazily from UnitName/GetRealmName if unset.
function Items.SetSelf(nameRealm) Items._self = nameRealm end

-- Live player class token ("WARRIOR", â€¦) for the proficiency gate. Set at login via
-- Items.SetPlayerClass; derived lazily from UnitClass if unset. Cached (class never
-- changes mid-session).
function Items.SetPlayerClass(token) Items._playerClass = token end
local function playerClassToken()
    if Items._playerClass then return Items._playerClass end
    if _G.UnitClass then
        local _, token = _G.UnitClass("player")
        Items._playerClass = token
    end
    return Items._playerClass
end
local function playerLevelNow()
    if _G.UnitLevel then return _G.UnitLevel("player") end
    return Items._playerLevel
end

function Items.IsLive(owner)
    if not owner or owner.source ~= "full" then return false end
    if not Items._self and _G.UnitName and _G.GetRealmName then
        local realm = ((_G.GetRealmName() or ""):gsub("%s+", ""))
        Items._self = Store.MakeNameRealm(_G.UnitName("player"), realm)
    end
    return owner.nameRealm ~= nil and owner.nameRealm == Items._self
end

-- Injected-live resolver from the game globals (C_Item namespace; catalog-verified).
local function liveResolver()
    local CI = _G.C_Item or {}
    return {
        instant = CI.GetItemInfoInstant or _G.GetItemInfoInstant,
        info    = CI.GetItemInfo        or _G.GetItemInfo,
    }
end

local function mutedRGB()
    if _G.DaseekiUI and _G.DaseekiUI.Color then return _G.DaseekiUI.Color("muted") end
    return 0.60, 0.56, 0.47
end

-- Token color with a hardcoded fallback (so per-slot dress still tints sensibly if
-- DaseekiUI is somehow absent). Colors are read at button CREATION and baked into the
-- dress (no per-cell ThemeChanged hook â€” 100+ hooks are the per-frame cost C vetoes;
-- the quality edge, which re-reads the live provider each paint, carries live rarity).
local TOKEN_FALLBACK = {
    inset      = { 0.0706, 0.0627, 0.0471 }, -- #12100C sunken well (EMPTY cell)
    raised     = { 0.1490, 0.1294, 0.0980 }, -- #262119 raised card (FILLED cell)
    border     = { 0.2353, 0.2039, 0.1490 }, -- #3C3426 hairline (the 1px cell border)
    borderLite = { 0.3020, 0.2627, 0.1922 }, -- #4D4331 lighter hairline (hover wash)
    text       = { 0.9137, 0.8784, 0.8039 },
    brand      = { 0.7529, 0.2824, 0.2353 }, -- crimson wax (Field Ledger)
    warn       = { 0.9600, 0.7600, 0.1800 },
    danger     = { 0.8118, 0.3647, 0.2902 },
    -- Core-less parity (latent white-square bug): tokenRGB returns {1,1,1} for an unknown
    -- key, so any token used by the dress that was NOT listed here rendered PURE WHITE on
    -- an install without Daseeki-Core (which is OptionalDeps, not Dependencies). `bronze`
    -- is the set marker; `idle` is used by the owner selector. Values mirror
    -- Daseeki-Core/theme.lua's Field Ledger defaults (bronze = accentDim, idle = faint).
    bronze     = { 0.5412, 0.4471, 0.2235 }, -- metallic keyline / ornament
    idle       = { 0.4275, 0.3922, 0.3137 }, -- calm / owned neutral
}
local function tokenRGB(name)
    if _G.DaseekiUI and _G.DaseekiUI.Color then return _G.DaseekiUI.Color(name) end
    local c = TOKEN_FALLBACK[name] or { 1, 1, 1 }
    return c[1], c[2], c[3]
end
Items._tokenRGB = tokenRGB   -- exposed so the harness can prove the Core-less fallbacks

-- Subtle danger tint for an UNUSABLE icon: danger mixed toward white so a desaturated
-- (greyscale) icon reads warm-red â€” the classic "can't use" cue â€” not a solid red block.
local function unusableTintRGB()
    local dr, dg, db = tokenRGB("danger")
    local m = 0.45
    return dr + (1 - dr) * m, dg + (1 - dg) * m, db + (1 - db) * m
end

local function iconOf(button)
    return button.icon or (button.GetName and _G[(button:GetName() or "") .. "IconTexture"]) or nil
end

----------------------------------------------------------------------
-- Async pending registry (GET_ITEM_INFO_RECEIVED)
----------------------------------------------------------------------

Items._pending = Items._pending or {}   -- [itemID] = weak set of buttons awaiting data

local function ensureEventFrame()
    if Items._evt or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(_, _, itemID)
        local set = Items._pending[itemID]
        if not set then return end
        Items._pending[itemID] = nil
        for btn in pairs(set) do
            if btn._dsRepaint then btn:_dsRepaint() end
        end
    end)
    Items._evt = f
end

local function watchPending(button, itemID)
    Items._pending[itemID] = Items._pending[itemID] or setmetatable({}, { __mode = "k" })
    Items._pending[itemID][button] = true
    ensureEventFrame()
    if _G.C_Item and _G.C_Item.RequestLoadItemDataByID then
        _G.C_Item.RequestLoadItemDataByID(itemID)
    end
end

----------------------------------------------------------------------
-- Button paint helpers
----------------------------------------------------------------------

----------------------------------------------------------------------
-- STATE layer (Layer 2): live-fact detection for the per-slot markers.
-- All three read the LIVE container/item APIs and are meaningful only for the logged-in
-- character's own bags (button._live). Offline/remote owners get no state markers (they
-- have no live new/quest/usable state) â€” junk calm still applies via captured quality.
----------------------------------------------------------------------

-- NEW-ITEM: C_NewItems is the game's own new-item set (1.x drove glowNew from it). The
-- wax dot shows while a slot is new; MarkSeen clears it on interaction (below).
local function slotIsNew(button)
    local CN = _G.C_NewItems
    if not (CN and CN.IsNewItem and button._cid and button._slot) then return false end
    return CN.IsNewItem(button._cid, button._slot) and true or false
end

-- QUEST: container quest info, split into the two 1.x cues. Returns `isQuest, isStarter`
-- (see Items.QuestFlags for the exact 1.x rule): every quest item takes the gold border,
-- and only a quest STARTER also takes the bang glyph.
local function slotQuestFlags(button)
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemQuestInfo and button._cid and button._slot) then return false, false end
    return Items.QuestFlags(CC.GetContainerItemQuestInfo(button._cid, button._slot))
end

-- UNUSABLE: 1.x glowUnusable parity via CLASS PROFICIENCY (Items.ClassCannotEquip),
-- NOT C_Item.IsUsableItem (which washed all equippable gear grey â€” the beta defect).
-- GetItemInfoInstant resolves classID/subclassID/equipLoc from static data for any
-- valid itemID immediately, so the proficiency verdict is stable on the first paint.
-- The additive below-level gate uses GetItemInfo's minLevel (async â€” nil => not washed
-- until known; the pending repaint re-evaluates once the server responds).
local function slotIsUnusable(button)
    local id = button._data and button._data.id
    if not id then return false end
    local gii = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not gii then return false end
    local _, _, _, equipLoc, _, classID, subclassID = gii(id)
    if Items.ClassCannotEquip(playerClassToken(), classID, subclassID, equipLoc) then
        return true
    end
    local gi = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    if gi then
        local _, _, _, _, minLevel = gi(id)
        if Items.IsBelowLevel(equipLoc, minLevel, playerLevelNow()) then return true end
    end
    return false
end

-- ====================================================================================
-- EQUIPMENT-SET teal â€” the cue that regressed, and why it is now OPT-IN.
--
-- WHAT 1.x ACTUALLY DOES ON THIS CLIENT. 1.x's set branch (core/classes/item.lua:201,
-- `Addon.sets.glowSets and Search:BelongsToSet(id)`) is fed by ItemSearch-1.3, and that
-- library binds BelongsToSet by client + environment:
--
--   Daseeki-Bags/libs/ItemSearch-1.3/API.lua:113   if IsAddOnLoaded('ItemRack') then ...
--   Daseeki-Bags/libs/ItemSearch-1.3/API.lua:128   elseif LE_EXPANSION_LEVEL_CURRENT
--                                                       > LE_EXPANSION_CLASSIC then ...
--   Daseeki-Bags/libs/ItemSearch-1.3/API.lua:145-146  else Lib.BelongsToSet = nop
--
-- On Classic Era LE_EXPANSION_LEVEL_CURRENT IS LE_EXPANSION_CLASSIC, so the middle arm is
-- dead, and the owner's AddOns.txt records `ItemRack: disabled`. His 1.x therefore takes
-- the `nop` arm: BelongsToSet always returns nil and 1.x paints ZERO set teal, ever.
--
-- WHAT THE PARITY ROUND SHIPPED. It transcribed the branch faithfully but wired it to a
-- source 1.x never reads â€” Daseeki-Armory's saved gear sets â€” and defaulted it ON. The
-- owner keeps 9 sets per raiding character naming 63 distinct item ids; measured against
-- his live SavedVariables, 47 of Poonyx's 156 filled bag cells (30%) match, and because
-- the set branch outranks rarity (borders.lua:191) every one of those cells LOSES its
-- purple/blue rarity halo and turns teal. That is the "teal on nearly every item" report:
-- not a broken predicate, a cue 1.x does not draw at all, applied to a third of the bag.
--
-- THE FIX IS TWO PARTS.
--   1. DEFAULT OFF (db.setMarkers absent => OFF). Off is what his 1.x renders, so the
--      shipped default is now byte-for-byte his 1.x appearance. The toggle stays, because
--      the Armory bridge is a genuinely useful 2.0 feature â€” it is just not parity.
--   2. A STRICTER, PURE predicate (below): 1.x/ItemSearch only ever answers true for an
--      EQUIPPABLE item, and only when a set actually NAMES that item id in a slot that set
--      has not disabled. No Armory, no sets, an empty sets table, a malformed entry â€” all
--      false, with no error surfaced to the paint path.
--
-- Like new/quest, this is meaningful only for live self bags: Armory's sets are
-- SavedVariablesPerCharacter, so a cached alt's bags have no set data to consult.
-- ====================================================================================

-- LIVE: is the equipment-set cue switched on? Absent key => OFF (1.x parity, see above).
function Items.SetCueEnabled()
    local db = ns.Store and ns.Store.db
    return (db ~= nil and db.setMarkers == true)
end

-- PURE: does a Daseeki-Armory database NAME `itemID` in one of its saved sets?
--
-- Armory shape (Daseeki-Armory/core.lua:59, sets.lua:143-149):
--   db.sets[<name>] = { name=, icon=, order=, equip = { [slotId] = { id=, exact=, str= } },
--                       disabled = { [slotId] = true } }
-- so the id lives at db.sets[name].equip[slotId].id â€” an ID-KEYED-BY-SLOT map, never a
-- flat list. A slot listed in `disabled` is one the set deliberately does not equip, so an
-- item parked there is NOT a member. Every level is type-guarded: this walks foreign
-- SavedVariables and must never throw into a paint.
--
-- Returns true/false only â€” it never leaks the Armory tables to the caller.
function Items.ArmoryNamesItem(armoryDb, itemID)
    if type(armoryDb) ~= "table" or type(itemID) ~= "number" then return false end
    local sets = armoryDb.sets
    if type(sets) ~= "table" then return false end
    for _, set in pairs(sets) do
        if type(set) == "table" and type(set.equip) == "table" then
            local disabled = type(set.disabled) == "table" and set.disabled or nil
            for slotId, e in pairs(set.equip) do
                if type(e) == "table" and e.id == itemID
                    and not (disabled and disabled[slotId]) then
                    return true
                end
            end
        end
    end
    return false
end

-- PURE: 1.x/ItemSearch gates the whole set branch on IsEquippableItem (API.lua:115/130).
-- Ours derives the same fact from GetItemInfoInstant's equipLoc, which the proficiency
-- path already reads â€” a non-empty, non-BAG equip location means the item goes on the
-- character, which is the only kind of thing a gear set can contain.
function Items.IsEquippableLoc(equipLoc)
    if type(equipLoc) ~= "string" or equipLoc == "" then return false end
    if equipLoc == "INVTYPE_BAG" then return false end
    return true
end

local function slotIsSet(button)
    if not Items.SetCueEnabled() then return false end       -- default OFF (1.x parity)
    local id = button._data and button._data.id
    if type(id) ~= "number" then return false end

    -- 1.x's equippable gate. GetItemInfoInstant resolves from static data, so this is
    -- stable on the first paint; an unresolvable id simply never gets the cue.
    local gii = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not gii then return false end
    local ok, _, _, _, equipLoc = pcall(gii, id)
    if not (ok and Items.IsEquippableLoc(equipLoc)) then return false end

    local A = _G.DaseekiArmory
    if type(A) ~= "table" or type(A.db) ~= "table" then return false end
    local named
    ok, named = pcall(Items.ArmoryNamesItem, A.db, id)
    return (ok and named) and true or false
end

-- Clear the new-item mark on interaction (1.x MarkSeen fact: RemoveNewItem on seen).
-- Wired as an insecure OnEnter post-hook on live buttons (hover-to-clear) so the secure
-- click path is never touched. RemoveNewItem is not a protected op.
function Items.MarkSeen(button)
    if not button._live then return end
    local CN = _G.C_NewItems
    if CN and CN.RemoveNewItem and button._cid and button._slot then
        CN.RemoveNewItem(button._cid, button._slot)
    end
    if button._dsNewDot then button._dsNewDot:Hide() end
end

-- Apply a resolved STATE spec to a button's dress. Operates ONLY on child textures/
-- frames/fontstrings + the icon sub-texture â€” never a protected op on the secure button.
-- This is also the DIM CASCADE: `spec.dressAlpha` recedes the icon, quality edge, count
-- numeral AND both markers together, so a search-dimmed slot fully recedes (no bright
-- quality rim or crimson dot floating over a non-match).
function Items._applyDress(button, spec)
    local a = spec.dressAlpha

    -- icon: alpha + desaturation + (unusable) subtle danger tint
    --
    -- 1.x item.lua:167 sets the icon to `hasItem and 1 or slotAlpha`, and then dims the
    -- WHOLE button on a search miss (item.lua:233), so the two multiply. spec.iconAlpha
    -- carries that product: full on a filled cell, the profile's slotAlpha on an empty one.
    local icon = iconOf(button)
    if icon then
        if icon.SetAlpha then icon:SetAlpha(a * (spec.iconAlpha or 1)) end
        if icon.SetDesaturated then icon:SetDesaturated(spec.iconDesat) end
        if icon.SetVertexColor then
            if spec.unusableTint then icon:SetVertexColor(unusableTintRGB())
            else icon:SetVertexColor(1, 1, 1) end
        end
    end
    if _G.SetItemButtonDesaturated then _G.SetItemButtonDesaturated(button, spec.iconDesat) end

    -- quality edge (Layer 1) recedes with the dim
    if ns.Borders and ns.Borders.SetAlpha then ns.Borders.SetAlpha(button, a) end

    -- 1.x SLOT BORDER: re-asserted from the live profile colour on every dress, and
    -- cascaded with the dim (1.x dims it too â€” it dims the entire button).
    if Items._applySlotBorder then Items._applySlotBorder(button) end
    if button._dsSlotBorder and button._dsSlotBorder.SetAlpha then
        button._dsSlotBorder:SetAlpha(a)
    end

    -- count numeral recedes with the dim
    if button._dsCount and button._dsCount.SetAlpha then button._dsCount:SetAlpha(a) end

    -- keep the template's native quest region suppressed (we draw the bang ourselves, on
    -- an addon-owned region the kill sweep can't reach)
    if button._dsNativeQuest then button._dsNativeQuest:Hide() end

    -- NEW-ITEM wax dot: one-shot 120ms fade-in on the rising edge (arrival), then still.
    -- No OnUpdate/loop; shown frames only. Hidden entirely while dimmed.
    local dot = button._dsNewDot
    if dot then
        if spec.showNewDot then
            if not (dot.IsShown and dot:IsShown()) then
                local UI = _G.DaseekiUI
                if UI and UI.Animate and UI.Animate.FadeIn then UI.Animate.FadeIn(dot, 120)
                else dot:SetAlpha(1); dot:Show() end
            else
                dot:SetAlpha(a)
            end
        else
            dot:Hide()
        end
    end

    -- QUEST bang glyph
    local tab = button._dsQuestTab
    if tab then
        if spec.showQuestTab then tab:SetAlpha(a); tab:Show() else tab:Hide() end
    end

    -- JUNK COIN â€” the template's own JunkIcon, driven exactly as 1.x drives it
    -- (item.lua:222). This replaces the greyscale junk icon: 1.x keeps the icon in full
    -- colour and puts a small vendor coin on the cell instead.
    local junk = button.JunkIcon
        or (button.GetName and _G and _G[(button:GetName() or "") .. "JunkIcon"])
    if junk then
        if spec.junkCoin then
            if junk.SetAlpha then junk:SetAlpha(a) end
            if junk.Show then junk:Show() end
        else
            if junk.SetAlpha then junk:SetAlpha(0) end
            if junk.Hide then junk:Hide() end
        end
    end
end

-- Detect the live facts, resolve the state spec, and apply it. Also the SetDimmed target.
local function applyDressState(button)
    local live = button._live and true or false
    local hasItem = button._data and button._data.id ~= nil
    local isNew, isQuest, isStarter, isUnusable, isSet = false, false, false, false, false
    if hasItem and live then
        isNew      = slotIsNew(button)
        if button._isSet ~= nil then isSet = button._isSet else isSet = slotIsSet(button) end
        -- reuse the verdicts paintButton already computed (avoids a second proficiency/level
        -- scan and a second quest query); recompute only if this path ran standalone.
        if button._questItem ~= nil then isQuest, isStarter = button._questItem, button._questStarter
        else isQuest, isStarter = slotQuestFlags(button) end
        if button._unusable ~= nil then isUnusable = button._unusable else isUnusable = slotIsUnusable(button) end
    end
    local spec = Items.ResolveState({
        quality        = button._quality,
        dimmed         = button._dimmed,
        isNew          = isNew,
        isQuest        = isQuest,
        isQuestStarter = isStarter,
        isUnusable     = isUnusable,
        isSet          = isSet,
        hasNoValue     = button._hasNoValue,
        filled         = hasItem,
        emptySlot      = not hasItem,
    })
    button._isSet = isSet
    Items._applyDress(button, spec)
end

----------------------------------------------------------------------
-- SORT-LOCK CONFIG LAYER  (locks.lua; entered by right-clicking the sort glyph)
--
-- Two addon-owned pieces per cell, both created LAZILY the first time the mode opens,
-- so a session that never uses the feature pays nothing:
--
--   _dsLockMark   an OVERLAY texture on the whole cell — the prohibition sign
--                 (art/icon-lock-slot.tga) tinted `danger`. Shown ONLY while the mode
--                 is open, exactly like 1.x's IgnoredOverlay (item.lua:237-240): the
--                 mark is a configuration affordance, not a permanent cell decoration.
--
--   _dsLockCatch  an INSECURE Button covering the cell at a higher frame level. While
--                 it is shown it takes every mouse event, so the secure container
--                 button underneath receives NOTHING — no pickup, no split, no use, no
--                 drag, no tooltip. That is how "normal item interaction is suspended"
--                 is implemented, and it is 1.x's own trick (its shared `Item.Dummy`,
--                 item.lua:262-266) with the hover race removed: 1.x only raised the
--                 dummy on OnEnter, so a click on a cell the cursor was ALREADY sitting
--                 on went to the real slot. Ours is up for every visible cell the
--                 instant the mode opens.
--
-- Restoring on exit is the same code path in reverse (hide both), so there is exactly
-- one implementation of "put the window back" and it cannot drift between the
-- right-click / Escape / window-close exits.
--
-- LIVE CELLS ONLY. Locks are per-character and only mean anything for containers the
-- sort engine can actually touch, so a cached/offline owner's grid is never editable.
----------------------------------------------------------------------

Items.TEX_LOCK_SLOT = "Interface\\AddOns\\" .. tostring(ADDON) .. "\\art\\icon-lock-slot"

-- Every button ever created, weak-keyed so a pooled-away button is collectable.
-- Used only to sweep the lock layer on a mode transition.
Items._buttons = Items._buttons or setmetatable({}, { __mode = "k" })

local function lockDangerRGB()
    local UI = _G.DaseekiUI
    if UI and UI.Color then return UI.Color("danger") end
    return 0.85, 0.15, 0.15
end

local function lockTooltip(button)
    local GT = _G.GameTooltip
    if not GT or not GT.SetOwner then return end
    local L = ns.Locks
    local locked = L and L.IsLocked(button._cid, button._slot)
    GT:SetOwner(button, "ANCHOR_RIGHT")
    if GT.ClearLines then GT:ClearLines() end
    local r, g, b = 1, 1, 1
    local UI = _G.DaseekiUI
    if UI and UI.Color then r, g, b = UI.Color("text") end
    GT:SetText(locked and "Locked for sorting" or "Not locked", r, g, b)
    local mr, mg, mb = mutedRGB()
    if GT.AddLine then
        GT:AddLine(locked and "A sort will never move this slot."
                           or "A sort may move whatever is here.", mr, mg, mb, true)
        GT:AddLine(locked and "Click to unlock." or "Click to lock.", mr, mg, mb)
    end
    if GT.Show then GT:Show() end
end

local function ensureLockLayer(button)
    if button._dsLockCatch or not _G.CreateFrame then return end

    local mark = button:CreateTexture(nil, "OVERLAY", nil, 6)
    mark:SetTexture(Items.TEX_LOCK_SLOT)
    mark:SetAllPoints(button)
    mark:SetVertexColor(lockDangerRGB())
    mark:Hide()
    button._dsLockMark = mark

    local catch = _G.CreateFrame("Button", nil, button)
    catch:SetAllPoints(button)
    if catch.SetFrameLevel then catch:SetFrameLevel((button:GetFrameLevel() or 1) + 10) end
    if catch.RegisterForClicks then catch:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    catch:SetScript("OnClick", function(self)
        local b = self:GetParent()
        local L = ns.Locks
        if not (L and L.ToggleSlot and b._cid and b._slot) then return end
        local nowLocked = L.ToggleSlot(b._cid, b._slot)
        -- The canonical checkbox pair — this IS a checkbox, one per cell. (House
        -- pattern: named SOUNDKIT constant with the FrameXML numeric id as the guard.)
        if _G.PlaySound and _G.SOUNDKIT then
            _G.PlaySound(nowLocked and (_G.SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                                    or (_G.SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or 857))
        end
        lockTooltip(b)   -- the cursor has not moved; refresh the state line under it
    end)
    catch:SetScript("OnEnter", function(self) lockTooltip(self:GetParent()) end)
    catch:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    catch:Hide()
    button._dsLockCatch = catch
end

-- Apply the current lock-mode state to ONE button. Idempotent; safe on any button in
-- any state, and creates nothing while the mode is closed.
local function applyLockLayer(button)
    local L = ns.Locks
    local active = (L and L.IsActive and L.IsActive()) and button._live
                   and button._cid ~= nil and button._slot ~= nil
    if not active then
        if button._dsLockMark then button._dsLockMark:Hide() end
        if button._dsLockCatch then button._dsLockCatch:Hide() end
        return
    end
    ensureLockLayer(button)
    if not button._dsLockCatch then return end   -- headless
    button._dsLockMark:SetVertexColor(lockDangerRGB())
    button._dsLockMark:SetShown(L.IsLocked(button._cid, button._slot))
    button._dsLockCatch:Show()
end
Items._applyLockLayer = applyLockLayer

-- Sweep every live button. Called on a lock-mode transition and whenever the lock SET
-- changes, so entering/leaving the mode is a single call from ui_frame.
function Items.RefreshLockLayer()
    for b in pairs(Items._buttons) do
        if b.IsObjectType or b._live ~= nil then applyLockLayer(b) end
    end
end

-- LIVE fact behind 1.x's glowPoor gate (item.lua:222 `not self.info.hasNoValue`): a poor
-- item a vendor will not buy carries no coin. Only the live container API knows it; a
-- cached/offline slot returns nil, which reads as "has value" â€” exactly what 1.x's cached
-- info does, since it never populates the field either.
local function slotHasNoValue(button)
    if not button._live then return nil end
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemInfo and button._cid and button._slot) then return nil end
    local info = CC.GetContainerItemInfo(button._cid, button._slot)
    return info and info.hasNoValue or nil
end
Items._slotHasNoValue = slotHasNoValue

local function updateCooldown(button)
    local cd = button.Cooldown or button.cooldown
        or (button.GetName and _G[(button:GetName() or "") .. "Cooldown"])
    if not cd then return end
    local CC = _G.C_Container
    if not (CC and CC.GetContainerItemCooldown) then return end
    local start, duration, enable = CC.GetContainerItemCooldown(button._cid, button._slot)
    if _G.CooldownFrame_Set then
        _G.CooldownFrame_Set(cd, start or 0, duration or 0, enable or 0)
    elseif cd.SetCooldown then
        if (enable or 0) ~= 0 and (duration or 0) > 0 then cd:SetCooldown(start, duration)
        elseif cd.Clear then cd:Clear() end
    end
end

-- CELL PARITY: the stack-count numeral is the TEMPLATE's, untouched â€” 1.x never restyles
-- it (core/classes/item.lua:168 is a bare `SetItemButtonCount(self, stackCount)` and there
-- is no font/colour/anchor call anywhere in the file). The previous round re-fonted it to
-- ARIALN+OUTLINE in cream and pulled it 3px in from the template's own corner, on the
-- reasoning that the default "glares on the dark well" â€” but there is no dark well any
-- more, and the owner's target is the default numeral he already looks at in 1.x.
--
-- We still BIND the region, because the dim cascade has to be able to recede it with the
-- rest of the dress; binding is all this does now.
local function bindCount(button)
    local count = button.Count
        or (button.GetName and _G[(button:GetName() or "") .. "Count"])
    if not count then return end
    button._dsCount = count
end

-- =====================================================================
-- TEMPLATE-ART KILL-LIST â€” the load-bearing defensive layer
-- =====================================================================
-- INSTITUTIONAL LESSON (why the previous single-shot neutralize failed): killing the
-- template art ONCE at creation is not enough. ContainerFrameItemButtonTemplate /
-- ItemButtonTemplate re-apply their art AFTER creation â€” SetItemButton* helpers, the
-- template's own OnShow, and quality/new-item update paths re-SHOW NormalTexture /
-- IconBorder / NewItemTexture and re-start the flash/glow anims. Any build that verifies
-- the kill only at creation is verifying a state the game overwrites on the owner's screen.
--
-- So this is DEFENSIVE BY CONSTRUCTION, three redundant layers:
--   (1) an EXHAUSTIVE kill sweep (Items._killTemplateArt) that unconditionally hides every
--       art region both templates own and stops the glow anims â€” idempotent, cheap, pure
--       texture/anim ops;
--   (2) GLOBAL hooksecurefunc post-hooks on the resurrection helpers (SetItemButtonTexture
--       / SetItemButtonQuality / SetItemButtonCount) that re-sweep OUR buttons the instant
--       the game touches them, plus a per-button OnShow HookScript re-sweep;
--   (3) a re-kill sweep at the top of our OWN paint (paintButton) so a repaint can never
--       leave resurrected art on screen.
-- The ONLY visible slot art after this is OURS (well + quality edge + markers + count).
--
-- Every entry has a REASON (the owner asked "no blue anywhere"; each is a blue/bright vector):
--   NormalTexture      UI-Quickslot2 bluish-lavender ring â€” empty-cell blue glow (defect #1)
--                      + filled-cell blue-purple rim (defect #2). Killed + SetNormalTexture(nil).
--                      This is the one region 1.x also kills (item.lua:51-52).
--   NewItemTexture     the "new loot" flash sheet (blue/gold burst) â€” our crimson wax dot replaces it.
--                      1.x kills this one too (item.lua:49).
--   flashAnim /        AnimationGroups that PULSE NewItemTexture's alpha back up â€” stopped, or
--   newitemglowAnim    the sheet we just hid re-animates itself bright next frame.
--   BattlepayItemTexture  cash-shop swirl â€” irrelevant in Classic bags, hidden for safety.
--                      1.x kills this one too (item.lua:48).
--   UpgradeIcon        green upgrade arrow (may be absent in Classic) â€” off; we don't upsell.
--   IconOverlay(2)     azerite/corruption ring (retail-only; absent in Classic) â€” off if present.
--   SearchOverlay      the template's OWN dark search dim â€” we run our own dim cascade; killing
--                      it prevents a double-dark muddy overlay (a "dull" contributor).
--   IconQuestTexture   the template's quest region â€” killed because the sweep re-hides it
--                      on every repaint; we paint the SAME bang art on our own region.
--   Stock              merchant stock count â€” never valid in bags, hidden.
--   Cooldown edge/bling  the cooldown swipe's bright edge ring + finish flash â€” quieted
--                      (SetDrawEdge/SetDrawBling false); the dark swipe itself stays (ours).
--
-- CELL PARITY â€” TWO REGIONS LEFT THE KILL LIST, because 1.x DRIVES them rather than killing
-- them, and both are load-bearing for the look the owner is comparing against:
--   IconBorder   1.x re-tints it to the glow colour and shows it on exactly the glowing
--                cells (item.lua:194/210/220). It is the crisp ring that anchors the soft
--                67px wash to its own cell; without it the halo reads as an unanchored
--                colour bloom over the gutters. Owned by borders.SetIconBorder, which sets
--                its state on EVERY paint, so there is no window where Blizzard's own
--                full-saturation ring survives a repaint.
--   JunkIcon     1.x shows the vendor coin on poor items that have value (item.lua:222) and
--                keeps the icon in FULL COLOUR. 2.0 used to kill the coin and greyscale the
--                icon instead â€” a third of a Classic bag rendered in greyscale, which is the
--                "hard to view" half of the owner's report. Owned by Items._applyDress.
-- Both are still SWEPT on the paths that can resurrect them out of band (the OnShow hook
-- and the SetItemButton* post-hooks run the sweep, then our paint re-asserts the state), so
-- the defensive posture is unchanged for every region that is genuinely not ours.
--
-- SECURE / TAINT: every op here is a texture/animation op on a CHILD region of the button
-- (SetTexture / SetAlpha / Hide / anim:Stop / Cooldown:SetDrawEdge). NONE is a protected op
-- on the secure button itself (no Show/Hide/SetPoint/SetID/SetParent/SetAttribute on the
-- button), so the whole sweep is combat-safe and taint-free â€” it can run on every paint and
-- inside the hooksecurefunc post-hooks without touching the secure click path.
-- Guard-free of the WoW API (resolves regions via the accessors/$parent names the templates
-- expose) so the harness drives it headless with a fake button.

-- Resolve a named child region by accessor field first, then $parentName global.
local function region(button, field, suffix)
    if button[field] ~= nil then return button[field] end
    local name = button.GetName and button:GetName()
    if name and _G then return _G[name .. suffix] end
    return nil
end

-- Hide a texture region hard: clear its texture, park alpha at 0 (survives a later
-- template :Show()), and Hide(). Records it in the button's art registry for the gate.
local function hideRegion(button, tex, key)
    if not tex then return end
    if tex.SetTexture then tex:SetTexture(nil) end
    if tex.SetAlpha   then tex:SetAlpha(0)    end
    if tex.Hide       then tex:Hide()         end
    button._dsArt = button._dsArt or {}
    button._dsArt[key] = tex
end

-- Stop a pulsing AnimationGroup (the glow motors) so a hidden sheet cannot re-animate bright.
local function stopAnim(ag)
    if not ag then return end
    if ag.Stop   then ag:Stop()   end
    if ag.Finish then pcall(ag.Finish, ag) end
end

-- THE exhaustive kill sweep. Idempotent; safe on any button shape (accessor OR $parent OR
-- neither). Returns the NormalTexture (back-compat with callers/tests).
function Items._killTemplateArt(button)
    if not button then return nil end

    -- NormalTexture is fetched via its accessor when present (not a plain field), else
    -- via _normalTexture / $parentNormalTexture (the harness's fake-button shape).
    local nt = (button.GetNormalTexture and button:GetNormalTexture())
        or button._normalTexture
        or (button.GetName and _G and _G[(button:GetName() or "") .. "NormalTexture"])
    hideRegion(button, nt, "normal")
    -- Blank the button's STORED normal texture so the template cannot re-set the ring.
    if button.SetNormalTexture then pcall(button.SetNormalTexture, button, nil) end
    button._dsSlotArtHidden = nt   -- back-compat marker

    -- CELL PARITY: IconBorder and JunkIcon are NOT killed any more â€” 1.x drives both (see
    -- the block above). They are owned by borders.SetIconBorder / Items._applyDress, which
    -- re-assert their state on every paint and on every resurrection path.

    hideRegion(button, region(button, "NewItemTexture",        "NewItemTexture"),        "newItem")
    hideRegion(button, region(button, "BattlepayItemTexture",  "BattlepayItemTexture"),  "battlepay")
    hideRegion(button, region(button, "UpgradeIcon",           "UpgradeIcon"),           "upgrade")
    hideRegion(button, region(button, "IconOverlay",           "IconOverlay"),           "iconOverlay")
    hideRegion(button, region(button, "IconOverlay2",          "IconOverlay2"),          "iconOverlay2")
    hideRegion(button, region(button, "searchOverlay",         "SearchOverlay"),         "searchOverlay")
    hideRegion(button, region(button, "IconQuestTexture",      "IconQuestTexture"),      "quest")
    hideRegion(button, region(button, "Stock",                 "Stock"),                 "stock")
    button._dsNativeQuest = button._dsArt and button._dsArt.quest   -- back-compat marker

    -- Stop the new-item glow motors (they pulse NewItemTexture's alpha).
    stopAnim(button.flashAnim)
    stopAnim(button.newitemglowAnim)

    -- Quiet the cooldown swipe's bright edge ring + finish flash; keep the dark swipe (ours).
    local cd = button.Cooldown or button.cooldown
        or (button.GetName and _G[(button:GetName() or "") .. "Cooldown"])
    if cd then
        if cd.SetDrawEdge  then cd:SetDrawEdge(false)  end
        if cd.SetDrawBling then cd:SetDrawBling(false) end
    end

    return nt
end

-- Back-compat alias (older call sites / tests referenced the single-shot name).
Items._neutralizeSlotArt = Items._killTemplateArt

-- CELL PARITY, layer 2b: re-assert the two template regions we now OWN rather than kill.
-- The kill sweep can no longer hide IconBorder / JunkIcon (1.x shows both), so every path
-- that runs the sweep because the template may have just resurrected art must also re-put
-- OUR verdict back on those two. Reads only cached button state â€” it never calls
-- SetItemButton*, so it cannot re-enter the post-hooks that invoke it.
function Items._reassertOwnedArt(button)
    if not (button and button._dsDressed) then return end
    if ns.Borders and ns.Borders.Apply then
        ns.Borders.Apply(button, button._quality, button._unusable,
            button._questItem, button._isSet)
    end
    local junk = button.JunkIcon
        or (button.GetName and _G and _G[(button:GetName() or "") .. "JunkIcon"])
    if junk then
        local show = (button._quality == 0) and not button._hasNoValue and not button._dimmed
        if show then
            if junk.SetAlpha then junk:SetAlpha(Items.DressAlpha(button._dimmed)) end
            if junk.Show then junk:Show() end
        else
            if junk.SetAlpha then junk:SetAlpha(0) end
            if junk.Hide then junk:Hide() end
        end
    end
end

-- GATE HELPER: does the art registry report every killed region hidden? True iff every
-- recorded region has alpha 0 OR is not shown. The kill-list presence test drives a
-- SetItemButtonQuality-style resurrection (re-show the regions), fires the re-kill, and
-- asserts this returns true â€” proving the DEFENSIVE re-kill, not just the creation kill.
function Items.ArtRegistryHidden(button)
    local reg = button and button._dsArt
    if not reg then return true end
    for _, tex in pairs(reg) do
        local a = tex.GetAlpha and tex:GetAlpha()
        local shown = tex.IsShown and tex:IsShown()
        if (a ~= nil and a > 0) and (shown ~= false) then return false end
    end
    return true
end

-- Restyle the KEPT click feedback (hover highlight + pressed) to a quiet token wash so we
-- keep the tactile feedback without the template's bluish default highlight. In-game only
-- (SetHighlightTexture/SetPushedTexture are button methods). Non-secure texture setup at
-- creation â€” not a protected op.
local function restyleFeedback(button)
    if button.SetHighlightTexture then
        local hl = button:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\Buttons\\WHITE8X8")
        hl:SetVertexColor(tokenRGB("borderLite"))
        hl:SetAlpha(0.18)   -- barely-there warm wash, not the blue glow
        hl:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        hl:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        button:SetHighlightTexture(hl)
        button._dsHighlight = hl
    end
    if button.GetPushedTexture and button.SetPushedTexture then
        local pt = button:CreateTexture(nil, "OVERLAY")
        pt:SetTexture("Interface\\Buttons\\WHITE8X8")
        pt:SetVertexColor(tokenRGB("border"))
        pt:SetAlpha(0.28)
        pt:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        pt:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        button:SetPushedTexture(pt)
        button._dsPushed = pt
    end
end

-- Install the GLOBAL defensive re-kill hooks ONCE. hooksecurefunc post-hooks run AFTER the
-- game's own helper, so the instant the template re-applies art (icon/quality/count update)
-- we re-sweep. The hooks are global (these helpers are global), but each body no-ops unless
-- the button is one of OURS (marked _dsDressed) â€” a single cheap identity check; foreign item
-- buttons (bank/merchant/etc.) are untouched. hooksecurefunc is the sanctioned non-tainting
-- hook; the bodies do only child-texture ops, so no taint reaches the secure click path.
local function installArtHooks()
    if Items._artHooksInstalled or not _G.hooksecurefunc then return end
    if _G.SetItemButtonTexture then
        _G.hooksecurefunc("SetItemButtonTexture", function(btn)
            if btn and btn._dsDressed then
                Items._killTemplateArt(btn); Items._reassertOwnedArt(btn)
            end
        end)
    end
    if _G.SetItemButtonQuality then
        _G.hooksecurefunc("SetItemButtonQuality", function(btn)
            if btn and btn._dsDressed then
                Items._killTemplateArt(btn); Items._reassertOwnedArt(btn)
            end
        end)
    end
    -- The SetItemButtonCount hook is GONE: the numeral is the template's own again
    -- (CELL PARITY â€” 1.x never restyles it), so there is nothing to re-assert.
    Items._artHooksInstalled = true
end
Items._installArtHooks = installArtHooks

-- THE WELL IS RETIRED â€” see the CELL SUBSTRATE block at the top of this file and the
-- superseding note in borders.lua. 1.x paints NO cell substrate FILL in any state; the icon
-- region is the substrate, carrying the item's icon when filled and the chosen slot-
-- background art when empty. setWellState is gone with it; paintButton drives the icon
-- directly, and the only thing that describes a cell's footprint is the 2px SlotBorder edge
-- below (1.x item.lua:65-71 / 171-174), which 1.x draws on every cell.

-- EMPTY-CELL ICON (1.x item.lua:156-166). `bg` is a texture path OR an atlas descriptor;
-- 1.x branches on `type(bg) == 'function'` for exactly this reason (its atlas entries are
-- functions calling icon:SetAtlas). Enum 1 ("None") clears the icon entirely, which is what
-- 1.x's nil Backgrounds[1] does in Era. Never a protected op â€” a texture set on a child.
local function paintEmptyIcon(button)
    local art = Items.SlotBackgroundArt(Items.SlotBackground())
    local tex = iconOf(button)
    if type(art) == "table" and art.atlas then
        -- 1.x clears the texture FIRST, then applies the atlas (item.lua:159-160). An atlas
        -- the client does not ship simply leaves the region blank â€” which is precisely what
        -- 1.x renders in that case too, so the fallback IS the parity behaviour.
        if tex then
            if tex.SetTexture then tex:SetTexture(nil) end
            if tex.SetAtlas then tex:SetAtlas(art.atlas) end
            if tex.Show then tex:Show() end
        end
        return
    end
    if type(art) == "string" then
        -- A plain path goes through the template helper, exactly as 1.x's non-function
        -- branch does (item.lua:165), so the count/desat helpers stay in agreement.
        if _G.SetItemButtonTexture then _G.SetItemButtonTexture(button, art)
        elseif tex and tex.SetTexture then tex:SetTexture(art) end
        return
    end
    -- "None": clear the region outright. Driven directly rather than through the template
    -- helper, whose nil handling differs by client build.
    if tex and tex.SetTexture then tex:SetTexture(nil) end
end

-- PER-CELL SLOT BORDER â€” 1.x's `SlotBorder` (item.lua:65-71), driven exactly as 1.x drives
-- it (item.lua:171-174): a 2px edge around EVERY cell, filled or empty, in the profile's
-- slotBorderColor. 1.x ships it invisible (alpha 0); the owner deliberately set a near-black
-- maroon at 59% and asked for it back â€” it is what makes his grid read as "darkened,
-- slightly opaque" and is the reason the pre-parity 2.0 grid felt bare by comparison.
--
-- Implemented on borders.lua's SHARED snapped-outline factory rather than a BackdropTemplate
-- so the edge stays a true 2 physical pixels at any UI scale (a fractional-scale backdrop
-- edgeSize half-samples into a fuzzy rim at 720p â€” the reason that factory exists).
local function ensureSlotBorder(button)
    if button._dsSlotBorder then return button._dsSlotBorder end
    if not (ns.Borders and ns.Borders.NewSnappedOutline) then return nil end
    local o = ns.Borders.NewSnappedOutline(button, {
        outset = 0, layer = "OVERLAY", thicknessPx = Items.SLOT_BORDER_PX,
    })
    button._dsSlotBorder = o
    return o
end

-- Re-colour + show/hide the per-cell edge from the live profile value. Idempotent; safe on
-- every repaint (texture ops only). Alpha 0 hides it outright, so 1.x's own default
-- ({1,1,1,0}) reproduces 1.x's own "no visible edge" exactly.
-- STRUCTURE IS BAKED AT CREATION (C rule 1): this NEVER creates the outline, so a repaint
-- — which can land mid-combat — is a pure texture op. ensureDress owns the CreateFrame.
local function applySlotBorder(button)
    local o = button._dsSlotBorder
    if not o then return end
    local r, g, b, a = Items.SlotBorderColor()
    if a <= 0 then o:Hide(); return end
    o:SetColor(r, g, b, a)
    o:Show()
end
Items._applySlotBorder = applySlotBorder

-- PURE: the CELL border-presence matrix (1.0 parity â€” NO universal neutral ring). 1.x shows
-- no border on common/poor items or empties; a cell gets a ring ONLY for the quest gold
-- (which wins outright), the unusable red, the equipment-set teal, or a qualifying quality
-- edge (uncommon+, per minQuality). The order is 1.x's UpdateBorder branch chain
-- (item.lua:197-205) â€” quest > unusable > set > quality. Mirrors borders.ResolveTint so the
-- two never disagree.
-- Returns "quest" | "unusable" | "set" | "quality" | "none".
function Items.CellBorderKind(quality, unusable, enabled, minQuality, quest, set)
    if not enabled then return "none" end            -- borders off / gate closed
    if quest then return "quest" end                 -- gold tint: 1.x's first branch
    if unusable then return "unusable" end           -- red border wins over rarity
    if set then return "set" end                     -- 1.x glowSets teal, over rarity
    if ns.Borders and ns.Borders.ShouldShow(quality, enabled, minQuality) then return "quality" end
    return "none"                                     -- common / poor / empty -> clean cell
end

-- Paint a marker PIP from its Items.MarkerArt spec: a flat WHITE8X8 fill, tinted to the
-- spec's theme token, clipped to the shipped round stencil so it reads as a DOT and not a
-- box. Mirrors the suite's mask primitive (Daseeki-Core ledgerkit UI.MaskTexture: a
-- CreateMaskTexture host + AddMaskTexture, CLAMPTOBLACKADDITIVE both axes so everything
-- outside the stencil is clipped) but implemented locally â€” Core is OptionalDeps and a
-- core visual must not depend on it. `host` is the frame that owns the mask (masks are
-- frame-level objects); when masking is unavailable the pip simply stays a square â€” the
-- old look, never an invisible marker.
local function paintPip(tex, host, art)
    if tex.SetTexture then tex:SetTexture(art.texture) end
    if art.token and tex.SetVertexColor then tex:SetVertexColor(tokenRGB(art.token)) end
    if not (art.mask and host and host.CreateMaskTexture and tex.AddMaskTexture) then return nil end
    local mask = host:CreateMaskTexture()
    mask:SetAllPoints(tex)
    mask:SetTexture(art.mask, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    tex:AddMaskTexture(mask)
    return mask
end

-- Build the per-slot dress ONCE, at button creation (out of combat, gated by the
-- combat-deferred layout). After the CELL-PARITY round that is TWO regions â€” the round
-- new-item wax dot and the quest bang glyph â€” plus a binding of the template's own count
-- numeral so the dim cascade can reach it. There is no well, no hairline and no set pip:
-- 1.x draws none of them, and the icon region is the whole cell substrate. All children are
-- non-secure; nothing here (or at runtime) is a protected op on the button. Also installs
-- the global defensive re-kill hooks (once) and restyles the kept click feedback.
local function ensureDress(button)
    if button._dsDressed or not _G.CreateFrame then return end

    -- Kill the template's native art FIRST (exhaustive sweep), and arm the defensive re-kill
    -- hooks + quiet feedback restyle.
    Items._killTemplateArt(button)
    installArtHooks()
    restyleFeedback(button)

    -- CELL PARITY: NO WELL. 1.x draws no cell substrate FILL in any state â€” the icon region
    -- IS the substrate (item's icon when filled, the chosen slot-background art when empty),
    -- and nothing else COVERS the cell's footprint. The `inset`/`raised` colour rect that
    -- used to live here, inset 1px inside every button, is what turned the grid into a
    -- lattice of hard-edged squares with a visible gutter; it is gone, not tuned.
    button._dsDressed = true

    -- 1.x SLOT BORDER â€” the one cell-footprint element 1.x DOES create for every cell
    -- (item.lua:65-71) and colours on every update (item.lua:171-174). The previous round
    -- omitted it because 1.x's shipped default makes it invisible (alpha 0); the owner's
    -- profile does not, and the cue is his deliberate design. Created once, here.
    ensureSlotBorder(button)

    local sz = button:GetWidth() or Items.DEFAULT_SIZE

    -- NEW-ITEM wax dot (brand crimson), top-right corner. A Frame (so UI.Animate.FadeIn can
    -- play a one-shot 120ms reveal on arrival) holding the round pip texture.
    local newArt = Items.MarkerArt("new")
    local dot = _G.CreateFrame("Frame", nil, button)
    local dsz = math.max(5, math.floor(sz * newArt.sizeRatio))
    dot:SetSize(dsz, dsz)
    dot:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
    if dot.SetFrameLevel then dot:SetFrameLevel((button:GetFrameLevel() or 1) + 2) end
    local dt = dot:CreateTexture(nil, "OVERLAY")
    dt:SetAllPoints(dot)
    paintPip(dt, dot, newArt)
    dot:Hide()
    button._dsNewDot = dot

    -- QUEST bang glyph, over the cell â€” the real 1.x marker (item.lua:47 paints the
    -- template's IconQuestTexture with TEXTURE_ITEM_QUEST_BANG). Ours is an addon-owned
    -- OVERLAY region on the same footprint, because _killTemplateArt permanently hides
    -- the native one. No token tint: the bang keeps its own gold, exactly as in 1.0.
    local questArt = Items.MarkerArt("quest")
    local tab = button:CreateTexture(nil, "OVERLAY")
    tab:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    tab:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    tab:SetTexture(questArt.texture)
    tab:Hide()
    button._dsQuestTab = tab

    -- CELL PARITY: NO equipment-set corner pip. 1.x expresses set membership through the
    -- glow chain (item.lua:201-202, teal .2/1/.8), not as a second mark on the cell. The
    -- bronze pip that used to be created here is retired; borders.ResolveTint carries the
    -- cue now, gated by the same db.setMarkers toggle â€” which is DEFAULT OFF, because 1.x
    -- cannot draw the cue at all on Classic Era with ItemRack disabled (see slotIsSet).

    bindCount(button)
end
Items._ensureDress = ensureDress

local function paintButton(button)
    -- DEFENSIVE re-kill sweep (layer 3): our own paint calls SetItemButton* below, which are
    -- the template's art-resurrection helpers. Sweeping first makes a repaint idempotent w.r.t.
    -- template art â€” no resurrected blue can survive a paint even if a hook is somehow missed.
    Items._killTemplateArt(button)

    local data = button._data
    if not data or not data.id then
        -- CELL PARITY (1.x item.lua:156-167): an EMPTY slot is the CHOSEN slot-background
        -- art in the icon region, at slotAlpha â€” not a blank icon over a colour rect, and
        -- not the bevelled backpack art at full opacity. The owner's profile selects the
        -- faction crest at 29%; applyDressState below applies the alpha.
        paintEmptyIcon(button)
        if _G.SetItemButtonCount then _G.SetItemButtonCount(button, 0) end
        if ns.Borders then ns.Borders.Apply(button, nil) end
        if button._live then updateCooldown(button) end
        button._pendingId = nil
        button._quality = nil
        button._hasNoValue = nil
        button._unusable, button._isSet = false, false
        -- Clear the cached quest verdicts with the slot, so a recycled button can never
        -- carry a stale bang/gold tint from the item that used to sit here.
        button._questItem, button._questStarter = false, false
        applyDressState(button)   -- icon alpha/desat, hides markers + junk coin, cascades alpha
        -- An EMPTY cell still carries its lock: the lock belongs to the SLOT, and an
        -- empty locked slot is exactly the case the sort planner must refuse to fill.
        applyLockLayer(button)
        return
    end

    local visual = Items.ResolveVisual(data, liveResolver())
    local icon = (visual and visual.icon) or Items.PLACEHOLDER_ICON
    if _G.SetItemButtonTexture then _G.SetItemButtonTexture(button, icon)
    else local t = iconOf(button); if t then t:SetTexture(icon) end end
    if _G.SetItemButtonCount then _G.SetItemButtonCount(button, (visual and visual.count) or 1) end

    local quality = visual and visual.quality
    -- CELL PARITY (1.x item.lua:194): hand the quality to the TEMPLATE first, exactly as 1.x
    -- does, so Blizzard sets the IconBorder region's own art from its own tables â€” we never
    -- guess a texture path. borders.Apply immediately below overrides colour + shown, which
    -- is precisely 1.x's item.lua:210/220 sequence.
    if _G.SetItemButtonQuality then
        pcall(_G.SetItemButtonQuality, button, quality, data.link or data.id, false, false)
    end

    -- 1.0-PARITY border chain, top down: QUEST gold > UNUSABLE red > SET teal > quality edge.
    -- A quest item (starter or objective) draws the gold tint â€” 1.x's first branch. An
    -- UNUSABLE (class-can't-equip / below-level) item draws the red. A saved-set member draws
    -- the teal. All are computed once here (live only) and cached on the button so
    -- applyDressState and the re-assert path reuse them without a second scan; the bang
    -- glyph is decided from _questStarter over in ResolveState.
    local isQuest, isStarter = false, false
    if button._live then isQuest, isStarter = slotQuestFlags(button) end
    button._questItem, button._questStarter = isQuest, isStarter
    local unusable = (button._live and slotIsUnusable(button)) or false
    button._unusable = unusable
    local isSet = (button._live and slotIsSet(button)) or false
    button._isSet = isSet
    button._hasNoValue = slotHasNoValue(button)
    if ns.Borders then ns.Borders.Apply(button, quality, unusable, isQuest, isSet) end
    button._quality = quality

    -- FILLED: the icon IS the cell (1.x). No card, no ring by default; the ONLY thing that
    -- can describe this cell's edge is the tint chain drawn just above.

    if button._live then
        updateCooldown(button)
    end

    if visual and visual.pending then
        button._pendingId = data.id
        watchPending(button, data.id)
    else
        button._pendingId = nil
    end
    applyDressState(button)
    -- Re-assert the lock layer on every paint: a relayout recycles buttons across
    -- (cid, slot) pairs, so the mark has to follow the SLOT, not the frame. With the
    -- mode closed this is a two-field test and no allocation.
    applyLockLayer(button)
end

local function showCachedTooltip(button)
    local GT = _G.GameTooltip
    if not GT then return end
    local data = button._data
    if not data then return end
    GT:SetOwner(button, "ANCHOR_RIGHT")
    local link = data.link
    if link and GT.SetHyperlink then GT:SetHyperlink(link)
    elseif data.id and GT.SetHyperlink then GT:SetHyperlink("item:" .. data.id) end
    local owner = button._owner
    local age = owner and button._cid and Store.ContainerAge(owner, button._cid)
    local ageStr = age and Items.FormatCachedAge(age)
    if ageStr and GT.AddLine then GT:AddLine(ageStr, mutedRGB()) end
    if GT.Show then GT:Show() end
end

----------------------------------------------------------------------
-- Button factory + methods
----------------------------------------------------------------------

local _btnSeq = 0
local function nextButtonName()
    _btnSeq = _btnSeq + 1
    return "DaseekiBags2Item" .. _btnSeq
end

-- Create an item button. opts.live selects the secure container template (interactive)
-- vs the plain render-only ItemButtonTemplate. opts.size sets the cell size.
function Items.CreateButton(parent, opts)
    opts = opts or {}
    if not _G.CreateFrame then return nil end
    local live = opts.live and true or false
    local template = live and "ContainerFrameItemButtonTemplate" or "ItemButtonTemplate"
    local button = _G.CreateFrame("Button", nextButtonName(), parent, template)
    button._live = live
    Items._buttons[button] = true   -- weak registry; only the lock-layer sweep reads it
    local cell = Items.ClampCell(opts.size)
    button:SetSize(cell, cell)
    button._dsRepaint = function(self) paintButton(self) end

    if not live then
        -- Render-only: hyperlink tooltip + inert click (shift-link only), no drag.
        if button.RegisterForDrag then button:RegisterForDrag() end
        button:SetScript("OnEnter", function(self) showCachedTooltip(self) end)
        button:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        button:SetScript("OnClick", function(self)
            if _G.HandleModifiedItemClick and self._data and self._data.link then
                _G.HandleModifiedItemClick(self._data.link)
            end
        end)
    else
        -- LIVE keeps the template's own OnClick/OnDragStart/OnReceiveDrag/OnEnter handlers
        -- (secure, combat-correct pickup/place/split/use + real-slot tooltip) untouched.
        -- An INSECURE OnEnter post-hook clears the new-item mark on hover (1.x MarkSeen
        -- fact) â€” a non-secure hook that never touches the secure click path.
        if button.HookScript then
            button:HookScript("OnEnter", function(self) Items.MarkSeen(self) end)
        end
    end

    if ns.Borders then ns.Borders.Attach(button) end
    ensureDress(button)

    -- DEFENSIVE re-kill (layer 2b): the template's OWN OnShow re-applies art every time the
    -- button is shown (relayout / pool reuse). A non-secure OnShow post-hook re-sweeps AFTER
    -- it, so no resurrected NormalTexture/NewItemTexture ever survives a Show. Never touches
    -- the secure click path (HookScript adds an insecure post-hook; body is texture-only).
    if button.HookScript then
        button:HookScript("OnShow", function(self)
            Items._killTemplateArt(self); Items._reassertOwnedArt(self)
        end)
    end

    button.SetSlot   = function(self, o, c, s, d) Items._setSlot(self, o, c, s, d) end
    button.SetEmpty  = function(self, o, c, s)    Items._setSlot(self, o, c, s, nil) end
    button.SetDimmed = function(self, on) self._dimmed = on and true or false; applyDressState(self) end
    button.Clear     = function(self)
        self._owner, self._cid, self._slot, self._data, self._pendingId, self._quality = nil, nil, nil, nil, nil, nil
        if _G.SetItemButtonTexture then _G.SetItemButtonTexture(self, nil) end
        if _G.SetItemButtonCount then _G.SetItemButtonCount(self, 0) end
        self._unusable, self._isSet, self._hasNoValue = false, false, nil
        if ns.Borders then ns.Borders.Apply(self, nil) end
        if self._dsNewDot then self._dsNewDot:Hide() end
        if self._dsQuestTab then self._dsQuestTab:Hide() end
        -- A cleared button no longer stands for any slot, so its lock affordance must
        -- go with it (the catcher especially: it must never outlive its (cid, slot)).
        if self._dsLockMark then self._dsLockMark:Hide() end
        if self._dsLockCatch then self._dsLockCatch:Hide() end
        self:Hide()
    end
    return button
end

function Items._setSlot(button, owner, cid, slot, data)
    button._owner, button._cid, button._slot, button._data = owner, cid, slot, data
    if button._live and button.SetID then button:SetID(slot) end  -- template reads slot from GetID()
    paintButton(button)
    button:Show()
end

----------------------------------------------------------------------
-- Per-container holder (carries SetID(cid) for the live template's bag lookup)
----------------------------------------------------------------------

local function holderFor(G, cid)
    local h = G._holders[cid]
    if not h then
        h = _G.CreateFrame("Frame", nil, G)
        h:SetID(cid)          -- ContainerFrameItemButtonTemplate reads parent:GetID() as bagID
        h:SetAllPoints(G)
        G._holders[cid] = h
    end
    return h
end

----------------------------------------------------------------------
-- Group factory
----------------------------------------------------------------------

local function combatFlush(G)
    if G._combatFrame or not _G.CreateFrame then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        if G._pendingEntries then
            local e = G._pendingEntries
            G._pendingEntries = nil
            G:ShowSlots(e)
        end
    end)
    G._combatFrame = f
end

local function layoutGroup(G, entries)
    entries = entries or {}
    local n = #entries

    -- Secure item buttons are protected frames â€” never create/reparent them in combat.
    -- Defer the whole relayout to PLAYER_REGEN_ENABLED (repaint of existing buttons is
    -- safe, but a structural rebuild is not, so we defer wholesale for simplicity).
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        for _, e in ipairs(entries) do
            if Items.IsLive(e.owner) then
                G._pendingEntries = entries
                combatFlush(G)
                return
            end
        end
    end

    local cols, size, gap = G._columns, G._size, G._gap
    -- Run-split geometry (keyring row-break). OFF unless the caller opted in, so split
    -- groups (one cid each), category sections (deliberately mixed-cid) and the bank keep
    -- exactly the flat flow they had; with one run the math is identical to the old path.
    local L = G._runSplit and Items.RunLayout(Items.SplitRuns(entries), cols, size, gap, Items.RUN_GAP) or nil
    for i = 1, n do
        local e = entries[i]
        local live = Items.IsLive(e.owner)
        local button = G._buttons[i]
        if (not button) or (button._live ~= live) then
            if button then button:Hide(); if button.SetParent then button:SetParent(nil) end end
            local parent = live and holderFor(G, e.cid) or G
            button = Items.CreateButton(parent, { live = live, size = size })
            G._buttons[i] = button
        elseif live then
            button:SetParent(holderFor(G, e.cid))   -- keep the bag holder current
        end
        local x, y
        if L then x, y = Items.RunSlotPosition(L, i, cols, size, gap)
        else x, y = Items.SlotPosition(i, cols, size, gap) end
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", G, "TOPLEFT", x, y)
        button:SetSize(size, size)
        button._dimmed = false
        if e.data then button:SetSlot(e.owner, e.cid, e.slot, e.data)
        else button:SetEmpty(e.owner, e.cid, e.slot) end
    end
    for i = n + 1, #G._buttons do G._buttons[i]:Hide() end

    local m = L or Items.GridMetrics(n, cols, size, gap)
    G:SetSize(math.max(m.width, size), math.max(m.height, size))  -- never zero-size
end

-- Split-view bag header text: the bag item's real name when a link resolves, else a
-- class label. `group` is the descriptor { cid, class, size, link }.
local function headerText(group)
    local class = group.class
    if not class and group.cid ~= nil then class = Store.ContainerClass(group.cid) end
    local label = CLASS_LABEL[class or "unknown"] or "Items"
    if group.link and _G.C_Item and _G.C_Item.GetItemInfo then
        local name = _G.C_Item.GetItemInfo(group.link)
        if name then label = name end
    end
    return label
end

-- Create a grid group. G:SetGrid(columns, buttonSize, gap); G:ShowSlots(entries);
-- G:Clear(); G:SetHeader(group) (split mode). The group self-sizes from grid math on
-- every ShowSlots.
function Items.CreateGroup(parent)
    if not _G.CreateFrame then return nil end
    local G = _G.CreateFrame("Frame", nil, parent)
    G._columns = Items.DEFAULT_COLUMNS
    G._size    = Items.DEFAULT_SIZE
    G._gap     = Items.DEFAULT_GAP
    G._buttons = {}
    G._holders = {}

    function G:SetGrid(columns, buttonSize, gap)
        if columns then self._columns = math.max(1, columns) end
        if buttonSize then self._size = Items.ClampCell(buttonSize) end  -- 720p cell floor (C)
        if gap ~= nil then self._gap = gap end
        -- Re-flow the current contents so a grid change is immediately visible.
        if self._lastEntries then layoutGroup(self, self._lastEntries) end
    end

    -- Opt in to the 1.0 keyring ROW-BREAK for this group: the entry list is split into
    -- runs at the generic->keyring boundary and each later run starts at column 0 of a
    -- fresh row, Items.RUN_GAP px lower. Only the flat COMBINED grid wants this (split
    -- groups are already one container each; category sections are deliberately mixed).
    -- Default OFF, so every other consumer keeps the flat flow unchanged.
    function G:SetRunSplit(enabled)
        local want = enabled and true or false
        if self._runSplit == want then return end
        self._runSplit = want
        if self._lastEntries then layoutGroup(self, self._lastEntries) end
    end

    function G:ShowSlots(entries)
        self._lastEntries = entries
        layoutGroup(self, entries)
    end

    -- Split mode: label this group with its bag's header (icon + name), sitting in a
    -- band ABOVE the grid so it never displaces a cell (keeps the shared grid math,
    -- 37/4/12, exact). Pass nil to hide. Frame no-ops gracefully if never called.
    function G:SetHeader(group)
        if not group then
            if self._header then self._header:Hide() end
            return
        end
        local h = self._header
        if not h then
            h = _G.CreateFrame("Frame", nil, self)
            h:SetHeight(Items.HEADER_HEIGHT)
            h:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 2)
            h:SetPoint("BOTTOMRIGHT", self, "TOPRIGHT", 0, 2)
            h._icon = h:CreateTexture(nil, "ARTWORK")
            h._icon:SetSize(14, 14)
            h._icon:SetPoint("LEFT", h, "LEFT", 0, 0)
            h._label = h:CreateFontString(nil, "OVERLAY")
            if _G.DaseekiUI and _G.DaseekiUI.fonts and _G.DaseekiUI.fonts.small then
                h._label:SetFontObject(_G.DaseekiUI.fonts.small)
            else
                h._label:SetFontObject("GameFontNormalSmall")
            end
            self._header = h
        end
        local icon
        if group.link and _G.C_Item and _G.C_Item.GetItemInfoInstant then
            local _, _, _, _, i = _G.C_Item.GetItemInfoInstant(group.link)
            icon = i
        end
        h._label:ClearAllPoints()
        if icon then
            h._icon:SetTexture(icon); h._icon:Show()
            h._label:SetPoint("LEFT", h._icon, "RIGHT", 4, 0)
        else
            h._icon:Hide()
            h._label:SetPoint("LEFT", h, "LEFT", 0, 0)
        end
        h._label:SetText(headerText(group))
        if _G.DaseekiUI and _G.DaseekiUI.Color then h._label:SetTextColor(_G.DaseekiUI.Color("muted")) end
        h:Show()
    end

    function G:Clear()
        self._lastEntries = nil
        if self._header then self._header:Hide() end
        for _, b in ipairs(self._buttons) do b:Clear() end
    end

    local m = Items.GridMetrics(0, G._columns, G._size, G._gap)
    G:SetSize(math.max(m.width, G._size), math.max(m.height, G._size))
    return G
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "ui_items")
----------------------------------------------------------------------

local function newOwnerWith(containers)
    _G.DaseekiBags2Data = nil; Store.Init()
    local o = Store.EnsureOwner("Tester-TestRealm")
    o.source = "full"
    for cid, spec in pairs(containers) do
        local c = Store.NewContainer(spec.size, spec.link)
        for slot, s in pairs(spec.slots or {}) do
            c.slots[slot] = Store.NewSlot(s.id, s.count, s.quality, s.link)
        end
        Store.PutContainer(o, cid, c, spec.ts or 1)
    end
    return o
end

local function testGridMath(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local m0 = Items.GridMetrics(0, 12, 37, 4)
    ck(m0.rows == 0 and m0.height == 0, "N=0 -> zero rows/height (group floors size itself)")
    local m1 = Items.GridMetrics(1, 12, 37, 4)
    ck(m1.cols == 1 and m1.rows == 1 and m1.width == 37 and m1.height == 37, "N=1 single cell")
    local m5 = Items.GridMetrics(5, 12, 37, 4)
    ck(m5.cols == 5 and m5.rows == 1, "N=5 hugs 5 columns, 1 row")
    ck(m5.width == 5 * 37 + 4 * 4, "N=5 width = 5 cells + 4 gaps")
    local m12 = Items.GridMetrics(12, 12, 37, 4)
    ck(m12.cols == 12 and m12.rows == 1, "N=12 fills the row")
    local m13 = Items.GridMetrics(13, 12, 37, 4)
    ck(m13.cols == 12 and m13.rows == 2, "N=13 wraps to 2 rows")
    ck(m13.height == 2 * 37 + 1 * 4, "N=13 height = 2 cells + 1 gap")
    -- positions
    local x1, y1 = Items.SlotPosition(1, 12, 37, 4)
    ck(x1 == 0 and y1 == 0, "cell 1 at origin")
    local x13, y13 = Items.SlotPosition(13, 12, 37, 4)
    ck(x13 == 0 and y13 == -(37 + 4), "cell 13 at row 2 col 1")
    local x12, y12 = Items.SlotPosition(12, 12, 37, 4)
    ck(x12 == 11 * (37 + 4) and y12 == 0, "cell 12 at row 1 col 12")
end

local function testEntryBuilding(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = newOwnerWith({
        [0]  = { size = 16, slots = { [1] = { id = 6948, count = 1 }, [5] = { id = 22157, count = 20, quality = 3 } } },
        [1]  = { size = 6,  link = "item:14046", slots = { [2] = { id = 4234, count = 4 } } },
        [-1] = { size = 24, slots = { [1] = { id = 4306, count = 20 } } },      -- bank main
        [5]  = { size = 16, slots = { [1] = { id = 4338, count = 8 } } },       -- bank bag
        [-2] = { size = 12, slots = { [1] = { id = 5175, count = 1 } } },       -- keyring
    })

    -- split grouping, "bags" scope: backpack + bag 1 only, in rank order.
    local gBags = Items.BuildGroups(o, { scope = "bags" })
    ck(#gBags == 2, "bags scope -> 2 groups (backpack + bag)")
    ck(gBags[1].cid == 0 and gBags[2].cid == 1, "groups sorted backpack(0) then bag(1)")
    ck(#gBags[1].entries == 16 and #gBags[2].entries == 6, "entries fill full container size incl. empties")
    ck(gBags[1].entries[1].data ~= nil and gBags[1].entries[1].data.id == 6948, "slot 1 populated")
    ck(gBags[1].entries[2].data == nil, "slot 2 empty -> nil data")
    ck(gBags[1].entries[5].data.quality == 3, "captured quality preserved on entry")

    -- combined flatten, "bags" scope: 16 + 6 = 22 entries, backpack first.
    local flat = Items.BuildEntries(o, { scope = "bags" })
    ck(#flat == 22, "combined flatten length = 16 + 6")
    ck(flat[1].cid == 0 and flat[17].cid == 1, "flatten runs backpack (1..16) then bag (17..)")

    -- "all" scope orders bank AFTER carried: backpack(0), bag(1), keyring(-2), bank(-1), bankbag(5).
    local gAll = Items.BuildGroups(o, { scope = "all" })
    local order = {}
    for i, g in ipairs(gAll) do order[i] = g.cid end
    ck(order[1] == 0 and order[2] == 1 and order[3] == -2 and order[4] == -1 and order[5] == 5,
        "all-scope rank order: backpack, bag, keyring, bank, bankbag")

    -- scope predicates
    ck(Items._cidInScope(0, "bags") == true and Items._cidInScope(-1, "bags") == false, "bags excludes bank")
    ck(Items._cidInScope(-1, "bank") == true and Items._cidInScope(0, "bank") == false, "bank scope is bank-only")
    ck(Items._cidInScope(-2, "carried") == true, "carried includes keyring")
end

local function testQualityDerivation(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Captured quality present -> resolved immediately, no pending, no info() needed.
    local vCaptured = Items.ResolveVisual({ id = 22157, count = 2, quality = 3 },
        { instant = function() return 22157, "Armor", "Cloth", "", 1338 end })
    ck(vCaptured.icon == 1338, "icon derived from instant path")
    ck(vCaptured.quality == 3 and vCaptured.pending == false, "captured quality -> not pending")

    -- Migrated slot: quality = nil, info() also returns nil quality (server-uncached).
    local uncached = { info = function() return nil, nil, nil end,
                       instant = function() return 4306, "Consumable", "Food", "", 5555 end }
    local vPending = Items.ResolveVisual({ id = 4306, count = 20 }, uncached)
    ck(vPending.icon == 5555, "uncached still gets an icon from instant")
    ck(vPending.quality == nil and vPending.pending == true, "nil quality -> pending")

    -- After the server responds, info() now returns the quality -> resolved.
    local resolved = { info = function() return "Roasted Boar", "item:4306", 1 end,
                       instant = function() return 4306, "Consumable", "Food", "", 5555 end }
    local vDone = Items.ResolveVisual({ id = 4306, count = 20 }, resolved)
    ck(vDone.quality == 1 and vDone.pending == false, "resolved quality -> not pending")
    ck(vDone.name == "Roasted Boar", "name resolved from info")

    ck(Items.ResolveVisual(nil) == nil, "nil data -> nil visual")
    ck(Items.ResolveVisual({ count = 1 }) == nil, "data without id -> nil visual")
end

local function testDimAndAge(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local a1, d1 = Items.DimValues(true)
    -- CELL PARITY: 0.3, 1.x core/classes/item.lua:233 (SetAlpha(matches and 1 or 0.3)).
    ck(a1 == 0.3 and d1 == true, "dimmed -> 0.3 alpha + desaturate (1.x item.lua:233)")
    ck(Items.DIM_ALPHA == 0.3, "the dim constant IS 1.x's 0.3")
    ck(Items.DressAlpha(true) == Items.DimValues(true), "both dim forms agree")
    local a0, d0 = Items.DimValues(false)
    ck(a0 == 1.0 and d0 == false, "undimmed -> full alpha, no desaturate")

    ck(Items.FormatCachedAge(nil) == nil, "nil age -> nil")
    ck(Items.FormatCachedAge(30) == "cached just now", "<1m -> just now")
    ck(Items.FormatCachedAge(300) == "cached 5m ago", "5 minutes")
    ck(Items.FormatCachedAge(7200) == "cached 2h ago", "2 hours")
    ck(Items.FormatCachedAge(259200) == "cached 3d ago", "3 days")
end

-- Cell clamp (720p floor): the button cell never drops below MIN_CELL.
local function testCellClamp(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Items.ClampCell(37) == 37, "37 unchanged (above floor)")
    ck(Items.ClampCell(30) == 30, "30 == floor, unchanged")
    ck(Items.ClampCell(24) == Items.MIN_CELL, "24 clamped up to floor 30")
    ck(Items.ClampCell(nil) == Items.DEFAULT_SIZE, "nil -> default cell (above floor)")
    ck(Items.MIN_CELL == 30, "floor is 30 (C)")
end

-- STATE-marker precedence matrix (Layer 2). Verifies the icon precedence
--   dimmed > junk > normal   (1.0: unusable no longer greys the icon â€” it flags redBorder)
-- and that markers / the red border show only when NOT dimmed.
local function testStatePrecedence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- normal rare item: no treatment, no markers
    local s = Items.ResolveState({ quality = 3 })
    ck(s.icon == "normal" and s.iconDesat == false and s.unusableTint == false, "normal rare -> clean icon")
    ck(s.redBorder == false, "normal -> no red border")
    ck(s.showNewDot == false and s.showQuestTab == false and s.showSetMark == false, "normal -> no markers")
    ck(s.dressAlpha == 1.0, "normal -> full dress alpha")

    -- CELL PARITY â€” junk (quality 0): FULL-COLOUR icon + the template's vendor coin, exactly
    -- as 1.x (item.lua:170 restores vertex colour; :222 shows JunkIcon). The greyscale junk
    -- treatment is retired: it washed out a third of a Classic bag.
    local j = Items.ResolveState({ quality = 0 })
    ck(j.icon == "normal", "junk icon is NOT a treatment any more (1.x keeps it in colour)")
    ck(j.iconDesat == false, "junk -> NO desaturation (regression lock)")
    ck(j.junkCoin == true, "junk with value -> the 1.x vendor coin")
    local jnv = Items.ResolveState({ quality = 0, hasNoValue = true })
    ck(jnv.junkCoin == false, "junk a vendor won't buy -> no coin (1.x item.lua:222)")
    ck(Items.ResolveState({ quality = 1 }).junkCoin == false, "common -> no coin")
    ck(Items.ResolveState({ quality = 0, dimmed = true }).junkCoin == false, "dimmed -> no coin")

    -- 1.0 UNUSABLE: icon stays FULL-COLOR (no grey/tint); a RED BORDER is flagged instead.
    local u = Items.ResolveState({ quality = 4, isUnusable = true })
    ck(u.icon == "normal" and u.iconDesat == false, "unusable epic -> icon stays normal (no grey)")
    ck(u.redBorder == true and u.unusableTint == false, "unusable -> red border flagged, no tint")

    -- unusable JUNK: coin still shows, icon still full-colour, red border still flagged.
    local uj = Items.ResolveState({ quality = 0, isUnusable = true })
    ck(uj.icon == "normal" and uj.junkCoin == true and uj.redBorder == true,
        "unusable junk -> full-colour icon + coin + red border")

    -- CELL PARITY â€” the SET cue is a BORDER now, not a corner pip (1.x item.lua:201-202).
    local m = Items.ResolveState({ quality = 3, isNew = true, isQuestStarter = true, isSet = true, isUnusable = true })
    ck(m.showNewDot == true and m.showQuestTab == true, "new + quest-starter markers still show")
    ck(m.showSetMark == false, "the bronze set pip is retired (regression lock)")
    ck(m.questBorder == true and m.redBorder == false and m.setBorder == false,
        "quest gold wins the cell over BOTH the unusable red and the set teal (1.x branch order)")
    -- an unusable NON-quest item still gets the red, and the set teal yields to it
    local mu = Items.ResolveState({ quality = 3, isSet = true, isUnusable = true })
    ck(mu.redBorder == true and mu.questBorder == false and mu.setBorder == false,
        "unusable beats the set teal (1.x branch order)")
    -- a plain set member gets the teal, over its own rarity
    local ms = Items.ResolveState({ quality = 3, isSet = true })
    ck(ms.setBorder == true and ms.redBorder == false and ms.questBorder == false,
        "set member -> teal border, above rarity")
    ck(Items.ResolveState({ quality = 3 }).setBorder == false, "non-set item -> no teal")

    -- DIMMED outranks everything: icon=dimmed, ALL markers + every border suppressed, alpha 0.3
    local d = Items.ResolveState({ quality = 0, isNew = true, isQuestStarter = true, isSet = true, isUnusable = true, dimmed = true })
    ck(d.icon == "dimmed" and d.iconDesat == true, "dimmed is the ONLY icon treatment left")
    ck(d.redBorder == false and d.questBorder == false and d.setBorder == false,
        "dimmed suppresses every border")
    ck(d.showNewDot == false and d.showQuestTab == false and d.junkCoin == false,
        "dimmed suppresses all markers and the coin")
    ck(d.dressAlpha == 0.3, "dimmed -> 0.3 dress alpha (1.x item.lua:233)")

    -- 1.x QUEST SPLIT: an ORDINARY quest item (an objective already in the log) gets the
    -- gold border and NO bang; a quest STARTER gets both.
    local qo = Items.ResolveState({ quality = 1, isQuest = true })
    ck(qo.questBorder == true, "ordinary quest item -> gold border")
    ck(qo.showQuestTab == false, "ordinary quest item -> NO bang glyph (1.x reserves it for starters)")
    local qs = Items.ResolveState({ quality = 1, isQuest = true, isQuestStarter = true })
    ck(qs.showQuestTab == true and qs.questBorder == true, "quest starter -> bang glyph AND gold border")
    -- a starter flagged alone still implies a quest item (the tint can't go missing)
    local qs2 = Items.ResolveState({ quality = 1, isQuestStarter = true })
    ck(qs2.questBorder == true and qs2.showQuestTab == true, "starter alone implies quest item")
    -- a non-quest item takes neither cue
    local nq = Items.ResolveState({ quality = 1 })
    ck(nq.questBorder == false and nq.showQuestTab == false, "non-quest item -> no gold, no bang")

    -- new-only, quest-starter-only, set-only
    local n = Items.ResolveState({ quality = 2, isNew = true })
    ck(n.showNewDot == true and n.showQuestTab == false and n.icon == "normal", "new-only marker")
    local q = Items.ResolveState({ quality = 2, isQuestStarter = true })
    ck(q.showQuestTab == true and q.showNewDot == false, "quest-starter-only marker")
    local st = Items.ResolveState({ quality = 2, isSet = true })
    ck(st.setBorder == true and st.showNewDot == false and st.showQuestTab == false
        and st.icon == "normal", "set-only -> the teal border, no pip, clean icon")
end

-- 1.x QUEST RULE (Items.QuestFlags): the exact field mechanism that separates a quest
-- STARTER (bang glyph) from an ordinary quest item (gold border tint only). 1.x fact:
--   Item:GetQuestInfo -> info.isQuestItem, (info.questID and not info.isActive)
-- so the starter test is questID-present AND not-active â€” NOT isQuestItem.
local function testQuestFlags(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function flags(info) local q, s = Items.QuestFlags(info); return q, s end

    -- Ordinary quest OBJECTIVE: flagged a quest item, no questID at all.
    local q, s = flags({ isQuestItem = true })
    ck(q == true and s == false, "quest objective (no questID) -> quest, NOT a starter")

    -- Quest STARTER: carries a questID that is not yet active (right-click starts it).
    q, s = flags({ isQuestItem = true, questID = 1234, isActive = false })
    ck(q == true and s == true, "questID + not active -> STARTER (bang)")

    -- Same item once the quest is ACCEPTED: isActive true -> the bang is withheld, and it
    -- stays an ordinary quest item (gold border only). This is the whole point of the rule.
    q, s = flags({ isQuestItem = true, questID = 1234, isActive = true })
    ck(q == true and s == false, "questID but ALREADY ACTIVE -> quest, no bang")

    -- A starter whose isQuestItem is somehow false still counts as a quest item, so the
    -- tint can never go missing underneath the glyph.
    q, s = flags({ questID = 77, isActive = false })
    ck(q == true and s == true, "starter without isQuestItem still reads as a quest item")

    -- Not a quest item at all / no info (offline owner, API absent).
    q, s = flags({ isQuestItem = false })
    ck(q == false and s == false, "non-quest item -> neither cue")
    q, s = flags(nil)
    ck(q == false and s == false, "nil info -> neither cue (nil-safe)")
    q, s = flags({})
    ck(q == false and s == false, "empty info -> neither cue")
end

-- DIM CASCADE covering ALL dress layers: a dimmed slot recedes icon + quality edge +
-- count numeral + new dot + quest tab together (the C condition-4 bug fix). Uses a fake
-- button (no CreateFrame needed) so the wiring itself is asserted headless.
local function testDimCascade(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function recorder()
        local r = { alpha = nil, shown = true, desat = nil }
        function r:SetAlpha(a) self.alpha = a end
        function r:SetDesaturated(d) self.desat = d end
        function r:SetVertexColor() end
        function r:IsShown() return self.shown end
        function r:Show() self.shown = true end
        function r:Hide() self.shown = false end
        return r
    end

    -- a fake button carrying every dress layer
    local icon   = recorder()
    local border = recorder()
    local count  = recorder()
    local dot    = recorder(); dot.shown = true   -- currently shown (new)
    local tab    = recorder(); tab.shown = true
    local btn = {
        icon = icon, _dsBagsBorder = border, _dsCount = count,
        _dsNewDot = dot, _dsQuestTab = tab,
    }

    -- DIMMED spec: everything must land at 0.25 and markers hide
    Items._applyDress(btn, Items.ResolveState({ quality = 4, isNew = true, isQuest = true, dimmed = true }))
    ck(icon.alpha == 0.3,   "cascade: icon dimmed to 0.3")
    ck(border.alpha == 0.3, "cascade: quality edge dimmed to 0.3")
    ck(count.alpha == 0.3,  "cascade: count numeral dimmed to 0.3")
    ck(icon.desat == true,   "cascade: icon desaturated while dimmed")
    ck(dot.shown == false,   "cascade: new dot hidden while dimmed")
    ck(tab.shown == false,   "cascade: quest tab hidden while dimmed")

    -- UNDIMMED normal: dress alpha restored to 1.0, no desat
    local icon2, border2, count2 = recorder(), recorder(), recorder()
    local btn2 = { icon = icon2, _dsBagsBorder = border2, _dsCount = count2 }
    Items._applyDress(btn2, Items.ResolveState({ quality = 3 }))
    ck(icon2.alpha == 1.0 and border2.alpha == 1.0 and count2.alpha == 1.0, "undimmed -> full alpha across dress")
    ck(icon2.desat == false, "undimmed normal -> icon not desaturated")

    -- ns.Borders.SetAlpha path also cascades to the border container field
    local b3 = { _dsBagsBorder = recorder() }
    ns.Borders.SetAlpha(b3, 0.3)
    ck(b3._dsBagsBorder.alpha == 0.3, "Borders.SetAlpha recedes the quality edge container")

    -- CELL PARITY: the JUNK COIN cascades too â€” shown at the dress alpha on a poor item that
    -- has value, hidden otherwise, and never resurrected on a dimmed cell.
    local coin = recorder(); coin.shown = false
    local btn4 = { icon = recorder(), JunkIcon = coin }
    Items._applyDress(btn4, Items.ResolveState({ quality = 0 }))
    ck(coin.shown == true and coin.alpha == 1.0, "coin shown at full alpha on a junk cell")
    Items._applyDress(btn4, Items.ResolveState({ quality = 0, dimmed = true }))
    ck(coin.shown == false and coin.alpha == 0, "coin hidden while the cell is search-dimmed")
    Items._applyDress(btn4, Items.ResolveState({ quality = 3 }))
    ck(coin.shown == false, "coin hidden on a non-junk cell")
end

-- SLOT-ART NEUTRALIZATION (empty-well blue-glow fix, defect #1 + the "most filled slots
-- rimmed" half of #2). The item-button templates ship a UI-Quickslot2 NormalTexture (a
-- bright bluish ring) that drew over our dark well. _neutralizeSlotArt must clear it (and
-- the native IconBorder) to invisible. Driven headless with a fake button exposing the
-- same accessors the real templates do â€” no CreateFrame needed.
local function testSlotArtNeutralized(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local function texRecorder()
        local t = { tex = "Interface\\Buttons\\UI-Quickslot2", alpha = 1, shown = true }
        function t:SetTexture(v) self.tex = v end
        function t:SetAlpha(a) self.alpha = a end
        function t:Hide() self.shown = false end
        function t:Show() self.shown = true end
        return t
    end

    -- A fake button with a NormalTexture + IconBorder (mirrors the live template shape).
    local normal, border = texRecorder(), texRecorder()
    local setNormalCalled = false
    local btn = {
        GetNormalTexture = function() return normal end,
        SetNormalTexture = function() setNormalCalled = true end,
        IconBorder = border,
    }
    local ret = Items._neutralizeSlotArt(btn)
    ck(ret == normal, "returns the neutralized NormalTexture")
    ck(normal.tex == nil, "NormalTexture texture cleared (UI-Quickslot2 killed)")
    ck(normal.alpha == 0, "NormalTexture alpha 0 (survives a later template :Show())")
    ck(normal.shown == false, "NormalTexture hidden")
    ck(btn._dsSlotArtHidden == normal, "marked _dsSlotArtHidden")
    ck(setNormalCalled == true, "button's stored normal texture blanked (no re-set)")
    -- CELL PARITY regression lock: the sweep must NOT touch IconBorder any more. 1.x re-tints
    -- and shows it (item.lua:210/220); borders.SetIconBorder owns it, and a sweep that blanked
    -- its texture would destroy the ring art the template put there.
    ck(border.alpha == 1 and border.shown == true, "IconBorder left alone by the sweep (borders.lua owns it)")
    ck(border.tex ~= nil, "â€¦and its texture is NOT blanked")
    ck(btn._dsArt == nil or btn._dsArt.iconBorder == nil, "IconBorder is not in the kill registry")

    -- Cached-button shape: no accessor, resolves NormalTexture by $parentNormalTexture.
    local gNormal = texRecorder()
    _G["DaseekiBags2FakeItemNormalTexture"] = gNormal
    local btn2 = { GetName = function() return "DaseekiBags2FakeItem" end }
    Items._neutralizeSlotArt(btn2)
    ck(gNormal.tex == nil and gNormal.alpha == 0, "global $parentNormalTexture fallback neutralized")
    _G["DaseekiBags2FakeItemNormalTexture"] = nil

    -- Robust to a button with neither accessor nor name (never errors, no-op).
    ck(Items._neutralizeSlotArt({}) == nil, "button without slot art -> safe no-op")
    ck(Items._neutralizeSlotArt(nil) == nil, "nil button -> safe no-op")
end

-- KILL-LIST PRESENCE GATE â€” proves the DEFENSIVE re-kill, not just the creation kill.
-- Builds a fake button with every art region VISIBLE, kills once, then simulates the
-- template's SetItemButtonQuality/OnShow resurrection (re-showing NormalTexture / IconBorder
-- / NewItemTexture and restarting the glow anim), runs the re-kill the hooks + paint sweep
-- would run, and asserts the art registry reports EVERYTHING hidden again. This is the gate
-- the institutional lesson demands: the render is defensive by construction, not verified
-- only at the moment of creation.
local function testKillListResurrection(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local function tex()
        local t = { alpha = 1, shown = true, tex = "art" }
        function t:SetTexture(v) self.tex = v end
        function t:SetAlpha(a) self.alpha = a end
        function t:Hide() self.shown = false end
        function t:Show() self.shown = true end
        function t:GetAlpha() return self.alpha end
        function t:IsShown() return self.shown end
        return t
    end
    local anim = { running = true }
    function anim:Stop() self.running = false end
    function anim:Finish() end
    local cd = { edge = true, bling = true }
    function cd:SetDrawEdge(v) self.edge = v end
    function cd:SetDrawBling(v) self.bling = v end

    local normal, iconBorder, newItem, battlepay, junk, quest, search =
        tex(), tex(), tex(), tex(), tex(), tex(), tex()
    local btn = {
        _dsDressed = true,   -- marks it "ours" for the hook bodies
        GetNormalTexture = function() return normal end,
        SetNormalTexture = function() end,
        IconBorder = iconBorder, NewItemTexture = newItem,
        BattlepayItemTexture = battlepay, JunkIcon = junk,
        IconQuestTexture = quest, searchOverlay = search,
        flashAnim = anim, newitemglowAnim = anim, Cooldown = cd,
    }

    Items._killTemplateArt(btn)
    ck(Items.ArtRegistryHidden(btn) == true, "after first kill: all art hidden")
    ck(anim.running == false, "new-item glow anim stopped")
    ck(cd.edge == false and cd.bling == false, "cooldown edge + bling quieted")
    for _, k in ipairs({ "normal", "newItem", "battlepay", "quest", "searchOverlay" }) do
        ck(btn._dsArt[k] ~= nil, "kill registry enumerates " .. k)
    end
    -- CELL PARITY: the two regions 1.x DRIVES are deliberately NOT in the registry.
    ck(btn._dsArt.iconBorder == nil, "IconBorder is not killed (borders.lua drives it â€” 1.x)")
    ck(btn._dsArt.junk == nil, "JunkIcon is not killed (the dress drives it â€” 1.x glowPoor)")

    -- RESURRECTION: the template re-shows its art (exactly what SetItemButtonQuality / the
    -- template OnShow do after our creation-time kill).
    normal:Show(); normal.alpha = 1; normal.tex = "UI-Quickslot2"
    newItem:Show(); newItem.alpha = 1
    anim.running = true
    ck(Items.ArtRegistryHidden(btn) == false, "resurrection is detectable (registry not all-hidden)")

    -- The re-kill the global hooks + paint sweep run:
    Items._killTemplateArt(btn)
    ck(Items.ArtRegistryHidden(btn) == true, "re-kill hides ALL resurrected art (defensive)")
    ck(anim.running == false, "re-kill re-stops the glow anim")
    ck(normal.alpha == 0 and newItem.alpha == 0,
        "re-kill parks NormalTexture/NewItemTexture at alpha 0")

    -- ...and the RE-ASSERT path puts OUR verdict back on the two owned regions. The button is
    -- a common (quality 1) with no flags, so both must end hidden; then a rare must ring.
    btn._quality, btn._unusable, btn._questItem, btn._isSet = 1, false, false, false
    iconBorder:Show(); iconBorder.alpha = 1; junk:Show(); junk.alpha = 1
    Items._reassertOwnedArt(btn)
    ck(iconBorder.shown == false and junk.shown == false,
        "re-assert drops the ring + coin a common must not carry")
    btn._quality = 4
    Items._reassertOwnedArt(btn)
    ck(iconBorder.shown == true, "re-assert restores the ring an epic must carry")
    btn._quality, btn._hasNoValue = 0, false
    Items._reassertOwnedArt(btn)
    ck(junk.shown == true, "re-assert restores the coin a valued poor item must carry")
    -- a foreign button (no dress marker) is never touched
    local foreign = { IconBorder = tex() }
    Items._reassertOwnedArt(foreign)
    ck(foreign.IconBorder.shown == true, "a button that is not ours is left alone")
end

-- CLICK-IDENTITY MATRIX (Task 2). Proves the LAYOUT MATH binds each render position to the
-- correct (cid, slot) as a 1:1 map across every mode, and that _setSlot writes that slot into
-- the secure button's GetID(). A stale-ID click bug (the "completely broken" suspect) would
-- surface here as a position carrying the wrong (cid,slot), or a duplicated / dropped pair.
local function testClickIdentityMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local o = newOwnerWith({
        [0]  = { size = 4, slots = { [1] = { id = 6948 }, [3] = { id = 22157, quality = 3 } } },
        [1]  = { size = 3, link = "item:14046", slots = { [2] = { id = 4234 } } },
        [-1] = { size = 2, slots = { [1] = { id = 4306 } } },
    })

    local function assertBijection(list, label)
        local seen = {}
        for i, e in ipairs(list) do
            ck(e.cid ~= nil and e.slot ~= nil, label .. " entry " .. i .. " carries cid+slot")
            local key = tostring(e.cid) .. ":" .. tostring(e.slot)
            ck(not seen[key], label .. " no duplicate (cid,slot) binding " .. key)
            seen[key] = true
        end
        return seen
    end

    -- COMBINED-FLAT: positions map to (cid,slot) â€” backpack 1..4, then bag 1..3, then bank 1..2.
    local flat = Items.BuildEntries(o, { scope = "all" })
    ck(#flat == 4 + 3 + 2, "combined flatten covers every slot of every container")
    assertBijection(flat, "combined")
    ck(flat[1].cid == 0 and flat[1].slot == 1, "combined pos1 = backpack slot1")
    ck(flat[3].cid == 0 and flat[3].slot == 3 and flat[3].data and flat[3].data.quality == 3,
        "combined pos3 = backpack slot3 (the rare) â€” position carries the RIGHT slot")
    ck(flat[5].cid == 1 and flat[5].slot == 1, "combined pos5 = bag1 slot1")

    -- SPLIT: each group is one cid; positions 1..size map to slots 1..size within that cid.
    local groups = Items.BuildGroups(o, { scope = "all" })
    for _, g in ipairs(groups) do
        for i, e in ipairs(g.entries) do
            ck(e.cid == g.cid, "split group " .. tostring(g.cid) .. " entry keeps its own cid")
            ck(e.slot == i, "split group slot follows render position")
        end
    end

    -- CATEGORIES (mixed-cid section): a category = a saved query, so its section mixes bags.
    -- Every entry must keep its ORIGINAL (cid,slot) â€” mixed cids allowed â€” and the section's
    -- pairs must equal the occupied source slots exactly (no repaint over a stale pair).
    local filled = {}
    for _, e in ipairs(flat) do if e.data then filled[#filled + 1] = e end end
    local seen = assertBijection(filled, "category section")
    ck(seen["0:1"] and seen["0:3"] and seen["1:2"] and seen["-1:1"],
        "mixed-cid section spans all bags with the exact source (cid,slot) pairs")

    -- RE-BUCKET STABILITY: a reorder / search pass reuses pooled buttons. Position i must ALWAYS
    -- rebind to entries[i]'s own (cid,slot) â€” never inherit a stale pair from its prior tenant.
    local flat2 = Items.BuildEntries(o, { scope = "all" })
    for i = 1, #flat2 do
        ck(flat2[i].cid == flat[i].cid and flat2[i].slot == flat[i].slot,
            "rebuild position " .. i .. " rebinds to the same (cid,slot)")
    end

    -- SetID BINDING: _setSlot writes the displayed slot into the secure button's GetID() and
    -- records cid/slot, so the template's secure click acts on exactly the pair it paints.
    local recorded = {}
    local fakeIcon = { SetTexture = function() end, SetAlpha = function() end,
                       SetDesaturated = function() end, SetVertexColor = function() end }
    local btn = { _live = true, icon = fakeIcon,
                  SetNormalTexture = function() end,
                  SetID = function(_, id) recorded.id = id end,
                  Show  = function() recorded.shown = true end }
    Items._setSlot(btn, o, 1, 2, o.containers[1].slots[2])
    ck(recorded.id == 2, "_setSlot -> button:SetID(displayed slot)")
    ck(btn._cid == 1 and btn._slot == 2, "_setSlot binds cid+slot fields to the displayed pair")
    ck(recorded.shown == true, "_setSlot shows the freshly-bound button")
end

-- CLASS PROFICIENCY MATRIX (Task 1 â€” the grey-wash fix). Locks the real Era rule
-- (Unfit parity) that ONLY class-unequippable weapon/armor washes, and that
-- consumables / non-gear never do. This is the regression guard for "IsUsableItem
-- greyed everything".
local function testProficiency(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local WEAPON, ARMOR = Items.ITEMCLASS_WEAPON, Items.ITEMCLASS_ARMOR
    local function wep(class, sub) return Items.ClassCannotEquip(class, WEAPON, sub, "INVTYPE_WEAPONMAINHAND") end
    local function arm(class, sub) return Items.ClassCannotEquip(class, ARMOR, sub, "INVTYPE_CHEST") end
    -- subclass shorthands
    local PLATE, MAIL, LEATHER, CLOTH, SHIELD = 4, 3, 2, 1, 6
    local AXE1H, SWORD1H, SWORD2H, MACE1H, BOW, STAFF, DAGGER, WAND, WARGLAIVE = 0, 7, 8, 4, 2, 10, 15, 19, 9

    -- WARRIOR: all armor incl. plate; every weapon but warglaive/wand.
    ck(arm("WARRIOR", PLATE) == false, "warrior can wear plate")
    ck(wep("WARRIOR", WAND) == true and wep("WARRIOR", WARGLAIVE) == true, "warrior can't wand/warglaive")
    ck(wep("WARRIOR", SWORD2H) == false and wep("WARRIOR", BOW) == false, "warrior can 2h sword/bow")
    -- MAGE: cloth only; staff/1h-sword/dagger/wand only.
    ck(arm("MAGE", CLOTH) == false, "mage cloth ok")
    ck(arm("MAGE", LEATHER) == true and arm("MAGE", MAIL) == true and arm("MAGE", PLATE) == true, "mage no leather/mail/plate")
    ck(wep("MAGE", STAFF) == false and wep("MAGE", WAND) == false and wep("MAGE", DAGGER) == false and wep("MAGE", SWORD1H) == false, "mage staff/wand/dagger/1h-sword ok")
    ck(wep("MAGE", SWORD2H) == true and wep("MAGE", MACE1H) == true and wep("MAGE", BOW) == true, "mage no 2h-sword/mace/bow")
    -- PRIEST: 1h mace ok, 1h sword no; cloth only.
    ck(wep("PRIEST", MACE1H) == false and wep("PRIEST", SWORD1H) == true, "priest mace1h ok, sword1h no")
    ck(arm("PRIEST", LEATHER) == true, "priest no leather")
    -- ROGUE: leather ok, mail no; dagger ok, staff no.
    ck(arm("ROGUE", LEATHER) == false and arm("ROGUE", MAIL) == true, "rogue leather ok, mail no")
    ck(wep("ROGUE", DAGGER) == false and wep("ROGUE", STAFF) == true, "rogue dagger ok, staff no")
    -- HUNTER: mail ok, plate no; bow ok, wand no.
    ck(arm("HUNTER", MAIL) == false and arm("HUNTER", PLATE) == true, "hunter mail ok, plate no")
    ck(wep("HUNTER", BOW) == false and wep("HUNTER", WAND) == true, "hunter bow ok, wand no")
    -- PALADIN: plate ok; sword/mace/axe ok, dagger/bow no.
    ck(arm("PALADIN", PLATE) == false, "paladin plate ok")
    ck(wep("PALADIN", SWORD1H) == false and wep("PALADIN", DAGGER) == true and wep("PALADIN", BOW) == true, "paladin sword ok, dagger/bow no")
    -- DRUID: leather ok, mail no; mace ok, sword no.
    ck(arm("DRUID", LEATHER) == false and arm("DRUID", MAIL) == true, "druid leather ok, mail no")
    ck(wep("DRUID", MACE1H) == false and wep("DRUID", SWORD1H) == true, "druid mace ok, sword no")
    -- SHAMAN: mail + shield ok, plate no; axe1h ok, sword no.
    ck(arm("SHAMAN", MAIL) == false and arm("SHAMAN", SHIELD) == false and arm("SHAMAN", PLATE) == true, "shaman mail/shield ok, plate no")
    ck(wep("SHAMAN", AXE1H) == false and wep("SHAMAN", SWORD1H) == true, "shaman axe1h ok, sword no")
    -- WARLOCK mirrors MAGE.
    ck(arm("WARLOCK", CLOTH) == false and arm("WARLOCK", MAIL) == true and wep("WARLOCK", DAGGER) == false, "warlock cloth/dagger ok, mail no")

    -- OFFHAND dual-wield rule: paladin (cannotDual) offhand weapon unusable; rogue usable.
    ck(Items.ClassCannotEquip("PALADIN", WEAPON, SWORD1H, "INVTYPE_WEAPONOFFHAND") == true, "paladin can't offhand a weapon (no dual-wield)")
    ck(Items.ClassCannotEquip("ROGUE", WEAPON, SWORD1H, "INVTYPE_WEAPONOFFHAND") == false, "rogue can offhand a weapon (dual-wield)")

    -- NON-GEAR never washes (any item class that isn't weapon/armor, any equipLoc).
    ck(Items.ClassCannotEquip("MAGE", 0, 5, "") == false, "consumable never unusable")
    ck(Items.ClassCannotEquip("WARRIOR", 7, 0, "") == false, "trade goods never unusable")
    ck(Items.ClassCannotEquip("MAGE", ARMOR, PLATE, "") == false, "non-equippable armor row (no slot) -> not washed")
    ck(Items.ClassCannotEquip("DEATHKNIGHT", WEAPON, WAND, "INVTYPE_WEAPONMAINHAND") == false, "unknown class never washes")
end

-- BELOW-LEVEL gate (additive per owner ask): equippable gear over the char level washes;
-- consumables/bags/ammo and unknown/uncached levels never do.
local function testBelowLevel(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Items.IsBelowLevel("INVTYPE_CHEST", 40, 30) == true, "gear req 40 at level 30 -> below level")
    ck(Items.IsBelowLevel("INVTYPE_CHEST", 40, 40) == false, "gear req 40 at level 40 -> usable")
    ck(Items.IsBelowLevel("INVTYPE_CHEST", 40, 41) == false, "gear req 40 at level 41 -> usable")
    ck(Items.IsBelowLevel("", 40, 1) == false, "non-equippable never below-level")
    ck(Items.IsBelowLevel("INVTYPE_BAG", 40, 1) == false, "bags exempt from level gate")
    ck(Items.IsBelowLevel("INVTYPE_AMMO", 40, 1) == false, "ammo exempt from level gate")
    ck(Items.IsBelowLevel("INVTYPE_CHEST", nil, 30) == false, "uncached minLevel never washes")
    ck(Items.IsBelowLevel("INVTYPE_CHEST", 1, 1) == false, "minLevel 1 never washes")
    ck(Items.IsBelowLevel("INVTYPE_CHEST", 40, nil) == false, "unknown player level -> safe (no wash)")
end

-- 1.0-LOOK PARITY (cell treatment on the Daseeki theme, ROUND 2): quality edges are now
-- FULL-SATURATION and drop to UNCOMMON+, and the UNUSABLE red border wins over the quality
-- edge. This bakes the REAL "Daseeki" theme tokens (theme.lua: pure-crimson cell borders
-- #3A0E12 / #6E0E1C, green `ok` #5FB86B) and verifies full-sat separability on the near-black
-- ground: every rarity color stays clearly apart from the crimson cell borders, the uncommon
-- green stays apart from the `ok` green, and the pure-red unusable border stays apart from
-- Legendary orange. Also asserts the SAME-cell invariant (a drawn edge hides the hairline).
local function testDaseekiCellVsQualityEdge(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local B = ns.Borders
    if not B then fails[#fails + 1] = "ns.Borders not loaded"; return end
    local border  = { 0.2275, 0.0549, 0.0706 }   -- #3A0E12  pure-crimson per-cell hairline (`border`)
    local ctrlBrd = { 0.4314, 0.0549, 0.1098 }   -- #6E0E1C  brighter crimson (`controlBorder`)
    local okGreen = { 0.3725, 0.7216, 0.4196 }   -- #5FB86B  theme `ok` (positive green)
    local function dist(a, b)
        local dr, dg, db = a[1] - b[1], a[2] - b[2], a[3] - b[3]
        return math.sqrt(dr * dr + dg * dg + db * db)
    end
    -- FULL-SATURATION rarity edges (no desaturation now) vs the crimson cell borders.
    local worst = 99
    for _, q in ipairs({ 2, 3, 4, 5, 6 }) do
        local r, g, b = B.QualityRGB(q)   -- static fallback (headless == live full-sat hues)
        local edge = { r, g, b }
        local d1, d2 = dist(edge, border), dist(edge, ctrlBrd)
        ck(d1 >= 0.35, "q" .. q .. " full-sat edge vs #3A0E12 cell border distinguishable (" .. string.format("%.2f", d1) .. ")")
        ck(d2 >= 0.30, "q" .. q .. " full-sat edge vs #6E0E1C strip border distinguishable (" .. string.format("%.2f", d2) .. ")")
        worst = math.min(worst, d1, d2)
    end
    ck(worst >= 0.30, "closest full-sat rarity/crimson pairing clears the floor (" .. string.format("%.2f", worst) .. ")")
    -- Uncommon green vs the `ok` green (owner's cross-check): different surfaces, still apart.
    ck(dist({ B.QualityRGB(2) }, okGreen) >= 0.30, "uncommon green distinguishable from the ok-token green")
    -- Unusable pure-red vs Legendary orange: the unusable cue never reads as legendary.
    ck(dist({ B.UnusableRGB() }, { B.QualityRGB(5) }) >= 0.30, "unusable red distinguishable from Legendary orange")
    -- 1.0 clean-cell invariant: a cell carries a border ONLY at uncommon+ (quality) or when
    -- unusable â€” common/poor/empty draw NO ring at all (the neutral hairline was removed).
    ck(B.ShouldShow(2, true) == true and B.ShouldShow(1, true) == false,
        "border only at uncommon+ (common/poor draw no ring â€” 1.0 clean cell)")
end

-- 1.0-PARITY grey-border removal + the 1.x quest tint: the CELL border-presence matrix.
-- Common/poor/empty draw NO ring (the universal neutral hairline is gone); uncommon+ get the
-- quality edge; unusable gets red (winning over quality); a QUEST item gets the gold tint,
-- which is 1.x's first branch and wins over both; borders-off draws nothing. This is the
-- styling the KEYRING keys inherit too â€” keys are common quality, so they render as clean
-- dark cells like 1.x.
local function testCellBorderMatrix(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local K = Items.CellBorderKind
    -- enabled, default Uncommon floor
    ck(K(nil, false, true, 2) == "none", "empty / no quality -> no ring")
    ck(K(0, false, true, 2)   == "none", "poor -> no ring (1.0 clean commons)")
    ck(K(1, false, true, 2)   == "none", "common (e.g. a KEY) -> no ring â€” clean like 1.x")
    ck(K(2, false, true, 2)   == "quality", "uncommon -> quality edge")
    ck(K(3, false, true, 2)   == "quality", "rare -> quality edge")
    ck(K(4, false, true, 2)   == "quality", "epic -> quality edge")
    -- unusable red WINS over quality (and over common)
    ck(K(4, true, true, 2)    == "unusable", "unusable epic -> red (wins over quality)")
    ck(K(1, true, true, 2)    == "unusable", "unusable common -> red")
    -- QUEST gold wins over EVERYTHING (1.x UpdateBorder branch order)
    ck(K(1, false, true, 2, true) == "quest", "quest common -> gold tint (no quality edge to beat)")
    ck(K(4, false, true, 2, true) == "quest", "quest epic -> gold tint wins over the quality edge")
    ck(K(4, true, true, 2, true)  == "quest", "quest + unusable -> gold tint wins over the red")
    ck(K(nil, false, true, 2, false) == "none", "explicit non-quest is inert")
    -- CELL PARITY: the equipment-set teal is a BORDER branch (1.x item.lua:201-202), below
    -- the unusable red and above the rarity edge.
    ck(K(3, false, true, 2, false, true) == "set", "set member -> teal, over its own rarity")
    ck(K(1, false, true, 2, false, true) == "set", "a COMMON set member still gets the teal")
    ck(K(3, true,  true, 2, false, true) == "unusable", "unusable beats the set teal")
    ck(K(3, false, true, 2, true,  true) == "quest", "quest gold beats the set teal")
    ck(K(3, false, false, 2, false, true) == "none", "borders off -> no teal either")
    -- configurable floor raises where the quality ring starts
    ck(K(2, false, true, 3)   == "none",    "min=Rare -> uncommon has no ring")
    ck(K(3, false, true, 3)   == "quality", "min=Rare -> rare gets the quality edge")
    -- borders OFF -> nothing at all, even unusable or quest
    ck(K(4, true, false, 2)   == "none", "borders off -> no ring at all (even unusable)")
    ck(K(2, false, false, 2)  == "none", "borders off -> uncommon draws no ring")
    ck(K(4, false, false, 2, true) == "none", "borders off -> quest draws no ring either")

    -- The 1.x quest gold itself: (1, .82, .2), read as fact from 1.x's UpdateBorder. It is
    -- deliberately NOT NORMAL_FONT_COLOR (1, .82, 0) â€” the blue channel is .2.
    local r, g, b = ns.Borders.QuestRGB()
    ck(r == 1 and g == 0.82 and b == 0.2, "quest gold is exactly 1, .82, .2 (1.x fact)")
    -- ...and it stays distinguishable from the unusable red on the same cell edge.
    local ur = select(1, ns.Borders.UnusableRGB())
    local _, ug = ns.Borders.UnusableRGB()
    ck(g > ug and ur >= r - 1e-9, "quest gold separates from the unusable red by the green channel")

    -- CROSS-CHECK against borders.lua's ResolveTint, which is the single decision the halo
    -- AND the well yield both key off. "This cell carries a ring" and "this cell glows" must
    -- be the same predicate, or a cell could suppress its well without glowing (or glow with
    -- its grey well still up â€” the defect this lock exists to prevent).
    -- case = { quality, unusable, enabled, minQuality, quest, set }
    for _, c in ipairs({
        { nil, false, true, 2, false, false }, { 0, false, true, 2, false, false },
        { 1, false, true, 2, false, false },   { 2, false, true, 2, false, false },
        { 4, false, true, 2, false, false },   { 4, true,  true, 2, false, false },
        { 1, false, true, 2, true,  false },   { 4, true,  true, 2, true,  false },
        { 4, true,  false, 2, true, false },   { 2, false, true, 3, false, false },
        { 3, false, true, 3, false, false },
        -- the equipment-set teal branch (1.x item.lua:201-202) must agree too
        { 1, false, true, 2, false, true },    { 3, false, true, 4, false, true },
        { 3, true,  true, 2, false, true },    { 3, false, false, 2, false, true },
    }) do
        local kind  = K(c[1], c[2], c[3], c[4], c[5], c[6])
        local glows = ns.Borders.GlowShown(c[1], c[2], c[5], c[6], c[3], c[4])
        ck((kind ~= "none") == glows,
            "CellBorderKind agrees with Borders.GlowShown for q=" .. tostring(c[1])
            .. " (kind=" .. kind .. ", glows=" .. tostring(glows) .. ")")
    end
end

-- RUN SPLIT (1.0 keyring row-break). The defect: the keyring began at flat index
-- (Î£ bag slots)+1 and therefore at column (Î£ bag slots) % columns â€” mid-row, "floating".
-- The fix breaks the row at the generic->keyring family boundary. These cases pin the
-- exact geometry at the owner's real 11-column config.
local function testRunSplit(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local COLS, SZ, GAP = 11, 37, 2
    local PITCH = SZ + GAP                     -- 39
    local RG = Items.RUN_GAP

    -- flow class comes from the cid CLASS, never a captured family field
    ck(Items.FlowClass(0) == "generic",  "backpack is generic")
    ck(Items.FlowClass(1) == "generic",  "carried bag is generic")
    ck(Items.FlowClass(-2) == "keyring", "keyring (-2) is its own flow class")

    -- N generic slots + M keys => exactly two runs, the keyring run starting at N+1
    local function entries(nGeneric, mKeys)
        local e = {}
        for i = 1, nGeneric do e[#e + 1] = { cid = (i <= 16) and 0 or 1, slot = i } end
        for i = 1, mKeys do e[#e + 1] = { cid = -2, slot = i } end
        return e
    end
    local N, M = 36, 12                        -- 36 % 11 = 3 -> the defect's mid-row start
    local e = entries(N, M)
    local runs = Items.SplitRuns(e)
    ck(#runs == 2, "generic+keyring -> 2 runs, got " .. #runs)
    ck(runs[1].from == 1 and runs[1].n == N and runs[1].class == "generic", "run 1 = the 36 bag slots")
    ck(runs[2].from == N + 1 and runs[2].n == M and runs[2].class == "keyring", "run 2 = the 12 keyring slots")

    local L = Items.RunLayout(runs, COLS, SZ, GAP)
    -- run 1: 4 rows (36 = 3*11 + 3). run 2 starts one full row-gap + RUN_GAP below it.
    local run1H = Items.GridMetrics(N, COLS, SZ, GAP).height
    ck(L.runs[1].y == 0, "run 1 starts at the top")
    ck(L.runs[2].y == -(run1H + GAP + RG), "run 2 top = run1 height + gap + RUN_GAP")
    ck(L.height == run1H + GAP + RG + Items.GridMetrics(M, COLS, SZ, GAP).height,
       "total height = both runs + the break, got " .. L.height)
    ck(L.rows == 4 + 2, "4 bag rows + 2 keyring rows")

    -- POSITIONS: the last bag cell sits at column 2 of row 3; the FIRST KEY resets to
    -- column 0 of a brand-new row (the whole point of the fix).
    local x36, y36 = Items.RunSlotPosition(L, 36, COLS, SZ, GAP)
    ck(x36 == 2 * PITCH and y36 == -(3 * PITCH), "bag slot 36 = col 2, row 3")
    local x37, y37 = Items.RunSlotPosition(L, 37, COLS, SZ, GAP)
    ck(x37 == 0, "FIRST KEY starts at column 0 (1.0 row break), got x=" .. x37)
    ck(y37 == -(4 * PITCH + RG), "first key drops a full row + RUN_GAP below the bags")
    -- flat math would have put it mid-row â€” the regression guard
    local fx = Items.SlotPosition(37, COLS, SZ, GAP)
    ck(fx == 3 * PITCH and x37 ~= fx, "the OLD flat flow put key 1 at column 3 (the defect)")
    -- the rest of the keyring flows normally inside its own run
    local x48, y48 = Items.RunSlotPosition(L, 48, COLS, SZ, GAP)
    ck(x48 == 0 and y48 == -(5 * PITCH + RG), "key 12 wraps to the keyring run's 2nd row, col 0")

    -- A boundary-aligned bag run still gets the gap (1.x adds breakSpace unconditionally).
    local L2 = Items.RunLayout(Items.SplitRuns(entries(33, 4)), COLS, SZ, GAP)
    local kx, ky = Items.RunSlotPosition(L2, 34, COLS, SZ, GAP)
    ck(kx == 0 and ky == -(3 * PITCH + RG), "33 slots end the row; the key still gets the break gap")

    -- Degenerate / single-run inputs behave exactly like the plain grid.
    ck(#Items.SplitRuns({}) == 0, "empty list -> no runs")
    ck(Items.RunLayout({}, COLS, SZ, GAP).height == 0, "no runs -> zero height")
    local only = Items.RunLayout(Items.SplitRuns(entries(20, 0)), COLS, SZ, GAP)
    ck(only.height == Items.GridMetrics(20, COLS, SZ, GAP).height, "single run -> plain grid height")
    for i = 1, 20 do
        local ax, ay = Items.RunSlotPosition(only, i, COLS, SZ, GAP)
        local bx, by = Items.SlotPosition(i, COLS, SZ, GAP)
        ck(ax == bx and ay == by, "single run cell " .. i .. " matches the flat position")
    end
    -- A keyring-ONLY view (all bags hidden) is one run and never gets a leading gap.
    local kOnly = Items.RunLayout(Items.SplitRuns(entries(0, 6)), COLS, SZ, GAP)
    ck(kOnly.runs[1].y == 0, "keyring-only view starts at the top (no leading break)")
end

-- MARKER ART (defect #2). The markers were literal SetColorTexture squares â€” an amber box
-- where 1.0 shows the quest bang. This locks the ART CONTRACT: every marker names a real
-- texture, the quest marker is the native bang glyph 1.x uses, and the token pips carry a
-- shape mask so they render round. Also guards the Core-less white-square token gap.
local function testMarkerArt(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local q = Items.MarkerArt("quest")
    ck(q ~= nil and type(q.texture) == "string" and q.texture ~= "", "quest marker names a texture")
    ck(q.glyph == true and q.token == nil, "quest marker is native glyph art, not a token fill")
    ck(q.texture == Items.QuestBangTexture(), "quest marker uses the resolved bang texture")
    -- 1.x fact (core/classes/item.lua:47): QuestBang is painted with TEXTURE_ITEM_QUEST_BANG.
    -- We read the same FrameXML constant, with the Era path as the never-nil guard.
    local saved = _G.TEXTURE_ITEM_QUEST_BANG
    _G.TEXTURE_ITEM_QUEST_BANG = nil
    ck(Items.QuestBangTexture() == Items.TEX_QUEST_BANG, "constant absent -> literal Era bang path")
    ck(Items.TEX_QUEST_BANG:find("QuestBang", 1, true) ~= nil, "the fallback IS the quest-bang art")
    _G.TEXTURE_ITEM_QUEST_BANG = "Interface\\SomeOther\\Bang"
    ck(Items.MarkerArt("quest").texture == "Interface\\SomeOther\\Bang",
       "constant present -> the game's own value wins")
    _G.TEXTURE_ITEM_QUEST_BANG = saved

    for _, kind in ipairs({ "new" }) do
        local a = Items.MarkerArt(kind)
        ck(a ~= nil, kind .. " marker has an art spec")
        ck(a.texture == Items.TEX_WHITE, kind .. " pip is a WHITE8X8 fill (theme-tintable)")
        ck(a.mask == Items.TEX_DOT_MASK, kind .. " pip carries the ROUND mask (not a hard square)")
        ck(type(a.token) == "string", kind .. " pip is token-tinted")
        ck(a.sizeRatio > 0 and a.sizeRatio < 1, kind .. " pip stays a corner pip")
    end
    -- sizes/tokens/corners unchanged from the squares they replace
    ck(Items.MarkerArt("new").token == "brand" and Items.MarkerArt("new").sizeRatio == 0.24,
       "new dot keeps brand @ 0.24")
    ck(Items.MarkerArt("new").anchor == "TOPRIGHT", "new-dot corner unchanged")
    -- CELL PARITY: the equipment-set corner pip is retired; 1.x makes it a glow branch.
    ck(Items.MarkerArt("set") == nil, "set pip retired (1.x expresses sets as a teal glow)")
    ck(Items.MarkerArt("nope") == nil, "unknown marker kind -> nil")
    -- the mask is OUR shipped stencil, addressed through the live addon folder
    ck(Items.TEX_DOT_MASK:find("art\\dot%-mask") ~= nil, "mask path points at the shipped art/dot-mask")

    -- TOKEN FALLBACK: with no Daseeki-Core, an unlisted token returned {1,1,1} => a PURE
    -- WHITE marker. Every token the dress paints must have a fallback entry.
    local savedUI = _G.DaseekiUI
    _G.DaseekiUI = nil
    for _, tok in ipairs({ "brand", "bronze", "warn", "danger", "inset", "raised", "border", "borderLite", "text", "idle" }) do
        local r, g, b = Items._tokenRGB(tok)
        ck(not (r == 1 and g == 1 and b == 1), "Core-less token '" .. tok .. "' is not white")
    end
    _G.DaseekiUI = savedUI
end

-- EQUIPMENT-SET MEMBERSHIP â€” the predicate behind the teal regression. Driven against
-- REAL Daseeki-Armory shapes (core.lua:59 / sets.lua:143-149), including the malformed
-- ones a foreign SavedVariables file can legitimately hand us.
local function testSetMembership(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- An Armory db with two sets. `equip` is keyed BY SLOT ID, not a list â€” reading it as
    -- a list, or testing "does any set data exist", is the class of bug this guards.
    local armory = {
        sets = {
            ["1 - DPS"] = {
                name = "1 - DPS", order = 1,
                equip = {
                    [1]  = { id = 23244, exact = "23244:0:0" },
                    [16] = { id = 23577, exact = "23577:1900:0" },
                },
                disabled = { [4] = true, [19] = true },
            },
            ["2 - PvP"] = {
                name = "2 - PvP", order = 2,
                equip = {
                    [13] = { id = 19341, exact = "19341:0:0" },
                },
                -- slot 13 is disabled in THIS set: the item is parked, not a member
                disabled = { [13] = true },
            },
        },
    }

    -- ITEM IN A SET -> true (both sets, both slots)
    ck(Items.ArmoryNamesItem(armory, 23244) == true, "an item a set names is a member")
    ck(Items.ArmoryNamesItem(armory, 23577) == true, "â€¦in any slot of any set")
    -- ITEM NOT IN ANY SET -> false (falls through to the rarity path)
    ck(Items.ArmoryNamesItem(armory, 12345) == false, "an item no set names is NOT a member")
    -- A DISABLED slot is not equipped by that set, so its item is not a member.
    ck(Items.ArmoryNamesItem(armory, 19341) == false, "an item in a DISABLED set slot is not a member")

    -- NO ARMORY / EMPTY SETS -> never true. These are the "matched almost everything"
    -- shapes: a nil db, a db with no sets key, and a sets table that exists but is empty.
    ck(Items.ArmoryNamesItem(nil, 23244) == false, "no Armory at all -> never a member")
    ck(Items.ArmoryNamesItem({}, 23244) == false, "Armory with no sets table -> never a member")
    ck(Items.ArmoryNamesItem({ sets = {} }, 23244) == false, "an EMPTY sets table -> never a member")
    ck(Items.ArmoryNamesItem({ sets = { A = { name = "A", equip = {} } } }, 23244) == false,
        "a set with no equipped items -> never a member")

    -- MALFORMED foreign data must be inert, never an error into the paint path.
    ck(Items.ArmoryNamesItem({ sets = { A = true } }, 23244) == false, "a non-table set is skipped")
    ck(Items.ArmoryNamesItem({ sets = { A = { equip = 7 } } }, 23244) == false, "a non-table equip is skipped")
    ck(Items.ArmoryNamesItem({ sets = { A = { equip = { [1] = 5 } } } }, 23244) == false,
        "a non-table equip ENTRY is skipped")
    ck(Items.ArmoryNamesItem(armory, nil) == false, "a nil item id is never a member")
    ck(Items.ArmoryNamesItem(armory, "23244") == false, "a STRING item id never matches a numeric one")

    -- MUTATION: if the predicate degraded to "does this Armory have any set data at all"
    -- (the shape of the reported over-match), the not-a-member case would flip. Prove the
    -- suite would catch that by running the broken predicate against the same fixtures.
    local broken = function(db, id)
        return (type(db) == "table" and type(db.sets) == "table" and next(db.sets) ~= nil) and true or false
    end
    ck(broken(armory, 12345) ~= Items.ArmoryNamesItem(armory, 12345),
        "MUTATION: an 'any set data exists' predicate is detected on a non-member")
    ck(broken(armory, 19341) ~= Items.ArmoryNamesItem(armory, 19341),
        "MUTATION: â€¦and on an item parked in a disabled slot")

    -- 1.x's EQUIPPABLE gate (ItemSearch-1.3/API.lua:115/130) â€” a gear set can only ever
    -- contain something that goes on the character.
    ck(Items.IsEquippableLoc("INVTYPE_HEAD") == true, "an equip location is equippable")
    ck(Items.IsEquippableLoc("") == false, "no equip location (a consumable) is not")
    ck(Items.IsEquippableLoc(nil) == false, "a nil equip location is not")
    ck(Items.IsEquippableLoc("INVTYPE_BAG") == false, "a BAG is not gear a set can name")

    -- THE TOGGLE. Default (key absent) is OFF: 1.x cannot draw this cue on Classic Era
    -- with ItemRack disabled, so off is the parity default.
    local savedDb = ns.Store and ns.Store.db
    if ns.Store then
        ns.Store.db = nil
        ck(Items.SetCueEnabled() == false, "no store yet -> cue off")
        ns.Store.db = {}
        ck(Items.SetCueEnabled() == false, "setMarkers absent -> cue OFF (1.x parity)")
        ns.Store.db = { setMarkers = false }
        ck(Items.SetCueEnabled() == false, "setMarkers=false -> cue off")
        ns.Store.db = { setMarkers = true }
        ck(Items.SetCueEnabled() == true, "setMarkers=true -> cue on (opt-in)")
        ns.Store.db = savedDb
    end
end

-- SLOT SUBSTRATE â€” the owner's three profile values and their SCOPE.
local function testSlotSubstrate(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedDb = ns.Store and ns.Store.db

    -- Defaults with no stored value: the owner's live 1.x profile.
    if ns.Store then ns.Store.db = nil end
    ck(Items.SlotBackground() == Items.DEFAULT_SLOT_BACKGROUND, "slotBackground default = owner's 6")
    ck(Items.SlotAlpha() == Items.DEFAULT_SLOT_ALPHA, "slotAlpha default = owner's 0.29")
    do
        local r, g, b, a = Items.SlotBorderColor()
        local d = Items.DEFAULT_SLOT_BORDER_COLOR
        ck(r == d[1] and g == d[2] and b == d[3] and a == d[4], "slotBorderColor default = owner's maroon @59%")
    end

    -- Stored values win, and are clamped/validated.
    if ns.Store then
        ns.Store.db = { slotBackground = 2, slotAlpha = 1 }
        ck(Items.SlotBackground() == 2 and Items.SlotAlpha() == 1, "stored values are honoured")
        ns.Store.db = { slotBackground = 1 }
        ck(Items.SlotBackground() == 1, "'None' (1) is a real choice, not a fallback")
        ck(Items.SlotBackgroundArt(1) == nil, "â€¦and it resolves to no art")
        ns.Store.db = { slotBackground = 99 }
        ck(Items.SlotBackground() == Items.DEFAULT_SLOT_BACKGROUND, "an unknown enum falls back")
        ns.Store.db = { slotAlpha = 5 }
        ck(Items.SlotAlpha() == 1, "slotAlpha clamps above 1")
        ns.Store.db = { slotAlpha = -3 }
        ck(Items.SlotAlpha() == 0, "slotAlpha clamps below 0")
        ns.Store.db = { slotBorderColor = { 1, 0, 0 } }
        do local r, _, _, a = Items.SlotBorderColor(); ck(r == 1 and a == 1, "a 3-element colour reads as opaque") end
        ns.Store.db = { slotBorderColor = "nope" }
        do local r = Items.SlotBorderColor(); ck(r == Items.DEFAULT_SLOT_BORDER_COLOR[1], "a malformed colour falls back") end
        ns.Store.db = savedDb
    end

    -- SCOPE (1.x item.lua:157-167 vs :171-174): the background/alpha are EMPTY-only, the
    -- border is every cell. The state spec is where the empty-only half is decided.
    ck(Items.ResolveState({ emptySlot = true }).iconAlpha == Items.SlotAlpha(),
        "an EMPTY cell's icon carries slotAlpha")
    ck(Items.ResolveState({ quality = 1, filled = true }).iconAlpha == 1,
        "a FILLED cell's icon does not")
    ck(Items.ResolveState({ quality = nil }).emptySlot == true,
        "a nil-quality undeclared cell still reads as empty (back-compat callers)")
    ck(Items.ResolveState({ quality = 1, filled = true }).emptySlot == false,
        "â€¦and a filled one does not")
    -- The dim multiplies with slotAlpha rather than replacing it (1.x :167 x :233).
    local dimEmpty = Items.ResolveState({ emptySlot = true, dimmed = true })
    ck(dimEmpty.dressAlpha == Items.DimValues(true) and dimEmpty.iconAlpha == Items.SlotAlpha(),
        "a dimmed EMPTY cell composes both alphas")
end

-- SORT-LOCK CELL LAYER: the mark follows the LOCK, the catcher follows the MODE, and a
-- cached (non-live) cell is never made editable. Driven with fake regions — the real
-- ones are created by CreateFrame, which the headless harness deliberately does not
-- stub, so the layer's DECISIONS are what is asserted here (the creation itself is a
-- three-line CreateFrame body verified in-game).
local function testLockLayer(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local L = ns.Locks
    if not L then fails[#fails + 1] = "ns.Locks missing (load order changed?)"; return end

    local function region()
        local r = { shown = false }
        function r:Show() self.shown = true end
        function r:Hide() self.shown = false end
        function r:SetShown(v) self.shown = v and true or false end
        function r:IsShown() return self.shown end
        function r:SetVertexColor() end
        return r
    end
    local function fakeButton(live, cid, slot)
        return { _live = live, _cid = cid, _slot = slot,
                 _dsLockMark = region(), _dsLockCatch = region() }
    end

    -- Isolate the store + the mode.
    local savedDB, savedSelf, savedMode = ns.Store.db, L._self, L._mode
    ns.Store.db = {}
    L.SetCharacter("Tester-TestRealm")
    L._mode = false

    local locked   = fakeButton(true, 0, 3)
    local unlocked = fakeButton(true, 0, 4)
    local cached   = fakeButton(false, 0, 5)
    L.SetLocked(0, 3, true)

    -- MODE OFF: nothing on screen, whatever the lock state says.
    for _, b in ipairs({ locked, unlocked, cached }) do Items._applyLockLayer(b) end
    ck(locked._dsLockMark.shown == false, "mode off: no mark even on a locked slot")
    ck(locked._dsLockCatch.shown == false, "mode off: no click catcher (items stay interactive)")

    -- MODE ON: catchers up everywhere LIVE; the mark only where the slot is locked.
    L._mode = true
    for _, b in ipairs({ locked, unlocked, cached }) do Items._applyLockLayer(b) end
    ck(locked._dsLockMark.shown == true, "mode on: the locked slot wears the mark")
    ck(locked._dsLockCatch.shown == true, "mode on: the locked slot takes clicks")
    ck(unlocked._dsLockMark.shown == false, "mode on: an unlocked slot wears no mark")
    ck(unlocked._dsLockCatch.shown == true, "mode on: an unlocked slot still takes clicks")
    ck(cached._dsLockCatch.shown == false, "a CACHED (offline-owner) cell is never editable")
    ck(cached._dsLockMark.shown == false, "a CACHED cell never wears the mark")

    -- A slot toggled while the mode is open repaints to the new state.
    L.SetLocked(0, 4, true)
    Items._applyLockLayer(unlocked)
    ck(unlocked._dsLockMark.shown == true, "locking a slot lights its mark")
    L.SetLocked(0, 4, false)
    Items._applyLockLayer(unlocked)
    ck(unlocked._dsLockMark.shown == false, "unlocking a slot clears its mark")

    -- A button with no slot identity (pooled/cleared) is inert, not crashy.
    local orphan = fakeButton(true, nil, nil)
    Items._applyLockLayer(orphan)
    ck(orphan._dsLockCatch.shown == false, "a button with no (cid, slot) never takes clicks")

    -- EXIT restores every cell in one pass — the "restore fully on exit" contract.
    L._mode = false
    Items._applyLockLayer(locked); Items._applyLockLayer(unlocked)
    ck(locked._dsLockMark.shown == false and locked._dsLockCatch.shown == false,
       "leaving the mode hides the mark AND releases the click catcher")
    ck(unlocked._dsLockCatch.shown == false, "...on every cell, not just the locked ones")

    -- The art is a real shipped path, not a colour fill (same rule as Items.MarkerArt).
    ck(type(Items.TEX_LOCK_SLOT) == "string" and Items.TEX_LOCK_SLOT:find("icon%-lock%-slot"),
       "the lock mark is the shipped prohibition-sign texture")

    ns.Store.db, L._self, L._mode = savedDB, savedSelf, savedMode
end

function Items.RunSelfTests(verbose)
    local suites = {
        { name = "grid math",          fn = testGridMath },
        { name = "run split (keyring break)", fn = testRunSplit },
        { name = "marker art",         fn = testMarkerArt },
        { name = "cell border matrix", fn = testCellBorderMatrix },
        { name = "daseeki cell vs edge", fn = testDaseekiCellVsQualityEdge },
        { name = "proficiency matrix", fn = testProficiency },
        { name = "below-level gate",   fn = testBelowLevel },
        { name = "entry building",     fn = testEntryBuilding },
        { name = "quality derivation", fn = testQualityDerivation },
        { name = "dim + cached age",   fn = testDimAndAge },
        { name = "cell clamp",         fn = testCellClamp },
        { name = "state precedence",   fn = testStatePrecedence },
        { name = "quest flags (1.x)",  fn = testQuestFlags },
        { name = "dim cascade",        fn = testDimCascade },
        { name = "slot-art neutralized", fn = testSlotArtNeutralized },
        { name = "kill-list resurrection", fn = testKillListResurrection },
        { name = "click-identity matrix",  fn = testClickIdentityMatrix },
        { name = "set membership (Armory)", fn = testSetMembership },
        { name = "slot substrate (1.x profile)", fn = testSlotSubstrate },
        { name = "sort-lock cell layer", fn = testLockLayer },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS ui_items/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL ui_items/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ui_items", Items.RunSelfTests)
end

return Items
