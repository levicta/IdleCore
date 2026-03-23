--[[
================================================================================
  SaveConfig
  Location: ReplicatedStorage/Shared/Config/SaveConfig.lua

  Single source of truth for every tunable in the save system.
  SaveService reads this at require-time — never hardcode these values there.

  ── Schema Versioning ─────────────────────────────────────────────────────────

  Every saved document is stamped with { _version = CURRENT_SCHEMA_VERSION }.
  On load, SaveService walks the Migrations table from the saved version up to
  the current one, applying each migration function in order.

  To add a migration:
    1. Increment CURRENT_SCHEMA_VERSION by 1.
    2. Add a new entry to Migrations keyed by the OLD version number.
       The function receives the raw data table and must return the mutated
       (or replaced) table at the new version.

  Example — rename "gold" key to "Gold" in version 2:
    [1] = function(data)
        if data.currencies and data.currencies.gold then
            data.currencies.Gold = data.currencies.gold
            data.currencies.gold = nil
        end
        return data
    end,

  ── Auto-Save ─────────────────────────────────────────────────────────────────

  SaveService subscribes to TickService under the group named AUTO_SAVE_GROUP.
  The group is registered with interval = AUTO_SAVE_INTERVAL seconds.
  Only players whose _dirty flag is true are written on each auto-save tick,
  so the DataStore call count scales with actual state changes, not player count.

  ── Retry / Backoff ───────────────────────────────────────────────────────────

  On a DataStore failure, SaveService retries up to MAX_RETRIES times using
  exponential backoff:

      delay = RETRY_BASE_DELAY × (RETRY_BACKOFF_FACTOR ^ attempt)

  e.g. with base=1, factor=2: delays are 1s, 2s, 4s, 8s … (capped by Roblox
  DataStore throttling; the service yields between attempts via task.wait).

================================================================================
--]]

-- ── Types ─────────────────────────────────────────────────────────────────────

-- A migration function takes the old raw save data and returns upgraded data.
export type MigrationFn = (data: { [string]: any }) -> { [string]: any }

export type SaveConfigType = {
    -- DataStore name. Changing this abandons all existing saves — be careful.
    DATASTORE_NAME: string,

    -- Prefix prepended to every player key: "<PREFIX><UserId>"
    KEY_PREFIX: string,

    -- Current schema version stamped into every save document.
    CURRENT_SCHEMA_VERSION: number,

    -- Migration functions keyed by the FROM-version (integer).
    -- Entry [N] upgrades a document at version N to version N+1.
    Migrations: { [number]: MigrationFn },

    -- Seconds between auto-save ticks (passed to TickService:RegisterGroup).
    AUTO_SAVE_INTERVAL: number,

    -- TickService group name used for the auto-save loop.
    AUTO_SAVE_GROUP: string,

    -- Maximum number of DataStore retries per operation before giving up.
    MAX_RETRIES: number,

    -- Base delay (seconds) for the first retry.
    RETRY_BASE_DELAY: number,

    -- Exponential factor applied on each successive retry.
    RETRY_BACKOFF_FACTOR: number,

    -- Seconds given to BindToClose to flush all dirty saves before shutdown.
    -- Roblox enforces a hard ~30s limit; keep this comfortably below that.
    BIND_TO_CLOSE_TIMEOUT: number,

    -- Default save document returned when a player has no existing DataStore
    -- entry. All sub-tables should mirror the shape that service Serialize
    -- methods produce, so LoadPlayer receives a well-typed initial value.
    DEFAULT_DATA: {
        _version:   number,
        currencies: { [string]: number },
        upgrades:   { [string]: number },
        prestige:   { level: number },
    },
}

-- ── Config Values ─────────────────────────────────────────────────────────────

local SaveConfig: SaveConfigType = {

    DATASTORE_NAME          = "IncrementalFramework_v1",
    KEY_PREFIX              = "Player_",

    CURRENT_SCHEMA_VERSION  = 1,

    --[[
        Migrations table.
        Empty for a brand-new game — add entries here as the schema evolves.

        Format:
            [fromVersion] = function(data) ... return data end,

        Each function is responsible for upgrading data from `fromVersion`
        to `fromVersion + 1`. SaveService chains them automatically.
    --]]
    Migrations = {
        -- Example (disabled): version 0 → 1, no structural changes needed.
        -- [0] = function(data)
        --     return data
        -- end,
    },

    AUTO_SAVE_INTERVAL      = 60,          -- auto-save every 60 seconds
    AUTO_SAVE_GROUP         = "AutoSave",  -- TickService group name

    MAX_RETRIES             = 5,
    RETRY_BASE_DELAY        = 1,           -- seconds
    RETRY_BACKOFF_FACTOR    = 2,           -- doubles each attempt

    BIND_TO_CLOSE_TIMEOUT   = 25,          -- seconds; keep well under Roblox's 30s hard limit

    -- Shape that new players start with; mirrors what all Serialize methods return.
    DEFAULT_DATA = {
        _version   = 1,
        currencies = {},
        upgrades   = {},
        prestige   = { level = 0 },
    },
}

return SaveConfig
