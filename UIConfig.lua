--[[
================================================================================
  UIConfig
  Location: ReplicatedStorage/Shared/Config/UIConfig.lua

  Single source of truth for every UI presentation constant.
  UIService reads this at require-time — never hardcode these values there.

  ── Number Formatting ─────────────────────────────────────────────────────────

  Numbers pass through three formatting tiers in order:

    1. Raw          0 – RAW_THRESHOLD (default 999)
                    Displayed as plain integers: "0", "42", "999"

    2. Suffixed     1,000 – SCIENTIFIC_THRESHOLD-1
                    Divided by the appropriate tier divisor and suffixed:
                    "1.00K", "3.50M", "12.8B", etc.
                    Decimal places are controlled per-tier by SUFFIX_DECIMALS.

    3. Scientific   ≥ SCIENTIFIC_THRESHOLD (default 1e15)
                    Displayed in Lua's %g-style scientific notation:
                    "1.23e+15", "4.56e+18", etc.
                    Decimal places controlled by SCIENTIFIC_DECIMALS.

  ── Suffix Table ─────────────────────────────────────────────────────────────

  SUFFIXES is an ordered array of { divisor, suffix } pairs, sorted ascending
  by divisor. UIService walks the list in reverse to find the largest tier that
  fits the number. Add new tiers here without touching UIService.

  ── Tween Counters ───────────────────────────────────────────────────────────

  Currency labels animate from their old value to the new one over
  TWEEN_DURATION seconds using TWEEN_EASING_STYLE / TWEEN_EASING_DIRECTION.
  Set TWEEN_DURATION to 0 to disable animation entirely.

  ── Purchase Button Colours ──────────────────────────────────────────────────

  BUTTON_CAN_AFFORD and BUTTON_CANNOT_AFFORD define the ImageColor3 (or
  BackgroundColor3) applied to BindUpgradeButton-managed buttons depending on
  whether the local player can currently afford the next level. BUTTON_MAXED
  is applied when the upgrade is at its maximum level.

================================================================================
--]]

-- ── Types ─────────────────────────────────────────────────────────────────────

export type SuffixTier = {
    divisor: number,  -- value is divided by this before display
    suffix:  string,  -- appended after the formatted number
}

export type UIConfigType = {
    -- ── Number formatting ──────────────────────────────────────────────────

    -- Numbers ≤ this value are displayed raw (no suffix, no decimals).
    RAW_THRESHOLD: number,

    -- Numbers ≥ this value use scientific notation instead of suffixes.
    -- Keep this just above the largest suffix tier's divisor × 1000.
    SCIENTIFIC_THRESHOLD: number,

    -- Ordered suffix tiers (smallest divisor first).
    -- UIService walks in reverse to pick the largest fitting tier.
    SUFFIXES: { SuffixTier },

    -- Decimal places per suffix tier, keyed by suffix string.
    -- If a suffix is not listed here, SUFFIX_DECIMALS_DEFAULT is used.
    SUFFIX_DECIMALS: { [string]: number },

    -- Fallback decimal places for any suffix not in SUFFIX_DECIMALS.
    SUFFIX_DECIMALS_DEFAULT: number,

    -- Decimal places for scientific notation display.
    SCIENTIFIC_DECIMALS: number,

    -- ── Counter tween ──────────────────────────────────────────────────────

    -- Duration (seconds) for the label counter animation.
    -- Set to 0 to snap labels to their new value instantly.
    TWEEN_DURATION: number,

    -- TweenService EasingStyle name (must match Enum.EasingStyle member names).
    TWEEN_EASING_STYLE: string,

    -- TweenService EasingDirection name (must match Enum.EasingDirection).
    TWEEN_EASING_DIRECTION: string,

    -- ── Upgrade button colours ─────────────────────────────────────────────

    -- Applied when the player can afford the next upgrade level.
    BUTTON_CAN_AFFORD: Color3,

    -- Applied when the player cannot afford the next level.
    BUTTON_CANNOT_AFFORD: Color3,

    -- Applied when the upgrade is at maximum level.
    BUTTON_MAXED: Color3,

    -- ── Prestige fanfare ──────────────────────────────────────────────────

    -- How long (seconds) the prestige fanfare overlay stays visible.
    FANFARE_DURATION: number,
}

-- ── Config Values ─────────────────────────────────────────────────────────────

local UIConfig: UIConfigType = {

    RAW_THRESHOLD        = 999,
    SCIENTIFIC_THRESHOLD = 1e15,

    -- Suffix tiers — extend this list freely; UIService needs no changes.
    SUFFIXES = {
        { divisor = 1e3,  suffix = "K"  },   -- Thousand
        { divisor = 1e6,  suffix = "M"  },   -- Million
        { divisor = 1e9,  suffix = "B"  },   -- Billion
        { divisor = 1e12, suffix = "T"  },   -- Trillion
        { divisor = 1e15, suffix = "Qa" },   -- Quadrillion  (bumped to sci above this)
        { divisor = 1e18, suffix = "Qi" },   -- Quintillion
        { divisor = 1e21, suffix = "Sx" },   -- Sextillion
        { divisor = 1e24, suffix = "Sp" },   -- Septillion
        { divisor = 1e27, suffix = "Oc" },   -- Octillion
        { divisor = 1e30, suffix = "No" },   -- Nonillion
        { divisor = 1e33, suffix = "Dc" },   -- Decillion
    },

    -- More decimal places for lower tiers where precision matters more.
    SUFFIX_DECIMALS = {
        K  = 2,   -- "1.23K"
        M  = 2,   -- "3.50M"
        B  = 2,   -- "12.8B" → will round
        T  = 2,
        Qa = 2,
        Qi = 2,
        Sx = 2,
        Sp = 2,
        Oc = 2,
        No = 2,
        Dc = 2,
    },

    SUFFIX_DECIMALS_DEFAULT = 2,
    SCIENTIFIC_DECIMALS     = 3,   -- "1.234e+15"

    -- ── Tween ──────────────────────────────────────────────────────────────

    TWEEN_DURATION          = 0.35,    -- seconds; feels snappy without being jarring
    TWEEN_EASING_STYLE      = "Quad",
    TWEEN_EASING_DIRECTION  = "Out",

    -- ── Button colours ────────────────────────────────────────────────────

    BUTTON_CAN_AFFORD    = Color3.fromRGB(80,  180, 100),  -- green
    BUTTON_CANNOT_AFFORD = Color3.fromRGB(180, 80,  80 ),  -- red
    BUTTON_MAXED         = Color3.fromRGB(100, 100, 160),  -- muted purple

    -- ── Prestige fanfare ──────────────────────────────────────────────────

    FANFARE_DURATION = 3.0,
}

return UIConfig
