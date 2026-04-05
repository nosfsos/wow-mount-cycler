local addonName = ...

local FlyingMountCycler = CreateFrame("Frame")

local FLYING_MOUNT_TYPE_IDS = {
    [242] = true, -- Retail flying
    [247] = true, -- Legacy flying variant
    [248] = true, -- Legacy flying variant
    [398] = true, -- Skyriding/dragonriding family
    [407] = true, -- Skyriding variant
    [424] = true, -- Dual-mode flight variant
}

local db

local function printMessage(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99FlyingMountCycler:|r " .. text)
end

local function copyArray(source)
    local out = {}
    for i = 1, #source do
        out[i] = source[i]
    end
    return out
end

local function buildFavoritePool(shouldUseFlyingPool)
    local pool = {}
    local mountIDs = C_MountJournal.GetMountIDs() or {}

    for _, mountID in ipairs(mountIDs) do
        local name, _, _, _, isUsable, _, isFavorite, _, _, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
        if name and isCollected and isUsable and isFavorite and not shouldHideOnChar then
            local _, _, _, _, mountTypeID = C_MountJournal.GetMountInfoExtraByID(mountID)
            local isFlyingMountType = type(mountTypeID) == "number" and FLYING_MOUNT_TYPE_IDS[mountTypeID]
            if (shouldUseFlyingPool and isFlyingMountType) or (not shouldUseFlyingPool and not isFlyingMountType) then
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

local function summonNextFavoriteMount()
    local shouldUseFlyingPool = IsFlyableArea()
    local poolKey = shouldUseFlyingPool and "flying" or "ground"
    local pool = buildFavoritePool(shouldUseFlyingPool)
    if #pool == 0 then
        if shouldUseFlyingPool then
            printMessage("No usable favorite flying mounts found.")
        else
            printMessage("No usable favorite ground mounts found.")
        end
        return
    end

    rebuildCycleIfNeeded(pool, poolKey)

    local pickIndex = math.random(#db.remainingMountIDs[poolKey])
    local mountID = db.remainingMountIDs[poolKey][pickIndex]
    table.remove(db.remainingMountIDs[poolKey], pickIndex)

    C_MountJournal.SummonByID(mountID)
end

local function resetCycle()
    db.remainingMountIDs = {
        flying = {},
        ground = {},
    }
    printMessage("Cycle reset. Your next summon starts a fresh round.")
end

SLASH_FLYINGMOUNTCYCLER1 = "/fmount"
SLASH_FLYINGMOUNTCYCLER2 = "/flyingmount"
SlashCmdList.FLYINGMOUNTCYCLER = function(msg)
    local command = strlower(strtrim(msg or ""))
    if command == "reset" then
        resetCycle()
        return
    end

    summonNextFavoriteMount()
end

FlyingMountCycler:SetScript("OnEvent", function(_, event, loadedAddonName)
    if event == "ADDON_LOADED" then
        if loadedAddonName ~= addonName then
            return
        end

        FlyingMountCyclerDB = FlyingMountCyclerDB or {}
        FlyingMountCyclerDB.remainingMountIDs = FlyingMountCyclerDB.remainingMountIDs or {}
        FlyingMountCyclerDB.remainingMountIDs.flying = FlyingMountCyclerDB.remainingMountIDs.flying or {}
        FlyingMountCyclerDB.remainingMountIDs.ground = FlyingMountCyclerDB.remainingMountIDs.ground or {}
        db = FlyingMountCyclerDB

        printMessage("Loaded. Use /fmount to summon your next favorite mount.")
    end
end)

FlyingMountCycler:RegisterEvent("ADDON_LOADED")
