# Changelog

## 0.1.0 (unreleased)

- Tow company job: clock in, company flatbed and tow truck with keys.
- Flatbed winch with a synced cable; tow truck uses the game's tow arm.
- Flatbed loading over ramps: a parking guide tints the ground behind the truck, the winch lines the vehicle up and pulls it up the ramps, and it ends straight on the bed. `flatbed.motion` picks a computed path (default) or the game's physics; unloading always follows the path. The winch checks that the way is clear first, and nobody can block it by standing in it.
- Calls from players, police orders with fine and hold, NPC contracts, abandoned vehicles.
- Impound yard with release fee, police holds and a counter for owners and officers.
- Protection for the public Qbox impound lot through a `qbx_garages` hook.
- Shift panel in the Shiftworks style, restyled from `config.ui`.
- QBCore bridge (experimental): `qb-core`, `qb-garages`, `qb-vehiclekeys`, `qb-banking`. Impounded vehicles stay off the qb-garages depot list. Impound fees use the base rate there, since qb-core has no server-side vehicle class.
- `/swtow_spots`: admin tool that finds roadside spots for NPC contracts across the map and shows them as blips.
- A clerk stands at the office counter (`office.ped`), so players can find it.
- Languages: English, German, Russian.
- Sounds: ramps, winch motor, straps and tow arm, from the game's own audio, played from the truck for everyone nearby (`config.sounds`, `/swtow_sounds` to pick by ear).
- The winch cable runs along the bed and over its rear edge instead of through the bed.
- Fixed: the winch cable sagged through the ground while loading (the game shortens a rope only while winding it in).
- `swtow_selftest`: checks the installation (jobs, integrations and their accounts, database tables, a database round trip, clocks, texts, contract spots).
- `config.lua` is checked on start; mistakes stop the start with each problem named.
- Tests: offline suite on a simulated server (`scripts/test.sh`, also in CI) and in-game scenarios for development servers (`/swtow_test`, needs `setr sw_tow_dev 1`).
- Fixed: police holds never blocked a release (oxmysql returns the hold flag as a boolean).
- Fixed: a loaded call could be dropped and then never handed over; loaded calls no longer expire.
- Fixed: abandoned-vehicle calls stayed open after a player drove the car away.
- Fixed: vehicles could spawn into a car with a player in it at the truck spawn, release and contract spots.
- Fixed: a failed unload could leave the ramps down with no way to raise them.
- Fixed: a missed tow-arm hook counted as cargo.
- Fixed: route and yard-zone loops ran off shift.
- Repeating an action too quickly now says to wait a moment instead of "Something went wrong".
- Fixed (QBCore): released motorcycles were created as cars.
- Fixed: a hand-over could be refused as "nothing loaded" right after arriving, while the server's copy of the strapped car's position still trailed the truck.
