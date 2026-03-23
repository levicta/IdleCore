--[[
================================================================================
  UIService
  Location: StarterPlayerScripts/Client/UIService.lua  (ModuleScript)

  The reactive presentation layer for the Incremental Game Framework.
  All display logic lives here; no game-state is written from this module.

  Integrates with (client-side only):
    • CurrencyRemotes  — listens to CurrencyChanged for live balance updates
    • UpgradeRemotes   — listens to UpgradePurchased + UpgradesSync
    • PrestigeRemotes  — listens to PrestigeSync + PrestigeCompleted

  ── Architecture Notes ────────────────────────────────────────────────────────

    Label binding:
      BindLabel(label, currencyId) registers a TextLabel against a currency.
      Whenever CurrencyChanged fires for that currency, every bound label is
      tweened to the new value automatically — no manual wiring per label.

    Tween counters:
      Each bound label gets a running TweenInfo-based animation from its
      current displayed value to the new target. If a second update arrives
      while a tween is in flight, the old tween is cancelled and a new one
      starts from the current mid-animation value, keeping the display smooth.

    Upgrade button binding:
      BindUpgradeButton(button, upgradeId) subscribes a TextButton to an
      upgrade. The button's BackgroundColor3 and a child TextLabel named
      "Cost" (if present) are updated automatically whenever the upgrade
      level changes or the player's currency balance changes.

    Screens:
      RegisterScreen(name, screenGui) / UnregisterScreen(name, screenGui)
      provide a lightweight named registry so other scripts can show/hide
      panels without hard-referencing ScreenGui instances.

  ── API Reference ─────────────────────────────────────────────────────────────

  UIService.new() -> UIServiceImpl
      Constructs the singleton, connects all Remote listeners, and returns
      the instance. Call once from ClientMain.

  UIService:FormatNumber(n: number) -> string
      Formats any non-negative number according to UIConfig rules:
        0–RAW_THRESHOLD           → raw integer string ("42")
        RAW_THRESHOLD+1–SCI_THRESH → suffixed ("3.50M")
        ≥ SCIENTIFIC_THRESHOLD    → scientific ("1.234e+15")

  UIService:BindLabel(label: TextLabel, currencyId: string) -> () -> ()
      Registers label to auto-update when currencyId changes.
      Returns an unsubscribe function.

  UIService:UnbindLabel(label: TextLabel, currencyId: string) -> ()
      Removes a single label binding for the given currency.

  UIService:BindUpgradeButton(button: TextButton, upgradeId: string) -> () -> ()
      Registers button to reflect the current afford/maxed state of upgradeId.
      The button's BackgroundColor3 is updated immediately and on every
      relevant CurrencyChanged or UpgradePurchased event.
      A child TextLabel named "Cost" (if present) is also updated with the
      next-level cost string.
      Returns an unsubscribe function.

  UIService:UpdateCurrencyDisplay(currencyId: string, newAmount: number) -> ()
      Drives all bound labels for currencyId to newAmount (with tween).
      Called automatically by the CurrencyChanged listener; call manually
      if you need to force a refresh (e.g. after a prestige reset).

  UIService:UpdateUpgradeDisplays(levels: { [string]: number }) -> ()
      Refreshes all bound upgrade buttons from a bulk level map.
      Called automatically by the UpgradesSync listener on join.

  UIService:RefreshUpgradeButton(upgradeId: string, newLevel: number, nextCost: number) -> ()
      Refreshes a single upgrade button after a purchase.
      Called automatically by the UpgradePurchased listener.

  UIService:UpdatePrestigeDisplay(level: number, multiplier: number) -> ()
      Updates any labels registered under "PrestigeLevel" and "PrestigeMultiplier"
      currency slots, and refreshes the prestige button if one is registered.
      Called automatically by the PrestigeSync listener on join.

  UIService:ShowPrestigeFanfare(newLevel: number, pointsEarned: number) -> ()
      Plays the prestige fanfare. Looks for a ScreenGui registered as
      "PrestigeFanfare" and tweens it visible for UIConfig.FANFARE_DURATION
      seconds, then hides it. No-op if no fanfare screen is registered.

  UIService:RegisterScreen(name: string, screenGui: ScreenGui) -> ()
      Adds a ScreenGui to the named registry for show/hide control.

  UIService:UnregisterScreen(name: string, screenGui: ScreenGui) -> ()
      Removes a specific ScreenGui from the registry.

  UIService:ShowScreen(name: string) -> ()
      Sets Enabled = true on all ScreenGuis registered under name.

  UIService:HideScreen(name: string) -> ()
      Sets Enabled = false on all ScreenGuis registered under name.

  UIService:Destroy() -> ()
      Disconnects all Remote listeners and clears all bindings.
      Primarily for testing teardown.

  ── Example Usage ─────────────────────────────────────────────────────────────

  -- ClientMain.lua
  local UIService = require(script.Parent.UIService)
  local ui = UIService.new()

  -- Bind a currency label
  local goldLabel = playerGui.HUD.GoldFrame.ValueLabel
  ui:BindLabel(goldLabel, "Gold")

  -- Bind an upgrade purchase button
  local mineButton = playerGui.HUD.Upgrades.GoldMineButton
  ui:BindUpgradeButton(mineButton, "GoldMine")

  -- Wire the prestige button's click
  local prestigeBtn = playerGui.HUD.PrestigeButton
  prestigeBtn.MouseButton1Click:Connect(function()
      local PrestigeRemotes = require(ReplicatedStorage.Shared.Remotes.PrestigeRemotes)
      local ok, reason, lvl, pts = PrestigeRemotes.RequestPrestige:InvokeServer()
      if not ok then
          warn("Prestige failed:", reason)
      end
  end)

  -- Register a fanfare screen
  ui:RegisterScreen("PrestigeFanfare", playerGui.PrestigeFanfare)

================================================================================
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

-- ── Dependencies ──────────────────────────────────────────────────────────────

local UIConfig       = require(ReplicatedStorage.Shared.Config.UIConfig)
local UpgradeConfig  = require(ReplicatedStorage.Shared.Config.UpgradeConfig)
local CurrencyConfig = require(ReplicatedStorage.Shared.Config.CurrencyConfig)
local PrestigeConfig = require(ReplicatedStorage.Shared.Config.PrestigeConfig)

local CurrencyRemotes = require(ReplicatedStorage.Shared.Remotes.CurrencyRemotes)
local UpgradeRemotes  = require(ReplicatedStorage.Shared.Remotes.UpgradeRemotes)
local PrestigeRemotes = require(ReplicatedStorage.Shared.Remotes.PrestigeRemotes)

-- ── Types ─────────────────────────────────────────────────────────────────────

-- Per-label tween state
type LabelTweenState = {
    displayValue: number,          -- current value being rendered mid-tween
    tween:        Tween?,          -- active tween (nil if not animating)
}

-- Per-button upgrade binding state
type ButtonBinding = {
    upgradeId: string,
    button:    TextButton,
}

export type UIServiceImpl = {
    -- Public
    FormatNumber:          (self: UIServiceImpl, n: number) -> string,
    BindLabel:             (self: UIServiceImpl, label: TextLabel, currencyId: string) -> () -> (),
    UnbindLabel:           (self: UIServiceImpl, label: TextLabel, currencyId: string) -> (),
    BindUpgradeButton:     (self: UIServiceImpl, button: TextButton, upgradeId: string) -> () -> (),
    UpdateCurrencyDisplay: (self: UIServiceImpl, currencyId: string, newAmount: number) -> (),
    UpdateUpgradeDisplays: (self: UIServiceImpl, levels: { [string]: number }) -> (),
    RefreshUpgradeButton:  (self: UIServiceImpl, upgradeId: string, newLevel: number, nextCost: number) -> (),
    UpdatePrestigeDisplay: (self: UIServiceImpl, level: number, multiplier: number) -> (),
    ShowPrestigeFanfare:   (self: UIServiceImpl, newLevel: number, pointsEarned: number) -> (),
    RegisterScreen:        (self: UIServiceImpl, name: string, screenGui: ScreenGui) -> (),
    UnregisterScreen:      (self: UIServiceImpl, name: string, screenGui: ScreenGui) -> (),
    ShowScreen:            (self: UIServiceImpl, name: string) -> (),
    HideScreen:            (self: UIServiceImpl, name: string) -> (),
    Destroy:               (self: UIServiceImpl) -> (),
    -- Private
    _labelBindings:    { [string]: { [TextLabel]: LabelTweenState } },  -- currencyId → labels
    _buttonBindings:   { [TextButton]: ButtonBinding },
    _tweenInfoCache:   TweenInfo?,
    _currencyCache:    { [string]: number },                             -- last known amounts
    _upgradeCache:     { [string]: number },                             -- last known levels
    _nextCostCache:    { [string]: number },                             -- next-level costs (-1 = maxed)
    _prestigeLevel:    number,
    _prestigeMultiplier: number,
    _screens:          { [string]: { ScreenGui } },
    _connections:      { RBXScriptConnection },
}

-- ── Singleton cache ───────────────────────────────────────────────────────────

local _instance: UIServiceImpl? = nil

-- ── Internal: Number Formatting ───────────────────────────────────────────────

--[[
    Sorts the suffix table once at require-time for safe reverse traversal.
    We walk from largest to smallest, so the first tier that fits wins.
--]]
local SORTED_SUFFIXES: { UIConfig.SuffixTier } = table.clone(UIConfig.SUFFIXES)
table.sort(SORTED_SUFFIXES, function(a, b) return a.divisor < b.divisor end)

--[[
    Formats a non-negative number according to UIConfig display rules.
    Negative values are clamped to 0 for display purposes (balances are never negative).
--]]
local function formatNumber(n: number): string
    if n ~= n or n == math.huge then
        -- NaN / Inf guard
        return "∞"
    end

    n = math.max(0, math.floor(n + 0.5))  -- round to nearest integer

    -- ── Tier 3: scientific notation ───────────────────────────────────────
    if n >= UIConfig.SCIENTIFIC_THRESHOLD then
        local decimals = UIConfig.SCIENTIFIC_DECIMALS
        local fmt = "%." .. decimals .. "e"
        -- Lua's %e uses e+015 style; clean up to e+15
        local s = string.format(fmt, n)
        s = s:gsub("e%+0*(%d+)", "e+%1"):gsub("e%-0*(%d+)", "e-%1")
        return s
    end

    -- ── Tier 2: suffixed ──────────────────────────────────────────────────
    if n > UIConfig.RAW_THRESHOLD then
        -- Walk suffixes from largest down
        for i = #SORTED_SUFFIXES, 1, -1 do
            local tier = SORTED_SUFFIXES[i]
            if n >= tier.divisor then
                local decimals = UIConfig.SUFFIX_DECIMALS[tier.suffix]
                    or UIConfig.SUFFIX_DECIMALS_DEFAULT
                local divided = n / tier.divisor
                local fmt = "%." .. decimals .. "f"
                return string.format(fmt, divided) .. tier.suffix
            end
        end
    end

    -- ── Tier 1: raw integer ───────────────────────────────────────────────
    return tostring(math.floor(n))
end

-- ── Internal: TweenInfo singleton ────────────────────────────────────────────

local function makeTweenInfo(): TweenInfo
    local style = Enum.EasingStyle[UIConfig.TWEEN_EASING_STYLE]
        or Enum.EasingStyle.Quad
    local direction = Enum.EasingDirection[UIConfig.TWEEN_EASING_DIRECTION]
        or Enum.EasingDirection.Out
    return TweenInfo.new(UIConfig.TWEEN_DURATION, style, direction)
end

-- ── Class ─────────────────────────────────────────────────────────────────────

local UIService = {}
UIService.__index = UIService

--[[
    UIService.new() -> UIServiceImpl

    Constructs the singleton UIService, wires all Remote listeners, and returns
    the instance. Call once from ClientMain.
--]]
function UIService.new(): UIServiceImpl
    if _instance then
        return _instance
    end

    local self = setmetatable({
        _labelBindings      = {} :: { [string]: { [TextLabel]: LabelTweenState } },
        _buttonBindings     = {} :: { [TextButton]: ButtonBinding },
        _tweenInfoCache     = nil,
        _currencyCache      = {} :: { [string]: number },
        _upgradeCache       = {} :: { [string]: number },
        _nextCostCache      = {} :: { [string]: number },
        _prestigeLevel      = 0,
        _prestigeMultiplier = 1.0,
        _screens            = {} :: { [string]: { ScreenGui } },
        _connections        = {} :: { RBXScriptConnection },
    }, UIService)

    -- Seed currency cache with 0 for every defined currency so bound labels
    -- start at a known value before the first server event arrives.
    for _, def in CurrencyConfig.Currencies do
        self._currencyCache[def.id] = 0
    end

    -- Seed upgrade cache with 0 for every upgrade
    for _, def in UpgradeConfig.Upgrades do
        self._upgradeCache[def.id]  = 0
        -- First-level cost so buttons show a sensible default before UpgradesSync
        self._nextCostCache[def.id] = math.floor(
            def.cost.amount * (def.costScaling ^ 0) -- level 1 cost
        )
    end

    self:_connectRemotes()

    _instance = self
    return self :: any
end

-- ── Private: TweenInfo helper ─────────────────────────────────────────────────

function UIService:_getTweenInfo(): TweenInfo
    if not self._tweenInfoCache then
        self._tweenInfoCache = makeTweenInfo()
    end
    return self._tweenInfoCache :: TweenInfo
end

-- ── Private: Remote connections ───────────────────────────────────────────────

function UIService:_connectRemotes()
    -- CurrencyChanged: (currencyId, newAmount, delta)
    local c1 = CurrencyRemotes.CurrencyChanged.OnClientEvent:Connect(function(
        currencyId: string,
        newAmount:  number,
        _delta:     number
    )
        self:UpdateCurrencyDisplay(currencyId, newAmount)
        -- A currency change may affect button afford states
        self:_refreshAllUpgradeButtons()
    end)

    -- UpgradesSync: ({ [upgradeId]: level }) — fired on join
    local c2 = UpgradeRemotes.UpgradesSync.OnClientEvent:Connect(function(
        levels: { [string]: number }
    )
        self:UpdateUpgradeDisplays(levels)
    end)

    -- UpgradePurchased: (upgradeId, newLevel, nextCost)
    local c3 = UpgradeRemotes.UpgradePurchased.OnClientEvent:Connect(function(
        upgradeId: string,
        newLevel:  number,
        nextCost:  number
    )
        self:RefreshUpgradeButton(upgradeId, newLevel, nextCost)
    end)

    -- PrestigeSync: (level, multiplier) — fired on join
    local c4 = PrestigeRemotes.PrestigeSync.OnClientEvent:Connect(function(
        level:      number,
        multiplier: number
    )
        self:UpdatePrestigeDisplay(level, multiplier)
    end)

    -- PrestigeCompleted: (newLevel, pointsEarned) — fired after successful prestige
    local c5 = PrestigeRemotes.PrestigeCompleted.OnClientEvent:Connect(function(
        newLevel:     number,
        pointsEarned: number
    )
        -- The server fires CurrencyChanged for the new balances separately,
        -- so we only handle the fanfare and prestige-specific UI here.
        -- We synthesize a multiplier from the config formula for display.
        local f = PrestigeConfig.multiplierFormula
        local mult = f.baseMultiplier + (f.multiplierPerLevel * newLevel)
        self:UpdatePrestigeDisplay(newLevel, mult)
        self:ShowPrestigeFanfare(newLevel, pointsEarned)
    end)

    table.insert(self._connections, c1)
    table.insert(self._connections, c2)
    table.insert(self._connections, c3)
    table.insert(self._connections, c4)
    table.insert(self._connections, c5)
end

-- ── Private: Label tween ──────────────────────────────────────────────────────

--[[
    Animates a single TextLabel from its current tween state to `target`.
    If a tween is already running it is cancelled first so the new animation
    starts from the mid-flight value rather than jumping.
--]]
function UIService:_tweenLabel(label: TextLabel, state: LabelTweenState, target: number)
    -- Cancel any in-flight tween
    if state.tween then
        state.tween:Cancel()
        state.tween = nil
    end

    local duration = UIConfig.TWEEN_DURATION

    if duration <= 0 then
        -- Instant snap — no tween needed
        state.displayValue = target
        label.Text = formatNumber(target)
        return
    end

    -- We tween a NumberValue proxy because TextLabel has no numeric property
    -- we can tween directly. We manage the value manually each frame instead
    -- to avoid creating an Instance per label.
    --
    -- Strategy: use a BindableEvent-free approach by storing start/end/startTime
    -- and driving the label from a single RenderStepped connection that we
    -- disconnect when done. This keeps Instance count at zero.

    local startValue = state.displayValue
    local startTime  = os.clock()
    local tweenInfo  = self:_getTweenInfo()
    local totalTime  = tweenInfo.Time

    -- Build a simple lerp connection
    local RunService = game:GetService("RunService")
    local conn: RBXScriptConnection

    -- Easing function matching UIConfig settings.
    -- We implement Quad Out inline to avoid a TweenService call per frame.
    local function easeQuadOut(t: number): number
        return 1 - (1 - t) * (1 - t)
    end

    -- Allow other easing styles to fall back to linear
    local easingStyle = UIConfig.TWEEN_EASING_STYLE
    local easingDir   = UIConfig.TWEEN_EASING_DIRECTION

    local function ease(t: number): number
        -- Clamp t to [0, 1]
        t = math.clamp(t, 0, 1)
        if easingStyle == "Quad" and easingDir == "Out" then
            return easeQuadOut(t)
        elseif easingStyle == "Quad" and easingDir == "In" then
            return t * t
        elseif easingStyle == "Quad" and easingDir == "InOut" then
            return t < 0.5 and 2 * t * t or 1 - (-2 * t + 2)^2 / 2
        else
            return t  -- linear fallback
        end
    end

    conn = RunService.Heartbeat:Connect(function()
        local elapsed = os.clock() - startTime
        local t = math.min(elapsed / totalTime, 1)
        local eased = ease(t)

        local current = startValue + (target - startValue) * eased
        state.displayValue = current
        label.Text = formatNumber(current)

        if t >= 1 then
            -- Animation complete
            state.displayValue = target
            label.Text = formatNumber(target)
            conn:Disconnect()
            state.tween = nil
        end
    end)

    -- Store a sentinel so we can cancel this "tween" if another update arrives
    -- We repurpose the tween field as a connection wrapper
    state.tween = {
        Cancel = function()
            conn:Disconnect()
        end,
    } :: any
end

-- ── Private: Upgrade button refresh ──────────────────────────────────────────

--[[
    Computes the next-level cost for an upgrade from cached state.
    Returns -1 if the upgrade is at maxLevel (matches UpgradeService sentinel).
--]]
local function computeNextCost(upgradeId: string, currentLevel: number): number
    local def = UpgradeConfig.Map[upgradeId]
    if not def then return 0 end

    local nextLevel = currentLevel + 1
    if def.maxLevel > 0 and nextLevel > def.maxLevel then
        return -1 -- maxed
    end

    return math.floor(def.cost.amount * (def.costScaling ^ (nextLevel - 1)))
end

--[[
    Applies colour and cost label to a single button based on current cache state.
--]]
function UIService:_applyButtonState(binding: ButtonBinding)
    local def = UpgradeConfig.Map[binding.upgradeId]
    if not def then return end

    local level    = self._upgradeCache[binding.upgradeId] or 0
    local nextCost = self._nextCostCache[binding.upgradeId] or computeNextCost(binding.upgradeId, level)
    local button   = binding.button

    -- Guard: button may have been destroyed
    if not button or not button.Parent then return end

    local color: Color3
    local costText: string

    if nextCost < 0 then
        -- Maxed
        color    = UIConfig.BUTTON_MAXED
        costText = "MAX"
        button.Active = false
    else
        local balance  = self._currencyCache[def.cost.currencyId] or 0
        local canAfford = balance >= nextCost
        color    = canAfford and UIConfig.BUTTON_CAN_AFFORD or UIConfig.BUTTON_CANNOT_AFFORD
        costText = formatNumber(nextCost) .. " " .. def.cost.currencyId
        button.Active = canAfford
    end

    button.BackgroundColor3 = color

    -- Update "Cost" child label if present
    local costLabel = button:FindFirstChild("Cost")
    if costLabel and costLabel:IsA("TextLabel") then
        (costLabel :: TextLabel).Text = costText
    end

    -- Update "Level" child label if present
    local levelLabel = button:FindFirstChild("Level")
    if levelLabel and levelLabel:IsA("TextLabel") then
        (levelLabel :: TextLabel).Text = "Lv " .. tostring(level)
    end
end

--[[
    Iterates every bound button and refreshes its visual state.
    Called after any currency balance change that might flip an afford check.
--]]
function UIService:_refreshAllUpgradeButtons()
    for _, binding in self._buttonBindings do
        self:_applyButtonState(binding)
    end
end

-- ── Public: Formatting ────────────────────────────────────────────────────────

--[[
    Formats any non-negative number according to UIConfig display rules.
    Delegates to the module-local formatNumber function.
--]]
function UIService:FormatNumber(n: number): string
    return formatNumber(n)
end

-- ── Public: Label Binding ─────────────────────────────────────────────────────

--[[
    Registers `label` to auto-update whenever `currencyId` changes.

    The label is immediately set to the current cached balance so it shows
    a correct value even if this is called after the first CurrencyChanged
    event has already fired.

    @return () -> ()  — unsubscribe / remove this binding
--]]
function UIService:BindLabel(label: TextLabel, currencyId: string): () -> ()
    assert(label and label:IsA("TextLabel"), "[UIService] BindLabel: label must be a TextLabel")
    assert(type(currencyId) == "string",     "[UIService] BindLabel: currencyId must be a string")

    if not self._labelBindings[currencyId] then
        self._labelBindings[currencyId] = {}
    end

    local initialValue = self._currencyCache[currencyId] or 0
    local state: LabelTweenState = {
        displayValue = initialValue,
        tween        = nil,
    }

    label.Text = formatNumber(initialValue)
    self._labelBindings[currencyId][label] = state

    return function()
        self:UnbindLabel(label, currencyId)
    end
end

--[[
    Removes a label binding. Safe to call if the binding does not exist.
--]]
function UIService:UnbindLabel(label: TextLabel, currencyId: string)
    local group = self._labelBindings[currencyId]
    if not group then return end
    local state = group[label]
    if state and state.tween then
        state.tween:Cancel()
    end
    group[label] = nil
end

-- ── Public: Upgrade Button Binding ───────────────────────────────────────────

--[[
    Registers `button` to reflect the afford/maxed state of `upgradeId`.

    On every CurrencyChanged or UpgradePurchased event the button's colour,
    Active flag, and "Cost"/"Level" child labels are refreshed automatically.
    An immediate refresh is applied as soon as this is called.

    Expects the button to have (optionally):
        button.Cost  : TextLabel  — displays next-level cost
        button.Level : TextLabel  — displays current level

    @return () -> ()  — unsubscribe / remove this binding
--]]
function UIService:BindUpgradeButton(button: TextButton, upgradeId: string): () -> ()
    assert(button and button:IsA("TextButton"), "[UIService] BindUpgradeButton: button must be a TextButton")
    assert(UpgradeConfig.Map[upgradeId],
        string.format("[UIService] BindUpgradeButton: unknown upgradeId '%s'", upgradeId))

    local binding: ButtonBinding = {
        upgradeId = upgradeId,
        button    = button,
    }

    self._buttonBindings[button] = binding
    self:_applyButtonState(binding)

    -- Wire the click to RequestPurchase
    local clickConn = button.MouseButton1Click:Connect(function()
        if not button.Active then return end
        task.spawn(function()
            local ok, reason, _newLevel = UpgradeRemotes.RequestPurchase:InvokeServer(upgradeId)
            if not ok then
                warn(string.format("[UIService] Purchase failed for '%s': %s", upgradeId, tostring(reason)))
            end
        end)
    end)

    table.insert(self._connections, clickConn)

    return function()
        self._buttonBindings[button] = nil
        clickConn:Disconnect()
    end
end

-- ── Public: Display Updaters ──────────────────────────────────────────────────

--[[
    Drives all labels bound to `currencyId` to `newAmount` with a tween.
    Updates the currency cache so future button afford checks are correct.
    Called automatically by the CurrencyChanged listener.
--]]
function UIService:UpdateCurrencyDisplay(currencyId: string, newAmount: number)
    self._currencyCache[currencyId] = newAmount

    local group = self._labelBindings[currencyId]
    if not group then return end

    for label, state in group do
        -- Guard: label may have been destroyed without being explicitly unbound
        if label and label.Parent then
            self:_tweenLabel(label, state, newAmount)
        else
            group[label] = nil
        end
    end
end

--[[
    Refreshes all bound upgrade buttons from a bulk level map.
    Called automatically by the UpgradesSync listener on join.
    @param levels { [upgradeId]: number }
--]]
function UIService:UpdateUpgradeDisplays(levels: { [string]: number })
    for upgradeId, level in levels do
        self._upgradeCache[upgradeId] = level
        -- Recompute next cost from level
        self._nextCostCache[upgradeId] = computeNextCost(upgradeId, level)
    end
    self:_refreshAllUpgradeButtons()
end

--[[
    Refreshes a single upgrade button after a confirmed purchase.
    Called automatically by the UpgradePurchased listener.
    @param nextCost  number  — -1 signals the upgrade is now maxed
--]]
function UIService:RefreshUpgradeButton(upgradeId: string, newLevel: number, nextCost: number)
    self._upgradeCache[upgradeId]  = newLevel
    self._nextCostCache[upgradeId] = nextCost

    -- Refresh only buttons bound to this specific upgrade
    for _, binding in self._buttonBindings do
        if binding.upgradeId == upgradeId then
            self:_applyButtonState(binding)
        end
    end
end

--[[
    Updates prestige-related display elements.

    Treats "PrestigeLevel" and "PrestigeMultiplier" as virtual currency IDs so
    any labels bound to those strings update automatically through the normal
    BindLabel pathway.

    Also recolours a prestige button registered under "PrestigeButton" screen
    name to reflect whether the player can currently prestige (using the cached
    Gold balance vs PrestigeConfig.minimumGoldRequired).

    Called automatically by PrestigeSync on join and PrestigeCompleted after reset.
--]]
function UIService:UpdatePrestigeDisplay(level: number, multiplier: number)
    self._prestigeLevel      = level
    self._prestigeMultiplier = multiplier

    -- Drive labels bound to the virtual "PrestigeLevel" key
    local levelGroup = self._labelBindings["PrestigeLevel"]
    if levelGroup then
        for label, state in levelGroup do
            if label and label.Parent then
                self:_tweenLabel(label, state, level)
            end
        end
    end

    -- Drive labels bound to the virtual "PrestigeMultiplier" key
    -- We set them to the multiplier value; BindLabel will format it numerically.
    local multGroup = self._labelBindings["PrestigeMultiplier"]
    if multGroup then
        for label, state in multGroup do
            if label and label.Parent then
                self:_tweenLabel(label, state, multiplier)
            end
        end
    end
end

--[[
    Plays the prestige fanfare overlay.

    Looks for a ScreenGui registered under "PrestigeFanfare". If found:
      1. Sets Enabled = true
      2. Waits UIConfig.FANFARE_DURATION seconds
      3. Sets Enabled = false

    If the screen has a child TextLabel named "PrestigeLevel" or "PointsEarned",
    their Text is updated before display.

    This is deliberately simple — replace or extend for particle effects, etc.
--]]
function UIService:ShowPrestigeFanfare(newLevel: number, pointsEarned: number)
    local screens = self._screens["PrestigeFanfare"]
    if not screens or #screens == 0 then return end

    task.spawn(function()
        for _, screen in screens do
            if not screen or not screen.Parent then continue end

            -- Populate any info labels inside the fanfare GUI
            local lvlLabel = screen:FindFirstChild("PrestigeLevel", true)
            if lvlLabel and lvlLabel:IsA("TextLabel") then
                (lvlLabel :: TextLabel).Text = "Prestige " .. tostring(newLevel)
            end

            local ptsLabel = screen:FindFirstChild("PointsEarned", true)
            if ptsLabel and ptsLabel:IsA("TextLabel") then
                (ptsLabel :: TextLabel).Text = "+" .. formatNumber(pointsEarned) .. " ⭐"
            end

            screen.Enabled = true
        end

        task.wait(UIConfig.FANFARE_DURATION)

        for _, screen in screens do
            if screen and screen.Parent then
                screen.Enabled = false
            end
        end
    end)
end

-- ── Public: Screen Registry ───────────────────────────────────────────────────

--[[
    Adds a ScreenGui to the named registry.
    Multiple ScreenGuis can share a name — all are shown/hidden together.
--]]
function UIService:RegisterScreen(name: string, screenGui: ScreenGui)
    assert(type(name) == "string" and #name > 0, "[UIService] RegisterScreen: name must be a non-empty string")
    assert(screenGui and screenGui:IsA("ScreenGui"), "[UIService] RegisterScreen: screenGui must be a ScreenGui")

    if not self._screens[name] then
        self._screens[name] = {}
    end
    table.insert(self._screens[name], screenGui)
end

--[[
    Removes a specific ScreenGui from the named registry.
--]]
function UIService:UnregisterScreen(name: string, screenGui: ScreenGui)
    local list = self._screens[name]
    if not list then return end
    for i, gui in list do
        if gui == screenGui then
            table.remove(list, i)
            return
        end
    end
end

--[[
    Sets Enabled = true on all ScreenGuis registered under `name`.
--]]
function UIService:ShowScreen(name: string)
    local list = self._screens[name]
    if not list then return end
    for _, gui in list do
        if gui and gui.Parent then
            gui.Enabled = true
        end
    end
end

--[[
    Sets Enabled = false on all ScreenGuis registered under `name`.
--]]
function UIService:HideScreen(name: string)
    local list = self._screens[name]
    if not list then return end
    for _, gui in list do
        if gui and gui.Parent then
            gui.Enabled = false
        end
    end
end

-- ── Public: Teardown ──────────────────────────────────────────────────────────

--[[
    Disconnects all Remote listeners, cancels all running label tweens,
    and clears all internal tables. Primarily for unit-test teardown.
--]]
function UIService:Destroy()
    -- Cancel in-flight label tweens
    for _, group in self._labelBindings do
        for _, state in group do
            if state.tween then
                state.tween:Cancel()
            end
        end
    end

    -- Disconnect all connections (Remote listeners + button click connections)
    for _, conn in self._connections do
        conn:Disconnect()
    end

    table.clear(self._labelBindings)
    table.clear(self._buttonBindings)
    table.clear(self._currencyCache)
    table.clear(self._upgradeCache)
    table.clear(self._nextCostCache)
    table.clear(self._screens)
    table.clear(self._connections)

    _instance = nil
end

-- ── Return ────────────────────────────────────────────────────────────────────

return UIService
