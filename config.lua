-- Shiftworks Tow & Impound: configuration.
-- Every value here is safe to change. Coordinates are vec3(x, y, z) or vec4(x, y, z, heading).
-- Money is in whole dollars. Distances are in meters, times in the unit named next to them.

return {
    job = 'tow',                -- Job name from your framework. Only players with this job can clock in.
    policeJobType = 'leo',      -- Job type that may order tows and lift police holds.
    debug = false,              -- Extra console output and visible zones. Keep false on a live server.

    notify = {                   -- Notifications. By default they look like every other ox_lib notification on your server.
        style = 'server',        -- 'server': your ox_lib as it is (also restyled or replaced) | 'shiftworks': the dark Shiftworks look.
        position = nil,          -- nil = ox_lib's own position. Or 'top-right', 'top', 'center-right', ...
        -- Send them to any notification script instead; kind is 'success', 'inform', 'warning' or 'error'.
        -- custom = function(message, kind) exports.your_notify:Show(message, kind) end,
    },

    ui = {                       -- Shift panel shown while on shift. Restyle it here, no code changes needed.
        enabled = true,          -- false hides the panel; notifications and menus still work.
        menus = 'shiftworks',    -- Impound counter, police holds and tow order: 'shiftworks' (a window in the
                                 -- panel's colours and font) | 'ox' (your server's ox_lib menus and dialogs).
        theme = 'shiftworks',    -- 'shiftworks' (card with countdown ring) | 'ox' (the card in ox_lib's colours and font) | 'mission' (no box, like GTA objectives) | 'compact' (two small pills).
        accent = 'auto',         -- 'auto': your ox_lib colour if you set one (setr ox:primaryColor), else orange. Or a colour like '#ff7a2e'.
        position = 'right',      -- Screen edge: 'right' or 'left'.
        top = 26,                -- Distance from the top of the screen, in % of its height.
        scale = 1.0,             -- 0.8 to 1.3. Size of the whole panel; it already grows with the screen resolution.
        opacity = nil,           -- 0.6 to 1: how solid the background is. nil = fully solid.
        label = 'Shiftworks · Tow', -- Small label at the top while waiting for calls. Your server name works too.
        logo = nil,              -- Optional image in the header: a URL or 'nui://your_resource/logo.png'.
        font = nil,              -- Match your other UIs: { family = 'Poppins', url = 'nui://your_ui/fonts/poppins.woff2' }. nil = the theme's fonts.
        colors = {               -- Optional: any of these overrides the theme. Colours like '#172027'.
            -- surface = '#10171c',  -- Panel background.
            -- header = '#1a242c',   -- Top of the card (it fades into the background).
            -- text = '#f2f4f5',     -- Main text.
            -- muted = '#a9b5bd',    -- Labels and secondary text.
            -- line = '#2a363f',     -- Dividers and border.
        },
    },

    adapters = {                -- Which integration to use. 'auto' picks the first one that is running.
        garage = 'auto',        -- 'qbx_garages' | 'qb-garages' | 'none'. With 'none' owned vehicles cannot be impounded.
        keys = 'auto',          -- 'qbx_vehiclekeys' | 'qb-vehiclekeys' | 'none'.
        banking = 'auto',       -- 'Renewed-Banking' | 'qb-banking' | 'none'. Receives the company share of release fees.
    },

    office = {
        label = 'Shiftworks Towing',                        -- Name on the map and in menus.
        coords = vec4(472.18, -1310.78, 29.22, 218.2),      -- Counter where workers clock in and take trucks.
        size = vec3(2.0, 2.0, 2.5),                         -- Size of the counter interaction box (used when ped = nil).
        blip = { enabled = true, sprite = 68, color = 47, scale = 0.7 },
        -- Clerk at the counter, so players can find it; aiming at the clerk offers the counter's options
        -- (instead of the box above).
        -- Stands at office.coords unless you add coords = vec4(...) here. nil = no clerk.
        ped = { model = 's_m_m_autoshop_01', scenario = 'WORLD_HUMAN_CLIPBOARD' },
    },

    garage = {
        spawns = {                                          -- Truck spots: a truck appears on the first one that is clear
            vec4(489.65, -1331.82, 29.33, 306.5),           -- (no vehicle, nobody standing on it). One spot per worker who
            vec4(479.23, -1333.37, 29.31, 225.7),           -- may take a truck at the same moment; add more for busy servers.
            vec4(491.32, -1348.07, 29.36, 358.7),
            vec4(515.59, -1330.25, 29.32, 217.7),
            vec4(497.24, -1302.21, 29.35, 213.0),
            vec4(487.03, -1307.78, 29.36, 226.0),
        },
        returnDistance = 20.0,                              -- A truck can be handed back this close to any truck spot.
        deposit = 500,                                      -- $ taken when a truck goes out, paid back when it is handed in. 0 = no deposit.
        damageFromDeposit = true,                           -- Damage on the returned truck comes off the deposit (a wreck keeps it all).
        platePrefix = 'SWT',                                -- Plates are this prefix plus digits, 8 characters max.
        vehicles = {                                        -- Trucks a worker can take out, by model name.
            { model = 'flatbed', label = 'Flatbed', method = 'flatbed' },
            { model = 'towtruck', label = 'Tow truck', method = 'hook' },
        },
    },

    yards = {
        davis = {
            label = 'Shiftworks Impound',                   -- Name on the map and in the yard menu.
            -- Area where a loaded truck hands over its cargo: center, size (width, length, height) and
            -- rotation in degrees, which is also the heading a truck drives in with.
            zone = { coords = vec3(408.38, -1638.62, 29.38), size = vec3(6.0, 14.0, 8.0), rotation = 50.2 },
            counter = vec4(402.97, -1628.89, 29.29, 221.0), -- Release counter (vec4). nil = use the office counter.
            -- Clerk at the counter (only when counter is set); aiming at the clerk opens it. nil = an invisible box.
            ped = { model = 's_m_m_autoshop_02', scenario = 'WORLD_HUMAN_CLIPBOARD' },
            releaseSpots = {                                -- Released vehicles appear on the first free spot.
                vec4(395.58, -1645.16, 29.29, 316.0),
                vec4(397.96, -1647.01, 29.29, 318.1),
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
        motion = 'animated',                -- 'animated': follows a computed path, always straight on the bed;
                                            -- 'physics': the game's physics rolls it up. Unloading is always animated.
        pullSpeed = 1.0,                    -- Winch speed in m/s.
        pullTimeout = 40,                   -- Physics only: seconds before a winch run gives up.
        rope = true,                        -- Draw the winch cable for everyone nearby.
    },

    hook = {
        range = 7.0,                        -- Max distance from the tow arm to a vehicle to hook it.
    },

    sounds = {                              -- Game sounds, played from the truck for everyone nearby.
        enabled = true,                     -- false: silent. Set one line to false to mute only that sound.
        -- { sound name, soundset }. Listen to the alternatives in game with /swtow_sounds [event].
        rampsDown = { 'Enter_Car_Ramp_Deploy', 'DLC_GR_MOC_Enter_Exit_Sounds' },
        rampsUp = { 'RAMP_UP', 'TRUCK_RAMP_DOWN' },
        winch = { 'Move_U_D', 'CRANE_SOUNDS' },     -- Plays while the winch pulls or lets out.
        secured = { 'Clamp', 'CRANE_SOUNDS' },       -- Straps on, vehicle secured on the bed.
        hookOn = { 'Hook_Engage', 'DLC_IE_Steal_Cargobob_Sounds' },
        hookOff = { 'Hook_Detach', 'DLC_IE_Steal_Cargobob_Sounds' },
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
        spawnRadius = 150.0,                -- The vehicle appears once the worker is this close to the spot.
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
        collect = 'office',                 -- 'office': pay adds up during the shift and is paid when the worker ends it
                                            -- at the office (bring the truck back to get it); 'instant': after every delivery.
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
