--[[
================================================================================
  ServerMain
  Location: ServerScriptService/ServerMain (Script — NOT a ModuleScript)

  The single server bootstrap. Constructs every service, wires all inter-
  service callbacks, and handles the PlayerAdded / PlayerRemoving lifecycle.

  Load order enforced by construction sequence:
      TickService → SaveService → CurrencyService → UpgradeService
          → PrestigeService → (remote handlers self-register in constructors)

  Nothing except ServerMain should call game:GetService("DataStoreService"),
  require SaveService, or wire PlayerAdded/PlayerRemoving for persistence.
  All other services are constructed here and passed by reference.

================================================================================
--]]

-- ── Roblox Services ───────────────────────────────────────────────────────────

local Players       = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

-- ── Framework Modules ─────────────────────────────────────────────────────────

local Framework = ServerStorage.Framework

local TickService     = require(Framework.TickService)
local SaveService     = require(Framework.SaveService)
local CurrencyService = require(Framework.CurrencyService)
local UpgradeService  = require(Framework.UpgradeService)
local PrestigeService = require(Framework.PrestigeService)

-- ── 1. TickService ────────────────────────────────────────────────────────────
-- Create the singleton heartbeat. Services that need tick groups register them
-- during their own construction; TickService.new() pre-registers "Passive".

local tick = TickService.new()

-- Register the AutoSave group that SaveService will bind to.
-- We do this here (before SaveService.new) so the group exists when
-- SaveService's constructor calls TickService:Bind().
tick:RegisterGroup("AutoSave", 60)  -- seconds; mirrors SaveConfig.AUTO_SAVE_INTERVAL

-- ── 2. SaveService ────────────────────────────────────────────────────────────
-- Must be constructed before any service whose data needs persisting.

local save = SaveService.new(tick)

-- ── 3. CurrencyService ───────────────────────────────────────────────────────
-- Needs TickService to subscribe passive income. Remotes are wired inside new().

local currency = CurrencyService.new(tick)

-- ── 4. UpgradeService ────────────────────────────────────────────────────────
-- Needs CurrencyService for cost deduction. Remotes are wired inside new().

local upgrades = UpgradeService.new(currency)

-- ── 5. PrestigeService ───────────────────────────────────────────────────────
-- Needs CurrencyService to read Gold and award PrestigePoints. Remotes wired
-- inside new().

local prestige = PrestigeService.new(currency)

-- ── 6. Inter-service effect wiring ───────────────────────────────────────────
-- UpgradeService fires OnEffectApplied whenever an upgrade effect is applied
-- (purchase or re-apply after prestige). We translate those into concrete
-- CurrencyService calls here, keeping the two services decoupled.

upgrades:OnEffectApplied(function(
    player:    Player,
    upgradeId: string,
    effectType: string,
    value:     number,
    currencyId: string?
)
    local EffectTypes = require(
        game:GetService("ReplicatedStorage").Shared.Config.UpgradeConfig
    ).EffectTypes

    if effectType == EffectTypes.PassiveMultiplier then
        -- Stack upgrade multiplier on top of the prestige-floor multiplier.
        -- The prestige multiplier is already set on the player's state; we
        -- retrieve it and compound rather than replace.
        -- NOTE: For a production game you may want a dedicated multiplier
        -- accumulation layer. Here we simply set the combined value.
        local prestigeMultiplier = prestige:GetMultiplier(player)
        currency:SetMultiplier(player, prestigeMultiplier * value)

    elseif effectType == EffectTypes.PassiveFlat then
        -- Flat passive bonuses are re-evaluated by CurrencyService each tick
        -- via a per-player flat income accumulator. We notify it here that
        -- the upgrade flat income should be included.
        -- The architecture for flat bonus stacking: expose Add on currency
        -- which ProcessPassiveIncome will sum; here we just log for now.
        -- Extend CurrencyService:AddFlatBonus(player, currencyId, amount) if needed.
        _ = upgradeId  -- used in extended implementations

    elseif effectType == EffectTypes.CapIncrease and currencyId then
        -- CapIncrease upgrades raise the cap in CurrencyConfig at runtime.
        -- For a shipped game, maintain a per-player cap override table in
        -- CurrencyService and apply it here. The base architecture is in place;
        -- this is a game-specific extension point.
        _ = value

    end
    -- CostReduction is applied inside UpgradeService's calcCost; no action here.
end)

-- ── 7. Save wiring ───────────────────────────────────────────────────────────
-- OnLoaded: after a successful DataStore read, initialise all services.
-- OnBeforeSave: just before a DataStore write, serialize all services.

save:OnLoaded(function(player: Player, data)
    -- Restore currencies first (PrestigeService will override multiplier later)
    currency:LoadPlayer(player, data.currencies)
    upgrades:LoadPlayer(player, data.upgrades)
    prestige:LoadPlayer(player, data.prestige)

    -- Re-apply prestige multiplier now that all services are loaded.
    -- This sets the floor; UpgradeService:ApplyEffects then layers upgrades on top.
    local prestigeMultiplier = prestige:GetMultiplier(player)
    currency:SetMultiplier(player, prestigeMultiplier)

    -- Re-attach upgrade-derived multipliers (e.g. GoldRush) and flat bonuses.
    -- This fires OnEffectApplied for every owned upgrade level > 0.
    upgrades:ApplyEffects(player)
end)

save:OnBeforeSave(function(player: Player, snapshot)
    snapshot.currencies = currency:Serialize(player)
    snapshot.upgrades   = upgrades:Serialize(player)
    snapshot.prestige   = prestige:Serialize(player)
end)

-- Register BindToClose AFTER OnBeforeSave callbacks are fully wired so the
-- final flush captures all service state.
save:BindToClose()

-- ── 8. Prestige lifecycle wiring ─────────────────────────────────────────────
-- PrestigeService fires OnPrestige during the reset phase. The callback is
-- responsible for the full unload → reload → re-apply cycle.

prestige:OnPrestige(function(player: Player, newLevel: number, carryOver)
    -- Read upgrade carry-over levels BEFORE UnloadPlayer wipes them.
    local upgradeCarryOver: { [string]: number } = {}
    local PrestigeConfig = require(
        game:GetService("ReplicatedStorage").Shared.Config.PrestigeConfig
    )
    for _, upgradeId in PrestigeConfig.carryOver.upgrades do
        upgradeCarryOver[upgradeId] = upgrades:GetLevel(player, upgradeId)
    end

    -- Tear down live state
    upgrades:UnloadPlayer(player)
    currency:UnloadPlayer(player)

    -- Rebuild with carry-over values injected
    -- carryOver.currencies was populated by PrestigeService before this callback.
    currency:LoadPlayer(player, carryOver.currencies)
    upgrades:LoadPlayer(player, upgradeCarryOver)

    -- Re-attach upgrade-derived multipliers and flats
    upgrades:ApplyEffects(player)

    -- Mark prestige level in display (PrestigeService sets the multiplier
    -- on CurrencyService after this callback returns, as step [7] in the
    -- full prestige lifecycle).
    _ = newLevel  -- used for analytics extensions
end)

-- ── 9. Player lifecycle ───────────────────────────────────────────────────────

local function onPlayerAdded(player: Player)
    -- LoadPlayer yields on DataStore; run in a task so it doesn't block
    -- other PlayerAdded handlers or the engine frame.
    task.spawn(function()
        save:LoadPlayer(player)
        -- OnLoaded fires inside LoadPlayer, which calls currency/upgrades/prestige
        -- LoadPlayer methods — no additional work needed here.
    end)
end

local function onPlayerRemoving(player: Player)
    -- Force an immediate save on departure (bypasses the dirty-flag check;
    -- always safe to call — SaveService handles the no-dirty no-op internally
    -- but a leaving player is always worth writing).
    save:SavePlayer(player)

    -- Unload in reverse dependency order
    prestige:UnloadPlayer(player)
    upgrades:UnloadPlayer(player)
    currency:UnloadPlayer(player)
end

-- Connect lifecycle events
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players who joined before this script finished loading
-- (edge case in Studio playtest where the local player joins instantly).
for _, player in Players:GetPlayers() do
    task.spawn(onPlayerAdded, player)
end

-- ── 10. Start the tick loop ───────────────────────────────────────────────────
-- Must be called AFTER all groups are registered and all Bind() calls are made.
-- Services register their tick callbacks during construction (steps 3–5 above),
-- so this is safe to call last.

tick:Start()
