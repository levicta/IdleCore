# Incremental Game Framework — Developer Documentation

> **Framework version:** 1.0  
> **Roblox language:** Luau (strict-mode compatible)  
> **Last updated:** 2025

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Folder Structure](#2-folder-structure)
3. [Service Dependency Map](#3-service-dependency-map)
4. [Data Schema Reference](#4-data-schema-reference)
5. [TickService](#5-tickservice)
6. [CurrencyService](#6-currencyservice)
7. [UpgradeService](#7-upgradeservice)
8. [PrestigeService](#8-prestigeservice)
9. [SaveService](#9-saveservice)
10. [UIService](#10-uiservice)
11. [Config Files Reference](#11-config-files-reference)
12. [Remote Events & Functions](#12-remote-events--functions)
13. [Migration Guide](#13-migration-guide)
14. [Common Patterns](#14-common-patterns)

---

## 1. Quick Start

From a blank place to a working incremental game in roughly 20 lines. The full `ServerMain` and `ClientMain` files handle all the boilerplate — this is the conceptual minimum.

### Server (`ServerScriptService/ServerMain` — Script)

```lua
local ServerStorage = game:GetService("ServerStorage")
local Players       = game:GetService("Players")
local Framework     = ServerStorage.Framework

local TickService     = require(Framework.TickService)
local SaveService     = require(Framework.SaveService)
local CurrencyService = require(Framework.CurrencyService)
local UpgradeService  = require(Framework.UpgradeService)
local PrestigeService = require(Framework.PrestigeService)

-- 1. Construct services in dependency order
local tick     = TickService.new()
local save     = SaveService.new(tick)
local currency = CurrencyService.new(tick)
local upgrades = UpgradeService.new(currency)
local prestige = PrestigeService.new(currency)

-- 2. Wire save callbacks so services populate/restore from DataStore
save:OnLoaded(function(player, data)
    currency:LoadPlayer(player, data.currencies)
    upgrades:LoadPlayer(player, data.upgrades)
    prestige:LoadPlayer(player, data.prestige)
    currency:SetMultiplier(player, prestige:GetMultiplier(player))
    upgrades:ApplyEffects(player)
end)

save:OnBeforeSave(function(player, snapshot)
    snapshot.currencies = currency:Serialize(player)
    snapshot.upgrades   = upgrades:Serialize(player)
    snapshot.prestige   = prestige:Serialize(player)
end)

save:BindToClose()

-- 3. Player lifecycle
Players.PlayerAdded:Connect(function(player)
    task.spawn(function() save:LoadPlayer(player) end)
end)

Players.PlayerRemoving:Connect(function(player)
    save:SavePlayer(player)
    prestige:UnloadPlayer(player)
    upgrades:UnloadPlayer(player)
    currency:UnloadPlayer(player)
end)

tick:Start()
```

### Client (`StarterPlayerScripts/ClientMain` — LocalScript)

```lua
local UIService = require(script.Parent.UIService)
local ui = UIService.new()  -- connects all Remote listeners automatically

-- Bind a currency label (updates live via tween whenever the server fires CurrencyChanged)
local goldLabel = game.Players.LocalPlayer.PlayerGui.HUD.GoldLabel
ui:BindLabel(goldLabel, "Gold")

-- Bind an upgrade button (colour, cost label, and click handler all auto-managed)
local mineBtn = game.Players.LocalPlayer.PlayerGui.HUD.GoldMineButton
ui:BindUpgradeButton(mineBtn, "GoldMine")

-- Register the prestige fanfare overlay
ui:RegisterScreen("PrestigeFanfare", game.Players.LocalPlayer.PlayerGui.PrestigeFanfare)
```

That's the entire integration surface. Add currencies in `CurrencyConfig`, add upgrades in `UpgradeConfig`, adjust prestige rules in `PrestigeConfig`, and tune display in `UIConfig` — no service code changes required.

---

## 2. Folder Structure

```
game/
├── ServerScriptService/
│   └── ServerMain              ← Bootstrap Script (not a ModuleScript)
│
├── ServerStorage/
│   └── Framework/              ← Server-only modules (clients cannot require these)
│       ├── TickService.lua
│       ├── CurrencyService.lua
│       ├── UpgradeService.lua
│       ├── PrestigeService.lua
│       └── SaveService.lua
│
├── ReplicatedStorage/
│   └── Shared/                 ← Readable by both server and client
│       ├── Config/
│       │   ├── CurrencyConfig.lua
│       │   ├── UpgradeConfig.lua
│       │   ├── PrestigeConfig.lua
│       │   ├── SaveConfig.lua
│       │   └── UIConfig.lua
│       └── Remotes/
│           ├── CurrencyRemotes.lua
│           ├── UpgradeRemotes.lua
│           └── PrestigeRemotes.lua
│
└── StarterPlayerScripts/
    └── Client/
        ├── ClientMain          ← Bootstrap LocalScript (not a ModuleScript)
        └── UIService.lua
```

**Key rules enforced by this layout:**

| Rule | Reason |
|------|--------|
| Services live in `ServerStorage` | Clients cannot `require()` them — no server logic leaks |
| Config lives in `ReplicatedStorage/Shared/Config` | Both sides read definitions without duplication |
| Remotes defined once in `Shared/Remotes` | Single source of truth for event names and signatures |
| `TickService` server-only | Passive income is server-authoritative |
| `UIService` client-only | Pure presentation; never writes game state |

---

## 3. Service Dependency Map

```
ServerMain (wires everything)
│
├── TickService          (no dependencies)
│     └── provides heartbeat to:
│           ├── CurrencyService  (passive income tick)
│           └── SaveService      (auto-save tick)
│
├── CurrencyService      (depends on: TickService)
│     └── provides currency ops to:
│           ├── UpgradeService   (Subtract for cost, SetMultiplier for effects)
│           └── PrestigeService  (Get gold, Add prestige points, SetMultiplier)
│
├── UpgradeService       (depends on: CurrencyService)
│     └── effects fired via OnEffectApplied callbacks → ServerMain → CurrencyService
│
├── PrestigeService      (depends on: CurrencyService)
│     └── reset orchestrated via OnPrestige callbacks → ServerMain
│           → UpgradeService.UnloadPlayer / LoadPlayer / ApplyEffects
│           → CurrencyService.UnloadPlayer / LoadPlayer
│
└── SaveService          (depends on: TickService)
      └── data flows through OnLoaded / OnBeforeSave callbacks → all services

UIService               (client-only, depends on: all three Remote modules)
      └── purely reactive — reads Remote events, writes nothing to server
```

**Decoupling matrix** — a ✓ means the row service directly calls the column service at runtime:

| | TickService | CurrencyService | UpgradeService | PrestigeService | SaveService | UIService |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **TickService** | — | ✗ | ✗ | ✗ | ✗ | ✗ |
| **CurrencyService** | ✓ Subscribe | — | ✗ | ✗ | ✗ | ✗ |
| **UpgradeService** | ✗ | ✓ Subtract/Get | — | ✗ | ✗ | ✗ |
| **PrestigeService** | ✗ | ✓ Get/Add/SetMult | ✗ via callbacks | — | ✗ | ✗ |
| **SaveService** | ✓ RegisterGroup/Bind | ✗ via callbacks | ✗ via callbacks | ✗ via callbacks | — | ✗ |
| **UIService** | ✗ | ✗ via Remotes | ✗ via Remotes | ✗ via Remotes | ✗ | — |

> The ✗ entries between PrestigeService and UpgradeService are intentional design. PrestigeService never `require()`s UpgradeService. The reset cycle is orchestrated entirely through `OnPrestige` callbacks wired in ServerMain.

---

## 4. Data Schema Reference

Every player's persistent data is a single document stored under the key `Player_<UserId>` in the `IncrementalFramework_v1` DataStore.

```
SaveDocument {
    _version   : number               -- schema version stamp (currently 1)
    currencies : { [string]: number } -- currencyId → balance
    upgrades   : { [string]: number } -- upgradeId  → level (0 = not purchased)
    prestige   : {
        level  : number               -- prestige tier (0 = never prestiged)
    }
}
```

### Example document (a player at prestige 2 with some upgrades)

```json
{
  "_version": 1,
  "currencies": {
    "Gold": 45200,
    "Gems": 12,
    "PrestigePoints": 7
  },
  "upgrades": {
    "GoldMine": 5,
    "GoldRush": 2,
    "GemVault": 1,
    "PrestigeAccelerator": 0
  },
  "prestige": {
    "level": 2
  }
}
```

### Default document (brand-new player with no save)

```json
{
  "_version": 1,
  "currencies": {},
  "upgrades": {},
  "prestige": { "level": 0 }
}
```

Missing currency/upgrade keys are filled from `CurrencyConfig.startAmount` and `0` respectively during `LoadPlayer` — the default document does not need to enumerate every key.

---

## 5. TickService

**Location:** `ServerStorage/Framework/TickService.lua`  
**Side:** Server only

### Overview

The central heartbeat for the entire framework. Other services register named tick groups here instead of creating their own `RunService.Heartbeat` loops. This keeps all time-based logic on a single, controlled cadence with isolated error handling per callback.

A pre-registered `"Passive"` group fires every 1 second (configurable). Services register additional groups (`"AutoSave"` etc.) before calling `Start()`.

### API Reference

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `new` | `TickService.new()` | `TickServiceImpl` | Returns the singleton; creates it on first call |
| `Start` | `:Start()` | `void` | Connects `RunService.Heartbeat` and begins the tick loop. No-op if already running |
| `Stop` | `:Stop()` | `void` | Disconnects the loop. Does not reset elapsed time or tick counts |
| `RegisterGroup` | `:RegisterGroup(groupName: string, interval: number)` | `void` | Creates a named group firing every `interval` seconds. If the group exists, only its interval is updated |
| `Bind` | `:Bind(groupName: string, id: string, callback: (dt: number) -> ())` | `void` | Attaches a callback to a group. `dt` = the group interval, not the raw frame delta |
| `Unbind` | `:Unbind(groupName: string, id: string)` | `void` | Removes a callback by id. Safe to call if id does not exist |
| `GetElapsed` | `:GetElapsed()` | `number` | Seconds since `Start()` (pauses while stopped) |
| `GetTick` | `:GetTick(groupName: string)` | `number` | Cumulative fire count for a group since `Start()` |

### Built-in Groups

| Group name | Default interval | Registered by |
|------------|-----------------|---------------|
| `"Passive"` | 1 second | `TickService.new()` |
| `"AutoSave"` | 60 seconds | `ServerMain` (before `SaveService.new`) |

### Usage Example

```lua
local TickService = require(ServerStorage.Framework.TickService)
local tick = TickService.new()

-- Register a custom group for a daily reward system
tick:RegisterGroup("DailyCheck", 300)  -- check every 5 minutes

tick:Bind("DailyCheck", "DailyRewardSystem", function(dt: number)
    for _, player in game.Players:GetPlayers() do
        checkDailyReward(player)
    end
end)

-- "Every 60 passive ticks = 1 minute" pattern (no extra state needed)
tick:Bind("Passive", "MinuteBonus", function(dt: number)
    if tick:GetTick("Passive") % 60 == 0 then
        awardMinuteBonus()
    end
end)

tick:Start()

-- Cleanup
tick:Unbind("DailyCheck", "DailyRewardSystem")
```

---

## 6. CurrencyService

**Location:** `ServerStorage/Framework/CurrencyService.lua`  
**Side:** Server only

### Overview

Server-authoritative currency management. All balance mutations happen here. Clients request changes via `RemoteFunctions` and receive updates via `RemoteEvents`. Passive income is driven by `TickService`. The client is never trusted for amounts.

### API Reference

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `new` | `CurrencyService.new(tickService)` | `CurrencyService` | Constructs the service, wires `TickService`, sets up Remote handlers |
| `LoadPlayer` | `:LoadPlayer(player, savedData?)` | `void` | Initialises wallets from save data or defaults. Must be called before any per-player method |
| `UnloadPlayer` | `:UnloadPlayer(player)` | `void` | Removes the player's in-memory wallet. Call on `PlayerRemoving` |
| `Get` | `:Get(player, currencyId)` | `number` | Returns current balance |
| `Set` | `:Set(player, currencyId, amount)` | `number` | Sets balance directly, clamped to `[0, cap]`. Returns new amount |
| `Add` | `:Add(player, currencyId, amount)` | `number` | Adds `amount` (must be ≥ 0). Returns new amount |
| `Subtract` | `:Subtract(player, currencyId, amount)` | `(boolean, number)` | Deducts if affordable. Returns `(success, newAmount)`. On failure, state is not mutated |
| `Cap` | `:Cap(player, currencyId)` | `number` | Returns the configured cap (may be `math.huge`) |
| `SetMultiplier` | `:SetMultiplier(player, multiplier)` | `void` | Overrides passive income multiplier for one player. Called by PrestigeService after reset |
| `ProcessPassiveIncome` | `:ProcessPassiveIncome(dt)` | `void` | Called by TickService each tick. Awards `passiveRate × multiplier` to all loaded players |
| `Serialize` | `:Serialize(player)` | `{ [string]: number }` | Returns a shallow copy of the player's wallet for SaveService |
| `Deserialize` | `:Deserialize(player, data)` | `void` | Restores balances from a snapshot and notifies the client |
| `Destroy` | `:Destroy()` | `void` | Unsubscribes from TickService and clears Remote handlers |

### Events

| Event | Type | Arguments | Description |
|-------|------|-----------|-------------|
| `Changed` | `BindableEvent` | `(player, currencyId, newAmount, delta)` | Fires server-side after every balance mutation. Use for internal system reactions |

### Remote Handlers (auto-registered in `new`)

| Remote | Direction | Arguments | Returns | Notes |
|--------|-----------|-----------|---------|-------|
| `CurrencyChanged` | Server → Client | `(currencyId, newAmount, delta)` | — | Fired after every mutation |
| `GetCurrency` | Client → Server | `(currencyId)` | `number` | Returns caller's current balance |
| `RequestSpend` | Client → Server | `(currencyId, amount)` | `(boolean, number)` | Validates and deducts. Rejects non-positive amounts |

### Usage Example

```lua
local currency = CurrencyService.new(tick)

-- Award a one-off reward
currency:Add(player, "Gold", 1000)

-- Spend check pattern (used internally by UpgradeService)
local success, newBalance = currency:Subtract(player, "Gold", 500)
if success then
    print("Spent 500 Gold. Remaining:", newBalance)
else
    print("Insufficient Gold")
end

-- React to any balance change (server-side only)
currency.Changed.Event:Connect(function(plr, id, amount, delta)
    if id == "Gold" and amount >= 10000 then
        unlockPrestigeHint(plr)
    end
end)

-- Prestige wires multiplier after reset
currency:SetMultiplier(player, 2.0)  -- 2× passive income from prestige
```

---

## 7. UpgradeService

**Location:** `ServerStorage/Framework/UpgradeService.lua`  
**Side:** Server only

### Overview

Manages upgrade definitions, level tracking, exponential cost scaling, and effect application. All purchases are atomic: afford-check → deduct → increment → fire effects happen in one uninterruptible block. UpgradeService is decoupled from CurrencyService's effect application — it fires `OnEffectApplied` callbacks and ServerMain decides what to do with them.

### API Reference

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `new` | `UpgradeService.new(currencyService)` | `UpgradeService` | Constructs the service and registers Remote handlers |
| `LoadPlayer` | `:LoadPlayer(player, savedData?)` | `void` | Seeds upgrade levels (all 0 for new players) and bulk-syncs to client via `UpgradesSync` |
| `UnloadPlayer` | `:UnloadPlayer(player)` | `void` | Removes in-memory state. Call on `PlayerRemoving` |
| `GetLevel` | `:GetLevel(player, upgradeId)` | `number` | Returns current level (0 = never purchased) |
| `CanAfford` | `:CanAfford(player, upgradeId)` | `boolean` | Returns true if the player can afford the next level |
| `GetCostForLevel` | `:GetCostForLevel(upgradeId, level)` | `number` | Cost for a specific level using `floor(baseCost × costScaling ^ (level-1))` |
| `GetEffect` | `:GetEffect(upgradeId, level)` | `number` | Effect magnitude at a level using `effectValue + effectScaling × (level-1)` |
| `Purchase` | `:Purchase(player, upgradeId)` | `(boolean, string, number)` | Atomically buys one level. Returns `(success, reason, newLevel)` |
| `ApplyEffects` | `:ApplyEffects(player)` | `void` | Re-fires `OnEffectApplied` for all owned upgrades. Call after prestige reset |
| `OnEffectApplied` | `:OnEffectApplied(callback)` | `() -> ()` | Registers an effect callback. Returns an unsubscribe function |
| `Serialize` | `:Serialize(player)` | `{ [string]: number }` | Returns `{ upgradeId: level }` snapshot |
| `Deserialize` | `:Deserialize(player, data)` | `void` | Restores levels without firing effects. Call `ApplyEffects` separately |
| `Destroy` | `:Destroy()` | `void` | Clears Remote handlers and all state |

### Events

| Event | Type | Arguments | Description |
|-------|------|-----------|-------------|
| `Purchased` | `BindableEvent` | `(player, upgradeId, newLevel)` | Fires after every successful purchase. Use for achievements, analytics |

### `OnEffectApplied` Callback Signature

```lua
callback(
    player:     Player,
    upgradeId:  string,
    effectType: string,   -- see UpgradeConfig.EffectTypes
    value:      number,   -- computed effect magnitude at the new level
    currencyId: string?   -- target currency (nil for global effects)
)
```

### Effect Types

| Effect Type | What it means | Typical action in ServerMain |
|------------|---------------|------------------------------|
| `PassiveMultiplier` | Multiply a currency's passive rate | `currency:SetMultiplier(player, prestigeMultiplier * value)` |
| `PassiveFlat` | Add flat income per tick | Extend `ProcessPassiveIncome` or store flat bonus per player |
| `CapIncrease` | Raise a currency's storage cap | Maintain per-player cap override table in CurrencyService |
| `CostReduction` | Reduce all purchase costs | Apply inside `calcCost` or override per-player |

### Remote Handlers (auto-registered in `new`)

| Remote | Direction | Arguments | Returns | Notes |
|--------|-----------|-----------|---------|-------|
| `UpgradesSync` | Server → Client | `{ [upgradeId]: level }` | — | Fired on `LoadPlayer` |
| `UpgradePurchased` | Server → Client | `(upgradeId, newLevel, nextCost)` | — | `nextCost = -1` when maxed |
| `RequestPurchase` | Client → Server | `(upgradeId)` | `(boolean, string, number)` | Has in-flight duplicate guard |
| `GetUpgradeLevel` | Client → Server | `(upgradeId)` | `number` | For UI polling |

### Usage Example

```lua
local upgrades = UpgradeService.new(currency)

-- Wire effects into CurrencyService (ServerMain responsibility)
upgrades:OnEffectApplied(function(player, upgradeId, effectType, value, currencyId)
    local ET = UpgradeConfig.EffectTypes
    if effectType == ET.PassiveMultiplier then
        local baseMultiplier = prestige:GetMultiplier(player)
        currency:SetMultiplier(player, baseMultiplier * value)
    end
end)

-- Admin command: award an upgrade level directly
local ok, reason, level = upgrades:Purchase(player, "GoldMine")
print(ok, reason, level)  --> true  "OK"  1

-- Query the cost of an upgrade the player doesn't own yet
local cost = upgrades:GetCostForLevel("GoldRush", 1)  --> 500

-- Query the effect at a hypothetical level
local effect = upgrades:GetEffect("GoldMine", 5)  --> 5 (1 + 1×4)
```

---

## 8. PrestigeService

**Location:** `ServerStorage/Framework/PrestigeService.lua`  
**Side:** Server only

### Overview

Handles the full prestige lifecycle: eligibility validation, points calculation, carry-over snapshot, reset orchestration via callbacks, multiplier tracking, and client notification. PrestigeService **does not** directly call `UpgradeService` — the reset cycle is delegated to `OnPrestige` callbacks wired in ServerMain, keeping all three services decoupled.

`TickService` is intentionally not paused during prestige. Prestige is a player-state event, not a simulation pause.

### API Reference

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `new` | `PrestigeService.new(currencyService)` | `PrestigeService` | Constructs the service and registers Remote handlers |
| `LoadPlayer` | `:LoadPlayer(player, savedData?)` | `void` | Initialises prestige state and fires `PrestigeSync` to client |
| `UnloadPlayer` | `:UnloadPlayer(player)` | `void` | Removes in-memory state |
| `GetLevel` | `:GetLevel(player)` | `number` | Current prestige level (0 = never prestiged) |
| `GetMultiplier` | `:GetMultiplier(player)` | `number` | Passive income multiplier = `base + (perLevel × level)` |
| `CalculatePointsEarned` | `:CalculatePointsEarned(player)` | `number` | Points that would be earned right now. Pure read — no mutation |
| `CanPrestige` | `:CanPrestige(player)` | `(boolean, string)` | Eligibility check. Returns `(canPrestige, reason)` |
| `Prestige` | `:Prestige(player)` | `(boolean, string, number, number)` | Executes the full lifecycle. Returns `(success, reason, newLevel, pointsEarned)` |
| `OnPrestige` | `:OnPrestige(callback)` | `() -> ()` | Registers a reset callback. Returns an unsubscribe function |
| `Serialize` | `:Serialize(player)` | `{ level: number }` | Returns prestige snapshot for SaveService |
| `Deserialize` | `:Deserialize(player, data)` | `void` | Restores level from snapshot and re-syncs client |
| `Destroy` | `:Destroy()` | `void` | Clears Remote handlers and all state |

### Events

| Event | Type | Arguments | Description |
|-------|------|-----------|-------------|
| `Prestiged` | `BindableEvent` | `(player, newLevel, pointsEarned)` | Fires after a successful prestige. Use for achievements, analytics |

### `OnPrestige` Callback Signature

```lua
callback(
    player:    Player,
    newLevel:  number,          -- the level AFTER increment (i.e. new prestige tier)
    carryOver: CarryOverSnapshot
)

-- CarryOverSnapshot shape:
{
    currencies: { [string]: number },  -- carry-over balances, populated before reset
    upgrades:   { [string]: number },  -- carry-over levels, populated by the callback itself
}
```

> **Important:** `carryOver.upgrades` is an **empty table** when the callback receives it. The callback must read carry-over upgrade levels from `UpgradeService` **before** calling `UnloadPlayer`, then populate the table itself. See the example below.

### Prestige Lifecycle (9 steps)

```
[1]  CanPrestige()          — fail fast if ineligible
[2]  _buildCarryOverSnapshot — read currency carry-overs BEFORE any wipe
[3]  CalculatePointsEarned  — compute from live Gold BEFORE wipe
[4]  OnPrestige callbacks   — ServerMain tears down and rebuilds state
[5]  state.level += 1
[6]  CurrencyService:Add("PrestigePoints", pointsEarned)
[7]  CurrencyService:SetMultiplier(GetMultiplier(player))
[8]  Prestiged:Fire(...)
[9]  PrestigeCompleted:FireClient(...)
```

### Remote Handlers (auto-registered in `new`)

| Remote | Direction | Arguments | Returns | Notes |
|--------|-----------|-----------|---------|-------|
| `PrestigeSync` | Server → Client | `(level, multiplier)` | — | Fired on `LoadPlayer` |
| `PrestigeCompleted` | Server → Client | `(newLevel, pointsEarned)` | — | Fired after successful prestige |
| `RequestPrestige` | Client → Server | `()` | `(boolean, string, number, number)` | Has in-flight duplicate guard |
| `GetPrestigeInfo` | Client → Server | `()` | `(level, multiplier, pointsIfNow, canPrestige)` | For UI tooltip display |

### Usage Example

```lua
local prestige = PrestigeService.new(currency)

-- Wire the reset callback (ServerMain)
prestige:OnPrestige(function(player, newLevel, carryOver)
    -- Read carry-over upgrade levels BEFORE UnloadPlayer destroys them
    local PrestigeConfig = require(ReplicatedStorage.Shared.Config.PrestigeConfig)
    local upgradeCarryOver = {}
    for _, upgradeId in PrestigeConfig.carryOver.upgrades do
        upgradeCarryOver[upgradeId] = upgrades:GetLevel(player, upgradeId)
    end

    -- Tear down
    upgrades:UnloadPlayer(player)
    currency:UnloadPlayer(player)

    -- Rebuild with carry-over values
    currency:LoadPlayer(player, carryOver.currencies)
    upgrades:LoadPlayer(player, upgradeCarryOver)
    upgrades:ApplyEffects(player)
end)

-- Query eligibility from an admin command
local canDo, reason = prestige:CanPrestige(player)
if canDo then
    local ok, msg, level, pts = prestige:Prestige(player)
    print(ok, msg, level, pts)  --> true  "OK"  1  3
end

-- Preview points (useful for UI tooltip)
local preview = prestige:CalculatePointsEarned(player)
print("Prestige now for", preview, "points")
```

---

## 9. SaveService

**Location:** `ServerStorage/Framework/SaveService.lua`  
**Side:** Server only

### Overview

The single I/O layer the entire framework talks to. All DataStore reads and writes are funnelled through here. No other service calls `DataStoreService` directly.

Key features: dirty-flag skipping (only writes players with actual changes), schema versioning with automatic migration chaining, exponential backoff on DataStore failures, and a `BindToClose` flush with a timeout guard respecting Roblox's 30-second shutdown window.

### API Reference

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `new` | `SaveService.new(tickService)` | `SaveServiceImpl` | Constructs the singleton, registers the `AutoSave` tick group, and binds the auto-save callback |
| `LoadPlayer` | `:LoadPlayer(player)` | `void` | Reads DataStore, runs migrations, merges defaults, fires `OnLoaded`. Yields — wrap in `task.spawn` from `PlayerAdded` |
| `SavePlayer` | `:SavePlayer(player)` | `void` | Fires `OnBeforeSave`, writes DataStore, clears dirty flag. No-op if not loaded or not dirty |
| `DeletePlayer` | `:DeletePlayer(player)` | `void` | Removes the DataStore key and in-memory state. For GDPR / data deletion |
| `MarkDirty` | `:MarkDirty(player)` | `void` | Manually marks a player as having unsaved changes |
| `OnLoaded` | `:OnLoaded(callback)` | `() -> ()` | Registers a callback fired after load. Returns unsubscribe function |
| `OnBeforeSave` | `:OnBeforeSave(callback)` | `() -> ()` | Registers a callback fired before write. Returns unsubscribe function |
| `BindToClose` | `:BindToClose()` | `void` | Registers `game:BindToClose` to flush dirty players on shutdown. Call after all `OnBeforeSave` are wired |
| `Destroy` | `:Destroy()` | `void` | Unsubscribes from TickService. For testing teardown |

### Callback Signatures

```lua
-- OnLoaded
callback(player: Player, data: SaveDocument) -> ()
-- data is the fully hydrated, migrated document. Write nothing back here;
-- pass sub-tables to the appropriate service LoadPlayer methods.

-- OnBeforeSave
callback(player: Player, snapshot: SaveDocument) -> ()
-- snapshot is mutable. Populate it with service Serialize output:
--   snapshot.currencies = currency:Serialize(player)
--   snapshot.upgrades   = upgrades:Serialize(player)
--   snapshot.prestige   = prestige:Serialize(player)
```

### Architecture Details

**Dirty flag:** Set to `true` whenever `OnBeforeSave` is called (which happens on every auto-save and `PlayerRemoving` flush). Cleared only after a successful `SetAsync`. Auto-save skips players whose flag is `false`.

**Loading guard:** Between `LoadPlayer` being called and `GetAsync` returning, `loading = true`. Auto-save skips loading players to prevent writing default data over a real save.

**Exponential backoff:** On failure, retry delays are `1s, 2s, 4s, 8s, 16s` (default config). After `MAX_RETRIES` attempts the operation gives up, logs a warning, and leaves the dirty flag set so the next auto-save tries again.

**BindToClose timeout:** The shutdown handler iterates dirty players sequentially and stops at `BIND_TO_CLOSE_TIMEOUT` (25 seconds by default) to stay within Roblox's hard 30-second limit.

### Usage Example

```lua
local save = SaveService.new(tick)

save:OnLoaded(function(player, data)
    currency:LoadPlayer(player, data.currencies)
    upgrades:LoadPlayer(player, data.upgrades)
    prestige:LoadPlayer(player, data.prestige)
    currency:SetMultiplier(player, prestige:GetMultiplier(player))
    upgrades:ApplyEffects(player)
end)

save:OnBeforeSave(function(player, snapshot)
    snapshot.currencies = currency:Serialize(player)
    snapshot.upgrades   = upgrades:Serialize(player)
    snapshot.prestige   = prestige:Serialize(player)
end)

save:BindToClose()  -- always after all OnBeforeSave registrations

Players.PlayerAdded:Connect(function(player)
    task.spawn(function()
        save:LoadPlayer(player)
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    save:SavePlayer(player)  -- immediate flush on departure
    -- UnloadPlayer calls for each service follow
end)
```

---

## 10. UIService

**Location:** `StarterPlayerScripts/Client/UIService.lua`  
**Side:** Client only

### Overview

The reactive presentation layer. All display logic lives here; UIService never writes game state or sends data to the server. It connects to Remote events automatically on construction and drives TextLabel tweens, upgrade button states, and screen registry management.

### API Reference

| Method | Signature | Returns | Description |
|--------|-----------|---------|-------------|
| `new` | `UIService.new()` | `UIServiceImpl` | Constructs the singleton and connects all Remote listeners. Call once from ClientMain |
| `FormatNumber` | `:FormatNumber(n)` | `string` | Formats a number per UIConfig tiers: raw / suffixed / scientific |
| `BindLabel` | `:BindLabel(label, currencyId)` | `() -> ()` | Auto-updates the label with a tween whenever the currency changes. Returns unsubscribe function |
| `UnbindLabel` | `:UnbindLabel(label, currencyId)` | `void` | Removes a label binding |
| `BindUpgradeButton` | `:BindUpgradeButton(button, upgradeId)` | `() -> ()` | Manages button colour, cost label, level label, and click handling. Returns unsubscribe function |
| `UpdateCurrencyDisplay` | `:UpdateCurrencyDisplay(currencyId, newAmount)` | `void` | Drives all bound labels for a currency. Called automatically by `CurrencyChanged` |
| `UpdateUpgradeDisplays` | `:UpdateUpgradeDisplays(levels)` | `void` | Refreshes all bound buttons from a level map. Called automatically by `UpgradesSync` |
| `RefreshUpgradeButton` | `:RefreshUpgradeButton(upgradeId, newLevel, nextCost)` | `void` | Refreshes one button after a purchase. Called automatically by `UpgradePurchased` |
| `UpdatePrestigeDisplay` | `:UpdatePrestigeDisplay(level, multiplier)` | `void` | Updates labels bound to virtual keys `"PrestigeLevel"` and `"PrestigeMultiplier"` |
| `ShowPrestigeFanfare` | `:ShowPrestigeFanfare(newLevel, pointsEarned)` | `void` | Shows the `"PrestigeFanfare"` registered screen for `FANFARE_DURATION` seconds |
| `RegisterScreen` | `:RegisterScreen(name, screenGui)` | `void` | Adds a ScreenGui to the named registry |
| `UnregisterScreen` | `:UnregisterScreen(name, screenGui)` | `void` | Removes a ScreenGui from the registry |
| `ShowScreen` | `:ShowScreen(name)` | `void` | Sets `Enabled = true` on all registered screens under the name |
| `HideScreen` | `:HideScreen(name)` | `void` | Sets `Enabled = false` on all registered screens under the name |
| `Destroy` | `:Destroy()` | `void` | Disconnects all listeners and clears all bindings |

### Virtual Currency IDs for Prestige Display

Prestige labels are bound like currency labels, using special virtual IDs:

| Virtual ID | Updated by | Contains |
|------------|-----------|----------|
| `"PrestigeLevel"` | `UpdatePrestigeDisplay` | Current prestige tier (integer) |
| `"PrestigeMultiplier"` | `UpdatePrestigeDisplay` | Current multiplier value (e.g. `2.5`) |

### Button Child Element Conventions

`BindUpgradeButton` looks for these named children on the button and updates them automatically:

| Child name | Type | Content |
|------------|------|---------|
| `Cost` | `TextLabel` | Next-level cost string (e.g. `"150 Gold"`) or `"MAX"` |
| `Level` | `TextLabel` | Current level string (e.g. `"Lv 3"`) |

Neither child is required — the button still works for colour and click handling if they are absent.

### Tween Counter Behaviour

- Each bound label has a per-label `displayValue` that moves toward `target` over `TWEEN_DURATION` seconds.
- If a second update arrives mid-animation, the in-flight animation is cancelled and a new one starts from the **current mid-flight value** — the counter never jumps backwards.
- `TWEEN_DURATION = 0` snaps labels instantly with no animation.
- The tween runs on `RunService.Heartbeat` with an inline easing function — **no `NumberValue` instances are created**.

### Remote Listeners (auto-connected in `new`)

| Remote | Arguments received | Action taken |
|--------|--------------------|--------------|
| `CurrencyChanged` | `(currencyId, newAmount, delta)` | Calls `UpdateCurrencyDisplay` + refreshes all upgrade buttons |
| `UpgradesSync` | `({ [upgradeId]: level })` | Calls `UpdateUpgradeDisplays` |
| `UpgradePurchased` | `(upgradeId, newLevel, nextCost)` | Calls `RefreshUpgradeButton` |
| `PrestigeSync` | `(level, multiplier)` | Calls `UpdatePrestigeDisplay` |
| `PrestigeCompleted` | `(newLevel, pointsEarned)` | Calls `UpdatePrestigeDisplay` + `ShowPrestigeFanfare` |

### Usage Example

```lua
local ui = UIService.new()

-- Currency labels
ui:BindLabel(playerGui.HUD.GoldLabel,  "Gold")
ui:BindLabel(playerGui.HUD.GemsLabel,  "Gems")
ui:BindLabel(playerGui.HUD.PPLabel,    "PrestigePoints")

-- Prestige info labels (virtual IDs)
ui:BindLabel(playerGui.HUD.PrestigeLevelLabel,      "PrestigeLevel")
ui:BindLabel(playerGui.HUD.PrestigeMultiplierLabel, "PrestigeMultiplier")

-- Upgrade buttons (click, colour, cost, level all managed)
ui:BindUpgradeButton(playerGui.HUD.GoldMineButton,  "GoldMine")
ui:BindUpgradeButton(playerGui.HUD.GoldRushButton,  "GoldRush")
ui:BindUpgradeButton(playerGui.HUD.GemVaultButton,  "GemVault")

-- Screen registry
ui:RegisterScreen("PrestigeFanfare", playerGui.PrestigeFanfare)
playerGui.PrestigeFanfare.Enabled = false  -- starts hidden

-- Format a number manually (e.g. for a tooltip)
local display = ui:FormatNumber(1234567)  --> "1.23M"

-- Dynamically remove a binding when a panel is destroyed
local unsub = ui:BindLabel(someLabel, "Gold")
someLabel.Parent = nil
unsub()
```

---

## 11. Config Files Reference

All config files live in `ReplicatedStorage/Shared/Config/` and are readable by both server and client. **Never put logic in config files — data only.**

---

### CurrencyConfig

**File:** `CurrencyConfig.lua`  
**Exports:** `CurrencyConfig.Currencies`, `CurrencyConfig.Map`, `CurrencyConfig.BasePassiveMultiplier`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | `string` | — | Unique currency key used throughout the framework |
| `displayName` | `string` | — | Human-readable label for UI |
| `cap` | `number` | — | Maximum storable amount. Use `math.huge` for uncapped |
| `startAmount` | `number` | — | Balance given to new players on first join |
| `passiveRate` | `number` | — | Units awarded per passive tick (0 = no passive income) |
| `icon` | `string?` | `nil` | Emoji or asset ID for UI display |
| `BasePassiveMultiplier` | `number` | `1.0` | Global multiplier applied to all passive rates. Overridden per-player by PrestigeService |

**Built-in currencies:**

| ID | Cap | Passive Rate | Notes |
|----|-----|-------------|-------|
| `Gold` | `math.huge` | 1/tick | Primary resource |
| `Gems` | `10,000` | 0 | Premium cap-limited currency |
| `PrestigePoints` | `math.huge` | 0 | Awarded only by PrestigeService |

---

### UpgradeConfig

**File:** `UpgradeConfig.lua`  
**Exports:** `UpgradeConfig.Upgrades`, `UpgradeConfig.Map`, `UpgradeConfig.EffectTypes`

| Field | Type | Description |
|-------|------|-------------|
| `id` | `string` | Unique upgrade key |
| `name` | `string` | Display name |
| `description` | `string` | Tooltip text (may include `%d`/`%.2f` format specifiers for the effect value) |
| `cost.currencyId` | `string` | Which currency is spent |
| `cost.amount` | `number` | Base cost at level 1 |
| `costScaling` | `number` | Exponential multiplier per level. `1.5` = 50% more each level |
| `effectType` | `string` | One of `EffectTypes.*` (see below) |
| `effectValue` | `number` | Base effect magnitude at level 1 |
| `effectScaling` | `number` | Additive increase per additional level |
| `maxLevel` | `number` | Maximum level. `0` = unlimited |
| `currencyId` | `string?` | Target currency for currency-specific effects |
| `prerequisites` | `{string}?` | Upgrade IDs that must be ≥ level 1 before this can be purchased |

**Effect types:**

| Constant | Value | Meaning |
|----------|-------|---------|
| `EffectTypes.PassiveMultiplier` | `"PassiveMultiplier"` | Multiplies passive income for a currency |
| `EffectTypes.PassiveFlat` | `"PassiveFlat"` | Adds flat income per tick for a currency |
| `EffectTypes.CapIncrease` | `"CapIncrease"` | Raises the storage cap for a currency |
| `EffectTypes.CostReduction` | `"CostReduction"` | Reduces all purchase costs (global, future use) |

**Cost formula:** `floor(cost.amount × costScaling ^ (level - 1))`  
**Effect formula:** `effectValue + effectScaling × (level - 1)`

---

### PrestigeConfig

**File:** `PrestigeConfig.lua`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `costCurrencyId` | `string` | `"Gold"` | Currency spent to prestige |
| `costAmount` | `number` | `10,000` | Amount of `costCurrencyId` required |
| `rewardCurrencyId` | `string` | `"PrestigePoints"` | Currency that receives earned points |
| `pointsFormula.coefficient` | `number` | `1` | Flat multiplier on the points result |
| `pointsFormula.scale` | `number` | `1,000` | Divisor applied to Gold before the exponent |
| `pointsFormula.exponent` | `number` | `0.5` | Power applied to scaled Gold |
| `multiplierFormula.baseMultiplier` | `number` | `1.0` | Multiplier at prestige level 0 |
| `multiplierFormula.multiplierPerLevel` | `number` | `0.5` | Additive bonus per prestige level |
| `carryOver.currencies` | `{string}` | `{"PrestigePoints"}` | Currency IDs that survive the reset |
| `carryOver.upgrades` | `{string}` | `{"GemVault"}` | Upgrade IDs whose levels survive the reset |
| `minimumGoldRequired` | `number` | `10,000` | Floor gate separate from `costAmount` |

**Points formula:** `floor(coefficient × (Gold / scale) ^ exponent)`  
**Multiplier formula:** `baseMultiplier + (multiplierPerLevel × prestigeLevel)`

---

### SaveConfig

**File:** `SaveConfig.lua`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `DATASTORE_NAME` | `string` | `"IncrementalFramework_v1"` | DataStore name. Changing this abandons existing saves |
| `KEY_PREFIX` | `string` | `"Player_"` | Prepended to every player key: `"Player_<UserId>"` |
| `CURRENT_SCHEMA_VERSION` | `number` | `1` | Version stamped into every save document |
| `Migrations` | `{[number]: fn}` | `{}` | Migration functions keyed by FROM-version |
| `AUTO_SAVE_INTERVAL` | `number` | `60` | Seconds between auto-save ticks |
| `AUTO_SAVE_GROUP` | `string` | `"AutoSave"` | TickService group name used for auto-save |
| `MAX_RETRIES` | `number` | `5` | Maximum DataStore operation retries |
| `RETRY_BASE_DELAY` | `number` | `1` | Seconds before first retry |
| `RETRY_BACKOFF_FACTOR` | `number` | `2` | Delay multiplier each attempt (`1s, 2s, 4s, 8s, 16s`) |
| `BIND_TO_CLOSE_TIMEOUT` | `number` | `25` | Seconds allowed for shutdown flush (keep below 30) |
| `DEFAULT_DATA` | `table` | (see schema) | Document returned for brand-new players |

---

### UIConfig

**File:** `UIConfig.lua`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `RAW_THRESHOLD` | `number` | `999` | Numbers ≤ this are shown as plain integers |
| `SCIENTIFIC_THRESHOLD` | `number` | `1e15` | Numbers ≥ this use scientific notation |
| `SUFFIXES` | `{SuffixTier}` | K/M/B/T/Qa/Qi… | Array of `{divisor, suffix}` pairs, sorted ascending |
| `SUFFIX_DECIMALS` | `{[string]: number}` | `2` for all tiers | Decimal places per suffix |
| `SUFFIX_DECIMALS_DEFAULT` | `number` | `2` | Fallback decimal places for unlisted suffixes |
| `SCIENTIFIC_DECIMALS` | `number` | `3` | Decimal places in scientific notation |
| `TWEEN_DURATION` | `number` | `0.35` | Label counter animation duration in seconds. `0` = instant |
| `TWEEN_EASING_STYLE` | `string` | `"Quad"` | `Enum.EasingStyle` member name |
| `TWEEN_EASING_DIRECTION` | `string` | `"Out"` | `Enum.EasingDirection` member name |
| `BUTTON_CAN_AFFORD` | `Color3` | Green `(80, 180, 100)` | Button colour when player can afford |
| `BUTTON_CANNOT_AFFORD` | `Color3` | Red `(180, 80, 80)` | Button colour when player cannot afford |
| `BUTTON_MAXED` | `Color3` | Purple `(100, 100, 160)` | Button colour when upgrade is at max level |
| `FANFARE_DURATION` | `number` | `3.0` | Seconds the prestige fanfare overlay remains visible |

---

## 12. Remote Events & Functions

All remotes are created server-side and fetched client-side automatically when the relevant Remotes module is required. **Never create or destroy remotes outside of the Remotes modules.**

### CurrencyRemotes (folder: `ReplicatedStorage/CurrencyRemotes`)

| Remote | Class | Direction | Args | Returns |
|--------|-------|-----------|------|---------|
| `CurrencyChanged` | `RemoteEvent` | Server → Client | `(currencyId, newAmount, delta)` | — |
| `GetCurrency` | `RemoteFunction` | Client → Server | `(currencyId)` | `number` |
| `RequestSpend` | `RemoteFunction` | Client → Server | `(currencyId, amount)` | `(boolean, number)` |

### UpgradeRemotes (folder: `ReplicatedStorage/UpgradeRemotes`)

| Remote | Class | Direction | Args | Returns |
|--------|-------|-----------|------|---------|
| `UpgradesSync` | `RemoteEvent` | Server → Client | `({ [upgradeId]: level })` | — |
| `UpgradePurchased` | `RemoteEvent` | Server → Client | `(upgradeId, newLevel, nextCost)` | — |
| `RequestPurchase` | `RemoteFunction` | Client → Server | `(upgradeId)` | `(boolean, string, number)` |
| `GetUpgradeLevel` | `RemoteFunction` | Client → Server | `(upgradeId)` | `number` |

### PrestigeRemotes (folder: `ReplicatedStorage/PrestigeRemotes`)

| Remote | Class | Direction | Args | Returns |
|--------|-------|-----------|------|---------|
| `PrestigeSync` | `RemoteEvent` | Server → Client | `(level, multiplier)` | — |
| `PrestigeCompleted` | `RemoteEvent` | Server → Client | `(newLevel, pointsEarned)` | — |
| `RequestPrestige` | `RemoteFunction` | Client → Server | `()` | `(boolean, string, number, number)` |
| `GetPrestigeInfo` | `RemoteFunction` | Client → Server | `()` | `(level, multiplier, pointsIfNow, canPrestige)` |

---

## 13. Migration Guide

Schema migrations let you change the save format without breaking existing player data. The system chains migration functions automatically — you only write the delta between two versions.

### How it works

1. SaveService reads `data._version` from the DataStore document.
2. It walks `SaveConfig.Migrations` from `savedVersion` to `CURRENT_SCHEMA_VERSION - 1`, calling each migration function in order.
3. Each function receives the data table and **must return** the modified table.
4. The `_version` stamp is incremented automatically after each step regardless of whether a migration function existed for that step.

### Step-by-step: Adding a new migration

**Scenario:** You are adding a new `"Diamonds"` currency in version 2 and need all existing players to start with 10 Diamonds.

**Step 1:** Add the new currency to `CurrencyConfig.lua`.

```lua
{
    id          = "Diamonds",
    displayName = "Diamonds",
    cap         = 1_000,
    startAmount = 10,   -- new players get 10 on first join
    passiveRate = 0,
    icon        = "💠",
},
```

**Step 2:** Increment `CURRENT_SCHEMA_VERSION` in `SaveConfig.lua`.

```lua
CURRENT_SCHEMA_VERSION = 2,   -- was 1
```

**Step 3:** Add the migration entry to `SaveConfig.Migrations`.

```lua
Migrations = {
    [1] = function(data)
        -- Existing players start with 10 Diamonds to match new startAmount
        if data.currencies then
            data.currencies["Diamonds"] = data.currencies["Diamonds"] or 10
        end
        return data
    end,
},
```

**That's it.** On the next server start:
- New players receive a fresh `DEFAULT_DATA` with `_version = 2` and `currencies.Diamonds = 10` (from `startAmount`).
- Existing players with `_version = 1` have migration `[1]` applied, giving them 10 Diamonds, then their document is stamped `_version = 2`.
- Players already at `_version = 2` are loaded with no migrations applied.

### Rules and gotchas

| Rule | Reason |
|------|--------|
| Never modify an existing migration function | Players who already ran it would not be re-migrated |
| Always return the `data` table from a migration | A `nil` return causes SaveService to skip the step with a warning |
| Keep migration functions self-contained | Don't call service methods — work only with the raw table |
| A saved version newer than `CURRENT_SCHEMA_VERSION` is loaded as-is | Protects against code rollbacks silently corrupting newer saves |

---

## 14. Common Patterns

### Pattern 1 — Passive income wiring

Passive income flows through three layers: the rate defined in `CurrencyConfig`, the per-player multiplier set by `PrestigeService` and upgrade effects, and the tick driven by `TickService`.

```lua
-- In CurrencyConfig: define the base rate
{ id = "Gold", passiveRate = 1, ... }

-- In ServerMain: wire TickService → CurrencyService (done automatically by CurrencyService.new)
-- CurrencyService:ProcessPassiveIncome is bound to the "Passive" group internally.

-- After prestige: set the floor multiplier
currency:SetMultiplier(player, prestige:GetMultiplier(player))
-- e.g. prestige level 3 → multiplier = 1.0 + 0.5 × 3 = 2.5

-- After loading upgrades: stack upgrade multipliers on top
upgrades:ApplyEffects(player)
-- OnEffectApplied fires for GoldRush → ServerMain compounds the value:
upgrades:OnEffectApplied(function(player, id, effectType, value, currencyId)
    if effectType == UpgradeConfig.EffectTypes.PassiveMultiplier then
        local base = prestige:GetMultiplier(player)
        currency:SetMultiplier(player, base * value)
    end
end)
```

### Pattern 2 — Prestige reset order

Getting the order wrong causes stale multipliers or missing carry-over data. The canonical sequence:

```lua
prestige:OnPrestige(function(player, newLevel, carryOver)
    -- 1. Read carry-over upgrade levels FIRST (before UnloadPlayer destroys them)
    local upgradeCarryOver = {}
    for _, upgradeId in PrestigeConfig.carryOver.upgrades do
        upgradeCarryOver[upgradeId] = upgrades:GetLevel(player, upgradeId)
    end

    -- 2. Tear down (order matters: upgrades before currency)
    upgrades:UnloadPlayer(player)
    currency:UnloadPlayer(player)

    -- 3. Rebuild with carry-overs
    --    carryOver.currencies was populated by PrestigeService before this callback
    currency:LoadPlayer(player, carryOver.currencies)
    upgrades:LoadPlayer(player, upgradeCarryOver)

    -- 4. Re-attach upgrade multipliers (fires OnEffectApplied for each owned upgrade)
    upgrades:ApplyEffects(player)

    -- PrestigeService then sets the prestige multiplier as the authoritative floor
    -- (steps 5–9 in the lifecycle) — do not set it here.
end)
```

### Pattern 3 — Adding a new currency

1. **Add definition** in `CurrencyConfig.lua`:

```lua
{
    id          = "EnergyShards",
    displayName = "Energy Shards",
    cap         = 500,
    startAmount = 0,
    passiveRate = 0,
    icon        = "⚡",
},
```

2. **Add a migration** so existing players get the new key (see [Migration Guide](#13-migration-guide)).

3. **Bind a UI label** in `ClientMain.lua`:

```lua
ui:BindLabel(playerGui.HUD.EnergyLabel, "EnergyShards")
```

4. **(Optional)** Add an upgrade that targets the new currency in `UpgradeConfig.lua`.

No changes to any service are required.

---

### Pattern 4 — Adding a new upgrade

1. **Add definition** in `UpgradeConfig.lua`:

```lua
{
    id            = "ShardCollector",
    name          = "Shard Collector",
    description   = "Passively collect Energy Shards. +%d/tick.",
    cost          = { currencyId = "Gold", amount = 2_000 },
    costScaling   = 1.7,
    effectType    = EffectTypes.PassiveFlat,
    effectValue   = 1,
    effectScaling = 1,
    maxLevel      = 25,
    currencyId    = "EnergyShards",
    prerequisites = { "GoldMine" },
},
```

2. **Handle the effect** in the `OnEffectApplied` callback in `ServerMain.lua` if the effect type requires it. `PassiveFlat` effects require an extension to `ProcessPassiveIncome` — add a per-player flat bonus accumulator to `CurrencyService` or track it in your own system.

3. **Bind a UI button** in `ClientMain.lua`:

```lua
ui:BindUpgradeButton(playerGui.HUD.ShardCollectorButton, "ShardCollector")
```

No changes to any service are required for `PassiveMultiplier`, `CapIncrease`, or `CostReduction` effect types — just handle them in your `OnEffectApplied` wiring.

---

### Pattern 5 — Admin / server commands

All service methods are safe to call from a server-side admin system (e.g. a `RemoteFunction` protected by a UserId allowlist):

```lua
-- Award premium currency to a player
currency:Add(targetPlayer, "Gems", 100)

-- Force-unlock an upgrade level
local ok, reason, level = upgrades:Purchase(targetPlayer, "GoldRush")
print(ok, reason, level)

-- Check prestige eligibility
local canDo, reason = prestige:CanPrestige(targetPlayer)

-- Wipe a player's DataStore entry (data-deletion request)
save:DeletePlayer(targetPlayer)
```

---

### Pattern 6 — Reacting to balance milestones

Use `CurrencyService.Changed` to watch for thresholds without polling:

```lua
currency.Changed.Event:Connect(function(player, currencyId, newAmount, delta)
    if currencyId == "Gold" and newAmount >= 10_000 and (newAmount - delta) < 10_000 then
        -- Player just crossed 10K Gold for the first time this session
        showPrestigeUnlockNotification(player)
    end
end)
```

---

### Pattern 7 — Showing upgrade tooltips on the client

`GetPrestigeInfo` and `GetUpgradeLevel` are available as `RemoteFunction` calls for richer UI:

```lua
-- In a ClientScript attached to a tooltip frame:
local level, multiplier, pointsIfNow, canPrestige =
    PrestigeRemotes.GetPrestigeInfo:InvokeServer()

tooltipLabel.Text = string.format(
    "Prestige %d — ×%.1f income\nPrestige now for %d points",
    level, multiplier, pointsIfNow
)
prestigeButton.Active = canPrestige
```

For upgrade costs, use the data already in `UpgradeConfig` on the client — no server round-trip needed:

```lua
local def      = UpgradeConfig.Map["GoldMine"]
local myLevel  = UpgradeRemotes.GetUpgradeLevel:InvokeServer("GoldMine")
local nextCost = math.floor(def.cost.amount * (def.costScaling ^ myLevel))
costLabel.Text = ui:FormatNumber(nextCost) .. " " .. def.cost.currencyId
```
