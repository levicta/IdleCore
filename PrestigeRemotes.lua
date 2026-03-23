--[[
================================================================================
  PrestigeRemotes
  Location: ReplicatedStorage/Shared/Remotes/PrestigeRemotes.lua

  Creates (server) or fetches (client) the Remote instances used by
  PrestigeService and the client UI layer. Same pattern as CurrencyRemotes
  and UpgradeRemotes — require on either side, branching handled internally.

  ── Remotes Exposed ──────────────────────────────────────────────────────────

  RemoteEvents:
    PrestigeCompleted  — Server → Client
                         Fired after a successful prestige so the UI can
                         play a fanfare, update the prestige level display, etc.
                         Args: (newPrestigeLevel: number, pointsEarned: number)

    PrestigeSync       — Server → Client
                         Fires on player load with the player's saved prestige
                         level so the client never has to poll on join.
                         Args: (prestigeLevel: number, multiplier: number)

  RemoteFunctions:
    RequestPrestige    — Client → Server
                         Client requests to prestige. Server validates everything;
                         the client sends no amounts (nothing to trust).
                         Args:    ()   — no client arguments needed
                         Returns: (success: boolean, reason: string,
                                   newLevel: number, pointsEarned: number)

    GetPrestigeInfo    — Client → Server
                         Client requests current prestige state for UI display.
                         Args:    ()
                         Returns: (level: number, multiplier: number,
                                   pointsIfPrestigeNow: number, canPrestige: boolean)

  ── Usage ────────────────────────────────────────────────────────────────────

  -- Server:
  local PrestigeRemotes = require(ReplicatedStorage.Shared.Remotes.PrestigeRemotes)
  PrestigeRemotes.PrestigeCompleted:FireClient(player, 3, 12)

  -- Client:
  local PrestigeRemotes = require(ReplicatedStorage.Shared.Remotes.PrestigeRemotes)
  PrestigeRemotes.PrestigeCompleted.OnClientEvent:Connect(function(level, points)
      UIService:ShowPrestigeFanfare(level, points)
  end)

================================================================================
--]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Folder bootstrap ──────────────────────────────────────────────────────────

local remotesFolder: Folder

if RunService:IsServer() then
    local existing = ReplicatedStorage:FindFirstChild("PrestigeRemotes")
    if existing then
        remotesFolder = existing :: Folder
    else
        remotesFolder        = Instance.new("Folder")
        remotesFolder.Name   = "PrestigeRemotes"
        remotesFolder.Parent = ReplicatedStorage
    end
else
    remotesFolder = ReplicatedStorage:WaitForChild("PrestigeRemotes", 10) :: Folder
    assert(remotesFolder, "[PrestigeRemotes] Timed out waiting for PrestigeRemotes folder")
end

-- ── Helper ────────────────────────────────────────────────────────────────────

local function getOrCreate<T>(className: string, name: string): T
    if RunService:IsServer() then
        local existing = remotesFolder:FindFirstChild(name)
        if existing then return existing :: any end
        local inst      = Instance.new(className)
        inst.Name       = name
        inst.Parent     = remotesFolder
        return inst :: any
    else
        local inst = remotesFolder:WaitForChild(name, 10)
        assert(inst, string.format("[PrestigeRemotes] Timed out waiting for: %s", name))
        return inst :: any
    end
end

-- ── Remote Declarations ───────────────────────────────────────────────────────

local PrestigeRemotes = {

    -- Server → Client: prestige succeeded
    -- FireClient(player, newPrestigeLevel, pointsEarned)
    PrestigeCompleted = getOrCreate("RemoteEvent",    "PrestigeCompleted") :: RemoteEvent,

    -- Server → Client: bulk sync on join
    -- FireClient(player, prestigeLevel, multiplier)
    PrestigeSync      = getOrCreate("RemoteEvent",    "PrestigeSync")      :: RemoteEvent,

    -- Client → Server: attempt prestige
    -- InvokeServer() -> (boolean, string, number, number)
    RequestPrestige   = getOrCreate("RemoteFunction", "RequestPrestige")   :: RemoteFunction,

    -- Client → Server: query current state for UI
    -- InvokeServer() -> (number, number, number, boolean)
    GetPrestigeInfo   = getOrCreate("RemoteFunction", "GetPrestigeInfo")   :: RemoteFunction,
}

return PrestigeRemotes
