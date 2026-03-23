--[[
================================================================================
  UpgradeRemotes
  Location: ReplicatedStorage/Shared/Remotes/UpgradeRemotes.lua

  Creates (server) or fetches (client) the Remote instances used by
  UpgradeService and the client UI layer. Mirrors the pattern from
  CurrencyRemotes — require on either side, branching handled internally.

  ── Remotes Exposed ──────────────────────────────────────────────────────────

  RemoteEvents:
    UpgradePurchased  — Server → Client
                        Fired after a successful purchase so the UI can update.
                        Args: (upgradeId: string, newLevel: number, nextCost: number)

    UpgradesSync      — Server → Client
                        Fires on player load with the full current upgrade state.
                        Args: (data: { [upgradeId]: number })
                        Sends the complete level map so the client never needs
                        to poll individual levels on join.

  RemoteFunctions:
    RequestPurchase   — Client → Server
                        Client asks to buy one level of an upgrade.
                        Args:    (upgradeId: string)
                        Returns: (success: boolean, reason: string, newLevel: number)

    GetUpgradeLevel   — Client → Server
                        Client requests a single upgrade's current level.
                        Args:    (upgradeId: string)
                        Returns: (level: number)

  ── Usage ────────────────────────────────────────────────────────────────────

  -- Server:
  local UpgradeRemotes = require(ReplicatedStorage.Shared.Remotes.UpgradeRemotes)
  UpgradeRemotes.UpgradePurchased:FireClient(player, "GoldMine", 3, 225)

  -- Client:
  local UpgradeRemotes = require(ReplicatedStorage.Shared.Remotes.UpgradeRemotes)
  UpgradeRemotes.UpgradePurchased.OnClientEvent:Connect(function(id, level, nextCost)
      UIService:RefreshUpgradeButton(id, level, nextCost)
  end)

================================================================================
--]]

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Folder bootstrap ──────────────────────────────────────────────────────────

local remotesFolder: Folder

if RunService:IsServer() then
    local existing = ReplicatedStorage:FindFirstChild("UpgradeRemotes")
    if existing then
        remotesFolder = existing :: Folder
    else
        remotesFolder        = Instance.new("Folder")
        remotesFolder.Name   = "UpgradeRemotes"
        remotesFolder.Parent = ReplicatedStorage
    end
else
    remotesFolder = ReplicatedStorage:WaitForChild("UpgradeRemotes", 10) :: Folder
    assert(remotesFolder, "[UpgradeRemotes] Timed out waiting for UpgradeRemotes folder")
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
        assert(inst, string.format("[UpgradeRemotes] Timed out waiting for: %s", name))
        return inst :: any
    end
end

-- ── Remote Declarations ───────────────────────────────────────────────────────

local UpgradeRemotes = {

    -- Server → Client: upgrade level changed
    -- FireClient(player, upgradeId, newLevel, nextCost)
    UpgradePurchased = getOrCreate("RemoteEvent",    "UpgradePurchased") :: RemoteEvent,

    -- Server → Client: bulk sync on join
    -- FireClient(player, { [upgradeId]: level })
    UpgradesSync     = getOrCreate("RemoteEvent",    "UpgradesSync")     :: RemoteEvent,

    -- Client → Server: buy one level of an upgrade
    -- InvokeServer(upgradeId) -> (boolean, string, number)
    RequestPurchase  = getOrCreate("RemoteFunction", "RequestPurchase")  :: RemoteFunction,

    -- Client → Server: read a single level
    -- InvokeServer(upgradeId) -> number
    GetUpgradeLevel  = getOrCreate("RemoteFunction", "GetUpgradeLevel")  :: RemoteFunction,
}

return UpgradeRemotes
