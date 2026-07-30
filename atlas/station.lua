local LIBRARY = fs.exists("/atlas/lib.lua") and "/atlas/lib.lua" or "atlas/lib.lua"
local atlas = dofile(LIBRARY)

local CONFIG_PATH = "/atlas/station.cfg"
local POI_PATH = "/atlas/pois.dat"
local LOG_LIMIT = 80
local DRIVE_RESCAN_SECONDS = 1
local UI_REFRESH_SECONDS = 0.10
local TRAFFIC_STALE_MS = 5000
local TRAFFIC_REMOVE_MS = 15000
local MAX_BULK_REQUEST_TILES = 16
local MAX_BULK_UPLOAD_TILES = 14
local MAX_WINDOW_REQUEST_TILES = 98
local WINDOW_SEGMENT_TILES = 14
local WINDOW_SEGMENT_CONCURRENCY = 3
local WINDOW_RETRY_MS = 900
local WINDOW_MAX_ATTEMPTS = 8
local WINDOW_EXPIRE_MS = 30000
local CATALOG_PAGE_SIZE = 256
local INDEX_FLUSH_MS = 5000
local INDEX_DIRTY_MARKER = "atlas/index.dirty"

local config = atlas.readTable(CONFIG_PATH) or {}
config.name = config.name or ("ATLAS-" .. os.getComputerID())
config.writeKey = config.writeKey or ""

local running = true
local maintenance = false
local drives = {}
local volumes = {}
local tileIndex = {}
local aircraft = {}
local logs = {}
local selectedDrive = 1
local page = 1
local notice = "STARTING"
local job
local uiButtons = {}
local radioState = "NO MODEM"
local radioDetail = "No modem detected"
local hostedName
local networkHosted = false
local windowTransfers = {}
local catalogRevision = 1
local catalogKeys
local catalogDirty = true
local catalogBuiltAt = 0
local dirtyVolumeIndexes = {}
local poiStore = atlas.readTable(POI_PATH) or {}
poiStore.format = 1
poiStore.revision = tonumber(poiStore.revision) or 0
poiStore.pois = type(poiStore.pois) == "table" and poiStore.pois or {}
local stats = {
    uploads = 0,
    downloads = 0,
    duplicates = 0,
    rejected = 0
}

local PAGE_NAMES = { "OVERVIEW", "STORAGE", "TRAFFIC", "LOG" }

local function log(message, severity)
    logs[#logs + 1] = {
        at = atlas.now(),
        message = tostring(message),
        severity = severity or "INFO"
    }
    while #logs > LOG_LIMIT do table.remove(logs, 1) end
    notice = tostring(message)
end

local function tableCount(value)
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function ensureNetwork(quiet)
    local wireless = {}
    local wired = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            local okWireless, isWireless = pcall(modem.isWireless)
            if okWireless and isWireless then
                wireless[#wireless + 1] = name
            else
                wired[#wired + 1] = name
            end
            if not rednet.isOpen(name) then pcall(rednet.open, name) end
        end
    end
    table.sort(wireless)
    table.sort(wired)

    local previousState = radioState
    if #wireless > 0 then
        radioState = "WIRELESS"
        radioDetail = "Wireless: " .. table.concat(wireless, ", ")
    elseif #wired > 0 then
        radioState = "WIRED"
        radioDetail = "Wired only: " .. table.concat(wired, ", ")
    else
        radioState = "NO MODEM"
        radioDetail = "No modem detected"
    end

    if #wireless + #wired == 0 then
        if networkHosted and hostedName then
            pcall(rednet.unhost, atlas.PROTOCOL_DISCOVERY)
        end
        networkHosted = false
    elseif not networkHosted then
        local candidate = atlas.safeName(config.name)
        local hostOk = pcall(
            rednet.host, atlas.PROTOCOL_DISCOVERY, candidate)
        if not hostOk then
            candidate = atlas.safeName(
                config.name .. "-" .. os.getComputerID())
            rednet.host(atlas.PROTOCOL_DISCOVERY, candidate)
        end
        hostedName = candidate
        networkHosted = true
    end

    if not quiet and previousState ~= radioState then
        log(radioDetail, radioState == "WIRELESS" and "INFO" or "WARN")
    end
    return #wireless, #wired
end

local function isEmptyDirectory(path)
    local ok, contents = pcall(fs.list, path)
    return ok and #contents == 0
end

local function indexTemplate(volumeId)
    return {
        atlas = atlas.VERSION,
        format = atlas.VOLUME_FORMAT,
        volumeId = volumeId,
        tiles = {}
    }
end

local function walkTileFiles(root, relative, output)
    local path = relative == "" and root or fs.combine(root, relative)
    local ok, entries = pcall(fs.list, path)
    if not ok then return end
    for _, entry in ipairs(entries) do
        local childRelative = relative == "" and entry
            or fs.combine(relative, entry)
        local child = fs.combine(root, childRelative)
        if fs.isDir(child) then
            walkTileFiles(root, childRelative, output)
        elseif entry:sub(-5) == ".tile" then
            output[#output + 1] = childRelative
        end
    end
end

local function rebuildVolumeIndex(volume)
    local index = indexTemplate(volume.id)
    local root = fs.combine(volume.mount, atlas.TILE_ROOT)
    if fs.exists(root) then
        local files = {}
        walkTileFiles(root, "", files)
        for _, relativeFromTileRoot in ipairs(files) do
            local fullPath = fs.combine(root, relativeFromTileRoot)
            local tile = atlas.loadTile(fullPath)
            if tile then
                local key = atlas.tileKey(
                    tile.dimension, tile.chunkX, tile.chunkZ)
                index.tiles[key] = {
                    path = fs.combine(atlas.TILE_ROOT, relativeFromTileRoot),
                    checksum = tile.checksum,
                    storedAt = tile.storedAt or 0,
                    size = fs.getSize(fullPath)
                }
            end
        end
    end
    atlas.writeTable(fs.combine(volume.mount, atlas.VOLUME_INDEX), index)
    return index
end

local function loadVolumeIndex(volume)
    local path = fs.combine(volume.mount, atlas.VOLUME_INDEX)
    local index = atlas.readTable(path)
    local dirtyPath = fs.combine(volume.mount, INDEX_DIRTY_MARKER)
    if fs.exists(dirtyPath)
        or type(index) ~= "table"
        or index.format ~= atlas.VOLUME_FORMAT
        or index.volumeId ~= volume.id
        or type(index.tiles) ~= "table" then
        log("Rebuilding index for " .. volume.label, "WARN")
        index = rebuildVolumeIndex(volume)
        if fs.exists(dirtyPath) then pcall(fs.delete, dirtyPath) end
    end
    return index
end

local function classifyDrive(entry)
    local state = {
        name = entry.name,
        drive = entry.drive,
        status = "EMPTY",
        label = "—"
    }

    local okPresent, present = pcall(entry.drive.isDiskPresent)
    if not okPresent or not present then return state end

    local okLabel, label = pcall(entry.drive.getDiskLabel)
    if okLabel and label then state.label = label end

    local okData, hasData = pcall(entry.drive.hasData)
    if not okData or not hasData then
        state.status = "NON-DATA"
        return state
    end

    local okMount, mount = pcall(entry.drive.getMountPath)
    if not okMount or not mount then
        state.status = "UNAVAILABLE"
        return state
    end
    state.mount = mount
    state.capacity = atlas.capacity(mount)
    local okDiskId, diskId = pcall(entry.drive.getDiskID)
    if okDiskId then state.diskId = diskId end

    local meta = atlas.readTable(fs.combine(mount, atlas.VOLUME_META))
    if type(meta) == "table"
        and meta.atlas == atlas.VERSION
        and meta.format == atlas.VOLUME_FORMAT
        and type(meta.id) == "string" then
        state.status = "ONLINE"
        state.id = meta.id
        state.label = meta.label or state.label
        state.meta = meta
        return state
    end

    state.status = isEmptyDirectory(mount) and "UNFORMATTED" or "FOREIGN"
    return state
end

local function rebuildGlobalIndex()
    local nextIndex = {}
    for volumeId, volume in pairs(volumes) do
        for key, entry in pairs(volume.index.tiles) do
            local current = nextIndex[key]
            if not current or (entry.storedAt or 0) > (current.storedAt or 0) then
                nextIndex[key] = {
                    volumeId = volumeId,
                    path = entry.path,
                    checksum = entry.checksum,
                    storedAt = entry.storedAt or 0,
                    size = entry.size
                }
            end
        end
    end

    local changed = tableCount(nextIndex) ~= tableCount(tileIndex)
    if not changed then
        for key, entry in pairs(nextIndex) do
            local old = tileIndex[key]
            if not old or old.checksum ~= entry.checksum then
                changed = true
                break
            end
        end
    end
    tileIndex = nextIndex
    if changed then
        catalogDirty = true
    end
end

local function rescanDrives(quiet)
    local previousSignature = {}
    for _, driveState in ipairs(drives) do
        previousSignature[driveState.name] =
            driveState.status .. "|" .. tostring(driveState.id)
    end

    local discovered = atlas.discoverDrives()
    local nextDrives = {}
    local nextVolumes = {}
    for _, entry in ipairs(discovered) do
        local state = classifyDrive(entry)
        nextDrives[#nextDrives + 1] = state
        if state.status == "ONLINE" then
            local volume = {
                id = state.id,
                label = state.label,
                mount = state.mount,
                driveName = state.name,
                drive = state.drive,
                capacity = state.capacity,
                meta = state.meta
            }
            local existing = volumes[volume.id]
            volume.index = existing and existing.mount == volume.mount
                and existing.index or loadVolumeIndex(volume)
            state.tileCount = tableCount(volume.index.tiles)
            nextVolumes[volume.id] = volume
        end
    end

    local topologyChanged = tableCount(nextVolumes) ~= tableCount(volumes)
    if not topologyChanged then
        for volumeId, volume in pairs(nextVolumes) do
            local previous = volumes[volumeId]
            if not previous or previous.mount ~= volume.mount then
                topologyChanged = true
                break
            end
        end
    end

    drives = nextDrives
    volumes = nextVolumes
    selectedDrive = math.max(1, math.min(selectedDrive, math.max(1, #drives)))
    if topologyChanged then rebuildGlobalIndex() end

    if not quiet then
        log(("Storage scan: %d drive(s), %d volume(s)"):format(
            #drives, tableCount(volumes)))
    else
        for _, state in ipairs(drives) do
            local old = previousSignature[state.name]
            local new = state.status .. "|" .. tostring(state.id)
            if old ~= new then
                log(state.name .. " is " .. state.status)
            end
        end
    end
end

local function saveVolumeIndex(volume)
    return atlas.writeTable(
        fs.combine(volume.mount, atlas.VOLUME_INDEX), volume.index)
end

local function markVolumeIndexDirty(volume)
    if dirtyVolumeIndexes[volume.id] then return true end
    local ok, failure = atlas.writeAtomic(
        fs.combine(volume.mount, INDEX_DIRTY_MARKER),
        tostring(atlas.now()),
        false)
    if ok then dirtyVolumeIndexes[volume.id] = true end
    return ok, failure
end

local function flushVolumeIndex(volume)
    if not volume or not dirtyVolumeIndexes[volume.id] then return true end
    local ok, failure = saveVolumeIndex(volume)
    if not ok then return false, failure end
    local dirtyPath = fs.combine(volume.mount, INDEX_DIRTY_MARKER)
    if fs.exists(dirtyPath) then pcall(fs.delete, dirtyPath) end
    dirtyVolumeIndexes[volume.id] = nil
    return true
end

local function flushDirtyVolumeIndexes()
    for volumeId in pairs(dirtyVolumeIndexes) do
        local volume = volumes[volumeId]
        if volume then
            local ok, failure = flushVolumeIndex(volume)
            if not ok then
                log("Index flush failed: " .. tostring(failure), "ERROR")
            end
        end
    end
end

local function availableFree(volume)
    volume.capacity = atlas.capacity(volume.mount)
    local free = volume.capacity.free
    if free == "unlimited" then return math.huge end
    return type(free) == "number" and free or -1
end

local function chooseVolume(requiredBytes, excludedId)
    local choice
    local bestFree = -1
    for id, volume in pairs(volumes) do
        if id ~= excludedId then
            local free = availableFree(volume)
            if free >= requiredBytes and free > bestFree then
                choice = volume
                bestFree = free
            end
        end
    end
    return choice
end

local function removeOldEntry(key, oldEntry, keepVolumeId, keepPath)
    if not oldEntry then return end
    if oldEntry.volumeId == keepVolumeId and oldEntry.path == keepPath then return end

    local oldVolume = volumes[oldEntry.volumeId]
    if not oldVolume then return end
    local oldPath = fs.combine(oldVolume.mount, oldEntry.path)
    oldVolume.index.tiles[key] = nil
    saveVolumeIndex(oldVolume)
    if fs.exists(oldPath) then pcall(fs.delete, oldPath) end
end

local function storeTile(tile, excludedVolumeId, force, deferIndexWrite)
    local valid, reason = atlas.validateTile(tile)
    if not valid then return false, reason end

    local key = atlas.tileKey(tile.dimension, tile.chunkX, tile.chunkZ)
    local existing = tileIndex[key]
    if existing and existing.checksum == tile.checksum and not force then
        return true, "duplicate", existing
    end

    tile = atlas.copyTile(tile)
    tile.storedAt = atlas.now()
    local encoded, encodeFailure = atlas.encodeTile(tile)
    if not encoded then return false, encodeFailure end

    local volume = chooseVolume(#encoded + 4096, excludedVolumeId)
    if not volume then return false, "no ATLAS volume has enough free space" end
    if deferIndexWrite then
        local dirtyOk, dirtyFailure = markVolumeIndexDirty(volume)
        if not dirtyOk then return false, dirtyFailure end
    end

    local relative = atlas.tileRelativePath(tile)
    local fullPath = fs.combine(volume.mount, relative)
    local writeOk, writeFailure = atlas.writeAtomic(fullPath, encoded, false)
    if not writeOk then return false, writeFailure end

    local entry = {
        path = relative,
        checksum = tile.checksum,
        storedAt = tile.storedAt,
        size = #encoded
    }
    volume.index.tiles[key] = entry
    if not deferIndexWrite then
        local indexOk, indexFailure = saveVolumeIndex(volume)
        if not indexOk then
            pcall(fs.delete, fullPath)
            volume.index.tiles[key] = nil
            return false, indexFailure
        end
        if dirtyVolumeIndexes[volume.id] then
            local dirtyPath = fs.combine(volume.mount, INDEX_DIRTY_MARKER)
            if fs.exists(dirtyPath) then pcall(fs.delete, dirtyPath) end
            dirtyVolumeIndexes[volume.id] = nil
        end
    end

    local indexed = {
        volumeId = volume.id,
        path = relative,
        checksum = tile.checksum,
        storedAt = tile.storedAt,
        size = #encoded
    }
    tileIndex[key] = indexed
    removeOldEntry(key, existing, volume.id, relative)
    if not existing or existing.checksum ~= indexed.checksum then
        catalogDirty = true
    end
    return true, "stored", indexed
end

local function loadIndexedTile(dimension, chunkX, chunkZ)
    local key = atlas.tileKey(dimension, chunkX, chunkZ)
    local entry = tileIndex[key]
    if not entry then return nil, "missing" end
    local volume = volumes[entry.volumeId]
    if not volume then return nil, "volume offline" end
    local tile, reason = atlas.loadTile(fs.combine(volume.mount, entry.path))
    if not tile then return nil, reason end
    return tile
end

local function initialiseSelectedDrive()
    local state = drives[selectedDrive]
    if not state or state.status ~= "UNFORMATTED" then
        log("Select an empty unformatted floppy first", "WARN")
        return
    end

    local sequence = tableCount(volumes) + 1
    local label = ("ATLAS VOLUME %03d"):format(sequence)
    local meta = {
        atlas = atlas.VERSION,
        format = atlas.VOLUME_FORMAT,
        id = atlas.randomId("volume"),
        label = label,
        createdAt = atlas.now(),
        diskId = state.diskId
    }
    local ok, failure = atlas.writeTable(
        fs.combine(state.mount, atlas.VOLUME_META), meta)
    if not ok then
        log("Initialize failed: " .. tostring(failure), "ERROR")
        return
    end
    atlas.writeTable(
        fs.combine(state.mount, atlas.VOLUME_INDEX), indexTemplate(meta.id))
    pcall(state.drive.setDiskLabel, label)
    log(label .. " initialized")
    rescanDrives(true)
end

local function initialiseAllDrives()
    local targets = {}
    for _, state in ipairs(drives) do
        if state.status == "UNFORMATTED" then
            targets[#targets + 1] = state.name
        end
    end
    if #targets == 0 then
        log("No empty unformatted floppies found", "WARN")
        return
    end

    local initialized = 0
    for _, targetName in ipairs(targets) do
        for index, state in ipairs(drives) do
            if state.name == targetName and state.status == "UNFORMATTED" then
                selectedDrive = index
                initialiseSelectedDrive()
                initialized = initialized + 1
                break
            end
        end
    end
    log(("%d ATLAS volume(s) initialized"):format(initialized))
end

local function selectedVolume()
    local state = drives[selectedDrive]
    if not state or not state.id then return nil end
    return volumes[state.id]
end

local function startDrain()
    if job then
        log("Another storage job is active", "WARN")
        return
    end
    local volume = selectedVolume()
    if not volume then
        log("Select an online ATLAS volume", "WARN")
        return
    end
    if tableCount(volumes) < 2 and tableCount(volume.index.tiles) > 0 then
        log("Attach another volume before draining", "WARN")
        return
    end
    local keys = {}
    for key in pairs(volume.index.tiles) do keys[#keys + 1] = key end
    table.sort(keys)
    job = {
        type = "drain",
        volumeId = volume.id,
        keys = keys,
        index = 1,
        total = #keys,
        status = "RUNNING"
    }
    log("Draining " .. volume.label)
end

local function processJobStep()
    if not job or job.status ~= "RUNNING" then return end
    if job.index > job.total then
        local volume = volumes[job.volumeId]
        job.status = "COMPLETE"
        log((volume and volume.label or "Volume") .. " drained")
        return
    end

    local key = job.keys[job.index]
    local entry = tileIndex[key]
    if entry and entry.volumeId == job.volumeId then
        local source = volumes[job.volumeId]
        local tile = source and atlas.loadTile(fs.combine(source.mount, entry.path))
        if not tile then
            job.status = "FAILED"
            job.error = "cannot read " .. key
            log(job.error, "ERROR")
            return
        end
        local ok, reason = storeTile(tile, job.volumeId, true)
        if not ok then
            job.status = "FAILED"
            job.error = tostring(reason)
            log("Drain stopped: " .. job.error, "ERROR")
            return
        end
    end
    job.index = job.index + 1
end

local function ejectSelected()
    local state = drives[selectedDrive]
    if not state or state.status == "EMPTY" then return end
    if state.status == "ONLINE" then
        local volume = volumes[state.id]
        if volume and tableCount(volume.index.tiles) > 0 then
            log("Drain this volume before ejecting it", "WARN")
            return
        end
    end
    local ok, reason = pcall(state.drive.ejectDisk)
    if not ok then log("Eject failed: " .. tostring(reason), "ERROR") end
end

local function totalCapacity()
    local capacity = 0
    local free = 0
    local known = true
    for _, volume in pairs(volumes) do
        local details = atlas.capacity(volume.mount)
        if type(details.capacity) == "number" then
            capacity = capacity + details.capacity
        else
            known = false
        end
        if type(details.free) == "number" then
            free = free + details.free
        end
    end
    return known and capacity or nil, free
end

local function poiList()
    local result = {}
    for _, poi in pairs(poiStore.pois) do
        result[#result + 1] = poi
    end
    table.sort(result, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    return result
end

local function validCoordinate(value)
    return type(value) == "number"
        and value == value
        and math.abs(value) <= 30000000
end

local function cleanPoiText(value, maximum, fallback)
    local text = tostring(value or fallback or "")
        :gsub("[%c]", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    if text == "" then text = fallback or "" end
    return text:sub(1, maximum)
end

local function savePoiStore()
    return atlas.writeTable(POI_PATH, poiStore)
end

local function storePoi(sender, value)
    if type(value) ~= "table"
        or type(value.dimension) ~= "string"
        or value.dimension == ""
        or not validCoordinate(value.x)
        or not validCoordinate(value.z)
        or value.y ~= nil and not validCoordinate(value.y) then
        return nil, "invalid POI"
    end
    local existing = type(value.id) == "string" and poiStore.pois[value.id]
    local id = existing and existing.id or atlas.randomId("poi")
    local timestamp = atlas.now()
    local poi = {
        id = id,
        name = cleanPoiText(value.name, 32, "POINT"),
        category = cleanPoiText(value.category, 16, "GENERAL"):upper(),
        dimension = value.dimension,
        x = math.floor(value.x + 0.5),
        y = value.y and math.floor(value.y + 0.5) or nil,
        z = math.floor(value.z + 0.5),
        createdAt = existing and existing.createdAt or timestamp,
        updatedAt = timestamp,
        createdBy = existing and existing.createdBy or sender
    }
    poiStore.pois[id] = poi
    poiStore.revision = poiStore.revision + 1
    local ok, failure = savePoiStore()
    if not ok then
        if existing then poiStore.pois[id] = existing
        else poiStore.pois[id] = nil end
        poiStore.revision = poiStore.revision - 1
        return nil, failure
    end
    return poi
end

local function deletePoi(identifier)
    if type(identifier) ~= "string" or not poiStore.pois[identifier] then
        return false, "POI not found"
    end
    local previous = poiStore.pois[identifier]
    poiStore.pois[identifier] = nil
    poiStore.revision = poiStore.revision + 1
    local ok, failure = savePoiStore()
    if not ok then
        poiStore.pois[identifier] = previous
        poiStore.revision = poiStore.revision - 1
        return false, failure
    end
    return true
end

local function stationInfo()
    local capacity, free = totalCapacity()
    return {
        name = config.name,
        computerId = os.getComputerID(),
        appVersion = atlas.APP_VERSION,
        maintenance = maintenance,
        tiles = tableCount(tileIndex),
        volumes = tableCount(volumes),
        capacity = capacity,
        free = free,
        aircraft = tableCount(aircraft),
        pois = tableCount(poiStore.pois),
        capabilities = {
            bulkTiles = true,
            maxBulkTiles = MAX_BULK_REQUEST_TILES,
            bulkUploads = true,
            maxBulkUploads = MAX_BULK_UPLOAD_TILES,
            tileWindows = true,
            maxWindowTiles = MAX_WINDOW_REQUEST_TILES,
            windowSegmentTiles = WINDOW_SEGMENT_TILES,
            windowSegmentsInFlight = WINDOW_SEGMENT_CONCURRENCY,
            catalog = true,
            catalogPageSize = CATALOG_PAGE_SIZE,
            catalogRevision = catalogRevision,
            sharedPois = true,
            poiRevision = poiStore.revision
        }
    }
end

local function authorised(message)
    return config.writeKey == "" or message.writeKey == config.writeKey
end

local function trafficSnapshot()
    local snapshot = {}
    local currentTime = atlas.now()
    for id, contact in pairs(aircraft) do
        if currentTime - contact.lastSeen <= TRAFFIC_REMOVE_MS then
            snapshot[#snapshot + 1] = {
                id = id,
                callsign = contact.callsign,
                dimension = contact.dimension,
                x = contact.x,
                y = contact.y,
                z = contact.z,
                heading = contact.heading,
                track = contact.track,
                speed = contact.speed,
                status = contact.status,
                age = currentTime - contact.lastSeen
            }
        end
    end
    table.sort(snapshot, function(a, b)
        return tostring(a.callsign) < tostring(b.callsign)
    end)
    return snapshot
end

local function makeTileItem(request)
    if type(request) ~= "table"
        or type(request.dimension) ~= "string"
        or type(request.chunkX) ~= "number"
        or type(request.chunkZ) ~= "number" then
        return nil
    end

    local item = {
        dimension = request.dimension,
        chunkX = request.chunkX,
        chunkZ = request.chunkZ
    }
    local tile, reason = loadIndexedTile(
        request.dimension, request.chunkX, request.chunkZ)
    if tile then
        if request.checksum == tile.checksum then
            item.status = "current"
        else
            item.status = "data"
            item.tile = tile
            stats.downloads = stats.downloads + 1
        end
    else
        item.status = reason == "missing" and "missing" or "unavailable"
        item.reason = reason
    end
    return item
end

local function catalogSnapshot()
    if catalogKeys
        and (not catalogDirty or atlas.now() - catalogBuiltAt < 5000) then
        return catalogKeys
    end
    local keys = {}
    for key in pairs(tileIndex) do keys[#keys + 1] = key end
    table.sort(keys)
    catalogKeys = keys
    catalogBuiltAt = atlas.now()
    if catalogDirty then
        catalogRevision = catalogRevision + 1
        catalogDirty = false
    end
    return keys
end

local function catalogPage(cursor, requestedLimit)
    local keys = catalogSnapshot()
    cursor = math.max(1, math.floor(tonumber(cursor) or 1))
    local limit = math.max(
        1, math.min(CATALOG_PAGE_SIZE, math.floor(tonumber(requestedLimit)
            or CATALOG_PAGE_SIZE)))
    local entries = {}
    local finalIndex = math.min(#keys, cursor + limit - 1)
    for index = cursor, finalIndex do
        local key = keys[index]
        local dimension, chunkX, chunkZ =
            key:match("^(.-)|(-?%d+)|(-?%d+)$")
        local indexed = tileIndex[key]
        if dimension and indexed then
            entries[#entries + 1] = {
                dimension = dimension,
                chunkX = tonumber(chunkX),
                chunkZ = tonumber(chunkZ),
                checksum = indexed.checksum
            }
        end
    end
    return {
        entries = entries,
        cursor = cursor,
        nextCursor = finalIndex < #keys and (finalIndex + 1) or nil,
        total = #keys,
        revision = catalogRevision
    }
end

local function startWindowTransfer(sender, message)
    local requests = type(message.tiles) == "table" and message.tiles or {}
    local count = math.min(#requests, MAX_WINDOW_REQUEST_TILES)
    local items = {}
    for index = 1, count do
        local item = makeTileItem(requests[index])
        if item then items[#items + 1] = item end
    end

    local segments = {}
    for first = 1, #items, WINDOW_SEGMENT_TILES do
        local segmentItems = {}
        local final = math.min(#items, first + WINDOW_SEGMENT_TILES - 1)
        for index = first, final do
            segmentItems[#segmentItems + 1] = items[index]
        end
        segments[#segments + 1] = {
            items = segmentItems,
            attempts = 0,
            sentAt = 0,
            acknowledged = false
        }
    end
    if #segments == 0 then segments[1] = {
        items = {},
        attempts = 0,
        sentAt = 0,
        acknowledged = false
    } end

    local transferKey = tostring(sender) .. "|" .. tostring(message.requestId)
    windowTransfers[transferKey] = {
        sender = sender,
        requestId = message.requestId,
        segments = segments,
        createdAt = atlas.now()
    }
end

local function acknowledgeWindowSegment(sender, message)
    local transferKey = tostring(sender) .. "|" .. tostring(message.requestId)
    local transfer = windowTransfers[transferKey]
    local segment = transfer and transfer.segments[tonumber(message.segment)]
    if segment then segment.acknowledged = true end
end

local function handleMessage(sender, message)
    if type(message) ~= "table" or message.atlas ~= atlas.VERSION then return end

    if message.op == "station_info" then
        atlas.reply(sender, message, "station_info", stationInfo())
    elseif message.op == "offer_tile" then
        if not authorised(message) then
            stats.rejected = stats.rejected + 1
            atlas.reply(sender, message, "denied", { reason = "write access denied" })
            return
        end
        local key = atlas.tileKey(
            message.dimension, message.chunkX, message.chunkZ)
        local existing = tileIndex[key]
        local operation = existing and existing.checksum == message.checksum
            and "tile_have" or "tile_send"
        atlas.reply(sender, message, operation)
    elseif message.op == "put_tile" then
        if not authorised(message) then
            stats.rejected = stats.rejected + 1
            atlas.reply(sender, message, "denied", { reason = "write access denied" })
        elseif maintenance then
            atlas.reply(sender, message, "deferred", {
                reason = "station is in storage maintenance"
            })
        else
            local ok, status = storeTile(message.tile)
            if ok then
                if status == "duplicate" then
                    stats.duplicates = stats.duplicates + 1
                else
                    stats.uploads = stats.uploads + 1
                end
                atlas.reply(sender, message, "tile_stored", { status = status })
            elseif status == "no ATLAS volume has enough free space" then
                atlas.reply(sender, message, "deferred", { reason = status })
                log("Upload deferred until storage is available", "WARN")
            else
                stats.rejected = stats.rejected + 1
                atlas.reply(sender, message, "tile_error", { reason = status })
                log("Upload rejected: " .. tostring(status), "WARN")
            end
        end
    elseif message.op == "put_tiles" and type(message.tiles) == "table" then
        local items = {}
        local count = math.min(#message.tiles, MAX_BULK_UPLOAD_TILES)
        if not authorised(message) then
            stats.rejected = stats.rejected + count
            atlas.reply(sender, message, "tiles_stored", {
                items = {},
                reason = "write access denied",
                status = "denied"
            })
        elseif maintenance then
            atlas.reply(sender, message, "tiles_stored", {
                items = {},
                reason = "station is in storage maintenance",
                status = "deferred"
            })
        else
            for index = 1, count do
                local tile = message.tiles[index]
                local item = type(tile) == "table" and {
                    dimension = tile.dimension,
                    chunkX = tile.chunkX,
                    chunkZ = tile.chunkZ
                } or {}
                local ok, status = storeTile(tile, nil, false, true)
                if ok then
                    item.status = status
                    if status == "duplicate" then
                        stats.duplicates = stats.duplicates + 1
                    else
                        stats.uploads = stats.uploads + 1
                    end
                else
                    item.status =
                        status == "no ATLAS volume has enough free space"
                            and "deferred" or "error"
                    item.reason = status
                    if item.status == "error" then
                        stats.rejected = stats.rejected + 1
                    end
                end
                items[#items + 1] = item
            end
            atlas.reply(sender, message, "tiles_stored", { items = items })
        end
    elseif message.op == "get_tile" then
        local tile, reason = loadIndexedTile(
            message.dimension, message.chunkX, message.chunkZ)
        if tile then
            stats.downloads = stats.downloads + 1
            if message.checksum == tile.checksum then
                atlas.reply(sender, message, "tile_current")
            else
                atlas.reply(sender, message, "tile_data", { tile = tile })
            end
        elseif reason == "missing" then
            atlas.reply(sender, message, "tile_missing", { reason = reason })
        else
            atlas.reply(sender, message, "tile_unavailable", {
                reason = reason
            })
        end
    elseif message.op == "get_tiles" and type(message.tiles) == "table" then
        local items = {}
        local count = math.min(#message.tiles, MAX_BULK_REQUEST_TILES)
        for index = 1, count do
            local item = makeTileItem(message.tiles[index])
            if item then items[#items + 1] = item end
        end
        atlas.reply(sender, message, "tiles_data", { items = items })
    elseif message.op == "get_tile_window"
        and type(message.tiles) == "table"
        and message.requestId ~= nil then
        startWindowTransfer(sender, message)
    elseif message.op == "tiles_segment_ack" then
        acknowledgeWindowSegment(sender, message)
    elseif message.op == "get_catalog" then
        atlas.reply(sender, message, "catalog_page",
            catalogPage(message.cursor, message.limit))
    elseif message.op == "get_pois" then
        if tonumber(message.revision) == poiStore.revision then
            atlas.reply(sender, message, "pois_current", {
                revision = poiStore.revision
            })
        else
            atlas.reply(sender, message, "pois_data", {
                revision = poiStore.revision,
                pois = poiList()
            })
        end
    elseif message.op == "put_poi" then
        if not authorised(message) then
            atlas.reply(sender, message, "poi_error", {
                reason = "write access denied"
            })
        else
            local poi, failure = storePoi(sender, message.poi)
            if poi then
                log(("POI saved: %s (%d,%d) by %d"):format(
                    poi.name, poi.x, poi.z, sender))
                atlas.reply(sender, message, "poi_stored", {
                    poi = poi,
                    revision = poiStore.revision
                })
            else
                atlas.reply(sender, message, "poi_error", {
                    reason = failure
                })
            end
        end
    elseif message.op == "delete_poi" then
        if not authorised(message) then
            atlas.reply(sender, message, "poi_error", {
                reason = "write access denied"
            })
        else
            local ok, failure = deletePoi(message.poiId)
            if ok then
                log(("POI deleted: %s by %d"):format(
                    tostring(message.poiId), sender))
                atlas.reply(sender, message, "poi_deleted", {
                    poiId = message.poiId,
                    revision = poiStore.revision
                })
            else
                atlas.reply(sender, message, "poi_error", {
                    reason = failure
                })
            end
        end
    elseif message.op == "heartbeat" then
        aircraft[sender] = {
            callsign = message.callsign or ("AC-" .. sender),
            dimension = message.dimension,
            x = message.x,
            y = message.y,
            z = message.z,
            heading = message.heading,
            track = message.track,
            speed = message.speed,
            status = message.status or "ONLINE",
            lastSeen = atlas.now()
        }
    elseif message.op == "traffic_request" then
        atlas.reply(sender, message, "traffic_data", {
            contacts = trafficSnapshot()
        })
    end
end

local function fit(text, width)
    text = tostring(text)
    if #text <= width then return text end
    if width <= 1 then return text:sub(1, width) end
    return text:sub(1, width - 1) .. "~"
end

local function writeAt(x, y, text, foreground, background)
    local width, height = term.getSize()
    if y < 1 or y > height or x > width then return end
    text = fit(text, width - x + 1)
    term.setCursorPos(math.max(1, x), y)
    if foreground then term.setTextColor(foreground) end
    if background then term.setBackgroundColor(background) end
    term.write(text)
end

local function clearLine(y, background)
    local width = term.getSize()
    writeAt(1, y, string.rep(" ", width), colors.white, background)
end

local function drawButton(x, y, label, action, enabled)
    local text = " " .. label .. " "
    local foreground = enabled and colors.white or colors.gray
    local background = enabled and colors.blue or colors.black
    writeAt(x, y, text, foreground, background)
    uiButtons[#uiButtons + 1] = {
        x1 = x,
        x2 = x + #text - 1,
        y = y,
        action = action,
        enabled = enabled
    }
    return x + #text + 1
end

local function drawBar(x, y, width, used, capacity)
    local amount = 0
    if type(used) == "number" and type(capacity) == "number" and capacity > 0 then
        amount = math.max(0, math.min(1, used / capacity))
    end
    local filled = math.floor(width * amount + 0.5)
    writeAt(x, y, string.rep(" ", filled), colors.white, colors.lightBlue)
    writeAt(x + filled, y, string.rep(" ", width - filled),
        colors.white, colors.gray)
end

local function drawHeader(width)
    clearLine(1, colors.blue)
    writeAt(2, 1, "ATLAS STATION", colors.white, colors.blue)
    local state = maintenance and "MAINT" or radioState
    local stateColor = maintenance and colors.yellow
        or radioState == "WIRELESS" and colors.lime
        or radioState == "WIRED" and colors.yellow
        or colors.red
    writeAt(width - #state, 1, state,
        stateColor, colors.blue)

    clearLine(2, colors.black)
    local x = 1
    for index, name in ipairs(PAGE_NAMES) do
        local label = (" %d %s "):format(index, name)
        writeAt(x, 2, label,
            index == page and colors.black or colors.lightGray,
            index == page and colors.lightBlue or colors.black)
        x = x + #label
    end
end

local function drawOverview(width, height)
    local capacity, free = totalCapacity()
    local used = capacity and capacity - free
    writeAt(2, 4, config.name, colors.lightBlue)
    writeAt(2, 5, ("TILES       %d"):format(tableCount(tileIndex)), colors.white)
    writeAt(2, 6, ("VOLUMES     %d"):format(tableCount(volumes)), colors.white)
    writeAt(2, 7, ("AIRCRAFT    %d  POIS %d"):format(
        tableCount(aircraft), tableCount(poiStore.pois)), colors.white)
    writeAt(2, 8, fit("LINK        " .. radioDetail, width - 3),
        radioState == "WIRELESS" and colors.lime
            or radioState == "WIRED" and colors.yellow or colors.red)
    writeAt(2, 9, "STORAGE", colors.lightGray)
    drawBar(2, 10, math.max(10, width - 4), used, capacity)
    writeAt(2, 11, ("%s FREE / %s"):format(
        atlas.formatBytes(free), atlas.formatBytes(capacity)), colors.lightGray)
    writeAt(2, 13, ("UPLOADS %d  DOWNLOADS %d"):format(
        stats.uploads, stats.downloads), colors.white)
    writeAt(2, 14, ("DUPLICATES %d  REJECTED %d"):format(
        stats.duplicates, stats.rejected), colors.lightGray)
    if job then
        local progress = job.total == 0 and 1
            or math.min(1, (job.index - 1) / job.total)
        writeAt(2, 16, "JOB " .. job.type:upper() .. " " .. job.status,
            job.status == "FAILED" and colors.red or colors.yellow)
        drawBar(2, 17, math.max(10, width - 4), progress, 1)
    end
end

local function drawStorage(width, height)
    writeAt(2, 4, maintenance
        and "MAINTENANCE: READS ONLINE, WRITES DEFERRED"
        or "PRESS M TO ENTER MAINTENANCE",
        maintenance and colors.yellow or colors.lightGray)
    local top = 6
    local visible = math.max(1, height - top - 7)
    local first = math.max(1, math.min(selectedDrive, #drives) - visible + 1)
    for line = 0, visible - 1 do
        local index = first + line
        local state = drives[index]
        if not state then break end
        local selected = index == selectedDrive
        local prefix = selected and ">" or " "
        local usage = ""
        if state.capacity and type(state.capacity.capacity) == "number"
            and type(state.capacity.used) == "number" then
            usage = ("%3d%%"):format(math.floor(
                state.capacity.used / state.capacity.capacity * 100 + 0.5))
        end
        local row = ("%s%-14s %-12s %4s"):format(
            prefix, fit(state.name, 14), state.status, usage)
        writeAt(2, top + line, row,
            selected and colors.black or colors.white,
            selected and colors.lightBlue or colors.black)
        uiButtons[#uiButtons + 1] = {
            x1 = 2,
            x2 = math.max(2, width - 1),
            y = top + line,
            action = "select:" .. index,
            enabled = true
        }
    end
    if #drives == 0 then
        writeAt(2, 7, "NO WIRED DISK DRIVES DETECTED", colors.orange)
    end

    local selected = drives[selectedDrive]
    if selected then
        writeAt(2, height - 5, ("SELECTED %s  LABEL %s"):format(
            fit(selected.name, 14), fit(selected.label or "-", 16)),
            colors.lightBlue)
        local capacity = selected.capacity or {}
        local detail = ("%s  FREE %s / %s"):format(
            selected.status,
            atlas.formatBytes(capacity.free),
            atlas.formatBytes(capacity.capacity))
        if selected.tileCount then
            detail = detail .. ("  %d TILES"):format(selected.tileCount)
        end
        writeAt(2, height - 4, detail, colors.lightGray)
    end

    local buttonX = 2
    if maintenance then
        buttonX = drawButton(buttonX, height - 2, "INIT", "initialize", true)
        buttonX = drawButton(
            buttonX, height - 2, "INIT ALL", "initialize_all", true)
        buttonX = drawButton(buttonX, height - 2, "DRAIN", "drain", true)
        buttonX = drawButton(buttonX, height - 2, "EJECT", "eject", true)
        buttonX = drawButton(buttonX, height - 2, "RESCAN", "rescan", true)
        drawButton(buttonX, height - 2, "DONE", "maintenance", true)
    else
        buttonX = drawButton(buttonX, height - 2, "RESCAN", "rescan", true)
        drawButton(buttonX, height - 2, "MAINT", "maintenance", true)
    end
end

local function drawTraffic(width, height)
    local contacts = trafficSnapshot()
    writeAt(2, 4, ("LIVE CONTACTS %d"):format(#contacts), colors.lightBlue)
    local y = 6
    for _, contact in ipairs(contacts) do
        if y > height - 2 then break end
        local stale = contact.age > TRAFFIC_STALE_MS
        local row = ("%-12s %8.0f %4.0f %8.0f  %4.1fs"):format(
            fit(contact.callsign, 12),
            contact.x or 0, contact.y or 0, contact.z or 0,
            contact.age / 1000)
        writeAt(2, y, row, stale and colors.gray or colors.white)
        y = y + 1
    end
    if #contacts == 0 then writeAt(2, 6, "NO AIRCRAFT ONLINE", colors.gray) end
end

local function drawLogs(width, height)
    local visible = height - 5
    local first = math.max(1, #logs - visible + 1)
    local y = 4
    for index = first, #logs do
        local entry = logs[index]
        local color = entry.severity == "ERROR" and colors.red
            or entry.severity == "WARN" and colors.orange or colors.lightGray
        writeAt(2, y, entry.severity:sub(1, 1) .. " " .. entry.message, color)
        y = y + 1
    end
end

local function draw()
    local width, height = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    uiButtons = {}
    drawHeader(width)
    if page == 1 then drawOverview(width, height)
    elseif page == 2 then drawStorage(width, height)
    elseif page == 3 then drawTraffic(width, height)
    else drawLogs(width, height)
    end
    clearLine(height, colors.gray)
    writeAt(2, height, fit(notice, width - 7), colors.white, colors.gray)
    writeAt(width - 4, height, "Q EXIT", colors.white, colors.gray)
end

local function performUiAction(action)
    local driveIndex = action:match("^select:(%d+)$")
    if driveIndex then
        selectedDrive = math.max(1, math.min(#drives, tonumber(driveIndex)))
        local selected = drives[selectedDrive]
        notice = selected and ("Selected " .. selected.name) or "No drive selected"
    elseif action == "maintenance" then
        maintenance = not maintenance
        log(maintenance and "Maintenance mode entered"
            or "Maintenance mode exited")
    elseif action == "rescan" then
        rescanDrives(false)
    elseif maintenance and action == "initialize" then
        initialiseSelectedDrive()
    elseif maintenance and action == "initialize_all" then
        initialiseAllDrives()
    elseif maintenance and action == "drain" then
        startDrain()
    elseif maintenance and action == "eject" then
        ejectSelected()
    end
end

local function uiLoop()
    local timer = os.startTimer(UI_REFRESH_SECONDS)
    draw()
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            return
        elseif event[1] == "timer" and event[2] == timer then
            draw()
            timer = os.startTimer(UI_REFRESH_SECONDS)
        elseif event[1] == "term_resize" then
            draw()
        elseif event[1] == "char" then
            local character = event[2]:lower()
            if character >= "1" and character <= "4" then
                page = tonumber(character)
            elseif character == "q" then
                running = false
                return
            elseif character == "m" then
                performUiAction("maintenance")
            elseif character == "r" then
                performUiAction("rescan")
            elseif maintenance and character == "i" then
                performUiAction("initialize")
            elseif maintenance and character == "a" then
                performUiAction("initialize_all")
            elseif maintenance and character == "d" then
                performUiAction("drain")
            elseif maintenance and character == "e" then
                performUiAction("eject")
            end
            draw()
        elseif event[1] == "key" then
            if event[2] == keys.up then
                selectedDrive = math.max(1, selectedDrive - 1)
            elseif event[2] == keys.down then
                selectedDrive = math.min(math.max(1, #drives), selectedDrive + 1)
            end
            draw()
        elseif event[1] == "mouse_click" then
            local _, _, x, y = table.unpack(event, 1, event.n)
            for _, button in ipairs(uiButtons) do
                if button.enabled and y == button.y
                    and x >= button.x1 and x <= button.x2 then
                    performUiAction(button.action)
                    break
                end
            end
            if y == 2 then
                local cursor = 1
                for index, name in ipairs(PAGE_NAMES) do
                    local labelWidth = #((" %d %s "):format(index, name))
                    if x >= cursor and x < cursor + labelWidth then page = index end
                    cursor = cursor + labelWidth
                end
            end
            draw()
        end
    end
end

local function networkLoop()
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            return
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_LINK then
            local ok, failure = pcall(handleMessage, event[2], event[3])
            if not ok then log("Network error: " .. tostring(failure), "ERROR") end
        end
    end
end

local function driveLoop()
    local timer = os.startTimer(DRIVE_RESCAN_SECONDS)
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            running = false
            return
        elseif event[1] == "timer" and event[2] == timer then
            rescanDrives(true)
            ensureNetwork(false)
            timer = os.startTimer(DRIVE_RESCAN_SECONDS)
        elseif event[1] == "disk" or event[1] == "disk_eject"
            or event[1] == "peripheral"
            or event[1] == "peripheral_detach" then
            rescanDrives(true)
            ensureNetwork(false)
        end
    end
end

local function jobLoop()
    while running do
        if job and job.status == "RUNNING" then processJobStep() end
        local event = atlas.waitSeconds(job and 0.05 or 0.25)
        if not event then
            running = false
            return
        end
    end
end

local function trafficLoop()
    while running do
        local currentTime = atlas.now()
        for id, contact in pairs(aircraft) do
            if currentTime - contact.lastSeen > TRAFFIC_REMOVE_MS then
                aircraft[id] = nil
            end
        end
        local event = atlas.waitSeconds(1)
        if not event then
            running = false
            return
        end
    end
end

local function processWindowTransfers()
    local currentTime = atlas.now()
    for transferKey, transfer in pairs(windowTransfers) do
        local active = 0
        local complete = true
        for _, segment in ipairs(transfer.segments) do
            if not segment.acknowledged then
                complete = false
                if segment.sentAt > 0
                    and currentTime - segment.sentAt < WINDOW_RETRY_MS then
                    active = active + 1
                end
            end
        end

        if complete
            or currentTime - transfer.createdAt > WINDOW_EXPIRE_MS then
            windowTransfers[transferKey] = nil
        else
            for index, segment in ipairs(transfer.segments) do
                if active >= WINDOW_SEGMENT_CONCURRENCY then break end
                local ready = not segment.acknowledged
                    and (segment.sentAt == 0
                        or currentTime - segment.sentAt >= WINDOW_RETRY_MS)
                if ready and segment.attempts < WINDOW_MAX_ATTEMPTS then
                    atlas.send(transfer.sender, "tiles_segment", {
                        requestId = transfer.requestId,
                        segment = index,
                        segments = #transfer.segments,
                        items = segment.items
                    })
                    segment.sentAt = currentTime
                    segment.attempts = segment.attempts + 1
                    active = active + 1
                end
            end
        end
    end
end

local function transferLoop()
    local lastIndexFlush = 0
    while running do
        processWindowTransfers()
        if atlas.now() - lastIndexFlush >= INDEX_FLUSH_MS then
            flushDirtyVolumeIndexes()
            lastIndexFlush = atlas.now()
        end
        local event = atlas.waitSeconds(0.05)
        if not event then
            running = false
            return
        end
    end
end

local function main()
    math.randomseed(atlas.now() + os.getComputerID())
    atlas.writeTable(CONFIG_PATH, config)
    ensureNetwork(true)

    rescanDrives(false)
    if networkHosted then
        log("ATLAS Link online as " .. hostedName)
    else
        log("ATLAS storage online; attach a modem for networking", "WARN")
    end
    parallel.waitForAny(
        uiLoop, networkLoop, driveLoop, jobLoop, trafficLoop, transferLoop)
    running = false
    flushDirtyVolumeIndexes()
    if networkHosted then pcall(rednet.unhost, atlas.PROTOCOL_DISCOVERY) end
end

local ok, failure = xpcall(main, debug.traceback)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then
    printError(failure)
else
    print("ATLAS Station offline.")
end
