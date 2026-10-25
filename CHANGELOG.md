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
