-- Lib.lua: the few helpers Huddle needs, so it runs on its own. They mirror the author's shared library (AlcCore,
-- 2026-11-06), cut down to what Huddle calls:
--   Value: in combat the client hands addons "secret" values that Lua may not compare; this returns nil for them
--   error isolation (Safe): every way into Huddle's code runs under xpcall; the first error goes to the game's error
--     handler (BugSack shows it), repeats are counted, and after 20 that part switches itself off until /reload
--   timers, scripts, hooked scripts, guarded event registration on one shared event frame
--   OnLoad (saved variables are ready), WhenLoaded (a Blizzard addon is loaded), Fill (defaults), Printer
local ADDON, ns = ...
local L = {}
ns.L = L

--------------------------------------------------------------------- secret values
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- the value when Lua may use it, else nil (always exactly one return)
function L.Value(v)
	if v ~= nil and not IsSecret(v) then return v end
	return nil
end

-- pcall(fn, ...) and Value() in one: the first return when the call worked and it is readable, else nil
function L.Read(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok then return nil end
	return L.Value(v)
end

--------------------------------------------------------------------- error isolation
local MAX_ERRORS = 20
local errors = {}
L.errors = errors

local function report(label, err)
	local e = errors[label]
	if not e then
		e = { count = 0, first = tostring(err) }
		errors[label] = e
	end
	e.count = e.count + 1
	if e.count == 1 then
		local handler = geterrorhandler and geterrorhandler()
		if handler then pcall(handler, ADDON .. ": " .. label .. ": " .. tostring(err)) end
	elseif e.count == MAX_ERRORS then
		e.off = true
		print("|cff66ccff" .. ADDON .. "|r: " .. label .. " failed " .. MAX_ERRORS .. " times and is off until /reload.")
	end
end

-- the game's xpcall passes extra arguments on; plain Lua 5.1's does not (the test harness runs that)
local XPCALL_ARGS = select(2, xpcall(function(a) return a end, function() end, true)) == true

function L.Safe(label, fn)
	local function trace(err) return debugstack and (tostring(err) .. "\n" .. debugstack(2, 6, 0)) or tostring(err) end
	return function(...)
		local e = errors[label]
		if e and e.off then return end
		local ok, err
		if XPCALL_ARGS then
			ok, err = xpcall(fn, trace, ...)
		else
			local n, args = select("#", ...), { ... }
			ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, trace)
		end
		if not ok then report(label, err) end
	end
end

--------------------------------------------------------------------- timers, scripts, events
function L.After(seconds, fn, label)
	local safe = L.Safe(label or "timer", fn)
	if C_Timer and C_Timer.After then C_Timer.After(seconds, safe) else safe() end
end

function L.Script(frame, script, fn, label)
	frame:SetScript(script, L.Safe(label or script, fn))
end

-- after the frame's own script (a frame that is not Huddle's: its script stays as it is)
function L.HookScript(frame, script, fn, label)
	local ok = pcall(frame.HookScript, frame, script, L.Safe(label or script, fn))   -- guard: a frame without it
	return ok
end

local ev = CreateFrame("Frame")
local handlers = {}

-- RegisterEvent that never throws: an event a patch removed is skipped
local function Register(event)
	local valid = C_EventUtils and C_EventUtils.IsEventValid
	if valid then
		local ok, v = pcall(valid, event)   -- guard: a client whose test throws
		if ok and v == false then return false end
	end
	return (pcall(ev.RegisterEvent, ev, event))   -- guard: unknown events throw
end

function L.On(event, fn, label)
	if not handlers[event] then
		handlers[event] = {}
		Register(event)
	end
	local list = handlers[event]
	list[#list + 1] = L.Safe(label or event, fn)
end

ev:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do list[i](event, ...) end
end)

--------------------------------------------------------------------- loading
local loadFns, waiting = {}, {}
function L.OnLoad(fn) loadFns[#loadFns + 1] = L.Safe("OnLoad", fn) end

local function IsLoaded(name)
	local fn = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	return L.Read(fn, name) == true
end

-- fn once the addon `name` is loaded (now, if it already is)
function L.WhenLoaded(name, fn)
	if IsLoaded(name) then L.Safe("load " .. name, fn)() return end
	waiting[name] = waiting[name] or {}
	table.insert(waiting[name], L.Safe("load " .. name, fn))
end

L.On("ADDON_LOADED", function(_, name)
	if name == ADDON then
		for _, f in ipairs(loadFns) do f() end
	end
	local list = waiting[name]
	if list then
		waiting[name] = nil
		for _, f in ipairs(list) do f() end
	end
end, "ADDON_LOADED")

--------------------------------------------------------------------- the rest
-- missing keys from the defaults, nested; what is saved wins
function L.Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			if type(v) == "table" then
				t[k] = {}
				L.Fill(t[k], v)
			else
				t[k] = v
			end
		elseif type(v) == "table" and type(t[k]) == "table" then
			L.Fill(t[k], v)
		end
	end
	return t
end

function L.Printer(name, colour)
	local prefix = "|cff" .. colour .. name .. "|r: "
	return function(msg) print(prefix .. msg) end
end
