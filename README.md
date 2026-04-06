# WoW Flying Mount Cycler

A World of Warcraft Retail addon that cycles through your favorite mounts without repetition, split by flying / ground / any-favorite pools.

## Features

- **No-repeat cycling** — every favorite gets used before any mount repeats
- **Pool-aware** — automatically picks flying-type mounts in flyable areas, ground-type elsewhere (configurable)
- **Skyriding support** — optionally includes dragonriding / skyriding families in the flying pool
- **Recent-history avoidance** — optionally avoid the last few mounts when full no-repeat mode is disabled
- **Mount lock timer** — keep the same mount for a configurable duration with preset options and a custom 1-1440 minute input
- **Cycle status tools** — inspect live pool counts, lock state, and pending summons from slash commands or settings
- **Debug selection mode** — print pool resolution and summon reasoning to chat when troubleshooting
- **Addon Compartment** — left-click the minimap button to open settings, right-click to summon
- **Settings panel** — full options in Esc > Options > AddOns > Flying Mount Cycler

## Slash Commands

| Command | Action |
|---|---|
| `/fmount` | Summon the next mount (or dismount in combat) |
| `/fmount skip` | Force next mount now (bypass current lock one time) |
| `/fmount next` | Alias of `/fmount skip` |
| `/fmount reset` | Reset all cycle queues and start fresh |
| `/fmount reset flying` | Reset only one pool (`flying`, `ground`, or `any`) |
| `/fmount refresh` | Refresh available mounts without losing progress |
| `/fmount status` | Print the current pool counts, lock state, and active mode |
| `/fmount debug` | Toggle debug selection messages |
| `/fmount config` | Open the settings panel |

Aliases: `/flyingmount`, `/fmc`

## File Structure

```
FlyingMountCycler/
├── FlyingMountCycler.toc   # Addon metadata & load order
├── Init.lua                # Shared namespace, constants, defaults
├── Utils.lua               # Messaging helpers, array utilities
├── CycleState.lua          # Pure cycle state transitions
├── MountPool.lua           # Pool building, cycle management, summoning
├── Settings.lua            # Settings UI, addon compartment (minimap)
└── Core.lua                # Event dispatch, slash commands, initialization
```

Files communicate through the addon namespace table (`local addonName, ns = ...`) rather than globals.

## Environment Setup (Windows)

1. Install WoW Retail.
2. Install [Visual Studio Code](https://code.visualstudio.com/) (or Cursor).
3. Recommended extensions:
   - [WoW API](https://marketplace.visualstudio.com/items?itemName=ketho.wow-api) — IntelliSense
   - [WoW Bundle](https://marketplace.visualstudio.com/items?itemName=Septh.wow-bundle) — Lua syntax
   - [WoW TOC](https://marketplace.visualstudio.com/items?itemName=stanzilla.vscode-wow-toc) — TOC support
4. From this project root, run:
   ```powershell
   .\scripts\install-addon.ps1
   ```
   This creates a junction from your WoW `AddOns` directory so file changes are reflected instantly.

## Testing

Run the automated test suite with:

```powershell
.\scripts\run-tests.ps1
```

The tests use `lupa` to exercise the queue and summon-selection logic outside the WoW client.

## In-Game Usage

1. Enable **Flying Mount Cycler** in the AddOns menu.
2. Use `/fmount` each time you want the next mount.
3. Optional: place `/fmount` in a macro on your action bar.

## Lock Timer Notes

- Preset lock durations are available in settings.
- A custom lock duration can be set in Cycle Tools from 1 to 1440 minutes.
- Remaining lock time displays in minutes while above 60 seconds, then switches to seconds at 60 or less.

## Notes

- The addon targets Retail / Midnight (`## AllowLoadGameType: mainline`).
- SavedVariables are stored account-wide in `FlyingMountCyclerDB`.
- If Blizzard changes mount type IDs in future patches, update the lookup tables in `Init.lua`.
