local _, ns = ...

local C_MountJournal = C_MountJournal
local IsFlyableArea  = IsFlyableArea
local IsMounted      = IsMounted
local TimerAfter     = C_Timer and C_Timer.After

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

local function rebuildCycleIfNeeded(pool, poolKey)
    local db = ns.db
    local poolLookup = ns.poolToLookup(pool)

    db.remainingMountIDs = db.remainingMountIDs or ns.newEmptyRemainingPools()
    db.cycleMountIDs     = db.cycleMountIDs or ns.newEmptyRemainingPools()

    local trackedCycle = ns.retainOnlyCurrentPool(db.cycleMountIDs[poolKey] or {}, poolLookup)
    local newMounts = {}
    if #trackedCycle == 0 then
        trackedCycle = ns.copyArray(pool)
    else
        local trackedLookup = ns.poolToLookup(trackedCycle)
        for i = 1, #pool do
            local mountID = pool[i]
            if not trackedLookup[mountID] then
                trackedCycle[#trackedCycle + 1] = mountID
                trackedLookup[mountID] = true
                newMounts[#newMounts + 1] = mountID
            end
        end
    end
    db.cycleMountIDs[poolKey] = trackedCycle

    local remaining = ns.retainOnlyCurrentPool(db.remainingMountIDs[poolKey] or {}, poolLookup)
    ns.appendArray(remaining, newMounts)
    db.remainingMountIDs[poolKey] = remaining
end

local function removeMountFromPoolRemainingIfPresent(poolKey, mountID)
    local remaining = ns.db.remainingMountIDs[poolKey]
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
    local db = ns.db
    for _, poolKey in ipairs(POOL_KEYS) do
        if isFavoriteInPoolIgnoringUsable(poolKey, mountID) then
            local pool = buildFavoritePool(poolKey, true)
            if #pool > 0 then
                rebuildCycleIfNeeded(pool, poolKey)
            end
            removeMountFromPoolRemainingIfPresent(poolKey, mountID)
            if #(db.remainingMountIDs[poolKey] or {}) == 0 then
                setFreshCyclePool(poolKey, db.cycleMountIDs[poolKey] or {})
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
    local db = ns.db
    rebuildCycleIfNeeded(pool, poolKey)

    local remaining = db.remainingMountIDs[poolKey] or {}
    if #remaining > 0 then
        return remaining
    end

    local trackedCycle = db.cycleMountIDs[poolKey] or {}
    if #trackedCycle == 0 then
        trackedCycle = ns.copyArray(pool)
        db.cycleMountIDs[poolKey] = trackedCycle
    end

    if #trackedCycle == 0 then
        return remaining
    end

    setFreshCyclePool(poolKey, trackedCycle)
    return db.remainingMountIDs[poolKey]
end

function ns.refreshAvailableMounts(showChatFeedback)
    local db = ns.db
    db.remainingMountIDs = db.remainingMountIDs or ns.newEmptyRemainingPools()
    db.cycleMountIDs     = db.cycleMountIDs or ns.newEmptyRemainingPools()

    local summaryParts = {}
    local anyChanges = false
    for _, poolKey in ipairs(POOL_KEYS) do
        local pool         = buildFavoritePool(poolKey, true)
        local poolLookup   = ns.poolToLookup(pool)
        local prevCycle    = db.cycleMountIDs[poolKey] or {}
        local prevRemain   = db.remainingMountIDs[poolKey] or {}
        local filtCycle    = ns.retainOnlyCurrentPool(prevCycle, poolLookup)
        local filtRemain   = ns.retainOnlyCurrentPool(prevRemain, poolLookup)
        local removedCount = #prevCycle - #filtCycle
        local addedMounts  = {}

        if #filtCycle == 0 then
            filtCycle = ns.copyArray(pool)
        else
            local filtCycleLookup = ns.poolToLookup(filtCycle)
            for i = 1, #pool do
                local mountID = pool[i]
                if not filtCycleLookup[mountID] then
                    filtCycle[#filtCycle + 1] = mountID
                    filtCycleLookup[mountID] = true
                    addedMounts[#addedMounts + 1] = mountID
                end
            end
        end

        ns.appendArray(filtRemain, addedMounts)
        db.cycleMountIDs[poolKey]     = filtCycle
        db.remainingMountIDs[poolKey] = filtRemain

        local addedCount = #addedMounts
        if addedCount > 0 or removedCount > 0 then
            anyChanges = true
            summaryParts[#summaryParts + 1] = string.format(
                "%s: +%d / -%d", poolKey, addedCount, removedCount
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
        local usableRemaining = {}
        for i = 1, #remaining do
            if usableLookup[remaining[i]] then
                usableRemaining[#usableRemaining + 1] = remaining[i]
            end
        end

        if #usableRemaining == 0 then
            ns.printMessage("No usable favorite mounts are queued for that pool right now.", true)
            return
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
