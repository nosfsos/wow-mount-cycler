local _, ns = ...

local C_MountJournal = C_MountJournal
local IsFlyableArea  = IsFlyableArea
local IsMounted      = IsMounted
local TimerAfter     = C_Timer and C_Timer.After

local CycleState = ns.CycleState
local ZONE_MODE = ns.ZONE_MODE
local POOL_KEYS = ns.POOL_KEYS

--------------------------------------------------------------------------------
-- Flying-type lookup (cached; rebuilt when skyriding pref changes)
--------------------------------------------------------------------------------

local flyingLookupCache
local flyingLookupCacheIncludeSkyriding

local function getFlyingTypeLookup()
    local db = ns.db
    local includeSkyriding = db.options.includeSkyriding
    if flyingLookupCache and flyingLookupCacheIncludeSkyriding == includeSkyriding then
        return flyingLookupCache
    end
    flyingLookupCacheIncludeSkyriding = includeSkyriding
    local lookup = {}
    for id in pairs(ns.BASE_FLYING_MOUNT_TYPE_IDS) do
        lookup[id] = true
    end
    if includeSkyriding then
        for id in pairs(ns.SKYRIDING_MOUNT_TYPE_IDS) do
            lookup[id] = true
        end
    end
    flyingLookupCache = lookup
    return lookup
end

--------------------------------------------------------------------------------
-- Active mount resolution
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Pool building
--------------------------------------------------------------------------------

local function buildFavoritePool(summonKind, ignoreUsable)
    local pool = {}
    local mountIDs = C_MountJournal.GetMountIDs() or {}
    local flyingLookup = getFlyingTypeLookup()

    for _, mountID in ipairs(mountIDs) do
        local name, _, _, _, isUsable, _, isFavorite, _, _, shouldHideOnChar, isCollected =
            C_MountJournal.GetMountInfoByID(mountID)
        if name and isCollected and (ignoreUsable or isUsable) and isFavorite and not shouldHideOnChar then
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

--------------------------------------------------------------------------------
-- Cycle management
--------------------------------------------------------------------------------

local function setFreshCyclePool(poolKey, pool)
    local db = ns.db
    db.cycleMountIDs[poolKey] = ns.copyArray(pool)
    db.remainingMountIDs[poolKey] = ns.copyArray(pool)
end

local function announceCycleReset(reason, poolKeys)
    local db = ns.db
    if not db or not db.options or db.options.showResetAnnouncements ~= true then
        return
    end

    local warningText
    if #poolKeys == 1 then
        warningText = string.format("%s cycle reset: %s", poolKeys[1], reason)
    else
        warningText = "Cycle reset: " .. reason
    end

    ns.warnResetAnnouncement(warningText)
    ns.printResetAnnouncementMessage(warningText .. ".")

    local parts = {}
    for i = 1, #poolKeys do
        local poolKey = poolKeys[i]
        local n = #(db.remainingMountIDs[poolKey] or {})
        parts[#parts + 1] = string.format("%s: %d", poolKey, n)
    end
    if #parts > 0 then
        ns.printCycleRemainingMessage(
            "No-repeat cycle — " .. table.concat(parts, ", ") .. " left until refill."
        )
    end
end

local function removeMountFromAllCycleQueues(mountID)
    for _, poolKey in ipairs(POOL_KEYS) do
        if isFavoriteInPoolIgnoringUsable(poolKey, mountID) then
            local pool = buildFavoritePool(poolKey, true)
            local result = CycleState.consumeMountFromPool(ns.db, poolKey, pool, mountID)
            if result.refilled then
                announceCycleReset("reached the end of the list", { poolKey })
            end
        end
    end
end

--------------------------------------------------------------------------------
-- No-repeat cycle tracking
--------------------------------------------------------------------------------

local mountAnnounceDeferSeq = 0
local lastProcessedNoRepeatMountID

local function announceNoRepeatCycleProgress(mountID)
    local db = ns.db
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
    ns.printCycleRemainingMessage(
        "No-repeat cycle — " .. table.concat(parts, ", ") .. " left until refill."
    )
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
    local db = ns.db
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

function ns.scheduleNoRepeatCycleUpdateFromMountState()
    if not IsMounted() then
        lastProcessedNoRepeatMountID = nil
        mountAnnounceDeferSeq = mountAnnounceDeferSeq + 1
        return
    end
    local db = ns.db
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

--------------------------------------------------------------------------------
-- Refresh & summon
--------------------------------------------------------------------------------

local function ensureRemainingPoolReady(poolKey, pool)
    local remaining = CycleState.ensureRemainingPoolReady(ns.db, poolKey, pool)
    return remaining
end

function ns.refreshAvailableMounts(showChatFeedback)
    local db = ns.db
    db.remainingMountIDs = db.remainingMountIDs or ns.newEmptyRemainingPools()
    db.cycleMountIDs     = db.cycleMountIDs or ns.newEmptyRemainingPools()

    local summaryParts = {}
    local anyChanges = false
    for _, poolKey in ipairs(POOL_KEYS) do
        local pool = buildFavoritePool(poolKey, true)
        local result = CycleState.syncPoolState(db, poolKey, pool)
        if result.addedCount > 0 or result.removedCount > 0 then
            anyChanges = true
            summaryParts[#summaryParts + 1] = string.format(
                "%s: +%d / -%d", poolKey, result.addedCount, result.removedCount
            )
        end
    end

    if showChatFeedback then
        if anyChanges then
            ns.printMessage(
                "Mount refresh complete. Cycle updated without resetting progress ("
                .. table.concat(summaryParts, ", ") .. ")."
            )
        else
            ns.printMessage("Mount refresh complete. No changes were needed.")
        end
    end
end

local function resolveSummonKind()
    local mode = ns.db.options.zoneMode or ZONE_MODE.AUTO
    if mode == ZONE_MODE.FLYING_ONLY then
        return "flying"
    elseif mode == ZONE_MODE.GROUND_ONLY then
        return "ground"
    elseif mode == ZONE_MODE.ANY_FAVORITE then
        return "any"
    end
    return IsFlyableArea() and "flying" or "ground"
end

function ns.summonNextFavoriteMount()
    local summonKind = resolveSummonKind()
    local usablePool = buildFavoritePool(summonKind)
    if #usablePool == 0 then
        if summonKind == "flying" then
            ns.printMessage("No usable favorite flying mounts match your filters.", true)
        elseif summonKind == "ground" then
            ns.printMessage("No usable favorite ground mounts match your filters.", true)
        else
            ns.printMessage("No usable favorite mounts found.", true)
        end
        return
    end

    if ns.db.options.cycleWithoutRepeats then
        local fullPool = buildFavoritePool(summonKind, true)
        local remaining = ensureRemainingPoolReady(summonKind, fullPool)

        local usableLookup = ns.poolToLookup(usablePool)
        local usableRemaining = CycleState.filterUsableMounts(remaining, usableLookup)

        if #usableRemaining == 0 then
            setFreshCyclePool(summonKind, fullPool)
            announceCycleReset("reached the end of the list", { summonKind })
            remaining = ns.db.remainingMountIDs[summonKind] or {}
            usableRemaining = CycleState.filterUsableMounts(remaining, usableLookup)
            if #usableRemaining == 0 then
                ns.printMessage("No usable favorite mounts are queued for that pool right now.", true)
                return
            end
        end
        local mountID = usableRemaining[math.random(#usableRemaining)]
        C_MountJournal.SummonByID(mountID)
    else
        C_MountJournal.SummonByID(usablePool[math.random(#usablePool)])
    end
end

--------------------------------------------------------------------------------
-- Cycle reset
--------------------------------------------------------------------------------

function ns.resetCycle(reason)
    local db = ns.db
    db.remainingMountIDs = ns.newEmptyRemainingPools()
    db.cycleMountIDs     = ns.newEmptyRemainingPools()

    for _, poolKey in ipairs(POOL_KEYS) do
        setFreshCyclePool(poolKey, buildFavoritePool(poolKey, true))
    end

    announceCycleReset(reason or "reset command used", POOL_KEYS)
end

--------------------------------------------------------------------------------
-- Combat / dismount
--------------------------------------------------------------------------------

local COMBAT_NO_MOUNT_MSG = "Cannot mount in combat."

function ns.warnCannotMountInCombat()
    ns.printMessage(COMBAT_NO_MOUNT_MSG, true)
    UIErrorsFrame:AddMessage(COMBAT_NO_MOUNT_MSG, 1.0, 0.25, 0.25)
end

function ns.dismountIfMounted()
    if not IsMounted() then
        return
    end
    if C_MountJournal.Dismiss then
        C_MountJournal.Dismiss()
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
