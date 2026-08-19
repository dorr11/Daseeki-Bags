-- Daseeki Bags 2.0 — core.lua
-- The addon-namespace plumbing every other 2.0 file assumes: the shared ns
-- runtime (Print / SafeCall / event dispatch / local callback bus / self-test
-- registry), the slash surface, and the init/login lifecycle that drives
-- Store.Init -> Migrate.Migrate -> (login) Capture.OnLogin + Frame.OnLogin.
--
-- Mirrors the Daseeki-Nexus core.lua idioms (same suite, same patterns) as
-- FRESH code — clean-room, no third-party identifiers.
--
-- Headless-safe: every game-only global (CreateFrame, SlashCmdList,
-- geterrorhandler) is guarded, so the real core loads under the test harness's
-- minimal stub and PROVIDES the methods the harness previously faked. This is
-- the reconciliation of "friction point 5": W1's capture.lua fires
-- ns:Fire("BAGS_CAPTURED", ...) and W2's ui_frame.lua subscribes with ns:On —
-- both are now backed by the real bus below.

local ADDON, ns = ...

ns.ADDON    = ADDON
ns.DISPLAY  = "Daseeki Bags"
ns.VERSION  = "2.0.9"
ns.CHAT_TAG = "|cffc9a24dDaseeki Bags|r"

----------------------------------------------------------------------
-- Error routing (standing suite rule: NEVER a silent pcall — surface every
-- error to the real handler). geterrorhandler is a live global in-game; the
-- harness installs a recorder so the "SafeCall error routing" self-test can
-- assert the route. Falls back to a re-raise if no handler is present at all.
----------------------------------------------------------------------

local function routeError(err)
    local geh = _G.geterrorhandler
    local handler = geh and geh()
    if handler then handler(err) else error(err, 0) end
end
ns.RouteError = routeError

----------------------------------------------------------------------
-- Chat print (addon-colored prefix). Freestanding print() is catalog-verified.
----------------------------------------------------------------------

function ns:Print(...)
    print(ns.CHAT_TAG .. ":", ...)
end

----------------------------------------------------------------------
-- SafeCall — pcall a fn and route any error to geterrorhandler (never hide the
-- traceback). Returns the pcall status so callers can branch.
----------------------------------------------------------------------

function ns:SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then routeError(err) end
    return ok, err
end

----------------------------------------------------------------------
-- Event dispatch
--
-- Modules subscribe with ns:RegisterEvent(event, handler). One shared frame
-- registers each Blizzard event once and fans out to every subscribed handler;
-- a throwing handler is isolated (error routed, siblings still run). Headless:
-- the frame is absent, so handlers are recorded but never driven by a real
-- OnEvent — the harness exercises modules directly.
----------------------------------------------------------------------

local eventFrame = _G.CreateFrame and _G.CreateFrame("Frame", "DaseekiBags2EventFrame")
ns.eventFrame = eventFrame

local eventHandlers = {}   -- event -> array of handler fns

function ns:RegisterEvent(event, handler)
    local list = eventHandlers[event]
    if not list then
        list = {}
        eventHandlers[event] = list
        if eventFrame then eventFrame:RegisterEvent(event) end
    end
    list[#list + 1] = handler
end

if eventFrame then
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        local list = eventHandlers[event]
        if not list then return end
        for i = 1, #list do
            local ok, err = pcall(list[i], event, ...)
            if not ok then routeError(err) end
        end
    end)
end

----------------------------------------------------------------------
-- Local callback bus (in-process signalling between modules; NOT network).
--   ns:On(name, listener)   -- multi-subscriber
--   ns:Fire(name, ...)      -- safe-calls each listener; one throwing listener
--                              never blocks the others (error routed).
-- capture.lua fires "BAGS_CAPTURED"; ui_frame.lua subscribes to debounce-repaint.
----------------------------------------------------------------------

local callbacks = {}   -- name -> array of listener fns

function ns:On(name, listener)
    local list = callbacks[name]
    if not list then
        list = {}
        callbacks[name] = list
    end
    list[#list + 1] = listener
end

function ns:Fire(name, ...)
    local list = callbacks[name]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then routeError(err) end
    end
end

-- =====================================================================
-- STOCK-SURFACE LEDGER  (2026-08-12 — the container-click taint defect)
--
-- THE LIVE DEFECT, read exactly. BugGrabber, Era 11509:
--
--   [ADDON_ACTION_BLOCKED] AddOn 'Daseeki-Bags' tried to call the protected
--   function 'UseContainerItem()'.
--   [C]: in function 'UseContainerItem'
--   [Blizzard_UIPanels_Game/Classic/ContainerFrame_Shared.lua]:1341: in function <...1288>
--   [C]: in function 'ContainerFrameItemButton_OnClick'
--   [*ContainerFrame.xml:163_OnClick]:13
--
-- Those two line numbers are not decoration; they name the code. Against the shipped
-- Classic-Era source, line 1288 is `function ContainerFrameItemButton_OnClick(self, button)`
-- and line 1341 -- the frame that was blocked -- is, character for character:
--
--   C_Container.UseContainerItem(self:GetParent():GetID(), self:GetID(), nil, nil,
--                                BankFrame:IsShown() and (BankFrame.selectedTab == 2));
--
-- That is the RIGHT-BUTTON branch: right-click an item to USE it. (The left-button branch
-- calls PickupContainerItem, which is not protected -- which is why picking items up never
-- broke and only "use" did.) It is reached from the stock template's own OnClick, which OUR
-- live cells deliberately inherit, so no Blizzard container frame has to be on screen for
-- this line to run: every right-click-to-use inside our own bag window ends here, by design.
--
-- WHAT LINE 1341 READS. Only five things: `self` and its parent (widgets we create -- every
-- bag replacement in the ecosystem creates those and none of them is blocked for it), the
-- two GetID() numbers, and the two GLOBAL VARIABLES `C_Container` and `BankFrame`. The
-- wiki's rule is short: "When code sets global values, the resulting value has the taint of
-- the execution path", and "when code accesses tainted values ... the execution path is also
-- tainted". So the reachable question is exactly one question: does this addon ever WRITE
-- the globals `C_Container` or `BankFrame`?
--
-- It does. Not in the bag code -- in the SELF-TEST RIGS. sort.lua's simulator installs its
-- fake client over the real one (`_G.C_Container`, `_G.BankFrame = nil`, plus GetTime,
-- CreateFrame, InCombatLockdown, ClearCursor, CursorHasItem, C_Item, C_Timer, bit, Enum),
-- ui_bank's rig overwrites `_G.BankFrame`, capture's rig overwrites `_G.C_Container`, and
-- store's rig nils the SavedVariables globals outright. They restore afterwards -- but a
-- restore is itself a write by tainted code, so the global carries OUR taint from the first
-- assignment until the next /reload. And those rigs are reachable IN THE CLIENT: core's own
-- help text advertises `/bags debug selftest`, and `/bags debug` with no subcommand runs
-- them too. One diagnostic command, and every right-click-to-use in the session is blocked,
-- with our name on it. (Same command also blew the owner's SavedVariables away: store's rig
-- nils DaseekiBags2Data/DB and re-inits defaults, which the client then writes to disk at
-- logout. One root cause, two defects.)
--
-- THE RULE THAT REPLACES IT. A test rig's contract is "I own the global table". That is true
-- headless and false in a client, and it must be PROVEN rather than assumed -- so the proof
-- is a positive beacon the harness plants (ns.HARNESS_BEACON) and the client never has.
-- Absence of the beacon means live; live means the rigs do not run. Fail-closed, in the
-- shape CLIENT_ASYNC_LESSONS class 4 already demands: absence of proof is not absence.
--
-- THE LEDGER. Refusing the rigs fixes the vector that fired. The ledger is what stops the
-- next one: every touch this addon makes on a Blizzard-owned NAME registers here, with its
-- kind, at the moment it is installed. `securehook` is the sanctioned post-hook; `replace`
-- is an outright takeover of a FrameXML global (we do exactly nine, all bag-toggle globals,
-- all enumerated below); `binding` is the BINDING_* string table the keybinding UI reads.
-- Two rules are then machine-checkable, in-game and headless, by walking the ledger:
--   (1) nothing we touch may be a global the blocked secure click path READS, and
--   (2) `replace` is only legal for the nine names REPLACE_ALLOWED lists.
-- The harness asserts both, and cross-checks the ledger against a source scan of every
-- `_G.<Name> =` in the shipping tree, so a new stock-surface write cannot arrive unnoticed.
-- =====================================================================

-- The GLOBAL read set of the secure container click path, with the line that reads each.
-- Sourced from the shipped Classic-Era ContainerFrame_Shared.lua, not from memory.
ns.SECURE_CLICK_READS = {
    C_Container     = "ContainerFrame_Shared.lua:1341 — C_Container.UseContainerItem(...)",
    BankFrame       = "ContainerFrame_Shared.lua:1341 — BankFrame:IsShown() and (BankFrame.selectedTab == 2)",
    StackSplitFrame = "ContainerFrame_Shared.lua:1342/1316 — StackSplitFrame:Hide()",
    MerchantFrame   = "ContainerFrame_Shared.lua:1303/1318 — MerchantFrame.extendedCost / :IsShown()",
    AuctionHouseFrame = "ContainerFrame_Shared.lua:1334 — AuctionHouseFrame:IsShown()",
    ItemLocation    = "ContainerFrame_Shared.lua:1329 — ItemLocation:CreateFromBagAndSlot(...)",
    C_AuctionHouse  = "ContainerFrame_Shared.lua:1330 — C_AuctionHouse.IsSellItemValid(...)",
    C_Item          = "ContainerFrame_Shared.lua:1331 — C_Item.DoesItemExist(...)",
}

ns.StockSurface = { entries = {}, byName = {} }

-- The only kinds that exist. `securehook` never taints; `replace` always does and is
-- therefore closed to the roster below; `binding` is a string the keybinding UI reads.
ns.StockSurface.KINDS = { securehook = true, replace = true, binding = true, registry = true }

-- The nine FrameXML bag-toggle globals ui_frame takes over, and nothing else. These are
-- insecure FrameXML helpers, none is on the secure click path's read set, and taking them
-- over is what makes the bag key open OUR window (see ui_frame.HookBagToggles).
ns.StockSurface.REPLACE_ALLOWED = {
    ToggleBackpack = true, ToggleAllBags = true, ToggleBag = true,
    OpenAllBags = true, OpenBackpack = true, OpenBag = true,
    CloseAllBags = true, CloseBackpack = true, CloseBag = true,
}

-- Record one touch. Idempotent per (name, kind): installers are guarded to run once, but a
-- re-entry must not double the ledger and turn a clean walk into a false alarm.
function ns.StockSurface.Record(name, kind, why)
    if type(name) ~= "string" or type(kind) ~= "string" then return false end
    local prev = ns.StockSurface.byName[name]
    if prev and prev.kind == kind then return false end
    local e = { name = name, kind = kind, why = why }
    ns.StockSurface.entries[#ns.StockSurface.entries + 1] = e
    ns.StockSurface.byName[name] = e
    return true
end

-- Walk the ledger and report every entry that breaks a rule. PURE: no client needed, so
-- the harness pins it and `/bags debug surface` can print it live.
function ns.StockSurface.Violations()
    local bad = {}
    for _, e in ipairs(ns.StockSurface.entries) do
        if not ns.StockSurface.KINDS[e.kind] then
            bad[#bad + 1] = e.name .. ": unknown kind '" .. tostring(e.kind) .. "'"
        end
        if ns.SECURE_CLICK_READS[e.name] then
            bad[#bad + 1] = e.name .. ": touched (" .. e.kind .. ") but it is READ by the " ..
                            "secure container click path — " .. ns.SECURE_CLICK_READS[e.name]
        end
        if e.kind == "replace" and not ns.StockSurface.REPLACE_ALLOWED[e.name] then
            bad[#bad + 1] = e.name .. ": replaced outright and is not one of the nine " ..
                            "bag-toggle globals the design allows"
        end
    end
    return bad
end

----------------------------------------------------------------------
-- HARNESS OWNERSHIP OF THE GLOBAL TABLE
--
-- The self-test rigs swap real globals for fakes. That is correct headless and catastrophic
-- in a client (see the banner above). The beacon is planted by harness/run-selftests.lua and
-- exists nowhere else, so the answer is positive-evidence only: no beacon, no rigs.
----------------------------------------------------------------------
ns.HARNESS_BEACON = "__DaseekiBagsHarness"

function ns:HarnessOwnsGlobals()
    return _G[ns.HARNESS_BEACON] == true
end

ns.SELFTEST_REFUSAL =
    "self-tests are headless-only: they swap real game globals (C_Container, BankFrame, " ..
    "GetTime, CreateFrame) and the saved-variable tables for fakes, which taints the " ..
    "container click path and would blank your saved data. Run harness/run-selftests.cmd."

----------------------------------------------------------------------
-- Self-test registry (pure-Lua suites; the headless harness runs these).
----------------------------------------------------------------------

local selfTests = {}   -- ordered { name, fn(verbose) -> ok }

function ns:RegisterSelfTest(name, fn)
    selfTests[#selfTests + 1] = { name = name, fn = fn }
end

-- Run every registered suite in registration order. Each suite is pcall-isolated
-- so one crashing suite can't abort the run (its failure is reported and the
-- overall result goes red). Returns the overall pass boolean.
function ns:RunRegisteredSelfTests(verbose)
    -- THE GATE (2026-08-12). Not a warning, not a "verbose" nicety: a refusal. Every suite below
    -- installs a fake client over the real one, and the two globals the container click path
    -- reads (C_Container, BankFrame) are both in that set. Running one suite in the client
    -- blocks every right-click-to-use for the rest of the session and re-inits the saved
    -- data. Nothing partial is safe here, so nothing runs.
    if not ns:HarnessOwnsGlobals() then
        ns:Print(ns.SELFTEST_REFUSAL)
        return false
    end
    local allPass = true
    for i = 1, #selfTests do
        if verbose then ns:Print("selftest: " .. selfTests[i].name) end
        local ok, res = pcall(selfTests[i].fn, verbose)
        local passed = ok and res
        if not ok then ns:Print("  FAIL " .. selfTests[i].name .. " :: error " .. tostring(res)) end
        allPass = allPass and passed
    end
    if verbose then
        ns:Print(allPass and "selftest: ALL SUITES PASS" or "selftest: FAILURES ABOVE")
    end
    return allPass
end

----------------------------------------------------------------------
-- Slash routing — /bags (short /dbags), plus the two LEGACY 1.x commands.
--
-- RELEASE-GATE C.10 ("previous slash commands still resolve"), and the same reasoning
-- as the legacy Bindings.xml action names (AT-RISK-4): 1.x registered `/Daseeki-Bags`
-- and `/dbg` (its slashCommands.lua:26-28, keyed on the folder name). At the cutover the
-- 1.x tree goes away and, with it, those two commands — so anything the owner has typed
-- for years, or written into a macro, would start answering "Type /help for a list of
-- commands". They are therefore re-registered here onto the SAME dispatcher. Four
-- command strings on one SlashCmdList key is ordinary; the client scans SLASH_<KEY><n>.
--
-- Declared unconditionally (not inside the SlashCmdList guard) so the headless harness
-- can assert the roster: this list is the C.10 regression guard, and losing an entry
-- from it is the slash-command version of orphaning a keybinding.
--
-- Subcommands mirror the surface the feature waves fill in; `debug selftest` runs the
-- pure suites in-game. `mesh` is a legacy 1.x subcommand kept as a SIGNPOST (gate E.19):
-- cross-account sync moved to Daseeki-Nexus, and the point of loss is where it is said.
----------------------------------------------------------------------

ns.SLASH_COMMANDS = { "/bags", "/dbags", "/dbg", "/daseeki-bags" }
-- The subset inherited from 1.x. Dropping one is a user typing into the void.
ns.SLASH_LEGACY   = { "/dbg", "/daseeki-bags" }


local function dispatch(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "toggle" then
        if ns.Frame and ns.Frame.Toggle then ns.Frame.Toggle() end
    elseif cmd == "combined" or cmd == "split" then
        if ns.Frame and ns.Frame.SetLayout then ns.Frame.SetLayout(cmd) end
    elseif cmd == "bank" then
        if ns.Bank and ns.Bank.Toggle then ns.Bank.Toggle() end
    elseif cmd == "find" then
        if ns.Find and ns.Find.Open then ns.Find.Open(rest) end
    elseif cmd == "debug" then
        local sub = (rest or ""):match("^(%S*)"):lower()
        if sub == "selftest" or sub == "" then
            ns:RunRegisteredSelfTests(true)
        elseif sub == "surface" then
            -- 2026-08-12: print the stock-surface ledger. `debug selftest` used to be the answer
            -- to "what is this addon doing to the game's own UI?" and that answer cost the
            -- owner his right-click. This is the answer that is safe to ask in a client:
            -- every Blizzard-owned name we touch, how we touch it, and the rule walk.
            ns:Print("stock surface — every Blizzard-owned name this addon touches:")
            for _, e in ipairs(ns.StockSurface.entries) do
                ns:Print(string.format("  %-22s %-11s %s", e.name, e.kind, e.why or ""))
            end
            if #ns.StockSurface.entries == 0 then
                ns:Print("  (nothing installed yet — hooks go in at login)")
            end
            local bad = ns.StockSurface.Violations()
            if #bad == 0 then
                ns:Print("  rule walk: clean (nothing we touch is read by the secure " ..
                         "container click path, and every takeover is one of the nine " ..
                         "bag-toggle globals)")
            else
                for _, v in ipairs(bad) do ns:Print("  VIOLATION: " .. v) end
            end
        elseif sub == "strip" then
            if ns.Frame and ns.Frame.DebugStrip then ns.Frame.DebugStrip()
            else ns:Print("strip diagnostic unavailable") end
        elseif sub == "toolbar" then
            if ns.Frame and ns.Frame.DebugToolbar then ns.Frame.DebugToolbar()
            else ns:Print("toolbar diagnostic unavailable") end
        elseif sub == "bankstrip" then
            -- 2.0.4: the BANK bag-slot strip's sibling of `debug strip`. Added with the
            -- bank-bag swap fix for exactly the reason the inventory one was added — the
            -- defect it fixes was a SILENT behavioral report (no Lua error anywhere, the
            -- cells simply did nothing), and a readout is what turns that into a fact.
            if ns.Bank and ns.Bank.DebugStrip then ns.Bank.DebugStrip()
            else ns:Print("bank strip diagnostic unavailable") end
        elseif sub == "money" then
            if ns.Frame and ns.Frame.DebugMoney then ns.Frame.DebugMoney()
            else ns:Print("money diagnostic unavailable") end
        elseif sub == "equiptrace" then
            -- 2.0.5: the equip-swap capture trace. Same reasoning as `debug bankstrip` and
            -- the sort log — the defect it diagnoses is SILENT (no Lua error, the cell just
            -- keeps drawing the old item), so the only way to answer a repeat report is a
            -- record the owner already has in his SavedVariables.
            if ns.Capture and ns.Capture.PrintTrace then ns.Capture.PrintTrace(rest:match("^%S*%s*(.-)%s*$"))
            else ns:Print("equip trace unavailable") end
        elseif sub == "nexus" then
            if ns.Nexus and ns.Nexus.Debug then ns.Nexus.Debug()
            else ns:Print("Nexus bridge diagnostic unavailable") end
        else
            ns:Print("unknown debug command: " .. sub)
        end
    elseif cmd == "sortlog" then
        -- 2.0.2a: the sort telemetry ring buffer. A TOP-LEVEL subcommand, not one under
        -- `debug`, because the owner asked for it by name as `/dbg sortlog` — and every
        -- command string in ns.SLASH_COMMANDS reaches this one dispatcher, so /bags,
        -- /dbags, /dbg and /Daseeki-Bags all answer it identically.
        if ns.Sort and ns.Sort.PrintLog then ns.Sort.PrintLog(rest)
        else ns:Print("the sort engine is not loaded, so there is no sort log") end
    elseif cmd == "mesh" then
        local sub = (rest or ""):match("^(%S*)"):lower()
        if sub == "import" then
            -- BAG-5's explicit release path. The automatic settlement needs a
            -- deferral recorded at migration time; a store that migrated before
            -- that existed carries none, and whether it owes anything is not
            -- decidable from the data. So the owner can say so. Additive-only.
            if ns.Migrate and ns.Migrate.MeshImportCommand then ns.Migrate.MeshImportCommand()
            else ns:Print("the 1.x import is not loaded") end
        else
            -- 1.x's cross-account sync commands (/dbg mesh, mesh send, mesh clear). The
            -- feature moved to Daseeki-Nexus; say so once, here, where it is missed.
            ns:Print("cross-account sync moved to Daseeki Nexus. Your 1.x mesh data was " ..
                     "imported and those characters are in the character list; the live " ..
                     "sync itself is now the Nexus Inventory module.")
            ns:Print("  /bags mesh import - re-import cross-account characters from your " ..
                     "1.x data if they are missing from the list")
        end
    elseif cmd == "help" then
        ns:Print("commands (/bags, short /dbags; 1.x's /dbg and /Daseeki-Bags still work):")
        ns:Print("  /bags [toggle]      - show/hide the bag window")
        ns:Print("  /bags bank          - show/hide the bank window")
        ns:Print("  /bags find <name>   - find an item across every character")
        ns:Print("  /bags combined|split - switch layout")
        ns:Print("  /bags sortlog [clear] - the last 50 sort runs, newest first")
        ns:Print("  /bags debug surface - what this addon touches in the game's own UI")
        ns:Print("  /bags debug selftest - headless only (run harness/run-selftests.cmd)")
        ns:Print("  /bags debug strip|bankstrip|toolbar|money - diagnose the open window")
        ns:Print("  /bags debug equiptrace [clear] - what the last equip swaps did to your bag cells")
        ns:Print("  /bags debug nexus   - is the Daseeki Nexus inventory bridge active?")
        ns:Print("  /bags mesh import   - re-import cross-account characters from your 1.x data")
    else
        ns:Print("unknown command '" .. cmd .. "'. Try /bags help.")
    end
end
ns.SlashDispatch = dispatch

if _G.SlashCmdList then
    for i, cmdText in ipairs(ns.SLASH_COMMANDS) do
        _G["SLASH_DASEEKIBAGS" .. i] = cmdText
    end
    _G.SlashCmdList["DASEEKIBAGS"] = dispatch
    ns.StockSurface.Record("SlashCmdList", "registry",
        "one entry added under our own key (DASEEKIBAGS) — the sanctioned slash mechanism")
end

----------------------------------------------------------------------
-- Keybindings (audit §10.2). Bindings.xml calls these in-game handler globals; the
-- BINDING_HEADER_/BINDING_CATEGORY_/BINDING_NAME_ strings label them in the KeyBindings
-- UI (enUS inline — suite convention, no localization files on this tree).
--
-- Bindings.xml is auto-discovered by the client from the addon root and is NOT listed in
-- any .toc (listing it there ALSO double-loads it through the generic UI-XML parser, which
-- warns on every <Binding>). It may therefore be parsed before this file runs — every
-- binding body is guarded on its handler global, so that ordering is harmless.
--
-- Action names: the DASEEKIBAGS2_* set is 2.0's own, and the two LEGACY 1.x names
-- (DASEEKIBAGS_TOGGLE / DASEEKIBAGS_BANK_TOGGLE) are declared alongside them so a key the
-- owner bound under 1.x still fires after the cutover removes the 1.x addon — a binding is
-- stored against an action NAME, so a name that disappears orphans the key
-- (ROLLOUT_CONTINUITY_AUDIT AT-RISK-4). Both names call the same handler below; only the
-- labels differ, so the Key Bindings list does not show two identical rows. Guarded on
-- _G.SlashCmdList so the headless harness (no SlashCmdList, no bindings UI) never sees these.
----------------------------------------------------------------------

-- 2026-08-12: a NAMED function rather than a bare `if` block, so the stock-surface gate can drive
-- the one path that writes BINDING_* and prove the ledger records what the code really does.
-- The guard is unchanged; only the shape is.
function ns.DeclareBindingGlobals()
    function _G.DaseekiBags2_ToggleBags() if ns.Frame and ns.Frame.Toggle then ns.Frame.Toggle() end end
    function _G.DaseekiBags2_ToggleBank() if ns.Bank and ns.Bank.Toggle then ns.Bank.Toggle() end end
    function _G.DaseekiBags2_ToggleFind()
        if ns.Find and ns.Find.Toggle then ns.Find.Toggle()
        elseif ns.Find and ns.Find.Open then ns.Find.Open() end
    end

    _G.BINDING_HEADER_DASEEKIBAGS2           = "Daseeki Bags"
    _G.BINDING_CATEGORY_DASEEKIBAGS2         = "Daseeki Bags"
    _G.BINDING_NAME_DASEEKIBAGS2_TOGGLE      = "Toggle Bags"
    _G.BINDING_NAME_DASEEKIBAGS2_BANK_TOGGLE = "Toggle Bank"
    _G.BINDING_NAME_DASEEKIBAGS2_FIND        = "Find Item Across Characters"

    -- Legacy 1.x action names kept alive for keybinding continuity at cutover.
    _G.BINDING_NAME_DASEEKIBAGS_TOGGLE       = "Toggle Bags (legacy binding)"
    _G.BINDING_NAME_DASEEKIBAGS_BANK_TOGGLE  = "Toggle Bank (legacy binding)"

    -- 2026-08-12: these are Blizzard-NAMESPACE globals (the keybinding UI reads BINDING_*), so
    -- they belong in the stock-surface ledger even though they are only display strings and
    -- there is no other way to name a binding. None is on the secure click path's read set.
    for _, n in ipairs({ "BINDING_HEADER_DASEEKIBAGS2", "BINDING_CATEGORY_DASEEKIBAGS2",
                         "BINDING_NAME_DASEEKIBAGS2_TOGGLE",
                         "BINDING_NAME_DASEEKIBAGS2_BANK_TOGGLE",
                         "BINDING_NAME_DASEEKIBAGS2_FIND",
                         "BINDING_NAME_DASEEKIBAGS_TOGGLE",
                         "BINDING_NAME_DASEEKIBAGS_BANK_TOGGLE" }) do
        ns.StockSurface.Record(n, "binding", "keybinding display string (Bindings.xml)")
    end
    return true
end

if _G.SlashCmdList then ns.DeclareBindingGlobals() end

----------------------------------------------------------------------
-- Lifecycle
--   ADDON_LOADED (this addon) -> Store.Init() then one-time Migrate.Migrate()
--                                (marker-guarded/idempotent). Fires STORE_READY.
--   PLAYER_LOGIN              -> live modules go active: Capture.OnLogin()
--                                (event wiring + first snapshot) and
--                                Frame.OnLogin() (bag-toggle hooks + refresh
--                                subscription). Fires LOGIN.
--   PLAYER_LOGOUT            -> flush hooks (future). Fires LOGOUT.
----------------------------------------------------------------------

ns.state = { loaded = false, loggedIn = false }

ns:RegisterEvent("ADDON_LOADED", function(_, loaded)
    if loaded ~= ADDON then return end
    if ns.Store and ns.Store.Init then ns.Store.Init() end
    if ns.Migrate and ns.Migrate.Migrate then ns:SafeCall(ns.Migrate.Migrate) end
    ns.state.loaded = true
    ns:Fire("STORE_READY")
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    ns.state.loggedIn = true
    -- Items must know the self character before any IsLive gate runs, so alt and
    -- remote owners render read-only from the first paint.
    if ns.Items and ns.Items.SetSelf and UnitName and GetRealmName then
        ns:SafeCall(function()
            -- MUST match capture.selfNameRealm's canonical key EXACTLY: the realm is
            -- space-stripped there (SV keys drop spaces), so a raw UnitName.."-"..realm
            -- mismatches owner.nameRealm on any spaced-realm and IsLive() is falsely
            -- false — self bags would render inert and the bag-slot strip never becomes
            -- manageable. Canonicalize through Store.MakeNameRealm(name, spaceStripped).
            local realm = ((GetRealmName() or ""):gsub("%s+", ""))
            local key = ns.Store.MakeNameRealm(UnitName("player"), realm)
            ns.Items.SetSelf(key)
            -- SORT LOCKS are per-character and keyed by the SAME canonical string, for
            -- the same reason: a mismatch here would silently read an empty lock set on
            -- any spaced-realm character and quietly sort slots the owner locked.
            if ns.Locks and ns.Locks.SetCharacter then ns.Locks.SetCharacter(key) end
        end)
    end
    -- Player class token drives the item-usability (proficiency) desaturation.
    if ns.Items and ns.Items.SetPlayerClass and UnitClass then
        ns:SafeCall(function() ns.Items.SetPlayerClass((select(2, UnitClass("player")))) end)
    end
    -- Player LEVEL drives the required-level (red border) gate. Seeded here for the same
    -- reason the class token is: the grid can paint before the client has answered for the
    -- player's own unit, and UnitLevel returns 0 until it has. SetPlayerLevel ignores a
    -- zero, so an early login seeds nothing and the gate stays "unknown" — which never
    -- washes an item — rather than seeing a truthy zero (data-honesty BAG-3).
    if ns.Items and ns.Items.SetPlayerLevel and UnitLevel then
        ns:SafeCall(function() ns.Items.SetPlayerLevel(UnitLevel("player")) end)
    end
    if ns.Capture and ns.Capture.OnLogin then ns:SafeCall(ns.Capture.OnLogin) end
    if ns.Frame   and ns.Frame.OnLogin   then ns:SafeCall(ns.Frame.OnLogin)   end
    ns:Fire("LOGIN")
end)

ns:RegisterEvent("PLAYER_LOGOUT", function()
    ns:Fire("LOGOUT")
end)

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "core") — the bus + error routing contract.
----------------------------------------------------------------------

-- Multi-subscriber Fire/On + handler-error isolation + SafeCall routing.
local function testBusAndRouting(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Swap in a recording error handler for the duration of this suite so we can
    -- assert routing WITHOUT hiding real errors (restored in a finally-style pcall).
    local captured = {}
    local prevGEH = _G.geterrorhandler
    _G.geterrorhandler = function() return function(err) captured[#captured + 1] = err end end

    local ok, err = pcall(function()
        -- 1) multi-subscriber Fire/On: every listener runs, in order, with args.
        local hits = {}
        ns:On("T_MSG", function(a, b) hits[#hits + 1] = "h1:" .. tostring(a) .. "/" .. tostring(b) end)
        ns:On("T_MSG", function(a)    hits[#hits + 1] = "h2:" .. tostring(a) end)
        ns:Fire("T_MSG", "x", 7)
        ck(#hits == 2, "both subscribers fired")
        ck(hits[1] == "h1:x/7" and hits[2] == "h2:x", "listeners get args in order")

        -- 2) handler-error isolation: a throwing listener routes its error but
        --    never blocks a later listener; Fire itself does not throw.
        local reached = false
        ns:On("T_ERR", function() error("boom-in-listener") end)
        ns:On("T_ERR", function() reached = true end)
        local fireOk = pcall(function() ns:Fire("T_ERR") end)
        ck(fireOk, "Fire does not propagate a listener error")
        ck(reached, "later listener still runs after an earlier one throws")
        ck(#captured >= 1, "listener error was ROUTED to geterrorhandler (not swallowed)")
        local sawBoom = false
        for _, e in ipairs(captured) do if tostring(e):find("boom%-in%-listener") then sawBoom = true end end
        ck(sawBoom, "routed error carries the listener's message")

        -- 3) SafeCall routes a thrown error and reports ok=false.
        local before = #captured
        local scOk = ns:SafeCall(function() error("boom-in-safecall") end)
        ck(scOk == false, "SafeCall returns ok=false on error")
        ck(#captured == before + 1, "SafeCall routed exactly one error")
        -- ...and returns ok=true, swallowing nothing, on success.
        local okTrue = ns:SafeCall(function() end)
        ck(okTrue == true, "SafeCall returns ok=true on success")

        -- 4) Fire on an unknown message is a no-op (no listeners, no error).
        local noOne = pcall(function() ns:Fire("T_NOBODY") end)
        ck(noOne, "Fire on a message with no subscribers is a safe no-op")
    end)

    _G.geterrorhandler = prevGEH   -- restore
    if not ok then fails[#fails + 1] = "suite error: " .. tostring(err) end
end

-- Event dispatch registry: RegisterEvent accumulates multiple handlers per event.
local function testEventRegistry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Two handlers for one event; both recorded under the same event key.
    ns:RegisterEvent("T_EVENT", function() end)
    ns:RegisterEvent("T_EVENT", function() end)
    -- We can't drive OnEvent headless (no frame), but the registry must accept
    -- multiple handlers without error — the fan-out path is identical to Fire,
    -- which is covered above.
    ck(true, "RegisterEvent accepts multiple handlers")
end

-- Slash roster (release-gate C.10). The mirror of the harness's EXPECTED_BINDINGS check:
-- a command the owner has typed for years, or baked into a macro, must not vanish because
-- the addon it belonged to was rewritten. The two 1.x commands are named explicitly so
-- deleting one from ns.SLASH_COMMANDS turns this suite red instead of shipping.
local function testSlashRoster(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local declared = {}
    for _, c in ipairs(ns.SLASH_COMMANDS or {}) do declared[c] = true end
    ck(declared["/bags"],  "/bags is declared")
    ck(declared["/dbags"], "/dbags is declared")
    for _, c in ipairs(ns.SLASH_LEGACY or {}) do
        ck(declared[c], "LEGACY 1.x command " .. c .. " is still declared (gate C.10)")
    end
    ck(type(ns.SlashDispatch) == "function", "one dispatcher backs every command")
    -- The legacy `mesh` subcommand answers with the where-it-went notice rather than
    -- "unknown command" (gate E.19: a moved feature announces itself at the point of loss).
    local said = {}
    local realPrint = ns.Print
    ns.Print = function(_, ...) said[#said + 1] = table.concat({ ... }, " ") end
    ns.SlashDispatch("mesh")
    ns.Print = realPrint
    ck(#said == 2 and said[1]:lower():find("nexus", 1, true) ~= nil,
       "/dbg mesh points at Daseeki Nexus instead of failing as unknown")
    -- BAG-5: the bare notice also advertises the explicit re-import gesture, because
    -- a release path nobody is told about is the same as no release path (CDT-3's
    -- Unblock() with zero live callers is the suite's cautionary tale).
    ck(#said == 2 and said[2]:find("mesh import", 1, true) ~= nil,
       "...and names /bags mesh import as the way back for a missing cross-account alt")

    -- `mesh import` reaches the migration, not the notice.
    local reached = false
    local realMig = ns.Migrate
    ns.Migrate = { MeshImportCommand = function() reached = true end }
    said = {}
    ns.Print = function(_, ...) said[#said + 1] = table.concat({ ... }, " ") end
    ns.SlashDispatch("mesh import")
    ns.Print, ns.Migrate = realPrint, realMig
    ck(reached and #said == 0, "/bags mesh import routes to the 1.x re-import, not the notice")

    -- 2.0.2a: `sortlog` is a TOP-LEVEL subcommand on the same dispatcher, so it answers
    -- on all four command strings. Pinned here because it is the coordinator's read
    -- surface for the telemetry ring — losing the route makes the data unreachable
    -- in-game even though it is still on disk.
    local logged = {}
    ns.Print = function(_, ...) logged[#logged + 1] = table.concat({ ... }, " ") end
    ns.SlashDispatch("sortlog")
    ns.SlashDispatch("sortlog clear")
    ns.Print = realPrint
    ck(#logged >= 2, "/bags sortlog and /bags sortlog clear both answer")
    local anyUnknown = false
    for _, l in ipairs(logged) do
        if l:lower():find("unknown command", 1, true) then anyUnknown = true end
    end
    ck(not anyUnknown, "…and neither falls through to 'unknown command'")
end

function ns.CoreRunSelfTests(verbose)
    local suites = {
        { name = "bus + error routing", fn = testBusAndRouting },
        { name = "event registry",      fn = testEventRegistry },
        { name = "slash roster",        fn = testSlashRoster },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local okc, e = pcall(suite.fn, fails)
        if not okc then fails[#fails + 1] = "error: " .. tostring(e) end
        local passed = #fails == 0
        if not passed then allPass = false end
        if verbose and ns.Print then
            if passed then ns:Print("  PASS core/" .. suite.name)
            else for _, f in ipairs(fails) do ns:Print("  FAIL core/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

ns:RegisterSelfTest("core", ns.CoreRunSelfTests)

return ns
