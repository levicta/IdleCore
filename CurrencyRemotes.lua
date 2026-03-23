--[[
================================================================================
  CurrencyRemotes
  Location: ReplicatedStorage/Shared/Remotes/CurrencyRemotes.lua

  Creates (server) or fetches (client) the Remote instances used by
  CurrencyService and the client UI layer.

  Require this module on BOTH sides — it handles the server/client split
  internally so callers never need to branch on RunService.IsServer().

  ── Remotes Exposed ──────────────────────────────────────────────────────────

  RemoteEvents:
    CurrencyChanged   — Server → Client
                        Fired whenever a player's currency value changes.
                        Args: (currencyId: string, newAmount: number, delta: number)

  RemoteFunctions:
    GetCurrency       — Client → Server
                        Client requests its own currency balance.
                        Args:    (currencyId: string)
                        Returns: (amount: number)

    RequestSpend      — Client → Server
                        Client asks to spend currency (e.g. buy upgrade via UI).
                        Server validates & deducts; returns success flag.
                        Args:    (currencyId: string, amount: number)
                        Returns: (success: boolean, newAmount: number)

  ── Usage ────────────────────────────────────────────────────────────────────

  -- Server:
  local CurrencyRemotes = require(ReplicatedStorage.Shared.Remotes.CurrencyRemotes)
  CurrencyRemotes.CurrencyChanged:FireClient(player, "Gold", 150, 50)

  -- Client:
  local CurrencyRemotes = require(ReplicatedStorage.Shared.Remotes.CurrencyRemotes)
  CurrencyRemotes.CurrencyChanged.OnClientEvent:Connect(function(id, amount, delta)
      UIService:UpdateLabel(id, amount)
  end)

================================================================================
--]]

local RunService       = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Folder bootstrap (server creates, client waits) ───────────────────────────

local remotesFolder: Folder

if RunService:IsServer() then
    -- Create the container folder if it doesn't already exist
    local existing = ReplicatedStorage:FindFirstChild("CurrencyRemotes")
    if existing then
        remotesFolder = existing :: Folder
    else
        remotesFolder      = Instance.new("Folder")
        remotesFolder.Name = "CurrencyRemotes"
        remotesFolder.Parent = ReplicatedStorage
    end
else
    -- Client waits up to 10 s for the server to create the folder
    remotesFolder = ReplicatedStorage:WaitForChild("CurrencyRemotes", 10) :: Folder
    assert(remotesFolder, "[CurrencyRemotes] Timed out waiting for CurrencyRemotes folder")
end

-- ── Helper: create or fetch a remote instance ─────────────────────────────────

local function getOrCreate<T>(className: string, name: string): T
    if RunService:IsServer() then
        local existing = remotesFolder:FindFirstChild(name)
        if existing then
            return existing :: any
        end
        local inst = Instance.new(className)
        inst.Name   = name
        inst.Parent = remotesFolder
        return inst :: any
    else
        local inst = remotesFolder:WaitForChild(name, 10)
        assert(inst, string.format("[CurrencyRemotes] Timed out waiting for remote: %s", name))
        return inst :: any
    end
end

-- ── Remote Declarations ───────────────────────────────────────────────────────

local CurrencyRemotes = {

    -- Server → All clients: a player's currency changed
    -- FireClient(player, currencyId, newAmount, delta)
    CurrencyChanged = getOrCreate("RemoteEvent",    "CurrencyChanged") :: RemoteEvent,

    -- Client → Server: read own balance
    -- InvokeServer(currencyId) -> number
    GetCurrency     = getOrCreate("RemoteFunction", "GetCurrency")     :: RemoteFunction,

    -- Client → Server: request to spend currency
    -- InvokeServer(currencyId, amount) -> (boolean, number)
    RequestSpend    = getOrCreate("RemoteFunction", "RequestSpend")    :: RemoteFunction,
}

return CurrencyRemotes
