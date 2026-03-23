--[[
================================================================================
  UpgradeConfig
  Location: ReplicatedStorage/Shared/Config/UpgradeConfig.lua

  Defines every upgrade available in the game. Both the server (UpgradeService)
  and client (UIService) read from here. Never put upgrade logic in this file —
  only data.

  ── EffectType Registry ───────────────────────────────────────────────────────

  "PassiveMultiplier"   — multiplies a currency's passive income rate
                          value: multiplier applied on top of the base rate
                          currencyId: which currency is affected

  "PassiveFlat"         — adds a flat amount to a currency's passive income
                          value: units added per tick
                          currencyId: which currency is affected

  "CapIncrease"         — raises the storage cap for a currency
                          value: flat units added to the cap
                          currencyId: which currency is affected

  "CostReduction"       — reduces purchase costs across the board (future use)
                          value: multiplier applied to all costs (e.g. 0.9 = -10%)
                          currencyId: nil (global effect)

  ── Cost Scaling ─────────────────────────────────────────────────────────────

  cost.amount is the BASE cost (level 1).
  Each subsequent level costs:  floor(baseCost × costScaling ^ (level - 1))

  Example — goldMine at level 3:
      floor(100 × 1.5 ^ 2) = floor(100 × 2.25) = floor(225) = 225

  ── Fields per UpgradeDefinition ─────────────────────────────────────────────

  id           string          — unique key used throughout the framework
  name         string          — human-readable display name
  description  string          — tooltip / flavour text (may include %d for level)
  cost         CostDef         — { currencyId: string, amount: number }
  costScaling  number          — exponential multiplier per level (1.0 = flat cost)
  effectType   string          — one of the EffectType values above
  effectValue  number          — base effect magnitude at level 1
  effectScaling number         — how effectValue grows per level (additive)
                                 newValue = effectValue + effectScaling × (level - 1)
  maxLevel     number          — 0 = unlimited
  currencyId   string?         — target currency for currency-specific effects
  prerequisites { string }?   — list of upgrade ids that must be ≥ level 1 first

================================================================================
--]]

-- ── Types ─────────────────────────────────────────────────────────────────────

export type CostDef = {
    currencyId: string,
    amount: number,
}

export type UpgradeDefinition = {
    id:            string,
    name:          string,
    description:   string,
    cost:          CostDef,
    costScaling:   number,
    effectType:    string,
    effectValue:   number,
    effectScaling: number,
    maxLevel:      number,
    currencyId:    string?,
    prerequisites: { string }?,
}

-- ── Effect Type Constants (import these instead of magic strings) ──────────────

local EffectTypes = {
    PassiveMultiplier = "PassiveMultiplier",
    PassiveFlat       = "PassiveFlat",
    CapIncrease       = "CapIncrease",
    CostReduction     = "CostReduction",
}

-- ── Upgrade Definitions ───────────────────────────────────────────────────────

local Upgrades: { UpgradeDefinition } = {

    -- ── Gold Mine (tiered passive flat income) ────────────────────────────────
    {
        id            = "GoldMine",
        name          = "Gold Mine",
        description   = "Hire miners. +%d Gold per tick.",
        cost          = { currencyId = "Gold", amount = 100 },
        costScaling   = 1.5,   -- each level costs 50% more than the last
        effectType    = EffectTypes.PassiveFlat,
        effectValue   = 1,     -- +1 Gold/tick at level 1
        effectScaling = 1,     -- +1 more Gold/tick per additional level
        maxLevel      = 50,
        currencyId    = "Gold",
        prerequisites = nil,
    },

    -- ── Gold Multiplier (tiered passive multiplier) ───────────────────────────
    {
        id            = "GoldRush",
        name          = "Gold Rush",
        description   = "A surge of wealth. ×%.2f Gold income.",
        cost          = { currencyId = "Gold", amount = 500 },
        costScaling   = 2.0,   -- doubles each level — ramp up quickly
        effectType    = EffectTypes.PassiveMultiplier,
        effectValue   = 1.25,  -- ×1.25 at level 1
        effectScaling = 0.25,  -- +0.25× per additional level
        maxLevel      = 20,
        currencyId    = "Gold",
        prerequisites = { "GoldMine" }, -- must own at least 1 level of GoldMine
    },

    -- ── Gem Vault (cap increase, paid in Gems) ────────────────────────────────
    {
        id            = "GemVault",
        name          = "Gem Vault",
        description   = "Expand your vault. +%d Gem capacity.",
        cost          = { currencyId = "Gems", amount = 5 },
        costScaling   = 1.8,
        effectType    = EffectTypes.CapIncrease,
        effectValue   = 500,   -- +500 cap at level 1
        effectScaling = 500,   -- +500 cap per additional level
        maxLevel      = 18,    -- max 10,000 base + 18×500 = 19,000 cap total
        currencyId    = "Gems",
        prerequisites = nil,
    },

    -- ── Prestige Accelerator (unlimited, Gold cost) ───────────────────────────
    {
        id            = "PrestigeAccelerator",
        name          = "Prestige Accelerator",
        description   = "Speed toward your next prestige. +%d Prestige Point/tick.",
        cost          = { currencyId = "Gold", amount = 10_000 },
        costScaling   = 3.0,
        effectType    = EffectTypes.PassiveFlat,
        effectValue   = 1,
        effectScaling = 1,
        maxLevel      = 0,     -- unlimited
        currencyId    = "PrestigePoints",
        prerequisites = { "GoldRush" },
    },

}

-- ── Build Lookup Map ──────────────────────────────────────────────────────────

local Map: { [string]: UpgradeDefinition } = {}
for _, def in Upgrades do
    assert(
        Map[def.id] == nil,
        string.format("[UpgradeConfig] Duplicate upgrade id: '%s'", def.id)
    )
    Map[def.id] = def
end

-- ── Module ────────────────────────────────────────────────────────────────────

local UpgradeConfig = {
    Upgrades    = Upgrades,
    Map         = Map,
    EffectTypes = EffectTypes,
}

return UpgradeConfig
