local addonName, ns = ...

local UnitAffectingCombat = UnitAffectingCombat
local IsMounted = IsMounted

local POOL_KEYS = ns.POOL_KEYS

--------------------------------------------------------------------------------
-- SavedVariables bootstrapping
--------------------------------------------------------------------------------

local function ensureRemainingMountIDsShape(target)
    target.remainingMountIDs = target.remainingMountIDs or ns.newEmptyRemainingPools()
    for _, key in ipairs(POOL_KEYS) do
        target.remainingMountIDs[key] = target.remainingMountIDs[key] or {}
    end
end

local function ensureCycleMountIDsShape(target)
    target.cycleMountIDs = target.cycleMountIDs or ns.newEmptyRemainingPools()
    for _, key in ipairs(POOL_KEYS) do
        target.cycleMountIDs[key] = target.cycleMountIDs[key] or {}
    end
end

local function mergeDefaults(target)
    target.options = target.options or {}
    for key, value in pairs(ns.DEFAULT_OPTIONS) do
        if target.options[key] == nil then
            target.options[key] = value
        end
    end
end

--------------------------------------------------------------------------------
-- Event handling — table dispatch (O(1) lookup, scales cleanly)
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

local eventHandlers = {
    ADDON_LOADED = function(_, loadedAddon)
        if loadedAddon ~= addonName then return end

        FlyingMountCyclerDB = FlyingMountCyclerDB or {}
        ns.db = FlyingMountCyclerDB

        ensureRemainingMountIDsShape(ns.db)
        ensureCycleMountIDsShape(ns.db)
        mergeDefaults(ns.db)

        ns.refreshAvailableMounts(false)
        ns.registerSettings()

        ns.printMessage(
            "Loaded. |cffaaaaaa/fmount|r — next mount, "
            .. "|cffaaaaaa/fmount reset|r — reset cycle, "
            .. "|cffaaaaaa/fmount refresh|r — refresh mounts, "
            .. "|cffaaaaaa/fmount config|r — options."
        )

        eventFrame:UnregisterEvent("ADDON_LOADED")
    end,

    PLAYER_MOUNT_DISPLAY_CHANGED = function()
        ns.scheduleNoRepeatCycleUpdateFromMountState()
    end,

    NEW_MOUNT_ADDED = function()
        ns.refreshAvailableMounts(false)
    end,

    UNIT_AURA = function()
        ns.scheduleNoRepeatCycleUpdateFromMountState()
    end,
}

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = eventHandlers[event]
    if handler then
        handler(eventFrame, ...)
    end
end)

for event in pairs(eventHandlers) do
    if event == "UNIT_AURA" then
        eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
    else
        eventFrame:RegisterEvent(event)
    end
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
        ns.resetCycle("reset command used")
        return
    end
    if command == "refresh" then
        ns.refreshAvailableMounts(true)
        return
    end
    if command == "config" or command == "options" then
        ns.openAddonSettings()
        return
    end

    if UnitAffectingCombat("player") then
        if IsMounted() then
            ns.dismountIfMounted()
        else
            ns.warnCannotMountInCombat()
        end
        return
    end

    ns.summonNextFavoriteMount()
end
