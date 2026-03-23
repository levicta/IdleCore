--[[
================================================================================
  CurrencyConfig
  Location: ReplicatedStorage/Shared/Config/CurrencyConfig.lua

  Single source of truth for every currency in the game.
  Both the server (CurrencyService) and client (UIService) read from here —
  never duplicate these definitions elsewhere.

  ── Fields per CurrencyDefinition ───────────────────────────────────────────

  id          string   — unique key used throughout the framework ("Gold", etc.)
  displayName string   — human-readable label shown in UI
  cap         number   — maximum storable amount (math.huge = uncapped)
  startAmount number   — value given to new players on first join
  passiveRate number   — units awarded per tick (0 = no passive income)
  icon        string?  — optional asset id / emoji for UI display

================================================================================
--]]

export type CurrencyDefinition = {
    id: string,
    displayName: string,
    cap: number,
    startAmount: number,
    passiveRate: number,
    icon: string?,
}

local CurrencyConfig = {

    -- ── Currency Definitions ─────────────────────────────────────────────────

    Currencies = {

        {
            id          = "Gold",
            displayName = "Gold",
            cap         = math.huge,   -- uncapped; BigNum handles display
            startAmount = 0,
            passiveRate = 1,           -- +1 Gold per tick (base, before multipliers)
            icon        = "💰",
        },

        {
            id          = "Gems",
            displayName = "Gems",
            cap         = 10_000,      -- hard cap; premium currency example
            startAmount = 0,
            passiveRate = 0,           -- Gems are not earned passively
            icon        = "💎",
        },

        {
            id          = "PrestigePoints",
            displayName = "Prestige Points",
            cap         = math.huge,
            startAmount = 0,
            passiveRate = 0,           -- awarded only by PrestigeService
            icon        = "⭐",
        },

    } :: { CurrencyDefinition },

    -- ── Passive Income Global Multiplier ─────────────────────────────────────
    -- Applied to every currency's passiveRate each tick.
    -- PrestigeService will override this per-player at runtime.
    BasePassiveMultiplier = 1.0,

}

-- Build a quick lookup map: CurrencyConfig.Map["Gold"] -> CurrencyDefinition
-- Populated once at require-time so callers don't linear-scan the array.
CurrencyConfig.Map = {} :: { [string]: CurrencyDefinition }
for _, def in CurrencyConfig.Currencies do
    assert(
        CurrencyConfig.Map[def.id] == nil,
        string.format("[CurrencyConfig] Duplicate currency id: '%s'", def.id)
    )
    CurrencyConfig.Map[def.id] = def
end

return CurrencyConfig
