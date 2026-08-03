-- Daseeki Bags 2.0 — capture.lua
-- Live inventory scan for THIS character on the WoW Classic Era 1.15 event
-- surface, written into the store's owner record. Every API touched here is
-- catalog-verified against wow-api-catalog/1.15.9.68808:
--
--   C_Container.GetContainerNumSlots(cid)                 -> numSlots
--   C_Container.GetContainerItemInfo(cid, slot)           -> ContainerItemInfo
--         (struct: .itemID .stackCount .quality .hyperlink .isBound ...)
--   C_Container.GetContainerItemLink(cid, slot)           -> itemLink (fallback)
--   C_Container.ContainerIDToInventoryID(cid)             -> inventoryID (bag's slot)
--   GetInventoryItemLink("player", invID)                 -> the bag item link
--   GetMoney()                                            -> copper
--
-- Events (all present in the catalog, SCREAMING_SNAKE forms):
--   BAG_UPDATE, BAG_UPDATE_DELAYED, PLAYERBANKSLOTS_CHANGED,
--   PLAYERBANKBAGSLOTS_CHANGED, BANKFRAME_OPENED, BANKFRAME_CLOSED, PLAYER_MONEY
-- The keyring has no dedicated event on Era: it updates through BAG_UPDATE with
-- bagID == KEYRING_CONTAINER (-2).
--
-- Bank rule: bank containers are only READABLE while the bank frame is open, so
-- we gate bank scanning on a BANKFRAME_OPENED..CLOSED window and otherwise leave
-- the last-seen bank snapshot untouched (its per-container ts goes stale — that
-- is the intended "as last parked" behaviour).
--
-- The heavy lifting lives in PURE functions (BuildSlot / ScanContainer /
-- BuildSnapshot) that take an injected `api` table, so the headless harness can
-- drive a full scan with a fake container API — no live globals required.

local ADDON, ns = ...

local Capture = {}
ns.Capture = Capture

local Store = ns.Store

----------------------------------------------------------------------
-- Identity helpers (live)
----------------------------------------------------------------------

local function selfNameRealm()
    local name  = (_G.UnitName and _G.UnitName("player")) or "Unknown"
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))   -- SV realm keys are space-stripped in 1.x
    return Store.MakeNameRealm(name, realm), name, realm
end

local function liveIdentity()
    local ident = {}
    if _G.UnitClass then
        local _, tag = _G.UnitClass("player")
        ident.class = tag
    end
    if _G.UnitRace then
        local _, tag = _G.UnitRace("player")
        ident.race = tag
    end
    if _G.UnitSex     then ident.sex     = _G.UnitSex("player") end
    if _G.UnitFactionGroup then ident.faction = _G.UnitFactionGroup("player") end
    if _G.UnitLevel   then ident.level   = _G.UnitLevel("player") end
    return ident
end

----------------------------------------------------------------------
-- PURE scan core (api-injected; unit-testable headless)
--
-- `api` shape (every field a function; all optional except numSlots/itemInfo):
--   api.numSlots(cid)          -> numSlots (0/nil => empty/absent container)
--   api.itemInfo(cid, slot)    -> { itemID, stackCount, quality, hyperlink } | nil
--   api.bagLink(cid)           -> string link of the bag item in this slot | nil
--   api.bagFamily(cid)         -> number bag family bitmask | nil
----------------------------------------------------------------------

-- Turn one ContainerItemInfo-style struct into a store slot, or nil if empty.
function Capture.BuildSlot(info)
    if type(info) ~= "table" then return nil end
    local id = info.itemID
    if not id then return nil end
    return Store.NewSlot(id, info.stackCount or 1, info.quality, info.hyperlink)
end

-- Scan a single container into a fresh store container table (nil if the
-- container does not exist for this character, e.g. an unowned bag slot).
function Capture.ScanContainer(cid, api)
    local n = api.numSlots and api.numSlots(cid)
    if not n or n <= 0 then
        -- A zero-size result means "no bag here". We still return an empty
        -- container for real storage ids (backpack/bank/keyring) so their
        -- emptiness is recorded; for unowned bag slots we return nil.
        local class = Store.ContainerClass(cid)
        if class == "bag" or class == "bankbag" then return nil end
        n = n or 0
    end
    local link   = api.bagLink   and api.bagLink(cid)   or nil
    local family = api.bagFamily and api.bagFamily(cid) or nil
    local c = Store.NewContainer(n, link, family)
    for slot = 1, n do
        local slotRec = Capture.BuildSlot(api.itemInfo and api.itemInfo(cid, slot))
        if slotRec then c.slots[slot] = slotRec end
    end
    return c
end

-- The full list of container ids to scan for a given scope.
--   scope.bank == true   -> include bank main (-1) and bank bags
--   always                -> backpack (0), carried bags (1..N), keyring (-2)
function Capture.ContainerIDs(scope)
    local ids = { Store.BACKPACK_CONTAINER }
    for i = 1, Store.NumBagSlots() do ids[#ids + 1] = i end
    ids[#ids + 1] = Store.KEYRING_CONTAINER
    if scope and scope.bank then
        ids[#ids + 1] = Store.BANK_CONTAINER
        local first = Store.NumBagSlots() + 1
        local last  = Store.NumBagSlots() + Store.NumBankBagSlots()
        for i = first, last do ids[#ids + 1] = i end
    end
    return ids
end

-- Build a complete snapshot into `owner` using `api`. Bank containers are only
-- touched when scope.bank is set (frame open), so a normal carried-bag update
-- never clobbers the parked bank snapshot. `now` is injectable for tests.
-- Returns counts { containers, slots }.
function Capture.BuildSnapshot(owner, api, scope, now)
    now = now or Store.Now()
    local nContainers, nSlots = 0, 0
    for _, cid in ipairs(Capture.ContainerIDs(scope)) do
        local c = Capture.ScanContainer(cid, api)
        if c then
            Store.PutContainer(owner, cid, c, now)
            nContainers = nContainers + 1
            for _ in pairs(c.slots) do nSlots = nSlots + 1 end
        end
    end
    Store.RecomputeItemCounts(owner)
    Store.BumpRevision(owner, now)
    return { containers = nContainers, slots = nSlots }
end

----------------------------------------------------------------------
-- Live API binding (C_Container) — only built in-game
----------------------------------------------------------------------

local function liveAPI()
    local CC = _G.C_Container
    if not CC then return nil end
    return {
        numSlots = CC.GetContainerNumSlots,
        itemInfo = function(cid, slot)
            -- GetContainerItemInfo returns a ContainerItemInfo struct on 1.15.
            local info = CC.GetContainerItemInfo and CC.GetContainerItemInfo(cid, slot)
            if type(info) == "table" then return info end
            return nil
        end,
        bagLink = function(cid)
            if cid <= 0 then return nil end   -- backpack/bank/keyring have no bag item
            if not CC.ContainerIDToInventoryID or not _G.GetInventoryItemLink then
                return nil
            end
            local invID = CC.ContainerIDToInventoryID(cid)
            if not invID then return nil end
            return _G.GetInventoryItemLink("player", invID)
        end,
        bagFamily = function(cid)
            if cid <= 0 then return nil end
            local _, fam = CC.GetContainerNumFreeSlots and CC.GetContainerNumFreeSlots(cid)
            return fam
        end,
    }
end

----------------------------------------------------------------------
-- Live capture + debounce (Nexus RequestCapture pattern)
----------------------------------------------------------------------

Capture._bankOpen    = false   -- BANKFRAME_OPENED..CLOSED window
Capture._captureQueued = false

-- Perform one live capture into the store. No-ops headless (no C_Container).
function Capture.Capture()
    if not Store.data then return end
    local api = liveAPI()
    if not api then return end

    local nameRealm, name, realm = selfNameRealm()
    local owner = Store.EnsureOwner(nameRealm, name, realm)
    owner.source  = "full"
    owner.account = Store.data.selfAccount or ""

    Store.SetIdentity(owner, liveIdentity())
    if _G.GetMoney then Store.SetMoney(owner, _G.GetMoney()) end

    Capture.CaptureEquip(owner)

    Capture.BuildSnapshot(owner, api, { bank = Capture._bankOpen })

    if ns.Fire then ns:Fire("BAGS_CAPTURED", nameRealm, owner) end
end

-- Snapshot equipped items (appearance-relevant). Best-effort; guarded.
function Capture.CaptureEquip(owner)
    if not _G.GetInventoryItemID then return end
    owner.equip = {}
    -- Classic equipment slots 1..19 (INVSLOT_FIRST_EQUIPPED..LAST). We probe
    -- the stable range; absent slots simply return nil.
    for invSlot = 1, 19 do
        local id = _G.GetInventoryItemID("player", invSlot)
        if id then
            local count = (_G.GetInventoryItemCount and _G.GetInventoryItemCount("player", invSlot)) or 1
            owner.equip[invSlot] = { id = id, count = count }
        end
    end
end

-- Coalesce bursty bag events into one capture on the next frame tick.
function Capture.RequestCapture()
    if Capture._captureQueued then return end
    Capture._captureQueued = true
    local fire = function()
        Capture._captureQueued = false
        if ns.SafeCall then ns:SafeCall(Capture.Capture) else Capture.Capture() end
    end
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, fire)
    else
        fire()
    end
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

function Capture.OnLogin()
    local events = {
        "BAG_UPDATE_DELAYED",         -- primary carried-bag refresh (coalesced by Blizzard)
        "BAG_UPDATE",                 -- also carries keyring (bagID -2)
        "PLAYER_MONEY",               -- gold changed
        "PLAYERBANKSLOTS_CHANGED",    -- bank main slots
        "PLAYERBANKBAGSLOTS_CHANGED", -- bank bag slots
    }
    for _, evt in ipairs(events) do
        if ns.RegisterEvent then
            ns:RegisterEvent(evt, function() Capture.RequestCapture() end)
        end
    end
    -- Bank window gating: open enables bank scanning, close disables it after a
    -- final capture so the just-seen bank state is stored.
    if ns.RegisterEvent then
        ns:RegisterEvent("BANKFRAME_OPENED", function()
            Capture._bankOpen = true
            Capture.RequestCapture()
        end)
        ns:RegisterEvent("BANKFRAME_CLOSED", function()
            Capture.RequestCapture()      -- capture the final state while still readable
            Capture._bankOpen = false
        end)
    end
    -- First snapshot once the world is up.
    Capture.RequestCapture()
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "capture") — driven by a fake container API
----------------------------------------------------------------------

-- Build a fake api from a plain fixture:
--   fixture[cid] = { size = N, link = <str>, family = <n>, items = { [slot] = {itemID, stackCount, quality, hyperlink} } }
-- A cid absent from the fixture reports numSlots 0 (unowned bag slot / empty).
local function fakeAPI(fixture)
    return {
        numSlots = function(cid)
            local c = fixture[cid]
            return c and c.size or 0
        end,
        itemInfo = function(cid, slot)
            local c = fixture[cid]
            return c and c.items and c.items[slot] or nil
        end,
        bagLink   = function(cid) local c = fixture[cid]; return c and c.link end,
        bagFamily = function(cid) local c = fixture[cid]; return c and c.family end,
    }
end

local function testBuildSlot(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Capture.BuildSlot(nil) == nil, "nil info -> nil slot")
    ck(Capture.BuildSlot({}) == nil, "empty struct (no itemID) -> nil")
    local s = Capture.BuildSlot({ itemID = 22157, stackCount = 5, quality = 3, hyperlink = "item:22157" })
    ck(s and s.id == 22157 and s.count == 5 and s.quality == 3 and s.link == "item:22157",
        "full struct -> populated slot")
    local s2 = Capture.BuildSlot({ itemID = 6948 })   -- stackCount absent
    ck(s2.count == 1, "missing stackCount defaults to 1")
end

local function testScanContainer(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local fix = {
        [0]  = { size = 16, items = { [1] = { itemID = 6948, stackCount = 1, quality = 1 },
                                      [5] = { itemID = 22157, stackCount = 20, quality = 3 } } },
        [1]  = { size = 14, link = "item:14046", family = 0 },  -- an empty carried bag
    }
    local api = fakeAPI(fix)
    local c0 = Capture.ScanContainer(0, api)
    ck(c0.size == 16, "backpack size 16")
    ck(c0.slots[1].id == 6948 and c0.slots[5].count == 20, "sparse slots captured")
    ck(c0.slots[2] == nil, "empty slots stay nil")
    local c1 = Capture.ScanContainer(1, api)
    ck(c1.link == "item:14046" and c1.size == 14, "bag link + size captured")
    ck(next(c1.slots) == nil, "empty bag has no slots")
    -- Unowned bag slot (not in fixture) -> nil for a bag id.
    ck(Capture.ScanContainer(4, api) == nil, "unowned bag slot -> nil container")
    -- Backpack always returns a container even when empty.
    local empty = Capture.ScanContainer(0, fakeAPI({}))
    ck(empty ~= nil and next(empty.slots) == nil, "empty backpack still stored")
end

local function testSnapshotBankGating(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    _G.DaseekiBags2Data = nil; Store.Init()
    local fix = {
        [0]  = { size = 16, items = { [1] = { itemID = 6948, stackCount = 1 } } },
        [1]  = { size = 14, link = "item:14046",
                 items = { [1] = { itemID = 22157, stackCount = 20 } } },
        [-2] = { size = 12, items = { [1] = { itemID = 5175, stackCount = 1 } } }, -- keyring
        [-1] = { size = 24, items = { [1] = { itemID = 4306, stackCount = 20 } } }, -- bank main
        [5]  = { size = 16, link = "item:14156",
                 items = { [1] = { itemID = 4338, stackCount = 8 } } },             -- bank bag
    }
    local api = fakeAPI(fix)
    local o = Store.EnsureOwner("Tester-TestRealm")

    -- Carried-only scope: bank containers must NOT be written.
    Capture.BuildSnapshot(o, api, { bank = false }, 100)
    ck(Store.GetContainer(o, 0) ~= nil, "backpack captured")
    ck(Store.GetContainer(o, -2) ~= nil, "keyring captured (carried scope)")
    ck(Store.GetContainer(o, -1) == nil, "bank NOT captured without bank scope")
    ck(Store.GetContainer(o, 5) == nil, "bank bag NOT captured without bank scope")
    local revAfterFirst = o.rev
    ck(revAfterFirst == 1, "revision bumped once")

    -- Bank scope: now bank containers appear, carried stay.
    Capture.BuildSnapshot(o, api, { bank = true }, 200)
    ck(Store.GetContainer(o, -1) ~= nil, "bank captured with bank scope")
    ck(Store.GetContainer(o, 5) ~= nil, "bank bag captured with bank scope")
    ck(Store.ContainerAge(o, -1, 260) == 60, "bank container ts stamped at scan time")
    ck(o.rev == 2, "revision bumped to 2")

    -- itemCounts aggregate across everything scanned.
    ck(o.itemCounts[22157] == 20 and o.itemCounts[4306] == 20 and o.itemCounts[4338] == 8,
        "itemCounts aggregate carried + bank")
end

function Capture.RunSelfTests(verbose)
    local suites = {
        { name = "build slot",     fn = testBuildSlot },
        { name = "scan container", fn = testScanContainer },
        { name = "snapshot + bank gating", fn = testSnapshotBankGating },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS capture/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL capture/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("capture", Capture.RunSelfTests)
end

return Capture
