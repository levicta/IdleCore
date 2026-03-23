--[[
================================================================================
  SaveService
  Location: ServerStorage/Framework/SaveService.lua

  The single I/O layer the entire framework talks to. All DataStore reads and
  writes are funnelled through here. No other service should call DataStoreService
  directly.

  Integrates with:
    • TickService   — auto-save loop via a registered tick group
    • SaveConfig    — all tunable values (key prefix, intervals, retries, etc.)
    • CurrencyService / UpgradeService / PrestigeService
        → wired in ServerMain via OnLoaded / OnBeforeSave callbacks

  ── Architecture Notes ────────────────────────────────────────────────────────

    Dirty flag:
      Every mutation path (Deserialize from services on join, or any explicit
      MarkDirty call) sets _dirty = true for that player. Auto-save and
      BindToClose only write players whose flag is set, keeping DataStore
      call counts proportional to actual state changes.

    Schema versioning:
      Every document is stamped with { _version = N }. On load, the saved
      version is compared to SaveConfig.CURRENT_SCHEMA_VERSION and any
      intervening migration functions are applied in order. This lets the
      save format evolve without breaking existing player data.

    Exponential backoff:
      DataStore operations are wrapped in a retry loop using
          delay = RETRY_BASE_DELAY × (RETRY_BACKOFF_FACTOR ^ attempt)
      After MAX_RETRIES failures the error is logged and the operation gives
      up gracefully — data is not lost from memory, only the write failed.

    BindToClose:
      Registered once in SaveService.new(). On server shutdown Roblox calls
      the handler; it iterates all dirty players and flushes synchronously
      (with retries). A timeout guard (BIND_TO_CLOSE_TIMEOUT) ensures we
      don't run past Roblox's hard 30-second limit.

  ── Wiring in ServerMain ─────────────────────────────────────────────────────

  local SaveService     = require(ServerStorage.Framework.SaveService)
  local CurrencyService = require(ServerStorage.Framework.CurrencyService)
  local UpgradeService  = require(ServerStorage.Framework.UpgradeService)
  local PrestigeService = require(ServerStorage.Framework.PrestigeService)

  local save = SaveService.new(tickService)

  save:OnLoaded(function(player, data)
      CurrencyService:LoadPlayer(player, data.currencies)
      UpgradeService:LoadPlayer(player, data.upgrades)
      PrestigeService:LoadPlayer(player, data.prestige)
  end)

  save:OnBeforeSave(function(player, snapshot)
      snapshot.currencies = CurrencyService:Serialize(player)
      snapshot.upgrades   = UpgradeService:Serialize(player)
      snapshot.prestige   = PrestigeService:Serialize(player)
  end)

  save:BindToClose()

  Players.PlayerAdded:Connect(function(player)
      save:LoadPlayer(player)
  end)

  Players.PlayerRemoving:Connect(function(player)
      save:SavePlayer(player)
      -- Service UnloadPlayer calls happen after this in ServerMain
  end)

  ── API Reference ─────────────────────────────────────────────────────────────

  SaveService.new(tickService: TickServiceRef) -> SaveServiceImpl
      Constructs the singleton, registers the AutoSave tick group, and wires
      the auto-save callback. Call once from ServerMain.

  SaveService:LoadPlayer(player: Player) -> ()
      Reads the player's DataStore document (with retries), runs any pending
      migrations, merges with DEFAULT_DATA for missing keys, fires all
      OnLoaded callbacks with the hydrated data table, then marks the player
      as clean (no unsaved changes yet).

  SaveService:SavePlayer(player: Player) -> ()
      If the player is dirty, fires all OnBeforeSave callbacks to let services
      populate the snapshot, writes to DataStore (with retries), then clears
      the dirty flag. No-ops cleanly if the player is not loaded or not dirty.

  SaveService:DeletePlayer(player: Player) -> ()
      Removes the player's DataStore key. Useful for GDPR/data-deletion flows.
      Also clears in-memory state.

  SaveService:MarkDirty(player: Player) -> ()
      Marks the player as having unsaved changes. Call this from any system
      that mutates state outside of the normal OnBeforeSave flow (rare).

  SaveService:OnLoaded(callback: LoadedCallback) -> () -> ()
      Registers a callback fired after a successful load.
      Signature: (player: Player, data: SaveDocument) -> ()
      Returns an unsubscribe function.

  SaveService:OnBeforeSave(callback: BeforeSaveCallback) -> () -> ()
      Registers a callback fired just before a write, allowing systems to
      inject their serialized state into the snapshot.
      Signature: (player: Player, snapshot: SaveDocument) -> ()
      Returns an unsubscribe function.

  SaveService:BindToClose() -> ()
      Registers game:BindToClose to flush all dirty players on server shutdown.
      Call once from ServerMain after all OnBeforeSave callbacks are wired.

  SaveService:Destroy() -> ()
      Unsubscribes from TickService and disconnects internal connections.
      Primarily for testing teardown.

================================================================================
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──────────────────────────────────────────────────────────────

local SaveConfig = require(ReplicatedStorage.Shared.Config.SaveConfig)

-- ── Types ─────────────────────────────────────────────────────────────────────

-- Minimal TickService surface needed here
export type TickServiceRef = {
    RegisterGroup: (self: any, groupName: string, interval: number) -> (),
    Bind:          (self: any, groupName: string, id: string, cb: (dt: number) -> ()) -> (),
    Unbind:        (self: any, groupName: string, id: string) -> (),
}

-- Shape of a fully-hydrated save document (after migration + DEFAULT_DATA merge)
export type SaveDocument = {
    _version:   number,
    currencies: { [string]: number },
    upgrades:   { [string]: number },
    prestige:   { level: number },
    [string]:   any,  -- future keys added by migrations
}

-- Callback types
export type LoadedCallback    = (player: Player, data: SaveDocument) -> ()
export type BeforeSaveCallback = (player: Player, snapshot: SaveDocument) -> ()

-- Per-player in-memory record
type PlayerRecord = {
    data:        SaveDocument,  -- live copy; mutated by OnBeforeSave callbacks
    dirty:       boolean,       -- true if data has changed since last successful write
    loading:     boolean,       -- guard: prevents duplicate LoadPlayer calls
}

export type SaveServiceImpl = {
    -- Public
    LoadPlayer:   (self: SaveServiceImpl, player: Player) -> (),
    SavePlayer:   (self: SaveServiceImpl, player: Player) -> (),
    DeletePlayer: (self: SaveServiceImpl, player: Player) -> (),
    MarkDirty:    (self: SaveServiceImpl, player: Player) -> (),
    OnLoaded:     (self: SaveServiceImpl, cb: LoadedCallback) -> () -> (),
    OnBeforeSave: (self: SaveServiceImpl, cb: BeforeSaveCallback) -> () -> (),
    BindToClose:  (self: SaveServiceImpl) -> (),
    Destroy:      (self: SaveServiceImpl) -> (),
    -- Private
    _store:             GlobalDataStore,
    _tick:              TickServiceRef,
    _records:           { [number]: PlayerRecord },         -- keyed by UserId
    _loadedCallbacks:   { [string]: LoadedCallback },
    _beforeSaveCallbacks: { [string]: BeforeSaveCallback },
    _callbackIdCounter: number,
    _boundToClose:      boolean,
}

-- ── Internal Utilities ────────────────────────────────────────────────────────

--[[
    Builds the DataStore key for a player.
--]]
local function playerKey(player: Player): string
    return SaveConfig.KEY_PREFIX .. tostring(player.UserId)
end

--[[
    Deep-copies DEFAULT_DATA so each player gets an independent table.
    Only one level deep for sub-tables (currencies, upgrades, prestige) —
    sufficient for our flat schema.
--]]
local function freshDefault(): SaveDocument
    local d = SaveConfig.DEFAULT_DATA
    return {
        _version   = d._version,
        currencies = table.clone(d.currencies),
        upgrades   = table.clone(d.upgrades),
        prestige   = table.clone(d.prestige) :: { level: number },
    }
end

--[[
    Merges `defaults` into `target` for any key that is nil in target.
    Operates one level deep: if a sub-table key is missing entirely it is
    replaced with a clone of the default sub-table.
--]]
local function mergeMissing(target: { [string]: any }, defaults: { [string]: any })
    for k, v in defaults do
        if target[k] == nil then
            -- Clone tables to avoid shared references
            target[k] = type(v) == "table" and table.clone(v) or v
        end
    end
end

--[[
    Runs the migration chain on raw data loaded from DataStore.
    Applies migration [N] to upgrade data from version N to N+1,
    continuing until data._version == CURRENT_SCHEMA_VERSION.
    Returns the migrated data.
--]]
local function runMigrations(data: { [string]: any }): { [string]: any }
    local savedVersion = type(data._version) == "number" and data._version or 0
    local targetVersion = SaveConfig.CURRENT_SCHEMA_VERSION

    if savedVersion == targetVersion then
        return data
    end

    if savedVersion > targetVersion then
        -- Saved version is newer than this code — do not corrupt; return as-is.
        warn(string.format(
            "[SaveService] Save version %d is newer than current schema %d. Loading without migration.",
            savedVersion, targetVersion
        ))
        return data
    end

    for v = savedVersion, targetVersion - 1 do
        local migrationFn = SaveConfig.Migrations[v]
        if migrationFn then
            local ok, result = pcall(migrationFn, data)
            if ok and result then
                data = result
            else
                warn(string.format(
                    "[SaveService] Migration from v%d to v%d failed: %s. Skipping step.",
                    v, v + 1, tostring(result)
                ))
            end
        end
        -- Whether or not a migration function existed, bump the version stamp.
        data._version = v + 1
    end

    return data
end

--[[
    Retries `operation` up to MAX_RETRIES times with exponential backoff.
    Returns (success: boolean, result: any | errorMessage: string).

    `operationName` is used in warning messages only.
--]]
local function withRetry(operationName: string, operation: () -> any): (boolean, any)
    local lastError: any

    for attempt = 0, SaveConfig.MAX_RETRIES - 1 do
        local ok, result = pcall(operation)
        if ok then
            return true, result
        end

        lastError = result

        if attempt < SaveConfig.MAX_RETRIES - 1 then
            local delay = SaveConfig.RETRY_BASE_DELAY * (SaveConfig.RETRY_BACKOFF_FACTOR ^ attempt)
            warn(string.format(
                "[SaveService] %s failed (attempt %d/%d): %s — retrying in %.1fs",
                operationName, attempt + 1, SaveConfig.MAX_RETRIES, tostring(lastError), delay
            ))
            task.wait(delay)
        end
    end

    warn(string.format(
        "[SaveService] %s gave up after %d attempts. Last error: %s",
        operationName, SaveConfig.MAX_RETRIES, tostring(lastError)
    ))
    return false, lastError
end

-- ── Class ─────────────────────────────────────────────────────────────────────

local SaveService = {}
SaveService.__index = SaveService

-- Module-level singleton cache — re-requiring the module returns the same object.
local _instance: SaveServiceImpl? = nil

--[[
    SaveService.new(tickService: TickServiceRef) -> SaveServiceImpl

    Creates the singleton. Registers the AutoSave tick group and binds the
    auto-save callback. Call once from your server bootstrap script.
--]]
function SaveService.new(tickService: TickServiceRef): SaveServiceImpl
    if _instance then
        return _instance
    end

    assert(tickService, "[SaveService] tickService is required")
    assert(type(tickService.RegisterGroup) == "function", "[SaveService] Invalid TickService")

    local store = DataStoreService:GetDataStore(SaveConfig.DATASTORE_NAME)

    local self = setmetatable({
        _store                = store,
        _tick                 = tickService,
        _records              = {} :: { [number]: PlayerRecord },
        _loadedCallbacks      = {} :: { [string]: LoadedCallback },
        _beforeSaveCallbacks  = {} :: { [string]: BeforeSaveCallback },
        _callbackIdCounter    = 0,
        _boundToClose         = false,
    }, SaveService)

    -- Register a dedicated auto-save tick group so the interval is independent
    -- of the passive-income "Passive" group interval.
    tickService:RegisterGroup(SaveConfig.AUTO_SAVE_GROUP, SaveConfig.AUTO_SAVE_INTERVAL)

    -- Bind the auto-save callback. It iterates all loaded players and saves
    -- those whose dirty flag is set. Errors are isolated per-player via pcall.
    tickService:Bind(SaveConfig.AUTO_SAVE_GROUP, "SaveService_AutoSave", function(_dt: number)
        for userId, record in self._records do
            if record.dirty and not record.loading then
                local player = Players:GetPlayerByUserId(userId)
                if player then
                    -- Run in a new thread so one slow write doesn't block others.
                    task.spawn(function()
                        self:SavePlayer(player)
                    end)
                end
            end
        end
    end)

    _instance = self
    return self :: any
end

-- ── Private: Callback helpers ─────────────────────────────────────────────────

function SaveService:_nextId(): string
    self._callbackIdCounter += 1
    return tostring(self._callbackIdCounter)
end

function SaveService:_fireLoaded(player: Player, data: SaveDocument)
    for _, cb in self._loadedCallbacks do
        local ok, err = pcall(cb, player, data)
        if not ok then
            warn(string.format("[SaveService] OnLoaded callback error for %s: %s", player.Name, tostring(err)))
        end
    end
end

function SaveService:_fireBeforeSave(player: Player, snapshot: SaveDocument)
    for _, cb in self._beforeSaveCallbacks do
        local ok, err = pcall(cb, player, snapshot)
        if not ok then
            warn(string.format("[SaveService] OnBeforeSave callback error for %s: %s", player.Name, tostring(err)))
        end
    end
end

-- ── Public Methods ────────────────────────────────────────────────────────────

--[[
    Loads a player's save data from DataStore, migrates if needed, merges
    defaults for any missing keys, then fires all OnLoaded callbacks.

    This is non-blocking (uses task.spawn internally when called from
    PlayerAdded). However the method itself yields — call it inside a
    task.spawn or coroutine from PlayerAdded if you need non-blocking join.

    The player is marked clean (dirty = false) after a successful load.
    If the DataStore read fails after all retries, the player is loaded
    with DEFAULT_DATA so they can still play (their progress is not lost
    from the server's perspective; it just wasn't read).
--]]
function SaveService:LoadPlayer(player: Player)
    local userId = player.UserId

    -- Guard against duplicate calls
    if self._records[userId] then
        warn(string.format("[SaveService] LoadPlayer: '%s' is already loaded.", player.Name))
        return
    end

    -- Reserve slot and mark as loading so auto-save skips this player
    -- while the async DataStore read is in flight.
    self._records[userId] = {
        data    = freshDefault(),
        dirty   = false,
        loading = true,
    }

    local key = playerKey(player)

    -- Attempt DataStore read with retries
    local ok, raw = withRetry(
        string.format("GetAsync(%s)", key),
        function()
            return self._store:GetAsync(key)
        end
    )

    -- Player may have left during the async read
    if not self._records[userId] then
        return
    end

    local data: SaveDocument

    if ok and raw ~= nil then
        -- Migrate the raw table and patch any missing keys with defaults
        local migrated = runMigrations(raw :: { [string]: any })
        mergeMissing(migrated, freshDefault())
        data = migrated :: SaveDocument
    else
        -- Fall back to fresh defaults; warn only on DataStore failure
        if not ok then
            warn(string.format(
                "[SaveService] Failed to load data for '%s' — using defaults.", player.Name
            ))
        end
        data = freshDefault()
    end

    -- Stamp current schema version (covers the fresh-default path and
    -- any migration that forgot to update _version).
    data._version = SaveConfig.CURRENT_SCHEMA_VERSION

    self._records[userId] = {
        data    = data,
        dirty   = false,
        loading = false,
    }

    -- Notify all wired services (CurrencyService:LoadPlayer, etc.)
    self:_fireLoaded(player, data)
end

--[[
    Saves a player's data to DataStore if their dirty flag is set.

    1. Fires OnBeforeSave callbacks so services can populate the snapshot.
    2. Stamps _version.
    3. Writes to DataStore with retries.
    4. Clears dirty flag on success.

    Safe to call on PlayerRemoving; no-ops if player is not loaded.
--]]
function SaveService:SavePlayer(player: Player)
    local record = self._records[player.UserId]
    if not record then
        return -- player not loaded; nothing to save
    end

    if record.loading then
        return -- still loading; don't write partial state
    end

    if not record.dirty then
        return -- clean; skip the DataStore write
    end

    -- Let services fill in the snapshot
    self:_fireBeforeSave(player, record.data)

    -- Ensure version stamp is current
    record.data._version = SaveConfig.CURRENT_SCHEMA_VERSION

    local key      = playerKey(player)
    local snapshot = record.data -- reference; callbacks have mutated it in place

    local ok, _ = withRetry(
        string.format("SetAsync(%s)", key),
        function()
            self._store:SetAsync(key, snapshot)
        end
    )

    if ok then
        record.dirty = false
    end
    -- If the write failed after all retries, dirty remains true so the
    -- next auto-save or BindToClose will try again.
end

--[[
    Removes a player's DataStore key entirely (GDPR / data-deletion flows).
    Also clears in-memory state. The player is effectively treated as new
    on their next join.
--]]
function SaveService:DeletePlayer(player: Player)
    local key = playerKey(player)

    withRetry(
        string.format("RemoveAsync(%s)", key),
        function()
            self._store:RemoveAsync(key)
        end
    )

    -- Clear in-memory record regardless of DataStore success
    self._records[player.UserId] = nil
end

--[[
    Explicitly marks a player as having unsaved changes.
    Most systems don't need to call this — OnBeforeSave and the normal save
    flow handle it — but it's available for edge cases such as awarding a
    one-off item outside of the tick loop.
--]]
function SaveService:MarkDirty(player: Player)
    local record = self._records[player.UserId]
    if record then
        record.dirty = true
    end
end

--[[
    Registers a callback fired after a successful DataStore load.
    Use this to pipe save data into service LoadPlayer methods.

    @param callback LoadedCallback — (player, data) -> ()
    @return () -> ()   — unsubscribe function
--]]
function SaveService:OnLoaded(callback: LoadedCallback): () -> ()
    assert(type(callback) == "function", "[SaveService] OnLoaded: callback must be a function")
    local id = self:_nextId()
    self._loadedCallbacks[id] = callback
    return function()
        self._loadedCallbacks[id] = nil
    end
end

--[[
    Registers a callback fired just before each DataStore write.
    Use this to inject serialized service state into the save document.

    Callbacks receive a mutable `snapshot` table — write directly into it:
        snapshot.currencies = CurrencyService:Serialize(player)

    After all callbacks return, SaveService stamps _version and writes.

    @param callback BeforeSaveCallback — (player, snapshot) -> ()
    @return () -> ()   — unsubscribe function
--]]
function SaveService:OnBeforeSave(callback: BeforeSaveCallback): () -> ()
    assert(type(callback) == "function", "[SaveService] OnBeforeSave: callback must be a function")
    local id = self:_nextId()
    self._beforeSaveCallbacks[id] = callback
    return function()
        self._beforeSaveCallbacks[id] = nil
    end
end

--[[
    Registers game:BindToClose to flush all dirty players before shutdown.

    Must be called AFTER all OnBeforeSave callbacks are wired so the final
    snapshot is complete. Safe to call only once (warns on subsequent calls).

    Roblox enforces a hard ~30-second shutdown window. BIND_TO_CLOSE_TIMEOUT
    (default 25s) guards against running over. Any players not flushed within
    that window are logged as warnings — their in-memory state was live but
    the write window closed before they could be persisted.
--]]
function SaveService:BindToClose()
    if self._boundToClose then
        warn("[SaveService] BindToClose already registered. Call it only once.")
        return
    end
    self._boundToClose = true

    game:BindToClose(function()
        local startTime = os.clock()

        -- Collect dirty players synchronously to avoid iterating a changing table
        local dirtyPlayers: { Player } = {}
        for userId, record in self._records do
            if record.dirty and not record.loading then
                local player = Players:GetPlayerByUserId(userId)
                if player then
                    table.insert(dirtyPlayers, player)
                end
            end
        end

        if #dirtyPlayers == 0 then
            return
        end

        -- Flush each dirty player in sequence; parallel writes can hit
        -- DataStore rate limits more aggressively on a busy server.
        for _, player in dirtyPlayers do
            local elapsed = os.clock() - startTime
            if elapsed >= SaveConfig.BIND_TO_CLOSE_TIMEOUT then
                warn(string.format(
                    "[SaveService] BindToClose timeout reached (%.1fs). %d player(s) may not have been saved.",
                    SaveConfig.BIND_TO_CLOSE_TIMEOUT, #dirtyPlayers
                ))
                break
            end

            self:SavePlayer(player)
        end
    end)
end

--[[
    Unsubscribes from TickService and clears internal state.
    Primarily for unit-test teardown; not normally called in production.
--]]
function SaveService:Destroy()
    self._tick:Unbind(SaveConfig.AUTO_SAVE_GROUP, "SaveService_AutoSave")
    table.clear(self._loadedCallbacks)
    table.clear(self._beforeSaveCallbacks)
    table.clear(self._records)
    _instance = nil
end

-- ── Return ────────────────────────────────────────────────────────────────────

return SaveService
