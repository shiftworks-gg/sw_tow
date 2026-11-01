# Changelog

## 1.0.0 (unreleased)

First release.

**The job**
- Tow company: clock in at the office, take a flatbed or a tow truck with keys. A clerk stands at the counter (`office.ped`) so players find it.
- Flatbed: ramps go down, a parking guide tints the ground behind the truck, the winch lines the vehicle up and pulls it up the ramps on a cable everyone nearby sees, and it ends straight in the middle of the bed. The winch checks that the way is clear first, and nobody can block it by standing in it. `flatbed.motion` picks a computed path (default) or the game's physics.
- Tow truck: the game's own tow arm.
- Four kinds of calls: players call for their own vehicle (`/calltow`), officers order a tow with a fine and a hold, NPC contracts appear when the server is quiet, and vehicles left standing become calls after 30 minutes.
- End shift from the call list (`F6`): a route leads back to the depot, `E` at the truck spot hands the truck in and ends the shift. Without a truck the route leads to the office counter.
- Pay is collected at the office by default (`payout.collect`): it adds up during the shift and is paid when the shift ends there. Nothing is lost on a disconnect; it is paid at the next clock in.
- Truck deposit (`garage.deposit`, $500): paid back when the truck is handed in, less damage (`garage.damageFromDeposit`). A truck left somewhere or wrecked keeps it; a wrecked one can be replaced at the counter. A truck removed by the game or another script in working order gives it back.
- Six truck spots at Hayes Depot (`garage.spawns`): each truck goes to the first clear one. Workers asking at the same moment never get the same spot; the release spots at the yard work the same way.
- Your own truck among identical company trucks: an arrow above it until you first get in, and a map blip that follows it.
- A second worker in the truck gets 50% of the delivery pay on top.
- Sounds for ramps, winch motor, straps and tow arm, from the game's own audio, heard by everyone nearby (`config.sounds`, `/swtow_sounds` to pick by ear).

**The impound yard**
- Default yard: the Davis impound on Innocence Blvd, with its own clerk at the release counter (`yards.*.ped`) and two release spots.
- Release fee: base + vehicle class + days in storage + police fine + the tow itself. Owners pay at the counter and drive off with their keys. The company account gets 60%.
- Police holds: an officer sets one with the tow order and lifts it at the counter; a held vehicle is not released.
- Works with `qbx_garages`: the public impound lot cannot hand out a vehicle held in the yard. Nothing in your garage script is edited.

**Shift panel**
- Built around the next step: drive to the pickup, load, deliver to the yard, with a countdown ring, where to go and how far, step progress, cargo state, earnings with the last payout, time on shift and open calls. It scales with the screen resolution.
- Themes: `shiftworks`, `ox` (in ox_lib's colours and font), `mission` (like the game's objectives) and `compact`. The accent follows `ox:primaryColor` when set; colours, font, opacity, side, height and size are in `config.ui`.
- Your own HUD instead: `ui.enabled = false` and `exports.sw_tow:GetShiftState()` on the client.
- Menus, dialogs and notifications are your server's ox_lib as it is. `notify.custom` sends notifications to any other script; `notify.style = 'shiftworks'` gives the dark Shiftworks look.

**Server owners**
- Every action is checked on the server: shift, truck, distance, rate and trip time. Refused actions are logged with the reason, never punished. A tow called on your own car never makes money.
- `swtow_selftest` checks the installation: jobs, garage, keys and banking scripts and their accounts, database tables and a round trip, clocks, texts, contract spots.
- `config.lua` is checked on start; a mistake stops the start with every problem named.
- If the game or another resource removes a company truck, the worker is told and can take a new one; the console names it (`truck_lost`).
- `/swtow_spots`: finds roadside spots for NPC contracts across the map.
- Discord log through `set sw_tow:webhook`.
- Languages: English, German, Russian.
- QBCore (experimental): `qb-core`, `qb-garages`, `qb-vehiclekeys`, `qb-banking`. Fees use the base rate there, since qb-core has no server-side vehicle class.

**Development**
- Offline tests on a simulated server and static analysis (`scripts/test.sh`, also in CI); in-game scenarios for development servers (`/swtow_test`, needs `setr sw_tow_dev 1`).
