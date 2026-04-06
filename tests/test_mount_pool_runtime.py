import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
ADDON_DIR = ROOT / "FlyingMountCycler"


def lua_array_to_list(lua_table):
    values = []
    index = 1
    while True:
        value = lua_table[index]
        if value is None:
            return values
        values.append(value)
        index += 1


def make_runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        """
        function __load_addon_chunk(path, ...)
            local chunk, err = loadfile(path)
            if not chunk then
                error(err)
            end
            return chunk(...)
        end

        __mount_ids = {}
        __mount_db = {}
        __summon_calls = {}
        __time_now = 0
        __is_mounted = false
        __flyable_area = false
        __active_mount_id = nil
        __dismiss_called = false

        function IsFlyableArea()
            return __flyable_area
        end

        function IsMounted()
            return __is_mounted
        end

        function GetTime()
            return __time_now
        end

        DEFAULT_CHAT_FRAME = {
            messages = {},
            AddMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        }

        UIErrorsFrame = {
            messages = {},
            AddMessage = function(self, message)
                table.insert(self.messages, message)
            end,
        }

        C_MountJournal = {
            GetMountIDs = function()
                return __mount_ids
            end,
            GetMountInfoByID = function(mountID)
                local mount = __mount_db[mountID]
                if not mount then
                    return nil
                end
                return mount.name, nil, nil, nil, mount.isUsable, nil, mount.isFavorite, nil, nil, mount.shouldHideOnChar, mount.isCollected
            end,
            GetMountInfoExtraByID = function(mountID)
                local mount = __mount_db[mountID]
                if not mount then
                    return nil, nil, nil, nil, nil
                end
                return nil, nil, nil, nil, mount.mountTypeID
            end,
            SummonByID = function(mountID)
                table.insert(__summon_calls, mountID)
            end,
            GetSummonedMountID = function()
                return __active_mount_id or 0
            end,
            Dismiss = function()
                __dismiss_called = true
            end,
        }

        C_Timer = nil

        math.random = function(max)
            return 1
        end
        """
    )
    return lua


def load_mount_pool_runtime():
    lua = make_runtime()
    load_chunk = lua.globals().__load_addon_chunk
    ns = lua.table()

    load_chunk(str(ADDON_DIR / "Init.lua"), "FlyingMountCycler", ns)
    load_chunk(str(ADDON_DIR / "Utils.lua"), "FlyingMountCycler", ns)
    load_chunk(str(ADDON_DIR / "CycleState.lua"), "FlyingMountCycler", ns)
    load_chunk(str(ADDON_DIR / "MountPool.lua"), "FlyingMountCycler", ns)

    db = lua.table()
    db["options"] = lua.table_from(
        {
            "zoneMode": ns.ZONE_MODE.AUTO,
            "includeSkyriding": True,
            "cycleWithoutRepeats": True,
            "recentHistoryCount": 0,
            "showCycleRemainingChat": True,
            "showResetAnnouncements": False,
            "showChatMessages": True,
            "showDebugMessages": False,
            "mountLockEnabled": False,
            "mountLockDuration": 15,
        }
    )
    db["cycleMountIDs"] = ns.newEmptyRemainingPools()
    db["remainingMountIDs"] = ns.newEmptyRemainingPools()
    db["recentMountIDs"] = lua.table_from([])
    ns["db"] = db

    return lua, ns


def set_mounts(lua, mounts):
    mount_ids = lua.table_from([mount["id"] for mount in mounts])
    mount_db = lua.table()
    for mount in mounts:
        mount_db[mount["id"]] = lua.table_from(
            {
                "name": mount["name"],
                "mountTypeID": mount["mount_type_id"],
                "isUsable": mount.get("is_usable", True),
                "isFavorite": mount.get("is_favorite", True),
                "shouldHideOnChar": mount.get("should_hide_on_char", False),
                "isCollected": mount.get("is_collected", True),
            }
        )
    lua.globals()["__mount_ids"] = mount_ids
    lua.globals()["__mount_db"] = mount_db


class MountPoolRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.ns = load_mount_pool_runtime()

    def test_repeated_press_reuses_pending_mount_until_mount_state_updates(self):
        set_mounts(
            self.lua,
            [
                {"id": 101, "name": "Azure Drake", "mount_type_id": 242},
                {"id": 102, "name": "Blue Dragonhawk", "mount_type_id": 242},
            ],
        )
        self.lua.globals()["__flyable_area"] = True

        self.ns.refreshAvailableMounts(False)
        self.ns.summonNextFavoriteMount()
        self.ns.summonNextFavoriteMount()

        self.assertEqual(lua_array_to_list(self.lua.globals()["__summon_calls"]), [101, 101])

        self.lua.globals()["__active_mount_id"] = 101
        self.lua.globals()["__is_mounted"] = True
        self.ns.scheduleNoRepeatCycleUpdateFromMountState()

        self.assertEqual(lua_array_to_list(self.ns.db["remainingMountIDs"]["flying"]), [102])

    def test_recent_history_avoidance_filters_out_recent_mounts_in_random_mode(self):
        set_mounts(
            self.lua,
            [
                {"id": 201, "name": "Swift Brown Steed", "mount_type_id": 230},
                {"id": 202, "name": "Traveler's Tundra Mammoth", "mount_type_id": 230},
            ],
        )
        self.lua.globals()["__flyable_area"] = False
        self.ns.db["options"]["cycleWithoutRepeats"] = False
        self.ns.db["options"]["recentHistoryCount"] = 1
        self.ns.db["recentMountIDs"] = self.lua.table_from([201])

        self.ns.summonNextFavoriteMount()

        self.assertEqual(lua_array_to_list(self.lua.globals()["__summon_calls"]), [202])

    def test_pool_reset_only_refreshes_the_requested_pool(self):
        set_mounts(
            self.lua,
            [
                {"id": 301, "name": "Bronze Drake", "mount_type_id": 242},
                {"id": 302, "name": "Black Drake", "mount_type_id": 242},
                {"id": 401, "name": "Swift White Ram", "mount_type_id": 230},
            ],
        )
        self.lua.globals()["__flyable_area"] = True
        self.ns.refreshAvailableMounts(False)

        self.ns.db["remainingMountIDs"]["flying"] = self.lua.table_from([302])
        self.ns.db["remainingMountIDs"]["ground"] = self.lua.table_from([])

        self.assertTrue(self.ns.resetCyclePool("flying", "test reset"))
        self.assertEqual(lua_array_to_list(self.ns.db["remainingMountIDs"]["flying"]), [301, 302])
        self.assertEqual(lua_array_to_list(self.ns.db["remainingMountIDs"]["ground"]), [])

    def test_lock_is_cleared_when_the_active_pool_changes(self):
        set_mounts(
            self.lua,
            [
                {"id": 501, "name": "Red Drake", "mount_type_id": 242},
                {"id": 601, "name": "Brown Horse", "mount_type_id": 230},
            ],
        )
        self.lua.globals()["__flyable_area"] = True
        self.ns.db["options"]["mountLockEnabled"] = True

        self.ns.summonNextFavoriteMount()

        self.lua.globals()["__flyable_area"] = False
        self.ns.summonNextFavoriteMount()

        self.assertEqual(lua_array_to_list(self.lua.globals()["__summon_calls"]), [501, 601])
        chat_messages = lua_array_to_list(self.lua.globals().DEFAULT_CHAT_FRAME["messages"])
        self.assertTrue(
            any("active pool changed to ground" in message for message in chat_messages),
            chat_messages,
        )


if __name__ == "__main__":
    unittest.main()
