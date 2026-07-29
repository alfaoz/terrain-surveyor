-- ATLAS Navigator for:
--   Terrain Surveyor 0.1.3
--   CC: Tweaked 1.120.0
--   CC: Graphics 0.2.0
--
-- The map is north-up: +X is right and +Z is down.

local LIBRARY = fs.exists("/atlas/lib.lua") and "/atlas/lib.lua" or "atlas/lib.lua"
local atlas = dofile(LIBRARY)

-- One Minecraft tick: 20 visual/position updates per second (4x the original).
local UPDATE_SECONDS = 0.05
local TILE_REFRESH_MS = 120000
local RETRY_MS = 1500
local NETWORK_TICK_SECONDS = 0.20
local HEARTBEAT_MS = 1000
local TRAFFIC_MS = 1000
local NETWORK_TIMEOUT_MS = 3000
local NETWORK_MISS_MS = 30000
local CACHE_META_PATH = "/atlas/cache/index.dat"
local CACHE_TILE_ROOT = "/atlas/cache/tiles"
local NAV_CONFIG_PATH = "/atlas/navigator.cfg"
local ROUTE_PATH = "/atlas/route.dat"
local MAP_BUILD_ROWS_PER_YIELD = 12
local MAP_BUILD_EVENT = "terrain_map_build"
local MAP_BUILD_STEP_EVENT = "terrain_map_build_step"
local HEADER_HEIGHT = 15
local FOOTER_HEIGHT = 22
local CONTOUR_INTERVAL = 10
local ZOOM_LEVELS = { 0.25, 0.5, 1, 2, 4, 8 }
local INITIAL_ZOOM = 4
local running = true

local COLOR = {
    background = 0,
    unknown = 1,
    water = 2,
    lava = 3,
    otherFluid = 4,
    obstacle = 5,
    contour = 6,
    grid = 7,
    panel = 8,
    panelEdge = 9,
    text = 10,
    textDim = 11,
    aircraft = 12,
    aircraftEdge = 13,
    warning = 14,
    route = 15,
    waypoint = 16,
    traffic = 17,
    terrainFirst = 32
}

local FONT = {
    ["A"] = { 2, 5, 7, 5, 5 }, ["B"] = { 6, 5, 6, 5, 6 },
    ["C"] = { 3, 4, 4, 4, 3 }, ["D"] = { 6, 5, 5, 5, 6 },
    ["E"] = { 7, 4, 6, 4, 7 }, ["F"] = { 7, 4, 6, 4, 4 },
    ["G"] = { 3, 4, 5, 5, 3 }, ["H"] = { 5, 5, 7, 5, 5 },
    ["I"] = { 7, 2, 2, 2, 7 }, ["J"] = { 1, 1, 1, 5, 2 },
    ["K"] = { 5, 5, 6, 5, 5 }, ["L"] = { 4, 4, 4, 4, 7 },
    ["M"] = { 5, 7, 7, 5, 5 }, ["N"] = { 5, 7, 7, 7, 5 },
    ["O"] = { 2, 5, 5, 5, 2 }, ["P"] = { 6, 5, 6, 4, 4 },
    ["Q"] = { 2, 5, 5, 3, 1 }, ["R"] = { 6, 5, 6, 5, 5 },
    ["S"] = { 3, 4, 2, 1, 6 }, ["T"] = { 7, 2, 2, 2, 2 },
    ["U"] = { 5, 5, 5, 5, 7 }, ["V"] = { 5, 5, 5, 5, 2 },
    ["W"] = { 5, 5, 7, 7, 5 }, ["X"] = { 5, 5, 2, 5, 5 },
    ["Y"] = { 5, 5, 2, 2, 2 }, ["Z"] = { 7, 1, 2, 4, 7 },
    ["0"] = { 7, 5, 5, 5, 7 }, ["1"] = { 2, 6, 2, 2, 7 },
    ["2"] = { 6, 1, 2, 4, 7 }, ["3"] = { 6, 1, 2, 1, 6 },
    ["4"] = { 5, 5, 7, 1, 1 }, ["5"] = { 7, 4, 6, 1, 6 },
    ["6"] = { 3, 4, 6, 5, 2 }, ["7"] = { 7, 1, 2, 2, 2 },
    ["8"] = { 2, 5, 2, 5, 2 }, ["9"] = { 2, 5, 3, 1, 6 },
    ["-"] = { 0, 0, 7, 0, 0 }, ["+"] = { 0, 2, 7, 2, 0 },
    ["."] = { 0, 0, 0, 0, 2 }, [":"] = { 0, 2, 0, 2, 0 },
    ["/"] = { 1, 1, 2, 4, 4 }, ["?"] = { 6, 1, 2, 0, 2 },
    ["="] = { 0, 7, 0, 7, 0 }, ["_"] = { 0, 0, 0, 0, 7 },
    [" "] = { 0, 0, 0, 0, 0 }
}

local BYTE = {}
for index = 0, 255 do BYTE[index] = string.char(index) end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function lerp(a, b, amount)
    return a + (b - a) * amount
end

local function mixColor(a, b, amount)
    return {
        lerp(a[1], b[1], amount),
        lerp(a[2], b[2], amount),
        lerp(a[3], b[3], amount)
    }
end

local function setPalette(index, rgb)
    term.setPaletteColor(index, rgb[1] / 255, rgb[2] / 255, rgb[3] / 255)
end

local function configurePalette()
    setPalette(COLOR.background, { 14, 18, 20 })
    setPalette(COLOR.unknown, { 25, 31, 33 })
    setPalette(COLOR.water, { 78, 126, 145 })
    setPalette(COLOR.lava, { 210, 83, 43 })
    setPalette(COLOR.otherFluid, { 121, 87, 142 })
    setPalette(COLOR.obstacle, { 191, 133, 81 })
    setPalette(COLOR.contour, { 53, 57, 49 })
    setPalette(COLOR.grid, { 83, 91, 86 })
    setPalette(COLOR.panel, { 20, 25, 27 })
    setPalette(COLOR.panelEdge, { 59, 69, 70 })
    setPalette(COLOR.text, { 223, 226, 218 })
    setPalette(COLOR.textDim, { 139, 151, 146 })
    setPalette(COLOR.aircraft, { 244, 231, 169 })
    setPalette(COLOR.aircraftEdge, { 52, 46, 35 })
    setPalette(COLOR.warning, { 224, 95, 75 })
    setPalette(COLOR.route, { 224, 181, 92 })
    setPalette(COLOR.waypoint, { 238, 221, 159 })
    setPalette(COLOR.traffic, { 105, 183, 184 })

    local low = { 68, 103, 77 }
    local middle = { 132, 135, 99 }
    local high = { 176, 171, 151 }
    local shade = { 0.70, 0.86, 1.00, 1.13 }

    for band = 0, 15 do
        local amount = band / 15
        local base
        if amount < 0.55 then
            base = mixColor(low, middle, amount / 0.55)
        else
            base = mixColor(middle, high, (amount - 0.55) / 0.45)
        end

        for shadeIndex = 0, 3 do
            local factor = shade[shadeIndex + 1]
            setPalette(COLOR.terrainFirst + band * 4 + shadeIndex, {
                clamp(base[1] * factor, 0, 255),
                clamp(base[2] * factor, 0, 255),
                clamp(base[3] * factor, 0, 255)
            })
        end
    end
end

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function waitForRawEvent(name, identifier)
    while running do
        local event, value = os.pullEventRaw()
        if event == "terminate" then
            running = false
            return false
        end
        if event == name and (identifier == nil or value == identifier) then
            return true
        end
    end
    return false
end

local function waitSeconds(seconds)
    return waitForRawEvent("timer", os.startTimer(seconds))
end

local function tileKey(dimension, chunkX, chunkZ)
    return atlas.tileKey(dimension, chunkX, chunkZ)
end

local function decodeHeights(data, minY)
    local decoded = {}
    for sample = 0, 255 do
        local byteIndex = sample * 2 + 1
        local high, low = data:byte(byteIndex, byteIndex + 1)
        local encoded = high * 256 + low
        decoded[sample + 1] = encoded == 0xffff and false or minY + encoded
    end
    return decoded
end

local function decodeTile(raw)
    local valid, reason = atlas.validateTile(raw)
    if not valid then error("Invalid ATLAS terrain tile: " .. reason, 0) end

    local flags = {}
    for sample = 1, 256 do flags[sample] = raw.flags:byte(sample) end

    return {
        dimension = raw.dimension,
        chunkX = raw.chunkX,
        chunkZ = raw.chunkZ,
        minY = raw.minY,
        maxY = raw.maxY,
        surface = decodeHeights(raw.surface, raw.minY),
        clearance = decodeHeights(raw.clearance, raw.minY),
        fluid = decodeHeights(raw.fluid, raw.minY),
        flags = flags,
        checksum = raw.checksum,
        scannedAt = nowMs(),
        raw = atlas.copyTile(raw)
    }
end

local function findSurveyor()
    local surveyor = peripheral.find("terrain_surveyor")
    if not surveyor then error("No Terrain Surveyor is attached", 0) end
    return surveyor
end

local navConfig = atlas.readTable(NAV_CONFIG_PATH) or {}
navConfig.callsign = navConfig.callsign or ("AC-" .. os.getComputerID())
navConfig.writeKey = navConfig.writeKey or ""
navConfig.lastServer = navConfig.lastServer or ""
navConfig.headingOffset = tonumber(navConfig.headingOffset) or 0

local routeData = atlas.readTable(ROUTE_PATH) or {}
local waypoints = type(routeData.waypoints) == "table"
    and routeData.waypoints or {}
local activeWaypoint = math.max(1, tonumber(routeData.active) or 1)

local cacheIndex = atlas.readTable(CACHE_META_PATH) or {}
cacheIndex.tiles = type(cacheIndex.tiles) == "table" and cacheIndex.tiles or {}

local surveyor = findSurveyor()
local tiles = {}
local retryAfter = {}
local tileCount = 0
local scanOffsets = {}
local scanRadius
local scanStatus = "STARTING"
local info
local viewX
local viewZ
local follow = true
local showGrid = true
local showContours = true
local showObstacles = true
local zoomIndex = 1
local renderStyleVersion = 1
local terrainRevision = 0
local mapCache = {
    signature = nil,
    rows = nil
}
local mapBuildRequest
local blankRowsCache = {}
local serverId
local serverInfo
local linkStatus = "OFFLINE"
local lastServerSeen = 0
local pendingNetwork = {}
local pendingKeys = {}
local uploadQueue = {}
local downloadQueue = {}
local networkMissUntil = {}
local traffic = {}
local motion = {
    speed = 0,
    track = 0,
    heading = 0,
    rawHeading = nil,
    headingSource = "TRACK"
}
local previousPosition
local scanPlanSignature
local modal = false
local lastDisplayMap

local function saveRoute()
    activeWaypoint = math.max(1, math.min(
        activeWaypoint, math.max(1, #waypoints)))
    atlas.writeTable(ROUTE_PATH, {
        waypoints = waypoints,
        active = activeWaypoint
    })
end

local function nextWaypoint()
    return waypoints[activeWaypoint]
end

local function bearingBetween(x1, z1, x2, z2)
    local radians
    if math.atan2 then
        radians = math.atan2(x2 - x1, -(z2 - z1))
    else
        radians = math.atan(x2 - x1, -(z2 - z1))
    end
    return (math.deg(radians) + 360) % 360
end

local function distanceBetween(x1, z1, x2, z2)
    local dx = x2 - x1
    local dz = z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

local function quaternionHeading(orientation)
    if type(orientation) ~= "table" then return nil end

    -- CC:Sable normally returns an Advanced Math quaternion ({ v, a }).
    -- Native pose tables use the equivalent { x, y, z, w } layout.
    local vectorPart = orientation.v
    local x = tonumber(orientation.x)
        or (type(vectorPart) == "table" and tonumber(vectorPart.x))
    local y = tonumber(orientation.y)
        or (type(vectorPart) == "table" and tonumber(vectorPart.y))
    local z = tonumber(orientation.z)
        or (type(vectorPart) == "table" and tonumber(vectorPart.z))
    local w = tonumber(orientation.w) or tonumber(orientation.a)
    if not (x and y and z and w) then return nil end

    local lengthSquared = x * x + y * y + z * z + w * w
    if lengthSquared < 0.000001 then return nil end
    local inverseLength = 1 / math.sqrt(lengthSquared)
    x, y, z, w = x * inverseLength, y * inverseLength,
        z * inverseLength, w * inverseLength

    -- Rotate local -Z (the default craft nose) into world space.
    local forwardX = -2 * (x * z + y * w)
    local forwardZ = -(1 - 2 * (x * x + y * y))
    if forwardX * forwardX + forwardZ * forwardZ < 0.000001 then
        return nil
    end
    return bearingBetween(0, 0, forwardX, forwardZ)
end

local function refreshSableMotion()
    if type(sublevel) ~= "table" then return false end

    local velocityOk, velocity = pcall(sublevel.getVelocity)
    if velocityOk and type(velocity) == "table" then
        local velocityX = tonumber(velocity.x)
        local velocityZ = tonumber(velocity.z)
        if velocityX and velocityZ then
            local horizontalSpeed = math.sqrt(
                velocityX * velocityX + velocityZ * velocityZ)
            motion.speed = horizontalSpeed
            if horizontalSpeed > 0.01 then
                motion.track = bearingBetween(0, 0, velocityX, velocityZ)
            end
        end
    end

    local poseOk, pose = pcall(sublevel.getLogicalPose)
    local rawHeading = poseOk and type(pose) == "table"
        and quaternionHeading(pose.orientation) or nil
    if not rawHeading then return false end

    motion.rawHeading = rawHeading
    motion.heading = (rawHeading + navConfig.headingOffset) % 360
    motion.headingSource = "SABLE"
    return true
end

local function calibrateHeading()
    if not motion.rawHeading then
        scanStatus = "NO SABLE HEADING"
        return
    end
    if motion.speed < 0.5 then
        scanStatus = "FLY STRAIGHT TO CALIBRATE"
        return
    end

    navConfig.headingOffset = (
        motion.track - motion.rawHeading + 540) % 360 - 180
    motion.heading = (motion.rawHeading + navConfig.headingOffset) % 360
    atlas.writeTable(NAV_CONFIG_PATH, navConfig)
    scanStatus = ("HEADING CAL %+.1f"):format(navConfig.headingOffset)
end

local function localCachePath(dimension, chunkX, chunkZ)
    local regionX = math.floor(chunkX / 32)
    local regionZ = math.floor(chunkZ / 32)
    return fs.combine(
        CACHE_TILE_ROOT,
        atlas.safeName(dimension),
        regionX .. "_" .. regionZ,
        chunkX .. "_" .. chunkZ .. ".tile")
end

local cacheDirty = false

local function saveLocalRaw(raw, unsynced)
    local encoded, reason = atlas.encodeTile(raw)
    if not encoded then return false, reason end
    local path = localCachePath(raw.dimension, raw.chunkX, raw.chunkZ)
    local ok, failure = atlas.writeAtomic(path, encoded, false)
    if not ok then return false, failure end

    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    local previous = cacheIndex.tiles[key]
    cacheIndex.tiles[key] = {
        path = path,
        checksum = raw.checksum,
        lastUsed = nowMs(),
        unsynced = unsynced
            or (previous and previous.unsynced)
            or false,
        size = #encoded
    }
    cacheDirty = true
    return true
end

local function loadLocalRaw(dimension, chunkX, chunkZ)
    local key = tileKey(dimension, chunkX, chunkZ)
    local entry = cacheIndex.tiles[key]
    local path = entry and entry.path
        or localCachePath(dimension, chunkX, chunkZ)
    if not fs.exists(path) then return nil end
    local raw = atlas.loadTile(path)
    if not raw then return nil end
    cacheIndex.tiles[key] = entry or {
        path = path,
        checksum = raw.checksum,
        unsynced = false,
        size = fs.getSize(path)
    }
    cacheIndex.tiles[key].lastUsed = nowMs()
    cacheDirty = true
    return raw
end

local function queueUpload(raw)
    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    uploadQueue[key] = atlas.copyTile(raw)
end

local function markSynced(raw)
    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    local entry = cacheIndex.tiles[key]
    if entry and entry.checksum == raw.checksum then
        entry.unsynced = false
        cacheDirty = true
    end
    uploadQueue[key] = nil
end

local function queueDownload(dimension, chunkX, chunkZ, priority)
    if not serverId then return end
    local key = tileKey(dimension, chunkX, chunkZ)
    if tiles[key] or pendingKeys[key]
        or nowMs() < (networkMissUntil[key] or 0) then return end
    local cached = cacheIndex.tiles[key]
    if cached and fs.exists(cached.path) then return end
    local existing = downloadQueue[key]
    if not existing or priority < existing.priority then
        downloadQueue[key] = {
            dimension = dimension,
            chunkX = chunkX,
            chunkZ = chunkZ,
            priority = priority
        }
    end
end

local function discoverStations()
    local found = {}
    local ids = { rednet.lookup(atlas.PROTOCOL_DISCOVERY, nil, 1) }
    local requests = {}
    for _, id in ipairs(ids) do
        local requestId = atlas.requestId()
        requests[requestId] = id
        atlas.send(id, "station_info", { requestId = requestId })
    end

    local timer = os.startTimer(1)
    while next(requests) do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            break
        elseif event[1] == "timer" and event[2] == timer then
            break
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_LINK
            and type(event[3]) == "table"
            and event[3].op == "station_info"
            and requests[event[3].requestId] then
            event[3].id = event[2]
            found[#found + 1] = event[3]
            requests[event[3].requestId] = nil
        end
    end
    table.sort(found, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return found
end

local function fitTerminal(text, width)
    text = tostring(text)
    if #text <= width then return text end
    return text:sub(1, math.max(0, width - 1)) .. "~"
end

local function chooseStation(hasWireless)
    if not hasWireless then return nil, nil end
    local stations = discoverStations()
    local selected = #stations > 0 and 1 or 0
    for index, station in ipairs(stations) do
        if station.name == navConfig.lastServer then selected = index end
    end

    while running do
        local width, height = term.getSize()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(2, 2)
        term.setTextColor(colors.lightBlue)
        term.write("ATLAS NAVIGATOR")
        term.setCursorPos(2, 4)
        term.setTextColor(colors.lightGray)
        term.write("SELECT A MAP NETWORK")

        local firstY = 6
        if #stations == 0 then
            term.setCursorPos(2, firstY)
            term.setTextColor(colors.gray)
            term.write("NO ATLAS STATIONS FOUND")
        else
            for index, station in ipairs(stations) do
                local y = firstY + index - 1
                if y >= height - 3 then break end
                term.setCursorPos(2, y)
                local active = index == selected
                term.setBackgroundColor(active and colors.lightBlue or colors.black)
                term.setTextColor(active and colors.black or colors.white)
                local status = ("%s  %d VOL  %d TILES"):format(
                    station.name or ("STATION " .. station.id),
                    station.volumes or 0, station.tiles or 0)
                term.write(fitTerminal(status, width - 3))
                term.setBackgroundColor(colors.black)
            end
        end

        term.setCursorPos(2, height - 1)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" CONNECT ")
        term.setCursorPos(14, height - 1)
        term.write(" RESCAN ")
        term.setCursorPos(25, height - 1)
        term.write(" OFFLINE ")
        term.setBackgroundColor(colors.black)

        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            return nil, nil
        elseif event[1] == "key" then
            if event[2] == keys.up then
                selected = math.max(1, selected - 1)
            elseif event[2] == keys.down then
                selected = math.min(#stations, selected + 1)
            elseif event[2] == keys.enter and stations[selected] then
                local station = stations[selected]
                navConfig.lastServer = station.name or ""
                atlas.writeTable(NAV_CONFIG_PATH, navConfig)
                return station.id, station
            end
        elseif event[1] == "mouse_click" then
            local _, _, x, y = table.unpack(event, 1, event.n)
            local row = y - firstY + 1
            if row >= 1 and row <= #stations then
                selected = row
            elseif y == height - 1 and x >= 2 and x <= 10
                and stations[selected] then
                local station = stations[selected]
                navConfig.lastServer = station.name or ""
                atlas.writeTable(NAV_CONFIG_PATH, navConfig)
                return station.id, station
            elseif y == height - 1 and x >= 14 and x <= 21 then
                stations = discoverStations()
                selected = #stations > 0 and 1 or 0
            elseif y == height - 1 and x >= 25 and x <= 33 then
                return nil, nil
            end
        elseif event[1] == "char" then
            local character = event[2]:lower()
            if character == "r" then
                stations = discoverStations()
                selected = #stations > 0 and 1 or 0
            elseif character == "o" then
                return nil, nil
            end
        end
    end
end

for index, zoom in ipairs(ZOOM_LEVELS) do
    if zoom == INITIAL_ZOOM then zoomIndex = index end
end

local function zoom()
    return ZOOM_LEVELS[zoomIndex]
end

local function getSample(worldX, worldZ, dimension)
    local chunkX = math.floor(worldX / 16)
    local chunkZ = math.floor(worldZ / 16)
    local tile = tiles[tileKey(dimension, chunkX, chunkZ)]
    if not tile then return nil end

    local localX = worldX - chunkX * 16
    local localZ = worldZ - chunkZ * 16
    local sample = localZ * 16 + localX + 1
    return tile.surface[sample], tile.clearance[sample],
        tile.fluid[sample], tile.flags[sample]
end

local function invalidateTileDependencies(dimension, chunkX, chunkZ)
    local affected = {
        { chunkX, chunkZ },
        { chunkX - 1, chunkZ },
        { chunkX, chunkZ - 1 }
    }
    for _, coordinates in ipairs(affected) do
        local tile = tiles[tileKey(dimension, coordinates[1], coordinates[2])]
        if tile then
            tile.renderPixels = nil
            tile.renderStyleVersion = nil
        end
    end
    terrainRevision = terrainRevision + 1
    mapCache.signature = nil
end

local function invalidateRenderStyle()
    renderStyleVersion = renderStyleVersion + 1
    mapCache.signature = nil
end

local function installRawTile(raw, source)
    local decoded = decodeTile(raw)
    local key = tileKey(decoded.dimension, decoded.chunkX, decoded.chunkZ)
    local previous = tiles[key]
    local cached = cacheIndex.tiles[key]
    if source == "network" and cached and cached.unsynced
        and cached.checksum ~= decoded.checksum then
        return previous
    end
    tiles[key] = decoded
    retryAfter[key] = nil
    if not previous then tileCount = tileCount + 1 end
    invalidateTileDependencies(decoded.dimension, decoded.chunkX, decoded.chunkZ)

    if source == "survey" then
        saveLocalRaw(raw, true)
        queueUpload(raw)
    elseif source == "network" then
        saveLocalRaw(raw, false)
    end
    return decoded
end

local function scanDirection()
    local waypoint = nextWaypoint()
    if info and waypoint then
        local dx = waypoint.x - info.x
        local dz = waypoint.z - info.z
        local length = math.sqrt(dx * dx + dz * dz)
        if length > 0.001 then return dx / length, dz / length end
    end
    local radians = math.rad(motion.track or 0)
    return math.sin(radians), -math.cos(radians)
end

local function rebuildScanPlan(infoValue)
    local directionX, directionZ = scanDirection()
    local radius = infoValue.maxChunkRadius
    local waypoint = nextWaypoint()
    local waypointChunkX = waypoint and math.floor(waypoint.x / 16)
    local waypointChunkZ = waypoint and math.floor(waypoint.z / 16)
    local offsets = {}

    for dz = -radius, radius do
        for dx = -radius, radius do
            local distanceSquared = dx * dx + dz * dz
            if distanceSquared <= radius * radius then
                local distance = math.sqrt(distanceSquared)
                local score = distance * 100
                if distance <= 2.25 then score = score - 10000 end

                if distance > 0 then
                    local forward = dx * directionX + dz * directionZ
                    local cross = math.abs(dx * directionZ - dz * directionX)
                    local coneWidth = 1.5 + math.max(0, forward) * 0.55
                    if forward > 0 and cross <= coneWidth then
                        score = score - 6000 - forward * 120
                    end
                end

                if waypointChunkX then
                    local targetDx = infoValue.chunkX + dx - waypointChunkX
                    local targetDz = infoValue.chunkZ + dz - waypointChunkZ
                    if targetDx * targetDx + targetDz * targetDz <= 4 then
                        score = score - 8000
                    end
                end

                offsets[#offsets + 1] = {
                    dx = dx,
                    dz = dz,
                    distance = distanceSquared,
                    score = score
                }
            end
        end
    end
    table.sort(offsets, function(a, b)
        if a.score == b.score then return a.distance < b.distance end
        return a.score < b.score
    end)
    scanOffsets = offsets
end

local function chooseScan(infoValue)
    local waypoint = nextWaypoint()
    local direction = math.floor((motion.track or 0) / 15)
    local signature = table.concat({
        infoValue.chunkX,
        infoValue.chunkZ,
        infoValue.maxChunkRadius,
        direction,
        activeWaypoint,
        waypoint and math.floor(waypoint.x / 16) or "",
        waypoint and math.floor(waypoint.z / 16) or ""
    }, ":")
    if scanRadius ~= infoValue.maxChunkRadius
        or scanPlanSignature ~= signature then
        scanRadius = infoValue.maxChunkRadius
        scanPlanSignature = signature
        rebuildScanPlan(infoValue)
    end

    local currentTime = nowMs()
    local staleChoice
    local staleAge = -1

    for _, offset in ipairs(scanOffsets) do
        local chunkX = infoValue.chunkX + offset.dx
        local chunkZ = infoValue.chunkZ + offset.dz
        local key = tileKey(infoValue.dimension, chunkX, chunkZ)
        local tile = tiles[key]
        local retryTime = retryAfter[key] or 0

        if not tile then
            local cached = loadLocalRaw(
                infoValue.dimension, chunkX, chunkZ)
            if cached then
                tile = installRawTile(cached, "disk")
            end
        end

        if not tile and currentTime >= retryTime then
            return offset, key
        end

        if tile then
            local age = currentTime - tile.scannedAt
            if age >= TILE_REFRESH_MS and age > staleAge then
                staleChoice = { offset = offset, key = key }
                staleAge = age
            end
        end
    end

    if staleChoice then return staleChoice.offset, staleChoice.key end
end

local function scanOne(infoValue)
    if infoValue.ready == false then
        scanStatus = "SCANNER BUSY"
        return false
    end

    local offset, key = chooseScan(infoValue)
    if not offset then
        scanStatus = "CURRENT"
        return false
    end

    scanStatus = ("SCAN %d %d"):format(offset.dx, offset.dz)
    local ok, rawOrError = pcall(surveyor.scanChunk, offset.dx, offset.dz)
    if not ok then
        retryAfter[key] = nowMs() + RETRY_MS
        scanStatus = "WAITING"
        return false
    end

    installRawTile(rawOrError, "survey")
    scanStatus = "RECEIVED"
    return true
end

local function tileSampleColor(tile, eastTile, southTile, localX, localZ)
    local sample = localZ * 16 + localX + 1
    local surface = tile.surface[sample]
    local clearance = tile.clearance[sample]
    local fluid = tile.fluid[sample]
    local flags = tile.flags[sample]
    if not surface and not clearance then return COLOR.unknown end
    if not surface then return COLOR.obstacle end

    local fluidKind = flags % 4
    if fluid and fluid >= surface then
        if fluidKind == 1 then return COLOR.water end
        if fluidKind == 2 then return COLOR.lava end
        if fluidKind == 3 then return COLOR.otherFluid end
    end

    local band = clamp(math.floor((surface - 48) / 8), 0, 15)
    local east
    if localX < 15 then
        east = tile.surface[sample + 1]
    elseif eastTile then
        east = eastTile.surface[localZ * 16 + 1]
    end
    local south
    if localZ < 15 then
        south = tile.surface[sample + 16]
    elseif southTile then
        south = southTile.surface[localX + 1]
    end

    local eastForShade = east or surface
    local southForShade = south or surface
    local slope = (eastForShade - surface) + (southForShade - surface)
    local shade
    if slope >= 4 then
        shade = 0
    elseif slope >= 1 then
        shade = 1
    elseif slope <= -4 then
        shade = 3
    else
        shade = 2
    end
    local color = COLOR.terrainFirst + band * 4 + shade

    if showContours then
        local contour = math.floor(surface / CONTOUR_INTERVAL)
        if (east and math.floor(east / CONTOUR_INTERVAL) ~= contour)
            or (south and math.floor(south / CONTOUR_INTERVAL) ~= contour) then
            color = COLOR.contour
        end
    end

    if showObstacles and clearance and clearance > surface
        and (tile.chunkX * 16 + localX + tile.chunkZ * 16 + localZ) % 3 == 0 then
        color = COLOR.obstacle
    end

    if showGrid and zoom() >= 1
        and (localX == 0 or localZ == 0) then
        color = COLOR.grid
    end

    return color
end

local function renderedPixelsFor(tile)
    if tile.renderPixels and tile.renderStyleVersion == renderStyleVersion then
        return tile.renderPixels
    end

    local eastTile = tiles[tileKey(tile.dimension, tile.chunkX + 1, tile.chunkZ)]
    local southTile = tiles[tileKey(tile.dimension, tile.chunkX, tile.chunkZ + 1)]
    local pixels = {}
    for localZ = 0, 15 do
        for localX = 0, 15 do
            local sample = localZ * 16 + localX + 1
            pixels[sample] = BYTE[tileSampleColor(
                tile, eastTile, southTile, localX, localZ)]
        end
    end

    tile.renderPixels = table.concat(pixels)
    tile.renderStyleVersion = renderStyleVersion
    return tile.renderPixels
end

local function drawPixel(x, y, color, width, height)
    if x >= 0 and x < width and y >= 0 and y < height then
        term.setPixel(x, y, color)
    end
end

local function drawText(x, y, text, color, width, height)
    text = tostring(text):upper()
    for characterIndex = 1, #text do
        local glyph = FONT[text:sub(characterIndex, characterIndex)] or FONT["?"]
        local glyphX = x + (characterIndex - 1) * 4
        for row = 0, 4 do
            local bits = glyph[row + 1]
            for column = 0, 2 do
                if math.floor(bits / (2 ^ (2 - column))) % 2 == 1 then
                    drawPixel(glyphX + column, y + row, color, width, height)
                end
            end
        end
    end
end

local function fitText(text, width)
    local maximum = math.max(0, math.floor((width - 4) / 4))
    if #text <= maximum then return text end
    return text:sub(1, math.max(0, maximum - 1)) .. "?"
end

local function drawAircraft(screenX, screenY, width, height, warning)
    local edge = COLOR.aircraftEdge
    local center = warning and COLOR.warning or COLOR.aircraft
    for offset = -3, 3 do
        drawPixel(screenX + offset, screenY, edge, width, height)
        drawPixel(screenX, screenY + offset, edge, width, height)
    end
    drawPixel(screenX - 1, screenY, center, width, height)
    drawPixel(screenX + 1, screenY, center, width, height)
    drawPixel(screenX, screenY - 1, center, width, height)
    drawPixel(screenX, screenY + 1, center, width, height)
    drawPixel(screenX, screenY, center, width, height)
end

local function drawLine(x0, y0, x1, y1, color, width, height)
    x0, y0 = math.floor(x0 + 0.5), math.floor(y0 + 0.5)
    x1, y1 = math.floor(x1 + 0.5), math.floor(y1 + 0.5)
    local dx = math.abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math.abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local failure = dx + dy
    while true do
        drawPixel(x0, y0, color, width, height)
        if x0 == x1 and y0 == y1 then break end
        local doubled = 2 * failure
        if doubled >= dy then
            failure = failure + dy
            x0 = x0 + sx
        end
        if doubled <= dx then
            failure = failure + dx
            y0 = y0 + sy
        end
    end
end

local function worldToScreen(
        worldX, worldZ, mapViewX, mapViewZ,
        pixelsPerBlock, centerX, centerY, mapTop)
    return centerX + (worldX - mapViewX) * pixelsPerBlock,
        mapTop + centerY + (worldZ - mapViewZ) * pixelsPerBlock
end

local function drawNavigationOverlay(
        width, height, mapTop, mapHeight, pixelsPerBlock,
        mapViewX, mapViewZ, centerX, centerY)
    local previousX = info.x
    local previousZ = info.z
    for index = activeWaypoint, #waypoints do
        local waypoint = waypoints[index]
        local fromX, fromY = worldToScreen(
            previousX, previousZ, mapViewX, mapViewZ,
            pixelsPerBlock, centerX, centerY, mapTop)
        local toX, toY = worldToScreen(
            waypoint.x, waypoint.z, mapViewX, mapViewZ,
            pixelsPerBlock, centerX, centerY, mapTop)
        drawLine(fromX, fromY, toX, toY, COLOR.route, width, height)
        for offset = -2, 2 do
            drawPixel(math.floor(toX + 0.5) + offset,
                math.floor(toY + 0.5), COLOR.waypoint, width, height)
            drawPixel(math.floor(toX + 0.5),
                math.floor(toY + 0.5) + offset, COLOR.waypoint, width, height)
        end
        drawText(math.floor(toX + 4), math.floor(toY - 2),
            tostring(index), COLOR.waypoint, width, height)
        previousX, previousZ = waypoint.x, waypoint.z
    end

    for id, contact in pairs(traffic) do
        if id ~= os.getComputerID()
            and contact.dimension == info.dimension
            and (contact.age or 0) < 15000 then
            local x, y = worldToScreen(
                contact.x, contact.z, mapViewX, mapViewZ,
                pixelsPerBlock, centerX, centerY, mapTop)
            x, y = math.floor(x + 0.5), math.floor(y + 0.5)
            drawPixel(x, y - 2, COLOR.traffic, width, height)
            drawPixel(x - 2, y, COLOR.traffic, width, height)
            drawPixel(x, y + 2, COLOR.traffic, width, height)
            drawPixel(x + 2, y, COLOR.traffic, width, height)
            drawText(x + 4, y - 2,
                contact.callsign or ("AC" .. id),
                COLOR.traffic, width, height)
        end
    end
end

local function buildMapRows(request)
    local width = request.width
    local mapHeight = request.mapHeight
    local pixelsPerBlock = request.pixelsPerBlock
    local mapViewX = request.mapViewX
    local mapViewZ = request.mapViewZ
    local dimension = request.dimension
    local centerX = (width - 1) / 2
    local centerY = (mapHeight - 1) / 2
    local worldXs = {}
    local chunkXs = {}
    local localXs = {}
    for screenX = 0, width - 1 do
        local worldX = math.floor(mapViewX
            + (screenX - centerX) / pixelsPerBlock)
        local chunkX = math.floor(worldX / 16)
        worldXs[screenX + 1] = worldX
        chunkXs[screenX + 1] = chunkX
        localXs[screenX + 1] = worldX - chunkX * 16
    end

    local rows = {}
    local rowCache = {}
    for screenY = 0, mapHeight - 1 do
        local worldZ = math.floor(mapViewZ
            + (screenY - centerY) / pixelsPerBlock)
        local encodedRow = rowCache[worldZ]
        if not encodedRow then
            local chunkZ = math.floor(worldZ / 16)
            local localZ = worldZ - chunkZ * 16
            local row = {}
            local lastWorldX
            local lastColor
            local lastChunkX
            local tilePixels

            for screenX = 0, width - 1 do
                local index = screenX + 1
                local worldX = worldXs[index]
                if worldX ~= lastWorldX then
                    lastWorldX = worldX
                    local chunkX = chunkXs[index]
                    if chunkX ~= lastChunkX then
                        lastChunkX = chunkX
                        local tile = tiles[tileKey(dimension, chunkX, chunkZ)]
                        tilePixels = tile and renderedPixelsFor(tile) or nil
                    end
                    if tilePixels then
                        lastColor = tilePixels:byte(
                            localZ * 16 + localXs[index] + 1)
                    else
                        lastColor = COLOR.unknown
                    end
                end
                row[index] = BYTE[lastColor]
            end

            encodedRow = table.concat(row)
            rowCache[worldZ] = encodedRow
        end
        rows[screenY + 1] = encodedRow

        if (screenY + 1) % MAP_BUILD_ROWS_PER_YIELD == 0
            and screenY + 1 < mapHeight then
            os.queueEvent(MAP_BUILD_STEP_EVENT)
            if not waitForRawEvent(MAP_BUILD_STEP_EVENT) then return nil end
            if mapBuildRequest ~= request
                and mapBuildRequest.layoutSignature
                    ~= request.layoutSignature then
                return nil
            end
        end
    end
    return rows
end

local function blankRows(width, height)
    local key = width .. ":" .. height
    local rows = blankRowsCache[key]
    if rows then return rows end

    rows = {}
    local row = string.rep(BYTE[COLOR.unknown], width)
    for y = 1, height do rows[y] = row end
    blankRowsCache[key] = rows
    return rows
end

local function requestMapBuild(request)
    if mapCache.signature == request.signature then return end
    if mapBuildRequest and mapBuildRequest.signature == request.signature then return end
    mapBuildRequest = request
    os.queueEvent(MAP_BUILD_EVENT)
end

local function render()
    if not info then return end

    if follow then
        viewX = info.x
        viewZ = info.z
    end

    local width, height = term.getSize(2)
    local mapTop = HEADER_HEIGHT
    local mapHeight = height - HEADER_HEIGHT - FOOTER_HEIGHT
    if mapHeight < 8 then error("Display is too short for the terrain map", 0) end

    local pixelsPerBlock = zoom()
    local centerX = (width - 1) / 2
    local centerY = (mapHeight - 1) / 2
    local blocksPerPixel = 1 / pixelsPerBlock
    local mapStepX = math.floor(viewX / blocksPerPixel + 0.5)
    local mapStepZ = math.floor(viewZ / blocksPerPixel + 0.5)
    local mapViewX = mapStepX * blocksPerPixel
    local mapViewZ = mapStepZ * blocksPerPixel
    local signature = table.concat({
        width, mapHeight, pixelsPerBlock, mapStepX, mapStepZ,
        info.dimension, terrainRevision, renderStyleVersion
    }, ":")
    local layoutSignature = table.concat({
        width, mapHeight, pixelsPerBlock, mapStepX, mapStepZ,
        info.dimension, renderStyleVersion
    }, ":")
    requestMapBuild({
        signature = signature,
        layoutSignature = layoutSignature,
        width = width,
        mapHeight = mapHeight,
        pixelsPerBlock = pixelsPerBlock,
        mapViewX = mapViewX,
        mapViewZ = mapViewZ,
        dimension = info.dimension
    })

    local rows
    local displayMapViewX = mapViewX
    local displayMapViewZ = mapViewZ
    if mapCache.rows
        and mapCache.width == width
        and mapCache.mapHeight == mapHeight
        and mapCache.pixelsPerBlock == pixelsPerBlock
        and mapCache.dimension == info.dimension then
        rows = mapCache.rows
        displayMapViewX = mapCache.mapViewX
        displayMapViewZ = mapCache.mapViewZ
    else
        rows = blankRows(width, mapHeight)
    end
    lastDisplayMap = {
        width = width,
        height = height,
        mapTop = mapTop,
        mapHeight = mapHeight,
        pixelsPerBlock = pixelsPerBlock,
        mapViewX = displayMapViewX,
        mapViewZ = displayMapViewZ,
        centerX = centerX,
        centerY = centerY
    }

    term.setFrozen(true)
    term.drawPixels(0, 0, COLOR.background, width, height)
    term.drawPixels(0, mapTop, rows, width, mapHeight)
    drawNavigationOverlay(
        width, height, mapTop, mapHeight, pixelsPerBlock,
        displayMapViewX, displayMapViewZ, centerX, centerY)
    term.drawPixels(0, 0, COLOR.panel, width, HEADER_HEIGHT)
    term.drawPixels(0, HEADER_HEIGHT - 1, COLOR.panelEdge, width, 1)
    term.drawPixels(0, height - FOOTER_HEIGHT, COLOR.panelEdge, width, 1)
    term.drawPixels(0, height - FOOTER_HEIGHT + 1,
        COLOR.panel, width, FOOTER_HEIGHT - 1)

    local zoomLabel
    if pixelsPerBlock >= 1 then
        zoomLabel = ("%dX"):format(pixelsPerBlock)
    else
        zoomLabel = ("1/%dX"):format(1 / pixelsPerBlock)
    end

    local networkLabel = serverId
        and ((serverInfo and serverInfo.name) or ("SERVER " .. serverId))
        or "OFFLINE"
    local header = ("ATLAS NAV %s LINK:%s %s"):format(
        navConfig.callsign, linkStatus, networkLabel)
    drawText(2, 2, fitText(header, width), COLOR.text, width, height)
    local waypoint = nextWaypoint()
    local bearing = waypoint and bearingBetween(
        info.x, info.z, waypoint.x, waypoint.z) or 0
    local headingLine = ("HDG:%03d TRK:%03d BRG:%03d X:%d Y:%d Z:%d"):format(
        math.floor((motion.heading or 0) + 0.5) % 360,
        math.floor((motion.track or 0) + 0.5) % 360,
        math.floor(bearing + 0.5) % 360,
        math.floor(info.x), math.floor(info.y), math.floor(info.z))
    drawText(2, 9, fitText(headingLine, width), COLOR.textDim, width, height)

    local footerY = height - FOOTER_HEIGHT + 3
    local distance = waypoint and distanceBetween(
        info.x, info.z, waypoint.x, waypoint.z) or 0
    local eta = motion.speed > 0.5 and distance / motion.speed or 0
    local routeLine = waypoint
        and ("NEXT:%s DIST:%d ETA:%ds SPD:%.1f"):format(
            waypoint.name or ("WP" .. activeWaypoint),
            math.floor(distance + 0.5), math.floor(eta + 0.5), motion.speed)
        or ("NO ACTIVE ROUTE SPD:%.1f"):format(motion.speed)
    drawText(2, footerY, fitText(routeLine, width),
        waypoint and COLOR.text or COLOR.textDim, width, height)
    local status = ("MAP:%d %s NET:%s ZOOM:%s HDG:%s"):format(
        tileCount, scanStatus, linkStatus, zoomLabel, motion.headingSource)
    drawText(2, footerY + 7, fitText(status, width),
        COLOR.textDim, width, height)
    drawText(2, footerY + 14,
        fitText("W WAYPOINT N NEXT H HDG-CAL +/- ZOOM Q EXIT", width),
        COLOR.textDim, width, height)

    drawText(width - 7, mapTop + 3, "N", COLOR.text, width, height)
    for arrowY = mapTop + 9, mapTop + 14 do
        drawPixel(width - 6, arrowY, COLOR.textDim, width, height)
    end
    drawPixel(width - 7, mapTop + 9, COLOR.textDim, width, height)
    drawPixel(width - 5, mapTop + 9, COLOR.textDim, width, height)

    local aircraftX = math.floor(centerX
        + (info.x - displayMapViewX) * pixelsPerBlock + 0.5)
    local aircraftY = mapTop
        + math.floor(centerY
            + (info.z - displayMapViewZ) * pixelsPerBlock + 0.5)
    local _, clearance = getSample(math.floor(info.x), math.floor(info.z), info.dimension)
    local terrainWarning = clearance and info.y <= clearance + 5
    drawAircraft(aircraftX, aircraftY, width, height, terrainWarning)
    term.setFrozen(false)
end

local function changeZoom(direction)
    local previous = zoomIndex
    zoomIndex = clamp(zoomIndex + direction, 1, #ZOOM_LEVELS)
    if zoomIndex ~= previous then invalidateRenderStyle() end
end

local function pan(dx, dz)
    follow = false
    local amount = math.max(1, math.floor(24 / zoom()))
    viewX = viewX + dx * amount
    viewZ = viewZ + dz * amount
end

local function refreshInfo()
    local ok, result = pcall(surveyor.getInfo)
    if not ok then
        scanStatus = "NO SENSOR"
        return false
    end

    local currentTime = nowMs()
    motion.headingSource = "TRACK"
    if previousPosition then
        local elapsed = (currentTime - previousPosition.at) / 1000
        local dx = result.x - previousPosition.x
        local dz = result.z - previousPosition.z
        local distance = math.sqrt(dx * dx + dz * dz)
        if elapsed > 0 then motion.speed = distance / elapsed end
        if distance > 0.01 then
            motion.track = bearingBetween(
                previousPosition.x, previousPosition.z, result.x, result.z)
        end
    end
    motion.heading = motion.track
    refreshSableMotion()
    previousPosition = {
        x = result.x,
        z = result.z,
        at = currentTime
    }

    info = result
    if not viewX then
        viewX = info.x
        viewZ = info.z
    end

    local waypoint = nextWaypoint()
    if waypoint and distanceBetween(
        info.x, info.z, waypoint.x, waypoint.z) <= 16 then
        if activeWaypoint < #waypoints then
            activeWaypoint = activeWaypoint + 1
            scanPlanSignature = nil
            saveRoute()
        end
    end

    scanOne(info)
    return true
end

local function sendPending(operation, payload, pending)
    if not serverId then return false end
    local requestId = atlas.requestId()
    payload.requestId = requestId
    payload.writeKey = navConfig.writeKey
    if not atlas.send(serverId, operation, payload) then return false end
    pending.sentAt = nowMs()
    pending.requestId = requestId
    pendingNetwork[requestId] = pending
    if pending.key then pendingKeys[pending.key] = requestId end
    return true
end

local function nextQueuedDownload()
    local choiceKey
    local choice
    for key, request in pairs(downloadQueue) do
        if not pendingKeys[key]
            and (not choice or request.priority < choice.priority) then
            choiceKey, choice = key, request
        end
    end
    return choiceKey, choice
end

local function processNetworkQueue()
    if not serverId or linkStatus == "LOST" then return end

    for key, raw in pairs(uploadQueue) do
        if not pendingKeys[key] then
            sendPending("offer_tile", {
                dimension = raw.dimension,
                chunkX = raw.chunkX,
                chunkZ = raw.chunkZ,
                checksum = raw.checksum
            }, {
                type = "offer",
                key = key,
                tile = raw
            })
            return
        end
    end

    local key, request = nextQueuedDownload()
    if request then
        sendPending("get_tile", {
            dimension = request.dimension,
            chunkX = request.chunkX,
            chunkZ = request.chunkZ
        }, {
            type = "download",
            key = key,
            request = request
        })
    end
end

local function clearPending(request)
    pendingNetwork[request.requestId] = nil
    if request.key and pendingKeys[request.key] == request.requestId then
        pendingKeys[request.key] = nil
    end
end

local function handleNetworkMessage(sender, message)
    if sender ~= serverId or type(message) ~= "table"
        or message.atlas ~= atlas.VERSION then return end
    lastServerSeen = nowMs()
    linkStatus = "ONLINE"

    if message.op == "traffic_data" and type(message.contacts) == "table" then
        traffic = {}
        for _, contact in ipairs(message.contacts) do
            if type(contact) == "table" and contact.id then
                traffic[contact.id] = contact
            end
        end
    elseif message.op == "station_info" then
        serverInfo = message
    end

    local pending = message.requestId and pendingNetwork[message.requestId]
    if not pending then return end
    clearPending(pending)

    if pending.type == "offer" then
        if message.op == "tile_have" then
            markSynced(pending.tile)
        elseif message.op == "tile_send" then
            sendPending("put_tile", {
                tile = pending.tile
            }, {
                type = "upload",
                key = pending.key,
                tile = pending.tile
            })
        end
    elseif pending.type == "upload" then
        if message.op == "tile_stored" then
            markSynced(pending.tile)
        end
    elseif pending.type == "download" then
        if message.op == "tile_data" and message.tile then
            local ok = pcall(installRawTile, message.tile, "network")
            if ok then downloadQueue[pending.key] = nil end
        elseif message.op == "tile_missing" then
            downloadQueue[pending.key] = nil
            networkMissUntil[pending.key] = nowMs() + NETWORK_MISS_MS
        end
    end
end

local function expireNetworkRequests()
    local currentTime = nowMs()
    for _, request in pairs(pendingNetwork) do
        if currentTime - request.sentAt > NETWORK_TIMEOUT_MS then
            clearPending(request)
        end
    end
end

local function heartbeat()
    if not serverId or not info then return end
    atlas.send(serverId, "heartbeat", {
        callsign = navConfig.callsign,
        dimension = info.dimension,
        x = info.x,
        y = info.y,
        z = info.z,
        heading = motion.heading,
        track = motion.track,
        speed = motion.speed,
        status = nextWaypoint() and "ENROUTE" or "LOCAL"
    })
end

local function requestTraffic()
    if not serverId then return end
    sendPending("traffic_request", {}, {
        type = "traffic"
    })
end

local function queueCorridor(
        dimension, fromChunkX, fromChunkZ, toChunkX, toChunkZ, basePriority)
    local dx = toChunkX - fromChunkX
    local dz = toChunkZ - fromChunkZ
    local steps = math.max(math.abs(dx), math.abs(dz))
    if steps == 0 then return end
    for step = 0, math.min(steps, 256) do
        local amount = step / steps
        local chunkX = math.floor(fromChunkX + dx * amount + 0.5)
        local chunkZ = math.floor(fromChunkZ + dz * amount + 0.5)
        for width = -1, 1 do
            queueDownload(dimension, chunkX + width, chunkZ,
                basePriority + step + math.abs(width))
            queueDownload(dimension, chunkX, chunkZ + width,
                basePriority + step + math.abs(width))
        end
    end
end

local function refreshPrefetch()
    if not info or not serverId then return end
    local chunkX = math.floor(info.x / 16)
    local chunkZ = math.floor(info.z / 16)

    for dz = -4, 4 do
        for dx = -4, 4 do
            local distance = dx * dx + dz * dz
            if distance <= 16 then
                queueDownload(
                    info.dimension, chunkX + dx, chunkZ + dz, distance)
            end
        end
    end

    local directionX, directionZ = scanDirection()
    for dz = -12, 12 do
        for dx = -12, 12 do
            local distance = math.sqrt(dx * dx + dz * dz)
            if distance <= 12 and distance > 0 then
                local forward = dx * directionX + dz * directionZ
                local cross = math.abs(dx * directionZ - dz * directionX)
                if forward > 0 and cross <= 1.5 + forward * 0.45 then
                    queueDownload(info.dimension, chunkX + dx, chunkZ + dz,
                        30 + distance)
                end
            end
        end
    end

    local fromX, fromZ = chunkX, chunkZ
    for index = activeWaypoint, #waypoints do
        local waypoint = waypoints[index]
        local toX = math.floor(waypoint.x / 16)
        local toZ = math.floor(waypoint.z / 16)
        queueCorridor(info.dimension, fromX, fromZ, toX, toZ,
            100 + (index - activeWaypoint) * 300)
        fromX, fromZ = toX, toZ
    end
end

local function evictCacheIfNeeded()
    local details = atlas.capacity("/")
    if type(details.capacity) ~= "number"
        or type(details.free) ~= "number" then return end
    local reserve = details.capacity * 0.02
    if details.free >= reserve then return end

    local candidates = {}
    for key, entry in pairs(cacheIndex.tiles) do
        if not entry.unsynced and not tiles[key] then
            candidates[#candidates + 1] = { key = key, entry = entry }
        end
    end
    table.sort(candidates, function(a, b)
        return (a.entry.lastUsed or 0) < (b.entry.lastUsed or 0)
    end)
    for _, candidate in ipairs(candidates) do
        if atlas.capacity("/").free >= reserve then break end
        if fs.exists(candidate.entry.path) then
            pcall(fs.delete, candidate.entry.path)
        end
        cacheIndex.tiles[candidate.key] = nil
        cacheDirty = true
    end
end

local function networkLoop()
    local timer = os.startTimer(NETWORK_TICK_SECONDS)
    local lastHeartbeat = 0
    local lastTraffic = 0
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            return
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_LINK then
            handleNetworkMessage(event[2], event[3])
        elseif event[1] == "timer" and event[2] == timer then
            local currentTime = nowMs()
            expireNetworkRequests()
            processNetworkQueue()
            if currentTime - lastHeartbeat >= HEARTBEAT_MS then
                heartbeat()
                lastHeartbeat = currentTime
            end
            if currentTime - lastTraffic >= TRAFFIC_MS then
                requestTraffic()
                lastTraffic = currentTime
            end
            if serverId and currentTime - lastServerSeen > 5000 then
                linkStatus = "LOST"
            end
            timer = os.startTimer(NETWORK_TICK_SECONDS)
        end
    end
end

local function cacheLoop()
    while running do
        for key, entry in pairs(cacheIndex.tiles) do
            if entry.unsynced and not uploadQueue[key] then
                local raw = atlas.loadTile(entry.path)
                if raw then uploadQueue[key] = raw end
            end
        end
        refreshPrefetch()
        evictCacheIfNeeded()
        if cacheDirty then
            atlas.writeTable(CACHE_META_PATH, cacheIndex)
            cacheDirty = false
        end
        if not waitSeconds(1) then return end
    end
end

local function mapBuilderLoop()
    while running do
        if not waitForRawEvent(MAP_BUILD_EVENT) then return end
        while running do
            local request = mapBuildRequest
            if not request or request.signature == mapCache.signature then break end

            local rows = buildMapRows(request)
            local latestRequest = mapBuildRequest
            if rows and running
                and (latestRequest == request
                    or latestRequest.layoutSignature
                        == request.layoutSignature) then
                mapCache = {
                    signature = request.signature,
                    rows = rows,
                    width = request.width,
                    mapHeight = request.mapHeight,
                    pixelsPerBlock = request.pixelsPerBlock,
                    mapViewX = request.mapViewX,
                    mapViewZ = request.mapViewZ,
                    dimension = request.dimension
                }
                if latestRequest == request then break end
            end
        end
    end
end

local function sensorLoop()
    while running do
        refreshInfo()
        if not waitSeconds(UPDATE_SECONDS) then return end
    end
end

local function displayLoop()
    while running do
        if not modal then render() end
        if not waitSeconds(UPDATE_SECONDS) then return end
    end
end

local function addWaypoint(worldX, worldZ, altitude, name)
    waypoints[#waypoints + 1] = {
        name = name or ("WP" .. (#waypoints + 1)),
        x = math.floor(worldX + 0.5),
        z = math.floor(worldZ + 0.5),
        y = altitude
    }
    if #waypoints == 1 then activeWaypoint = 1 end
    scanPlanSignature = nil
    saveRoute()
end

local function waypointEditor()
    modal = true
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("ATLAS WAYPOINT ENTRY")
    print()
    write("Name [WP" .. (#waypoints + 1) .. "]: ")
    local name = read()
    if name == "" then name = "WP" .. (#waypoints + 1) end
    write("X coordinate: ")
    local x = tonumber(read())
    write("Z coordinate: ")
    local z = tonumber(read())
    write("Altitude (optional): ")
    local altitudeText = read()
    local altitude = altitudeText ~= "" and tonumber(altitudeText) or nil
    if x and z then addWaypoint(x, z, altitude, name) end

    local ok, failure = pcall(term.setGraphicsMode, 2)
    if not ok then error(failure, 0) end
    configurePalette()
    invalidateRenderStyle()
    modal = false
end

local function inputLoop()
    while running do
        local event = { os.pullEventRaw() }
        local eventName = event[1]

        if eventName == "terminate" then
            running = false
            return
        elseif eventName == "char" then
            local character = event[2]:lower()
            if character == "+" or character == "=" then
                changeZoom(1)
            elseif character == "-" or character == "_" then
                changeZoom(-1)
            elseif character == "g" then
                showGrid = not showGrid
                invalidateRenderStyle()
            elseif character == "c" then
                showContours = not showContours
                invalidateRenderStyle()
            elseif character == "o" then
                showObstacles = not showObstacles
                invalidateRenderStyle()
            elseif character == "w" then
                waypointEditor()
            elseif character == "n" then
                if activeWaypoint < #waypoints then
                    activeWaypoint = activeWaypoint + 1
                    scanPlanSignature = nil
                    saveRoute()
                end
            elseif character == "h" then
                calibrateHeading()
            elseif character == "q" then
                running = false
                return
            elseif character == "r" and info then
                local key = tileKey(info.dimension, info.chunkX, info.chunkZ)
                if tiles[key] then
                    tiles[key] = nil
                    tileCount = math.max(0, tileCount - 1)
                    invalidateTileDependencies(
                        info.dimension, info.chunkX, info.chunkZ)
                end
            end
        elseif eventName == "key" then
            local key = event[2]
            if key == keys.left then pan(-1, 0)
            elseif key == keys.right then pan(1, 0)
            elseif key == keys.up then pan(0, -1)
            elseif key == keys.down then pan(0, 1)
            elseif key == keys.space then follow = true
            end
        elseif eventName == "mouse_scroll" then
            changeZoom(event[2] < 0 and 1 or -1)
        elseif eventName == "mouse_click" and info then
            local _, button, mouseX, mouseY = table.unpack(event)
            local display = lastDisplayMap
            if display
                and mouseY >= display.mapTop
                and mouseY < display.mapTop + display.mapHeight then
                if button == 1 then
                    local worldX = display.mapViewX
                        + (mouseX - display.centerX)
                            / display.pixelsPerBlock
                    local worldZ = display.mapViewZ
                        + (mouseY - display.mapTop - display.centerY)
                            / display.pixelsPerBlock
                    addWaypoint(worldX, worldZ, nil)
                else
                    viewX = display.mapViewX
                        + (mouseX - display.centerX)
                            / display.pixelsPerBlock
                    viewZ = display.mapViewZ
                        + (mouseY - display.mapTop - display.centerY)
                            / display.pixelsPerBlock
                    follow = false
                end
            end
        end
    end
end

local function main()
    math.randomseed(atlas.now() + os.getComputerID())
    atlas.writeTable(NAV_CONFIG_PATH, navConfig)
    local wireless = atlas.openWirelessRednet()
    serverId, serverInfo = chooseStation(#wireless > 0)
    if not running then return end
    if serverId then
        linkStatus = "ONLINE"
        lastServerSeen = nowMs()
    else
        linkStatus = "OFFLINE"
    end

    if not term.setGraphicsMode or not term.drawPixels or not term.setFrozen then
        error("CC: Graphics is not available on this computer", 0)
    end

    local graphicsOk, graphicsError = pcall(term.setGraphicsMode, 2)
    if not graphicsOk then
        error("Cannot enter CC: Graphics mode 2: " .. tostring(graphicsError), 0)
    end

    configurePalette()
    refreshInfo()
    parallel.waitForAny(
        inputLoop,
        sensorLoop,
        displayLoop,
        mapBuilderLoop,
        networkLoop,
        cacheLoop)
    running = false
end

local ok, failure = xpcall(main, debug.traceback)
pcall(term.setFrozen, false)
pcall(term.setGraphicsMode, false)
if cacheDirty then pcall(atlas.writeTable, CACHE_META_PATH, cacheIndex) end
pcall(saveRoute)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if not ok then
    printError(failure)
else
    print("ATLAS Navigator closed.")
end
