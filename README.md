# WoW Flying Mount Cycler

A World of Warcraft Retail addon that cycles through your favorite mounts without repetition, split by flying / ground / any-favorite pools.

## Features

- **No-repeat cycling** — every favorite gets used before any mount repeats
- **Pool-aware** — automatically picks flying-type mounts in flyable areas, ground-type elsewhere (configurable)
- **Skyriding support** — optionally includes dragonriding / skyriding families in the flying pool
- **Addon Compartment** — left-click the minimap button to open settings, right-click to summon
- **Settings panel** — full options in Esc > Options > AddOns > Flying Mount Cycler

## Slash Commands

| Command | Action |
|---|---|
| `/fmount` | Summon the next mount (or dismount in combat) |
| `/fmount reset` | Reset all cycle queues and start fresh |
| `/fmount refresh` | Refresh available mounts without losing progress |
| `/fmount config` | Open the settings panel |

Aliases: `/flyingmount`, `/fmc`

## File Structure

```
FlyingMountCycler/
├── FlyingMountCycler.toc   # Addon metadata & load order
├── Init.lua                # Shared namespace, constants, defaults
├── Utils.lua               # Messaging helpers, array utilities
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

## In-Game Usage

1. Enable **Flying Mount Cycler** in the AddOns menu.
2. Use `/fmount` each time you want the next mount.
3. Optional: place `/fmount` in a macro on your action bar.

## Notes

- The addon targets Retail / Midnight (`## AllowLoadGameType: mainline`).
- SavedVariables are stored account-wide in `FlyingMountCyclerDB`.
- If Blizzard changes mount type IDs in future patches, update the lookup tables in `Init.lua`.
