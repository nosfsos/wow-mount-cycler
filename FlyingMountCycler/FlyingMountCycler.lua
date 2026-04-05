local addonName = ...

-- API locals (slightly cheaper than global lookups each call).
local C_MountJournal = C_MountJournal
local IsFlyableArea = IsFlyableArea
local IsMounted = IsMounted
local UnitAffectingCombat = UnitAffectingCombat

-- Display name for Esc → Options → AddOns (matches ## Title in .toc).
local SETTINGS_TITLE = "Flying Mount Cycler"

local eventFrame = CreateFrame("Frame")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

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

--- Zone mode (dropdown); aligned with MountUp-style behavior where useful.
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

local POOL_KEYS = { "flying", "ground", "any" }

--------------------------------------------------------------------------------
-- Saved state & UI
--------------------------------------------------------------------------------

local db
local settingsCategory

--- Cleared cycle queues (one list per summon pool).
local function newEmptyRemainingPools()
    return {
        flying = {},
        ground = {},
        any = {},
    }
end

--- Ensure SavedVariables have expected keys for repeat-tracking.
local function ensureRemainingMountIDsShape(target)
    target.remainingMountIDs = target.remainingMountIDs or newEmptyRemainingPools()
    for _, key in ipairs(POOL_KEYS) do
        target.remainingMountIDs[key] = target.remainingMountIDs[key] or {}
    end
end

local function mergeDefaults(target)
    target.options = target.options or {}
    local o = target.options
    for key, value in pairs(DEFAULT_OPTIONS) do
        if o[key] == nil then
            o[key] = value
        end
    end
end

--------------------------------------------------------------------------------
-- Messaging
--------------------------------------------------------------------------------

local function printMessage(text, forceWhenQuiet)
    if not forceWhenQuiet and db and db.options and db.options.showChatMessages == false then
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99FlyingMountCycler:|r " .. text)
end

--------------------------------------------------------------------------------
-- Flying-type lookup (cached; rebuild only when skyriding option changes)
--------------------------------------------------------------------------------

local flyingLookupCache
local flyingLookupCacheIncludeSkyriding

local function getFlyingTypeLookup()
    local includeSkyriding = db.options.includeSkyriding
    if flyingLookupCache and flyingLookupCacheIncludeSkyriding == includeSkyriding then
        return flyingLookupCache
    end
    flyingLookupCacheIncludeSkyriding = includeSkyriding
    local lookup = {}
    for id in pairs(BASE_FLYING_MOUNT_TYPE_IDS) do
        lookup[id] = true
    end
    if includeSkyriding then
        for id in pairs(SKYRIDING_MOUNT_TYPE_IDS) do
            lookup[id] = true
        end
    end
    flyingLookupCache = lookup
    return lookup
end

--------------------------------------------------------------------------------
-- Pool building & “no repeat” cycle
--------------------------------------------------------------------------------

local function copyArray(source)
    local out = {}
    for i = 1, #source do
        out[i] = source[i]
    end
    return out
end

--- Build set of mount IDs still valid for filtering the remaining queue.
local function poolToLookup(pool)
    local poolLookup = {}
    for i = 1, #pool do
        poolLookup[pool[i]] = true
    end
    return poolLookup
end

local function retainOnlyCurrentPool(remaining, poolLookup)
    local filtered = {}
    for i = 1, #remaining do
        local mountID = remaining[i]
        if poolLookup[mountID] then
            filtered[#filtered + 1] = mountID
        end
    end
    return filtered
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

--- When favorites/usability change, drop stale IDs; refill queue when empty.
local function rebuildCycleIfNeeded(pool, poolKey)
    local poolLookup = poolToLookup(pool)

    db.remainingMountIDs = db.remainingMountIDs or newEmptyRemainingPools()
    local remaining = db.remainingMountIDs[poolKey] or {}
    db.remainingMountIDs[poolKey] = retainOnlyCurrentPool(remaining, poolLookup)

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
        -- Random pick, O(1) removal: swap with tail then truncate (avoid table.remove shift cost).
        local n = #remaining
        local pickIndex = math.random(n)
        local mountID = remaining[pickIndex]
        remaining[pickIndex] = remaining[n]
        remaining[n] = nil
        C_MountJournal.SummonByID(mountID)
    else
        C_MountJournal.SummonByID(pool[math.random(#pool)])
    end
end

--------------------------------------------------------------------------------
-- Combat / dismount
--------------------------------------------------------------------------------

local COMBAT_NO_MOUNT_MSG = "Cannot mount in combat."

local function warnCannotMountInCombat()
    printMessage(COMBAT_NO_MOUNT_MSG, true)
    UIErrorsFrame:AddMessage(COMBAT_NO_MOUNT_MSG, 1.0, 0.25, 0.25)
end

--- Dismiss mount (SummonByID toggles off when already active; safe from slash).
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

--------------------------------------------------------------------------------
-- Slash & cycle reset
--------------------------------------------------------------------------------

local function resetCycle()
    db.remainingMountIDs = newEmptyRemainingPools()
    printMessage("Cycle reset. Your next summon starts a fresh round.")
end

local function openAddonSettings()
    if settingsCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end

--------------------------------------------------------------------------------
-- Settings (Retail Settings API)
--------------------------------------------------------------------------------

local function registerCheckboxSetting(category, opts, addonVariable, optionKey, title, tooltip)
    local defaultValue = DEFAULT_OPTIONS[optionKey]
    local setting = Settings.RegisterAddOnSetting(
        category,
        addonVariable,
        optionKey,
        opts,
        type(defaultValue),
        title,
        defaultValue
    )
    Settings.CreateCheckbox(category, setting, tooltip)
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

    registerCheckboxSetting(
        category,
        opts,
        "FMC_IncludeSkyriding",
        "includeSkyriding",
        "Include skyriding mount types in the flying pool",
        "When enabled, dragonriding / skyriding families count as flying for pool selection. Turn off if you only want classic flying types in the flying pool."
    )

    registerCheckboxSetting(
        category,
        opts,
        "FMC_CycleWithoutRepeats",
        "cycleWithoutRepeats",
        "Cycle without repeats",
        "When enabled, you will not see the same mount again until every mount in the current pool has been used (per pool: flying, ground, or any)."
    )

    registerCheckboxSetting(
        category,
        opts,
        "FMC_ResetCycleOnLogin",
        "resetCycleOnLogin",
        "Reset cycle on login",
        "When enabled, repeat-tracking is cleared each time you log in on this character."
    )

    registerCheckboxSetting(
        category,
        opts,
        "FMC_ShowChatMessages",
        "showChatMessages",
        "Chat messages (load / reset)",
        "Show optional chat feedback when the addon loads or when you reset the cycle. Errors (e.g. empty pool) still print."
    )

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(_, event, loadedAddonName)
    if event == "ADDON_LOADED" and loadedAddonName == addonName then
        FlyingMountCyclerDB = FlyingMountCyclerDB or {}
        db = FlyingMountCyclerDB
        ensureRemainingMountIDsShape(db)
        mergeDefaults(db)
        registerSettings()
        printMessage("Loaded. |cffaaaaaa/fmount|r — next mount, |cffaaaaaa/fmount reset|r — reset cycle, |cffaaaaaa/fmount config|r — options.|r")
        return
    end

    if event == "PLAYER_LOGIN" then
        if db and db.options and db.options.resetCycleOnLogin then
            db.remainingMountIDs = newEmptyRemainingPools()
        end
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
