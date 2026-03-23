--[[
================================================================================
  PrestigeConfig
  Location: ReplicatedStorage/Shared/Config/PrestigeConfig.lua

  Single source of truth for all prestige rules. PrestigeService reads this;
  UIService reads it for tooltips and requirement display. Never put logic here.

  ── PointsFormula ────────────────────────────────────────────────────────────

  Prestige Points earned is derived from the player's Gold at the moment of
  prestige using the formula:

      points = floor(formulaCoefficient × (Gold / formulaScale) ^ formulaExponent)

  This is the classic incremental game "soft currency from hard currency" curve.
  Tuning guide:
    • formulaScale    — raise to make points rarer (shift curve right)
    • formulaExponent — raise to reward later prestiges more (steeper curve)
    • formulaCoefficient — flat multiplier on the whole result

  Example at default values (coeff=1, scale=1000, exp=0.5):
      Gold 1,000   → floor(1 × (1)^0.5)     = 1   point
      Gold 4,000   → floor(1 × (4)^0.5)     = 2   points
      Gold 10,000  → floor(1 × (10)^0.5)    = 3   points
      Gold 100,000 → floor(1 × (100)^0.5)   = 10  points
      Gold 1,000,000 → floor(1 × (1000)^0.5)= 31  points

  ── MultiplierFormula ─────────────────────────────────────────────────────────

  Passive income multiplier from prestige level P:

      multiplier = baseMultiplier + (multiplierPerLevel × P)

  Example at defaults (base=1.0, perLevel=0.5):
      P=0 → ×1.0   P=1 → ×1.5   P=2 → ×2.0   P=10 → ×6.0

  ── CarryOver ────────────────────────────────────────────────────────────────

  currencies  — list of currency ids whose balances SURVIVE the reset
  upgrades    — list of upgrade ids whose levels SURVIVE the reset
  (everything not listed is wiped back to its startAmount / 0)

================================================================================
--]]

-- ── Types ─────────────────────────────────────────────────────────────────────

export type PointsFormula = {
    coefficient: number, -- flat multiplier on final result
    scale:       number, -- divisor applied to Gold before exponent
    exponent:    number, -- power the scaled gold is raised to
}

export type MultiplierFormula = {
    baseMultiplier:    number, -- multiplier at prestige level 0 (always 1.0)
    multiplierPerLevel: number, -- additive bonus per prestige level
}

export type CarryOverRules = {
    currencies: { string }, -- currency ids that survive reset
    upgrades:   { string }, -- upgrade ids that survive reset
}

export type PrestigeConfig = {
    -- The currency + amount required to trigger prestige
    costCurrencyId:   string,
    costAmount:       number,

    -- The currency that prestige points are deposited into
    rewardCurrencyId: string,

    -- Point earnings formula
    pointsFormula:    PointsFormula,

    -- Passive income multiplier scaling
    multiplierFormula: MultiplierFormula,

    -- Carry-over rules
    carryOver:        CarryOverRules,

    -- Minimum Gold required to even attempt prestige (floor gate)
    minimumGoldRequired: number,
}

-- ── Config Values ─────────────────────────────────────────────────────────────

local PrestigeConfig: PrestigeConfig = {

    costCurrencyId   = "Gold",
    costAmount       = 10_000,      -- must have ≥ 10,000 Gold to prestige

    rewardCurrencyId = "PrestigePoints",

    -- Points earned = floor(1 × (Gold / 1000) ^ 0.5)
    pointsFormula = {
        coefficient = 1,
        scale       = 1_000,
        exponent    = 0.5,
    },

    -- Multiplier = 1.0 + (0.5 × prestigeLevel)
    multiplierFormula = {
        baseMultiplier     = 1.0,
        multiplierPerLevel = 0.5,
    },

    -- Prestige Points and the GemVault upgrade level survive every reset.
    -- Everything else (Gold, Gems, all other upgrades) is wiped.
    carryOver = {
        currencies = { "PrestigePoints" },
        upgrades   = { "GemVault" },
    },

    minimumGoldRequired = 10_000,   -- must match or exceed costAmount
}

return PrestigeConfig
