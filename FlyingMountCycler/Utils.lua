local _, ns = ...

local C_MountJournal = C_MountJournal
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME

local ADDON_PREFIX = "|cff33ff99FlyingMountCycler:|r "

--------------------------------------------------------------------------------
-- Messaging
--------------------------------------------------------------------------------

function ns.printMessage(text, forceWhenQuiet)
    local db = ns.db
    if not forceWhenQuiet and db and db.options and db.options.showChatMessages == false then
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. text)
end

function ns.printCycleRemainingMessage(text)
    local db = ns.db
    if not db or not db.options or db.options.showCycleRemainingChat ~= true then
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. text)
end

function ns.printResetAnnouncementMessage(text)
    local db = ns.db
    if not db or not db.options or db.options.showResetAnnouncements ~= true then
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. text)
end

function ns.warnResetAnnouncement(text)
    local db = ns.db
    if not db or not db.options or db.options.showResetAnnouncements ~= true then
        return
    end
    UIErrorsFrame:AddMessage(text, 1.0, 0.82, 0.0)
end

--------------------------------------------------------------------------------
-- Pool / array helpers
--------------------------------------------------------------------------------

function ns.newEmptyRemainingPools()
    return { flying = {}, ground = {}, any = {} }
end

function ns.copyArray(source)
    local out = {}
    for i = 1, #source do
        out[i] = source[i]
    end
    return out
end

function ns.poolToLookup(pool)
    local lookup = {}
    for i = 1, #pool do
        lookup[pool[i]] = true
    end
    return lookup
end

function ns.retainOnlyCurrentPool(remaining, poolLookup)
    local filtered = {}
    for i = 1, #remaining do
        local id = remaining[i]
        if poolLookup[id] then
            filtered[#filtered + 1] = id
        end
    end
    return filtered
end

function ns.appendArray(target, values)
    for i = 1, #values do
        target[#target + 1] = values[i]
    end
end

function ns.getMountDisplayName(mountID)
    local name = C_MountJournal.GetMountInfoByID(mountID)
    return name or ("Mount #" .. tostring(mountID))
end

function ns.formatMountList(mountIDs)
    if not mountIDs or #mountIDs == 0 then
        return "none"
    end
    local parts = {}
    for i = 1, #mountIDs do
        parts[i] = ns.getMountDisplayName(mountIDs[i])
    end
    return table.concat(parts, ", ")
end
