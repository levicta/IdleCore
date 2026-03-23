--[[
================================================================================
  ClientMain
  Location: StarterPlayerScripts/ClientMain (LocalScript — NOT a ModuleScript)

  The single client bootstrap. Constructs UIService and wires every label,
  button, and screen in the PlayerGui to the reactive update system.

  UIService's internal Remote listeners (CurrencyChanged, UpgradesSync,
  PrestigeSync, PrestigeCompleted) self-connect when UIService.new() is called,
  so this script only needs to handle PlayerGui element bindings.

  ── Customisation Guide ───────────────────────────────────────────────────────

  This file is intentionally explicit about element paths. In a real game you
  will replace the FindFirstChild / WaitForChild calls with your actual GUI
  hierarchy. The wiring patterns below are the canonical reference — copy and
  adapt them per-screen.

  Every BindLabel / BindUpgradeButton call returns an unsubscribe function.
  Store those if you need to dynamically remove bindings (e.g. when a panel
  is destroyed by the user).

================================================================================
--]]

-- ── Roblox Services ───────────────────────────────────────────────────────────

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Framework Modules ─────────────────────────────────────────────────────────

local UIService = require(script.Parent.UIService)

-- ── Remotes (needed for prestige button click wiring) ─────────────────────────

local PrestigeRemotes = require(ReplicatedStorage.Shared.Remotes.PrestigeRemotes)

-- ── Bootstrap UIService ───────────────────────────────────────────────────────
-- Constructing the singleton connects all Remote event listeners immediately,
-- so CurrencyChanged / UpgradesSync / PrestigeSync events that fire after this
-- point (including the initial load sync from the server) are captured.

local ui = UIService.new()

-- ── PlayerGui reference ───────────────────────────────────────────────────────

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Helper: safely find a descendant with a timeout ──────────────────────────
-- Used throughout this file to avoid hard errors on missing GUI elements.
-- Replace WaitForChild calls with direct paths once your GUI is final.

local function waitFor(parent: Instance, name: string, timeout: number?): Instance?
    local ok, result = pcall(function()
        return parent:WaitForChild(name, timeout or 10)
    end)
    if ok and result then
        return result
    end
    warn(string.format("[ClientMain] Could not find '%s' under '%s'", name, parent:GetFullName()))
    return nil
end

-- ============================================================================
--  HUD SCREEN
--  Expected hierarchy (adapt paths to your actual GUI):
--
--  PlayerGui
--  └── HUD (ScreenGui)
--      ├── CurrencyFrame
--      │   ├── GoldIcon   (ImageLabel or TextLabel with emoji)
--      │   ├── GoldLabel  (TextLabel)
--      │   ├── GemsLabel  (TextLabel)
--      │   └── PrestigePointsLabel (TextLabel)
--      ├── PrestigeFrame
--      │   ├── LevelLabel       (TextLabel)
--      │   ├── MultiplierLabel  (TextLabel)
--      │   └── PrestigeButton   (TextButton)
--      │       └── Cost         (TextLabel — auto-managed by BindUpgradeButton)
--      └── Upgrades
--          ├── GoldMineButton (TextButton)
--          │   ├── Cost       (TextLabel)
--          │   └── Level      (TextLabel)
--          ├── GoldRushButton (TextButton)
--          │   ├── Cost       (TextLabel)
--          │   └── Level      (TextLabel)
--          ├── GemVaultButton (TextButton)
--          │   ├── Cost       (TextLabel)
--          │   └── Level      (TextLabel)
--          └── PrestigeAcceleratorButton (TextButton)
--              ├── Cost  (TextLabel)
--              └── Level (TextLabel)
--
--  PlayerGui
--  └── PrestigeFanfare (ScreenGui, starts Enabled = false)
--      ├── Background    (Frame)
--      ├── PrestigeLevel (TextLabel)
--      └── PointsEarned  (TextLabel)
-- ============================================================================

-- Give the server a moment to replicate GUI objects that are inserted via
-- ReplicatedStorage after PlayerAdded. Most GUIs are in StarterGui and are
-- available immediately; adjust the timeout if your GUI loads asynchronously.

task.wait()  -- single-frame yield so Roblox can finish inserting StarterGui objects

-- ── HUD ──────────────────────────────────────────────────────────────────────

local hud = waitFor(playerGui, "HUD")

if hud then
    local hudScreen = hud :: ScreenGui
    ui:RegisterScreen("HUD", hudScreen)

    -- ── Currency labels ───────────────────────────────────────────────────

    local currencyFrame = waitFor(hud, "CurrencyFrame")
    if currencyFrame then

        local goldLabel = waitFor(currencyFrame, "GoldLabel")
        if goldLabel then
            ui:BindLabel(goldLabel :: TextLabel, "Gold")
        end

        local gemsLabel = waitFor(currencyFrame, "GemsLabel")
        if gemsLabel then
            ui:BindLabel(gemsLabel :: TextLabel, "Gems")
        end

        local ppLabel = waitFor(currencyFrame, "PrestigePointsLabel")
        if ppLabel then
            ui:BindLabel(ppLabel :: TextLabel, "PrestigePoints")
        end
    end

    -- ── Prestige display ──────────────────────────────────────────────────

    local prestigeFrame = waitFor(hud, "PrestigeFrame")
    if prestigeFrame then

        -- Bind the prestige level label to the virtual "PrestigeLevel" key.
        -- UIService:UpdatePrestigeDisplay writes to this key whenever
        -- PrestigeSync or PrestigeCompleted fires.
        local levelLabel = waitFor(prestigeFrame, "LevelLabel")
        if levelLabel then
            ui:BindLabel(levelLabel :: TextLabel, "PrestigeLevel")
        end

        -- Bind the multiplier label to the virtual "PrestigeMultiplier" key.
        local multLabel = waitFor(prestigeFrame, "MultiplierLabel")
        if multLabel then
            ui:BindLabel(multLabel :: TextLabel, "PrestigeMultiplier")
        end

        -- ── Prestige button ───────────────────────────────────────────────
        -- This is a plain click handler rather than BindUpgradeButton because
        -- prestige validation lives entirely on the server; the client just sends
        -- the request and waits for PrestigeCompleted.

        local prestigeBtn = waitFor(prestigeFrame, "PrestigeButton")
        if prestigeBtn then
            local btn = prestigeBtn :: TextButton

            -- Visual: update button label with "Prestige (need X Gold)"
            -- on every Gold balance change.
            local goldConn = ReplicatedStorage.Shared.Remotes.CurrencyRemotes  -- already required indirectly
            -- We use UIService's internal currency cache update path via a
            -- dedicated label bound to a synthetic key, keeping logic clean.
            -- For cost display, add a child TextLabel named "Requirement" to
            -- the button and update it manually here:
            local reqLabel = btn:FindFirstChild("Requirement")
            if reqLabel and reqLabel:IsA("TextLabel") then
                -- Refresh on every Gold change
                local PrestigeConfig = require(ReplicatedStorage.Shared.Config.PrestigeConfig)
                ReplicatedStorage.Shared.Remotes.CurrencyRemotes.CurrencyChanged.OnClientEvent:Connect(
                    function(currencyId: string, newAmount: number)
                        if currencyId ~= PrestigeConfig.costCurrencyId then return end
                        local needed = PrestigeConfig.minimumGoldRequired
                        if newAmount >= needed then
                            (reqLabel :: TextLabel).Text = "PRESTIGE!"
                            btn.BackgroundColor3 = Color3.fromRGB(255, 215, 0)  -- gold shimmer
                            btn.Active = true
                        else
                            local ui_cfg = require(ReplicatedStorage.Shared.Config.UIConfig)
                            ;(reqLabel :: TextLabel).Text =
                                ui:FormatNumber(newAmount) .. " / " ..
                                ui:FormatNumber(needed) .. " Gold"
                            btn.BackgroundColor3 = ui_cfg.BUTTON_CANNOT_AFFORD
                            btn.Active = false
                        end
                    end
                )
            end

            -- Click handler
            btn.MouseButton1Click:Connect(function()
                if not btn.Active then return end
                btn.Active = false  -- prevent double-fire; re-enabled by result
                task.spawn(function()
                    local ok, reason, newLevel, pointsEarned =
                        PrestigeRemotes.RequestPrestige:InvokeServer()
                    if not ok then
                        warn("[ClientMain] Prestige failed:", reason)
                        btn.Active = true  -- re-enable so the player can retry
                    end
                    -- On success, PrestigeCompleted fires → UIService handles fanfare.
                    -- PrestigeSync fires with the new level → UpdatePrestigeDisplay.
                    -- CurrencyChanged fires for the reset balances → labels update.
                    _ = newLevel
                    _ = pointsEarned
                end)
            end)
        end
    end

    -- ── Upgrade buttons ───────────────────────────────────────────────────

    local upgradesFolder = waitFor(hud, "Upgrades")
    if upgradesFolder then

        -- Gold Mine
        local goldMineBtn = upgradesFolder:FindFirstChild("GoldMineButton")
        if goldMineBtn and goldMineBtn:IsA("TextButton") then
            ui:BindUpgradeButton(goldMineBtn :: TextButton, "GoldMine")
        end

        -- Gold Rush
        local goldRushBtn = upgradesFolder:FindFirstChild("GoldRushButton")
        if goldRushBtn and goldRushBtn:IsA("TextButton") then
            ui:BindUpgradeButton(goldRushBtn :: TextButton, "GoldRush")
        end

        -- Gem Vault
        local gemVaultBtn = upgradesFolder:FindFirstChild("GemVaultButton")
        if gemVaultBtn and gemVaultBtn:IsA("TextButton") then
            ui:BindUpgradeButton(gemVaultBtn :: TextButton, "GemVault")
        end

        -- Prestige Accelerator
        local accelBtn = upgradesFolder:FindFirstChild("PrestigeAcceleratorButton")
        if accelBtn and accelBtn:IsA("TextButton") then
            ui:BindUpgradeButton(accelBtn :: TextButton, "PrestigeAccelerator")
        end
    end
end

-- ── Prestige Fanfare Screen ───────────────────────────────────────────────────
-- Starts hidden (Enabled = false). UIService shows it for FANFARE_DURATION
-- seconds whenever PrestigeCompleted fires.

local fanfareGui = playerGui:FindFirstChild("PrestigeFanfare")
if fanfareGui and fanfareGui:IsA("ScreenGui") then
    fanfareGui.Enabled = false
    ui:RegisterScreen("PrestigeFanfare", fanfareGui :: ScreenGui)
end

-- ── Cleanup on character removal (optional) ───────────────────────────────────
-- If your game resets GUI on respawn you may want to re-bind elements here.
-- For persistent GUIs (ResetOnSpawn = false) this block is not needed.
player.CharacterRemoving:Connect(function()
    -- UIService bindings survive character death by default since they are
    -- keyed to TextLabel instances which persist in PlayerGui.
    -- Add teardown here if your GUI is rebuilt on respawn.
end)

-- ── Developer: console helpers (Studio only) ─────────────────────────────────
-- Remove this block before shipping.
if game:GetService("RunService"):IsStudio() then
    -- Expose UIService to the command bar for quick testing:
    -- > _G.UIService:FormatNumber(1234567)  → "1.23M"
    _G.UIService = ui
end
