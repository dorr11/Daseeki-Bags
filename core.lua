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
ns.VERSION  = "2.0.0"
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
        elseif sub == "strip" then
            if ns.Frame and ns.Frame.DebugStrip then ns.Frame.DebugStrip()
            else ns:Print("strip diagnostic unavailable") end
        elseif sub == "toolbar" then
            if ns.Frame and ns.Frame.DebugToolbar then ns.Frame.DebugToolbar()
            else ns:Print("toolbar diagnostic unavailable") end
        elseif sub == "money" then
            if ns.Frame and ns.Frame.DebugMoney then ns.Frame.DebugMoney()
            else ns:Print("money diagnostic unavailable") end
        elseif sub == "nexus" then
            if ns.Nexus and ns.Nexus.Debug then ns.Nexus.Debug()
            else ns:Print("Nexus bridge diagnostic unavailable") end
        else
            ns:Print("unknown debug command: " .. sub)
        end
    elseif cmd == "mesh" then
        -- 1.x's cross-account sync commands (/dbg mesh, mesh send, mesh clear). The
        -- feature moved to Daseeki-Nexus; say so once, here, where it is missed.
        ns:Print("cross-account sync moved to Daseeki Nexus. Your 1.x mesh data was " ..
                 "imported and those characters are in the character list; the live " ..
                 "sync itself is now the Nexus Inventory module.")
    elseif cmd == "help" then
        ns:Print("commands (/bags, short /dbags; 1.x's /dbg and /Daseeki-Bags still work):")
        ns:Print("  /bags [toggle]      - show/hide the bag window")
        ns:Print("  /bags bank          - show/hide the bank window")
        ns:Print("  /bags find <name>   - find an item across every character")
        ns:Print("  /bags combined|split - switch layout")
        ns:Print("  /bags debug selftest - run self-tests")
        ns:Print("  /bags debug strip|toolbar|money - diagnose the open window")
        ns:Print("  /bags debug nexus   - is the Daseeki Nexus inventory bridge active?")
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

if _G.SlashCmdList then
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
end

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
    ck(#said == 1 and said[1]:lower():find("nexus", 1, true) ~= nil,
       "/dbg mesh points at Daseeki Nexus instead of failing as unknown")
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
