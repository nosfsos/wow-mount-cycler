local addonName, ns = ...

ns.addonName = addonName

ns.SETTINGS_TITLE = "Flying Mount Cycler"

ns.BASE_FLYING_MOUNT_TYPE_IDS = {
    [242] = true,
    [247] = true,
    [248] = true,
}

ns.SKYRIDING_MOUNT_TYPE_IDS = {
    [398] = true,
    [402] = true,
    [407] = true,
    [424] = true,
}

ns.ZONE_MODE = {
    AUTO        = 1,
    FLYING_ONLY = 2,
    GROUND_ONLY = 3,
    ANY_FAVORITE = 4,
}

ns.MOUNT_LOCK_DURATIONS = { 1, 5, 10, 15, 30, 45, 60, 90, 120, 180, 240, 360, 720, 1440 }
ns.RECENT_HISTORY_COUNTS = { 0, 1, 3, 5 }

ns.DEFAULT_OPTIONS = {
    zoneMode              = ns.ZONE_MODE.AUTO,
    includeSkyriding      = true,
    cycleWithoutRepeats   = true,
    recentHistoryCount    = 0,
    showCycleRemainingChat = true,
    showResetAnnouncements = true,
    showChatMessages      = true,
    showDebugMessages     = false,
    mountLockEnabled      = false,
    mountLockDuration     = 15,
}

ns.POOL_KEYS = { "flying", "ground", "any" }

-- Shared mutable state; set by Core.lua during ADDON_LOADED.
ns.db = nil
