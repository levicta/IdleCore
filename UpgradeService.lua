--[[
================================================================================
  UpgradeService
  Location: ServerStorage/Framework/UpgradeService.lua

  Manages upgrade definitions, level tracking, cost scaling, and effect
  application for the Incremental Game Framework. All purchases are
  server-authoritative and atomic: afford-check → deduct → increment → fire
  effects happen in one uninterruptible block with no intermediate state exposed.

  Integrates with:
    • CurrencyService — Subtract for purchase cost, SetMultiplier/Add for effects
    • SaveService     — Serialize/Deserialize player upgrade levels
    • UIService       — UpgradePurchased RemoteEvent, UpgradesSync on join

  ── API ──────────────────────────────────────────────────────────────────────

  UpgradeService.new(currencyService: CurrencyService) -> UpgradeService
      Constructs the service and wires up Remotes.

  UpgradeService:LoadPlayer(player: Player, savedData: PlayerUpgradeData?) -> ()
      Initialises a player's upgrade levels and syncs them to the client.
      Must be called before any other per-player method.

  UpgradeService:UnloadPlayer(player: Player) -> ()
      Removes the player's in-memory state. Call on PlayerRemoving.

  UpgradeService:GetLevel(player: Player, upgradeId: string) -> number
      Returns the player's current level for an upgrade (0 = not purchased).

  UpgradeService:CanAfford(player: Player, upgradeId: string) -> boolean
      Returns true if the player has enough currency for the next level.

  UpgradeService:GetCostForLevel(upgradeId: string, level: number) -> number
      Returns the cost to purchase the given level (level ≥ 1).
      Uses: floor(baseCost × costScaling ^ (level - 1))

  UpgradeService:GetEffect(upgradeId: string, level: number) -> number
      Returns the effect magnitude at a given level.
      Uses: effectValue + effectScaling × (level - 1)

  UpgradeService:Purchase(player: Player, upgradeId: string)
      -> (success: boolean, reason: string, newLevel: number)
      Atomically purchases one level. Validates: known id, prerequisites met,
      level cap, can afford. Deducts currency, increments level, fires effects
      and events. Returns a result triple so callers always know why it failed.

  UpgradeService:ApplyEffects(player: Player) -> ()
      Re-applies all purchased upgrades to CurrencyService from scratch.
      Call after a prestige reset when multipliers are wiped.

  UpgradeService:OnEffectApplied(callback: EffectCallback) -> () -> ()
      Registers a callback fired whenever an upgrade effect is applied.
      Returns an unsubscribe function. Signature:
          callback(player, upgradeId, effectType, value, currencyId?)

  UpgradeService:Serialize(player: Player) -> PlayerUpgradeData
      Returns { [upgradeId]: level } snapshot for SaveService.

  UpgradeService:Deserialize(player: Player, data: PlayerUpgradeData) -> ()
      Restores upgrade levels from a SaveService snapshot without firing effects
      (call ApplyEffects separately after deserialising to reattach multipliers).

  UpgradeService:Destroy() -> ()
      Clears remote handlers and all state.

  ── Events ───────────────────────────────────────────────────────────────────

  UpgradeService.Purchased : BindableEvent
      Fired server-side after every successful purchase.
      Args: (player: Player, upgradeId: string, newLevel: number)
      Use for achievements, analytics, unlock checks, etc.

  ── Example Usage ────────────────────────────────────────────────────────────

  -- ServerMain.lua
  local UpgradeService  = require(ServerStorage.Framework.UpgradeService)
  local CurrencyService = require(ServerStorage.Framework.CurrencyService)

  local upgrades = UpgradeService.new(currencyService)

  -- Wire effects → CurrencyService
  upgrades:OnEffectApplied(function(player, upgradeId, effectType, value, currencyId)
      local ET = UpgradeConfig.EffectTypes
      if effectType == ET.PassiveMultiplier and currencyId then
          CurrencyService:SetMultiplier(player, value)
      elseif effectType == ET.PassiveFlat and currencyId then
          -- Flat bonuses are re-evaluated by CurrencyService each tick via
          -- GetEffect — no persistent call needed here; included for completeness.
      end
  end)

  Players.PlayerAdded:Connect(function(player)
      upgrades:LoadPlayer(player, SaveService:Load(player))
  end)

  Players.PlayerRemoving:Connect(function(player)
      SaveService:Save(player, upgrades:Serialize(player))
      upgrades:UnloadPlayer(player)
  end)

  -- Manually award an upgrade level (e.g. admin command):
  local ok, reason, level = upgrades:Purchase(player, "GoldMine")
  print(ok, reason, level) --> true  "OK"  1

================================================================================
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──────────────────────────────────────────────────────────────

local UpgradeConfig  = require(ReplicatedStorage.Shared.Config.UpgradeConfig)
local UpgradeRemotes = require(ReplicatedStorage.Shared.Remotes.UpgradeRemotes)

-- ── Types ─────────────────────────────────────────────────────────────────────

-- Minimal surface of CurrencyService needed here (avoids circular requires)
export type CurrencyServiceRef = {
    Get:      (self: any, player: Player, currencyId: string) -> number,
    Subtract: (self: any, player: Player, currencyId: string, amount: number) -> (boolean, number),
    SetMultiplier: (self: any, player: Player, multiplier: number) -> (),
}

-- { upgradeId → currentLevel }  (0 = never purchased)
type LevelMap = { [string]: number }

-- Per-player runtime state
type PlayerState = {
    levels: LevelMap,
    -- Guard against duplicate in-flight RequestPurchase calls from the same client
    purchasing: { [string]: boolean },
}

-- Shape written to / read from SaveService
export type PlayerUpgradeData = { [string]: number }

-- Effect callback signature
export type EffectCallback = (
    player:     Player,
    upgradeId:  string,
    effectType: string,
    value:      number,
    currencyId: string?
) -> ()

export type UpgradeService = {
    -- Public
    LoadPlayer:      (self: UpgradeService, player: Player, data: PlayerUpgradeData?) -> (),
    UnloadPlayer:    (self: UpgradeService, player: Player) -> (),
    GetLevel:        (self: UpgradeService, player: Player, upgradeId: string) -> number,
    CanAfford:       (self: UpgradeService, player: Player, upgradeId: string) -> boolean,
    GetCostForLevel: (self: UpgradeService, upgradeId: string, level: number) -> number,
    GetEffect:       (self: UpgradeService, upgradeId: string, level: number) -> number,
    Purchase:        (self: UpgradeService, player: Player, upgradeId: string) -> (boolean, string, number),
    ApplyEffects:    (self: UpgradeService, player: Player) -> (),
    OnEffectApplied: (self: UpgradeService, cb: EffectCallback) -> () -> (),
    Serialize:       (self: UpgradeService, player: Player) -> PlayerUpgradeData,
    Deserialize:     (self: UpgradeService, player: Player, data: PlayerUpgradeData) -> (),
    Destroy:         (self: UpgradeService) -> (),
    -- Public event
    Purchased: BindableEvent,
    -- Private
    _currency:         CurrencyServiceRef,
    _states:           { [number]: PlayerState },
    _effectCallbacks:  { [string]: EffectCallback },
    _callbackIdCounter: number,
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function getDef(upgradeId: string): UpgradeConfig.UpgradeDefinition
    local def = UpgradeConfig.Map[upgradeId]
    assert(def, string.format("[UpgradeService] Unknown upgrade id: '%s'", upgradeId))
    return def
end

--[[
    Cost formula: floor(baseCost × costScaling ^ (level - 1))
    level is the level being purchased (1-indexed).
--]]
local function calcCost(def: UpgradeConfig.UpgradeDefinition, level: number): number
    return math.floor(def.cost.amount * (def.costScaling ^ (level - 1)))
end

--[[
    Effect formula: effectValue + effectScaling × (level - 1)
    level is the level already owned (1-indexed).
--]]
local function calcEffect(def: UpgradeConfig.UpgradeDefinition, level: number): number
    return def.effectValue + def.effectScaling * (level - 1)
end

-- ── Class ─────────────────────────────────────────────────────────────────────

local UpgradeService = {}
UpgradeService.__index = UpgradeService

function UpgradeService.new(currencyService: CurrencyServiceRef): UpgradeService
    assert(currencyService,                                 "[UpgradeService] currencyService is required")
    assert(type(currencyService.Subtract) == "function",    "[UpgradeService] Invalid CurrencyService")

    local purchasedEvent = Instance.new("BindableEvent")

    local self = setmetatable({
        Purchased          = purchasedEvent,
        _currency          = currencyService,
        _states            = {} :: { [number]: PlayerState },
        _effectCallbacks   = {} :: { [string]: EffectCallback },
        _callbackIdCounter = 0,
    }, UpgradeService)

    self:_bindRemotes()
    return self :: any
end

-- ── Private Helpers ───────────────────────────────────────────────────────────

function UpgradeService:_requireState(player: Player): PlayerState
    local state = self._states[player.UserId]
    assert(state, string.format(
        "[UpgradeService] Player '%s' not loaded. Call LoadPlayer first.", player.Name))
    return state
end

--[[
    Fires all registered OnEffectApplied callbacks.
    Does NOT mutate CurrencyService — callers listen and do that themselves,
    keeping UpgradeService decoupled from specific effect implementations.
--]]
function UpgradeService:_fireEffectCallbacks(
    player:    Player,
    upgradeId: string,
    level:     number
)
    local def    = getDef(upgradeId)
    local value  = calcEffect(def, level)

    for _, cb in self._effectCallbacks do
        local ok, err = pcall(cb, player, upgradeId, def.effectType, value, def.currencyId)
        if not ok then
            warn(string.format("[UpgradeService] OnEffectApplied callback error: %s", tostring(err)))
        end
    end
end

--[[
    Checks that all prerequisite upgrades are at level ≥ 1.
    Returns (met: boolean, reason: string).
--]]
function UpgradeService:_checkPrerequisites(player: Player, def: UpgradeConfig.UpgradeDefinition): (boolean, string)
    if not def.prerequisites then return true, "OK" end
    local state = self:_requireState(player)
    for _, prereqId in def.prerequisites do
        local lvl = state.levels[prereqId] or 0
        if lvl < 1 then
            local prereqDef = UpgradeConfig.Map[prereqId]
            local prereqName = prereqDef and prereqDef.name or prereqId
            return false, string.format("Requires '%s' first", prereqName)
        end
    end
    return true, "OK"
end

-- ── Private: Remote Binding ───────────────────────────────────────────────────

function UpgradeService:_bindRemotes()

    -- RequestPurchase: client asks to buy one level
    -- Validated: type safety, known id, prerequisites, level cap, can afford.
    -- A per-upgrade purchasing flag prevents the same client from double-firing
    -- the remote before the first invocation returns.
    UpgradeRemotes.RequestPurchase.OnServerInvoke = function(
        player:    Player,
        upgradeId: unknown
    ): (boolean, string, number)

        -- Type guard
        if type(upgradeId) ~= "string" then
            warn(string.format("[UpgradeService] RequestPurchase: bad upgradeId from %s", player.Name))
            return false, "Invalid request", 0
        end

        -- Known upgrade?
        if not UpgradeConfig.Map[upgradeId :: string] then
            warn(string.format("[UpgradeService] RequestPurchase: unknown id '%s' from %s", upgradeId, player.Name))
            return false, "Unknown upgrade", 0
        end

        -- Player loaded?
        local state = self._states[player.UserId]
        if not state then
            return false, "Player not loaded", 0
        end

        -- Duplicate in-flight guard
        local id = upgradeId :: string
        if state.purchasing[id] then
            return false, "Request already in progress", state.levels[id] or 0
        end

        state.purchasing[id] = true
        local ok, reason, newLevel = self:Purchase(player, id)
        state.purchasing[id] = false

        return ok, reason, newLevel
    end

    -- GetUpgradeLevel: client polls a single level (used for UI initialisation)
    UpgradeRemotes.GetUpgradeLevel.OnServerInvoke = function(
        player:    Player,
        upgradeId: unknown
    ): number
        if type(upgradeId) ~= "string" then return 0 end
        if not UpgradeConfig.Map[upgradeId :: string] then return 0 end
        local state = self._states[player.UserId]
        if not state then return 0 end
        return state.levels[upgradeId :: string] or 0
    end

end

-- ── Public Methods ────────────────────────────────────────────────────────────

--[[
    Initialises a player's upgrade state and syncs current levels to their client.
    @param player    Player
    @param savedData PlayerUpgradeData? — nil for brand-new players (all levels → 0)
--]]
function UpgradeService:LoadPlayer(player: Player, savedData: PlayerUpgradeData?)
    assert(not self._states[player.UserId], string.format(
        "[UpgradeService] LoadPlayer: '%s' already loaded", player.Name))

    local levels: LevelMap = {}

    -- Seed every upgrade at 0
    for _, def in UpgradeConfig.Upgrades do
        levels[def.id] = 0
    end

    -- Restore saved levels, clamping to maxLevel in case Config changed
    if savedData then
        for id, level in savedData do
            local def = UpgradeConfig.Map[id]
            if def then
                local cap = def.maxLevel > 0 and def.maxLevel or math.huge
                levels[id] = math.clamp(level, 0, cap)
            end
        end
    end

    self._states[player.UserId] = {
        levels    = levels,
        purchasing = {},
    }

    -- Bulk-sync the full level map to the client (avoids N round-trips)
    UpgradeRemotes.UpgradesSync:FireClient(player, table.clone(levels))
end

--[[
    Removes the player's in-memory state. Call on PlayerRemoving.
--]]
function UpgradeService:UnloadPlayer(player: Player)
    self._states[player.UserId] = nil
end

--[[
    Returns the player's current level for an upgrade. 0 = not yet purchased.
--]]
function UpgradeService:GetLevel(player: Player, upgradeId: string): number
    getDef(upgradeId)
    local state = self:_requireState(player)
    return state.levels[upgradeId] or 0
end

--[[
    Returns the cost to reach a specific level (1-indexed, level ≥ 1).
    e.g. GetCostForLevel("GoldMine", 1) → 100  (base cost)
         GetCostForLevel("GoldMine", 2) → 150  (100 × 1.5^1)
--]]
function UpgradeService:GetCostForLevel(upgradeId: string, level: number): number
    assert(type(level) == "number" and level >= 1,
        "[UpgradeService] GetCostForLevel: level must be ≥ 1")
    return calcCost(getDef(upgradeId), level)
end

--[[
    Returns the effect magnitude at a given owned level (1-indexed).
    e.g. GetEffect("GoldMine", 1) → 1   (base flat income)
         GetEffect("GoldMine", 3) → 3   (1 + 1×2)
--]]
function UpgradeService:GetEffect(upgradeId: string, level: number): number
    assert(type(level) == "number" and level >= 1,
        "[UpgradeService] GetEffect: level must be ≥ 1")
    return calcEffect(getDef(upgradeId), level)
end

--[[
    Returns true if the player has enough currency for the NEXT level purchase.
--]]
function UpgradeService:CanAfford(player: Player, upgradeId: string): boolean
    local def   = getDef(upgradeId)
    local state = self:_requireState(player)
    local nextLvl = (state.levels[upgradeId] or 0) + 1

    -- Already at cap?
    if def.maxLevel > 0 and nextLvl > def.maxLevel then
        return false
    end

    local cost    = calcCost(def, nextLvl)
    local balance = self._currency:Get(player, def.cost.currencyId)
    return balance >= cost
end

--[[
    Atomically purchases one level of an upgrade.
    Steps (all or nothing):
      1. Validate: known id, player loaded, prerequisites, level cap
      2. Compute next level cost
      3. Subtract from CurrencyService (may fail if balance changed concurrently)
      4. Increment level
      5. Fire effect callbacks → OnEffectApplied listeners update CurrencyService
      6. Fire BindableEvent (Purchased) and RemoteEvent (UpgradePurchased)

    @return (success: boolean, reason: string, newLevel: number)
            On failure, newLevel is the CURRENT level (unchanged).
--]]
function UpgradeService:Purchase(player: Player, upgradeId: string): (boolean, string, number)
    local def = UpgradeConfig.Map[upgradeId]
    if not def then
        return false, "Unknown upgrade", 0
    end

    local state = self._states[player.UserId]
    if not state then
        return false, "Player not loaded", 0
    end

    local currentLevel = state.levels[upgradeId] or 0
    local nextLevel    = currentLevel + 1

    -- ── Level cap check ────────────────────────────────────────────────────
    if def.maxLevel > 0 and nextLevel > def.maxLevel then
        return false, string.format("Already at max level (%d)", def.maxLevel), currentLevel
    end

    -- ── Prerequisites ──────────────────────────────────────────────────────
    local prereqMet, prereqReason = self:_checkPrerequisites(player, def)
    if not prereqMet then
        return false, prereqReason, currentLevel
    end

    -- ── Cost computation & currency deduction ──────────────────────────────
    local cost         = calcCost(def, nextLevel)
    local paid, newBal = self._currency:Subtract(player, def.cost.currencyId, cost)
    if not paid then
        return false, string.format(
            "Insufficient %s (need %d, have %d)",
            def.cost.currencyId, cost, newBal + cost
        ), currentLevel
    end

    -- ── Commit: increment level ────────────────────────────────────────────
    state.levels[upgradeId] = nextLevel

    -- ── Fire effect callbacks ──────────────────────────────────────────────
    -- Callbacks are responsible for calling CurrencyService:SetMultiplier etc.
    -- UpgradeService itself stays decoupled from specific effect implementations.
    self:_fireEffectCallbacks(player, upgradeId, nextLevel)

    -- ── Compute next-level cost for UI (or -1 if now maxed) ───────────────
    local nextCost: number
    if def.maxLevel > 0 and nextLevel >= def.maxLevel then
        nextCost = -1 -- signal to UI that the upgrade is maxed
    else
        nextCost = calcCost(def, nextLevel + 1)
    end

    -- ── Events ────────────────────────────────────────────────────────────
    self.Purchased:Fire(player, upgradeId, nextLevel)
    UpgradeRemotes.UpgradePurchased:FireClient(player, upgradeId, nextLevel, nextCost)

    return true, "OK", nextLevel
end

--[[
    Re-applies all effects for every upgrade the player owns.
    Call this after a prestige reset — multipliers/flats are wiped and need
    to be reconstructed from the player's current upgrade levels.
--]]
function UpgradeService:ApplyEffects(player: Player)
    local state = self:_requireState(player)
    for upgradeId, level in state.levels do
        if level > 0 then
            self:_fireEffectCallbacks(player, upgradeId, level)
        end
    end
end

--[[
    Registers a callback fired on every effect application (purchase or re-apply).
    Returns an unsubscribe function — store it to clean up later.

    @param callback EffectCallback
    @return () -> ()  — call to remove the subscription

    Example:
        local unsub = upgrades:OnEffectApplied(function(player, id, effectType, value, currencyId)
            if effectType == EffectTypes.PassiveMultiplier then
                CurrencyService:SetMultiplier(player, value)
            end
        end)
        -- later:
        unsub()
--]]
function UpgradeService:OnEffectApplied(callback: EffectCallback): () -> ()
    assert(type(callback) == "function", "[UpgradeService] OnEffectApplied: callback must be a function")

    self._callbackIdCounter += 1
    local id = tostring(self._callbackIdCounter)
    self._effectCallbacks[id] = callback

    -- Return unsubscribe closure
    return function()
        self._effectCallbacks[id] = nil
    end
end

--[[
    Serialises the player's upgrade levels for SaveService.
    Returns a shallow copy so post-serialisation mutations don't corrupt the snapshot.
--]]
function UpgradeService:Serialize(player: Player): PlayerUpgradeData
    local state = self:_requireState(player)
    return table.clone(state.levels)
end

--[[
    Restores upgrade levels from a SaveService snapshot WITHOUT firing effects.
    After calling this, invoke ApplyEffects to reattach multipliers etc.
    (Separating restore from apply-effects makes the call order explicit in ServerMain.)
--]]
function UpgradeService:Deserialize(player: Player, data: PlayerUpgradeData)
    local state = self:_requireState(player)
    for id, level in data do
        local def = UpgradeConfig.Map[id]
        if not def then
            warn(string.format("[UpgradeService] Deserialize: unknown upgrade '%s' — skipping", id))
            continue
        end
        local cap = def.maxLevel > 0 and def.maxLevel or math.huge
        state.levels[id] = math.clamp(level, 0, cap)
    end
    -- Re-sync client after restore
    UpgradeRemotes.UpgradesSync:FireClient(player, table.clone(state.levels))
end

--[[
    Stops the service and clears all state. Call during framework teardown.
--]]
function UpgradeService:Destroy()
    UpgradeRemotes.RequestPurchase.OnServerInvoke = nil :: any
    UpgradeRemotes.GetUpgradeLevel.OnServerInvoke = nil :: any
    table.clear(self._effectCallbacks)
    table.clear(self._states)
    self.Purchased:Destroy()
end

-- ── Return ────────────────────────────────────────────────────────────────────

return UpgradeService
