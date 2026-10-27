# Testing sw_tow

Three layers. Each one catches what the one before cannot.

| Layer | Command | Needs | Time | Catches |
|---|---|---|---|---|
| Offline tests and static analysis | `scripts/test.sh` | Lua 5.4 | ~10 s | Logic: rules, money, fees, abuse checks, timeouts, locales, config. Typos, wrong natives, wrong types |
| Self-test | `swtow_selftest` (server console) | a running server | 1 s | The real database, framework, jobs, garage, keys and banking scripts and their accounts |
| In-game scenarios | `/swtow_test` | a dev server and a game client | ~5 min | The real game: ramps, winch, hook, physics, streaming, ownership, the panel, the counter |

What none of them judges: how it looks and feels, two players watching the same winch, and resmon.
Those stay a short manual pass (see the end).

## 1. Offline: `scripts/test.sh`

```
scripts/test.sh            # all tests, then lua-language-server
scripts/test.sh impound    # only tests whose name contains "impound"
lua tests/run.lua calls    # tests only
```

Lua 5.4: `winget install DEVCOM.Lua` (Windows), `apt install lua5.4`, `brew install lua`.

`tests/lib/world.lua` is a simulated FiveM server: players, peds, vehicles, seats, state bags, events,
threads with a clock you can move (`w:advance(seconds)`), lib.callback and commands. It loads the real
`server/*.lua` through `server/main.lua`. Faked are only the thin layers that a real server checks
anyway (layer 2): the framework bridge, the garage/keys/banking integrations and `server/storage.lua`.

A test reads like the flow it checks:

```lua
test.case('too fast: a teleport to the yard is refused and nothing changes', function()
    local w = newWorld()
    local t = flow.towedToYard(w)          -- owner calls, worker accepts, loads, drives
    ...
    test.refusedWith('impound.too_fast', flow.deliver(w, worker, truck))
    w:assertNoErrors()                     -- nothing logged with lib.print.error
end)
```

Put the callback last in `test.refusedWith(key, w:call(...))`: Lua passes all return values only from
the last argument. `newWorld({ config = function(c) ... end })` changes config values for one test.

Static checks in the suite: every Lua file compiles, every language has the English keys with the
same `%s` placeholders, every key the code uses exists and none is unused, and the shipped
`config.lua` passes `server/configcheck.lua`.

## 2. Self-test: `swtow_selftest`

Server console (or an admin in game, results in F8). No player needed. Checks the framework, that the
`tow` job and a job of type `leo` exist, which garage, keys and banking scripts were picked, that the
company and police accounts exist, both tables with all columns, a full write → read → hold list →
lift → release cycle through `server/storage.lua` against the real database, the database clock
against the server clock (storage-day fees depend on it), the texts and the contract spots. Results
are printed and written to `selftest.log`.

It found a bug the offline tests could not: oxmysql returns `TINYINT(1)` as a boolean, so police holds
never blocked a release. `storage.lua` now casts it.

## 3. In game: `/swtow_test`

Development servers only. In `server.cfg`:

```
setr sw_tow_dev 1
```

It needs admin rights (ace `command.swtow_test`) and hands out the job, money and test vehicles, so
never set it on a live server. The console warns while it is on.

Stand on flat, open ground with about 40 m free in front of you (a big car park, the airport) and run
`/swtow_test` for a menu or `/swtow_test all`. It uses the same functions as the target options and
menus, with your own character:

| Scenario | What it does |
|---|---|
| `points` | All models exist; office, clerk, truck spawn, yard zone and release spots are on the ground |
| `shift` | Clock in (refused away from the counter), panel visible, take a truck, second truck refused, return refused far away, return, clock out, panel hidden |
| `flatbed` | Six vehicles and positions: sedan, SUV, low sports car, 1 m to the side, turned 10°, rear first. Each is winched up, checked straight in the middle of the bed and secured, unloaded and checked on its wheels. Out of range and blocked path are refused. A car standing on the bed is strapped in place |
| `hook` | Hooked on the tow arm and off again; an empty police car needs an order |
| `impound` | A call for someone else's car is refused. Your owned car: call, accept, panel shows call, cargo and timer, cancel refused once loaded, instant trip refused as too fast, hand-over pays the expected amount, garage lists it impounded, public lot will not hand it out, counter fee is base + class + tow, 27 hours add two days, release charges the fee and the car stands on the release spot |
| `police` | Police order with a hold and a $500 fine: release refused on hold, hold lifted, fee includes the fine, release |
| `contract` | A contract near you: the vehicle appears when you get close, engine damaged, locked, bonnet open; dropped stays open for others; closed takes the vehicle away |
| `abandoned` | A left vehicle becomes a call when nobody is near; the call closes when a player drives it away |

Every line goes to F8 and to `tests-ingame.log` in the resource folder. The format (numbers made up):

```
sw_tow in-game tests: 96 PASS · 1 WARN · 0 FAIL · 0 SKIP · 287 s · removed 3 test vehicles, 2 records
PASS  flatbed    sedan straight behind: loaded in 9.8 s
FAIL  flatbed    low sports car: straight in the middle of the bed (x +0.31 m, turned 1.2°)
```

At the end it removes every test vehicle (plates `SWTE…`) and its database rows and ends the shift.

## 4. By hand, about 15 minutes

- Looks: ramps, cable, the vehicle climbing and tipping over the edge, the panel, notifications.
- Two clients (`FiveM.exe -cl2`): the second one sees ramps, cable and the loaded vehicle the same way.
- The officer's order form and the hold list at the counter.
- The call list on F6 with several calls.
- `resmon 1`: off shift, on shift idle, during a winch run.
