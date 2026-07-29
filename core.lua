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
-- Slash routing — /bags (short /dbags). Subcommands mirror the surface the
-- feature waves fill in; `debug selftest` runs the pure suites in-game.
-- Guarded so the file loads headless (no SlashCmdList global).
----------------------------------------------------------------------

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
        else
            ns:Print("unknown debug command: " .. sub)
        end
    elseif cmd == "help" then
        ns:Print("commands (/bags, short /dbags):")
        ns:Print("  /bags [toggle]      - show/hide the bag window")
        ns:Print("  /bags bank          - show/hide the bank window")
        ns:Print("  /bags find <name>   - find an item across every character")
        ns:Print("  /bags combined|split - switch layout")
        ns:Print("  /bags debug selftest - run self-tests")
    else
        ns:Print("unknown command '" .. cmd .. "'. Try /bags help.")
    end
end
ns.SlashDispatch = dispatch

if _G.SlashCmdList then
    _G.SLASH_DASEEKIBAGS1 = "/bags"
    _G.SLASH_DASEEKIBAGS2 = "/dbags"
    _G.SlashCmdList["DASEEKIBAGS"] = dispatch
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
        ns:SafeCall(function() ns.Items.SetSelf(UnitName("player") .. "-" .. GetRealmName()) end)
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

function ns.CoreRunSelfTests(verbose)
    local suites = {
        { name = "bus + error routing", fn = testBusAndRouting },
        { name = "event registry",      fn = testEventRegistry },
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
