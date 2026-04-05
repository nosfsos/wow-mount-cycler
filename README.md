# WoW Flying Mount Cycler

This project contains a World of Warcraft Retail addon that cycles through your flying mounts without repetition until all available flying mounts have been used.

## What You Get

- Addon folder: `FlyingMountCycler`
- Slash command: `/fmount`
- Reset command: `/fmount reset`
- A deploy script to link the addon into your WoW `AddOns` folder

## Environment Setup (Windows)

1. Install WoW Retail.
2. Install [Visual Studio Code](https://code.visualstudio.com/) (or use Cursor).
3. Install a Lua extension:
  - [Lua Language Server](https://marketplace.visualstudio.com/items?itemName=sumneko.lua)
4. From this project root, run:
  ```powershell
   .\scripts\install-addon.ps1
  ```
   This creates a junction from your WoW `AddOns` directory to this local addon folder so file changes are reflected instantly.

## In-Game Usage

1. Enable `Flying Mount Cycler` in the AddOns menu.
2. Use `/fmount` each time you want the next flying mount.
3. Optional: place this macro on your action bar:
  ```text
   /fmount
  ```
4. If you want to restart the cycle early, use:
  ```text
   /fmount reset
  ```

## Notes

- The addon checks for usable flying mounts in your current area.
- It avoids repeating a mount until the full current pool has been used.
- If Blizzard changes mount type IDs in future patches, you may need to update the `FLYING_MOUNT_TYPE_IDS` table in `FlyingMountCycler.lua`.

