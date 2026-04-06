local _, ns = ...

local settingsCategory

local function buildStatusText()
    local lines = ns.getStatusReportLines and ns.getStatusReportLines() or {}
    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Settings panel (Retail Settings API)
--------------------------------------------------------------------------------

local function registerCheckbox(category, opts, addonVariable, optionKey, title, tooltip)
    local defaultValue = ns.DEFAULT_OPTIONS[optionKey]
    local setting = Settings.RegisterAddOnSetting(
        category, addonVariable, optionKey, opts,
        type(defaultValue), title, defaultValue
    )
    Settings.CreateCheckbox(category, setting, tooltip)
end

function ns.registerSettings()
    if settingsCategory then
        return
    end

    local db   = ns.db
    local opts = db.options
    local ZONE_MODE       = ns.ZONE_MODE
    local DEFAULT_OPTIONS = ns.DEFAULT_OPTIONS

    local category = Settings.RegisterVerticalLayoutCategory(ns.SETTINGS_TITLE)

    -- Zone mode dropdown
    do
        local defaultValue = DEFAULT_OPTIONS.zoneMode
        local function zoneModeOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add(ZONE_MODE.AUTO,         "Match zone (flying vs ground)")
            container:Add(ZONE_MODE.FLYING_ONLY,  "Always flying-type favorites")
            container:Add(ZONE_MODE.GROUND_ONLY,  "Always ground-type favorites")
            container:Add(ZONE_MODE.ANY_FAVORITE,  "Any favorite (ignore type)")
            return container:GetData()
        end
        local setting = Settings.RegisterAddOnSetting(
            category, "FMC_ZoneMode", "zoneMode", opts,
            type(defaultValue), "Mount pool", defaultValue
        )
        Settings.CreateDropdown(
            category, setting, zoneModeOptions,
            "Match zone: flying-type favorites in flyable areas, ground-type elsewhere."
            .. "\n\nAlways flying / ground: ignore zone and only pick from that pool."
            .. "\n\nAny favorite: all starred mounts, ignoring flying vs ground."
        )
    end

    registerCheckbox(
        category, opts,
        "FMC_IncludeSkyriding", "includeSkyriding",
        "Include skyriding mount types in the flying pool",
        "When enabled, dragonriding / skyriding families count as flying for pool selection."
    )

    -- "Cycle without repeats" with nested "show remaining" checkbox
    do
        local cycleSetting = Settings.RegisterAddOnSetting(
            category, "FMC_CycleWithoutRepeats", "cycleWithoutRepeats", opts,
            type(DEFAULT_OPTIONS.cycleWithoutRepeats), "Cycle without repeats",
            DEFAULT_OPTIONS.cycleWithoutRepeats
        )
        local cycleInit = Settings.CreateCheckbox(
            category, cycleSetting,
            "You will not see the same mount again until every mount in the current pool has been used."
        )

        local remainSetting = Settings.RegisterAddOnSetting(
            category, "FMC_ShowCycleRemainingChat", "showCycleRemainingChat", opts,
            type(DEFAULT_OPTIONS.showCycleRemainingChat), "Chat: mounts left until cycle refill",
            DEFAULT_OPTIONS.showCycleRemainingChat
        )
        local remainInit = Settings.CreateCheckbox(
            category, remainSetting,
            "After you mount, print how many favorites are still queued before the no-repeat pool refills."
        )
        remainInit:SetParentInitializer(cycleInit, function()
            return opts.cycleWithoutRepeats
        end)
        remainInit:Indent()

        local function recentHistoryOptions()
            local container = Settings.CreateControlTextContainer()
            for _, count in ipairs(ns.RECENT_HISTORY_COUNTS) do
                if count == 0 then
                    container:Add(count, "Disabled")
                elseif count == 1 then
                    container:Add(count, "Avoid the last mount")
                else
                    container:Add(count, "Avoid the last " .. count .. " mounts")
                end
            end
            return container:GetData()
        end
        local recentSetting = Settings.RegisterAddOnSetting(
            category, "FMC_RecentHistoryCount", "recentHistoryCount", opts,
            type(DEFAULT_OPTIONS.recentHistoryCount), "Recent-history avoidance",
            DEFAULT_OPTIONS.recentHistoryCount
        )
        local recentInit = Settings.CreateDropdown(
            category, recentSetting, recentHistoryOptions,
            "When no-repeat cycling is disabled, try to avoid recently used mounts before falling back to the full usable pool."
        )
        recentInit:SetParentInitializer(cycleInit, function()
            return not opts.cycleWithoutRepeats
        end)
        recentInit:Indent()
    end

    -- "Lock mount for duration" with nested duration dropdown
    do
        local lockSetting = Settings.RegisterAddOnSetting(
            category, "FMC_MountLockEnabled", "mountLockEnabled", opts,
            type(DEFAULT_OPTIONS.mountLockEnabled), "Lock mount for a duration",
            DEFAULT_OPTIONS.mountLockEnabled
        )
        local lockInit = Settings.CreateCheckbox(
            category, lockSetting,
            "When enabled, the same mount is summoned repeatedly until the timer expires, then cycles to the next."
        )

        local function lockDurationOptions()
            local container = Settings.CreateControlTextContainer()
            for _, minutes in ipairs(ns.MOUNT_LOCK_DURATIONS) do
                if minutes < 60 then
                    container:Add(minutes, minutes .. " minutes")
                elseif minutes == 60 then
                    container:Add(minutes, "1 hour")
                else
                    container:Add(minutes, (minutes / 60) .. " hours")
                end
            end
            return container:GetData()
        end
        local durationSetting = Settings.RegisterAddOnSetting(
            category, "FMC_MountLockDuration", "mountLockDuration", opts,
            type(DEFAULT_OPTIONS.mountLockDuration), "Lock duration",
            DEFAULT_OPTIONS.mountLockDuration
        )
        local durationInit = Settings.CreateDropdown(
            category, durationSetting, lockDurationOptions,
            "How long to keep the same mount before cycling to the next one."
        )
        durationInit:SetParentInitializer(lockInit, function()
            return opts.mountLockEnabled
        end)
        durationInit:Indent()
    end

    registerCheckbox(
        category, opts,
        "FMC_ShowResetAnnouncements", "showResetAnnouncements",
        "Announce cycle resets",
        "Resetting the cycle or reaching the end of a no-repeat list prints the reset reason and the rebuilt mount list."
    )

    registerCheckbox(
        category, opts,
        "FMC_ShowChatMessages", "showChatMessages",
        "Chat messages (load / refresh)",
        "Show optional chat feedback when the addon loads or when you refresh mounts."
    )

    registerCheckbox(
        category, opts,
        "FMC_ShowDebugMessages", "showDebugMessages",
        "Debug selection messages",
        "Print selection reasoning, resolved pool, and chosen mount details to chat for troubleshooting."
    )

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category

    -- Cycle Tools sub-panel
    local refreshFrame = CreateFrame("Frame")
    refreshFrame.name = "Cycle Tools"

    local title = refreshFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Cycle Tools")

    local desc = refreshFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    desc:SetWidth(520)
    desc:SetJustifyH("LEFT")
    desc:SetJustifyV("TOP")
    desc:SetText(
        "Refresh keeps your current progress and only updates the available mounts."
        .. " Reset starts a fresh round and rebuilds all lists."
    )

    local refreshBtn = CreateFrame("Button", nil, refreshFrame, "UIPanelButtonTemplate")
    refreshBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    refreshBtn:SetSize(190, 24)
    refreshBtn:SetText("Refresh Available Mounts")
    refreshBtn:SetScript("OnClick", function() ns.refreshAvailableMounts(true) end)

    local resetBtn = CreateFrame("Button", nil, refreshFrame, "UIPanelButtonTemplate")
    resetBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 12, 0)
    resetBtn:SetSize(140, 24)
    resetBtn:SetText("Reset Cycle")
    resetBtn:SetScript("OnClick", function() ns.resetCycle("reset button used") end)

    local statusTitle = refreshFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    statusTitle:SetPoint("TOPLEFT", refreshBtn, "BOTTOMLEFT", 0, -18)
    statusTitle:SetText("Current cycle status")

    local statusText = refreshFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    statusText:SetPoint("TOPLEFT", statusTitle, "BOTTOMLEFT", 0, -8)
    statusText:SetWidth(520)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")

    local function refreshCycleToolsSummary()
        statusText:SetText(buildStatusText())
    end

    refreshFrame:SetScript("OnShow", refreshCycleToolsSummary)
    refreshBtn:HookScript("OnClick", refreshCycleToolsSummary)
    resetBtn:HookScript("OnClick", refreshCycleToolsSummary)

    Settings.RegisterCanvasLayoutSubcategory(category, refreshFrame, "Cycle Tools")
end

function ns.openAddonSettings()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end

--------------------------------------------------------------------------------
-- Addon Compartment (minimap dropdown) — these must be global functions
--------------------------------------------------------------------------------

function FlyingMountCycler_OnAddonCompartmentClick(_, mouseButton)
    if mouseButton == "LeftButton" then
        ns.openAddonSettings()
    elseif mouseButton == "RightButton" then
        ns.runDefaultMountAction()
    end
end

function FlyingMountCycler_OnAddonCompartmentEnter(_, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("Flying Mount Cycler")
    GameTooltip:AddLine("|cffffffffLeft-click|r to open settings", 1, 1, 1)
    GameTooltip:AddLine("|cffffffffRight-click|r to summon next mount", 1, 1, 1)
    local lines = ns.getStatusReportLines and ns.getStatusReportLines() or {}
    for i = 1, #lines do
        GameTooltip:AddLine(lines[i], 0.85, 0.85, 0.85)
    end
    GameTooltip:Show()
end

function FlyingMountCycler_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
