local _, ns = ...

local C_MountJournal = C_MountJournal
local IsFlyableArea  = IsFlyableArea
local IsMounted      = IsMounted
local TimerAfter     = C_Timer and C_Timer.After

local GetTime = GetTime

local CycleState = ns.CycleState
local ZONE_MODE = ns.ZONE_MODE
local POOL_KEYS = ns.POOL_KEYS
local RECENT_HISTORY_COUNTS = ns.RECENT_HISTORY_COUNTS

local PENDING_SUMMON_TIMEOUT = 3
local LOCK_MESSAGE_THROTTLE_SECONDS = 2

--------------------------------------------------------------------------------
-- Mount lock (session-only): keep the same mount for a configurable duration
--------------------------------------------------------------------------------

local lockedMountID
local lockedAtTime
local lockedSummonKind
local lastLockMessageMountID
local lastLockMessageAt
local pendingMountID
local pendingSummonKind
local pendingSummonAtTime

local function isMountLockActive()
    local db = ns.db
    if not db or not db.options or not db.options.mountLockEnabled then
        return false
    end
    if not lockedMountID or not lockedAtTime then
        return false
    end
    local elapsed = GetTime() - lockedAtTime
    local duration = (db.options.mountLockDuration or 15) * 60
    return elapsed < duration
end

local function setMountLock(mountID, summonKind)
    lockedMountID = mountID
    lockedAtTime = GetTime()
    lockedSummonKind = summonKind
end

function ns.clearMountLock()
    lockedMountID = nil
    lockedAtTime = nil
    lockedSummonKind = nil
    lastLockMessageMountID = nil
    lastLockMessageAt = nil
end

function ns.getMountLockTimeRemaining()
    if not isMountLockActive() then
        return 0
    end
    local elapsed = GetTime() - lockedAtTime
    local duration = (ns.db.options.mountLockDuration or 15) * 60
    return math.max(0, duration - elapsed)
end

local function formatLockRemaining(secondsRemaining)
    local roundedSeconds = math.ceil(secondsRemaining or 0)
    if roundedSeconds > 60 then
        return math.ceil(roundedSeconds / 60) .. " min remaining"
    end
    return roundedSeconds .. " sec remaining"
end

local function clearPendingSummon()
    pendingMountID = nil
    pendingSummonKind = nil
    pendingSummonAtTime = nil
end

local function hasPendingSummon()
    if not pendingMountID or not pendingSummonAtTime then
        return false
    end
    if (GetTime() - pendingSummonAtTime) >= PENDING_SUMMON_TIMEOUT then
        clearPendingSummon()
        return false
    end
    return true
end

local function setPendingSummon(mountID, summonKind)
    pendingMountID = mountID
    pendingSummonKind = summonKind
    pendingSummonAtTime = GetTime()
end

local function isPendingMountReserved(mountID)
    return hasPendingSummon() and pendingMountID == mountID
end

local function filterOutPendingMount(source)
    if not hasPendingSummon() then
        return source
    end
    local filtered = {}
    for i = 1, #source do
        local mountID = source[i]
        if mountID ~= pendingMountID then
            filtered[#filtered + 1] = mountID
        end
    end
    return filtered
end

local function getMaxRecentHistoryCount()
    return RECENT_HISTORY_COUNTS[#RECENT_HISTORY_COUNTS] or 0
end

local function ensureRecentMountHistory()
    local db = ns.db
    db.recentMountIDs = db.recentMountIDs or {}
    return db.recentMountIDs
end

local function trimRecentMountHistory()
    local recent = ensureRecentMountHistory()
    local maxCount = getMaxRecentHistoryCount()
    while #recent > maxCount do
        table.remove(recent)
    end
end

local function pushRecentMountID(mountID)
    local recent = ensureRecentMountHistory()
    for i = 1, #recent do
        if recent[i] == mountID then
            table.remove(recent, i)
            break
        end
    end
    table.insert(recent, 1, mountID)
    trimRecentMountHistory()
end

local function getRecentMountLookup(limit)
    if not limit or limit <= 0 then
        return nil
    end
    local recent = ensureRecentMountHistory()
    local lookup = {}
    local maxIndex = math.min(limit, #recent)
    for i = 1, maxIndex do
        lookup[recent[i]] = true
    end
    return lookup
end

local function filterOutRecentMounts(source, limit)
    local recentLookup = getRecentMountLookup(limit)
    if not recentLookup then
        return source
    end
    local filtered = {}
    for i = 1, #source do
        local mountID = source[i]
        if not recentLookup[mountID] then
            filtered[#filtered + 1] = mountID
        end
    end
    return filtered
end

local function formatPoolLabel(poolKey)
    if poolKey == "flying" then
        return "flying"
    elseif poolKey == "ground" then
        return "ground"
    end
    return "any-favorite"
end

local function formatResolvedModeLabel(poolKey)
    if poolKey == "flying" then
        return "Flying favorites"
    elseif poolKey == "ground" then
        return "Ground favorites"
    end
    return "Any favorite"
end

local function debugSelectionMessage(text)
    local db = ns.db
    if not db or not db.options or db.options.showDebugMessages ~= true then
        return
    end
    ns.printMessage("Debug: " .. text, true)
end

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

local function mountQualifiesForTracking(mountID)
    for _, poolKey in ipairs(POOL_KEYS) do
        if isFavoriteInPoolIgnoringUsable(poolKey, mountID) then
            return true
        end
    end
    return false
end

local function processMountedState()
    local db = ns.db
    if not db or not db.options then
        return
    end
    if not IsMounted() then
        return
    end

    local mountID = getActiveMountID()
    if not mountID then
        return
    end
    if hasPendingSummon() and mountID ~= pendingMountID then
        clearPendingSummon()
    end
    if not mountQualifiesForTracking(mountID) then
        return
    end
    if mountID == lastProcessedNoRepeatMountID then
        if hasPendingSummon() and mountID == pendingMountID then
            clearPendingSummon()
        end
        return
    end

    lastProcessedNoRepeatMountID = mountID
    pushRecentMountID(mountID)

    if hasPendingSummon() and mountID == pendingMountID then
        clearPendingSummon()
    end

    if db.options.cycleWithoutRepeats then
        removeMountFromAllCycleQueues(mountID)
        announceNoRepeatCycleProgress(mountID)
    end
end

function ns.scheduleNoRepeatCycleUpdateFromMountState()
    if not IsMounted() then
        lastProcessedNoRepeatMountID = nil
        hasPendingSummon()
        mountAnnounceDeferSeq = mountAnnounceDeferSeq + 1
        return
    end
    local db = ns.db
    if not db or not db.options then
        return
    end

    mountAnnounceDeferSeq = mountAnnounceDeferSeq + 1
    local seq = mountAnnounceDeferSeq
    local function runDeferred()
        if seq ~= mountAnnounceDeferSeq then
            return
        end
        processMountedState()
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

function ns.getResolvedSummonKind()
    return resolveSummonKind()
end

local function getPoolSnapshot(poolKey)
    local fullPool = buildFavoritePool(poolKey, true)
    local remaining = ((ns.db or {}).remainingMountIDs or {})[poolKey] or {}
    local usablePool = buildFavoritePool(poolKey, false)
    return {
        poolKey = poolKey,
        totalCount = #fullPool,
        remainingCount = #remaining,
        usableCount = #usablePool,
    }
end

function ns.getCycleSummaryLines()
    local lines = {}
    for _, poolKey in ipairs(POOL_KEYS) do
        local snapshot = getPoolSnapshot(poolKey)
        lines[#lines + 1] = string.format(
            "%s: %d queued / %d total (%d usable now)",
            formatPoolLabel(snapshot.poolKey),
            snapshot.remainingCount,
            snapshot.totalCount,
            snapshot.usableCount
        )
    end
    return lines
end

function ns.getStatusReportLines()
    local lines = {}
    local db = ns.db
    local options = db and db.options or {}
    local summonKind = resolveSummonKind()
    lines[#lines + 1] = "Current mode: " .. formatResolvedModeLabel(summonKind)

    if isMountLockActive() then
        lines[#lines + 1] = string.format(
            "Mount lock: %s (%s, %s pool)",
            ns.getMountDisplayName(lockedMountID),
            formatLockRemaining(ns.getMountLockTimeRemaining()),
            formatPoolLabel(lockedSummonKind)
        )
    elseif options.mountLockEnabled then
        lines[#lines + 1] = "Mount lock: enabled, waiting for next summon"
    else
        lines[#lines + 1] = "Mount lock: disabled"
    end

    if hasPendingSummon() then
        lines[#lines + 1] = "Pending summon: " .. ns.getMountDisplayName(pendingMountID)
            .. " (" .. formatPoolLabel(pendingSummonKind) .. " pool)"
    end

    local recentCount = options.recentHistoryCount or 0
    if recentCount > 0 and options.cycleWithoutRepeats ~= true then
        lines[#lines + 1] = "Recent-history avoidance: enabled (" .. recentCount .. " recent mounts)"
    elseif options.cycleWithoutRepeats ~= true then
        lines[#lines + 1] = "Recent-history avoidance: disabled"
    end

    if options.showDebugMessages == true then
        lines[#lines + 1] = "Debug selection messages: enabled"
    end

    local summaryLines = ns.getCycleSummaryLines()
    for i = 1, #summaryLines do
        lines[#lines + 1] = summaryLines[i]
    end

    return lines
end

local function clearSessionStateForReset()
    clearPendingSummon()
    ns.clearMountLock()
    local db = ns.db
    if db then
        db.recentMountIDs = {}
    end
end

local function normalizePoolKey(poolKey)
    if poolKey == "flying" or poolKey == "ground" or poolKey == "any" then
        return poolKey
    end
    return nil
end

function ns.resetCyclePool(poolKey, reason)
    local normalizedPoolKey = normalizePoolKey(poolKey)
    if not normalizedPoolKey then
        ns.printMessage("Unknown pool '" .. tostring(poolKey) .. "'. Use flying, ground, or any.", true)
        return false
    end

    setFreshCyclePool(normalizedPoolKey, buildFavoritePool(normalizedPoolKey, true))
    clearPendingSummon()
    if lockedSummonKind == normalizedPoolKey then
        ns.clearMountLock()
    end
    announceCycleReset(reason or ("reset " .. normalizedPoolKey .. " pool"), { normalizedPoolKey })
    return true
end

local function filterOutMountID(source, mountID)
    if not mountID then
        return source
    end
    local filtered = {}
    for i = 1, #source do
        local candidate = source[i]
        if candidate ~= mountID then
            filtered[#filtered + 1] = candidate
        end
    end
    return filtered
end

local function summonNextFavoriteMountInternal(forceSkip)
    local summonKind = resolveSummonKind()
    local activeMountID = getActiveMountID()
    local usablePool = buildFavoritePool(summonKind)
    if forceSkip and activeMountID then
        local withoutActive = filterOutMountID(usablePool, activeMountID)
        if #withoutActive > 0 then
            usablePool = withoutActive
        end
    end
    debugSelectionMessage(
        string.format(
            "Resolved %s pool with %d usable favorites.",
            formatPoolLabel(summonKind),
            #usablePool
        )
    )
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

    if forceSkip and isMountLockActive() then
        ns.clearMountLock()
    end

    if forceSkip and hasPendingSummon() then
        clearPendingSummon()
    end

    if isMountLockActive() and lockedSummonKind ~= summonKind then
        ns.clearMountLock()
        ns.printMessage(
            "Mount lock cleared because the active pool changed to " .. formatPoolLabel(summonKind) .. ".",
            true
        )
    end

    if not forceSkip and isMountLockActive() and lockedSummonKind == summonKind then
        local usableLookup = ns.poolToLookup(usablePool)
        if usableLookup[lockedMountID] then
            local now = GetTime()
            if lastLockMessageMountID ~= lockedMountID
                or not lastLockMessageAt
                or (now - lastLockMessageAt) >= LOCK_MESSAGE_THROTTLE_SECONDS then
                ns.printCycleRemainingMessage(
                    "Mount locked: " .. ns.getMountDisplayName(lockedMountID)
                    .. " (" .. formatLockRemaining(ns.getMountLockTimeRemaining()) .. ")."
                )
                lastLockMessageMountID = lockedMountID
                lastLockMessageAt = now
            end
            debugSelectionMessage("Reusing locked mount " .. ns.getMountDisplayName(lockedMountID) .. ".")
            setPendingSummon(lockedMountID, summonKind)
            C_MountJournal.SummonByID(lockedMountID)
            return
        end
        ns.clearMountLock()
        ns.printMessage("Mount lock cleared because the locked mount is no longer usable in that pool.", true)
    end

    if not forceSkip and hasPendingSummon() and pendingSummonKind == summonKind then
        local usableLookup = ns.poolToLookup(usablePool)
        if usableLookup[pendingMountID] then
            debugSelectionMessage(
                "Reusing pending summon " .. ns.getMountDisplayName(pendingMountID)
                    .. " while mount state is still settling."
            )
            C_MountJournal.SummonByID(pendingMountID)
            return
        end
        clearPendingSummon()
    end

    local chosenMountID
    if ns.db.options.cycleWithoutRepeats then
        local fullPool = buildFavoritePool(summonKind, true)
        local remaining = ensureRemainingPoolReady(summonKind, fullPool)

        local usableLookup = ns.poolToLookup(usablePool)
        local usableRemainingBase = CycleState.filterUsableMounts(remaining, usableLookup)
        local usableRemaining = filterOutPendingMount(usableRemainingBase)
        if forceSkip and activeMountID then
            local filteredBase = filterOutMountID(usableRemainingBase, activeMountID)
            local filtered = filterOutMountID(usableRemaining, activeMountID)
            if #filteredBase > 0 then
                usableRemainingBase = filteredBase
            end
            if #filtered > 0 then
                usableRemaining = filtered
            end
        end

        if (not forceSkip) and #usableRemaining == 0 and #usableRemainingBase > 0
            and hasPendingSummon() and pendingSummonKind == summonKind then
            chosenMountID = pendingMountID
        end

        if not chosenMountID and #usableRemaining == 0 then
            setFreshCyclePool(summonKind, fullPool)
            announceCycleReset("reached the end of the list", { summonKind })
            remaining = ns.db.remainingMountIDs[summonKind] or {}
            usableRemainingBase = CycleState.filterUsableMounts(remaining, usableLookup)
            usableRemaining = filterOutPendingMount(usableRemainingBase)
            if forceSkip and activeMountID then
                local filteredBase = filterOutMountID(usableRemainingBase, activeMountID)
                local filtered = filterOutMountID(usableRemaining, activeMountID)
                if #filteredBase > 0 then
                    usableRemainingBase = filteredBase
                end
                if #filtered > 0 then
                    usableRemaining = filtered
                end
            end
            if (not forceSkip) and #usableRemaining == 0 and #usableRemainingBase > 0
                and hasPendingSummon() and pendingSummonKind == summonKind then
                chosenMountID = pendingMountID
            end
        end

        if not chosenMountID and #usableRemaining == 0 then
            usableRemaining = CycleState.filterUsableMounts(remaining, usableLookup)
            usableRemaining = filterOutPendingMount(usableRemaining)
            if forceSkip and activeMountID then
                local filtered = filterOutMountID(usableRemaining, activeMountID)
                if #filtered > 0 then
                    usableRemaining = filtered
                end
            end
            if #usableRemaining == 0 then
                ns.printMessage("No usable favorite mounts are queued for that pool right now.", true)
                return
            end
        end
        if not chosenMountID then
            debugSelectionMessage(
                string.format(
                    "No-repeat selection using %d queued usable mounts from %s pool.",
                    #usableRemaining,
                    formatPoolLabel(summonKind)
                )
            )
            chosenMountID = usableRemaining[math.random(#usableRemaining)]
        else
            debugSelectionMessage(
                "Reusing pending summon " .. ns.getMountDisplayName(chosenMountID)
                    .. " while mount state is still settling."
            )
        end
    else
        local recentHistoryCount = ns.db.options.recentHistoryCount or 0
        local candidatePool = usablePool
        if recentHistoryCount > 0 then
            local filteredPool = filterOutRecentMounts(candidatePool, recentHistoryCount)
            if #filteredPool > 0 then
                candidatePool = filteredPool
            end
        end
        candidatePool = filterOutPendingMount(candidatePool)
        if #candidatePool == 0 then
            candidatePool = usablePool
        end
        if forceSkip and activeMountID then
            local candidateWithoutActive = filterOutMountID(candidatePool, activeMountID)
            if #candidateWithoutActive > 0 then
                candidatePool = candidateWithoutActive
            end
        end
        debugSelectionMessage(
            string.format(
                "Random selection using %d candidate mounts (%d usable total).",
                #candidatePool,
                #usablePool
            )
        )
        chosenMountID = candidatePool[math.random(#candidatePool)]
    end

    setPendingSummon(chosenMountID, summonKind)

    if ns.db.options.mountLockEnabled then
        setMountLock(chosenMountID, summonKind)
        local duration = ns.db.options.mountLockDuration or 15
        ns.printCycleRemainingMessage(
            "Mount locked: " .. ns.getMountDisplayName(chosenMountID)
            .. " for " .. duration .. " min."
        )
    end

    debugSelectionMessage(
        "Summoning " .. ns.getMountDisplayName(chosenMountID) .. " from the "
        .. formatPoolLabel(summonKind) .. " pool."
    )
    C_MountJournal.SummonByID(chosenMountID)
end

function ns.summonNextFavoriteMount()
    summonNextFavoriteMountInternal(false)
end

function ns.skipToNextFavoriteMount()
    summonNextFavoriteMountInternal(true)
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

    clearSessionStateForReset()
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
