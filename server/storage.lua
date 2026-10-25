---Database access. Tables are created on start, so installing needs no manual SQL step.
local storage = {}

local SCHEMA = {
    [[
    CREATE TABLE IF NOT EXISTS `sw_tow_impound` (
        `id`          INT AUTO_INCREMENT PRIMARY KEY,
        `yard`        VARCHAR(32)  NOT NULL,
        `plate`       VARCHAR(8)   NOT NULL,
        `vehicle_id`  INT          NULL,
        `owner`       VARCHAR(64)  NULL,
        `model`       VARCHAR(64)  NOT NULL,
        `reason`      VARCHAR(16)  NOT NULL,
        `note`        VARCHAR(255) NULL,
        `fine`        INT          NOT NULL DEFAULT 0,
        `tow_charge`  INT          NOT NULL DEFAULT 0,
        `police_hold` TINYINT(1)   NOT NULL DEFAULT 0,
        `hold_until`  DATETIME     NULL,
        `towed_by`    VARCHAR(64)  NULL,
        `stored_at`   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        `released_at` DATETIME     NULL,
        `released_by` VARCHAR(64)  NULL,
        `paid`        INT          NULL,
        INDEX `idx_active` (`vehicle_id`, `released_at`),
        INDEX `idx_owner` (`owner`, `released_at`)
    )
    ]],
    [[
    CREATE TABLE IF NOT EXISTS `sw_tow_log` (
        `id`         INT AUTO_INCREMENT PRIMARY KEY,
        `citizenid`  VARCHAR(64) NOT NULL,
        `call_type`  VARCHAR(16) NOT NULL,
        `payout`     INT         NOT NULL,
        `distance_m` INT         NOT NULL,
        `created_at` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX `idx_citizen` (`citizenid`, `created_at`)
    )
    ]],
}

function storage.migrate()
    for i = 1, #SCHEMA do
        MySQL.query.await(SCHEMA[i])
    end
end

---@class SwImpoundRecord
---@field id integer
---@field yard string
---@field plate string
---@field vehicle_id integer?
---@field owner string?
---@field model string
---@field reason string
---@field note string?
---@field fine integer
---@field tow_charge integer what the worker was paid; the owner pays it back on release
---@field police_hold integer
---@field hold_until integer? unix seconds
---@field stored_at integer unix seconds

local COLUMNS = [[id, yard, plate, vehicle_id, owner, model, reason, note, fine, tow_charge, police_hold,
    UNIX_TIMESTAMP(hold_until) AS hold_until, UNIX_TIMESTAMP(stored_at) AS stored_at]]

---@param record table
---@return integer id
function storage.insertImpound(record)
    return MySQL.insert.await([[
        INSERT INTO sw_tow_impound (yard, plate, vehicle_id, owner, model, reason, note, fine, tow_charge, police_hold, towed_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        record.yard, record.plate, record.vehicle_id, record.owner, record.model, record.reason,
        record.note, record.fine or 0, record.tow_charge or 0, record.police_hold and 1 or 0, record.towed_by,
    })
end

---@return SwImpoundRecord[]
function storage.allActive()
    return MySQL.query.await(('SELECT %s FROM sw_tow_impound WHERE released_at IS NULL'):format(COLUMNS)) or {}
end

---@param id integer
---@return SwImpoundRecord?
function storage.getActive(id)
    return MySQL.single.await(('SELECT %s FROM sw_tow_impound WHERE id = ? AND released_at IS NULL'):format(COLUMNS), { id })
end

---@param owner string
---@param yard string
---@return SwImpoundRecord[]
function storage.activeForOwner(owner, yard)
    return MySQL.query.await(
        ('SELECT %s FROM sw_tow_impound WHERE owner = ? AND yard = ? AND released_at IS NULL ORDER BY stored_at'):format(COLUMNS),
        { owner, yard }
    ) or {}
end

---Marks a record released. Returns false when another request released it first.
---@param id integer
---@param releasedBy string
---@param paid integer
---@return boolean
function storage.markReleased(id, releasedBy, paid)
    local changed = MySQL.update.await(
        'UPDATE sw_tow_impound SET released_at = NOW(), released_by = ?, paid = ? WHERE id = ? AND released_at IS NULL',
        { releasedBy, paid, id }
    )
    return (changed or 0) > 0
end

---@param citizenid string
---@param callType string
---@param payout integer
---@param distance number
function storage.logDelivery(citizenid, callType, payout, distance)
    MySQL.insert('INSERT INTO sw_tow_log (citizenid, call_type, payout, distance_m) VALUES (?, ?, ?, ?)', {
        citizenid, callType, payout, math.floor(distance),
    })
end

return storage
