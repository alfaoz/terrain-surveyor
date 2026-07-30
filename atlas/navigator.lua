-- ATLAS Navigator for:
--   Terrain Surveyor 0.2.1
--   CC: Tweaked 1.120.0
--   CC: Graphics 0.2.0
--
-- The map is north-up: +X is right and +Z is down.

local LIBRARY = fs.exists("/atlas/lib.lua") and "/atlas/lib.lua" or "atlas/lib.lua"
local atlas = dofile(LIBRARY)
-- Keep helpers in a private program environment instead of consuming one
-- Cobalt local slot each. CraftOS permits at most 200 active locals.
local _ENV = setmetatable({}, { __index = _ENV })
COMPANION_HOST_LIBRARY = fs.exists("/atlas/companion-host.lua")
    and "/atlas/companion-host.lua" or "atlas/companion-host.lua"

-- One Minecraft tick: 20 visual/position updates per second.
local UPDATE_SECONDS = 0.05
local RETRY_MS = 1500
local UNLOADED_RETRY_MS = 250
local DEFAULT_SCAN_BATCH_CHUNKS = 8
local DEFAULT_SCAN_BUDGET_MICROS = 4000
local DEFAULT_SCAN_REQUEST_WINDOW = 32
local SCAN_PREFETCH_TARGET = 96
local CACHE_WRITES_PER_TICK = 6
local NETWORK_TICK_SECONDS = 0.05
local HEARTBEAT_MS = 1000
local TRAFFIC_MS = 1000
local STATION_INFO_MS = 2000
local NETWORK_TIMEOUT_MS = 3000
local NETWORK_MISS_MS = 30000
local CACHE_META_PATH = "/atlas/cache/index.dat"
local CACHE_TILE_ROOT = "/atlas/cache/tiles"
local CACHE_POLICY = {
    volumeMeta = "atlas/air_cache.dat",
    volumeFormat = 1,
    rescanMs = 2000,
    reserveFraction = 0.02,
    evictionCooldownMs = 60000,
    localRadiusChunks = 24,
    forwardMaxChunks = 64
}
local NAV_CONFIG_PATH = "/atlas/navigator.cfg"
local ROUTE_PATH = "/atlas/route.dat"
local POI_CACHE_PATH = "/atlas/pois.dat"
local MAP_BUILD_ROWS_PER_YIELD = 12
local MAP_BUILD_EVENT = "terrain_map_build"
local MAP_BUILD_STEP_EVENT = "terrain_map_build_step"
local MAX_DOWNLOAD_QUEUE = 512
local VIEWPORT_DOWNLOADS_PER_REFRESH = 64
local VIEWPORT_INSPECTIONS_PER_REFRESH = 512
-- Tuned against ATLAS Link Speedtest v2: 120 KB reliable payloads and
-- 4,329-byte real terrain tiles. Fourteen tiles stay below the 84 KB
-- recommended response budget, with three requests in flight.
local DOWNLOAD_BATCH_SIZE = 14
local MAX_IN_FLIGHT_DOWNLOADS = 3
local DOWNLOAD_WINDOW_SIZE = 98
local CATALOG_POLICY = {
    pageSize = 256,
    restartMs = 5000,
    pageDelayMs = 100,
    downloadPriority = 10000
}
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
    poi = 18,
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

function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function tableCount(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

function lerp(a, b, amount)
    return a + (b - a) * amount
end

function mixColor(a, b, amount)
    return {
        lerp(a[1], b[1], amount),
        lerp(a[2], b[2], amount),
        lerp(a[3], b[3], amount)
    }
end

function setPalette(index, rgb)
    term.setPaletteColor(index, rgb[1] / 255, rgb[2] / 255, rgb[3] / 255)
end

local originalTextPalette = {}
for exponent = 0, 15 do
    local color = 2 ^ exponent
    local ok, red, green, blue = pcall(term.getPaletteColor, color)
    if ok then originalTextPalette[color] = { red, green, blue } end
end

function restoreTextPalette()
    for exponent = 0, 15 do
        local color = 2 ^ exponent
        local red
        local green
        local blue
        if term.nativePaletteColor then
            local ok
            ok, red, green, blue = pcall(term.nativePaletteColor, color)
            if not ok then red = nil end
        end
        local saved = originalTextPalette[color]
        red = red or (saved and saved[1])
        green = green or (saved and saved[2])
        blue = blue or (saved and saved[3])
        if red and green and blue then
            pcall(term.setPaletteColor, color, red, green, blue)
        end
    end
end

function configurePalette()
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
    setPalette(COLOR.poi, { 210, 151, 221 })

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

function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

function waitForRawEvent(name, identifier)
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

function waitSeconds(seconds)
    return waitForRawEvent("timer", os.startTimer(seconds))
end

function tileKey(dimension, chunkX, chunkZ)
    return atlas.tileKey(dimension, chunkX, chunkZ)
end

function decodeHeights(data, minY)
    local decoded = {}
    for sample = 0, 255 do
        local byteIndex = sample * 2 + 1
        local high, low = data:byte(byteIndex, byteIndex + 1)
        local encoded = high * 256 + low
        decoded[sample + 1] = encoded == 0xffff and false or minY + encoded
    end
    return decoded
end

function decodeTile(raw)
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

function findSurveyor()
    local surveyor = peripheral.find("terrain_surveyor")
    if not surveyor then error("No Terrain Surveyor is attached", 0) end
    return surveyor
end

local navConfig = atlas.readTable(NAV_CONFIG_PATH) or {}
function validCallsign(value)
    return type(value) == "string"
        and value:upper():match("^[A-Z][A-Z]%-%d%d$") ~= nil
end

if validCallsign(navConfig.callsign) then
    navConfig.callsign = navConfig.callsign:upper()
else
    navConfig.callsign = ("AC-%02d"):format(os.getComputerID() % 100)
end
navConfig.writeKey = navConfig.writeKey or ""
navConfig.lastServer = navConfig.lastServer or ""
navConfig.lastServerId = tonumber(navConfig.lastServerId)
navConfig.headingOffset = tonumber(navConfig.headingOffset) or 0
navConfig.scanBatchChunks = clamp(
    tonumber(navConfig.scanBatchChunks) or DEFAULT_SCAN_BATCH_CHUNKS, 1, 24)
navConfig.scanBudgetMicros = clamp(
    tonumber(navConfig.scanBudgetMicros) or DEFAULT_SCAN_BUDGET_MICROS,
    500, 8000)

local routeData = atlas.readTable(ROUTE_PATH) or {}
local waypoints = type(routeData.waypoints) == "table"
    and routeData.waypoints or {}
local activeWaypoint = math.max(1, tonumber(routeData.active) or 1)
routeRevision = math.max(0, tonumber(routeData.revision) or 0)

local poiCache = atlas.readTable(POI_CACHE_PATH) or {}
local pois = {}
for _, cachedPoi in ipairs(type(poiCache.pois) == "table"
        and poiCache.pois or {}) do
    if type(cachedPoi) == "table" and type(cachedPoi.id) == "string" then
        pois[cachedPoi.id] = cachedPoi
    end
end
local poiRevision = tonumber(poiCache.revision) or 0
local poiSourceId = tonumber(poiCache.serverId)
local selectedPoiId
local poiDialog
local poiMenu

local cacheIndex = atlas.readTable(CACHE_META_PATH) or {}
cacheIndex.tiles = type(cacheIndex.tiles) == "table" and cacheIndex.tiles or {}
knownLocalTerrain = {}
knownServerTerrain = {}
knownTerrainRevision = 0
for cachedKey in pairs(cacheIndex.tiles) do
    knownLocalTerrain[cachedKey] = true
end

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
local uploadRetry = {}
local cacheWriteQueue = {}
local cacheVolumes = {}
local cacheStorage = {
    volumes = 1,
    capacity = 0,
    free = 0
}
local lastCacheVolumeScan = 0
local cacheEvictedUntil = {}
local downloadQueue = {}
local networkMissUntil = {}
local serverVerifiedAt = {}
local forceSurvey = {}
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
local pointerDetails
pairDialog = nil
companionHost = nil
local viewportPrefetchState
local catalogState = {
    revision = nil,
    cursor = 1,
    total = 0,
    seen = 0,
    mirrored = 0,
    pending = false,
    nextAt = 0
}
local scanMetrics = {
    completedAt = {},
    chunksPerSecond = 0,
    backlog = 0,
    waiting = 0,
    aheadChunks = 0,
    aheadSeconds = 0,
    lastBatchChunks = 0,
    lastBatchRequests = 0,
    lastBatchInspected = 0,
    lastBatchUnloaded = 0,
    lastBatchMicros = 0,
    batchSupported = false
}

function saveRoute(changed)
    if changed then routeRevision = routeRevision + 1 end
    activeWaypoint = math.max(1, math.min(
        activeWaypoint, math.max(1, #waypoints)))
    atlas.writeTable(ROUTE_PATH, {
        format = 1,
        revision = routeRevision,
        waypoints = waypoints,
        active = activeWaypoint
    })
end

function routeSnapshot()
    local snapshot = {}
    for index, waypoint in ipairs(waypoints) do
        snapshot[index] = {
            name = waypoint.name,
            x = waypoint.x,
            y = waypoint.y,
            z = waypoint.z
        }
    end
    return {
        revision = routeRevision,
        waypoints = snapshot,
        active = activeWaypoint
    }
end

function trafficArray()
    local result = {}
    for _, contact in pairs(traffic) do
        result[#result + 1] = contact
    end
    return result
end

function companionSnapshot()
    return {
        aircraft = info and {
            dimension = info.dimension,
            x = info.x,
            y = info.y,
            z = info.z,
            chunkX = info.chunkX,
            chunkZ = info.chunkZ,
            heading = motion.heading,
            track = motion.track,
            speed = motion.speed
        } or nil,
        route = routeSnapshot(),
        pois = poiArray(),
        poiRevision = poiRevision,
        traffic = trafficArray(),
        station = {
            id = serverId,
            name = serverInfo and serverInfo.name,
            status = linkStatus
        },
        scan = {
            status = scanStatus,
            chunksPerSecond = scanMetrics.chunksPerSecond,
            aheadSeconds = scanMetrics.aheadSeconds
        },
        knownTerrainRevision = knownTerrainRevision
    }
end

function terrainKnown(key)
    return knownLocalTerrain[key] or knownServerTerrain[key] or false
end

function markTerrainKnown(key, source)
    local before = terrainKnown(key)
    local target = source == "server"
        and knownServerTerrain or knownLocalTerrain
    target[key] = true
    if not before then
        knownTerrainRevision = knownTerrainRevision + 1
        return true
    end
    return false
end

function forgetTerrainKnown(key, source)
    local before = terrainKnown(key)
    if source == "server" then
        knownServerTerrain[key] = nil
    elseif source == "local" then
        knownLocalTerrain[key] = nil
    else
        knownServerTerrain[key] = nil
        knownLocalTerrain[key] = nil
    end
    if before and not terrainKnown(key) then
        knownTerrainRevision = knownTerrainRevision + 1
        return true
    end
    return false
end

function resetServerTerrainKnowledge()
    knownServerTerrain = {}
    knownTerrainRevision = knownTerrainRevision + 1
end

function companionGetCoverage(dimension, regionX, regionZ)
    local bytes = {}
    local originX = math.floor(regionX) * 32
    local originZ = math.floor(regionZ) * 32
    for localZ = 0, 31 do
        for byteX = 0, 3 do
            local value = 0
            for bitIndex = 0, 7 do
                local chunkX = originX + byteX * 8 + bitIndex
                local chunkZ = originZ + localZ
                if terrainKnown(tileKey(dimension, chunkX, chunkZ)) then
                    value = value + 2 ^ bitIndex
                end
            end
            bytes[#bytes + 1] = string.char(value)
        end
    end
    return table.concat(bytes), knownTerrainRevision
end

function companionGetTile(dimension, chunkX, chunkZ)
    local key = tileKey(dimension, chunkX, chunkZ)
    local loaded = tiles[key]
    if loaded and loaded.raw then return atlas.copyTile(loaded.raw), "data" end
    local pendingWrite = cacheWriteQueue[key]
    if pendingWrite and pendingWrite.raw then
        return atlas.copyTile(pendingWrite.raw), "data"
    end
    local raw = loadLocalRaw(dimension, chunkX, chunkZ)
    if raw then return raw, "data" end
    if nowMs() < (networkMissUntil[key] or 0) then
        return nil, "missing"
    end
    if not terrainKnown(key) then
        return nil, "missing"
    end
    if serverId and linkStatus ~= "LOST" then
        queueDownload(dimension, chunkX, chunkZ, -25000, false, true)
        return nil, "pending"
    end
    return nil, "unavailable"
end

function companionMutateRoute(operation, message)
    local baseRevision = tonumber(message.baseRevision)
    if baseRevision and baseRevision ~= routeRevision then
        return false, "route changed; refresh and try again", routeSnapshot()
    end
    if operation == "route_add" then
        local waypoint = type(message.waypoint) == "table"
            and message.waypoint or {}
        local x = tonumber(waypoint.x)
        local z = tonumber(waypoint.z)
        local y = waypoint.y ~= nil and tonumber(waypoint.y) or nil
        if not x or not z or math.abs(x) > 30000000
            or math.abs(z) > 30000000
            or waypoint.y ~= nil and not y then
            return false, "invalid waypoint", routeSnapshot()
        end
        local name = tostring(waypoint.name or ("WP" .. (#waypoints + 1)))
        name = name:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 24)
        if name == "" then name = "WP" .. (#waypoints + 1) end
        addWaypoint(x, z, y, name)
    elseif operation == "route_delete" then
        local index = math.floor(tonumber(message.index) or activeWaypoint)
        if not removeWaypoint(index) then
            return false, "waypoint does not exist", routeSnapshot()
        end
    elseif operation == "route_set_active" then
        local index = math.floor(tonumber(message.index) or 0)
        if not waypoints[index] then
            return false, "waypoint does not exist", routeSnapshot()
        end
        activeWaypoint = index
        scanPlanSignature = nil
        saveRoute(true)
    else
        return false, "unsupported route operation", routeSnapshot()
    end
    return true, nil, routeSnapshot()
end

function startCompanionHost()
    if not fs.exists(COMPANION_HOST_LIBRARY) then
        scanStatus = "COMPANION HOST NOT INSTALLED"
        return false
    end
    local module = dofile(COMPANION_HOST_LIBRARY)
    companionHost = module.new({
        callsign = function() return navConfig.callsign end,
        snapshot = companionSnapshot,
        getTile = companionGetTile,
        getCoverage = companionGetCoverage,
        mutateRoute = companionMutateRoute
    })
    if not companionHost:host() then
        scanStatus = "COMPANION HOST OFFLINE"
        return false
    end
    return true
end

function nextWaypoint()
    return waypoints[activeWaypoint]
end

function poiArray()
    local result = {}
    for _, poi in pairs(pois) do result[#result + 1] = poi end
    table.sort(result, function(a, b)
        local aName = tostring(a.name or "")
        local bName = tostring(b.name or "")
        if aName == bName then return tostring(a.id) < tostring(b.id) end
        return aName < bName
    end)
    return result
end

function savePoiCache()
    return atlas.writeTable(POI_CACHE_PATH, {
        format = 1,
        revision = poiRevision,
        serverId = serverId or poiSourceId,
        pois = poiArray()
    })
end

function validPoi(value)
    return type(value) == "table"
        and type(value.id) == "string"
        and type(value.name) == "string"
        and type(value.dimension) == "string"
        and type(value.x) == "number"
        and type(value.z) == "number"
end

function installPoiList(values, revision)
    if type(values) ~= "table" then return false end
    local replacement = {}
    for _, poi in ipairs(values) do
        if validPoi(poi) then replacement[poi.id] = poi end
    end
    pois = replacement
    poiRevision = tonumber(revision) or poiRevision
    poiSourceId = serverId or poiSourceId
    if selectedPoiId and not pois[selectedPoiId] then selectedPoiId = nil end
    savePoiCache()
    return true
end

function bearingBetween(x1, z1, x2, z2)
    local radians
    if math.atan2 then
        radians = math.atan2(x2 - x1, -(z2 - z1))
    else
        radians = math.atan(x2 - x1, -(z2 - z1))
    end
    return (math.deg(radians) + 360) % 360
end

function distanceBetween(x1, z1, x2, z2)
    local dx = x2 - x1
    local dz = z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

function quaternionHeading(orientation)
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

function refreshSableMotion()
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

function calibrateHeading()
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

function cacheRelativePath(dimension, chunkX, chunkZ)
    local regionX = math.floor(chunkX / 32)
    local regionZ = math.floor(chunkZ / 32)
    return fs.combine(
        "atlas/cache/tiles",
        atlas.safeName(dimension),
        regionX .. "_" .. regionZ,
        chunkX .. "_" .. chunkZ .. ".tile")
end

function localCachePath(dimension, chunkX, chunkZ)
    return "/" .. cacheRelativePath(dimension, chunkX, chunkZ)
end

function cacheVolumeById(identifier)
    for _, volume in ipairs(cacheVolumes) do
        if volume.id == identifier then return volume end
    end
end

function cacheEntryPath(entry)
    if not entry then return nil end
    if entry.volumeId and entry.relativePath then
        local volume = cacheVolumeById(entry.volumeId)
        if not volume then return nil end
        return fs.combine(volume.mount, entry.relativePath)
    end
    return entry.path
end

function refreshCacheVolumes(force)
    local currentTime = nowMs()
    if not force
        and currentTime - lastCacheVolumeScan
            < CACHE_POLICY.rescanMs then return end
    lastCacheVolumeScan = currentTime

    local nextVolumes = {
        {
            id = "computer",
            label = "ONBOARD COMPUTER",
            mount = "/",
            removable = false
        }
    }
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "drive") then
            local drive = peripheral.wrap(name)
            local okMount, mount = pcall(drive.getMountPath)
            if okMount and type(mount) == "string" and fs.exists(mount) then
                local metaPath = fs.combine(mount, CACHE_POLICY.volumeMeta)
                local meta = atlas.readTable(metaPath)
                if type(meta) ~= "table" then
                    local okList, entries = pcall(fs.list, mount)
                    if okList and #entries == 0 then
                        meta = {
                            atlas = atlas.VERSION,
                            format = CACHE_POLICY.volumeFormat,
                            id = atlas.randomId("air-cache"),
                            label = "ATLAS AIR CACHE",
                            createdAt = atlas.now()
                        }
                        atlas.writeTable(metaPath, meta)
                        pcall(drive.setDiskLabel, "ATLAS AIR CACHE")
                    end
                end
                if type(meta) == "table"
                    and meta.atlas == atlas.VERSION
                    and meta.format == CACHE_POLICY.volumeFormat
                    and type(meta.id) == "string" then
                    nextVolumes[#nextVolumes + 1] = {
                        id = meta.id,
                        label = meta.label or "ATLAS AIR CACHE",
                        mount = mount,
                        drive = name,
                        removable = true
                    }
                end
            end
        end
    end
    cacheVolumes = nextVolumes

    local capacity = 0
    local free = 0
    for _, volume in ipairs(cacheVolumes) do
        local details = atlas.capacity(volume.mount)
        if type(details.capacity) == "number" then
            capacity = capacity + details.capacity
        end
        if type(details.free) == "number" then
            free = free + details.free
        end
    end
    cacheStorage.volumes = #cacheVolumes
    cacheStorage.capacity = capacity
    cacheStorage.free = free
end

function chooseCacheVolume(requiredBytes, previous)
    refreshCacheVolumes(false)
    local preferred = previous and cacheVolumeById(previous.volumeId)
    if preferred then
        local details = atlas.capacity(preferred.mount)
        local reserve = type(details.capacity) == "number"
            and details.capacity * CACHE_POLICY.reserveFraction or 0
        local reclaimable = tonumber(previous.size) or 0
        if details.free == "unlimited"
            or type(details.free) == "number"
                and details.free + reclaimable - reserve >= requiredBytes then
            return preferred
        end
    end

    local choice
    local bestAvailable = -math.huge
    for _, volume in ipairs(cacheVolumes) do
        local details = atlas.capacity(volume.mount)
        local available
        if details.free == "unlimited" then
            available = math.huge
        elseif type(details.free) == "number" then
            local reserve = type(details.capacity) == "number"
                and details.capacity * CACHE_POLICY.reserveFraction or 0
            available = details.free - reserve
        end
        if available and available >= requiredBytes then
            local score = available
            if volume.removable and score < math.huge then score = score + 1 end
            if score > bestAvailable then
                choice = volume
                bestAvailable = score
            end
        end
    end
    return choice
end

local cacheDirty = false

function saveLocalRaw(raw, unsynced)
    local encoded, reason = atlas.encodeTile(raw)
    if not encoded then return false, reason end
    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    local previous = cacheIndex.tiles[key]
    local volume = chooseCacheVolume(#encoded + 512, previous)
    if not volume then return false, "onboard cache is full" end
    local relativePath = cacheRelativePath(
        raw.dimension, raw.chunkX, raw.chunkZ)
    local path = fs.combine(volume.mount, relativePath)
    local ok, failure = atlas.writeAtomic(path, encoded, false)
    if not ok then return false, failure end

    cacheIndex.tiles[key] = {
        path = path,
        volumeId = volume.id,
        relativePath = relativePath,
        checksum = raw.checksum,
        lastUsed = nowMs(),
        unsynced = unsynced == nil
            and (previous and previous.unsynced or false)
            or unsynced,
        size = #encoded
    }
    local oldPath = cacheEntryPath(previous)
    if oldPath and oldPath ~= path and fs.exists(oldPath) then
        pcall(fs.delete, oldPath)
    end
    cacheDirty = true
    return true
end

function queueLocalSave(raw, unsynced, background)
    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    local pending = cacheWriteQueue[key]
    cacheWriteQueue[key] = {
        raw = atlas.copyTile(raw),
        unsynced = unsynced
            or (pending and pending.unsynced)
            or false,
        background = background == true
            and (not pending or pending.background ~= false),
        attempts = pending and pending.attempts or 0,
        notBefore = pending and pending.notBefore or 0
    }
end

function loadLocalRaw(dimension, chunkX, chunkZ)
    local key = tileKey(dimension, chunkX, chunkZ)
    local entry = cacheIndex.tiles[key]
    local path = cacheEntryPath(entry)
        or localCachePath(dimension, chunkX, chunkZ)
    if not fs.exists(path) then
        if entry then
            local volumeMissing = entry.volumeId
                and entry.volumeId ~= "computer"
                and not cacheVolumeById(entry.volumeId)
            if not volumeMissing then
                cacheIndex.tiles[key] = nil
                cacheDirty = true
            end
        end
        if not tiles[key] and not cacheWriteQueue[key] then
            forgetTerrainKnown(key, "local")
        end
        return nil
    end
    local raw = atlas.loadTile(path)
    if not raw then
        cacheIndex.tiles[key] = nil
        cacheDirty = true
        if not tiles[key] and not cacheWriteQueue[key] then
            forgetTerrainKnown(key, "local")
        end
        return nil
    end
    cacheIndex.tiles[key] = entry or {
        path = path,
        volumeId = "computer",
        relativePath = cacheRelativePath(dimension, chunkX, chunkZ),
        checksum = raw.checksum,
        unsynced = false,
        size = fs.getSize(path)
    }
    cacheIndex.tiles[key].lastUsed = nowMs()
    cacheDirty = true
    return raw
end

function queueUpload(raw)
    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    uploadQueue[key] = atlas.copyTile(raw)
    local entry = cacheIndex.tiles[key]
    if entry then
        entry.unsynced = true
        cacheDirty = true
    end
    local pendingWrite = cacheWriteQueue[key]
    if pendingWrite then pendingWrite.unsynced = true end
    local retry = uploadRetry[key]
    if retry and retry.checksum ~= raw.checksum then uploadRetry[key] = nil end
end

function markSynced(raw)
    local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
    local entry = cacheIndex.tiles[key]
    if entry and entry.checksum == raw.checksum then
        entry.unsynced = false
        cacheDirty = true
    end
    local pendingWrite = cacheWriteQueue[key]
    if pendingWrite and pendingWrite.raw.checksum == raw.checksum then
        pendingWrite.unsynced = false
        pendingWrite.background = false
    end
    uploadQueue[key] = nil
    uploadRetry[key] = nil
    networkMissUntil[key] = nil
    serverVerifiedAt[key] = nowMs()
end

function queueDownload(
        dimension, chunkX, chunkZ, priority, verifyExisting, cacheOnly)
    if not serverId then return false end
    local key = tileKey(dimension, chunkX, chunkZ)
    if pendingKeys[key] then
        local pendingRequest = downloadQueue[key]
        if pendingRequest and not cacheOnly then
            pendingRequest.cacheOnly = false
        end
        return false
    end
    local cached = cacheIndex.tiles[key]
    if cached and verifyExisting and not cached.unsynced
        and serverVerifiedAt[key] then return false end
    local cachedPath = cacheEntryPath(cached)
    local hasCached = cachedPath and fs.exists(cachedPath)
    local localTile = tiles[key]
    local knownChecksum = localTile and localTile.checksum
        or hasCached and cached.checksum
    if localTile and not hasCached and not cacheWriteQueue[key] then
        queueLocalSave(localTile.raw, uploadQueue[key] ~= nil)
    end

    if localTile or hasCached then
        if not verifyExisting or cached and cached.unsynced
            or serverVerifiedAt[key] then return false end
    elseif nowMs() < (networkMissUntil[key] or 0) then
        return false
    end

    local existing = downloadQueue[key]
    if not existing or priority < existing.priority then
        if not existing and tableCount(downloadQueue) >= MAX_DOWNLOAD_QUEUE then
            local worstKey
            local worstPriority = -math.huge
            for queuedKey, queued in pairs(downloadQueue) do
                if not pendingKeys[queuedKey]
                    and queued.priority > worstPriority then
                    worstKey = queuedKey
                    worstPriority = queued.priority
                end
            end
            if not worstKey or priority >= worstPriority then return false end
            downloadQueue[worstKey] = nil
        end
        downloadQueue[key] = {
            dimension = dimension,
            chunkX = chunkX,
            chunkZ = chunkZ,
            priority = priority,
            knownChecksum = knownChecksum,
            cacheOnly = cacheOnly == true
        }
        return not existing
    end
    if existing and not cacheOnly then existing.cacheOnly = false end
    return false
end

function discoverStations()
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

function fitTerminal(text, width)
    text = tostring(text)
    if #text <= width then return text end
    return text:sub(1, math.max(0, width - 1)) .. "~"
end

function rememberStation(station)
    navConfig.lastServer = station.name or ""
    navConfig.lastServerId = station.id
    atlas.writeTable(NAV_CONFIG_PATH, navConfig)
    return station.id, station
end

function chooseStation(hasWireless, autoConnect)
    if not hasWireless then return nil, nil end
    local stations = discoverStations()
    local selected = #stations > 0 and 1 or 0
    local remembered
    for index, station in ipairs(stations) do
        if navConfig.lastServerId
            and station.id == navConfig.lastServerId then
            selected = index
            remembered = station
            break
        end
    end
    if not remembered and navConfig.lastServer ~= "" then
        for index, station in ipairs(stations) do
            if station.name == navConfig.lastServer then
                selected = index
                remembered = station
                break
            end
        end
    end
    if autoConnect and remembered then
        return rememberStation(remembered)
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
        term.setCursorPos(2, 5)
        term.setTextColor(colors.white)
        term.write("VEHICLE " .. navConfig.callsign .. "  [C] CHANGE CODE")

        local firstY = 7
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

        term.setCursorPos(2, height - 2)
        term.setBackgroundColor(colors.blue)
        term.setTextColor(colors.white)
        term.write(" CHANGE CODE ")

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
                return rememberStation(stations[selected])
            elseif event[2] == keys.escape then
                return serverId, serverInfo, "cancel"
            end
        elseif event[1] == "mouse_click" then
            local _, _, x, y = table.unpack(event, 1, event.n)
            local row = y - firstY + 1
            if row >= 1 and row <= #stations then
                selected = row
            elseif y == height - 2 and x >= 2 and x <= 14 then
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
                term.clear()
                term.setCursorPos(2, 2)
                print("VEHICLE CODE")
                term.setCursorPos(2, 4)
                write("Enter XX-NN (blank cancels): ")
                local value = read():upper()
                if validCallsign(value) then
                    navConfig.callsign = value
                    atlas.writeTable(NAV_CONFIG_PATH, navConfig)
                end
            elseif y == height - 1 and x >= 2 and x <= 10
                and stations[selected] then
                return rememberStation(stations[selected])
            elseif y == height - 1 and x >= 14 and x <= 21 then
                stations = discoverStations()
                selected = #stations > 0 and 1 or 0
            elseif y == height - 1 and x >= 25 and x <= 33 then
                return nil, nil
            end
        elseif event[1] == "char" then
            local character = event[2]:lower()
            if character == "c" then
                term.setBackgroundColor(colors.black)
                term.setTextColor(colors.white)
                term.clear()
                term.setCursorPos(2, 2)
                print("VEHICLE CODE")
                term.setCursorPos(2, 4)
                write("Enter XX-NN (blank cancels): ")
                local value = read():upper()
                if validCallsign(value) then
                    navConfig.callsign = value
                    atlas.writeTable(NAV_CONFIG_PATH, navConfig)
                end
            elseif character == "r" then
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

function zoom()
    return ZOOM_LEVELS[zoomIndex]
end

function getSample(worldX, worldZ, dimension)
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

function inspectMapPoint(mouseX, mouseY)
    local display = lastDisplayMap
    if not display or not info
        or mouseY < display.mapTop
        or mouseY >= display.mapTop + display.mapHeight then
        return false
    end

    local worldX = math.floor(display.mapViewX
        + (mouseX - display.centerX) / display.pixelsPerBlock)
    local worldZ = math.floor(display.mapViewZ
        + (mouseY - display.mapTop - display.centerY)
            / display.pixelsPerBlock)
    local surface, clearance, fluid, flags = getSample(
        worldX, worldZ, info.dimension)
    local fluidKind = flags and flags % 4 or 0
    local fluidLabel = fluidKind == 1 and "WATER"
        or fluidKind == 2 and "LAVA"
        or fluidKind == 3 and "FLUID"
        or "-"

    pointerDetails = {
        at = nowMs(),
        x = worldX,
        z = worldZ,
        text = ("MAP X:%d Z:%d SUR:%s CLR:%s FLD:%s"):format(
            worldX, worldZ, tostring(surface or "?"),
            tostring(clearance or "?"),
            fluid and (fluidLabel .. "@" .. fluid) or "-")
    }
    return true
end

function invalidateTileDependencies(dimension, chunkX, chunkZ)
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

function invalidateRenderStyle()
    renderStyleVersion = renderStyleVersion + 1
    mapCache.signature = nil
end

function installRawTile(raw, source)
    local decoded = decodeTile(raw)
    local key = tileKey(decoded.dimension, decoded.chunkX, decoded.chunkZ)
    markTerrainKnown(key, "local")
    local previous = tiles[key]
    local cached = cacheIndex.tiles[key]
    local pendingWrite = cacheWriteQueue[key]
    if source == "network" then
        if cached and cached.unsynced
            and cached.checksum ~= decoded.checksum then
            return previous
        end
        if pendingWrite and pendingWrite.unsynced
            and pendingWrite.raw.checksum ~= decoded.checksum then
            return previous
        end
    end
    tiles[key] = decoded
    retryAfter[key] = nil
    networkMissUntil[key] = nil
    if source == "network" then serverVerifiedAt[key] = nowMs() end
    if not previous then tileCount = tileCount + 1 end
    invalidateTileDependencies(decoded.dimension, decoded.chunkX, decoded.chunkZ)

    if source == "survey" then
        forceSurvey[key] = nil
        queueLocalSave(raw, true)
        queueUpload(raw)
    elseif source == "network" then
        queueLocalSave(raw, false)
    end
    return decoded
end

function loadCachedTileIfPresent(dimension, chunkX, chunkZ)
    local key = tileKey(dimension, chunkX, chunkZ)
    if tiles[key] then
        local entry = cacheIndex.tiles[key]
        local path = cacheEntryPath(entry)
        if (not path or not fs.exists(path)) and not cacheWriteQueue[key] then
            queueLocalSave(tiles[key].raw, uploadQueue[key] ~= nil)
        end
        return false
    end
    local raw = loadLocalRaw(dimension, chunkX, chunkZ)
    if not raw then return false end
    installRawTile(raw, "disk")
    return true
end

function scanDirection()
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

function rebuildScanPlan(infoValue)
    local directionX, directionZ = scanDirection()
    local radius = infoValue.maxChunkRadius
    local highSpeed = motion.speed >= 8
    local horizonChunks = clamp(
        math.ceil((motion.speed * 8 + 32) / 16), 3, radius)
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
                local forward = dx * directionX + dz * directionZ
                local cross = math.abs(dx * directionZ - dz * directionX)
                local corridorWidth = 1.25 + math.max(0, forward) * 0.28

                if distance <= 1.5 then score = score - 20000 end

                if distance > 0 then
                    if forward > 0 and cross <= corridorWidth then
                        score = score - (highSpeed and 16000 or 7000)
                        score = score - forward * (highSpeed and 420 or 140)
                        score = score + cross * 300
                        if forward <= horizonChunks then
                            score = score - 1200
                        end
                    elseif highSpeed then
                        score = score + 8000
                        if forward < -1 then score = score + 10000 end
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
                    score = score,
                    forward = forward,
                    cross = cross
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

function prepareScanPlan(infoValue)
    local waypoint = nextWaypoint()
    local direction = math.floor((motion.track or 0) / 15)
    local speedBand = math.floor((motion.speed or 0) / 4)
    local signature = table.concat({
        infoValue.chunkX,
        infoValue.chunkZ,
        infoValue.maxChunkRadius,
        direction,
        speedBand,
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
end

function chooseScanBatch(infoValue, maximum)
    prepareScanPlan(infoValue)
    local currentTime = nowMs()
    local waitingForSharedMap = false
    local selected = {}
    local selectedKeys = {}
    local waitingCount = 0
    local backlog = 0
    local sharedQueued = 0

    for _, offset in ipairs(scanOffsets) do
        local chunkX = infoValue.chunkX + offset.dx
        local chunkZ = infoValue.chunkZ + offset.dz
        local key = tileKey(infoValue.dimension, chunkX, chunkZ)
        local tile = tiles[key]
        local retryTime = retryAfter[key] or 0
        local forced = forceSurvey[key]

        if not tile and not forced then
            local cached = loadLocalRaw(
                infoValue.dimension, chunkX, chunkZ)
            if cached then
                tile = installRawTile(cached, "disk")
            end
        end

        if not tile and currentTime >= retryTime then
            local stationConfirmedMissing =
                currentTime < (networkMissUntil[key] or 0)
            if forced or stationConfirmedMissing
                or not serverId or linkStatus == "LOST" then
                backlog = backlog + 1
                if #selected < maximum then
                    selected[#selected + 1] = {
                        dx = offset.dx,
                        dz = offset.dz,
                        chunkX = chunkX,
                        chunkZ = chunkZ,
                        score = offset.score
                    }
                    selectedKeys[key] = true
                end
            elseif serverId and linkStatus ~= "LOST"
                and not stationConfirmedMissing then
                if sharedQueued < SCAN_PREFETCH_TARGET then
                    queueDownload(
                        infoValue.dimension, chunkX, chunkZ,
                        -10000 + offset.score)
                    sharedQueued = sharedQueued + 1
                end
                waitingForSharedMap = true
                waitingCount = waitingCount + 1
            end
        end
    end

    scanMetrics.backlog = backlog
    scanMetrics.waiting = waitingCount
    return selected, selectedKeys, waitingForSharedMap
end

function recordCompletedScans(count)
    local timestamp = nowMs()
    for _ = 1, count do
        scanMetrics.completedAt[#scanMetrics.completedAt + 1] = timestamp
    end
end

function updateScanTelemetry(infoValue)
    local currentTime = nowMs()
    while scanMetrics.completedAt[1]
        and currentTime - scanMetrics.completedAt[1]
            > 5000 do
        table.remove(scanMetrics.completedAt, 1)
    end
    scanMetrics.chunksPerSecond =
        #scanMetrics.completedAt / 5

    local directionX, directionZ = scanDirection()
    local ahead = 0
    for step = 1, infoValue.maxChunkRadius do
        local chunkX = math.floor(
            infoValue.chunkX + directionX * step + 0.5)
        local chunkZ = math.floor(
            infoValue.chunkZ + directionZ * step + 0.5)
        if tiles[tileKey(infoValue.dimension, chunkX, chunkZ)] then
            ahead = step
        else
            break
        end
    end
    scanMetrics.aheadChunks = ahead
    scanMetrics.aheadSeconds = motion.speed > 0.5
        and ahead * 16 / motion.speed or 0
end

function scanLegacy(infoValue)
    for _ = 1, 4 do
        local selected, _, waitingForSharedMap =
            chooseScanBatch(infoValue, 1)
        local offset = selected[1]
        if not offset then
            scanStatus = waitingForSharedMap
                and "SYNCING SHARED MAP" or "CURRENT"
            return
        end

        scanStatus = ("SCAN %d %d"):format(offset.dx, offset.dz)
        local key = tileKey(
            infoValue.dimension, offset.chunkX, offset.chunkZ)
        local ok, rawOrError = pcall(
            surveyor.scanChunk, offset.dx, offset.dz)
        if not ok then
            retryAfter[key] = nowMs() + RETRY_MS
            scanStatus = "WAITING"
            return
        end
        installRawTile(rawOrError, "survey")
        recordCompletedScans(1)
    end
    scanStatus = "LEGACY SCAN"
end

function markBatchOffsetsForRetry(
        entries, originChunkX, originChunkZ, delay)
    if type(entries) ~= "table" then return end
    for _, offset in ipairs(entries) do
        if type(offset) == "table"
            and type(offset.dx) == "number"
            and type(offset.dz) == "number" then
            local chunkX = tonumber(offset.chunkX)
                or originChunkX + offset.dx
            local chunkZ = tonumber(offset.chunkZ)
                or originChunkZ + offset.dz
            local key = tileKey(
                info.dimension,
                chunkX,
                chunkZ)
            retryAfter[key] = nowMs() + delay
        end
    end
end

function scanAvailable(infoValue)
    if infoValue.ready == false then
        scanStatus = "SCANNER BUSY"
        return
    end

    local supportsBatch = infoValue.supportsBatch
        and type(surveyor.scanBatch) == "function"
    scanMetrics.batchSupported = supportsBatch
    if not supportsBatch then
        scanLegacy(infoValue)
        updateScanTelemetry(infoValue)
        return
    end

    local maximum = clamp(
        navConfig.scanBatchChunks,
        1,
        tonumber(infoValue.maxBatchChunks) or 16)
    if motion.speed >= 8 then
        maximum = tonumber(infoValue.maxBatchChunks) or 16
    elseif motion.speed >= 4 then
        maximum = math.max(maximum, math.min(
            12, tonumber(infoValue.maxBatchChunks) or 16))
    end
    local maxRequests = tonumber(infoValue.maxBatchRequests)
        or DEFAULT_SCAN_REQUEST_WINDOW
    local requestWindow
    if motion.speed >= 8 then
        requestWindow = maxRequests
    elseif motion.speed >= 4 then
        requestWindow = math.min(64, maxRequests)
    else
        requestWindow = math.min(DEFAULT_SCAN_REQUEST_WINDOW, maxRequests)
    end
    requestWindow = math.max(maximum, requestWindow)
    local selected, selectedKeys, waitingForSharedMap =
        chooseScanBatch(infoValue, requestWindow)
    if #selected == 0 then
        scanStatus = waitingForSharedMap
            and "SYNCING SHARED MAP" or "CURRENT"
        updateScanTelemetry(infoValue)
        return
    end

    scanStatus = ("BATCH %d"):format(#selected)
    local requests = {}
    for _, offset in ipairs(selected) do
        requests[#requests + 1] = {
            dx = offset.dx,
            dz = offset.dz,
            chunkX = offset.chunkX,
            chunkZ = offset.chunkZ
        }
    end

    local ok, result = pcall(
        surveyor.scanBatch,
        requests,
        maximum,
        motion.speed >= 8
            and (tonumber(infoValue.maxScanBudgetMicros) or 8000)
            or navConfig.scanBudgetMicros)
    if not ok or type(result) ~= "table" then
        for _, offset in ipairs(selected) do
            local key = tileKey(
                infoValue.dimension, offset.chunkX, offset.chunkZ)
            retryAfter[key] = nowMs() + RETRY_MS
        end
        scanStatus = "BATCH ERROR"
        updateScanTelemetry(infoValue)
        return
    end

    local completed = 0
    for _, raw in ipairs(type(result.tiles) == "table"
        and result.tiles or {}) do
        local key = type(raw) == "table"
            and tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
        if key and selectedKeys[key] then
            local installed = pcall(installRawTile, raw, "survey")
            if installed then completed = completed + 1 end
        end
    end

    local originChunkX = tonumber(result.chunkX) or infoValue.chunkX
    local originChunkZ = tonumber(result.chunkZ) or infoValue.chunkZ
    local unloadedCount = type(result.unloaded) == "table"
        and #result.unloaded or 0
    markBatchOffsetsForRetry(
        result.unloaded,
        originChunkX,
        originChunkZ,
        motion.speed >= 8 and 100 or UNLOADED_RETRY_MS)
    scanMetrics.lastBatchChunks = completed
    scanMetrics.lastBatchRequests =
        tonumber(result.requested) or #selected
    scanMetrics.lastBatchInspected =
        tonumber(result.inspected) or 0
    scanMetrics.lastBatchUnloaded = unloadedCount
    scanMetrics.lastBatchMicros = tonumber(result.elapsedMicros) or 0
    recordCompletedScans(completed)
    scanStatus = completed > 0
        and ("BATCH +%d/%d"):format(completed, #selected)
        or unloadedCount > 0
            and "WAITING FOR CHUNKS"
        or "BUDGET WAIT"
    updateScanTelemetry(infoValue)
end

function tileSampleColor(tile, eastTile, southTile, localX, localZ)
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

function renderedPixelsFor(tile)
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

function drawPixel(x, y, color, width, height)
    if x >= 0 and x < width and y >= 0 and y < height then
        term.setPixel(x, y, color)
    end
end

function drawText(x, y, text, color, width, height)
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

function fitText(text, width)
    local maximum = math.max(0, math.floor((width - 4) / 4))
    if #text <= maximum then return text end
    return text:sub(1, math.max(0, maximum - 1)) .. "?"
end

function drawToolbarButton(
        buttons, x, y, label, action, width, height)
    local buttonWidth = #label * 4 + 7
    term.drawPixels(x, y, COLOR.panelEdge, buttonWidth, 7)
    drawText(x + 4, y + 1, label, COLOR.text, width, height)
    buttons[#buttons + 1] = {
        x1 = x,
        x2 = x + buttonWidth - 1,
        y1 = y,
        y2 = y + 6,
        action = action
    }
    return x + buttonWidth + 2
end

function drawCompanionPairDialog(width, height)
    if not pairDialog or not companionHost then return end
    local pairing = companionHost:pairingStatus()
    if not pairing then
        pairDialog = nil
        scanStatus = "COMPANION PAIRED OR CODE EXPIRED"
        return
    end

    local dialogWidth = math.min(236, width - 20)
    local dialogHeight = 82
    local left = math.floor((width - dialogWidth) / 2)
    local top = math.floor((height - dialogHeight) / 2)
    term.drawPixels(left, top, COLOR.panelEdge, dialogWidth, dialogHeight)
    term.drawPixels(
        left + 2, top + 2, COLOR.panel,
        dialogWidth - 4, dialogHeight - 4)
    drawText(left + 10, top + 9, "PAIR ATLAS COMPANION",
        COLOR.text, width, height)
    drawText(left + 10, top + 24, "ENTER THIS CODE ON THE POCKET",
        COLOR.textDim, width, height)
    drawText(left + 72, top + 39, pairing.code,
        COLOR.route, width, height)
    local seconds = math.max(0,
        math.ceil((pairing.expiresAt - nowMs()) / 1000))
    drawText(left + 10, top + 55,
        ("EXPIRES IN %dS"):format(seconds),
        COLOR.textDim, width, height)
    local cancelWidth = 54
    local cancelLeft = left + dialogWidth - cancelWidth - 10
    local cancelTop = top + dialogHeight - 17
    term.drawPixels(
        cancelLeft, cancelTop, COLOR.warning, cancelWidth, 9)
    drawText(cancelLeft + 7, cancelTop + 2, "CANCEL",
        COLOR.background, width, height)
    pairDialog.cancel = {
        x1 = cancelLeft,
        x2 = cancelLeft + cancelWidth - 1,
        y1 = cancelTop,
        y2 = cancelTop + 8
    }
end

function handleCompanionPairEvent(event)
    if not pairDialog then return false end
    if event[1] == "key" and event[2] == keys.escape then
        companionHost:cancelPairing()
        pairDialog = nil
        scanStatus = "PAIRING CANCELLED"
    elseif event[1] == "mouse_click" and pairDialog.cancel then
        local x = event[3]
        local y = event[4]
        local bounds = pairDialog.cancel
        if x >= bounds.x1 and x <= bounds.x2
            and y >= bounds.y1 and y <= bounds.y2 then
            companionHost:cancelPairing()
            pairDialog = nil
            scanStatus = "PAIRING CANCELLED"
        end
    end
    return true
end

function drawAircraft(
        screenX, screenY, heading, width, height, warning)
    local edge = COLOR.aircraftEdge
    local fill = warning and COLOR.warning or COLOR.aircraft
    local radians = math.rad(heading or 0)
    local forwardX = math.sin(radians)
    local forwardY = -math.cos(radians)
    local rightX = math.cos(radians)
    local rightY = math.sin(radians)

    -- Filled 12-pixel-long triangle: a sharp nose and a broad trailing edge.
    for longitudinal = -4, 7 do
        local halfWidth = (7 - longitudinal) / 11 * 4
        local integerWidth = math.floor(halfWidth + 0.5)
        for lateral = -integerWidth, integerWidth do
            local x = math.floor(screenX
                + forwardX * longitudinal + rightX * lateral + 0.5)
            local y = math.floor(screenY
                + forwardY * longitudinal + rightY * lateral + 0.5)
            local outline = longitudinal == -4 or longitudinal == 7
                or math.abs(lateral) == integerWidth
            drawPixel(x, y, outline and edge or fill, width, height)
        end
    end
end

function drawLine(x0, y0, x1, y1, color, width, height)
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

function worldToScreen(
        worldX, worldZ, mapViewX, mapViewZ,
        pixelsPerBlock, centerX, centerY, mapTop)
    return centerX + (worldX - mapViewX) * pixelsPerBlock,
        mapTop + centerY + (worldZ - mapViewZ) * pixelsPerBlock
end

function drawNavigationOverlay(
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

    for id, poi in pairs(pois) do
        if poi.dimension == info.dimension then
            local x, y = worldToScreen(
                poi.x, poi.z, mapViewX, mapViewZ,
                pixelsPerBlock, centerX, centerY, mapTop)
            x, y = math.floor(x + 0.5), math.floor(y + 0.5)
            for offset = -3, 3 do
                local widthAtRow = 3 - math.abs(offset)
                for across = -widthAtRow, widthAtRow do
                    drawPixel(x + across, y + offset,
                        COLOR.poi, width, height)
                end
            end
            if id == selectedPoiId then
                drawPixel(x, y - 5, COLOR.text, width, height)
                drawPixel(x - 5, y, COLOR.text, width, height)
                drawPixel(x + 5, y, COLOR.text, width, height)
                drawPixel(x, y + 5, COLOR.text, width, height)
            end
            if pixelsPerBlock >= 0.5 or id == selectedPoiId then
                drawText(x + 6, y - 2,
                    poi.name or "POI", COLOR.poi, width, height)
            end
        end
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

function buildMapRows(request)
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

function blankRows(width, height)
    local key = width .. ":" .. height
    local rows = blankRowsCache[key]
    if rows then return rows end

    rows = {}
    local row = string.rep(BYTE[COLOR.unknown], width)
    for y = 1, height do rows[y] = row end
    blankRowsCache[key] = rows
    return rows
end

function requestMapBuild(request)
    if mapCache.signature == request.signature then return end
    if mapBuildRequest and mapBuildRequest.signature == request.signature then return end
    mapBuildRequest = request
    os.queueEvent(MAP_BUILD_EVENT)
end

function render()
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
    local mobileCount = companionHost and companionHost:sessionCount() or 0
    local header = ("ATLAS NAV %s LINK:%s MOB:%d %s"):format(
        navConfig.callsign, linkStatus, mobileCount, networkLabel)
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
    local detailActive = pointerDetails
        and nowMs() - pointerDetails.at < 5000
    drawText(2, footerY,
        fitText(detailActive and pointerDetails.text or routeLine, width),
        (detailActive or waypoint) and COLOR.text or COLOR.textDim,
        width, height)
    local stationTiles = serverInfo and serverInfo.tiles or "?"
    local status = (
        "CACHE:%d/%s POI:%d V:%d FREE:%s UP:%d DOWN:%d WRITE:%d NET:%s"):format(
        tableCount(cacheIndex.tiles), tostring(stationTiles),
        tableCount(pois), cacheStorage.volumes,
        atlas.formatBytes(cacheStorage.free),
        tableCount(uploadQueue), tableCount(downloadQueue),
        tableCount(cacheWriteQueue), linkStatus)
    local scannerStatus = (
        "SCAN %.1f/S Q:%d AHEAD:%.1fs %s"):format(
        scanMetrics.chunksPerSecond,
        scanMetrics.backlog + scanMetrics.waiting,
        scanMetrics.aheadSeconds,
        scanStatus)
    local scannerX = math.max(2, width - #scannerStatus * 4 - 1)
    drawText(2, footerY + 7,
        fitText(status, scannerX - 4), COLOR.textDim, width, height)
    drawText(scannerX, footerY + 7,
        scannerStatus, COLOR.textDim, width, height)
    local toolbarY = footerY + 13
    local toolbarButtons = {}
    local toolbarX = 2
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "+", "zoom_in", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "-", "zoom_out", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "WP", "waypoint", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "POI", "poi", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "GO", "poi_route", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "PDEL", "poi_delete", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "NEXT", "next", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "DEL", "delete", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "CTR", "center", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "HOME", "home", width, height)
    toolbarX = drawToolbarButton(
        toolbarButtons, toolbarX, toolbarY, "PAIR", "pair", width, height)
    drawText(toolbarX + 2, footerY + 14,
        fitText("LCLICK WP  MCLICK POI  CLICK POI SELECT",
            width - toolbarX - 2),
        COLOR.textDim, width, height)
    lastDisplayMap.buttons = toolbarButtons

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
    drawAircraft(aircraftX, aircraftY, motion.heading,
        width, height, terrainWarning)
    drawPoiContextMenu(width, height)
    drawPoiDialog(width, height)
    drawCompanionPairDialog(width, height)
    term.setFrozen(false)
end

function changeZoom(direction)
    local previous = zoomIndex
    zoomIndex = clamp(zoomIndex + direction, 1, #ZOOM_LEVELS)
    if zoomIndex ~= previous then invalidateRenderStyle() end
end

function pan(dx, dz)
    follow = false
    local amount = math.max(1, math.floor(24 / zoom()))
    viewX = viewX + dx * amount
    viewZ = viewZ + dz * amount
end

function returnHomeView()
    follow = true
    pointerDetails = nil
    if info then
        viewX = info.x
        viewZ = info.z
    end
end

function refreshInfo()
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
            saveRoute(true)
        end
    end

    scanAvailable(info)
    return true
end

function sendPending(operation, payload, pending)
    if not serverId then return false end
    local requestId = atlas.requestId()
    payload.requestId = requestId
    payload.writeKey = navConfig.writeKey
    if not atlas.send(serverId, operation, payload) then return false end
    pending.sentAt = nowMs()
    pending.requestId = requestId
    pendingNetwork[requestId] = pending
    if pending.key then pendingKeys[pending.key] = requestId end
    if pending.keys then
        for _, key in ipairs(pending.keys) do
            pendingKeys[key] = requestId
        end
    end
    return true
end

function processCatalogMirror()
    if not serverId or linkStatus == "LOST" or catalogState.pending then return end
    local capabilities = serverInfo
        and type(serverInfo.capabilities) == "table"
        and serverInfo.capabilities or {}
    if not capabilities.catalog or nowMs() < catalogState.nextAt then return end

    local sent = sendPending("get_catalog", {
        cursor = catalogState.cursor,
        limit = math.min(
            CATALOG_POLICY.pageSize,
            tonumber(capabilities.catalogPageSize) or CATALOG_POLICY.pageSize)
    }, {
        type = "catalog"
    })
    if sent then catalogState.pending = true end
end

function acceptCatalogPage(message)
    catalogState.pending = false
    if type(message.entries) ~= "table"
        or type(message.revision) ~= "number" then
        catalogState.nextAt = nowMs() + 1000
        return
    end

    if catalogState.revision ~= message.revision then
        resetServerTerrainKnowledge()
        catalogState.revision = message.revision
    end
    if catalogState.cursor == 1 then
        catalogState.seen = 0
        catalogState.mirrored = 0
    end

    local currentTime = nowMs()
    for _, catalogEntry in ipairs(message.entries) do
        if type(catalogEntry) == "table"
            and type(catalogEntry.dimension) == "string"
            and type(catalogEntry.chunkX) == "number"
            and type(catalogEntry.chunkZ) == "number"
            and type(catalogEntry.checksum) == "string" then
            local key = tileKey(
                catalogEntry.dimension,
                catalogEntry.chunkX,
                catalogEntry.chunkZ)
            markTerrainKnown(key, "server")
            catalogState.seen = catalogState.seen + 1
            local cached = cacheIndex.tiles[key]
            local path = cacheEntryPath(cached)
            local pendingWrite = cacheWriteQueue[key]
            local localChecksum = cached and path and fs.exists(path)
                and cached.checksum
                or pendingWrite and pendingWrite.raw.checksum
                or tiles[key] and tiles[key].checksum
            if localChecksum == catalogEntry.checksum then
                serverVerifiedAt[key] = currentTime
                catalogState.mirrored = catalogState.mirrored + 1
                if cached and cached.unsynced then cached.unsynced = false end
                if pendingWrite then pendingWrite.unsynced = false end
                uploadQueue[key] = nil
                uploadRetry[key] = nil
                cacheDirty = true
            elseif currentTime >= (cacheEvictedUntil[key] or 0) then
                local distancePriority = 0
                if info and info.dimension == catalogEntry.dimension then
                    local dx = catalogEntry.chunkX - math.floor(info.x / 16)
                    local dz = catalogEntry.chunkZ - math.floor(info.z / 16)
                    distancePriority = math.floor(math.sqrt(dx * dx + dz * dz))
                else
                    distancePriority = 1000
                end
                queueDownload(
                    catalogEntry.dimension,
                    catalogEntry.chunkX,
                    catalogEntry.chunkZ,
                    CATALOG_POLICY.downloadPriority + distancePriority,
                    true,
                    true)
            end
        end
    end

    catalogState.total = tonumber(message.total) or catalogState.total
    if type(message.nextCursor) == "number" then
        catalogState.cursor = message.nextCursor
        catalogState.nextAt = currentTime + CATALOG_POLICY.pageDelayMs
    else
        catalogState.cursor = 1
        catalogState.nextAt = currentTime + CATALOG_POLICY.restartMs
    end
end

function scheduleUploadRetry(request, reason)
    if not request or not request.key or not request.tile then return end
    local previous = uploadRetry[request.key]
    local attempts = previous and previous.checksum == request.tile.checksum
        and previous.attempts + 1 or 1
    local delay = math.min(30000, 1000 * 2 ^ math.min(attempts - 1, 5))
    uploadRetry[request.key] = {
        checksum = request.tile.checksum,
        attempts = attempts,
        after = nowMs() + delay,
        reason = tostring(reason or "no acknowledgement")
    }
    scanStatus = ("SYNC RETRY %ds"):format(math.ceil(delay / 1000))
end

function nextQueuedDownload()
    local choiceKey
    local choice
    for key, request in pairs(downloadQueue) do
        if not pendingKeys[key]
            and nowMs() >= (request.notBefore or 0)
            and (not choice or request.priority < choice.priority) then
            choiceKey, choice = key, request
        end
    end
    return choiceKey, choice
end

function nextQueuedDownloads(limit)
    local choices = {}
    for key, request in pairs(downloadQueue) do
        if not pendingKeys[key]
            and nowMs() >= (request.notBefore or 0) then
            choices[#choices + 1] = { key = key, request = request }
        end
    end
    table.sort(choices, function(a, b)
        if a.request.priority == b.request.priority then
            return a.key < b.key
        end
        return a.request.priority < b.request.priority
    end)
    while #choices > limit do table.remove(choices) end
    return choices
end

function processNetworkQueue()
    if not serverId or linkStatus == "LOST" then return end

    local capabilities = serverInfo
        and type(serverInfo.capabilities) == "table"
        and serverInfo.capabilities or {}
    if capabilities.bulkUploads then
        local inFlightUploads = 0
        for _, pending in pairs(pendingNetwork) do
            if pending.type == "upload_batch" then
                inFlightUploads = inFlightUploads + 1
            end
        end
        if inFlightUploads < 3 then
            local keys = {}
            local rawTiles = {}
            local tilesByKey = {}
            local maximum = math.min(
                DOWNLOAD_BATCH_SIZE,
                tonumber(capabilities.maxBulkUploads)
                    or DOWNLOAD_BATCH_SIZE)
            for key, raw in pairs(uploadQueue) do
                local retry = uploadRetry[key]
                if not pendingKeys[key]
                    and (not retry or nowMs() >= retry.after) then
                    keys[#keys + 1] = key
                    rawTiles[#rawTiles + 1] = raw
                    tilesByKey[key] = raw
                    if #keys >= maximum then break end
                end
            end
            if #keys > 0 then
                sendPending("put_tiles", {
                    tiles = rawTiles
                }, {
                    type = "upload_batch",
                    keys = keys,
                    tiles = tilesByKey
                })
                return
            end
        end
    end

    if not capabilities.bulkUploads then
        for key, raw in pairs(uploadQueue) do
            local retry = uploadRetry[key]
            if not pendingKeys[key]
                and (not retry or nowMs() >= retry.after) then
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
    end

    local inFlightDownloads = 0
    local inFlightWindows = 0
    for _, pending in pairs(pendingNetwork) do
        if pending.type == "download"
            or pending.type == "download_batch"
            or pending.type == "download_window" then
            inFlightDownloads = inFlightDownloads + 1
            if pending.type == "download_window" then
                inFlightWindows = inFlightWindows + 1
            end
        end
    end
    if inFlightDownloads >= MAX_IN_FLIGHT_DOWNLOADS then return end

    if capabilities.tileWindows and inFlightWindows > 0 then return end
    if capabilities.tileWindows and inFlightDownloads == 0 then
        local windowSize = math.min(
            DOWNLOAD_WINDOW_SIZE,
            tonumber(capabilities.maxWindowTiles)
                or DOWNLOAD_WINDOW_SIZE)
        local choices = nextQueuedDownloads(windowSize)
        if #choices > 0 then
            local requests = {}
            local requestByKey = {}
            local keys = {}
            for _, choice in ipairs(choices) do
                local request = choice.request
                requests[#requests + 1] = {
                    dimension = request.dimension,
                    chunkX = request.chunkX,
                    chunkZ = request.chunkZ,
                    checksum = request.knownChecksum
                }
                requestByKey[choice.key] = request
                keys[#keys + 1] = choice.key
            end
            sendPending("get_tile_window", {
                tiles = requests
            }, {
                type = "download_window",
                keys = keys,
                requests = requestByKey,
                receivedSegments = {},
                receivedCount = 0
            })
            return
        end
    end

    local bulkSupported = serverInfo
        and type(serverInfo.capabilities) == "table"
        and serverInfo.capabilities.bulkTiles
    if bulkSupported then
        local choices = nextQueuedDownloads(DOWNLOAD_BATCH_SIZE)
        if #choices > 0 then
            local requests = {}
            local requestByKey = {}
            local keys = {}
            for _, choice in ipairs(choices) do
                local request = choice.request
                requests[#requests + 1] = {
                    dimension = request.dimension,
                    chunkX = request.chunkX,
                    chunkZ = request.chunkZ,
                    checksum = request.knownChecksum
                }
                requestByKey[choice.key] = request
                keys[#keys + 1] = choice.key
            end
            sendPending("get_tiles", {
                tiles = requests
            }, {
                type = "download_batch",
                keys = keys,
                requests = requestByKey
            })
            return
        end
    end

    local key, request = nextQueuedDownload()
    if request then
        sendPending("get_tile", {
            dimension = request.dimension,
            chunkX = request.chunkX,
            chunkZ = request.chunkZ,
            checksum = request.knownChecksum
        }, {
            type = "download",
            key = key,
            request = request
        })
    end
end

function clearPending(request)
    pendingNetwork[request.requestId] = nil
    if request.key and pendingKeys[request.key] == request.requestId then
        pendingKeys[request.key] = nil
    end
    if request.keys then
        for _, key in ipairs(request.keys) do
            if pendingKeys[key] == request.requestId then
                pendingKeys[key] = nil
            end
        end
    end
end

function acceptNetworkTile(raw, request)
    if request and request.cacheOnly then
        local valid = atlas.validateTile(raw)
        if not valid then return false end
        local key = tileKey(raw.dimension, raw.chunkX, raw.chunkZ)
        local cached = cacheIndex.tiles[key]
        local pendingWrite = cacheWriteQueue[key]
        if cached and cached.unsynced and cached.checksum ~= raw.checksum then
            return false
        end
        if pendingWrite and pendingWrite.unsynced
            and pendingWrite.raw.checksum ~= raw.checksum then
            return false
        end
        queueLocalSave(raw, false, true)
        serverVerifiedAt[key] = nowMs()
        return true
    end
    local ok = pcall(installRawTile, raw, "network")
    return ok
end

function handleDownloadItem(item, key, request)
    if item.status == "data" and item.tile then
        local ok = acceptNetworkTile(item.tile, request)
        if ok then downloadQueue[key] = nil end
    elseif item.status == "current" then
        downloadQueue[key] = nil
        serverVerifiedAt[key] = nowMs()
    elseif item.status == "missing" then
        downloadQueue[key] = nil
        local localTile = tiles[key]
        local raw = localTile and localTile.raw
            or loadLocalRaw(
                request.dimension, request.chunkX, request.chunkZ)
        if raw then
            queueUpload(raw)
        else
            forgetTerrainKnown(key, "server")
            networkMissUntil[key] = nowMs() + NETWORK_MISS_MS
        end
    elseif item.status == "unavailable" then
        request.notBefore = nowMs() + 3000
        scanStatus = "SHARED TILE OFFLINE"
    end
end

function handleNetworkMessage(sender, message)
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
    if pending.type == "download_window"
        and message.op == "tiles_segment"
        and type(message.segment) == "number"
        and type(message.segments) == "number"
        and type(message.items) == "table" then
        pending.sentAt = nowMs()
        local segment = message.segment
        if not pending.receivedSegments[segment] then
            pending.receivedSegments[segment] = true
            pending.receivedCount = pending.receivedCount + 1
            pending.segmentCount = message.segments
            for _, item in ipairs(message.items) do
                if type(item) == "table"
                    and type(item.dimension) == "string"
                    and type(item.chunkX) == "number"
                    and type(item.chunkZ) == "number" then
                    local key = tileKey(
                        item.dimension, item.chunkX, item.chunkZ)
                    local request = pending.requests[key]
                    if request then
                        handleDownloadItem(item, key, request)
                    end
                end
            end
        end
        atlas.send(serverId, "tiles_segment_ack", {
            requestId = pending.requestId,
            segment = segment
        })
        if pending.receivedCount >= message.segments then
            clearPending(pending)
        end
        return
    end
    clearPending(pending)

    if pending.type == "poi_list" then
        if message.op == "pois_current" then
            poiSourceId = serverId
            scanStatus = ("SHARED POIS CURRENT:%d"):format(tableCount(pois))
        elseif message.op == "pois_data"
            and installPoiList(message.pois, message.revision) then
            scanStatus = ("SHARED POIS SYNCED:%d"):format(tableCount(pois))
        else
            scanStatus = "POI SYNC FAILED"
        end
    elseif pending.type == "poi_put" then
        if message.op == "poi_stored" and validPoi(message.poi) then
            pois[message.poi.id] = message.poi
            poiRevision = tonumber(message.revision) or poiRevision
            poiSourceId = serverId
            savePoiCache()
            selectPoi(message.poi.id)
            scanStatus = "SHARED POI SAVED"
        else
            scanStatus = "POI SAVE FAILED: "
                .. tostring(message.reason or message.op)
        end
    elseif pending.type == "poi_delete" then
        if message.op == "poi_deleted" then
            local deletedId = message.poiId or pending.poiId
            if deletedId then pois[deletedId] = nil end
            poiRevision = tonumber(message.revision) or poiRevision
            poiSourceId = serverId
            if selectedPoiId == deletedId then
                selectedPoiId = nil
                pointerDetails = nil
            end
            savePoiCache()
            scanStatus = "SHARED POI DELETED"
        else
            scanStatus = "POI DELETE FAILED: "
                .. tostring(message.reason or message.op)
        end
    elseif pending.type == "upload_batch" then
        local handled = {}
        if message.op == "tiles_stored"
            and type(message.items) == "table" then
            for _, item in ipairs(message.items) do
                if type(item) == "table"
                    and type(item.dimension) == "string"
                    and type(item.chunkX) == "number"
                    and type(item.chunkZ) == "number" then
                    local key = tileKey(
                        item.dimension, item.chunkX, item.chunkZ)
                    local raw = pending.tiles[key]
                    if raw then
                        handled[key] = true
                        if item.status == "stored"
                            or item.status == "duplicate" then
                            markSynced(raw)
                        else
                            scheduleUploadRetry({
                                key = key,
                                tile = raw
                            }, item.reason or item.status)
                        end
                    end
                end
            end
        end
        for key, raw in pairs(pending.tiles) do
            if not handled[key] then
                scheduleUploadRetry({
                    key = key,
                    tile = raw
                }, message.reason or message.status or "incomplete batch reply")
            end
        end
    elseif pending.type == "catalog" then
        if message.op == "catalog_page" then
            acceptCatalogPage(message)
        else
            catalogState.pending = false
            catalogState.nextAt = nowMs() + 1000
        end
    elseif pending.type == "offer" then
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
        elseif message.op == "denied"
            or message.op == "deferred"
            or message.op == "tile_error" then
            scheduleUploadRetry(pending, message.reason or message.op)
        end
    elseif pending.type == "upload" then
        if message.op == "tile_stored" then
            markSynced(pending.tile)
        elseif message.op == "denied"
            or message.op == "deferred"
            or message.op == "tile_error" then
            scheduleUploadRetry(pending, message.reason or message.op)
        end
    elseif pending.type == "download" then
        if message.op == "tile_data" and message.tile then
            handleDownloadItem({
                status = "data",
                tile = message.tile
            }, pending.key, pending.request)
        elseif message.op == "tile_current" then
            handleDownloadItem({
                status = "current"
            }, pending.key, pending.request)
        elseif message.op == "tile_missing" then
            handleDownloadItem({
                status = "missing"
            }, pending.key, pending.request)
        elseif message.op == "tile_unavailable" then
            handleDownloadItem({
                status = "unavailable"
            }, pending.key, pending.request)
        end
    elseif pending.type == "download_batch"
        and message.op == "tiles_data"
        and type(message.items) == "table" then
        for _, item in ipairs(message.items) do
            if type(item) == "table"
                and type(item.dimension) == "string"
                and type(item.chunkX) == "number"
                and type(item.chunkZ) == "number" then
                local key = tileKey(
                    item.dimension, item.chunkX, item.chunkZ)
                if pending.requests[key] then
                    handleDownloadItem(
                        item, key, pending.requests[key])
                end
            end
        end
    end
end

function expireNetworkRequests()
    local currentTime = nowMs()
    for _, request in pairs(pendingNetwork) do
        if currentTime - request.sentAt > NETWORK_TIMEOUT_MS then
            clearPending(request)
            if request.type == "offer" or request.type == "upload" then
                scheduleUploadRetry(request, "network timeout")
            elseif request.type == "upload_batch" then
                for key, raw in pairs(request.tiles) do
                    scheduleUploadRetry({
                        key = key,
                        tile = raw
                    }, "network timeout")
                end
            elseif request.type == "catalog" then
                catalogState.pending = false
                catalogState.nextAt = currentTime + 1000
            elseif request.type == "poi_list"
                or request.type == "poi_put"
                or request.type == "poi_delete" then
                scanStatus = "POI NETWORK TIMEOUT"
            end
        end
    end
end

function heartbeat()
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

function requestTraffic()
    if not serverId then return end
    sendPending("traffic_request", {}, {
        type = "traffic"
    })
end

function requestPois()
    if not serverId then return end
    local capabilities = serverInfo
        and type(serverInfo.capabilities) == "table"
        and serverInfo.capabilities or {}
    if not capabilities.sharedPois then return end
    for _, pending in pairs(pendingNetwork) do
        if pending.type == "poi_list" then return end
    end
    sendPending("get_pois", {
        revision = poiSourceId == serverId and poiRevision or nil
    }, {
        type = "poi_list"
    })
end

function queueCorridor(
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

function queueVisibleMap()
    local display = lastDisplayMap
    if not display or not info then return end

    local minimumWorldX = display.mapViewX
        - display.centerX / display.pixelsPerBlock
    local maximumWorldX = display.mapViewX
        + (display.width - 1 - display.centerX)
            / display.pixelsPerBlock
    local minimumWorldZ = display.mapViewZ
        - display.centerY / display.pixelsPerBlock
    local maximumWorldZ = display.mapViewZ
        + (display.mapHeight - 1 - display.centerY)
            / display.pixelsPerBlock
    local minimumChunkX = math.floor(minimumWorldX / 16)
    local maximumChunkX = math.floor(maximumWorldX / 16)
    local minimumChunkZ = math.floor(minimumWorldZ / 16)
    local maximumChunkZ = math.floor(maximumWorldZ / 16)
    local centerChunkX = math.floor(display.mapViewX / 16)
    local centerChunkZ = math.floor(display.mapViewZ / 16)
    local maximumRadius = math.max(
        math.abs(minimumChunkX - centerChunkX),
        math.abs(maximumChunkX - centerChunkX),
        math.abs(minimumChunkZ - centerChunkZ),
        math.abs(maximumChunkZ - centerChunkZ))

    local signature = table.concat({
        info.dimension,
        minimumChunkX, maximumChunkX,
        minimumChunkZ, maximumChunkZ,
        centerChunkX, centerChunkZ
    }, ":")
    if not viewportPrefetchState
        or viewportPrefetchState.signature ~= signature then
        viewportPrefetchState = {
            signature = signature,
            radius = 0,
            edge = 0,
            offset = 0
        }
    end

    local function nextOffset()
        local state = viewportPrefetchState
        if state.radius == 0 then
            state.radius = 1
            return 0, 0, 0
        end

        local radius = state.radius
        local edge = state.edge
        local offset = state.offset
        local dx
        local dz
        if edge == 0 then
            dx, dz = -radius + offset, -radius
        elseif edge == 1 then
            dx, dz = radius, -radius + offset
        elseif edge == 2 then
            dx, dz = radius - offset, radius
        else
            dx, dz = -radius, radius - offset
        end

        state.offset = state.offset + 1
        if state.offset >= radius * 2 then
            state.offset = 0
            state.edge = state.edge + 1
            if state.edge >= 4 then
                state.edge = 0
                state.radius = state.radius + 1
                if state.radius > maximumRadius then
                    state.radius = 0
                end
            end
        end
        return dx, dz, radius
    end

    local queued = 0
    for _ = 1, VIEWPORT_INSPECTIONS_PER_REFRESH do
        local dx, dz, radius = nextOffset()
        local chunkX = centerChunkX + dx
        local chunkZ = centerChunkZ + dz
        if chunkX >= minimumChunkX and chunkX <= maximumChunkX
            and chunkZ >= minimumChunkZ and chunkZ <= maximumChunkZ then
            local loaded = loadCachedTileIfPresent(
                info.dimension, chunkX, chunkZ)
            local requested = queueDownload(
                info.dimension, chunkX, chunkZ,
                60 + radius, true)
            if loaded or requested then
                queued = queued + 1
                if queued >= VIEWPORT_DOWNLOADS_PER_REFRESH then return end
            end
        end
    end
end

function refreshPrefetch()
    if not info or not serverId then return end
    local chunkX = math.floor(info.x / 16)
    local chunkZ = math.floor(info.z / 16)

    for dz = -CACHE_POLICY.localRadiusChunks,
            CACHE_POLICY.localRadiusChunks do
        for dx = -CACHE_POLICY.localRadiusChunks,
                CACHE_POLICY.localRadiusChunks do
            local distance = dx * dx + dz * dz
            if distance <= CACHE_POLICY.localRadiusChunks
                    * CACHE_POLICY.localRadiusChunks then
                loadCachedTileIfPresent(
                    info.dimension, chunkX + dx, chunkZ + dz)
                queueDownload(
                    info.dimension, chunkX + dx, chunkZ + dz,
                    distance, true)
            end
        end
    end

    local directionX, directionZ = scanDirection()
    local forwardHorizon = clamp(
        math.ceil(motion.speed * 20 / 16),
        CACHE_POLICY.localRadiusChunks,
        CACHE_POLICY.forwardMaxChunks)
    local perpendicularX = -directionZ
    local perpendicularZ = directionX
    for forward = 1, forwardHorizon do
        local halfWidth = math.min(12, math.ceil(2 + forward * 0.25))
        for cross = -halfWidth, halfWidth do
            local targetX = math.floor(
                chunkX + directionX * forward
                    + perpendicularX * cross + 0.5)
            local targetZ = math.floor(
                chunkZ + directionZ * forward
                    + perpendicularZ * cross + 0.5)
            queueDownload(
                info.dimension, targetX, targetZ,
                20 + forward + math.abs(cross))
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
    queueVisibleMap()
end

function cacheTileDistance(key)
    local dimension, chunkX, chunkZ =
        key:match("^(.-)|(-?%d+)|(-?%d+)$")
    chunkX, chunkZ = tonumber(chunkX), tonumber(chunkZ)
    if not info or not chunkX or dimension ~= info.dimension then
        return math.huge
    end
    local currentX = math.floor(info.x / 16)
    local currentZ = math.floor(info.z / 16)
    local best = math.sqrt(
        (chunkX - currentX) ^ 2 + (chunkZ - currentZ) ^ 2)
    for index = activeWaypoint, #waypoints do
        local waypoint = waypoints[index]
        local waypointX = math.floor(waypoint.x / 16)
        local waypointZ = math.floor(waypoint.z / 16)
        best = math.min(best, math.sqrt(
            (chunkX - waypointX) ^ 2 + (chunkZ - waypointZ) ^ 2))
    end
    return best
end

function evictCacheIfNeeded(extraBytes)
    refreshCacheVolumes(false)
    extraBytes = math.max(0, tonumber(extraBytes) or 0)
    local currentTime = nowMs()
    for _, volume in ipairs(cacheVolumes) do
        local details = atlas.capacity(volume.mount)
        if type(details.capacity) == "number"
            and type(details.free) == "number" then
            local targetFree =
                details.capacity * CACHE_POLICY.reserveFraction + extraBytes
            if details.free < targetFree then
                local candidates = {}
                for key, entry in pairs(cacheIndex.tiles) do
                    if (entry.volumeId or "computer") == volume.id
                        and not entry.unsynced
                        and not uploadQueue[key]
                        and not cacheWriteQueue[key]
                        and not pendingKeys[key] then
                        local distance = cacheTileDistance(key)
                        if distance > CACHE_POLICY.localRadiusChunks then
                            candidates[#candidates + 1] = {
                                key = key,
                                entry = entry,
                                distance = distance
                            }
                        end
                    end
                end
                table.sort(candidates, function(a, b)
                    if a.distance == b.distance then
                        return (a.entry.lastUsed or 0)
                            < (b.entry.lastUsed or 0)
                    end
                    return a.distance > b.distance
                end)
                for _, candidate in ipairs(candidates) do
                    local latest = atlas.capacity(volume.mount)
                    if type(latest.free) ~= "number"
                        or latest.free >= targetFree then break end
                    local path = cacheEntryPath(candidate.entry)
                    if path and fs.exists(path) then pcall(fs.delete, path) end
                    cacheIndex.tiles[candidate.key] = nil
                    cacheEvictedUntil[candidate.key] =
                        currentTime + CACHE_POLICY.evictionCooldownMs
                    local loaded = tiles[candidate.key]
                    if loaded then
                        tiles[candidate.key] = nil
                        tileCount = math.max(0, tileCount - 1)
                        invalidateTileDependencies(
                            loaded.dimension, loaded.chunkX, loaded.chunkZ)
                    end
                    forgetTerrainKnown(candidate.key, "local")
                    cacheDirty = true
                end
            end
        end
    end
end

function networkLoop()
    local timer = os.startTimer(NETWORK_TICK_SECONDS)
    local lastHeartbeat = 0
    local lastTraffic = 0
    local lastPois = 0
    local lastStationInfo = 0
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            return
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_LINK then
            handleNetworkMessage(event[2], event[3])
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_COMPANION_LINK
            and companionHost then
            local handled, failure = pcall(
                companionHost.handle,
                companionHost,
                event[2],
                event[3])
            if not handled then
                scanStatus = "COMPANION LINK ERROR"
            end
        elseif event[1] == "timer" and event[2] == timer then
            local currentTime = nowMs()
            if companionHost then companionHost:tick() end
            expireNetworkRequests()
            processCatalogMirror()
            processNetworkQueue()
            if currentTime - lastHeartbeat >= HEARTBEAT_MS then
                heartbeat()
                lastHeartbeat = currentTime
            end
            if currentTime - lastTraffic >= TRAFFIC_MS then
                requestTraffic()
                lastTraffic = currentTime
            end
            if currentTime - lastPois >= 1000 then
                requestPois()
                lastPois = currentTime
            end
            if serverId
                and currentTime - lastStationInfo >= STATION_INFO_MS then
                atlas.send(serverId, "station_info", {})
                lastStationInfo = currentTime
            end
            if serverId and currentTime - lastServerSeen > 5000 then
                linkStatus = "LOST"
            end
            timer = os.startTimer(NETWORK_TICK_SECONDS)
        end
    end
end

function cacheLoop()
    local lastPrefetch = 0
    local lastMaintenance = 0
    while running do
        local currentTime = nowMs()
        refreshCacheVolumes(false)

        local writes = 0
        for key, pendingWrite in pairs(cacheWriteQueue) do
            if writes >= CACHE_WRITES_PER_TICK then break end
            if currentTime >= (pendingWrite.notBefore or 0) then
                local ok, reason = saveLocalRaw(
                    pendingWrite.raw, pendingWrite.unsynced)
                if not ok and reason == "onboard cache is full"
                    and not pendingWrite.background then
                    evictCacheIfNeeded(8192)
                    ok, reason = saveLocalRaw(
                        pendingWrite.raw, pendingWrite.unsynced)
                end
                if ok then
                    cacheWriteQueue[key] = nil
                elseif reason == "onboard cache is full"
                    and pendingWrite.background then
                    cacheWriteQueue[key] = nil
                    cacheEvictedUntil[key] =
                        currentTime + CACHE_POLICY.evictionCooldownMs
                else
                    pendingWrite.attempts =
                        (pendingWrite.attempts or 0) + 1
                    pendingWrite.notBefore = currentTime
                        + math.min(5000, 250 * 2
                            ^ math.min(pendingWrite.attempts, 4))
                end
                writes = writes + 1
            end
        end

        if currentTime - lastPrefetch >= 1000 then
            refreshPrefetch()
            lastPrefetch = currentTime
        end
        if currentTime - lastMaintenance >= 5000 then
            for key, entry in pairs(cacheIndex.tiles) do
                if entry.unsynced and not uploadQueue[key] then
                    local path = cacheEntryPath(entry)
                    local raw = path and atlas.loadTile(path)
                    if raw then uploadQueue[key] = raw end
                end
            end
            evictCacheIfNeeded()
            if cacheDirty then
                atlas.writeTable(CACHE_META_PATH, cacheIndex)
                cacheDirty = false
            end
            lastMaintenance = currentTime
        end
        if not waitSeconds(0.05) then return end
    end
end

function mapBuilderLoop()
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

function sensorLoop()
    while running do
        refreshInfo()
        if not waitSeconds(UPDATE_SECONDS) then return end
    end
end

function displayLoop()
    while running do
        if not modal then render() end
        if not waitSeconds(UPDATE_SECONDS) then return end
    end
end

function addWaypoint(worldX, worldZ, altitude, name)
    waypoints[#waypoints + 1] = {
        name = name or ("WP" .. (#waypoints + 1)),
        x = math.floor(worldX + 0.5),
        z = math.floor(worldZ + 0.5),
        y = altitude
    }
    if #waypoints == 1 then activeWaypoint = 1 end
    scanPlanSignature = nil
    saveRoute(true)
    pointerDetails = nil
    scanStatus = "ADDED " .. tostring(
        waypoints[#waypoints].name or ("WP" .. #waypoints))
end

function removeWaypoint(index)
    if not waypoints[index] then return false end
    local removed = table.remove(waypoints, index)
    if #waypoints == 0 then
        activeWaypoint = 1
    elseif index < activeWaypoint then
        activeWaypoint = activeWaypoint - 1
    else
        activeWaypoint = math.min(activeWaypoint, #waypoints)
    end
    scanPlanSignature = nil
    saveRoute(true)
    scanStatus = "REMOVED " .. tostring(removed.name or ("WP" .. index))
    return true
end

function waypointAtPointer(mouseX, mouseY, display)
    local bestIndex
    local bestDistance = 9
    for index, waypoint in ipairs(waypoints) do
        local screenX = display.centerX
            + (waypoint.x - display.mapViewX) * display.pixelsPerBlock
        local screenY = display.mapTop + display.centerY
            + (waypoint.z - display.mapViewZ) * display.pixelsPerBlock
        local dx = screenX - mouseX
        local dy = screenY - mouseY
        local distance = math.sqrt(dx * dx + dy * dy)
        if distance < bestDistance then
            bestIndex = index
            bestDistance = distance
        end
    end
    return bestIndex
end

function poiAtPointer(mouseX, mouseY, display)
    local bestId
    local bestDistance = 11
    for id, poi in pairs(pois) do
        if not info or poi.dimension == info.dimension then
            local screenX = display.centerX
                + (poi.x - display.mapViewX) * display.pixelsPerBlock
            local screenY = display.mapTop + display.centerY
                + (poi.z - display.mapViewZ) * display.pixelsPerBlock
            local dx = screenX - mouseX
            local dy = screenY - mouseY
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance < bestDistance then
                bestId = id
                bestDistance = distance
            end
        end
    end
    return bestId
end

function selectPoi(identifier)
    local poi = identifier and pois[identifier]
    selectedPoiId = poi and identifier or nil
    if poi then
        pointerDetails = {
            at = nowMs(),
            x = poi.x,
            z = poi.z,
            text = ("POI %s [%s] X:%d%s Z:%d"):format(
                poi.name or "POINT", poi.category or "GENERAL",
                poi.x, poi.y and (" Y:" .. poi.y) or "", poi.z)
        }
    end
    return poi
end

function poiEditor(identifier, seedX, seedZ)
    if not serverId or linkStatus == "LOST" then
        scanStatus = "POI REQUIRES STATION LINK"
        return
    end
    local capabilities = serverInfo
        and type(serverInfo.capabilities) == "table"
        and serverInfo.capabilities or {}
    if not capabilities.sharedPois then
        scanStatus = "STATION NEEDS POI UPDATE"
        return
    end

    local existing = identifier and pois[identifier]
    local defaultX = existing and existing.x or seedX
        or (pointerDetails and pointerDetails.x)
        or (lastDisplayMap and lastDisplayMap.mapViewX)
        or (info and info.x) or 0
    local defaultZ = existing and existing.z or seedZ
        or (pointerDetails and pointerDetails.z)
        or (lastDisplayMap and lastDisplayMap.mapViewZ)
        or (info and info.z) or 0
    local defaultName = existing and existing.name
        or ("POINT " .. (tableCount(pois) + 1))
    local defaultCategory = existing and existing.category or "GENERAL"

    poiMenu = nil
    poiDialog = {
        mode = "edit",
        title = existing and "EDIT SHARED POI" or "NEW SHARED POI",
        existingId = existing and existing.id or nil,
        dimension = existing and existing.dimension
            or (info and info.dimension) or "minecraft:overworld",
        active = 1,
        fields = {
            {
                key = "name", label = "NAME",
                value = tostring(defaultName), maximum = 32
            },
            {
                key = "category", label = "CATEGORY",
                value = tostring(defaultCategory), maximum = 16
            },
            {
                key = "x", label = "X",
                value = tostring(math.floor(defaultX + 0.5)),
                maximum = 12, numeric = true
            },
            {
                key = "z", label = "Z",
                value = tostring(math.floor(defaultZ + 0.5)),
                maximum = 12, numeric = true
            },
            {
                key = "y", label = "ALT",
                value = existing and existing.y and tostring(existing.y) or "",
                maximum = 12, numeric = true
            }
        }
    }
end

function poiDialogValues()
    local result = {}
    for _, field in ipairs(poiDialog.fields or {}) do
        result[field.key] = field.value
    end
    return result
end

function savePoiDialog()
    if not poiDialog or poiDialog.mode ~= "edit" then return end
    local values = poiDialogValues()
    local x = tonumber(values.x)
    local z = tonumber(values.z)
    local y = values.y ~= "" and tonumber(values.y) or nil
    if not x or not z or values.y ~= "" and not y then
        poiDialog.error = "CHECK X Z AND ALTITUDE"
        return
    end
    local name = values.name:gsub("^%s+", ""):gsub("%s+$", "")
    local category = values.category:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        poiDialog.error = "NAME CANNOT BE EMPTY"
        return
    end
    if category == "" then category = "GENERAL" end
    local sent = sendPending("put_poi", {
        poi = {
            id = poiDialog.existingId,
            name = name,
            category = category,
            dimension = poiDialog.dimension,
            x = x,
            y = y,
            z = z
        }
    }, {
        type = "poi_put"
    })
    if sent then
        scanStatus = "SAVING SHARED POI"
        poiDialog = nil
    else
        poiDialog.error = "POI SEND FAILED"
    end
end

function deleteSelectedPoi(identifier)
    local poi = (identifier and pois[identifier])
        or (selectedPoiId and pois[selectedPoiId])
    if not poi then
        scanStatus = "SELECT A POI FIRST"
        return
    end
    if not serverId or linkStatus == "LOST" then
        scanStatus = "POI REQUIRES STATION LINK"
        return
    end
    poiMenu = nil
    poiDialog = {
        mode = "confirm_delete",
        title = "DELETE SHARED POI",
        poiId = poi.id,
        poiName = poi.name,
        x = poi.x,
        z = poi.z
    }
end

function confirmPoiDeletion()
    if not poiDialog or poiDialog.mode ~= "confirm_delete" then return end
    local identifier = poiDialog.poiId
    local sent = sendPending("delete_poi", {
        poiId = identifier
    }, {
        type = "poi_delete",
        poiId = identifier
    })
    if sent then
        scanStatus = "DELETING SHARED POI"
        poiDialog = nil
    else
        poiDialog.error = "POI SEND FAILED"
    end
end

function pointInside(x, y, bounds)
    return bounds
        and x >= bounds.x1 and x <= bounds.x2
        and y >= bounds.y1 and y <= bounds.y2
end

function drawPoiContextMenu(width, height)
    if not poiMenu or poiDialog then return end
    local poi = pois[poiMenu.poiId]
    if not poi then
        poiMenu = nil
        return
    end
    local menuWidth = 116
    local menuHeight = 29
    local x = clamp(poiMenu.anchorX, 2, width - menuWidth - 2)
    local y = clamp(poiMenu.anchorY, 2, height - menuHeight - 2)
    term.drawPixels(x, y, COLOR.panelEdge, menuWidth, menuHeight)
    term.drawPixels(x + 1, y + 1, COLOR.panel,
        menuWidth - 2, menuHeight - 2)
    drawText(x + 5, y + 5,
        fitText(poi.name or "POI", menuWidth - 10),
        COLOR.poi, width, height)
    local buttons = {}
    local buttonX = x + 5
    buttonX = drawToolbarButton(
        buttons, buttonX, y + 17, "EDIT", "edit", width, height)
    drawToolbarButton(
        buttons, buttonX, y + 17, "DELETE", "delete", width, height)
    poiMenu.bounds = {
        x1 = x, y1 = y, x2 = x + menuWidth - 1,
        y2 = y + menuHeight - 1
    }
    poiMenu.buttons = buttons
end

function drawPoiDialog(width, height)
    if not poiDialog then return end
    local editing = poiDialog.mode == "edit"
    local panelWidth = math.min(300, width - 20)
    local panelHeight = editing and 108 or 66
    local panelX = math.floor((width - panelWidth) / 2)
    local panelY = math.floor((height - panelHeight) / 2)
    term.drawPixels(panelX, panelY,
        COLOR.poi, panelWidth, panelHeight)
    term.drawPixels(panelX + 2, panelY + 2,
        COLOR.panel, panelWidth - 4, panelHeight - 4)
    drawText(panelX + 8, panelY + 7,
        poiDialog.title, COLOR.text, width, height)

    poiDialog.panel = {
        x1 = panelX, y1 = panelY,
        x2 = panelX + panelWidth - 1,
        y2 = panelY + panelHeight - 1
    }
    poiDialog.buttons = {}
    if editing then
        poiDialog.fieldBounds = {}
        local boxX = panelX + 72
        local boxWidth = panelWidth - 82
        for index, field in ipairs(poiDialog.fields) do
            local fieldY = panelY + 20 + (index - 1) * 14
            drawText(panelX + 8, fieldY + 2,
                field.label, COLOR.textDim, width, height)
            local active = index == poiDialog.active
            term.drawPixels(boxX, fieldY,
                active and COLOR.poi or COLOR.panelEdge, boxWidth, 9)
            term.drawPixels(boxX + 1, fieldY + 1,
                COLOR.background, boxWidth - 2, 7)
            local displayValue = field.value
            if active and math.floor(nowMs() / 400) % 2 == 0 then
                displayValue = displayValue .. "_"
            end
            drawText(boxX + 4, fieldY + 2,
                fitText(displayValue, boxWidth - 6),
                active and COLOR.text or COLOR.textDim, width, height)
            poiDialog.fieldBounds[index] = {
                x1 = boxX, y1 = fieldY,
                x2 = boxX + boxWidth - 1, y2 = fieldY + 8
            }
        end
        if poiDialog.error then
            drawText(panelX + 8, panelY + 91,
                fitText(poiDialog.error, panelWidth - 110),
                COLOR.warning, width, height)
        else
            drawText(panelX + 8, panelY + 91,
                "TAB FIELDS  ENTER NEXT  ESC CANCEL",
                COLOR.textDim, width, height)
        end
        local buttonX = panelX + panelWidth - 93
        buttonX = drawToolbarButton(
            poiDialog.buttons, buttonX, panelY + 96,
            "SAVE", "save", width, height)
        drawToolbarButton(
            poiDialog.buttons, buttonX, panelY + 96,
            "CANCEL", "cancel", width, height)
    else
        drawText(panelX + 8, panelY + 22,
            fitText("DELETE " .. tostring(poiDialog.poiName) .. "?",
                panelWidth - 16),
            COLOR.warning, width, height)
        drawText(panelX + 8, panelY + 31,
            fitText("THIS REMOVES IT FOR EVERY AIRCRAFT",
                panelWidth - 16),
            COLOR.textDim, width, height)
        drawText(panelX + 8, panelY + 40,
            ("X:%d Z:%d"):format(poiDialog.x, poiDialog.z),
            COLOR.textDim, width, height)
        if poiDialog.error then
            drawText(panelX + 8, panelY + 46,
                fitText(poiDialog.error, panelWidth - 110),
                COLOR.warning, width, height)
        end
        local buttonX = panelX + panelWidth - 105
        buttonX = drawToolbarButton(
            poiDialog.buttons, buttonX, panelY + 53,
            "CANCEL", "cancel", width, height)
        drawToolbarButton(
            poiDialog.buttons, buttonX, panelY + 53,
            "DELETE", "confirm_delete", width, height)
    end
end

function activatePoiDialogAction(action)
    if action == "cancel" then
        poiDialog = nil
    elseif action == "save" then
        savePoiDialog()
    elseif action == "confirm_delete" then
        confirmPoiDeletion()
    end
end

function handlePoiDialogEvent(event)
    if not poiDialog then return end
    local eventName = event[1]
    if eventName == "key" then
        local key = event[2]
        if key == keys.escape then
            poiDialog = nil
        elseif poiDialog.mode == "edit" then
            if key == keys.backspace then
                local field = poiDialog.fields[poiDialog.active]
                field.value = field.value:sub(1, -2)
                poiDialog.error = nil
            elseif key == keys.tab or key == keys.down then
                poiDialog.active = poiDialog.active % #poiDialog.fields + 1
            elseif key == keys.up then
                poiDialog.active = (poiDialog.active - 2)
                    % #poiDialog.fields + 1
            elseif key == keys.enter then
                if poiDialog.active < #poiDialog.fields then
                    poiDialog.active = poiDialog.active + 1
                else
                    savePoiDialog()
                end
            end
        end
    elseif eventName == "char" and poiDialog.mode == "edit" then
        local field = poiDialog.fields[poiDialog.active]
        local character = event[2]
        if #field.value < field.maximum
            and (not field.numeric or character:match("[%d%.%-]")) then
            field.value = field.value .. character
            poiDialog.error = nil
        end
    elseif eventName == "paste" and poiDialog.mode == "edit" then
        local field = poiDialog.fields[poiDialog.active]
        local addition = tostring(event[2]):gsub("[%c]", " ")
        if field.numeric then
            addition = addition:gsub("[^%d%.%-]", "")
        end
        field.value = (field.value .. addition):sub(1, field.maximum)
        poiDialog.error = nil
    elseif eventName == "mouse_click" then
        local x, y = event[3], event[4]
        if poiDialog.mode == "edit" then
            for index, bounds in ipairs(poiDialog.fieldBounds or {}) do
                if pointInside(x, y, bounds) then
                    poiDialog.active = index
                    return
                end
            end
        end
        for _, button in ipairs(poiDialog.buttons or {}) do
            if pointInside(x, y, button) then
                activatePoiDialogAction(button.action)
                return
            end
        end
    end
end

function openPoiMenu(identifier, x, y)
    poiDialog = nil
    poiMenu = {
        poiId = identifier,
        anchorX = x,
        anchorY = y
    }
end

function handlePoiMenuClick(x, y)
    if not poiMenu then return false end
    for _, button in ipairs(poiMenu.buttons or {}) do
        if pointInside(x, y, button) then
            local identifier = poiMenu.poiId
            local action = button.action
            poiMenu = nil
            if action == "edit" then poiEditor(identifier)
            elseif action == "delete" then deleteSelectedPoi(identifier) end
            return true
        end
    end
    poiMenu = nil
    return true
end

function waypointEditor()
    modal = true
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, false)
    restoreTextPalette()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("ATLAS WAYPOINT ENTRY")
    print()
    write("Name [WP" .. (#waypoints + 1) .. "]: ")
    local name = read()
    if name == "" then name = "WP" .. (#waypoints + 1) end
    write("X coordinate (blank cancels): ")
    local xText = read()
    if xText == "" then
        local ok, failure = pcall(term.setGraphicsMode, 2)
        if not ok then error(failure, 0) end
        configurePalette()
        invalidateRenderStyle()
        modal = false
        return
    end
    local x = tonumber(xText)
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

function openHomeMenu()
    modal = true
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, false)
    restoreTextPalette()

    local wireless = atlas.openWirelessRednet()
    local previousServerId = serverId
    local previousServerInfo = serverInfo
    local selectedId
    local selectedInfo
    local action
    if #wireless > 0 then
        selectedId, selectedInfo, action = chooseStation(true)
    else
        action = "cancel"
        scanStatus = "NO WIRELESS MODEM"
    end

    if action ~= "cancel" then
        pendingNetwork = {}
        pendingKeys = {}
        networkMissUntil = {}
        serverVerifiedAt = {}
        resetServerTerrainKnowledge()
        catalogState.revision = nil
        catalogState.cursor = 1
        catalogState.nextAt = 0
        serverId = selectedId
        serverInfo = selectedInfo
        if serverId then
            linkStatus = "ONLINE"
            lastServerSeen = nowMs()
            navConfig.lastServer = selectedInfo and selectedInfo.name or ""
        else
            linkStatus = "OFFLINE"
            navConfig.lastServer = ""
            navConfig.lastServerId = nil
        end
        atlas.writeTable(NAV_CONFIG_PATH, navConfig)
    else
        serverId = previousServerId
        serverInfo = previousServerInfo
    end

    local ok, failure = pcall(term.setGraphicsMode, 2)
    if not ok then error(failure, 0) end
    configurePalette()
    invalidateRenderStyle()
    modal = false
end

function performNavAction(action)
    if action == "zoom_in" then
        changeZoom(1)
    elseif action == "zoom_out" then
        changeZoom(-1)
    elseif action == "waypoint" then
        waypointEditor()
    elseif action == "poi" then
        poiEditor(selectedPoiId)
    elseif action == "poi_route" then
        local poi = selectedPoiId and pois[selectedPoiId]
        if poi then
            addWaypoint(poi.x, poi.z, poi.y, poi.name)
        else
            scanStatus = "SELECT A POI FIRST"
        end
    elseif action == "poi_delete" then
        deleteSelectedPoi()
    elseif action == "next" then
        if activeWaypoint < #waypoints then
            activeWaypoint = activeWaypoint + 1
            scanPlanSignature = nil
            saveRoute(true)
        end
    elseif action == "delete" then
        removeWaypoint(activeWaypoint)
    elseif action == "center" then
        returnHomeView()
    elseif action == "home" then
        openHomeMenu()
    elseif action == "pair" then
        if not companionHost then
            scanStatus = "COMPANION NEEDS A WIRELESS MODEM"
        else
            companionHost:openPairing(120000)
            pairDialog = {}
            scanStatus = "COMPANION PAIRING OPEN"
        end
    end
end

function inputLoop()
    while running do
        local event = { os.pullEventRaw() }
        local eventName = event[1]

        if eventName == "terminate" then
            running = false
            return
        elseif pairDialog then
            handleCompanionPairEvent(event)
        elseif poiDialog then
            handlePoiDialogEvent(event)
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
            elseif character == "p" then
                performNavAction("poi")
            elseif character == "e" then
                if selectedPoiId then poiEditor(selectedPoiId)
                else scanStatus = "SELECT A POI FIRST" end
            elseif character == "k" then
                deleteSelectedPoi()
            elseif character == "n" then
                performNavAction("next")
            elseif character == "x" then
                performNavAction("delete")
            elseif character == "b" then
                performNavAction("center")
            elseif character == "h" then
                calibrateHeading()
            elseif character == "q" then
                running = false
                return
            elseif character == "r" and info then
                local key = tileKey(info.dimension, info.chunkX, info.chunkZ)
                forceSurvey[key] = true
                downloadQueue[key] = nil
                networkMissUntil[key] = nil
                if tiles[key] then
                    tiles[key] = nil
                    tileCount = math.max(0, tileCount - 1)
                    invalidateTileDependencies(
                        info.dimension, info.chunkX, info.chunkZ)
                end
            end
        elseif eventName == "key" then
            local key = event[2]
            if key == keys.escape and poiMenu then
                poiMenu = nil
            elseif key == keys.left then pan(-1, 0)
            elseif key == keys.right then pan(1, 0)
            elseif key == keys.up then pan(0, -1)
            elseif key == keys.down then pan(0, 1)
            elseif key == keys.space or key == keys.escape then
                returnHomeView()
            end
        elseif eventName == "mouse_scroll" then
            inspectMapPoint(event[3], event[4])
            changeZoom(event[2] < 0 and 1 or -1)
        elseif eventName == "mouse_drag" and info then
            inspectMapPoint(event[3], event[4])
        elseif eventName == "mouse_click" and info then
            local _, button, mouseX, mouseY = table.unpack(event)
            local display = lastDisplayMap
            local handled = false
            if poiMenu then
                handled = handlePoiMenuClick(mouseX, mouseY)
            end
            if not handled and display and display.buttons then
                for _, uiButton in ipairs(display.buttons) do
                    if mouseX >= uiButton.x1 and mouseX <= uiButton.x2
                        and mouseY >= uiButton.y1 and mouseY <= uiButton.y2 then
                        performNavAction(uiButton.action)
                        handled = true
                        break
                    end
                end
            end
            if not handled and display
                and mouseY >= display.mapTop
                and mouseY < display.mapTop + display.mapHeight then
                local poiId = poiAtPointer(mouseX, mouseY, display)
                if poiId then
                    selectPoi(poiId)
                    if button == 2 then
                        openPoiMenu(poiId, mouseX, mouseY)
                    end
                    handled = true
                elseif button == 3 then
                    local worldX = display.mapViewX
                        + (mouseX - display.centerX)
                            / display.pixelsPerBlock
                    local worldZ = display.mapViewZ
                        + (mouseY - display.mapTop - display.centerY)
                            / display.pixelsPerBlock
                    selectedPoiId = nil
                    poiEditor(nil, worldX, worldZ)
                    handled = true
                end
            end
            if not handled then inspectMapPoint(mouseX, mouseY) end
            if not handled and display
                and mouseY >= display.mapTop
                and mouseY < display.mapTop + display.mapHeight then
                selectedPoiId = nil
                if button == 1 then
                    local worldX = display.mapViewX
                        + (mouseX - display.centerX)
                            / display.pixelsPerBlock
                    local worldZ = display.mapViewZ
                        + (mouseY - display.mapTop - display.centerY)
                            / display.pixelsPerBlock
                    addWaypoint(worldX, worldZ, nil)
                elseif button == 2 then
                    local waypointIndex = waypointAtPointer(
                        mouseX, mouseY, display)
                    if waypointIndex then
                        removeWaypoint(waypointIndex)
                    else
                        viewX = display.mapViewX
                            + (mouseX - display.centerX)
                                / display.pixelsPerBlock
                        viewZ = display.mapViewZ
                            + (mouseY - display.mapTop - display.centerY)
                                / display.pixelsPerBlock
                        follow = false
                    end
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

function main()
    math.randomseed(atlas.now() + os.getComputerID())
    restoreTextPalette()
    atlas.writeTable(NAV_CONFIG_PATH, navConfig)
    local wireless = atlas.openWirelessRednet()
    serverId, serverInfo = chooseStation(#wireless > 0, true)
    if not running then return end
    if serverId then
        linkStatus = "ONLINE"
        lastServerSeen = nowMs()
    else
        linkStatus = "OFFLINE"
    end
    if #wireless > 0 then startCompanionHost() end

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
if companionHost then pcall(companionHost.close, companionHost) end
pcall(term.setFrozen, false)
pcall(term.setGraphicsMode, false)
restoreTextPalette()
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
