# Flying Mount Cycler

Flying Mount Cycler is a WoW Retail addon that summons favorite mounts with smart pool selection and anti-repeat logic.

## What it does

- Cycles favorites across separate `flying`, `ground`, and `any` pools.
- Supports strict no-repeat cycling until the current pool is exhausted.
- Offers recent-history avoidance when no-repeat mode is disabled.
- Supports skyriding mount families in the flying pool (optional).
- Includes mount lock mode with preset and custom timers (1-1440 minutes).
- Adds skip/next controls to force a new mount immediately.

## Commands

- `/fmount` - summon next mount (or dismount in combat).
- `/fmount skip` - force next mount now (bypass current lock once).
- `/fmount next` - alias of `/fmount skip`.
- `/fmount reset` - reset all cycle queues.
- `/fmount reset flying|ground|any` - reset one pool.
- `/fmount refresh` - refresh available mounts without losing progress.
- `/fmount status` - print current cycle and lock status.
- `/fmount config` - open addon settings.

## UI

- Full options panel under `Esc > Options > AddOns > Flying Mount Cycler`.
- Addon Compartment button: left-click opens settings, right-click summons next mount.
- Cycle Tools includes refresh, reset, pool reset buttons, and skip/next button.

## Notes

- Retail/mainline only.
- Uses account-wide SavedVariables: `FlyingMountCyclerDB`.
