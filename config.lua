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

    adapters = {                -- Which integration to use. 'auto' picks the first one that is running.
        garage = 'auto',        -- 'qbx_garages' | 'none'. With 'none' owned vehicles cannot be impounded.
        keys = 'auto',          -- 'qbx_vehiclekeys' | 'none'.
        banking = 'auto',       -- 'Renewed-Banking' | 'none'. Receives the company share of release fees.
    },

    office = {
        label = 'Shiftworks Towing',                        -- Name on the map and in menus.
        coords = vec4(471.39, -1311.03, 29.21, 114.5),      -- Counter where workers clock in and take trucks.
        size = vec3(2.0, 2.0, 2.5),                         -- Size of the counter interaction box.
        blip = { enabled = true, sprite = 68, color = 47, scale = 0.7 },
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

    flatbed = {
        bone = 'bodyshell',                 -- Truck bone the cargo is attached to.
        bed = vec3(0.0, -2.35, 0.55),       -- Bed point relative to the truck: y along the truck, z bed surface.
        winch = vec3(0.0, 0.9, 0.95),       -- Winch drum relative to the truck, where the cable starts.
        rampStart = vec3(0.0, -7.0, 0.0),   -- Where the winch path starts behind the truck (z is ground level).
        winchRange = 12.0,                  -- Max distance from the rear of the bed to a vehicle to hook it.
        pullSpeed = 1.4,                    -- Winch speed in m/s.
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
    },
}
