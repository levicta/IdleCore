--[[
================================================================================
  CurrencyService
  Location: ServerStorage/Framework/CurrencyService.lua

  Server-authoritative currency management for the Incremental Game Framework.
  All balance mutations happen here; clients request changes via RemoteFunctions
  and receive updates via RemoteEvents. The client is never trusted for amounts.

  Integrates with:
    • TickService   — subscribe to drive ProcessPassiveIncome
    • SaveService   — call Serialize/Deserialize to persist balances
    • PrestigeService — call SetMultiplier to adjust passive rates

  ── API ──────────────────────────────────────────────────────────────────────

  CurrencyService.new(tickService: TickService) -> CurrencyService
      Constructs the service, wires TickService, and sets up Remotes.

  CurrencyService:LoadPlayer(player: Player, savedData: PlayerCurrencyData?) -> ()
      Initialises a player's wallets from SaveService data (or defaults).
      Must be called before any other per-player method.

  CurrencyService:UnloadPlayer(player: Player) -> ()
      Removes the player's in-memory wallet. Call on PlayerRemoving.

  CurrencyService:Get(player: Player, currencyId: string) -> number
      Returns the player's current balance for a currency.

  CurrencyService:Set(player: Player, currencyId: string, amount: number) -> number
      Directly sets a balance (clamped to [0, cap]). Returns new amount.

  CurrencyService:Add(player: Player, currencyId: string, amount: number) -> number
      Adds `amount` (must be ≥ 0). Returns new amount.

  CurrencyService:Subtract(player: Player, currencyId: string, amount: number)
      -> (success: boolean, newAmount: number)
      Deducts `amount` if the player can afford it. Returns success + new amount.

  CurrencyService:Cap(player: Player, currencyId: string) -> number
      Returns the configured cap for a currency (does not mutate state).

  CurrencyService:SetMultiplier(player: Player, multiplier: number) -> ()
      Overrides the passive income multiplier for one player (used by Prestige).

  CurrencyService:ProcessPassiveIncome(dt: number) -> ()
      Called every tick by TickService. Awards passive income to all players.

  CurrencyService:Serialize(player: Player) -> PlayerCurrencyData
      Returns a snapshot of the player's balances (for SaveService).

  CurrencyService:Deserialize(player: Player, data: PlayerCurrencyData) -> ()
      Restores balances from a SaveService snapshot.

  CurrencyService:Destroy() -> ()
      Unsubscribes from TickService and disconnects all Remotes.

  ── Events (BindableEvent) ────────────────────────────────────────────────────

  CurrencyService.Changed : BindableEvent
      Fired server-side after every balance mutation.
      Args: (player: Player, currencyId: string, newAmount: number, delta: number)
      Use this to react internally (e.g. UpgradeService checking unlock thresholds).

  ── Example Usage ────────────────────────────────────────────────────────────

  -- ServerMain.lua
  local TickService     = require(ServerStorage.Framework.TickService)
  local CurrencyService = require(ServerStorage.Framework.CurrencyService)

  local tick     = TickService.new({ tickRate = 1.0, autoStart = false })
  local currency = CurrencyService.new(tick)

  Players.PlayerAdded:Connect(function(player)
      -- SaveService will supply savedData; pass nil for new players
      currency:LoadPlayer(player, nil)
  end)

  Players.PlayerRemoving:Connect(function(player)
      local snapshot = currency:Serialize(player)
      SaveService:Save(player, snapshot)
      currency:UnloadPlayer(player)
  end)

  tick:Start()

  -- Award 500 Gold to a player from another system:
  currency:Add(player, "Gold", 500)

  -- Check if a player can afford an upgrade:
  local success, newBalance = currency:Subtract(player, "Gold", 200)
  if success then
      print("Bought upgrade! Gold remaining:", newBalance)
  end

  -- Listen server-side for any balance change:
  currency.Changed.Event:Connect(function(plr, id, amount, delta)
      print(plr.Name, id, "changed by", delta, "→ now", amount)
  end)

================================================================================
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

-- ── Dependencies ──────────────────────────────────────────────────────────────
-- Paths assume the standard framework folder layout described in FOLDER_STRUCTURE.md

local CurrencyConfig  = require(ReplicatedStorage.Shared.Config.CurrencyConfig)
local CurrencyRemotes = require(ReplicatedStorage.Shared.Remotes.CurrencyRemotes)

-- ── Types ─────────────────────────────────────────────────────────────────────

-- Re-export the TickService type so this file compiles standalone
export type TickServiceRef = {
    Subscribe: (self: any, id: string, cb: (dt: number) -> ()) -> (),
    Unsubscribe: (self: any, id: string) -> (),
}

-- Per-player runtime wallet: currencyId → balance
type Wallet = { [string]: number }

-- Per-player metadata stored alongside the wallet
type PlayerState = {
    wallet: Wallet,
    passiveMultiplier: number, -- default 1.0; overridden by PrestigeService
}

-- Serialised form written to / read from SaveService
export type PlayerCurrencyData = { [string]: number }

export type CurrencyService = {
    -- Public methods
    LoadPlayer:           (self: CurrencyService, player: Player, data: PlayerCurrencyData?) -> (),
    UnloadPlayer:         (self: CurrencyService, player: Player) -> (),
    Get:                  (self: CurrencyService, player: Player, currencyId: string) -> number,
    Set:                  (self: CurrencyService, player: Player, currencyId: string, amount: number) -> number,
    Add:                  (self: CurrencyService, player: Player, currencyId: string, amount: number) -> number,
    Subtract:             (self: CurrencyService, player: Player, currencyId: string, amount: number) -> (boolean, number),
    Cap:                  (self: CurrencyService, player: Player, currencyId: string) -> number,
    SetMultiplier:        (self: CurrencyService, player: Player, multiplier: number) -> (),
    ProcessPassiveIncome: (self: CurrencyService, dt: number) -> (),
    Serialize:            (self: CurrencyService, player: Player) -> PlayerCurrencyData,
    Deserialize:          (self: CurrencyService, player: Player, data: PlayerCurrencyData) -> (),
    Destroy:              (self: CurrencyService) -> (),
    -- Public event
    Changed: BindableEvent,
    -- Private
    _states: { [number]: PlayerState },      -- keyed by Player.UserId
    _tickService: TickServiceRef,
    _remoteConnections: { RBXScriptConnection },
}

-- ── Internal Helpers ──────────────────────────────────────────────────────────

-- Clamps a number to [0, cap], respecting math.huge caps
local function clamp(value: number, cap: number): number
    return math.max(0, math.min(value, cap))
end

-- Retrieves a validated CurrencyDefinition or errors loudly
local function getDef(currencyId: string): CurrencyConfig.CurrencyDefinition
    local def = CurrencyConfig.Map[currencyId]
    assert(def, string.format("[CurrencyService] Unknown currency id: '%s'", currencyId))
    return def
end

-- ── Class ─────────────────────────────────────────────────────────────────────

local CurrencyService = {}
CurrencyService.__index = CurrencyService

--[[
    Constructs and wires up the CurrencyService.
    @param tickService TickServiceRef — the game's TickService instance
    @return CurrencyService
--]]
function CurrencyService.new(tickService: TickServiceRef): CurrencyService
    assert(tickService,                           "[CurrencyService] tickService is required")
    assert(type(tickService.Subscribe) == "function", "[CurrencyService] Invalid TickService")

    local changedEvent = Instance.new("BindableEvent")

    local self = setmetatable({
        Changed             = changedEvent,
        _states             = {} :: { [number]: PlayerState },
        _tickService        = tickService,
        _remoteConnections  = {} :: { RBXScriptConnection },
    }, CurrencyService)

    -- Wire passive income into TickService
    tickService:Subscribe("CurrencyService", function(dt: number)
        self:ProcessPassiveIncome(dt)
    end)

    -- Set up server-side Remote handlers
    self:_bindRemotes()

    return self :: any
end

-- ── Private: Player State Access ──────────────────────────────────────────────

function CurrencyService:_requireState(player: Player): PlayerState
    local state = self._states[player.UserId]
    assert(
        state,
        string.format("[CurrencyService] Player '%s' is not loaded. Call LoadPlayer first.", player.Name)
    )
    return state
end

-- ── Private: Fire Changed event + RemoteEvent to client ───────────────────────

function CurrencyService:_notify(player: Player, currencyId: string, newAmount: number, delta: number)
    -- Notify other server-side systems via BindableEvent
    self.Changed:Fire(player, currencyId, newAmount, delta)

    -- Push update to this player's client
    CurrencyRemotes.CurrencyChanged:FireClient(player, currencyId, newAmount, delta)
end

-- ── Private: Remote Binding ───────────────────────────────────────────────────

function CurrencyService:_bindRemotes()

    -- GetCurrency: client requests its own balance
    -- The server validates the player identity via the implicit first argument.
    CurrencyRemotes.GetCurrency.OnServerInvoke = function(
        player: Player,
        currencyId: unknown
    ): number
        -- Validate arguments — never trust the client
        if type(currencyId) ~= "string" then
            warn(string.format("[CurrencyService] GetCurrency: invalid currencyId from %s", player.Name))
            return 0
        end
        if not CurrencyConfig.Map[currencyId :: string] then
            warn(string.format("[CurrencyService] GetCurrency: unknown currency '%s' from %s", currencyId, player.Name))
            return 0
        end
        if not self._states[player.UserId] then
            return 0
        end
        return self:Get(player, currencyId :: string)
    end

    -- RequestSpend: client asks to spend currency (e.g. buying an upgrade)
    -- Server validates amount > 0 and that the player can afford it.
    CurrencyRemotes.RequestSpend.OnServerInvoke = function(
        player: Player,
        currencyId: unknown,
        amount: unknown
    ): (boolean, number)
        -- Type guards
        if type(currencyId) ~= "string" or type(amount) ~= "number" then
            warn(string.format("[CurrencyService] RequestSpend: bad args from %s", player.Name))
            return false, 0
        end
        if not CurrencyConfig.Map[currencyId :: string] then
            warn(string.format("[CurrencyService] RequestSpend: unknown currency '%s' from %s", currencyId, player.Name))
            return false, 0
        end
        -- Reject negative or zero spend requests (exploit prevention)
        if (amount :: number) <= 0 then
            warn(string.format("[CurrencyService] RequestSpend: non-positive amount %.2f from %s", amount :: number, player.Name))
            return false, 0
        end
        if not self._states[player.UserId] then
            return false, 0
        end

        return self:Subtract(player, currencyId :: string, amount :: number)
    end

end

-- ── Public Methods ────────────────────────────────────────────────────────────

--[[
    Initialises a player's wallets. Call on PlayerAdded (after SaveService loads).
    @param player    Player
    @param savedData PlayerCurrencyData? — nil for brand-new players
--]]
function CurrencyService:LoadPlayer(player: Player, savedData: PlayerCurrencyData?)
    assert(not self._states[player.UserId],
        string.format("[CurrencyService] LoadPlayer: '%s' is already loaded", player.Name))

    local wallet: Wallet = {}

    -- Seed every defined currency with its startAmount
    for _, def in CurrencyConfig.Currencies do
        wallet[def.id] = def.startAmount
    end

    -- Overwrite with persisted balances if available, clamping to current caps
    if savedData then
        for id, amount in savedData do
            local def = CurrencyConfig.Map[id]
            if def then
                wallet[id] = clamp(amount, def.cap)
            end
        end
    end

    self._states[player.UserId] = {
        wallet            = wallet,
        passiveMultiplier = CurrencyConfig.BasePassiveMultiplier,
    }

    -- Push initial balances to the client so their UI starts correctly
    for id, amount in wallet do
        CurrencyRemotes.CurrencyChanged:FireClient(player, id, amount, 0)
    end
end

--[[
    Removes a player's in-memory state. Call on PlayerRemoving (after Serialize).
    @param player Player
--]]
function CurrencyService:UnloadPlayer(player: Player)
    self._states[player.UserId] = nil
end

--[[
    Returns the player's current balance for a currency.
    @param player     Player
    @param currencyId string
    @return number
--]]
function CurrencyService:Get(player: Player, currencyId: string): number
    getDef(currencyId) -- validates the id
    local state = self:_requireState(player)
    return state.wallet[currencyId] or 0
end

--[[
    Directly sets a player's balance, clamped to [0, cap].
    Prefer Add/Subtract for normal gameplay; use Set for debug or admin commands.
    @return number — the new clamped amount
--]]
function CurrencyService:Set(player: Player, currencyId: string, amount: number): number
    assert(type(amount) == "number", "[CurrencyService] Set: amount must be a number")
    local def   = getDef(currencyId)
    local state = self:_requireState(player)

    local prev          = state.wallet[currencyId] or 0
    local next          = clamp(amount, def.cap)
    state.wallet[currencyId] = next

    local delta = next - prev
    if delta ~= 0 then
        self:_notify(player, currencyId, next, delta)
    end
    return next
end

--[[
    Adds `amount` to a player's balance (floored at 0, capped at def.cap).
    @param amount number — must be ≥ 0
    @return number — new balance
--]]
function CurrencyService:Add(player: Player, currencyId: string, amount: number): number
    assert(type(amount) == "number" and amount >= 0,
        string.format("[CurrencyService] Add: amount must be ≥ 0, got %s", tostring(amount)))

    local def   = getDef(currencyId)
    local state = self:_requireState(player)

    local prev  = state.wallet[currencyId] or 0
    local next  = clamp(prev + amount, def.cap)
    state.wallet[currencyId] = next

    local delta = next - prev
    if delta ~= 0 then
        self:_notify(player, currencyId, next, delta)
    end
    return next
end

--[[
    Subtracts `amount` from a player's balance if they can afford it.
    @param amount number — must be > 0
    @return (success: boolean, newAmount: number)
            success = false means the player couldn't afford it; no mutation occurs.
--]]
function CurrencyService:Subtract(player: Player, currencyId: string, amount: number): (boolean, number)
    assert(type(amount) == "number" and amount > 0,
        string.format("[CurrencyService] Subtract: amount must be > 0, got %s", tostring(amount)))

    getDef(currencyId)
    local state = self:_requireState(player)

    local prev = state.wallet[currencyId] or 0
    if prev < amount then
        -- Can't afford — return false without mutating state
        return false, prev
    end

    local next = clamp(prev - amount, math.huge) -- cap irrelevant on subtract
    state.wallet[currencyId] = next

    self:_notify(player, currencyId, next, -amount)
    return true, next
end

--[[
    Returns the configured cap for a currency. Does not mutate state.
    @return number (may be math.huge for uncapped currencies)
--]]
function CurrencyService:Cap(_player: Player, currencyId: string): number
    return getDef(currencyId).cap
end

--[[
    Overrides the passive income multiplier for a single player.
    Called by PrestigeService when a player prestiges.
    @param multiplier number — e.g. 2.0 = double passive income
--]]
function CurrencyService:SetMultiplier(player: Player, multiplier: number)
    assert(type(multiplier) == "number" and multiplier >= 0,
        "[CurrencyService] SetMultiplier: multiplier must be a non-negative number")
    local state = self:_requireState(player)
    state.passiveMultiplier = multiplier
end

--[[
    Called every tick by TickService. Awards passive income to all loaded players
    based on each currency's passiveRate × the player's passiveMultiplier.
    `dt` is the real elapsed tick duration (seconds) — included for future
    variable-rate support, but currently passive income is per-tick not per-second.
    @param dt number — elapsed seconds since last tick
--]]
function CurrencyService:ProcessPassiveIncome(_dt: number)
    for userId, state in self._states do
        local player = Players:GetPlayerByUserId(userId)
        if not player then
            -- Player left between ticks; their state will be cleaned up on PlayerRemoving
            continue
        end

        for _, def in CurrencyConfig.Currencies do
            if def.passiveRate > 0 then
                local income = def.passiveRate * state.passiveMultiplier
                if income > 0 then
                    self:Add(player, def.id, income)
                end
            end
        end
    end
end

--[[
    Serialises the player's wallet into a plain table for SaveService.
    Call this before UnloadPlayer on PlayerRemoving.
    @return PlayerCurrencyData
--]]
function CurrencyService:Serialize(player: Player): PlayerCurrencyData
    local state = self:_requireState(player)
    -- Return a shallow copy so mutations after serialisation don't bleed through
    return table.clone(state.wallet)
end

--[[
    Restores a player's balances from a SaveService snapshot.
    Equivalent to calling LoadPlayer with savedData — provided separately so
    SaveService can deserialise after LoadPlayer if its async load finishes late.
    @param data PlayerCurrencyData
--]]
function CurrencyService:Deserialize(player: Player, data: PlayerCurrencyData)
    local state = self:_requireState(player)

    for id, amount in data do
        local def = CurrencyConfig.Map[id]
        if not def then
            warn(string.format("[CurrencyService] Deserialize: unknown currency '%s' — skipping", id))
            continue
        end
        local clamped = clamp(amount, def.cap)
        state.wallet[id] = clamped
        -- Notify client of restored balance
        CurrencyRemotes.CurrencyChanged:FireClient(player, id, clamped, 0)
    end
end

--[[
    Stops processing and cleans up all connections.
    Call on game:BindToClose or during a full framework teardown.
--]]
function CurrencyService:Destroy()
    self._tickService:Unsubscribe("CurrencyService")

    -- Clear Remote handlers so GC can collect
    CurrencyRemotes.GetCurrency.OnServerInvoke  = nil :: any
    CurrencyRemotes.RequestSpend.OnServerInvoke = nil :: any

    for _, conn in self._remoteConnections do
        conn:Disconnect()
    end

    self.Changed:Destroy()
    table.clear(self._states)
end

-- ── Return ────────────────────────────────────────────────────────────────────

return CurrencyService
