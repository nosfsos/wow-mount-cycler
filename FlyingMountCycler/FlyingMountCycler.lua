local addonName = ...
-- Display name for Esc → Options → AddOns (matches ## Title in .toc).
local SETTINGS_TITLE = "Flying Mount Cycler"

local FlyingMountCycler = CreateFrame("Frame")

--- Base flying mount type IDs (always treated as flying for pool split).
local BASE_FLYING_MOUNT_TYPE_IDS = {
    [242] = true,
    [247] = true,
    [248] = true,
}

--- Skyriding / dual-flight families (optional via settings).
local SKYRIDING_MOUNT_TYPE_IDS = {
    [398] = true,
    [407] = true,
    [424] = true,
}

--- Zone mode values (dropdown); aligned with MountUp-style behavior where useful.
local ZONE_MODE = {
    AUTO = 1,
    FLYING_ONLY = 2,
    GROUND_ONLY = 3,
    ANY_FAVORITE = 4,
}

local DEFAULT_OPTIONS = {
    zoneMode = ZONE_MODE.AUTO,
    includeSkyriding = true,
    cycleWithoutRepeats = true,
    resetCycleOnLogin = false,
    showChatMessages = true,
}

local db
local settingsCategory

local function mergeDefaults(target)
    target.options = target.options or {}
    local o = target.options
    for key, value in pairs(DEFAULT_OPTIONS) do
        if o[key] == nil then
            o[key] = value
        end
    end
end

local function printMessage(text, forceWhenQuiet)
    if not forceWhenQuiet and db and db.options and db.options.showChatMessages == false then
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99FlyingMountCycler:|r " .. text)
end

local function getFlyingTypeLookup()
    local lookup = {}
    for id in pairs(BASE_FLYING_MOUNT_TYPE_IDS) do
        lookup[id] = true
    end
    if db.options.includeSkyriding then
        for id in pairs(SKYRIDING_MOUNT_TYPE_IDS) do
            lookup[id] = true
        end
    end
    return lookup
end

local function copyArray(source)
    local out = {}
    for i = 1, #source do
        out[i] = source[i]
    end
    return out
end

--- summonKind: "flying" | "ground" | "any"
local function buildFavoritePool(summonKind)
    local pool = {}
    local mountIDs = C_MountJournal.GetMountIDs() or {}
    local flyingLookup = getFlyingTypeLookup()

    for _, mountID in ipairs(mountIDs) do
        local name, _, _, _, isUsable, _, isFavorite, _, _, shouldHideOnChar, isCollected =
            C_MountJournal.GetMountInfoByID(mountID)
        if name and isCollected and isUsable and isFavorite and not shouldHideOnChar then
            local _, _, _, _, mountTypeID = C_MountJournal.GetMountInfoExtraByID(mountID)
            local isFlyingMountType = type(mountTypeID) == "number" and flyingLookup[mountTypeID]
            local include
            if summonKind == "any" then
                include = true
            elseif summonKind == "flying" then
                include = isFlyingMountType
            else
                include = not isFlyingMountType
            end
            if include then
                pool[#pool + 1] = mountID
            end
        end
    end

    return pool
end

local function retainOnlyCurrentPool(remaining, poolLookup)
    local filtered = {}
    for _, mountID in ipairs(remaining) do
        if poolLookup[mountID] then
            filtered[#filtered + 1] = mountID
        end
    end
    return filtered
end

local function rebuildCycleIfNeeded(pool, poolKey)
    local poolLookup = {}
    for _, mountID in ipairs(pool) do
        poolLookup[mountID] = true
    end

    db.remainingMountIDs = db.remainingMountIDs or {}
    db.remainingMountIDs[poolKey] = retainOnlyCurrentPool(db.remainingMountIDs[poolKey] or {}, poolLookup)
    if #db.remainingMountIDs[poolKey] == 0 then
        db.remainingMountIDs[poolKey] = copyArray(pool)
    end
end

local function resolveSummonKind()
    local mode = db.options.zoneMode or ZONE_MODE.AUTO
    if mode == ZONE_MODE.FLYING_ONLY then
        return "flying"
    elseif mode == ZONE_MODE.GROUND_ONLY then
        return "ground"
    elseif mode == ZONE_MODE.ANY_FAVORITE then
        return "any"
    end
    return IsFlyableArea() and "flying" or "ground"
end

local function summonNextFavoriteMount()
    local summonKind = resolveSummonKind()
    local poolKey = summonKind
    local pool = buildFavoritePool(summonKind)
    if #pool == 0 then
        if summonKind == "flying" then
            printMessage("No usable favorite flying mounts match your filters.", true)
        elseif summonKind == "ground" then
            printMessage("No usable favorite ground mounts match your filters.", true)
        else
            printMessage("No usable favorite mounts found.", true)
        end
        return
    end

    if db.options.cycleWithoutRepeats then
        rebuildCycleIfNeeded(pool, poolKey)
        local remaining = db.remainingMountIDs[poolKey]
        local pickIndex = math.random(#remaining)
        local mountID = remaining[pickIndex]
        table.remove(remaining, pickIndex)
        C_MountJournal.SummonByID(mountID)
    else
        C_MountJournal.SummonByID(pool[math.random(#pool)])
    end
end

local COMBAT_NO_MOUNT_MSG = "Cannot mount in combat."

local function warnCannotMountInCombat()
    printMessage(COMBAT_NO_MOUNT_MSG, true)
    UIErrorsFrame:AddMessage(COMBAT_NO_MOUNT_MSG, 1.0, 0.25, 0.25)
end

--- Dismiss current mount (SummonByID toggles off when already active; works from user-initiated slash).
local function dismountIfMounted()
    if not IsMounted() then
        return
    end
    local getSummoned = C_MountJournal.GetSummonedMountID
    if getSummoned then
        local mountID = getSummoned()
        if mountID and mountID > 0 then
            C_MountJournal.SummonByID(mountID)
            return
        end
    end
    pcall(Dismount)
end

local function resetCycle()
    db.remainingMountIDs = {
        flying = {},
        ground = {},
        any = {},
    }
    printMessage("Cycle reset. Your next summon starts a fresh round.")
end

local function openAddonSettings()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end

local function registerSettings()
    if settingsCategory then
        return
    end

    local category = Settings.RegisterVerticalLayoutCategory(SETTINGS_TITLE)
    local opts = db.options

    do
        local variable = "FMC_ZoneMode"
        local variableKey = "zoneMode"
        local defaultValue = DEFAULT_OPTIONS.zoneMode
        local name = "Mount pool"
        local tooltip =
            "Match zone: flying-type favorites in flyable areas, ground-type elsewhere (similar to MountUp zone priority).\n\nAlways flying / ground: ignore zone and only pick from that pool.\n\nAny favorite: all starred mounts, ignoring flying vs ground."
        local function zoneModeOptions()
            local container = Settings.CreateControlTextContainer()
            container:Add(ZONE_MODE.AUTO, "Match zone (flying vs ground)")
            container:Add(ZONE_MODE.FLYING_ONLY, "Always flying-type favorites")
            container:Add(ZONE_MODE.GROUND_ONLY, "Always ground-type favorites")
            container:Add(ZONE_MODE.ANY_FAVORITE, "Any favorite (ignore type)")
            return container:GetData()
        end
        local setting = Settings.RegisterAddOnSetting(
            category,
            variable,
            variableKey,
            opts,
            type(defaultValue),
            name,
            defaultValue
        )
        Settings.CreateDropdown(category, setting, zoneModeOptions, tooltip)
    end

    do
        local variable = "FMC_IncludeSkyriding"
        local variableKey = "includeSkyriding"
        local defaultValue = DEFAULT_OPTIONS.includeSkyriding
        local name = "Include skyriding mount types in the flying pool"
        local tooltip =
            "When enabled, dragonriding / skyriding families count as flying for pool selection. Turn off if you only want classic flying types in the flying pool."
        local setting = Settings.RegisterAddOnSetting(
            category,
            variable,
            variableKey,
            opts,
            type(defaultValue),
            name,
            defaultValue
        )
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    do
        local variable = "FMC_CycleWithoutRepeats"
        local variableKey = "cycleWithoutRepeats"
        local defaultValue = DEFAULT_OPTIONS.cycleWithoutRepeats
        local name = "Cycle without repeats"
        local tooltip =
            "When enabled, you will not see the same mount again until every mount in the current pool has been used (per pool: flying, ground, or any)."
        local setting = Settings.RegisterAddOnSetting(
            category,
            variable,
            variableKey,
            opts,
            type(defaultValue),
            name,
            defaultValue
        )
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    do
        local variable = "FMC_ResetCycleOnLogin"
        local variableKey = "resetCycleOnLogin"
        local defaultValue = DEFAULT_OPTIONS.resetCycleOnLogin
        local name = "Reset cycle on login"
        local tooltip = "When enabled, repeat-tracking is cleared each time you log in on this character."
        local setting = Settings.RegisterAddOnSetting(
            category,
            variable,
            variableKey,
            opts,
            type(defaultValue),
            name,
            defaultValue
        )
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    do
        local variable = "FMC_ShowChatMessages"
        local variableKey = "showChatMessages"
        local defaultValue = DEFAULT_OPTIONS.showChatMessages
        local name = "Chat messages (load / reset)"
        local tooltip = "Show optional chat feedback when the addon loads or when you reset the cycle. Errors (e.g. empty pool) still print."
        local setting = Settings.RegisterAddOnSetting(
            category,
            variable,
            variableKey,
            opts,
            type(defaultValue),
            name,
            defaultValue
        )
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

SLASH_FLYINGMOUNTCYCLER1 = "/fmount"
SLASH_FLYINGMOUNTCYCLER2 = "/flyingmount"
SLASH_FLYINGMOUNTCYCLER3 = "/fmc"
SlashCmdList.FLYINGMOUNTCYCLER = function(msg)
    local command = strlower(strtrim(msg or ""))
    if command == "reset" then
        resetCycle()
        return
    end
    if command == "config" or command == "options" then
        openAddonSettings()
        return
    end

    if UnitAffectingCombat("player") then
        if IsMounted() then
            dismountIfMounted()
        else
            warnCannotMountInCombat()
        end
        return
    end

    summonNextFavoriteMount()
end

FlyingMountCycler:SetScript("OnEvent", function(_, event, loadedAddonName, ...)
    if event == "ADDON_LOADED" and loadedAddonName == addonName then
        FlyingMountCyclerDB = FlyingMountCyclerDB or {}
        FlyingMountCyclerDB.remainingMountIDs = FlyingMountCyclerDB.remainingMountIDs or {}
        FlyingMountCyclerDB.remainingMountIDs.flying = FlyingMountCyclerDB.remainingMountIDs.flying or {}
        FlyingMountCyclerDB.remainingMountIDs.ground = FlyingMountCyclerDB.remainingMountIDs.ground or {}
        FlyingMountCyclerDB.remainingMountIDs.any = FlyingMountCyclerDB.remainingMountIDs.any or {}
        db = FlyingMountCyclerDB
        mergeDefaults(db)
        registerSettings()
        printMessage("Loaded. |cffaaaaaa/fmount|r — next mount, |cffaaaaaa/fmount reset|r — reset cycle, |cffaaaaaa/fmount config|r — options.|r")
        return
    end

    if event == "PLAYER_LOGIN" then
        if db and db.options and db.options.resetCycleOnLogin then
            db.remainingMountIDs = {
                flying = {},
                ground = {},
                any = {},
            }
        end
    end
end)

FlyingMountCycler:RegisterEvent("ADDON_LOADED")
FlyingMountCycler:RegisterEvent("PLAYER_LOGIN")
