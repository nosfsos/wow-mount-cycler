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
        """
    )
    return lua


def load_cycle_state():
    lua = make_runtime()
    load_chunk = lua.globals().__load_addon_chunk
    ns = lua.table()

    load_chunk(str(ADDON_DIR / "Init.lua"), "FlyingMountCycler", ns)
    load_chunk(str(ADDON_DIR / "Utils.lua"), "FlyingMountCycler", ns)
    cycle_state = load_chunk(str(ADDON_DIR / "CycleState.lua"), "FlyingMountCycler", ns)

    return lua, ns, cycle_state


def new_db(lua, ns):
    db = lua.table()
    db["cycleMountIDs"] = ns.newEmptyRemainingPools()
    db["remainingMountIDs"] = ns.newEmptyRemainingPools()
    return db


class CycleStateTests(unittest.TestCase):
    def setUp(self):
        self.lua, self.ns, self.cycle_state = load_cycle_state()

    def test_init_mount_type_tables_cover_documented_flying_sets(self):
        self.assertTrue(self.ns.BASE_FLYING_MOUNT_TYPE_IDS[242])
        self.assertTrue(self.ns.BASE_FLYING_MOUNT_TYPE_IDS[247])
        self.assertTrue(self.ns.BASE_FLYING_MOUNT_TYPE_IDS[248])

        self.assertTrue(self.ns.SKYRIDING_MOUNT_TYPE_IDS[398])
        self.assertTrue(self.ns.SKYRIDING_MOUNT_TYPE_IDS[402])
        self.assertTrue(self.ns.SKYRIDING_MOUNT_TYPE_IDS[407])
        self.assertTrue(self.ns.SKYRIDING_MOUNT_TYPE_IDS[424])

    def test_sync_initializes_cycle_and_remaining_from_empty_state(self):
        db = new_db(self.lua, self.ns)
        pool = self.lua.table_from([101, 102, 103])

        result = self.cycle_state.syncPoolState(db, "any", pool)

        self.assertEqual(result["addedCount"], 3)
        self.assertEqual(result["removedCount"], 0)
        self.assertEqual(lua_array_to_list(db["cycleMountIDs"]["any"]), [101, 102, 103])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [101, 102, 103])

    def test_cycle_refills_only_after_last_mount_is_consumed(self):
        db = new_db(self.lua, self.ns)
        pool = self.lua.table_from([201, 202, 203])

        self.cycle_state.syncPoolState(db, "any", pool)

        result = self.cycle_state.consumeMountFromPool(db, "any", pool, 201)
        self.assertFalse(result["refilled"])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [202, 203])

        result = self.cycle_state.consumeMountFromPool(db, "any", pool, 202)
        self.assertFalse(result["refilled"])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [203])

        result = self.cycle_state.consumeMountFromPool(db, "any", pool, 203)
        self.assertTrue(result["refilled"])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [201, 202, 203])

    def test_refresh_appends_new_mounts_without_resetting_progress(self):
        db = new_db(self.lua, self.ns)
        initial_pool = self.lua.table_from([301, 302, 303])
        updated_pool = self.lua.table_from([301, 302, 303, 304])

        self.cycle_state.syncPoolState(db, "any", initial_pool)
        self.cycle_state.consumeMountFromPool(db, "any", initial_pool, 301)

        result = self.cycle_state.syncPoolState(db, "any", updated_pool)

        self.assertEqual(lua_array_to_list(result["addedMounts"]), [304])
        self.assertEqual(lua_array_to_list(db["cycleMountIDs"]["any"]), [301, 302, 303, 304])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [302, 303, 304])

    def test_refresh_prunes_removed_mounts_without_resetting_progress(self):
        db = new_db(self.lua, self.ns)
        initial_pool = self.lua.table_from([401, 402, 403])
        updated_pool = self.lua.table_from([401, 403])

        self.cycle_state.syncPoolState(db, "any", initial_pool)
        self.cycle_state.consumeMountFromPool(db, "any", initial_pool, 401)

        result = self.cycle_state.syncPoolState(db, "any", updated_pool)

        self.assertEqual(result["removedCount"], 1)
        self.assertEqual(lua_array_to_list(db["cycleMountIDs"]["any"]), [401, 403])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [403])

    def test_unusable_mounts_stay_in_round_but_are_filtered_for_selection(self):
        db = new_db(self.lua, self.ns)
        pool = self.lua.table_from([501, 502, 503])
        usable_lookup = self.lua.table()
        usable_lookup[502] = True

        remaining, _ = self.cycle_state.ensureRemainingPoolReady(db, "any", pool)
        usable_remaining = self.cycle_state.filterUsableMounts(remaining, usable_lookup)

        self.assertEqual(lua_array_to_list(db["cycleMountIDs"]["any"]), [501, 502, 503])
        self.assertEqual(lua_array_to_list(db["remainingMountIDs"]["any"]), [501, 502, 503])
        self.assertEqual(lua_array_to_list(usable_remaining), [502])


if __name__ == "__main__":
    unittest.main()
