local _, ns = ...

local CycleState = {}

local function copyArray(source)
    local out = {}
    for i = 1, #source do
        out[i] = source[i]
    end
    return out
end

local function poolToLookup(pool)
    local lookup = {}
    for i = 1, #pool do
        lookup[pool[i]] = true
    end
    return lookup
end

local function retainOnlyCurrentPool(source, poolLookup)
    local filtered = {}
    for i = 1, #source do
        local mountID = source[i]
        if poolLookup[mountID] then
            filtered[#filtered + 1] = mountID
        end
    end
    return filtered
end

local function removeFirstValue(source, value)
    for i = 1, #source do
        if source[i] == value then
            table.remove(source, i)
            return true
        end
    end
    return false
end

local function ensurePoolTables(db, poolKey)
    db.remainingMountIDs = db.remainingMountIDs or {}
    db.cycleMountIDs = db.cycleMountIDs or {}
    db.remainingMountIDs[poolKey] = db.remainingMountIDs[poolKey] or {}
    db.cycleMountIDs[poolKey] = db.cycleMountIDs[poolKey] or {}
end

local function setFreshCyclePool(db, poolKey, pool)
    db.cycleMountIDs[poolKey] = copyArray(pool)
    db.remainingMountIDs[poolKey] = copyArray(pool)
end

function CycleState.syncPoolState(db, poolKey, pool)
    ensurePoolTables(db, poolKey)

    local poolLookup = poolToLookup(pool)
    local prevCycle = db.cycleMountIDs[poolKey] or {}
    local prevRemaining = db.remainingMountIDs[poolKey] or {}
    local trackedCycle = retainOnlyCurrentPool(prevCycle, poolLookup)
    local remaining = retainOnlyCurrentPool(prevRemaining, poolLookup)
    local removedCount = #prevCycle - #trackedCycle
    local addedMounts = {}

    if #trackedCycle == 0 then
        trackedCycle = copyArray(pool)
        remaining = copyArray(pool)
        addedMounts = copyArray(pool)
    else
        local trackedLookup = poolToLookup(trackedCycle)
        for i = 1, #pool do
            local mountID = pool[i]
            if not trackedLookup[mountID] then
                trackedCycle[#trackedCycle + 1] = mountID
                trackedLookup[mountID] = true
                addedMounts[#addedMounts + 1] = mountID
                remaining[#remaining + 1] = mountID
            end
        end
    end

    db.cycleMountIDs[poolKey] = trackedCycle
    db.remainingMountIDs[poolKey] = remaining

    return {
        addedMounts = addedMounts,
        addedCount = #addedMounts,
        removedCount = removedCount,
        cycle = trackedCycle,
        remaining = remaining,
    }
end

function CycleState.ensureRemainingPoolReady(db, poolKey, pool)
    local result = CycleState.syncPoolState(db, poolKey, pool)
    local remaining = db.remainingMountIDs[poolKey] or {}
    if #remaining > 0 then
        return remaining, result
    end

    local trackedCycle = db.cycleMountIDs[poolKey] or {}
    if #trackedCycle == 0 then
        return remaining, result
    end

    setFreshCyclePool(db, poolKey, trackedCycle)
    return db.remainingMountIDs[poolKey], result
end

function CycleState.filterUsableMounts(source, usableLookup)
    local filtered = {}
    for i = 1, #source do
        local mountID = source[i]
        if usableLookup[mountID] then
            filtered[#filtered + 1] = mountID
        end
    end
    return filtered
end

function CycleState.consumeMountFromPool(db, poolKey, pool, mountID)
    CycleState.syncPoolState(db, poolKey, pool)

    local remaining = db.remainingMountIDs[poolKey] or {}
    local removed = removeFirstValue(remaining, mountID)
    if not removed then
        return {
            removed = false,
            refilled = false,
            remainingCount = #remaining,
        }
    end

    if #remaining == 0 then
        local trackedCycle = db.cycleMountIDs[poolKey] or {}
        if #trackedCycle > 0 then
            setFreshCyclePool(db, poolKey, trackedCycle)
            remaining = db.remainingMountIDs[poolKey] or {}
            return {
                removed = true,
                refilled = true,
                remainingCount = #remaining,
            }
        end
    end

    return {
        removed = true,
        refilled = false,
        remainingCount = #remaining,
    }
end

if ns then
    ns.CycleState = CycleState
end

return CycleState
