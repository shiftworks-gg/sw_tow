# Shiftworks Tow & Impound

Multiplayer towing job with player calls, police orders and an impound yard. Free and open source (GPL-3.0).

`Qbox` · `Open config` · `EN / DE / RU`

> Status: 0.1.0, in development. QBCore support is experimental: it passes a server smoke test against qb-core, qb-garages and qb-banking but has not been played yet. ESX is planned and stops with a clear message.

## What it does

- **Tow company.** Workers clock in at the office and take a flatbed or a tow truck with keys.
- **Winch and tow arm.** On the flatbed the cable pulls the vehicle up onto the bed; everyone nearby sees the cable. The tow truck uses the game's own arm.
- **Four kinds of calls.** Players call for their own vehicle (`/calltow`), officers order a tow with a fine and a hold, broken-down NPC vehicles appear when the server is quiet, and vehicles left behind by players become calls after 30 minutes.
- **Impound yard.** Owned vehicles are stored with a fee: base + vehicle class + days in storage + police fine + the tow itself. Owners pay at the counter and drive off with their keys.
- **Works with your garages.** The public Qbox impound lot cannot hand out a vehicle that is held in the yard. Nothing in `qbx_garages` is edited.
- **Server decides.** Every action is checked on the server: shift, truck, distance, rate and trip time. Refused actions are logged, never punished.
- **Leaves service vehicles alone.** Emergency and military vehicles are towed only on an accepted call and never flagged as abandoned.
- **Partner pay.** A second worker in the truck gets 50% of the delivery pay on top.

## Requirements

| | |
|---|---|
| Server | FXServer with OneSync |
| Framework | Qbox (`qbx_core` 1.19 or newer); QBCore (`qb-core`, experimental, with `qb-garages`, `qb-vehiclekeys`, `qb-banking`) |
| Libraries | `ox_lib` 3.30+, `ox_target` 1.17+, `oxmysql` 2.10+ |
| Optional | `qbx_garages` + `qbx_vehicles` (impound of owned vehicles and player calls), `qbx_vehiclekeys`, `Renewed-Banking` (company and police accounts) |

## Install in 5 steps

1. Download the latest release and put the `sw_tow` folder in your `resources` directory.
2. Add `ensure sw_tow` to `server.cfg`, after `ox_lib`, `ox_target`, `oxmysql` and your framework.
3. If you run `qbx_towjob`, remove it or add `stop qbx_towjob`: both use the same office.
4. Make sure your framework has a job named `tow` (Qbox ships one). Officers need a job with type `leo`.
5. Restart the server. Tables are created on the first start, there is no SQL to import.

The console shows one line when it is ready:

```
[sw_tow] Shiftworks Tow & Impound 0.1.0 · framework qbox · garage qbx_garages · keys qbx_vehiclekeys · banking Renewed-Banking
```

Then type `swtow_selftest` in the server console. It checks the job, the police job type, the garage, keys and banking scripts and their accounts, the database tables, a write and read through the database, its clock, the texts and the contract spots, and names anything that needs fixing:

```
sw_tow 0.1.0 self-test, 2026-10-27 16:54:33 · 14 PASS · 0 WARN · 0 FAIL
```

A mistake in `config.lua` stops the start with every problem named, for example `config.lua → payout.account: must be one of cash, bank, is wallet`.

## Configuration

Everything is in `config.lua`, one comment per line. The parts people change most:

| Key | Default | What it does |
|---|---|---|
| `office.coords` | Strawberry tow yard | Counter for clock in, trucks and vehicle release |
| `office.ped` | mechanic with a clipboard | Clerk at the counter so players find it; `nil` for none |
| `flatbed.motion` | `'animated'` | How the winch moves the vehicle: a computed path (always ends straight on the bed) or `'physics'` |
| `blockedClasses`, `orderOnlyClasses` | boats, aircraft, trains; emergency, military | Never towable; towable only on an accepted call |
| `yards` | one yard | Hand-over zone, release counter, exit spots. Add as many as you like |
| `payout.base`, `payout.perKm`, `payout.max` | 150, 60, 1500 | Delivery pay |
| `fees` | 250 base, 100 per day | Release fee. The company account gets 60% |
| `police.maxFine`, `police.ordersPerHour` | 5000, 6 | Limits for officers |
| `contracts.enabled` | true | NPC jobs when no player is calling |
| `abandoned.minutes`, `abandoned.owned` | 30, false | When a left vehicle becomes a call; whether owned vehicles count |
| `ui` | right edge, orange | Shift panel side, height, size, accent colour, header label, logo |

Discord logging: set `set sw_tow:webhook "https://discord.com/api/webhooks/..."` in `server.cfg`. Keep webhooks out of config files.

Texts live in `locales/en.json`, `de.json`, `ru.json`. The language follows `setr ox:locale`.

## Commands

| Command | Who | What |
|---|---|---|
| `/calltow [note]` | everyone | Call a tow truck for the vehicle you are in or drove last |
| `/canceltow` | everyone | Cancel your call |
| `/towcalls` or `F6` | workers on shift | Call list. The key can be changed in GTA settings |
| `/swtow_spots generate [cell]` | admins | Scans the map for roadside spots for NPC contracts and saves them to `data/spots.generated.lua`. One spot per cell, 250 m by default (100–1000). Takes a few minutes; stay in game |
| `/swtow_spots show` / `hide` | admins | Shows every contract spot on the map: blue are bundled, orange generated |
| `/swtow_coords` | everyone | Prints your position and heading as `vec4(...)` and copies it, for placing things in `config.lua` |
| `swtow_selftest` | console, admins | Checks the installation, see above. Results also go to `selftest.log` |

Admin commands need the ace `command.swtow_spots` (the default Qbox recipe gives `group.admin` all commands). Generated spots are used after `restart sw_tow`, face along the road, and keep 150 m from each other and 120 m from the office and yards. Delete a line from the file to drop a spot, or the whole file to go back to the bundled list.

## Exports and events

```lua
-- Server: create a call for a player's current vehicle (for phones and radial menus).
local ok, errorKey = exports.sw_tow:CreateCall(source, 'Flat tyre on the highway')
```

State bags other scripts can read:

| Bag | On | Value |
|---|---|---|
| `sw_tow:shift` | player | `true` while on shift |
| `sw_tow:company` | vehicle | citizenid of the worker who took the company truck |
| `sw_tow:cargo` | vehicle (truck) | netId of the loaded vehicle |
| `sw_tow:towedBy` | vehicle (cargo) | netId of the truck |

## Common problems

- **"no supported framework is running".** Start your framework before `sw_tow` in `server.cfg`.
- **Owned vehicles are refused at the yard ("no tow order").** Owned vehicles need an accepted call, a police order or an abandoned-vehicle call. This stops workers from impounding parked cars.
- **"No supported garage script found" in the console.** Without a supported garage script owned vehicles cannot be impounded and `/calltow` is off, because ownership cannot be checked. Police orders, NPC contracts and abandoned vehicles still work.
- **Two tow offices at the same spot.** Stop `qbx_towjob`.

## Performance

Built for 0.00 ms while not on shift. The client runs nothing until you clock in: only targets and state bag handlers. The server runs three light timers (call timeouts and the abandoned-vehicle scan every 30 s, contracts every 90 s). On shift the panel refreshes once per second; the winch draws its cable only while it is pulling. Measured resmon values will be published with the 1.0 release.

## Development

`scripts/test.sh` runs everything that needs no server: the offline test suite (the real server code
on a simulated FiveM server, Lua 5.4) and the static analysis. CI runs both on every push. On a
development server `/swtow_test` plays the main flows in game with your own character. See
[docs/TESTING.md](docs/TESTING.md).

## Credits

- Contract spots: from `qbx_towjob` by the Qbox project (GPL-3.0).
- Fonts: Barlow Condensed and IBM Plex (SIL Open Font License, see `html/fonts`).
- Icons: Tabler Icons (MIT).

## License

GPL-3.0-or-later. You can use, change and share it. If you share a changed version, it must stay open source under the same licence.

Made by Shiftworks.
