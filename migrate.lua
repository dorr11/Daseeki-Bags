-- Daseeki Bags 2.0 — migrate.lua
-- One-time, READ-ONLY, marker-guarded, idempotent conversion of the 1.x
-- SavedVariables into the 2.0 store. The 1.x globals are NEVER written.
--
-- 1.x source globals (verified from the shipping .toc and real WTF copies):
--   DaseekiBagsAccount[realm][char] = FULL per-slot data for THIS account's
--       characters. Container ids are the char table's NUMERIC keys:
--         [0]=backpack, [1..N]=carried bags, [-1]=bank, [-2]=keyring,
--         [N+1..]=bank bags. Each container = { items={[slot]="id" | "id;count"},
--         size=<n>, link="<bagItemId>" }. Non-container fields are string-keyed:
--         money, class, race, sex, faction, level, equip={[invSlot]="id[;count]"},
--         mesh={itemCounts={[id]=n}, rev=n}, guild, mail, currency.
--   DaseekiBagsMesh[realm][char] = SUMMARY for characters known through the
--       cross-account mesh: { money, level, class, race, sex, faction,
--       itemCounts={[id]=n}, rev, ts } — NO bag slots. This is what powered
--       1.x cross-account gold totals, so it MUST be converted (D1: gold sacred).
--   DaseekiBagsSets = 1.x settings/colors (not migrated here; W4 owns options).
--
-- Because SavedVariables are per-account, one account's file already contains
-- its own FULL characters plus SUMMARY entries for every other account's
-- characters. Converting both preserves the exact cross-account view 1.x had.
--
-- Idempotency: a marker (data.migratedFrom1x) guards the whole pass so a later
-- user edit in 2.0 (e.g. deleting an owner) is never re-clobbered by a re-run.
--
-- MARKER DISCIPLINE (ROLLOUT_CONTINUITY_AUDIT AT-RISK-1c; house pattern taken from
-- Daseeki-Conduit's migrate.lua, where an absent source returns BEFORE the marker is
-- written). The marker is set ONLY when the pass actually converted at least one
-- owner. A run against an absent or empty 1.x source leaves it UNSET, so the import
-- still happens when the source turns up later — the addon installed before the WTF
-- file was copied over, a second machine, 1.x re-enabled after being disabled for a
-- session. A marker written on an empty run is a permanently sticky "already done"
-- that can never be cleared from the UI, which is exactly the defect the audit found
-- in the Nexus Bags-import and Inventory-module one-shots.
--
-- SELF-HEAL: a DB that already carries a sticky marker from the pre-fix build (or any
-- other route to marker-set-but-nothing-imported) is repaired at startup — see
-- Migrate.SelfHeal, which re-runs the import forcibly and says so loudly.
--
-- MESH-IMPORT DEFERRAL (Nexus Inventory module, W2). When the Daseeki-Nexus Inventory
-- store is ACTIVE (see nexus.lua), it — not Bags — is the system of record for REMOTE
-- owners, so step 2 below (DaseekiBagsMesh -> summary owners) is skipped and Bags
-- reads those characters through the bridge instead of holding its own copies. Step 1
-- is untouched: THIS account's characters keep their full per-slot detail from
-- DaseekiBagsAccount, converted and owned by Bags exactly as before.
--
-- The deferral is threaded through as `opts.deferMesh` rather than probed inside these
-- functions, so every one of them stays pure and the harness can drive both directions
-- deterministically. It also flows into CountSourceChars, and therefore into SelfHeal:
-- a source census that counted deferred mesh records would make the self-heal fire on
-- a run that is CORRECTLY importing nothing, burning its bounded attempts and printing
-- a repair notice for a store that is not broken.

local ADDON, ns = ...

local Migrate = {}
ns.Migrate = Migrate

local Store = ns.Store

----------------------------------------------------------------------
-- Parsing: "id" or "id;count" -> id (number), count (number, default 1)
----------------------------------------------------------------------

function Migrate.ParseItemRef(str)
    if type(str) == "number" then return str, 1 end
    if type(str) ~= "string" then return nil, nil end
    local id, count = string.match(str, "^(%d+);(%d+)$")
    if id then return tonumber(id), tonumber(count) end
    id = string.match(str, "^(%d+)$")
    if id then return tonumber(id), 1 end
    -- Some 1.x links stored a full "id;count;..." with trailing fields; take the
    -- leading id;count pair defensively.
    id, count = string.match(str, "^(%d+);(%d+)")
    if id then return tonumber(id), tonumber(count) end
    id = string.match(str, "^(%d+)")
    if id then return tonumber(id), 1 end
    return nil, nil
end

----------------------------------------------------------------------
-- Convert one 1.x container -> a 2.0 store container (or nil to skip).
-- Truly-empty {} entries (unowned bag slots) are skipped; real storage
-- (backpack/bank with a size, or any container with items/link) is kept.
----------------------------------------------------------------------

function Migrate.ConvertContainer(oldC)
    if type(oldC) ~= "table" then return nil, 0 end
    local hasItems = type(oldC.items) == "table" and next(oldC.items) ~= nil
    local hasSize  = type(oldC.size) == "number" and oldC.size > 0
    if not hasItems and not hasSize and oldC.link == nil then
        return nil, 0   -- empty/unowned bag slot
    end
    local link = oldC.link
    if type(link) == "string" then link = tonumber(link) or link end
    local c = Store.NewContainer(oldC.size or 0, link)
    local nSlots = 0
    if type(oldC.items) == "table" then
        for slot, ref in pairs(oldC.items) do
            local id, count = Migrate.ParseItemRef(ref)
            if id then
                c.slots[slot] = Store.NewSlot(id, count)   -- quality unknown from 1.x
                nSlots = nSlots + 1
            end
        end
    end
    return c, nSlots
end

----------------------------------------------------------------------
-- Convert a FULL 1.x character into an owner record.
-- Returns owner, { containers, slots }.
----------------------------------------------------------------------

function Migrate.ConvertFullChar(realm, name, oldChar, account)
    local nameRealm = Store.MakeNameRealm(name, realm)
    local o = Store.NewOwner(nameRealm, name, realm)
    o.source  = "full"
    o.account = account or ""

    o.class   = oldChar.class
    o.race    = oldChar.race
    o.sex     = oldChar.sex
    o.faction = oldChar.faction
    o.level   = oldChar.level or 0
    o.money   = oldChar.money or 0

    local nContainers, nSlots = 0, 0
    for k, v in pairs(oldChar) do
        if type(k) == "number" and type(v) == "table" then   -- a container id
            local c, sc = Migrate.ConvertContainer(v)
            if c then
                o.containers[k] = c
                nContainers = nContainers + 1
                nSlots = nSlots + sc
            end
        end
    end

    -- Equipped items (appearance-relevant): string key "equip" = { [invSlot]=ref }
    if type(oldChar.equip) == "table" then
        for invSlot, ref in pairs(oldChar.equip) do
            local id, count = Migrate.ParseItemRef(ref)
            if id then o.equip[invSlot] = { id = id, count = count } end
        end
    end

    -- 1.x pre-aggregated item counts live under mesh.itemCounts; carry them so
    -- tooltip counts survive before the first live recapture. Recompute from
    -- our own converted containers where possible (more authoritative), falling
    -- back to the stored aggregate.
    Store.RecomputeItemCounts(o, true)
    if next(o.itemCounts) == nil and type(oldChar.mesh) == "table"
       and type(oldChar.mesh.itemCounts) == "table" then
        for id, n in pairs(oldChar.mesh.itemCounts) do o.itemCounts[id] = n end
    end
    if type(oldChar.mesh) == "table" and oldChar.mesh.rev then
        o.rev = oldChar.mesh.rev
    end
    o.ts = Store.Now()

    return o, { containers = nContainers, slots = nSlots }
end

----------------------------------------------------------------------
-- Convert a SUMMARY (mesh) 1.x character into an owner record (no containers).
----------------------------------------------------------------------

function Migrate.ConvertSummaryChar(realm, name, oldMesh)
    local nameRealm = Store.MakeNameRealm(name, realm)
    local o = Store.NewOwner(nameRealm, name, realm)
    o.source  = "summary"
    o.account = ""          -- remote/unknown account (flat, as 1.x mesh was)

    o.class   = oldMesh.class
    o.race    = oldMesh.race
    o.sex     = oldMesh.sex
    o.faction = oldMesh.faction
    o.level   = oldMesh.level or 0
    o.money   = oldMesh.money or 0
    o.rev     = oldMesh.rev or 0
    o.ts      = oldMesh.ts or 0

    if type(oldMesh.itemCounts) == "table" then
        for id, n in pairs(oldMesh.itemCounts) do o.itemCounts[id] = n end
    end
    return o
end

----------------------------------------------------------------------
-- How many 1.x character records a source global actually holds. READ-ONLY.
-- Declared here (rather than beside Migrate.CountSourceChars, which closes over
-- it) because Migrate.Run needs it to answer "is there a mesh half to owe?".
----------------------------------------------------------------------

local function countChars(src)
    local n = 0
    if type(src) ~= "table" then return n end
    for _, chars in pairs(src) do
        if type(chars) == "table" then
            for _, rec in pairs(chars) do
                if type(rec) == "table" then n = n + 1 end
            end
        end
    end
    return n
end

----------------------------------------------------------------------
-- The SUMMARY (mesh) half of the import, factored out because it now has TWO
-- callers: the migration pass itself, and the deferred-completion pass below.
-- One implementation, so the two can never drift apart — the audit's dominant
-- shape suite-wide is "the sibling got the guard and I didn't".
--
-- STRICTLY ADDITIVE. A nameRealm already in the store is never replaced: our own
-- converted characters keep their per-slot data rather than being downgraded to a
-- summary, and — the part that matters for the completion pass — six months of
-- live 2.0 captures can never be overwritten by a 1.x snapshot. The only write
-- to an existing record is the money backfill, and only into a zero.
----------------------------------------------------------------------

local function importMeshSummaries(data, oldMesh, counts)
    if type(oldMesh) ~= "table" then return counts end
    counts.backfilled = counts.backfilled or 0
    for realm, chars in pairs(oldMesh) do
        if type(chars) == "table" then
            for name, oldMeshChar in pairs(chars) do
                if type(oldMeshChar) == "table" then
                    local nameRealm = Store.MakeNameRealm(name, realm)
                    local existing = data.owners[nameRealm]
                    if not existing then
                        data.owners[nameRealm] = Migrate.ConvertSummaryChar(realm, name, oldMeshChar)
                        counts.owners  = counts.owners + 1
                        counts.summary = counts.summary + 1
                    elseif existing.source == "full" then
                        -- Backfill only genuinely-missing fields; never
                        -- overwrite the fuller record.
                        if (existing.money or 0) == 0 and oldMeshChar.money then
                            existing.money = oldMeshChar.money
                            counts.backfilled = counts.backfilled + 1
                        end
                    end
                end
            end
        end
    end
    return counts
end

----------------------------------------------------------------------
-- The migration pass. Operates directly on `data` (the store cache DB), so
-- tests can pass a standalone table. READ-ONLY on oldAccount / oldMesh.
--
--   data       : the 2.0 cache DB (data.owners, data.migratedFrom1x)
--   oldAccount : DaseekiBagsAccount (may be nil)
--   oldMesh    : DaseekiBagsMesh (may be nil)
--   opts       : { selfAccount=<id>, force=<bool>, deferMesh=<bool> }
-- Returns counts { skipped, owners, full, summary, containers, slots, meshDeferred }.
----------------------------------------------------------------------

function Migrate.Run(data, oldAccount, oldMesh, opts)
    opts = opts or {}
    if type(data) ~= "table" then return { skipped = true } end
    if type(data.owners) ~= "table" then data.owners = {} end
    if data.migratedFrom1x and not opts.force then
        return { skipped = true }
    end

    local selfAccount = opts.selfAccount or data.selfAccount or ""
    local deferMesh   = opts.deferMesh and true or false
    local counts = { skipped = false, owners = 0, full = 0, summary = 0,
                     containers = 0, slots = 0, meshDeferred = deferMesh }

    -- 1) FULL characters (this account) — authoritative, keyed with selfAccount.
    if type(oldAccount) == "table" then
        for realm, chars in pairs(oldAccount) do
            if type(chars) == "table" then
                for name, oldChar in pairs(chars) do
                    if type(oldChar) == "table" then
                        local o, c = Migrate.ConvertFullChar(realm, name, oldChar, selfAccount)
                        data.owners[o.nameRealm] = o
                        counts.owners = counts.owners + 1
                        counts.full = counts.full + 1
                        counts.containers = counts.containers + c.containers
                        counts.slots = counts.slots + c.slots
                    end
                end
            end
        end
    end

    -- 2) SUMMARY characters (mesh) — only for owners not already FULL, so our
    --    own converted characters keep their per-slot data and are not
    --    downgraded to a summary.
    --
    --    DEFERRED when the Nexus Inventory store is active: those same remote
    --    characters live in the Nexus owners graph, which is then the system of
    --    record for them, and nexus.lua serves them to the summary consumers with
    --    a newest-wins merge. Importing our own second copy here would give the
    --    money tooltip two sources for one character and put Bags in the business
    --    of ageing remote data it no longer receives.
    if not deferMesh then
        importMeshSummaries(data, oldMesh, counts)
    end

    -- Marker discipline (AT-RISK-1c): set ONLY on a non-empty result. Zero owners
    -- means there was nothing to read (no source, empty source, or a source shaped
    -- so unexpectedly that nothing converted) — leaving the marker unset keeps the
    -- door open for the real source to arrive on a later login.
    if counts.owners == 0 then
        counts.markerSet = false
        return counts
    end

    -- BAG-5. The marker above spans BOTH passes, but `deferMesh` can suppress the
    -- second one entirely — so a run that converted local characters and skipped
    -- every mesh summary latched exactly as if it had imported both. The debt was
    -- invisible: six months later the user disables Nexus (or its inventory
    -- module), Nexus.Owners() falls back to Store.data.owners, and every
    -- cross-account character and their gold is simply gone, with no code path
    -- able to re-import them — Migrate.SelfHeal bails on a non-empty owners table.
    --
    -- So the deferral is RECORDED, on the same proven-before-written rule as the
    -- marker itself: a debt is only written down when there really is one. A
    -- deferMesh run with no mesh source owes nothing, and says so by clearing.
    if deferMesh and countChars(oldMesh) > 0 then
        data.meshImportDeferred = true
        counts.meshDeferredRecorded = true
    elseif not deferMesh then
        -- The mesh half just ran (or there was nothing to run): no debt stands.
        data.meshImportDeferred = nil
    end

    data.migratedFrom1x = true
    counts.markerSet = true
    return counts
end

----------------------------------------------------------------------
-- BAG-5: pay the recorded mesh debt.
--
-- Triggered on any later login where the deferral was recorded and Nexus is no
-- longer taking the remote owners. Runs ONLY the summary half — never the
-- account pass, which is emphatically NOT idempotent against a live 2.0 store:
-- ConvertFullChar rebuilds an owner from the 1.x snapshot and replaces it
-- wholesale, so forcing it months later would overwrite current bag contents with
-- a year-old copy. That is why this is its own pass and not a `force = true`
-- re-run of Migrate.Run.
--
-- One-shot, stamped, additive-only:
--   * one-shot   — the flag is cleared on completion and never re-armed except by
--                  another genuinely deferred migration run;
--   * stamped    — meshImportCompletedAt records when the debt was settled;
--   * additive   — importMeshSummaries never replaces an existing owner, so a
--                  character the user deliberately removed stays removed if it is
--                  still in the store's shape, and live records are untouchable.
--
--   opts : { deferMesh=<bool>, force=<bool>, quiet=<bool> }
--          `force` is the explicit user gesture (/bags mesh import) for installs
--          that latched before this build and so carry no recorded flag.
-- Returns counts, or nil when there was nothing to do.
----------------------------------------------------------------------

function Migrate.CompleteDeferredMesh(data, oldMesh, opts)
    opts = opts or {}
    if type(data) ~= "table" then return nil end
    if type(data.owners) ~= "table" then data.owners = {} end
    if not (data.meshImportDeferred or opts.force) then return nil end

    -- Still deferring: Nexus owns those owners right now, and importing our own
    -- second copy is the exact double-source the deferral exists to prevent.
    -- The debt stands; do not clear it.
    if opts.deferMesh then
        return { skipped = true, reason = "nexus-active" }
    end

    -- A debt is only payable against a source that is actually there. An absent
    -- DaseekiBagsMesh may simply not be attached on this client, so REFUSE rather
    -- than clear the flag — absence of the source is not proof there is no debt.
    if countChars(oldMesh) == 0 then
        return { skipped = true, reason = "no-source" }
    end

    local counts = { skipped = false, owners = 0, full = 0, summary = 0,
                     containers = 0, slots = 0, backfilled = 0, meshCompleted = true }
    importMeshSummaries(data, oldMesh, counts)

    data.meshImportDeferred   = nil
    data.meshImportCompletedAt = Store.Now and Store.Now() or nil

    if not opts.quiet and counts.owners > 0 and ns and ns.Print then
        ns:Print(("1.x cross-account import completed: %d character(s) restored from your " ..
                  "saved 1.x data. They were held back while Daseeki Nexus was providing " ..
                  "them."):format(counts.owners))
    end
    return counts
end

----------------------------------------------------------------------
-- Source census: how many 1.x character records the source globals actually hold.
-- READ-ONLY. Used by the self-heal to tell "nothing to import" (a legitimately
-- empty source; leave everything alone) apart from "something to import but the
-- marker says we already did" (the sticky-marker anomaly).
--
-- `deferMesh` must match the flag Migrate.Run is being given, because the census
-- answers "is there anything this pass WOULD import?". With the mesh deferred to the
-- Nexus store, mesh records are not importable, and counting them would make the
-- self-heal diagnose an anomaly in a store that is behaving exactly as designed.
--
-- The two sources are counted by explicit calls rather than by iterating a
-- {oldAccount, oldMesh} literal: with oldAccount nil that literal is {[2]=oldMesh},
-- whose ipairs stops at the hole and visits NOTHING — so a store whose only 1.x
-- source is DaseekiBagsMesh censused as 0 and could never be self-healed.
----------------------------------------------------------------------

-- countChars is declared above Migrate.Run (it needs it too); this closes over it.
function Migrate.CountSourceChars(oldAccount, oldMesh, deferMesh)
    local n = countChars(oldAccount)
    if not deferMesh then n = n + countChars(oldMesh) end
    return n
end

----------------------------------------------------------------------
-- Startup self-heal (ROLLOUT_CONTINUITY_AUDIT AT-RISK-1c).
--
-- The anomaly: the marker says the 1.x import is done, the store holds ZERO owners,
-- and the 1.x source is sitting right there with real characters in it. That is a
-- migration that never happened but can never retry — the user's alts, banks and
-- cross-account gold are simply missing, with nothing on screen to explain it.
--
-- Detect it and force the import through, loudly (a silent repair of missing data is
-- indistinguishable from the bug for anyone comparing the window against 1.x).
--
-- Bounded: each attempt is counted, and after MAX_SELFHEAL_ATTEMPTS the pass stops
-- trying, so a pathological source can never turn into a chat-spam loop on every
-- login. A successful heal converts owners, which makes the trigger condition false
-- forever after anyway.
--
--   data       : the 2.0 cache DB
--   oldAccount / oldMesh : the 1.x globals (never written)
--   opts       : { selfAccount=<id>, quiet=<bool>, deferMesh=<bool> }
-- Returns the forced-run counts, or nil when nothing needed healing.
--
-- deferMesh flows through UNCHANGED into both the census and the forced run, so a
-- repair never re-imports what the Nexus store now owns — and, just as important,
-- never diagnoses an anomaly that is only the deferral doing its job.
----------------------------------------------------------------------

Migrate.MAX_SELFHEAL_ATTEMPTS = 3

function Migrate.SelfHeal(data, oldAccount, oldMesh, opts)
    opts = opts or {}
    if type(data) ~= "table" then return nil end
    if not data.migratedFrom1x then return nil end          -- normal path owns this
    if type(data.owners) == "table" and next(data.owners) ~= nil then return nil end

    local available = Migrate.CountSourceChars(oldAccount, oldMesh, opts.deferMesh)
    if available == 0 then return nil end   -- nothing importable; marker is honest

    local attempts = tonumber(data.selfHealAttempts) or 0
    if attempts >= Migrate.MAX_SELFHEAL_ATTEMPTS then return nil end
    data.selfHealAttempts = attempts + 1

    if not opts.quiet and ns and ns.Print then
        ns:Print(("1.x import repair: the saved data holds %d character record(s) but " ..
                  "none were imported, while the one-time import was already marked done. " ..
                  "Re-importing now."):format(available))
    end

    local counts = Migrate.Run(data, oldAccount, oldMesh,
                               { selfAccount = opts.selfAccount or data.selfAccount or "",
                                 force = true, deferMesh = opts.deferMesh })
    counts.selfHealed = true
    counts.sourceChars = available

    if not opts.quiet and ns and ns.Print then
        if counts.owners > 0 then
            ns:Print(("1.x import repair complete: %d character(s) restored (%d with full bag " ..
                      "contents, %d cross-account summaries)."):format(counts.owners, counts.full, counts.summary))
        else
            ns:Print("1.x import repair found no convertible characters; the saved 1.x data " ..
                     "is present but not in a shape this version can read. Nothing was changed.")
        end
    end
    return counts
end

----------------------------------------------------------------------
-- Live wrapper: read the 1.x globals and migrate into the attached store.
-- Runs once at login (after Store.Init); a no-op if already migrated.
--
-- The Nexus bridge is probed HERE, once, at the migration moment — not cached at
-- load and not consulted inside the pure passes. ns.Nexus ships with this addon, but
-- the call is still guarded the house way: an absent or half-loaded bridge simply
-- reads as "not deferring", which is the pre-bridge behaviour.
----------------------------------------------------------------------

function Migrate.Migrate()
    if not Store.data then return { skipped = true } end
    local deferMesh = (ns.Nexus and ns.Nexus.DeferMeshImport and ns.Nexus.DeferMeshImport()) and true or false
    local opts = { selfAccount = Store.data.selfAccount or "", deferMesh = deferMesh }
    local counts = Migrate.Run(Store.data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, opts)

    -- A skipped run means the marker was already set. That is normal on every login
    -- after the first — but it is also the sticky-marker anomaly's signature, so check.
    if counts.skipped then
        local healed = Migrate.SelfHeal(Store.data, _G.DaseekiBagsAccount, _G.DaseekiBagsMesh, opts)
        if healed then counts = healed end
    end

    -- BAG-5: settle a mesh half a previous run deferred. Checked on EVERY login,
    -- not only the migrating one, because the trigger is Nexus going away — which
    -- happens long after the marker latched. A no-op unless a debt was recorded.
    local completed = Migrate.CompleteDeferredMesh(Store.data, _G.DaseekiBagsMesh, opts)
    if completed and not completed.skipped then counts.meshCompletion = completed end
    -- (No Nexus.Invalidate here: core.lua fires STORE_READY immediately after this
    -- returns, and nexus.lua invalidates on it.)

    -- The SETTINGS + custom-rules pass (audit NW-1) runs at this same migration
    -- moment, against a different source global with its own marker. Optional by
    -- design: if migrate_settings.lua is absent the owner data still converts.
    if ns.MigrateSettings and ns.MigrateSettings.Migrate then
        counts.settings = ns.MigrateSettings.Migrate()
    end
    return counts
end

----------------------------------------------------------------------
-- `/bags mesh import` — the EXPLICIT release path for BAG-5.
--
-- The automatic settlement above needs a recorded deferral, and a store that
-- latched before this build carries none: nothing was written down at the time.
-- That gap is not decidable from the data (a mesh character missing from the
-- store is indistinguishable from one the owner deliberately removed through the
-- character list), so it is answered the same way Conduit's staging latch is —
-- with a live release path the OWNER drives. The user's gesture is the proof.
--
-- Still additive-only and still refuses while Nexus is providing those owners,
-- so the worst case of running it is that it reports adding nothing.
----------------------------------------------------------------------

function Migrate.MeshImportCommand()
    if not (ns and ns.Print) then return end
    if not Store.data then
        ns:Print("the bag store is not ready yet — try again in a moment.")
        return
    end
    local deferMesh = (ns.Nexus and ns.Nexus.DeferMeshImport and ns.Nexus.DeferMeshImport()) and true or false
    local res = Migrate.CompleteDeferredMesh(Store.data, _G.DaseekiBagsMesh,
                                             { deferMesh = deferMesh, force = true })
    if not res then return end

    if res.skipped then
        if res.reason == "nexus-active" then
            ns:Print("Daseeki Nexus is providing your cross-account characters right now, so " ..
                     "Bags deliberately holds its 1.x copies back — importing them would give " ..
                     "the money tooltip two sources for one character. Turn the Nexus " ..
                     "inventory module off first if you want Bags to keep its own copy.")
        else
            ns:Print("no 1.x cross-account data is attached on this client, so there is " ..
                     "nothing to import.")
        end
        return
    end

    if res.owners == 0 then
        ns:Print("every character in your 1.x cross-account data is already in the list; " ..
                 "nothing was added.")
    end
    if ns.Nexus and ns.Nexus.Invalidate then ns.Nexus.Invalidate() end
    if ns.Frame and ns.Frame.RequestRefresh then ns.Frame.RequestRefresh() end
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "migrate")
----------------------------------------------------------------------

-- A tiny inline 1.x-shaped fixture (structure-faithful, values trimmed).
local function sampleAccount()
    return {
        ["Whitemane"] = {
            ["Puuchoco"] = {
                [0]  = { items = { [1] = "6948", [12] = "22261;10" }, size = 20 },
                [1]  = { items = { "22157", "22157" }, size = 14, link = "14046" },
                [4]  = { },                       -- unowned bag slot (skip)
                [-1] = { items = { [3] = "4306;20" }, size = 24 },   -- bank main
                [-2] = { items = { [1] = "5175" }, size = 32 },      -- keyring
                ["equip"] = { [7] = "139", [18] = "3111;100" },
                ["money"] = 39000,
                ["class"] = "WARRIOR", ["race"] = "Troll", ["sex"] = 2,
                ["faction"] = "Horde", ["level"] = 60,
                ["mesh"] = { itemCounts = { [22157] = 2, [22261] = 10 }, rev = 32 },
            },
        },
    }
end

local function sampleMesh()
    return {
        ["Whitemane"] = {
            ["Puuchoco"] = {   -- same char as FULL -> must NOT downgrade
                money = 39000, level = 60, class = "WARRIOR", faction = "Horde",
                itemCounts = { [22157] = 2 }, rev = 32, ts = 111,
            },
            ["Shalk"] = {      -- remote char, summary only
                money = 1022693, level = 60, class = "SHAMAN", race = "Orc",
                faction = "Horde", itemCounts = { [6948] = 1, [13724] = 52 },
                rev = 179, ts = 222,
            },
        },
    }
end

local function testParse(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local id, n = Migrate.ParseItemRef("22261;10"); ck(id == 22261 and n == 10, "id;count parse")
    id, n = Migrate.ParseItemRef("22157");          ck(id == 22157 and n == 1, "bare id -> count 1")
    id, n = Migrate.ParseItemRef("3111;100");        ck(id == 3111 and n == 100, "large count parse")
    ck(Migrate.ParseItemRef("") == nil, "empty string -> nil")
    ck(Migrate.ParseItemRef(nil) == nil, "nil -> nil")
end

local function testConvertContainer(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local c, sc = Migrate.ConvertContainer({ items = { [1] = "22157", [13] = "22261;2" },
                                             size = 14, link = "14046" })
    ck(c.size == 14 and c.link == 14046, "size + numeric link")
    ck(c.slots[1].id == 22157 and c.slots[1].count == 1, "slot 1")
    ck(c.slots[13].id == 22261 and c.slots[13].count == 2, "slot 13 with count")
    ck(c.slots[1].quality == nil, "quality left nil (derived at render)")
    ck(sc == 2, "slot count = 2")
    ck(Migrate.ConvertContainer({}) == nil, "empty {} -> nil (unowned bag)")
end

local function testEndToEndAndIdempotency(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local data = Store._defaultData()
    data.selfAccount = "acctSELF"
    local r = Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF" })
    ck(r.skipped == false, "first run not skipped")
    ck(r.full == 1, "one full char (Puuchoco)")
    ck(r.summary == 1, "one summary char (Shalk); Puuchoco mesh not double-counted")
    ck(r.owners == 2, "two owners total")

    local pu = data.owners["Puuchoco-Whitemane"]
    ck(pu.source == "full" and pu.account == "acctSELF", "Puuchoco full + self account")
    ck(pu.money == 39000 and pu.class == "WARRIOR", "Puuchoco money/class")
    ck(pu.containers[0] and pu.containers[-1] and pu.containers[-2], "backpack/bank/keyring kept")
    ck(pu.containers[4] == nil, "empty bag slot 4 skipped")
    ck(pu.containers[0].slots[12].id == 22261 and pu.containers[0].slots[12].count == 10,
        "backpack slot 12 = 22261 x10")
    ck(pu.equip[18].id == 3111 and pu.equip[18].count == 100, "equipped ammo id;count")
    -- itemCounts recomputed from converted containers + equip (authoritative).
    ck(pu.itemCounts[22157] == 2, "Puuchoco 22157 count from slots")

    local sh = data.owners["Shalk-Whitemane"]
    ck(sh.source == "summary" and sh.account == "", "Shalk summary + unknown account")
    ck(sh.money == 1022693 and next(sh.containers) == nil, "Shalk money, no containers")
    ck(sh.itemCounts[13724] == 52, "Shalk itemCounts carried")

    -- Cross-account gold total (D1): full + summary both participate.
    -- Recreate the store-total math directly on the data.
    local total = 0
    for _, o in pairs(data.owners) do total = total + (o.money or 0) end
    ck(total == 39000 + 1022693, "cross-account gold total = full + summary money")

    -- Idempotency: a second run is skipped and mutates nothing.
    local before = pu.money
    local r2 = Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF" })
    ck(r2.skipped == true, "second run skipped via marker")
    ck(data.owners["Puuchoco-Whitemane"].money == before, "owners unchanged on skip")
    ck(Store.OwnerCount ~= nil, "store still intact")

    -- Read-only guarantee: converting must not have mutated the source tables.
    local acc = sampleAccount()
    Migrate.Run(Store._defaultData(), acc, nil, { selfAccount = "x" })
    ck(acc["Whitemane"]["Puuchoco"]["money"] == 39000, "source account not mutated")
    ck(acc["Whitemane"]["Puuchoco"][0].items[1] == "6948", "source item strings not mutated")
end

-- AT-RISK-1c: the marker must never be written by a run that imported nothing, and a
-- source that only shows up later must still import.
local function testEmptySourceLeavesMarkerUnset(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- 1) No source at all (the 1.x addon was never installed / SV never written).
    local data = Store._defaultData()
    local r = Migrate.Run(data, nil, nil, { selfAccount = "acctSELF" })
    ck(r.skipped == false, "a run with no source still executes (it is not 'already done')")
    ck(r.owners == 0, "no source converts no owners")
    ck(r.markerSet == false, "marker reported as NOT set")
    ck(data.migratedFrom1x == false, "marker left unset after an empty run")

    -- 2) Present but empty tables (1.x installed, never logged a character).
    local data2 = Store._defaultData()
    Migrate.Run(data2, {}, {}, { selfAccount = "acctSELF" })
    ck(data2.migratedFrom1x == false, "empty source tables leave the marker unset")

    -- 3) Realms present but holding no character records.
    local data3 = Store._defaultData()
    Migrate.Run(data3, { ["Whitemane"] = {} }, nil, { selfAccount = "acctSELF" })
    ck(data3.migratedFrom1x == false, "empty realm table leaves the marker unset")

    -- 4) THE POINT OF THE RULE: the source appears on a later login and imports.
    local r4 = Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF" })
    ck(r4.skipped == false, "late-appearing source is not blocked by a marker")
    ck(r4.owners == 2, "late-appearing source imports both owners")
    ck(r4.markerSet == true and data.migratedFrom1x == true, "marker set once real data landed")

    -- ...and only then does the guard engage.
    ck(Migrate.Run(data, sampleAccount(), sampleMesh(), {}).skipped == true,
        "marker now guards re-runs")
end

-- AT-RISK-1c self-heal: marker true + zero owners + a real source = repair it.
local function testSelfHeal(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local quiet = { selfAccount = "acctSELF", quiet = true }

    -- The anomaly: a DB carrying a sticky marker from the pre-fix build.
    local data = Store._defaultData()
    data.migratedFrom1x = true              -- "already imported"
    ck(Migrate.Run(data, sampleAccount(), sampleMesh(), quiet).skipped == true,
        "the normal path is blocked by the sticky marker (this is the bug)")
    ck(next(data.owners) == nil, "and the store is still empty")

    local healed = Migrate.SelfHeal(data, sampleAccount(), sampleMesh(), quiet)
    ck(healed ~= nil, "self-heal fired")
    ck(healed.selfHealed == true and healed.sourceChars == 3, "reports the heal + source census")
    ck(healed.owners == 2, "self-heal imported both owners")
    ck(data.owners["Puuchoco-Whitemane"].money == 39000, "full char restored with its money")
    ck(data.owners["Shalk-Whitemane"].source == "summary", "summary char restored")
    ck(data.selfHealAttempts == 1, "attempt counted")

    -- Now healthy: the trigger condition is false, so it never fires again.
    ck(Migrate.SelfHeal(data, sampleAccount(), sampleMesh(), quiet) == nil,
        "no re-heal once owners exist")

    -- Not an anomaly: marker set and the source is genuinely empty (the ordinary
    -- state of a fresh 2.0 install that already ran once against nothing).
    local clean = Store._defaultData()
    clean.migratedFrom1x = true
    ck(Migrate.SelfHeal(clean, nil, nil, quiet) == nil, "empty source is not an anomaly")
    ck(clean.selfHealAttempts == nil, "and costs no attempt")

    -- Not an anomaly: marker unset (the normal path owns that case).
    local fresh = Store._defaultData()
    ck(Migrate.SelfHeal(fresh, sampleAccount(), nil, quiet) == nil, "unset marker is not an anomaly")

    -- Bounded: an unconvertible-but-present source cannot spam forever.
    local weird = Store._defaultData()
    weird.migratedFrom1x = true
    local junk = { ["Whitemane"] = { ["Ghost"] = "not-a-table" } }
    ck(Migrate.CountSourceChars(junk, nil) == 0, "non-table records are not counted as source")
    -- A source that counts but converts to nothing: records are tables, but the whole
    -- pass yields owners because ANY table converts -- so force the bound directly.
    weird.selfHealAttempts = Migrate.MAX_SELFHEAL_ATTEMPTS
    ck(Migrate.SelfHeal(weird, sampleAccount(), nil, quiet) == nil,
        "attempts are bounded (no login-loop chat spam)")

    -- The loud print path must not error (harness re-points ns.Print to its log).
    local noisy = Store._defaultData()
    noisy.migratedFrom1x = true
    local okPrint = pcall(Migrate.SelfHeal, noisy, sampleAccount(), nil, { selfAccount = "x" })
    ck(okPrint, "the loud repair notice prints without error")
end

-- W2 (Nexus bridge): the mesh-import deferral, and the proof that it does not
-- disturb the cutover-continuity contract it sits next to.
local function testMeshDeferral(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local defer = { selfAccount = "acctSELF", deferMesh = true }
    local normal = { selfAccount = "acctSELF" }

    -- 1) THE DEFERRAL. Local characters still convert in full; the mesh summaries
    --    are left to the Nexus store.
    local data = Store._defaultData()
    local r = Migrate.Run(data, sampleAccount(), sampleMesh(), defer)
    ck(r.skipped == false, "a deferred run still executes")
    ck(r.meshDeferred == true, "the run reports the deferral")
    ck(r.full == 1, "LOCAL characters still convert with full detail")
    ck(r.summary == 0, "no mesh summaries imported while Nexus owns them")
    ck(r.owners == 1, "one owner total")
    ck(data.owners["Shalk-Whitemane"] == nil, "the remote character is NOT in the Bags store")
    local pu = data.owners["Puuchoco-Whitemane"]
    ck(pu ~= nil and pu.source == "full", "the local character is present and full")
    ck(pu.containers[0] and pu.containers[-1], "...with its bags and bank intact")
    ck(pu.money == 39000, "...and its money")
    ck(data.migratedFrom1x == true, "a deferred run that converted an owner still latches the marker")
    ck(data.meshImportDeferred == true,
        "BAG-5: ...and RECORDS that the mesh half is still owed")
    ck(r.meshDeferredRecorded == true, "BAG-5: the run reports having recorded the debt")

    -- 2) The NON-deferred run is unchanged (regression guard on the default path).
    local data2 = Store._defaultData()
    local r2 = Migrate.Run(data2, sampleAccount(), sampleMesh(), normal)
    ck(r2.meshDeferred == false, "the default path reports no deferral")
    ck(r2.summary == 1 and data2.owners["Shalk-Whitemane"] ~= nil,
        "without Nexus the mesh summary is imported exactly as before")

    -- 3) MARKER DISCIPLINE survives the deferral: a mesh-ONLY source with the mesh
    --    deferred converts nothing, so the marker must stay clear and the import must
    --    still land if Nexus later goes away.
    local data3 = Store._defaultData()
    local r3 = Migrate.Run(data3, nil, sampleMesh(), defer)
    ck(r3.owners == 0, "mesh-only source + deferral converts nothing")
    ck(r3.markerSet == false and data3.migratedFrom1x == false,
        "...and therefore leaves the marker UNSET (AT-RISK-1c holds)")
    local r3b = Migrate.Run(data3, nil, sampleMesh(), normal)
    ck(r3b.summary == 2 and data3.migratedFrom1x == true,
        "...so removing Nexus later still imports the mesh and latches then")

    -- 4) SELF-HEAL still works with the deferral on, and is not misfired BY it.
    local quiet = { selfAccount = "acctSELF", quiet = true, deferMesh = true }

    --    (a) census: deferred mesh records are not "available to import".
    ck(Migrate.CountSourceChars(sampleAccount(), sampleMesh(), false) == 3,
        "census counts both sources when nothing is deferred")
    ck(Migrate.CountSourceChars(sampleAccount(), sampleMesh(), true) == 1,
        "census counts only the local source when the mesh is deferred")
    ck(Migrate.CountSourceChars(nil, sampleMesh(), false) == 2,
        "census sees a mesh-only source (no ipairs hole)")
    ck(Migrate.CountSourceChars(nil, sampleMesh(), true) == 0,
        "...and reports nothing importable when that mesh is deferred")

    --    (b) the real anomaly still heals, and heals WITHOUT re-importing the mesh.
    local sticky = Store._defaultData()
    sticky.migratedFrom1x = true
    local healed = Migrate.SelfHeal(sticky, sampleAccount(), sampleMesh(), quiet)
    ck(healed ~= nil, "self-heal still fires under the deferral")
    ck(healed.sourceChars == 1, "census reported only the importable (local) records")
    ck(healed.owners == 1 and healed.full == 1 and healed.summary == 0,
        "the repair restored the local character and left the mesh to Nexus")
    ck(sticky.owners["Puuchoco-Whitemane"].money == 39000, "the repaired character kept its money")
    ck(sticky.selfHealAttempts == 1, "attempt counted exactly once")

    --    (c) THE MISFIRE GUARD: marker set, store empty, and the ONLY 1.x source is a
    --        mesh the Nexus store now owns. Nothing is broken — the store is empty
    --        because Bags correctly imported nothing — so the repair must NOT fire,
    --        must not print, and must not spend an attempt.
    local honest = Store._defaultData()
    honest.migratedFrom1x = true
    ck(Migrate.SelfHeal(honest, nil, sampleMesh(), quiet) == nil,
        "a deferred mesh-only source is not an anomaly")
    ck(honest.selfHealAttempts == nil, "...and costs no self-heal attempt")
    --        ...while the same state WITHOUT the deferral is still the real anomaly.
    ck(Migrate.SelfHeal(honest, nil, sampleMesh(), { selfAccount = "x", quiet = true }) ~= nil,
        "the same state without the deferral still heals")
end

----------------------------------------------------------------------
-- BAG-5: the mesh debt is recorded, and settled when Nexus goes away.
--
-- The audit's real-world shape, which the in-file suite did NOT cover: 1.x data
-- holding BOTH local characters and a cross-account mesh, with Nexus installed
-- and populated at the first 2.0 login. The old marker latched on
-- `counts.owners > 0`, but that count spans both passes while deferMesh
-- suppresses the mesh one entirely — so the store latched with the mesh half
-- never imported, and Migrate.SelfHeal could not recover it (it bails on a
-- non-empty owners table). Disable Nexus six months later and every
-- cross-account character and their gold is gone, permanently.
----------------------------------------------------------------------

local function testMeshDebtSettlement(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local defer  = { selfAccount = "acctSELF", deferMesh = true }
    local normal = { selfAccount = "acctSELF" }
    local quiet  = { quiet = true }

    -- (a) THE MIXED SOURCE, deferred. This is the state the audit describes.
    local data = Store._defaultData()
    Migrate.Run(data, sampleAccount(), sampleMesh(), defer)
    ck(data.migratedFrom1x == true, "(a) the marker latched")
    ck(data.owners["Shalk-Whitemane"] == nil, "(a) the mesh half really did not import")
    ck(data.meshImportDeferred == true, "(a) THE FIX: the unpaid half is written down")

    -- (b) A later login with Nexus STILL active: the debt stands, untouched.
    local held = Migrate.CompleteDeferredMesh(data, sampleMesh(), { deferMesh = true, quiet = true })
    ck(held ~= nil and held.skipped == true and held.reason == "nexus-active",
        "(b) settlement refuses while Nexus still owns those owners")
    ck(data.meshImportDeferred == true, "(b) ...and does NOT clear the debt")
    ck(data.owners["Shalk-Whitemane"] == nil, "(b) ...and imports nothing")

    -- Six months of live 2.0 play on the local character.
    local pu = data.owners["Puuchoco-Whitemane"]
    pu.money = 987654
    pu.containers[0].slots[1] = { id = 99999, count = 1 }

    -- (c) THE LOGIN WHERE NEXUS GOES AWAY. The debt is paid.
    local paid = Migrate.CompleteDeferredMesh(data, sampleMesh(), quiet)
    ck(paid ~= nil and paid.skipped == false, "(c) settlement runs once Nexus is gone")
    ck(paid.summary == 1 and paid.owners == 1,
        "(c) the genuinely-missing summary imported (the local twin is correctly skipped)")
    ck(data.owners["Shalk-Whitemane"] ~= nil, "(c) THE FIX: the cross-account character is back")
    ck(data.owners["Shalk-Whitemane"].money == 1022693, "(c) ...with its gold")
    ck(data.meshImportDeferred == nil, "(c) the debt is settled")
    ck(data.meshImportCompletedAt ~= nil, "(c) ...and stamped")

    -- (d) ADDITIVE-ONLY: six months of live data survived the settlement intact.
    --     This is why settlement is its own pass and not a forced Migrate.Run.
    --     Read back through data.owners, NOT the captured local: a settlement that
    --     REPLACED the record would leave the local looking untouched.
    local puNow = data.owners["Puuchoco-Whitemane"]
    ck(puNow == pu, "(d) the live record is the same table, not a replacement")
    ck(puNow.source == "full", "(d) ...still full, not downgraded to a 1.x summary")
    ck(puNow.money == 987654, "(d) the live character's money was NOT overwritten by the 1.x copy")
    ck(puNow.containers[0].slots[1].id == 99999, "(d) ...nor its live bag contents")

    -- (e) RED CONTROL: the forced re-run the audit's fix shape could be read as
    --     asking for really would clobber that live state. Kept so the choice of
    --     a separate additive pass is demonstrated, not merely asserted.
    Migrate.Run(data, sampleAccount(), sampleMesh(), { selfAccount = "acctSELF", force = true })
    ck(data.owners["Puuchoco-Whitemane"].money == 39000,
        "(e) RED CONTROL: a forced full re-run DOES overwrite live data with the 1.x snapshot")

    -- (f) ONE-SHOT. Nothing is owed after settlement.
    local again = Migrate.CompleteDeferredMesh(data, sampleMesh(), quiet)
    ck(again == nil, "(f) a settled store owes nothing on the next login")

    -- (g) A debt is only recorded when there IS one: deferring with no mesh source
    --     owes nothing (proven-before-written, same rule as the marker itself).
    local none = Store._defaultData()
    Migrate.Run(none, sampleAccount(), nil, defer)
    ck(none.migratedFrom1x == true, "(g) the run still latched")
    ck(none.meshImportDeferred == nil, "(g) ...but recorded no debt, because there was none")

    local emptyMesh = Store._defaultData()
    Migrate.Run(emptyMesh, sampleAccount(), { ["Whitemane"] = {} }, defer)
    ck(emptyMesh.meshImportDeferred == nil, "(g) an EMPTY mesh source records no debt either")

    -- (h) A non-deferred run leaves no debt standing.
    local plain = Store._defaultData()
    plain.meshImportDeferred = true                    -- a stale flag from anywhere
    Migrate.Run(plain, sampleAccount(), sampleMesh(), normal)
    ck(plain.meshImportDeferred == nil, "(h) the mesh half ran, so no debt is left recorded")

    -- (i) THE PRE-FIX INSTALL: latched before the deferral was ever written down,
    --     so it carries no flag. Not decidable from the data (a missing character
    --     is indistinguishable from one the owner removed by hand), so it is the
    --     owner's explicit gesture that settles it -- and only additively.
    local legacy = Store._defaultData()
    Migrate.Run(legacy, sampleAccount(), sampleMesh(), defer)
    legacy.meshImportDeferred = nil                    -- as an old build left it
    ck(Migrate.CompleteDeferredMesh(legacy, sampleMesh(), quiet) == nil,
        "(i) with no recorded debt the automatic settlement does nothing")
    local forced = Migrate.CompleteDeferredMesh(legacy, sampleMesh(),
                                                { force = true, quiet = true })
    ck(forced ~= nil and forced.summary == 1,
        "(i) the explicit /bags mesh import gesture settles it")
    ck(legacy.owners["Shalk-Whitemane"] ~= nil, "(i) ...and the character is back")
    ck(legacy.owners["Puuchoco-Whitemane"].source == "full",
        "(i) ...while the local character is still FULL, not downgraded to a summary")

    -- (j) The forced gesture still refuses while Nexus is active, and refuses on
    --     an absent source rather than pretending the debt is discharged.
    local g1 = Migrate.CompleteDeferredMesh(Store._defaultData(), sampleMesh(),
                                            { force = true, deferMesh = true, quiet = true })
    ck(g1 and g1.skipped and g1.reason == "nexus-active", "(j) forced import refuses under Nexus")
    local owing = Store._defaultData()
    owing.meshImportDeferred = true
    local g2 = Migrate.CompleteDeferredMesh(owing, nil, quiet)
    ck(g2 and g2.skipped and g2.reason == "no-source", "(j) an absent source is refused")
    ck(owing.meshImportDeferred == true,
        "(j) ...and the debt STANDS -- absence of the source is not proof there is no debt")
end

function Migrate.RunSelfTests(verbose)
    local suites = {
        { name = "parse item ref",   fn = testParse },
        { name = "convert container", fn = testConvertContainer },
        { name = "end-to-end + idempotency", fn = testEndToEndAndIdempotency },
        { name = "empty source leaves marker unset", fn = testEmptySourceLeavesMarkerUnset },
        { name = "sticky-marker self-heal", fn = testSelfHeal },
        { name = "nexus mesh-import deferral", fn = testMeshDeferral },
        { name = "deferred mesh debt settlement (BAG-5)", fn = testMeshDebtSettlement },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        if not ok then fails[#fails + 1] = "error: " .. tostring(err) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS migrate/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL migrate/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("migrate", Migrate.RunSelfTests)
end

return Migrate
