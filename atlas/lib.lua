local atlas = {}

atlas.VERSION = 1
atlas.APP_VERSION = "1.3.0"
atlas.PROTOCOL_DISCOVERY = "atlas.discovery.v1"
atlas.PROTOCOL_LINK = "atlas.link.v1"
atlas.VOLUME_FORMAT = 1
atlas.VOLUME_META = "atlas/volume.dat"
atlas.VOLUME_INDEX = "atlas/index.dat"
atlas.TILE_ROOT = "atlas/tiles"

local function now()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

atlas.now = now

function atlas.tileKey(dimension, chunkX, chunkZ)
    return dimension .. "|" .. chunkX .. "|" .. chunkZ
end

function atlas.safeName(value)
    return tostring(value):gsub("[^%w_.-]", "_")
end

function atlas.regionCoordinate(chunk)
    return math.floor(chunk / 32)
end

function atlas.tileRelativePath(tile)
    local dimension = atlas.safeName(tile.dimension)
    local regionX = atlas.regionCoordinate(tile.chunkX)
    local regionZ = atlas.regionCoordinate(tile.chunkZ)
    local checksum = atlas.safeName(tile.checksum or "unknown")
    return fs.combine(
        atlas.TILE_ROOT,
        dimension,
        regionX .. "_" .. regionZ,
        tile.chunkX .. "_" .. tile.chunkZ .. "_" .. checksum .. ".tile")
end

function atlas.validateTile(tile)
    if type(tile) ~= "table" then return false, "tile is not a table" end
    if type(tile.dimension) ~= "string" or tile.dimension == "" then
        return false, "invalid dimension"
    end
    if type(tile.chunkX) ~= "number" or tile.chunkX % 1 ~= 0
        or type(tile.chunkZ) ~= "number" or tile.chunkZ % 1 ~= 0 then
        return false, "invalid chunk coordinates"
    end
    if type(tile.minY) ~= "number" or type(tile.maxY) ~= "number" then
        return false, "invalid height range"
    end
    if type(tile.surface) ~= "string" or #tile.surface ~= 512
        or type(tile.clearance) ~= "string" or #tile.clearance ~= 512
        or type(tile.fluid) ~= "string" or #tile.fluid ~= 512
        or type(tile.flags) ~= "string" or #tile.flags ~= 256 then
        return false, "invalid terrain payload"
    end
    if type(tile.checksum) ~= "string" or tile.checksum == "" then
        return false, "missing checksum"
    end
    return true
end

function atlas.serialise(value)
    return textutils.serialize(value, {
        compact = true,
        allow_repetitions = false
    })
end

function atlas.unserialise(value)
    if type(value) ~= "string" then return nil end
    return textutils.unserialize(value)
end

function atlas.readFile(path, binary)
    local handle = fs.open(path, binary and "rb" or "r")
    if not handle then return nil end
    local contents = handle.readAll()
    handle.close()
    return contents
end

function atlas.writeFile(path, contents, binary)
    fs.makeDir(fs.getDir(path))
    local handle, reason = fs.open(path, binary and "wb" or "w")
    if not handle then return false, reason or "cannot open file" end
    local ok, failure = pcall(handle.write, contents)
    local closeOk, closeFailure = pcall(handle.close)
    if not ok then return false, failure end
    if not closeOk then return false, closeFailure end
    return true
end

function atlas.writeAtomic(path, contents, binary)
    local suffix = ".tmp." .. os.getComputerID() .. "." .. now()
    local temporary = path .. suffix
    local ok, failure = atlas.writeFile(temporary, contents, binary)
    if not ok then return false, failure end

    local backup
    if fs.exists(path) then
        backup = path .. ".previous"
        if fs.exists(backup) then fs.delete(backup) end
        fs.move(path, backup)
    end

    local moveOk, moveFailure = pcall(fs.move, temporary, path)
    if not moveOk then
        if backup and fs.exists(backup) and not fs.exists(path) then
            pcall(fs.move, backup, path)
        end
        if fs.exists(temporary) then pcall(fs.delete, temporary) end
        return false, moveFailure
    end

    if backup and fs.exists(backup) then pcall(fs.delete, backup) end
    return true
end

function atlas.readTable(path)
    local contents = atlas.readFile(path, false)
    if not contents then return nil end
    return atlas.unserialise(contents)
end

function atlas.writeTable(path, value)
    return atlas.writeAtomic(path, atlas.serialise(value), false)
end

function atlas.encodeTile(tile)
    local valid, reason = atlas.validateTile(tile)
    if not valid then return nil, reason end
    return atlas.serialise({
        atlas = atlas.VERSION,
        version = tile.version or 1,
        dimension = tile.dimension,
        chunkX = tile.chunkX,
        chunkZ = tile.chunkZ,
        minY = tile.minY,
        maxY = tile.maxY,
        width = tile.width or 16,
        depth = tile.depth or 16,
        order = tile.order or "z_major",
        byteOrder = tile.byteOrder or "big_endian",
        surface = tile.surface,
        clearance = tile.clearance,
        fluid = tile.fluid,
        flags = tile.flags,
        checksum = tile.checksum,
        storedAt = tile.storedAt or now()
    })
end

function atlas.decodeTile(contents)
    local tile = atlas.unserialise(contents)
    local valid, reason = atlas.validateTile(tile)
    if not valid then return nil, reason end
    return tile
end

function atlas.loadTile(path)
    local contents = atlas.readFile(path, false)
    if not contents then return nil, "tile file is missing" end
    return atlas.decodeTile(contents)
end

function atlas.randomId(prefix)
    local randomPart = math.random(0, 0x7fffffff)
    return ("%s-%d-%d-%08x"):format(
        prefix or "id", os.getComputerID(), now(), randomPart)
end

function atlas.requestId()
    return atlas.randomId("req")
end

function atlas.formatBytes(bytes)
    if bytes == "unlimited" then return "UNLIMITED" end
    if type(bytes) ~= "number" then return "UNKNOWN" end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local unit = 1
    while bytes >= 1000 and unit < #units do
        bytes = bytes / 1000
        unit = unit + 1
    end
    if unit == 1 then return ("%d %s"):format(bytes, units[unit]) end
    return ("%.1f %s"):format(bytes, units[unit])
end

function atlas.capacity(path)
    local capacity
    local free
    local okCapacity, capacityOrError = pcall(fs.getCapacity, path)
    if okCapacity then capacity = capacityOrError end
    local okFree, freeOrError = pcall(fs.getFreeSpace, path)
    if okFree then free = freeOrError end
    local used
    if type(capacity) == "number" and type(free) == "number" then
        used = capacity - free
    end
    return {
        capacity = capacity,
        free = free,
        used = used
    }
end

function atlas.openWirelessRednet()
    local opened = {}
    peripheral.find("modem", function(name, modem)
        local ok, wireless = pcall(modem.isWireless)
        if ok and wireless then
            if not rednet.isOpen(name) then rednet.open(name) end
            opened[#opened + 1] = name
        end
        return false
    end)
    return opened
end

function atlas.discoverDrives()
    local drives = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "drive") then
            drives[#drives + 1] = {
                name = name,
                drive = peripheral.wrap(name)
            }
        end
    end
    table.sort(drives, function(a, b) return a.name < b.name end)
    return drives
end

function atlas.copyTile(tile)
    return {
        version = tile.version,
        dimension = tile.dimension,
        chunkX = tile.chunkX,
        chunkZ = tile.chunkZ,
        minY = tile.minY,
        maxY = tile.maxY,
        width = tile.width,
        depth = tile.depth,
        order = tile.order,
        byteOrder = tile.byteOrder,
        surface = tile.surface,
        clearance = tile.clearance,
        fluid = tile.fluid,
        flags = tile.flags,
        checksum = tile.checksum,
        storedAt = tile.storedAt
    }
end

function atlas.waitForRawEvent(name, identifier)
    while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then return nil, "terminate" end
        if event[1] == name
            and (identifier == nil or event[2] == identifier) then
            return table.unpack(event, 1, event.n)
        end
    end
end

function atlas.waitSeconds(seconds)
    return atlas.waitForRawEvent("timer", os.startTimer(seconds))
end

function atlas.send(recipient, operation, payload)
    payload = payload or {}
    payload.atlas = atlas.VERSION
    payload.op = operation
    return rednet.send(recipient, payload, atlas.PROTOCOL_LINK)
end

function atlas.reply(recipient, request, operation, payload)
    payload = payload or {}
    payload.requestId = request and request.requestId or payload.requestId
    return atlas.send(recipient, operation, payload)
end

return atlas
