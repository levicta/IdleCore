--[[
================================================================================
  TickService
  Location: ServerStorage/Framework/TickService (ModuleScript)
================================================================================

  The central heartbeat for the entire framework. Other services register
  tick handlers here instead of creating their own RunService loops, keeping
  all passive-income and time-based logic on a single, controlled cadence.

  ARCHITECTURE NOTES:
    - Server-only. Never require this from a LocalScript.
    - Internally uses RunService.Heartbeat for sub-second precision, but
      fires registered callbacks at configurable intervals (default: 1s).
    - Supports multiple named tick groups with independent intervals, so
      CurrencyService can tick every 1s while SaveService ticks every 30s.

--------------------------------------------------------------------------------
  API REFERENCE
--------------------------------------------------------------------------------

  TickService.new() -> TickServiceImpl
    Creates and returns the singleton service instance.
    Call once from your server bootstrap script; re-requiring the module
    returns the same instance via the module-level cache.

  TickService:Start() -> ()
    Begins the heartbeat loop. Safe to call multiple times (no-op if running).

  TickService:Stop() -> ()
    Disconnects the heartbeat loop. Primarily for testing / cleanup.

  TickService:RegisterGroup(groupName: string, interval: number) -> ()
    Creates a named tick group that fires every `interval` seconds.
    groupName  - unique identifier, e.g. "Passive", "AutoSave"
    interval   - seconds between fires (minimum clamped to Config.MIN_TICK_INTERVAL)

  TickService:Bind(groupName: string, id: string, callback: TickCallback) -> ()
    Attaches a callback to a tick group.
    groupName  - must match a previously registered group
    id         - unique key within the group (used to unbind later)
    callback   - function(deltaTime: number) -> ()
                 deltaTime is the group interval, not the raw Heartbeat delta.

  TickService:Unbind(groupName: string, id: string) -> ()
    Removes a previously bound callback. Safe to call if id does not exist.

  TickService:GetElapsed() -> number
    Returns total seconds since Start() was called.

  TickService:GetTick(groupName: string) -> number
    Returns how many times the given group has fired since Start().

--------------------------------------------------------------------------------
  EXAMPLE USAGE
--------------------------------------------------------------------------------

  -- In your server bootstrap Script (ServerScriptService):
  local TickService = require(game.ServerStorage.Framework.TickService)
  local ts = TickService.new()

  -- Register tick groups
  ts:RegisterGroup("Passive", 1)    -- fires every 1 second
  ts:RegisterGroup("AutoSave", 30)  -- fires every 30 seconds

  -- Bind a passive income handler
  ts:Bind("Passive", "CurrencyTick", function(dt: number)
      print("Passive tick! dt =", dt)
      -- CurrencyService:Tick(dt) goes here
  end)

  -- Bind an auto-save handler
  ts:Bind("AutoSave", "SaveTick", function(dt: number)
      print("Auto-saving...")
      -- SaveService:SaveAll() goes here
  end)

  ts:Start()

  -- Later, to remove a specific handler:
  ts:Unbind("Passive", "CurrencyTick")

================================================================================
--]]

-- Services
local RunService = game:GetService("RunService")

-- Shared config (ReplicatedStorage/Shared/Config ModuleScript).
-- Falls back to safe defaults so TickService works standalone during dev.
local Config = (function()
    local ok, cfg = pcall(function()
        return require(game:GetService("ReplicatedStorage").Shared.Config)
    end)
    if ok then return cfg end
    return {
        MIN_TICK_INTERVAL     = 0.1, -- seconds; clamp floor for all groups
        DEFAULT_TICK_INTERVAL = 1,   -- seconds; used for the built-in "Passive" group
    }
end)()

--------------------------------------------------------------------------------
-- Type definitions
--------------------------------------------------------------------------------

export type TickCallback = (deltaTime: number) -> ()

type TickGroup = {
    interval:    number,                       -- desired seconds between fires
    accumulated: number,                       -- seconds since last fire
    tickCount:   number,                       -- total fires since Start()
    callbacks:   { [string]: TickCallback },   -- id -> callback map
}

export type TickServiceImpl = {
    _running:    boolean,
    _connection: RBXScriptConnection?,
    _elapsed:    number,
    _groups:     { [string]: TickGroup },

    Start:         (self: TickServiceImpl) -> (),
    Stop:          (self: TickServiceImpl) -> (),
    RegisterGroup: (self: TickServiceImpl, groupName: string, interval: number) -> (),
    Bind:          (self: TickServiceImpl, groupName: string, id: string, callback: TickCallback) -> (),
    Unbind:        (self: TickServiceImpl, groupName: string, id: string) -> (),
    GetElapsed:    (self: TickServiceImpl) -> number,
    GetTick:       (self: TickServiceImpl, groupName: string) -> number,
}

--------------------------------------------------------------------------------
-- Module + singleton cache
--------------------------------------------------------------------------------

local TickService = {}
TickService.__index = TickService

-- Module-level singleton cache — re-requiring returns the same object.
local _instance: TickServiceImpl? = nil

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

--[[
    TickService.new() -> TickServiceImpl

    Returns the singleton TickService instance, creating it if it doesn't
    already exist. Any service can safely call TickService.new() without
    spawning duplicate heartbeat loops.
--]]
function TickService.new(): TickServiceImpl
    if _instance then
        return _instance
    end

    local self: TickServiceImpl = setmetatable({
        _running    = false,
        _connection = nil,
        _elapsed    = 0,
        _groups     = {},
    }, TickService) :: any

    -- Pre-register the "Passive" group for convenience; services bind to it
    -- by default without needing an explicit RegisterGroup call.
    self:RegisterGroup("Passive", Config.DEFAULT_TICK_INTERVAL)

    _instance = self
    return self
end

--------------------------------------------------------------------------------
-- Public methods
--------------------------------------------------------------------------------

--[[
    :Start() -> ()

    Connects RunService.Heartbeat and begins the tick loop.
    Calling Start() while already running is a no-op (warns once).
--]]
function TickService:Start()
    if self._running then
        warn("[TickService] Start() called but service is already running.")
        return
    end

    self._running = true

    self._connection = RunService.Heartbeat:Connect(function(deltaTime: number)
        self._elapsed += deltaTime

        for groupName, group in self._groups do
            group.accumulated += deltaTime

            if group.accumulated >= group.interval then
                -- Use the configured interval as canonical dt so handlers
                -- always receive a consistent value, even if a frame is late.
                local fireDt: number = group.interval

                -- Carry the remainder forward instead of discarding it,
                -- keeping long-running groups from drifting over time.
                group.accumulated -= group.interval
                group.tickCount   += 1

                for id, callback in group.callbacks do
                    local success, err = pcall(callback, fireDt)
                    if not success then
                        warn(string.format(
                            "[TickService] Error in callback '%s' (group '%s'): %s",
                            id, groupName, tostring(err)
                        ))
                    end
                end
            end
        end
    end)
end

--[[
    :Stop() -> ()

    Disconnects the Heartbeat listener. Does NOT reset elapsed time or tick
    counts, so calling Start() again resumes from the current state.
    Useful for pausing the simulation in tests or during a prestige reset.
--]]
function TickService:Stop()
    if not self._running then
        warn("[TickService] Stop() called but service is not running.")
        return
    end

    if self._connection then
        self._connection:Disconnect()
        self._connection = nil
    end

    self._running = false
end

--[[
    :RegisterGroup(groupName: string, interval: number) -> ()

    Creates a named tick group with its own accumulator and callback table.
    If a group with this name already exists, only the interval is updated
    (callbacks and tick counts are preserved).

    Groups are independent — each has its own fire cadence. This lets
    different services tick at different rates without any coordination.

        "Passive"  -> 1s   (CurrencyService passive income)
        "AutoSave" -> 30s  (SaveService background saves)
        "Prestige" -> 0.5s (PrestigeService animations, if needed)
--]]
function TickService:RegisterGroup(groupName: string, interval: number)
    assert(
        type(groupName) == "string" and #groupName > 0,
        "[TickService] RegisterGroup: groupName must be a non-empty string."
    )
    assert(
        type(interval) == "number" and interval > 0,
        "[TickService] RegisterGroup: interval must be a positive number."
    )

    local clampedInterval = math.max(interval, Config.MIN_TICK_INTERVAL)

    if self._groups[groupName] then
        -- Only update the interval; leave callbacks and counters untouched.
        self._groups[groupName].interval = clampedInterval
        return
    end

    self._groups[groupName] = {
        interval    = clampedInterval,
        accumulated = 0,
        tickCount   = 0,
        callbacks   = {},
    }
end

--[[
    :Bind(groupName: string, id: string, callback: TickCallback) -> ()

    Attaches a callback to a named tick group. The callback signature is:

        callback(deltaTime: number) -> ()

    where deltaTime == the group's configured interval (not the raw frame dt).

    Prefer this over direct RunService.Heartbeat connections so all passive
    income logic runs through a single loop with shared error isolation.
--]]
function TickService:Bind(groupName: string, id: string, callback: TickCallback)
    assert(
        self._groups[groupName],
        string.format(
            "[TickService] Bind: group '%s' does not exist. Call RegisterGroup first.",
            groupName
        )
    )
    assert(
        type(id) == "string" and #id > 0,
        "[TickService] Bind: id must be a non-empty string."
    )
    assert(
        type(callback) == "function",
        "[TickService] Bind: callback must be a function."
    )

    if self._groups[groupName].callbacks[id] then
        warn(string.format(
            "[TickService] Bind: overwriting existing callback '%s' in group '%s'.",
            id, groupName
        ))
    end

    self._groups[groupName].callbacks[id] = callback
end

--[[
    :Unbind(groupName: string, id: string) -> ()

    Removes a callback from a tick group. Safe to call even if the id has
    already been removed or was never registered (warns, does not error).
--]]
function TickService:Unbind(groupName: string, id: string)
    if not self._groups[groupName] then
        warn(string.format("[TickService] Unbind: group '%s' does not exist.", groupName))
        return
    end

    if not self._groups[groupName].callbacks[id] then
        warn(string.format(
            "[TickService] Unbind: callback '%s' not found in group '%s'.",
            id, groupName
        ))
        return
    end

    self._groups[groupName].callbacks[id] = nil
end

--[[
    :GetElapsed() -> number

    Returns total seconds since Start() was called. Pauses while the service
    is stopped (i.e. reflects only "simulated time", not wall-clock time).
    Use this for time-gated features like daily rewards.
--]]
function TickService:GetElapsed(): number
    return self._elapsed
end

--[[
    :GetTick(groupName: string) -> number

    Returns the cumulative fire count for a group since Start().
    Useful for "every N ticks" logic without tracking state in the caller:

        if TickService:GetTick("Passive") % 60 == 0 then
            -- Run once per minute (assuming 1s Passive interval)
        end
--]]
function TickService:GetTick(groupName: string): number
    assert(
        self._groups[groupName],
        string.format("[TickService] GetTick: group '%s' does not exist.", groupName)
    )
    return self._groups[groupName].tickCount
end

--------------------------------------------------------------------------------

return TickService
