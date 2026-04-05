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

local function buildFlyingPool()
    local pool = {}
    local mountIDs = C_MountJournal.GetMountIDs() or {}

    for _, mountID in ipairs(mountIDs) do
        local name, _, _, _, isUsable, _, _, _, _, shouldHideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
        if name and isCollected and isUsable and not shouldHideOnChar then
            local _, _, _, _, mountTypeID = C_MountJournal.GetMountInfoExtraByID(mountID)
            if type(mountTypeID) == "number" and FLYING_MOUNT_TYPE_IDS[mountTypeID] then
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

local function rebuildCycleIfNeeded(pool)
    local poolLookup = {}
    for _, mountID in ipairs(pool) do
        poolLookup[mountID] = true
    end

    db.remainingMountIDs = retainOnlyCurrentPool(db.remainingMountIDs or {}, poolLookup)
    if #db.remainingMountIDs == 0 then
        db.remainingMountIDs = copyArray(pool)
    end
end

local function summonNextFlyingMount()
    if not IsFlyableArea() then
        printMessage("You are not in a flyable area.")
        return
    end

    local pool = buildFlyingPool()
    if #pool == 0 then
        printMessage("No usable flying mounts found.")
        return
    end

    rebuildCycleIfNeeded(pool)

    local pickIndex = math.random(#db.remainingMountIDs)
    local mountID = db.remainingMountIDs[pickIndex]
    table.remove(db.remainingMountIDs, pickIndex)

    C_MountJournal.SummonByID(mountID)
end

local function resetCycle()
    db.remainingMountIDs = {}
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

    summonNextFlyingMount()
end

FlyingMountCycler:SetScript("OnEvent", function(_, event, loadedAddonName)
    if event == "ADDON_LOADED" then
        if loadedAddonName ~= addonName then
            return
        end

        FlyingMountCyclerDB = FlyingMountCyclerDB or {}
        FlyingMountCyclerDB.remainingMountIDs = FlyingMountCyclerDB.remainingMountIDs or {}
        db = FlyingMountCyclerDB

        printMessage("Loaded. Use /fmount to summon your next flying mount.")
    end
end)

FlyingMountCycler:RegisterEvent("ADDON_LOADED")
