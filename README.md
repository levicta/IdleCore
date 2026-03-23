# IdleCore

> A modular, production-ready incremental game framework for Roblox Studio.

IdleCore gives you the complete server/client infrastructure for an incremental game — currencies, upgrades, prestige, persistence, and UI — so you can focus on designing your game, not rebuilding boilerplate.

---

## Features

- **TickService** — frame-rate-independent heartbeat driving all passive income and auto-save
- **CurrencyService** — server-authoritative multi-currency wallet with passive income and multipliers
- **UpgradeService** — tiered upgrades with exponential cost scaling, prerequisites, and effect callbacks
- **PrestigeService** — full reset lifecycle with carry-overs, points formula, and compounding multipliers
- **SaveService** — DataStore persistence with schema versioning, migrations, dirty-flag writes, and graceful shutdown flush
- **UIService** — reactive client-side displays, animated number counters, and auto-managed upgrade buttons
- Zero cross-service `require()` coupling — everything is wired through callbacks in `ServerMain`

---

## Folder Structure

```
game/
├── ServerScriptService/
│   └── ServerMain              ← Bootstrap Script
│
├── ServerStorage/
│   └── Framework/              ← Server-only (clients cannot require these)
│       ├── TickService.lua
│       ├── CurrencyService.lua
│       ├── UpgradeService.lua
│       ├── PrestigeService.lua
│       └── SaveService.lua
│
├── ReplicatedStorage/
│   └── Shared/
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
        ├── ClientMain          ← Bootstrap LocalScript
        └── UIService.lua
```

---

## Quick Start

**Server** (`ServerScriptService/ServerMain`):

```lua
local ServerStorage = game:GetService("ServerStorage")
local Players       = game:GetService("Players")
local Framework     = ServerStorage.Framework

local TickService     = require(Framework.TickService)
local SaveService     = require(Framework.SaveService)
local CurrencyService = require(Framework.CurrencyService)
local UpgradeService  = require(Framework.UpgradeService)
local PrestigeService = require(Framework.PrestigeService)

-- 1. Construct in dependency order
local tick     = TickService.new()
local save     = SaveService.new(tick)
local currency = CurrencyService.new(tick)
local upgrades = UpgradeService.new(currency)
local prestige = PrestigeService.new(currency)

-- 2. Wire save pipeline
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

**Client** (`StarterPlayerScripts/ClientMain`):

```lua
local UIService = require(script.Parent.UIService)
local ui = UIService.new()

local playerGui = game.Players.LocalPlayer.PlayerGui

-- Bind a currency label — updates live with a tween on every server change
ui:BindLabel(playerGui.HUD.GoldLabel, "Gold")

-- Bind an upgrade button — colour, cost label, and click handler auto-managed
ui:BindUpgradeButton(playerGui.HUD.GoldMineButton, "GoldMine")

-- Register prestige overlay screen
ui:RegisterScreen("PrestigeFanfare", playerGui.PrestigeFanfare)
```

Add currencies in `CurrencyConfig`, upgrades in `UpgradeConfig`, and prestige rules in `PrestigeConfig`. No service code changes required.

---

## Service Dependency Map

```
ServerMain (wires everything)
│
├── TickService          (no dependencies)
│     └── heartbeat → CurrencyService (passive income)
│                  → SaveService      (auto-save)
│
├── CurrencyService      (depends on: TickService)
│     └── currency ops → UpgradeService (cost deduction, multipliers)
│                      → PrestigeService (gold read, points award)
│
├── UpgradeService       (depends on: CurrencyService)
│     └── OnEffectApplied callbacks → ServerMain → CurrencyService
│
├── PrestigeService      (depends on: CurrencyService)
│     └── OnPrestige callbacks → ServerMain
│           → UpgradeService.UnloadPlayer / LoadPlayer / ApplyEffects
│           → CurrencyService.UnloadPlayer / LoadPlayer
│
└── SaveService          (depends on: TickService)
      └── OnLoaded / OnBeforeSave callbacks → all services

UIService  (client-only — reads Remotes, writes nothing to server)
```

**Decoupling matrix** — ✓ means the row service directly calls the column:

|                  | Tick | Currency | Upgrade | Prestige | Save | UI |
|------------------|:----:|:--------:|:-------:|:--------:|:----:|:--:|
| **TickService**  | —    | ✗        | ✗       | ✗        | ✗    | ✗  |
| **CurrencyService** | ✓ | —       | ✗       | ✗        | ✗    | ✗  |
| **UpgradeService** | ✗  | ✓        | —       | ✗        | ✗    | ✗  |
| **PrestigeService** | ✗ | ✓        | ✗ (cb)  | —        | ✗    | ✗  |
| **SaveService**  | ✓    | ✗ (cb)   | ✗ (cb)  | ✗ (cb)   | —    | ✗  |
| **UIService**    | ✗    | ✗ (remote) | ✗ (remote) | ✗ (remote) | ✗ | — |

---

## Data Schema

Every player's save is stored under `Player_<UserId>` in the `IncrementalFramework_v1` DataStore:

```
SaveDocument {
    _version   : number               -- schema version (currently 1)
    currencies : { [string]: number } -- currencyId → balance
    upgrades   : { [string]: number } -- upgradeId  → level (0 = not purchased)
    prestige   : {
        level  : number               -- prestige tier (0 = never prestiged)
    }
}
```

Example document (prestige 2, some upgrades owned):

```json
{
  "_version": 1,
  "currencies": { "Gold": 45200, "Gems": 12, "PrestigePoints": 7 },
  "upgrades":   { "GoldMine": 5, "GoldRush": 2, "GemVault": 1 },
  "prestige":   { "level": 2 }
}
```

---

## Adding a New Currency

1. Add a definition to `CurrencyConfig.lua`:

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

2. Add a migration so existing players receive the new key (see [Migration Guide](#migration-guide)).

3. Bind a UI label in `ClientMain`:

```lua
ui:BindLabel(playerGui.HUD.EnergyLabel, "EnergyShards")
```

No service changes required.

---

## Adding a New Upgrade

1. Add a definition to `UpgradeConfig.lua`:

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

2. Handle the effect in `OnEffectApplied` in `ServerMain` if needed.

3. Bind a UI button in `ClientMain`:

```lua
ui:BindUpgradeButton(playerGui.HUD.ShardCollectorButton, "ShardCollector")
```

---

## Migration Guide

Schema migrations live entirely in `SaveConfig.Migrations`. To add a new one:

**1.** Increment `CURRENT_SCHEMA_VERSION` in `SaveConfig.lua`:
```lua
CURRENT_SCHEMA_VERSION = 2,  -- was 1
```

**2.** Add the migration function:
```lua
Migrations = {
    [1] = function(data)
        data.currencies["Diamonds"] = data.currencies["Diamonds"] or 10
        return data
    end,
},
```

On the next server start, existing players at `_version = 1` have the migration applied and are stamped to `_version = 2`. New players start at `_version = 2` with the new defaults. Never modify an existing migration — players who already ran it will not be re-migrated.

---

## Common Patterns

**Passive income wiring:**
```lua
-- CurrencyConfig: set base rate
{ id = "Gold", passiveRate = 1, ... }

-- After prestige: set floor multiplier
currency:SetMultiplier(player, prestige:GetMultiplier(player))

-- After loading upgrades: compound upgrade multipliers on top
upgrades:ApplyEffects(player)
upgrades:OnEffectApplied(function(player, id, effectType, value)
    if effectType == UpgradeConfig.EffectTypes.PassiveMultiplier then
        currency:SetMultiplier(player, prestige:GetMultiplier(player) * value)
    end
end)
```

**Reacting to balance milestones:**
```lua
currency.Changed.Event:Connect(function(player, currencyId, newAmount, delta)
    if currencyId == "Gold" and newAmount >= 10_000 and (newAmount - delta) < 10_000 then
        showPrestigeUnlockHint(player)
    end
end)
```

**Admin commands:**
```lua
currency:Add(targetPlayer, "Gems", 100)
local ok, reason, level = upgrades:Purchase(targetPlayer, "GoldMine")
save:DeletePlayer(targetPlayer)  -- GDPR / data-deletion requests
```

---

## API Summary

| Service | Key Methods |
|---------|-------------|
| `TickService` | `new` `Start` `Stop` `RegisterGroup` `Bind` `Unbind` `GetTick` |
| `CurrencyService` | `LoadPlayer` `UnloadPlayer` `Get` `Set` `Add` `Subtract` `SetMultiplier` `Serialize` |
| `UpgradeService` | `LoadPlayer` `UnloadPlayer` `Purchase` `CanAfford` `GetLevel` `GetEffect` `ApplyEffects` `OnEffectApplied` `Serialize` |
| `PrestigeService` | `LoadPlayer` `UnloadPlayer` `CanPrestige` `Prestige` `GetLevel` `GetMultiplier` `OnPrestige` `Serialize` |
| `SaveService` | `LoadPlayer` `SavePlayer` `DeletePlayer` `OnLoaded` `OnBeforeSave` `BindToClose` |
| `UIService` | `BindLabel` `UnbindLabel` `BindUpgradeButton` `FormatNumber` `RegisterScreen` `UpdateCurrencyDisplay` `Destroy` |

---

## Language & Compatibility

- **Luau** — strict-mode compatible with full type annotations
- **Roblox Studio** — tested against the current live client
- No external dependencies — only Roblox services (`DataStoreService`, `RunService`, `Players`)

---

*IdleCore — built for developers who want to ship a game, not maintain a framework.*
