-- Shiftworks Tow & Impound: configuration.
-- Every value here is safe to change. Coordinates are vec3(x, y, z) or vec4(x, y, z, heading).
-- Money is in whole dollars. Distances are in meters, times in the unit named next to them.

return {
    job = 'tow',                -- Job name from your framework. Only players with this job can clock in.
    policeJobType = 'leo',      -- Job type that may order tows and lift police holds.
    debug = false,              -- Extra console output and visible zones. Keep false on a live server.

    notify = {
        position = 'top-right',  -- ox_lib notification position.
    },

    ui = {                       -- Shift panel shown while on shift. Restyle it here, no code changes needed.
        enabled = true,          -- false hides the panel; notifications and menus still work.
        position = 'right',      -- Screen edge: 'right' or 'left'.
        top = 32,                -- Distance from the top of the screen, in % of its height.
        scale = 1.0,             -- 0.8 to 1.3. Size of the whole panel.
        accent = '#ff7a2e',      -- Main colour: timer bar and active marks. Text on it stays dark.
        label = 'SHIFTWORKS · TOW', -- Small label in the header. Your server name works too.
        logo = nil,              -- Optional image in the header: a URL or 'nui://your_resource/logo.png'.
    },

    adapters = {                -- Which integration to use. 'auto' picks the first one that is running.
        garage = 'auto',        -- 'qbx_garages' | 'qb-garages' | 'none'. With 'none' owned vehicles cannot be impounded.
        keys = 'auto',          -- 'qbx_vehiclekeys' | 'qb-vehiclekeys' | 'none'.
        banking = 'auto',       -- 'Renewed-Banking' | 'qb-banking' | 'none'. Receives the company share of release fees.
    },

    office = {
        label = 'Shiftworks Towing',                        -- Name on the map and in menus.
        coords = vec4(472.18, -1310.78, 29.22, 218.2),      -- Counter where workers clock in and take trucks.
        size = vec3(2.0, 2.0, 2.5),                         -- Size of the counter interaction box.
        blip = { enabled = true, sprite = 68, color = 47, scale = 0.7 },
        -- Clerk at the counter, so players can find it; aiming at the clerk offers the counter's options.
        -- Stands at office.coords unless you add coords = vec4(...) here. nil = no clerk.
        ped = { model = 's_m_m_autoshop_01', scenario = 'WORLD_HUMAN_CLIPBOARD' },
    },

    garage = {
        spawn = vec4(489.65, -1331.82, 29.33, 306.5),       -- Where a company truck appears.
        returnDistance = 20.0,                              -- A truck can be returned this close to the spawn point.
        platePrefix = 'SWT',                                -- Plates are this prefix plus digits, 8 characters max.
        vehicles = {                                        -- Trucks a worker can take out, by model name.
            { model = 'flatbed', label = 'Flatbed', method = 'flatbed' },
            { model = 'towtruck', label = 'Tow truck', method = 'hook' },
        },
    },

    yards = {
        strawberry = {
            label = 'Shiftworks Impound',                   -- Name on the map and in the yard menu.
            -- Area where a loaded truck hands over its cargo: center, size and rotation in degrees.
            zone = { coords = vec3(491.0, -1314.69, 29.25), size = vec3(30.0, 30.0, 8.0), rotation = 0.0 },
            counter = nil,                                  -- Release counter (vec4). nil = use the office counter.
            releaseSpots = {                                -- Released vehicles appear on the first free spot.
                vec4(489.65, -1331.82, 29.33, 306.5),
            },
            blip = { enabled = true, sprite = 524, color = 47, scale = 0.7 },
        },
    },

    flatbed = {                             -- Truck-space values: x right, y forward, z up, in metres.
        winch = vec3(0.0, 0.9, 0.95),       -- Winch drum, where the cable starts.
        bedFrontY = 0.5,                    -- The loaded vehicle's front stops here, just behind the cab.
        rearY = nil,                        -- Rear edge of the bed. nil = measured from the truck model.
        bedHeight = 0.55,                   -- Bed surface height, used only if measuring it fails.
        ramp = {
            model = 'imp_prop_flatbed_ramp', -- Ramp object. Try others in game with /swtow_ramps.
            flip = true,                    -- true when the model's high end is at its back (as this one).
            pair = false,                   -- true: one ramp per wheel track; false: one wide ramp.
            spacing = 1.7,                  -- Distance between the two ramps when pair = true.
            candidates = {                  -- What /swtow_ramps shows when run without a model.
                'prop_metal_plates01', 'prop_metal_plates02', 'prop_mp_ramp_01', 'prop_mp_ramp_02',
                'prop_mp_ramp_03', 'prop_byard_ramp', 'prop_skate_flatramp', 'imp_prop_flatbed_ramp',
            },
        },
        winchRange = 10.0,                  -- Max distance from the ramp foot to the vehicle's bumper.
        pullSpeed = 1.0,                    -- Winch speed in m/s.
        pullTimeout = 40,                   -- Seconds before a winch run gives up.
        steerWheels = false,                -- Also turn the front wheels visibly while lining up.
        rope = true,                        -- Draw the winch cable for everyone nearby.
    },

    hook = {
        range = 7.0,                        -- Max distance from the tow arm to a vehicle to hook it.
    },

    blockedClasses = {                      -- Vehicle classes that cannot be towed.
        [14] = true,                        -- Boats.
        [15] = true,                        -- Helicopters.
        [16] = true,                        -- Planes.
        [21] = true,                        -- Trains.
    },

    orderOnlyClasses = {                    -- Classes that need an accepted call (police order, player call).
        [18] = true,                        -- Emergency: an empty police car at a scene is not street clutter.
        [19] = true,                        -- Military.
    },

    calls = {
        command = 'calltow',                -- Players call a tow truck: /calltow [message].
        cancelCommand = 'canceltow',        -- Players cancel their open call.
        listCommand = 'towcalls',           -- Workers open the call list.
        listKey = 'F6',                     -- Default key for the call list. Players can rebind it in settings.
        vehicleRange = 15.0,                -- The caller must be this close to the vehicle.
        acceptTimeout = 10,                 -- Minutes an open call waits before it expires.
        deliverTimeout = 30,                -- Minutes an accepted call may take until delivery.
        cooldown = 60,                      -- Seconds between two calls from one player.
        maxOpen = 10,                       -- Open calls on the whole server at once.
    },

    police = {
        enabled = true,                     -- Officers on duty can order a tow on any vehicle.
        maxFine = 5000,                     -- Highest fine an officer can add to the release fee.
        maxHoldHours = 168,                 -- Longest timed hold. 0 in the form means "until lifted".
        ordersPerHour = 6,                  -- Per officer, against abuse.
        fineAccount = 'police',             -- Account that receives the fine when the owner pays.
    },

    contracts = {
        enabled = true,                     -- Broken-down NPC vehicles to tow when no player is calling.
        maxOpen = 3,                        -- Open contracts at once. Never more than workers on shift + 1.
        interval = 90,                      -- Seconds between checks for a new contract.
        minDistance = 400.0,                -- Contract spot distance from the worker, min and max.
        maxDistance = 3500.0,
        models = {                          -- Vehicles that break down (lore-friendly base game models).
            'asea', 'asterope', 'emperor', 'fugitive', 'ingot', 'intruder', 'premier', 'primo',
            'stanier', 'stratum', 'washington', 'blista', 'dilettante', 'panto', 'prairie', 'rhapsody',
            'bison', 'bobcatxl', 'burrito3', 'minivan', 'rumpo', 'speedo', 'youga',
        },
    },

    abandoned = {
        enabled = true,                     -- Vehicles a player left behind become calls.
        minutes = 30,                       -- How long a vehicle must stand without anyone nearby.
        playerRadius = 50.0,                -- No player may be this close for the timer to run.
        owned = false,                      -- Also flag players' own (owned) vehicles. Off: only unowned ones.
        maxOpen = 4,                        -- Open abandoned-vehicle calls at once.
        scanInterval = 30,                  -- Seconds between scans. Calls are only created while someone is on shift.
        payFactor = 0.6,                    -- Share of the normal delivery pay.
        ignoreZones = {                     -- No flags inside these boxes (parking lots, garages).
            -- { coords = vec3(215.0, -810.0, 30.7), size = vec3(60.0, 60.0, 10.0), rotation = 70.0 },
        },
    },

    payout = {
        base = 150,                         -- $ for every delivered vehicle.
        perKm = 60,                         -- $ per km between pickup and yard.
        max = 1500,                         -- Cap per delivery.
        account = 'bank',                   -- Where workers are paid: 'cash' or 'bank'.
        partnerShare = 0.5,                 -- A partner in the truck gets this share of the payout on top.
        maxSpeed = 30.0,                    -- m/s used for the minimum trip time. Faster deliveries are refused.
    },

    fees = {
        base = 250,                         -- $ every release costs.
        byClass = {                         -- Extra $ by vehicle class.
            [6] = 200,                      -- Sports.
            [7] = 450,                      -- Super.
            [20] = 300,                     -- Commercial.
        },
        perDay = 100,                       -- $ per started day of storage after the free hours.
        freeHours = 2,                      -- Hours of free storage.
        companyShare = 0.6,                 -- Share of each release fee paid into the company account (0 to 1).
        companyAccount = 'tow',             -- Company account name in the banking script.
    },

    limits = {                              -- Anti-abuse: minimum milliseconds between actions per player.
        default = 500,
        takeTruck = 5000,
        call = 1000,
        policeOrder = 3000,
        ramps = 1500,
    },
}
