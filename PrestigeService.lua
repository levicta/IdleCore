--[[
================================================================================
  PrestigeService
  Location: ServerStorage/Framework/PrestigeService.lua

  Handles the prestige lifecycle: validation, point calculation, reset
  orchestration via callbacks, multiplier tracking, and persistence.

  Integrates with:
    • CurrencyService — reads Gold balance, awards PrestigePoints, SetMultiplier
    • UpgradeService  — UnloadPlayer/LoadPlayer/ApplyEffects during reset
    • SaveService     — Serialize/Deserialize prestige level
    • UIService       — PrestigeCompleted RemoteEvent, PrestigeSync on join

  PrestigeService does NOT directly mutate CurrencyService or UpgradeService
  state. Instead it fires OnPrestige callbacks that ServerMain wires up —
  keeping all three services decoupled from one another.

  TickService is intentionally NOT paused during prestige. The tick count is
  a continuous monotonic counter; prestige is a player-state event, not a
  simulation event.

  ── API ──────────────────────────────────────────────────────────────────────

  PrestigeService.new(currencyService: CurrencyServiceRef) -> PrestigeService
      Constructs the service and wires Remotes.

  PrestigeService:LoadPlayer(player: Player, savedData: PlayerPrestigeData?) -> ()
      Initialises prestige state and syncs level + multiplier to the client.
      Must be called before any other per-player method.

  PrestigeService:UnloadPlayer(player: Player) -> ()
      Removes in-memory state. Call on PlayerRemoving.

  PrestigeService:GetLevel(player: Player) -> number
      Returns the player's current prestige level (0 = never prestiged).

  PrestigeService:GetMultiplier(player: Player) -> number
      Returns the compounding passive income multiplier for the player's
      current prestige level: baseMultiplier + (multiplierPerLevel × level).

  PrestigeService:CalculatePointsEarned(player: Player) -> number
      Returns how many PrestigePoints would be earned if the player prestiged
      right now, without mutating any state. Used by GetPrestigeInfo and UI.

  PrestigeService:CanPrestige(player: Player) -> (boolean, string)
      Returns (canPrestige, reason). Checks: player loaded, minimum Gold,
      cost affordability. Never mutates state.

  PrestigeService:Prestige(player: Player)
      -> (success: boolean, reason: string, newLevel: number, pointsEarned: number)
      Atomically executes the full prestige lifecycle (see sequence below).

  PrestigeService:OnPrestige(callback: PrestigeCallback) -> () -> ()
      Registers a callback fired during the reset phase of Prestige().
      Returns an unsubscribe function.
      Callback signature: (player: Player, newLevel: number, carryOver: CarryOverSnapshot)

  PrestigeService:Serialize(player: Player) -> PlayerPrestigeData
      Returns { level: number } snapshot for SaveService.

  PrestigeService:Deserialize(player: Player, data: PlayerPrestigeData) -> ()
      Restores prestige level from snapshot and re-syncs client.

  PrestigeService:Destroy() -> ()
      Clears remote handlers and all state.

  ── Events ───────────────────────────────────────────────────────────────────

  PrestigeService.Prestiged : BindableEvent
      Fired server-side after a prestige completes.
      Args: (player: Player, newLevel: number, pointsEarned: number)

  ── Full Prestige Lifecycle Sequence ─────────────────────────────────────────

  CLIENT                         SERVER
  ──────                         ──────
  [Button click]
    RequestPrestige:InvokeServer()
                                 PrestigeService:Prestige(player)
                                 │
                                 ├─ [1] VALIDATE
                                 │     CanPrestige(player)
                                 │       ├─ player loaded?
                                 │       ├─ Gold ≥ minimumGoldRequired?
                                 │       └─ Gold ≥ costAmount?
                                 │     → fail fast with reason string
                                 │
                                 ├─ [2] SNAPSHOT carry-over balances
                                 │     Read CurrencyService for each id in
                                 │     carryOver.currencies BEFORE any reset.
                                 │     Read UpgradeService for each id in
                                 │     carryOver.upgrades BEFORE any reset.
                                 │     Stored in CarryOverSnapshot — passed to
                                 │     OnPrestige callbacks so they can restore.
                                 │
                                 ├─ [3] CALCULATE points earned
                                 │     floor(coeff × (Gold/scale)^exponent)
                                 │     Computed from live Gold BEFORE the wipe.
                                 │
                                 ├─ [4] FIRE OnPrestige callbacks
                                 │     ServerMain callback:
                                 │       UpgradeService:UnloadPlayer(player)
                                 │       CurrencyService:UnloadPlayer(player)
                                 │       CurrencyService:LoadPlayer(player, {
                                 │           carryOver currencies restored
                                 │       })
                                 │       UpgradeService:LoadPlayer(player, {
                                 │           carryOver upgrade levels restored
                                 │       })
                                 │       UpgradeService:ApplyEffects(player)
                                 │         └─► OnEffectApplied → SetMultiplier
                                 │
                                 ├─ [5] INCREMENT prestige level
                                 │     state.level += 1
                                 │
                                 ├─ [6] AWARD PrestigePoints
                                 │     CurrencyService:Add(player,
                                 │         "PrestigePoints", pointsEarned)
                                 │
                                 ├─ [7] APPLY new prestige multiplier
                                 │     CurrencyService:SetMultiplier(player,
                                 │         GetMultiplier(player))
                                 │
                                 ├─ [8] FIRE BindableEvent
                                 │     Prestiged:Fire(player, level, points)
                                 │
                                 └─ [9] NOTIFY client
                                       PrestigeCompleted:FireClient(
                                           player, newLevel, pointsEarned)

  InvokeServer returns:
    (true, "OK", newLevel, pointsEarned)
    or
    (false, reason, currentLevel, 0)

  [Client plays fanfare, refreshes UI]

  ── Example Usage ────────────────────────────────────────────────────────────

  -- ServerMain.lua
  local PrestigeService = require(ServerStorage.Framework.PrestigeService)
  local prestige = PrestigeService.new(currencyService)

  prestige:OnPrestige(function(player, newLevel, carryOver)
      -- Tear down old state
      upgrades:UnloadPlayer(player)
      currency:UnloadPlayer(player)

      -- Rebuild with carry-over data injected
      currency:LoadPlayer(player, carryOver.currencies)
      upgrades:LoadPlayer(player, carryOver.upgrades)

      -- Re-attach upgrade-based multipliers (e.g. GoldRush effect)
      upgrades:ApplyEffects(player)
  end)

  -- Query (e.g. for an admin command):
  local canDo, reason = prestige:CanPrestige(player)
  if canDo then
      local ok, msg, lvl, pts = prestige:Prestige(player)
      print(ok, msg, lvl, pts)
  end

================================================================================
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──────────────────────────────────────────────────────────────

local PrestigeConfig  = require(ReplicatedStorage.Shared.Config.PrestigeConfig)
local PrestigeRemotes = require(ReplicatedStorage.Shared.Remotes.PrestigeRemotes)

-- ── Types ─────────────────────────────────────────────────────────────────────

-- Minimal CurrencyService surface (avoids circular require)
export type CurrencyServiceRef = {
    Get:          (self: any, player: Player, currencyId: string) -> number,
    Add:          (self: any, player: Player, currencyId: string, amount: number) -> number,
    SetMultiplier:(self: any, player: Player, multiplier: number) -> (),
}

-- Snapshot of values to carry through the reset, built BEFORE any wipe occurs.
-- Passed to OnPrestige callbacks so they can restore exactly what was saved.
export type CarryOverSnapshot = {
    -- { currencyId → amount } for currencies in carryOver.currencies
    currencies: { [string]: number },
    -- { upgradeId → level }  for upgrades in carryOver.upgrades
    upgrades:   { [string]: number },
}

-- Prestige callback: receives the player, their new (post-increment) level,
-- and the carry-over snapshot built before the reset.
export type PrestigeCallback = (
    player:    Player,
    newLevel:  number,
    carryOver: CarryOverSnapshot
) -> ()

-- Per-player runtime state
type PlayerState = {
    level:       number,  -- current prestige level (0 = never)
    prestiging:  boolean, -- in-flight guard (mirrors UpgradeService purchasing pattern)
}

-- Serialised form written to / read from SaveService
export type PlayerPrestigeData = {
    level: number,
}

export type PrestigeService = {
    -- Public
    LoadPlayer:             (self: PrestigeService, player: Player, data: PlayerPrestigeData?) -> (),
    UnloadPlayer:           (self: PrestigeService, player: Player) -> (),
    GetLevel:               (self: PrestigeService, player: Player) -> number,
    GetMultiplier:          (self: PrestigeService, player: Player) -> number,
    CalculatePointsEarned:  (self: PrestigeService, player: Player) -> number,
    CanPrestige:            (self: PrestigeService, player: Player) -> (boolean, string),
    Prestige:               (self: PrestigeService, player: Player) -> (boolean, string, number, number),
    OnPrestige:             (self: PrestigeService, cb: PrestigeCallback) -> () -> (),
    Serialize:              (self: PrestigeService, player: Player) -> PlayerPrestigeData,
    Deserialize:            (self: PrestigeService, player: Player, data: PlayerPrestigeData) -> (),
    Destroy:                (self: PrestigeService) -> (),
    -- Public event
    Prestiged: BindableEvent,
    -- Private
    _currency:         CurrencyServiceRef,
    _states:           { [number]: PlayerState },
    _prestigeCallbacks: { [string]: PrestigeCallback },
    _callbackIdCounter: number,
}

-- ── Internal Helpers ──────────────────────────────────────────────────────────

--[[
    Applies the PointsFormula to a raw Gold amount.
    floor(coefficient × (gold / scale) ^ exponent)
    Returns at least 0 to guard against edge cases with very low Gold.
--]]
local function applyPointsFormula(gold: number): number
    local f      = PrestigeConfig.pointsFormula
    local scaled = gold / f.scale
    if scaled <= 0 then return 0 end
    return math.max(0, math.floor(f.coefficient * (scaled ^ f.exponent)))
end

--[[
    Applies the MultiplierFormula to a prestige level.
    baseMultiplier + (multiplierPerLevel × level)
--]]
local function applyMultiplierFormula(level: number): number
    local f = PrestigeConfig.multiplierFormula
    return f.baseMultiplier + (f.multiplierPerLevel * level)
end

-- ── Class ─────────────────────────────────────────────────────────────────────

local PrestigeService = {}
PrestigeService.__index = PrestigeService

function PrestigeService.new(currencyService: CurrencyServiceRef): PrestigeService
    assert(currencyService,                              "[PrestigeService] currencyService is required")
    assert(type(currencyService.Get) == "function",      "[PrestigeService] Invalid CurrencyService")
    assert(type(currencyService.Add) == "function",      "[PrestigeService] Invalid CurrencyService")
    assert(type(currencyService.SetMultiplier) == "function", "[PrestigeService] Invalid CurrencyService")

    local prestigedEvent = Instance.new("BindableEvent")

    local self = setmetatable({
        Prestiged           = prestigedEvent,
        _currency           = currencyService,
        _states             = {} :: { [number]: PlayerState },
        _prestigeCallbacks  = {} :: { [string]: PrestigeCallback },
        _callbackIdCounter  = 0,
    }, PrestigeService)

    self:_bindRemotes()
    return self :: any
end

-- ── Private Helpers ───────────────────────────────────────────────────────────

function PrestigeService:_requireState(player: Player): PlayerState
    local state = self._states[player.UserId]
    assert(state, string.format(
        "[PrestigeService] Player '%s' not loaded. Call LoadPlayer first.", player.Name))
    return state
end

--[[
    Builds the CarryOverSnapshot by reading live values from CurrencyService
    BEFORE the reset occurs. This is called as the very first step of the
    commit phase so the snapshot reflects pre-wipe state.

    The snapshot is then handed to OnPrestige callbacks, which call
    CurrencyService:LoadPlayer(player, carryOver.currencies) to restore them.
--]]
function PrestigeService:_buildCarryOverSnapshot(player: Player): CarryOverSnapshot
    local snap: CarryOverSnapshot = {
        currencies = {},
        upgrades   = {},
    }

    -- Snapshot carry-over currencies from live CurrencyService state.
    -- We read here; callbacks are responsible for restoring via LoadPlayer.
    for _, currencyId in PrestigeConfig.carryOver.currencies do
        snap.currencies[currencyId] = self._currency:Get(player, currencyId)
    end

    -- Upgrade levels cannot be read here without an UpgradeServiceRef —
    -- PrestigeService is intentionally decoupled from UpgradeService.
    -- The OnPrestige callback in ServerMain is responsible for reading and
    -- preserving upgrade carry-overs before calling UnloadPlayer.
    -- We expose the upgrades table so callbacks can populate it themselves
    -- before the reset if needed, but we do not populate it here.
    -- (See OnPrestige wiring example in the API header above.)

    return snap
end

-- ── Private: Remote Binding ───────────────────────────────────────────────────

function PrestigeService:_bindRemotes()

    -- RequestPrestige: client asks to prestige; sends no arguments (nothing to trust)
    PrestigeRemotes.RequestPrestige.OnServerInvoke = function(
        player: Player
    ): (boolean, string, number, number)

        local state = self._states[player.UserId]
        if not state then
            return false, "Player not loaded", 0, 0
        end

        -- In-flight duplicate guard
        if state.prestiging then
            return false, "Prestige already in progress", state.level, 0
        end

        state.prestiging = true
        local ok, reason, newLevel, pts = self:Prestige(player)
        state.prestiging = false

        return ok, reason, newLevel, pts
    end

    -- GetPrestigeInfo: client queries current state for tooltip / button display
    PrestigeRemotes.GetPrestigeInfo.OnServerInvoke = function(
        player: Player
    ): (number, number, number, boolean)

        local state = self._states[player.UserId]
        if not state then
            return 0, 1.0, 0, false
        end

        local level       = state.level
        local multiplier  = applyMultiplierFormula(level)
        local pointsIfNow = self:CalculatePointsEarned(player)
        local canDo, _    = self:CanPrestige(player)

        return level, multiplier, pointsIfNow, canDo
    end

end

-- ── Public Methods ────────────────────────────────────────────────────────────

--[[
    Initialises a player's prestige state and syncs to client.
    @param player    Player
    @param savedData PlayerPrestigeData? — nil for brand-new players
--]]
function PrestigeService:LoadPlayer(player: Player, savedData: PlayerPrestigeData?)
    assert(not self._states[player.UserId], string.format(
        "[PrestigeService] LoadPlayer: '%s' already loaded", player.Name))

    local level = 0
    if savedData and type(savedData.level) == "number" then
        level = math.max(0, math.floor(savedData.level))
    end

    self._states[player.UserId] = {
        level      = level,
        prestiging = false,
    }

    -- Push level + current multiplier to client for immediate UI display
    local multiplier = applyMultiplierFormula(level)
    PrestigeRemotes.PrestigeSync:FireClient(player, level, multiplier)
end

--[[
    Removes the player's in-memory state. Call on PlayerRemoving.
--]]
function PrestigeService:UnloadPlayer(player: Player)
    self._states[player.UserId] = nil
end

--[[
    Returns the player's current prestige level.
--]]
function PrestigeService:GetLevel(player: Player): number
    return self:_requireState(player).level
end

--[[
    Returns the passive income multiplier for the player's current prestige level.
    Formula: baseMultiplier + (multiplierPerLevel × level)
    CurrencyService:SetMultiplier is called with this value at the end of Prestige().
--]]
function PrestigeService:GetMultiplier(player: Player): number
    local state = self:_requireState(player)
    return applyMultiplierFormula(state.level)
end

--[[
    Calculates how many PrestigePoints the player would earn right now.
    Pure read — no state mutation. Safe to call from UI polling.
    Formula: floor(coefficient × (Gold / scale) ^ exponent)
--]]
function PrestigeService:CalculatePointsEarned(player: Player): number
    local gold = self._currency:Get(player, PrestigeConfig.costCurrencyId)
    return applyPointsFormula(gold)
end

--[[
    Checks whether the player is eligible to prestige.
    @return (canPrestige: boolean, reason: string)
    Does NOT mutate any state.
--]]
function PrestigeService:CanPrestige(player: Player): (boolean, string)
    local state = self._states[player.UserId]
    if not state then
        return false, "Player not loaded"
    end

    local gold = self._currency:Get(player, PrestigeConfig.costCurrencyId)

    -- Minimum gold floor (separate from cost — tuning convenience)
    if gold < PrestigeConfig.minimumGoldRequired then
        return false, string.format(
            "Need at least %d Gold to prestige (have %d)",
            PrestigeConfig.minimumGoldRequired, gold
        )
    end

    -- Cost affordability
    if gold < PrestigeConfig.costAmount then
        return false, string.format(
            "Need %d Gold to prestige (have %d)",
            PrestigeConfig.costAmount, gold
        )
    end

    return true, "OK"
end

--[[
    Executes the full prestige lifecycle atomically.
    See the lifecycle sequence diagram in the header for the full step-by-step.

    Steps:
      [1] Validate via CanPrestige
      [2] Snapshot carry-over balances BEFORE any wipe
      [3] Calculate PrestigePoints earned from live Gold
      [4] Fire OnPrestige callbacks (ServerMain performs the actual reset)
      [5] Increment prestige level
      [6] Award PrestigePoints via CurrencyService:Add
      [7] Apply new prestige multiplier via CurrencyService:SetMultiplier
      [8] Fire Prestiged BindableEvent (for analytics, achievements, etc.)
      [9] Notify client via PrestigeCompleted RemoteEvent

    @return (success, reason, newLevel, pointsEarned)
--]]
function PrestigeService:Prestige(player: Player): (boolean, string, number, number)

    -- ── [1] Validate ──────────────────────────────────────────────────────
    local canDo, reason = self:CanPrestige(player)
    if not canDo then
        local state = self._states[player.UserId]
        return false, reason, state and state.level or 0, 0
    end

    local state = self._states[player.UserId] -- guaranteed non-nil after CanPrestige

    -- ── [2] Snapshot carry-over values BEFORE reset ───────────────────────
    -- OnPrestige callbacks receive this so they can restore carry-over
    -- currencies when calling CurrencyService:LoadPlayer.
    -- Upgrade carry-overs must be read by the ServerMain callback itself
    -- (before UnloadPlayer) since PrestigeService has no UpgradeService ref.
    local carryOver = self:_buildCarryOverSnapshot(player)

    -- ── [3] Calculate points from live Gold ───────────────────────────────
    local gold         = self._currency:Get(player, PrestigeConfig.costCurrencyId)
    local pointsEarned = applyPointsFormula(gold)

    -- ── [4] Fire OnPrestige callbacks (reset happens inside these) ────────
    -- Callbacks are responsible for:
    --   • Reading upgrade carry-over levels (before UnloadPlayer)
    --   • Calling UpgradeService:UnloadPlayer
    --   • Calling CurrencyService:UnloadPlayer
    --   • Calling CurrencyService:LoadPlayer with carryOver.currencies
    --   • Calling UpgradeService:LoadPlayer with carry-over upgrade data
    --   • Calling UpgradeService:ApplyEffects to re-attach upgrade multipliers
    for _, cb in self._prestigeCallbacks do
        local ok, err = pcall(cb, player, state.level + 1, carryOver)
        if not ok then
            warn(string.format("[PrestigeService] OnPrestige callback error: %s", tostring(err)))
            -- A failed callback means the reset may be in a partial state.
            -- We continue — aborting here would leave the player in limbo.
        end
    end

    -- ── [5] Increment prestige level ──────────────────────────────────────
    state.level += 1
    local newLevel = state.level

    -- ── [6] Award PrestigePoints ──────────────────────────────────────────
    -- CurrencyService:LoadPlayer was just called (in callbacks), so the
    -- player's wallet is live again and Add is safe.
    if pointsEarned > 0 then
        self._currency:Add(player, PrestigeConfig.rewardCurrencyId, pointsEarned)
    end

    -- ── [7] Apply prestige multiplier ─────────────────────────────────────
    -- This sets the base multiplier. UpgradeService:ApplyEffects (called in
    -- the callback) may have also set multipliers from owned upgrades — since
    -- SetMultiplier is additive to prestige in most games, the ServerMain
    -- callback can compose both by reading GetMultiplier here and layering
    -- the upgrade multiplier on top. For simplicity, we set the prestige
    -- multiplier last so it is the authoritative floor.
    self._currency:SetMultiplier(player, applyMultiplierFormula(newLevel))

    -- ── [8] Fire server-side BindableEvent ────────────────────────────────
    self.Prestiged:Fire(player, newLevel, pointsEarned)

    -- ── [9] Notify client ─────────────────────────────────────────────────
    PrestigeRemotes.PrestigeCompleted:FireClient(player, newLevel, pointsEarned)

    return true, "OK", newLevel, pointsEarned
end

--[[
    Registers a callback invoked during the reset phase of Prestige().
    The callback receives the player, their INCOMING (not yet committed) level,
    and the CarryOverSnapshot built before any wipe.

    The callback is responsible for orchestrating the actual state reset:
        UpgradeService:UnloadPlayer / LoadPlayer / ApplyEffects
        CurrencyService:UnloadPlayer / LoadPlayer

    Returns an unsubscribe function.

    @param callback PrestigeCallback
    @return () -> ()
--]]
function PrestigeService:OnPrestige(callback: PrestigeCallback): () -> ()
    assert(type(callback) == "function", "[PrestigeService] OnPrestige: callback must be a function")

    self._callbackIdCounter += 1
    local id = tostring(self._callbackIdCounter)
    self._prestigeCallbacks[id] = callback

    return function()
        self._prestigeCallbacks[id] = nil
    end
end

--[[
    Serialises prestige state for SaveService.
--]]
function PrestigeService:Serialize(player: Player): PlayerPrestigeData
    local state = self:_requireState(player)
    return { level = state.level }
end

--[[
    Restores prestige level from a SaveService snapshot and re-syncs the client.
    Does not apply the multiplier — call CurrencyService:SetMultiplier(player,
    GetMultiplier(player)) separately after all systems are loaded.
--]]
function PrestigeService:Deserialize(player: Player, data: PlayerPrestigeData)
    local state = self:_requireState(player)
    if type(data.level) == "number" then
        state.level = math.max(0, math.floor(data.level))
    end
    local multiplier = applyMultiplierFormula(state.level)
    PrestigeRemotes.PrestigeSync:FireClient(player, state.level, multiplier)
end

--[[
    Stops the service and clears all state.
--]]
function PrestigeService:Destroy()
    PrestigeRemotes.RequestPrestige.OnServerInvoke = nil :: any
    PrestigeRemotes.GetPrestigeInfo.OnServerInvoke = nil :: any
    table.clear(self._prestigeCallbacks)
    table.clear(self._states)
    self.Prestiged:Destroy()
end

-- ── Return ────────────────────────────────────────────────────────────────────

return PrestigeService
