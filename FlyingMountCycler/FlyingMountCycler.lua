local addonName = ...

-- API locals (slightly cheaper than global lookups each call).
local C_MountJournal = C_MountJournal
local IsFlyableArea = IsFlyableArea
local IsMounted = IsMounted
local UnitAffectingCombat = UnitAffectingCombat
local TimerAfter = C_Timer and C_Timer.After

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
    showCycleRemainingChat = true,
    resetCycleOnLogin = false,
    showChatMessages = true,
}

local POOL_KEYS = { "flying", "ground", "any" }

--------------------------------------------------------------------------------
-- Saved state & UI
--------------------------------------------------------------------------------

local db
local settingsCategory

--- Coalesce rapid PLAYER_MOUNT_DISPLAY_CHANGED fires; only the latest deferred pass runs.
local mountAnnounceDeferSeq = 0
--- Skip duplicate processing while still on the same mount (extra display-changed events).
local lastProcessedNoRepeatMountID

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

--- No-repeat progress line (separate from general “chat messages” option).
local function printCycleRemainingMessage(text)
    if not db or not db.options or db.options.showCycleRemainingChat ~= true then
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

--- Resolve current mount ID robustly (journal API can briefly return 0 on mount change).
local function getActiveMountID()
    local getSummoned = C_MountJournal.GetSummonedMountID
    if getSummoned then
        local mountID = getSummoned()
        if mountID and mountID > 0 then
            return mountID
        end
    end

    local mountIDs = C_MountJournal.GetMountIDs() or {}
    for i = 1, #mountIDs do
        local mountID = mountIDs[i]
        local _, _, _, isActive = C_MountJournal.GetMountInfoByID(mountID)
        if isActive then
            return mountID
        end
    end
    return nil
end

-- Forward declaration (used by mount-cycle sync helpers below).
local rebuildCycleIfNeeded

--- While mounted, the journal often reports isUsable = false; still match pool/type for cycle sync + chat.
local function isFavoriteInPoolIgnoringUsable(poolKey, mountID)
    local name, _, _, _, _, _, isFavorite, _, _, shouldHideOnChar, isCollected =
        C_MountJournal.GetMountInfoByID(mountID)
    if not (name and isCollected and isFavorite and not shouldHideOnChar) then
        return false
    end
    local _, _, _, _, mountTypeID = C_MountJournal.GetMountInfoExtraByID(mountID)
    local isFlyingMountType = type(mountTypeID) == "number" and getFlyingTypeLookup()[mountTypeID]
    if poolKey == "any" then
        return true
    elseif poolKey == "flying" then
        return isFlyingMountType
    else
        return not isFlyingMountType
    end
end

--- Remove one occurrence of mountID from a pool’s remaining queue; true if something was removed.
local function removeMountFromPoolRemainingIfPresent(poolKey, mountID)
    local remaining = db.remainingMountIDs[poolKey]
    if not remaining then
        return false
    end
    for i = #remaining, 1, -1 do
        if remaining[i] == mountID then
            local n = #remaining
            remaining[i] = remaining[n]
            remaining[n] = nil
            return true
        end
    end
    return false
end

--- When the player rides a favorite, advance every cycle queue that contains that mount (journal + /fmount).
local function removeMountFromAllCycleQueues(mountID)
    for _, poolKey in ipairs(POOL_KEYS) do
        if isFavoriteInPoolIgnoringUsable(poolKey, mountID) then
            -- Keep no-repeat queues coherent even when mounting outside /fmount.
            local pool = buildFavoritePool(poolKey)
            if #pool > 0 then
                rebuildCycleIfNeeded(pool, poolKey)
            end
            removeMountFromPoolRemainingIfPresent(poolKey, mountID)
        end
    end
end

local function announceNoRepeatCycleProgress(mountID)
    local parts = {}
    for _, poolKey in ipairs(POOL_KEYS) do
        if isFavoriteInPoolIgnoringUsable(poolKey, mountID) then
            local n = #(db.remainingMountIDs[poolKey] or {})
            parts[#parts + 1] = string.format("%s: %d", poolKey, n)
        end
    end
    if #parts == 0 then
        return
    end
    printCycleRemainingMessage("No-repeat cycle — " .. table.concat(parts, ", ") .. " left until refill.")
end

local function mountQualifiesForNoRepeatSync(mountID)
    for _, poolKey in ipairs(POOL_KEYS) do
        if isFavoriteInPoolIgnoringUsable(poolKey, mountID) then
            return true
        end
    end
    return false
end

local function processMountedForNoRepeatCycle()
    if not db or not db.options or not db.options.cycleWithoutRepeats then
        return
    end
    if not IsMounted() then
        return
    end

    local mountID = getActiveMountID()
    if not mountID then
        return
    end
    if not mountQualifiesForNoRepeatSync(mountID) then
        return
    end
    if mountID == lastProcessedNoRepeatMountID then
        return
    end

    lastProcessedNoRepeatMountID = mountID
    removeMountFromAllCycleQueues(mountID)
    announceNoRepeatCycleProgress(mountID)
end

local function scheduleNoRepeatCycleUpdateFromMountState()
    if not IsMounted() then
        lastProcessedNoRepeatMountID = nil
        mountAnnounceDeferSeq = mountAnnounceDeferSeq + 1
        return
    end
    if not db or not db.options or not db.options.cycleWithoutRepeats then
        return
    end

    mountAnnounceDeferSeq = mountAnnounceDeferSeq + 1
    local seq = mountAnnounceDeferSeq
    local function runDeferred()
        if seq ~= mountAnnounceDeferSeq then
            return
        end
        processMountedForNoRepeatCycle()
    end

    if TimerAfter then
        TimerAfter(0.05, runDeferred)
    else
        runDeferred()
    end
end

--- When favorites/usability change, drop stale IDs; refill queue when empty.
rebuildCycleIfNeeded = function(pool, poolKey)
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
        local pickIndex = math.random(#remaining)
        local mountID = remaining[pickIndex]
        -- Removal from cycle queues happens on mount-state events so failed summons do not corrupt the list.
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

    do
        local cycleSetting = Settings.RegisterAddOnSetting(
            category,
            "FMC_CycleWithoutRepeats",
            "cycleWithoutRepeats",
            opts,
            type(DEFAULT_OPTIONS.cycleWithoutRepeats),
            "Cycle without repeats",
            DEFAULT_OPTIONS.cycleWithoutRepeats
        )
        local cycleInitializer = Settings.CreateCheckbox(
            category,
            cycleSetting,
            "When enabled, you will not see the same mount again until every mount in the current pool has been used (per pool: flying, ground, or any)."
        )
        local remainingSetting = Settings.RegisterAddOnSetting(
            category,
            "FMC_ShowCycleRemainingChat",
            "showCycleRemainingChat",
            opts,
            type(DEFAULT_OPTIONS.showCycleRemainingChat),
            "Chat: mounts left until cycle refill",
            DEFAULT_OPTIONS.showCycleRemainingChat
        )
        local remainingInitializer = Settings.CreateCheckbox(
            category,
            remainingSetting,
            "After you mount, print how many favorites are still queued before the no-repeat pool refills. Only applies while Cycle without repeats is on; the checkbox is disabled otherwise."
        )
        remainingInitializer:SetParentInitializer(cycleInitializer, function()
            return opts.cycleWithoutRepeats
        end)
        remainingInitializer:Indent()
    end

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
        "Show optional chat feedback when the addon loads or when you reset the cycle. No-repeat “mounts left” lines use the separate option under Cycle without repeats. Errors (e.g. empty pool) still print."
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
        return
    end

    if event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
        scheduleNoRepeatCycleUpdateFromMountState()
        return
    end

    if event == "UNIT_AURA" and loadedAddonName == "player" then
        scheduleNoRepeatCycleUpdateFromMountState()
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
eventFrame:RegisterEvent("UNIT_AURA")
