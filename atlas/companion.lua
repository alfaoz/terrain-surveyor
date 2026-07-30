-- ATLAS Companion
-- Pocket-computer terrain, route, POI, and live aircraft display.

local LIBRARY = fs.exists("/atlas/lib.lua") and "/atlas/lib.lua" or "atlas/lib.lua"
local atlas = dofile(LIBRARY)
local _ENV = setmetatable({}, { __index = _ENV })

CONFIG_PATH = "/atlas/companion.cfg"
CACHE_ROOT = "/atlas/companion-cache/tiles"
UPDATE_SECONDS = 0.05
NETWORK_SECONDS = 0.05
STATE_REQUEST_MS = 800
STATE_LOST_MS = 3500
TILE_TIMEOUT_MS = 3000
TILE_BATCH_SIZE = 14
VISIBLE_INSPECTIONS = 256
MAP_EVENT = "atlas_companion_map"
HEADER_HEIGHT = 15
FOOTER_HEIGHT = 22
ZOOM_LEVELS = { 0.25, 0.5, 1, 2, 4, 8 }

COLOR = {
    background = 0,
    unknown = 1,
    water = 2,
    lava = 3,
    fluid = 4,
    obstacle = 5,
    contour = 6,
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

FONT = {
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

BYTE = {}
for byte = 0, 255 do BYTE[byte] = string.char(byte) end

config = atlas.readTable(CONFIG_PATH) or {}
tiles = {}
wantedTiles = {}
tilePending = nil
missingUntil = {}
terrainRevision = 0
state = nil
stateReceivedAt = 0
session = nil
navigatorId = nil
connected = false
running = false
quitAll = false
switchRequested = false
modal = false
linkDialog = nil
connectionUi = nil
statusText = "STARTING"
viewX = nil
viewZ = nil
follow = true
zoomIndex = 4
selectedPoiId = nil
pointerDetails = nil
lastDisplay = nil
mapBuildRequest = nil
mapCache = {}
blankCache = {}
viewportPlan = nil
lastStateRequest = 0
lastHelloRequest = 0
helloRequestId = nil
originalPalette = {}
activeFrame = nil
displayFailures = 0
lastGraphicsWidth = nil
lastGraphicsHeight = nil

function now()
    return atlas.now()
end

function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function count(value)
    local result = 0
    for _ in pairs(value or {}) do result = result + 1 end
    return result
end

function setPalette(index, red, green, blue)
    term.setPaletteColor(index, red / 255, green / 255, blue / 255)
end

function mix(a, b, amount)
    return a + (b - a) * amount
end

function capturePalette()
    for exponent = 0, 15 do
        local color = 2 ^ exponent
        local ok, red, green, blue = pcall(term.getPaletteColor, color)
        if ok then originalPalette[color] = { red, green, blue } end
    end
end

function restorePalette()
    for exponent = 0, 15 do
        local color = 2 ^ exponent
        local saved = originalPalette[color]
        if saved then
            pcall(term.setPaletteColor,
                color, saved[1], saved[2], saved[3])
        end
    end
end

function configurePalette()
    setPalette(COLOR.background, 13, 18, 20)
    setPalette(COLOR.unknown, 24, 31, 33)
    setPalette(COLOR.water, 76, 128, 148)
    setPalette(COLOR.lava, 213, 82, 42)
    setPalette(COLOR.fluid, 122, 88, 145)
    setPalette(COLOR.obstacle, 196, 136, 83)
    setPalette(COLOR.contour, 54, 58, 50)
    setPalette(COLOR.panel, 19, 25, 27)
    setPalette(COLOR.panelEdge, 58, 70, 71)
    setPalette(COLOR.text, 225, 229, 221)
    setPalette(COLOR.textDim, 137, 151, 146)
    setPalette(COLOR.aircraft, 240, 99, 78)
    setPalette(COLOR.aircraftEdge, 58, 34, 31)
    setPalette(COLOR.warning, 231, 75, 63)
    setPalette(COLOR.route, 230, 185, 91)
    setPalette(COLOR.waypoint, 244, 229, 169)
    setPalette(COLOR.traffic, 103, 187, 190)
    setPalette(COLOR.poi, 213, 154, 224)

    local low = { 66, 105, 77 }
    local middle = { 133, 137, 98 }
    local high = { 180, 175, 154 }
    local shades = { 0.72, 0.87, 1.0, 1.12 }
    for band = 0, 15 do
        local amount = band / 15
        local red
        local green
        local blue
        if amount < 0.55 then
            local part = amount / 0.55
            red = mix(low[1], middle[1], part)
            green = mix(low[2], middle[2], part)
            blue = mix(low[3], middle[3], part)
        else
            local part = (amount - 0.55) / 0.45
            red = mix(middle[1], high[1], part)
            green = mix(middle[2], high[2], part)
            blue = mix(middle[3], high[3], part)
        end
        for shade = 0, 3 do
            local factor = shades[shade + 1]
            setPalette(COLOR.terrainFirst + band * 4 + shade,
                clamp(red * factor, 0, 255),
                clamp(green * factor, 0, 255),
                clamp(blue * factor, 0, 255))
        end
    end
end

function tileKey(dimension, chunkX, chunkZ)
    return atlas.tileKey(dimension, chunkX, chunkZ)
end

function cachePath(dimension, chunkX, chunkZ)
    local regionX = math.floor(chunkX / 32)
    local regionZ = math.floor(chunkZ / 32)
    return fs.combine(
        CACHE_ROOT,
        atlas.safeName(dimension),
        regionX .. "_" .. regionZ,
        chunkX .. "_" .. chunkZ .. ".tile")
end

function decodeHeights(data, minY)
    local result = {}
    for sample = 0, 255 do
        local offset = sample * 2 + 1
        local high, low = data:byte(offset, offset + 1)
        local encoded = high * 256 + low
        result[sample + 1] = encoded == 0xffff and false
            or minY + encoded
    end
    return result
end

function renderTilePixels(tile)
    local result = {}
    for z = 0, 15 do
        for x = 0, 15 do
            local sample = z * 16 + x + 1
            local surface = tile.surface[sample]
            local clearance = tile.clearance[sample]
            local fluid = tile.fluid[sample]
            local flags = tile.flags[sample]
            local color = COLOR.unknown
            if surface then
                local fluidKind = flags % 4
                if fluid and fluid >= surface and fluidKind ~= 0 then
                    color = fluidKind == 1 and COLOR.water
                        or fluidKind == 2 and COLOR.lava
                        or COLOR.fluid
                else
                    local band = clamp(
                        math.floor((surface - 48) / 8), 0, 15)
                    local east = x < 15 and tile.surface[sample + 1]
                        or surface
                    local south = z < 15 and tile.surface[sample + 16]
                        or surface
                    local slope = (east or surface) - surface
                        + (south or surface) - surface
                    local shade = slope >= 4 and 0
                        or slope >= 1 and 1
                        or slope <= -4 and 3 or 2
                    color = COLOR.terrainFirst + band * 4 + shade
                    local contour = math.floor(surface / 10)
                    if east and math.floor(east / 10) ~= contour
                        or south and math.floor(south / 10) ~= contour then
                        color = COLOR.contour
                    elseif clearance and clearance > surface
                        and (x + z) % 3 == 0 then
                        color = COLOR.obstacle
                    end
                end
            elseif clearance then
                color = COLOR.obstacle
            end
            result[sample] = BYTE[color]
        end
    end
    return table.concat(result)
end

function decodeTile(raw)
    local valid = atlas.validateTile(raw)
    if not valid then return nil end
    local flags = {}
    for index = 1, 256 do flags[index] = raw.flags:byte(index) end
    local tile = {
        dimension = raw.dimension,
        chunkX = raw.chunkX,
        chunkZ = raw.chunkZ,
        minY = raw.minY,
        maxY = raw.maxY,
        surface = decodeHeights(raw.surface, raw.minY),
        clearance = decodeHeights(raw.clearance, raw.minY),
        fluid = decodeHeights(raw.fluid, raw.minY),
        flags = flags,
        checksum = raw.checksum
    }
    tile.pixels = renderTilePixels(tile)
    return tile
end

function installTile(raw, save)
    local tile = decodeTile(raw)
    if not tile then return false end
    local key = tileKey(tile.dimension, tile.chunkX, tile.chunkZ)
    local previous = tiles[key]
    tiles[key] = tile
    wantedTiles[key] = nil
    missingUntil[key] = nil
    if not previous or previous.checksum ~= tile.checksum then
        terrainRevision = terrainRevision + 1
    end
    if save then
        local encoded = atlas.encodeTile(raw)
        if encoded then atlas.writeAtomic(
            cachePath(raw.dimension, raw.chunkX, raw.chunkZ),
            encoded, false)
        end
    end
    return true
end

function loadCachedTile(dimension, chunkX, chunkZ)
    local path = cachePath(dimension, chunkX, chunkZ)
    if not fs.exists(path) then return false end
    local raw = atlas.loadTile(path)
    if not raw then
        pcall(fs.delete, path)
        return false
    end
    return installTile(raw, false)
end

function zoom()
    return ZOOM_LEVELS[zoomIndex]
end

function aircraft()
    return state and type(state.aircraft) == "table"
        and state.aircraft or nil
end

function route()
    return state and type(state.route) == "table"
        and state.route or { revision = 0, active = 1, waypoints = {} }
end

function pois()
    return state and type(state.pois) == "table" and state.pois or {}
end

function saveConfig()
    atlas.writeTable(CONFIG_PATH, config)
end

function sendRaw(recipient, operation, payload)
    payload = payload or {}
    payload.requestId = payload.requestId or atlas.requestId()
    atlas.sendProtocol(
        recipient, atlas.PROTOCOL_COMPANION_LINK, operation, payload)
    return payload.requestId
end

function exchange(recipient, operation, payload, timeout)
    local requestId = sendRaw(recipient, operation, payload)
    local timer = os.startTimer(timeout or 2)
    while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            quitAll = true
            return nil
        elseif event[1] == "timer" and event[2] == timer then
            return nil, "timed out"
        elseif event[1] == "rednet_message"
            and event[2] == recipient
            and event[4] == atlas.PROTOCOL_COMPANION_LINK
            and type(event[3]) == "table"
            and event[3].requestId == requestId then
            return event[3]
        end
    end
end

function acceptConnection(identifier, message)
    if type(message) ~= "table"
        or type(message.session) ~= "string" then return false end
    navigatorId = identifier
    session = message.session
    connected = true
    stateReceivedAt = now()
    if type(message.state) == "table" then state = message.state end
    if message.info and message.info.callsign then
        config.callsign = message.info.callsign
    end
    if state and state.callsign then config.callsign = state.callsign end
    if aircraft() and not viewX then
        viewX = aircraft().x
        viewZ = aircraft().z
    end
    statusText = "CONNECTED"
    return true
end

function discoverAircraft()
    local identifiers = {
        rednet.lookup(atlas.PROTOCOL_COMPANION_DISCOVERY)
    }
    local requests = {}
    for _, identifier in ipairs(identifiers) do
        local requestId = sendRaw(identifier, "info_request", {})
        requests[requestId] = identifier
    end
    local found = {}
    local timer = os.startTimer(1.2)
    while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            quitAll = true
            break
        elseif event[1] == "timer" and event[2] == timer then
            break
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_COMPANION_LINK
            and type(event[3]) == "table"
            and event[3].op == "aircraft_info"
            and requests[event[3].requestId] == event[2] then
            event[3].id = event[2]
            found[#found + 1] = event[3]
            requests[event[3].requestId] = nil
        end
    end
    table.sort(found, function(a, b)
        return tostring(a.callsign) < tostring(b.callsign)
    end)
    return found
end

function isSavedAircraft(candidate)
    return candidate
        and candidate.id == config.navigatorId
        and type(config.pairId) == "string"
        and type(config.secret) == "string"
end

function beginConnectionGraphics()
    if not term.setGraphicsMode or not term.drawPixels
        or not term.setFrozen then
        error("CC: Graphics is required by ATLAS Companion", 0)
    end
    local ok, failure = pcall(term.setGraphicsMode, 2)
    if not ok then
        error("Cannot enter graphics mode: " .. tostring(failure), 0)
    end
    configurePalette()
end

function endConnectionGraphics()
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, false)
    restorePalette()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function connectionButton(
        buttons, x, y, label, action, color, width, height)
    local buttonWidth = math.max(64, #label * 4 + 18)
    fillPixels(x, y, color or COLOR.panelEdge, buttonWidth, 13)
    drawText(x + math.floor((buttonWidth - #label * 4 + 1) / 2),
        y + 4, label, COLOR.text, width, height)
    buttons[#buttons + 1] = {
        x1 = x,
        x2 = x + buttonWidth - 1,
        y1 = y,
        y2 = y + 12,
        action = action
    }
    return x + buttonWidth + 8
end

function connectionRadar(centerX, centerY, width, height)
    for radius = 10, 34, 8 do
        for degrees = 0, 345, 15 do
            local radians = math.rad(degrees)
            drawPixel(
                math.floor(centerX + math.cos(radians) * radius + 0.5),
                math.floor(centerY + math.sin(radians) * radius + 0.5),
                COLOR.panelEdge, width, height)
        end
    end
    drawLine(centerX - 38, centerY, centerX + 38, centerY,
        COLOR.panelEdge, width, height)
    drawLine(centerX, centerY - 38, centerX, centerY + 38,
        COLOR.panelEdge, width, height)
    drawLine(centerX, centerY, centerX + 27, centerY - 27,
        COLOR.route, width, height)
    for offset = -2, 2 do
        drawPixel(centerX + offset, centerY,
            COLOR.aircraft, width, height)
        drawPixel(centerX, centerY + offset,
            COLOR.aircraft, width, height)
    end
end

function drawConnectionScreen(model)
    local width, height = term.getSize(2)
    local panelWidth = math.min(560, width - 32)
    local panelHeight = math.min(height - 42, 224)
    local left = math.floor((width - panelWidth) / 2)
    local top = math.floor((height - panelHeight) / 2) + 8
    local buttons = {}
    local cards = {}

    beginFrame(width, height, COLOR.background)
    fillPixels(0, 0, COLOR.panel, width, 20)
    fillPixels(0, 19, COLOR.panelEdge, width, 1)
    drawText(10, 5, "ATLAS COMPANION",
        COLOR.text, width, height)
    drawText(width - 106, 5, "SECURE LINK",
        COLOR.textDim, width, height)

    fillPixels(left, top, COLOR.panelEdge, panelWidth, panelHeight)
    fillPixels(
        left + 2, top + 2, COLOR.panel,
        panelWidth - 4, panelHeight - 4)
    drawText(left + 14, top + 12,
        model.mode == "code"
            and ("PAIR " .. tostring(model.candidate.callsign))
            or model.mode == "reconnecting"
                and "RESTORING AIRCRAFT LINK"
                or "SELECT AIRCRAFT",
        COLOR.text, width, height)
    drawText(left + 14, top + 21,
        model.mode == "code"
            and "ENTER THE CODE SHOWN IN THE COCKPIT"
            or model.mode == "reconnecting"
                and ("LAST LINK "
                    .. tostring(model.callsign or "AIRCRAFT"))
                or "ENDER MODEM DISCOVERY",
        COLOR.textDim, width, height)

    if model.mode == "scanning" or model.mode == "reconnecting" then
        local centerX = left + math.floor(panelWidth / 2)
        local centerY = top + math.floor(panelHeight / 2) + 3
        connectionRadar(centerX, centerY, width, height)
        drawText(centerX - 38, centerY + 49,
            model.mode == "scanning"
                and "SCANNING" or "AUTHENTICATING",
            COLOR.route, width, height)
    elseif model.mode == "code" then
        local fieldWidth = 176
        local fieldLeft = left + math.floor((panelWidth - fieldWidth) / 2)
        local fieldTop = top + 70
        fillPixels(
            fieldLeft, fieldTop, COLOR.background, fieldWidth, 32)
        fillPixels(
            fieldLeft + 2, fieldTop + 2,
            COLOR.panelEdge, fieldWidth - 4, 28)
        local displayCode = (model.code or "")
            .. string.rep("_", 6 - #(model.code or ""))
        displayCode = displayCode:sub(1, 3)
            .. "-" .. displayCode:sub(4, 6)
        drawText(fieldLeft + 55, fieldTop + 13,
            displayCode, COLOR.route, width, height)
        drawText(fieldLeft + 2, fieldTop + 43,
            "SIX DIGITS  PAIRING EXPIRES IN TWO MINUTES",
            COLOR.textDim, width, height)
        local buttonX = left + math.floor((panelWidth - 152) / 2)
        buttonX = connectionButton(
            buttons, buttonX, top + panelHeight - 31,
            "PAIR", "pair", COLOR.route, width, height)
        connectionButton(
            buttons, buttonX, top + panelHeight - 31,
            "BACK", "back", COLOR.panelEdge, width, height)
    else
        local found = model.found or {}
        if #found == 0 then
            local centerX = left + math.floor(panelWidth / 2)
            connectionRadar(centerX, top + 86, width, height)
            drawText(centerX - 68, top + 134,
                "NO AIRCRAFT FOUND", COLOR.warning, width, height)
            drawText(centerX - 136, top + 146,
                "PRESS PAIR IN THE COCKPIT AND REFRESH",
                COLOR.textDim, width, height)
        else
            local maximumRows = math.max(
                1, math.floor((panelHeight - 100) / 24))
            local first = math.max(1,
                math.min(model.selected - maximumRows + 1,
                    math.max(1, #found - maximumRows + 1)))
            for row = 0, maximumRows - 1 do
                local index = first + row
                local candidate = found[index]
                if not candidate then break end
                local cardLeft = left + 12
                local cardTop = top + 38 + row * 24
                local selected = index == model.selected
                fillPixels(
                    cardLeft, cardTop,
                    selected and COLOR.route or COLOR.background,
                    panelWidth - 24, 20)
                fillPixels(
                    cardLeft + 2, cardTop + 2,
                    selected and COLOR.panel or COLOR.panelEdge,
                    panelWidth - 28, 16)
                drawText(cardLeft + 10, cardTop + 6,
                    tostring(candidate.callsign or "AIRCRAFT"),
                    COLOR.text, width, height)
                drawText(cardLeft + 90, cardTop + 6,
                    ("ID:%d"):format(candidate.id),
                    COLOR.textDim, width, height)
                local stateLabel = isSavedAircraft(candidate)
                    and "PAIRED"
                    or candidate.pairingOpen
                        and "PAIRING OPEN" or "LOCKED"
                local labelX = cardLeft + panelWidth
                    - 38 - #stateLabel * 4
                drawText(labelX, cardTop + 6, stateLabel,
                    isSavedAircraft(candidate)
                        and COLOR.traffic
                        or candidate.pairingOpen
                            and COLOR.route or COLOR.warning,
                    width, height)
                cards[#cards + 1] = {
                    x1 = cardLeft,
                    x2 = cardLeft + panelWidth - 25,
                    y1 = cardTop,
                    y2 = cardTop + 19,
                    index = index
                }
            end
        end
        if #found > 0 then
            local buttonX = left + math.floor((panelWidth - 244) / 2)
            buttonX = connectionButton(
                buttons, buttonX, top + panelHeight - 31,
                "SELECT", "select", COLOR.route, width, height)
            buttonX = connectionButton(
                buttons, buttonX, top + panelHeight - 31,
                "REFRESH", "refresh", COLOR.panelEdge, width, height)
            connectionButton(
                buttons, buttonX, top + panelHeight - 31,
                "QUIT", "quit", COLOR.warning, width, height)
        else
            local buttonX = left + math.floor((panelWidth - 136) / 2)
            buttonX = connectionButton(
                buttons, buttonX, top + panelHeight - 31,
                "RETRY", "refresh", COLOR.route, width, height)
            connectionButton(
                buttons, buttonX, top + panelHeight - 31,
                "QUIT", "quit", COLOR.warning, width, height)
        end
    end

    if model.message and model.message ~= "" then
        drawText(left + 14, top + panelHeight - 48,
            fitText(model.message, panelWidth - 28),
            COLOR.warning, width, height)
    end

    drawText(8, height - 9,
        model.mode == "code"
            and "TYPE CODE  ENTER PAIR  ESC BACK"
            or "ARROWS SELECT  ENTER OPEN  R REFRESH  Q QUIT",
        COLOR.textDim, width, height)
    connectionUi = {
        buttons = buttons,
        cards = cards
    }
    commitFrame()
end

function connectionHit(x, y)
    for _, card in ipairs(connectionUi and connectionUi.cards or {}) do
        if x >= card.x1 and x <= card.x2
            and y >= card.y1 and y <= card.y2 then
            return "card", card.index
        end
    end
    for _, button in ipairs(connectionUi and connectionUi.buttons or {}) do
        if x >= button.x1 and x <= button.x2
            and y >= button.y1 and y <= button.y2 then
            return button.action
        end
    end
end

function attemptPair(candidate, digits)
    local code = digits:sub(1, 3) .. "-" .. digits:sub(4, 6)
    local response = exchange(candidate.id, "pair_request", {
        code = code,
        name = os.getComputerLabel()
            or ("ATLAS POCKET " .. os.getComputerID())
    }, 2)
    if response and response.op == "pair_accepted"
        and type(response.pairId) == "string"
        and type(response.secret) == "string" then
        config.navigatorId = candidate.id
        config.pairId = response.pairId
        config.secret = response.secret
        config.callsign = candidate.callsign
        saveConfig()
        return acceptConnection(candidate.id, response)
    end
    return false, tostring(response and response.reason or "NO REPLY")
end

function reconnectSavedAircraft(candidate)
    local response = exchange(candidate.id, "hello", {
        pairId = config.pairId,
        secret = config.secret,
        name = os.getComputerLabel()
            or ("ATLAS POCKET " .. os.getComputerID())
    }, 1.5)
    if response and response.op == "hello_accepted" then
        return acceptConnection(candidate.id, response)
    end
    return false, tostring(response and response.reason or "NO REPLY")
end

function connectSaved()
    if type(config.navigatorId) ~= "number"
        or type(config.pairId) ~= "string"
        or type(config.secret) ~= "string" then return false end
    beginConnectionGraphics()
    drawConnectionScreen({
        mode = "reconnecting",
        callsign = config.callsign
    })
    local connectedToSaved = reconnectSavedAircraft({
        id = config.navigatorId
    })
    endConnectionGraphics()
    return connectedToSaved == true
end

function connectionMenu()
    beginConnectionGraphics()
    local found = {}
    local selected = 1
    local mode = "list"
    local candidate
    local digits = ""
    local message
    local rescan = true
    while not quitAll do
        if rescan then
            drawConnectionScreen({ mode = "scanning" })
            found = discoverAircraft()
            selected = clamp(selected, 1, math.max(1, #found))
            mode = "list"
            message = #found == 0
                and "CHECK BOTH ENDER MODEMS" or nil
            rescan = false
        end
        drawConnectionScreen({
            mode = mode,
            found = found,
            selected = selected,
            candidate = candidate,
            code = digits,
            message = message
        })
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            quitAll = true
            break
        end

        local action
        local cardIndex
        if event[1] == "mouse_click" then
            action, cardIndex = connectionHit(event[3], event[4])
            if action == "card" then
                selected = cardIndex
                action = "select"
            end
        elseif event[1] == "key" then
            if mode == "code" then
                if event[2] == keys.backspace then
                    digits = digits:sub(1, -2)
                elseif event[2] == keys.enter then
                    action = "pair"
                elseif event[2] == keys.escape then
                    action = "back"
                end
            else
                if event[2] == keys.up and #found > 0 then
                    selected = selected == 1 and #found or selected - 1
                elseif event[2] == keys.down and #found > 0 then
                    selected = selected == #found and 1 or selected + 1
                elseif event[2] == keys.enter then
                    action = "select"
                end
            end
        elseif event[1] == "char" then
            local character = event[2]:lower()
            if mode == "code" and character:match("%d")
                and #digits < 6 then
                digits = digits .. character
            elseif mode ~= "code" and character == "r" then
                action = "refresh"
            elseif mode ~= "code" and character == "q" then
                action = "quit"
            end
        end

        if action == "quit" then
            quitAll = true
            break
        elseif action == "refresh" then
            rescan = true
        elseif action == "back" then
            mode = "list"
            digits = ""
            message = nil
        elseif action == "select" and found[selected] then
            candidate = found[selected]
            if isSavedAircraft(candidate) then
                drawConnectionScreen({
                    mode = "reconnecting",
                    callsign = candidate.callsign
                })
                local restored, reason =
                    reconnectSavedAircraft(candidate)
                if restored then
                    endConnectionGraphics()
                    return true
                end
                mode = "list"
                message = "LINK FAILED: " .. tostring(reason)
            elseif candidate.pairingOpen then
                mode = "code"
                digits = ""
                message = nil
            else
                message = "OPEN PAIR ON THAT AIRCRAFT THEN REFRESH"
            end
        elseif action == "pair" then
            if #digits ~= 6 then
                message = "ENTER ALL SIX DIGITS"
            else
                drawConnectionScreen({
                    mode = "reconnecting",
                    callsign = candidate.callsign
                })
                local paired, reason = attemptPair(candidate, digits)
                if paired then
                    endConnectionGraphics()
                    return true
                end
                mode = "code"
                digits = ""
                message = "PAIRING FAILED: " .. tostring(reason)
            end
        end
    end
    endConnectionGraphics()
    return false
end

function sendCompanion(operation, payload)
    if not navigatorId or not session then return nil end
    payload = payload or {}
    payload.session = session
    return sendRaw(navigatorId, operation, payload)
end

function installState(value)
    if type(value) ~= "table" then return false end
    state = value
    stateReceivedAt = now()
    connected = true
    if state.callsign then config.callsign = state.callsign end
    local craft = aircraft()
    if craft and not viewX then
        viewX = craft.x
        viewZ = craft.z
    end
    return true
end

function requestHello()
    if type(config.navigatorId) ~= "number"
        or type(config.pairId) ~= "string"
        or type(config.secret) ~= "string"
        or now() - lastHelloRequest < 1500 then return end
    navigatorId = config.navigatorId
    lastHelloRequest = now()
    helloRequestId = sendRaw(navigatorId, "hello", {
        pairId = config.pairId,
        secret = config.secret,
        name = os.getComputerLabel()
            or ("ATLAS POCKET " .. os.getComputerID())
    })
end

function handleTiles(message)
    if not tilePending or message.requestId ~= tilePending.requestId
        or type(message.items) ~= "table" then return end
    local current = now()
    for _, item in ipairs(message.items) do
        if type(item) == "table"
            and type(item.dimension) == "string"
            and type(item.chunkX) == "number"
            and type(item.chunkZ) == "number" then
            local key = tileKey(item.dimension, item.chunkX, item.chunkZ)
            if item.status == "data" and item.tile then
                installTile(item.tile, true)
            elseif item.status == "pending" then
                local wanted = wantedTiles[key]
                if wanted then wanted.notBefore = current + 400 end
            else
                wantedTiles[key] = nil
                missingUntil[key] = current
                    + (item.status == "unavailable" and 3000 or 15000)
            end
        end
    end
    tilePending = nil
end

function handleNetworkMessage(sender, message)
    if sender ~= navigatorId or type(message) ~= "table"
        or message.atlas ~= atlas.VERSION then return end
    if message.op == "state" and message.session == session then
        installState(message.state)
    elseif message.op == "hello_accepted"
        and message.requestId == helloRequestId then
        session = message.session
        helloRequestId = nil
        acceptConnection(sender, message)
    elseif message.op == "auth_required" then
        session = nil
        connected = false
        statusText = "RECONNECTING"
    elseif message.op == "tiles_data" and message.session == session then
        handleTiles(message)
    elseif (message.op == "route_updated"
        or message.op == "route_rejected")
        and message.session == session then
        if type(message.route) == "table" then
            state = state or {}
            state.route = message.route
        end
        statusText = message.op == "route_updated"
            and "ROUTE SAVED"
            or ("ROUTE REJECTED: " .. tostring(message.reason or "UNKNOWN"))
    elseif message.op == "pair_required" then
        session = nil
        connected = false
        statusText = "PAIRING REQUIRED"
    end
end

function prepareViewport()
    local display = lastDisplay
    local craft = aircraft()
    if not display or not craft then return end
    local minimumX = display.mapViewX
        - display.centerX / display.pixelsPerBlock
    local maximumX = display.mapViewX
        + (display.width - display.centerX) / display.pixelsPerBlock
    local minimumZ = display.mapViewZ
        - display.centerY / display.pixelsPerBlock
    local maximumZ = display.mapViewZ
        + (display.mapHeight - display.centerY) / display.pixelsPerBlock
    local minimumChunkX = math.floor(minimumX / 16) - 1
    local maximumChunkX = math.floor(maximumX / 16) + 1
    local minimumChunkZ = math.floor(minimumZ / 16) - 1
    local maximumChunkZ = math.floor(maximumZ / 16) + 1
    local signature = table.concat({
        craft.dimension, minimumChunkX, maximumChunkX,
        minimumChunkZ, maximumChunkZ
    }, ":")
    if viewportPlan and viewportPlan.signature == signature then return end
    viewportPlan = {
        signature = signature,
        dimension = craft.dimension,
        minX = minimumChunkX,
        maxX = maximumChunkX,
        minZ = minimumChunkZ,
        maxZ = maximumChunkZ,
        x = minimumChunkX,
        z = minimumChunkZ
    }
end

function inspectViewport()
    prepareViewport()
    if not viewportPlan then return end
    local craft = aircraft()
    local centerChunkX = craft and math.floor(craft.x / 16) or 0
    local centerChunkZ = craft and math.floor(craft.z / 16) or 0
    for _ = 1, VISIBLE_INSPECTIONS do
        local plan = viewportPlan
        local chunkX = plan.x
        local chunkZ = plan.z
        local key = tileKey(plan.dimension, chunkX, chunkZ)
        if not tiles[key] and now() >= (missingUntil[key] or 0) then
            if not loadCachedTile(plan.dimension, chunkX, chunkZ) then
                wantedTiles[key] = wantedTiles[key] or {
                    dimension = plan.dimension,
                    chunkX = chunkX,
                    chunkZ = chunkZ,
                    priority = (chunkX - centerChunkX) ^ 2
                        + (chunkZ - centerChunkZ) ^ 2,
                    notBefore = 0
                }
            end
        end
        plan.x = plan.x + 1
        if plan.x > plan.maxX then
            plan.x = plan.minX
            plan.z = plan.z + 1
            if plan.z > plan.maxZ then plan.z = plan.minZ end
        end
    end
end

function nextTileBatch()
    local choices = {}
    local current = now()
    for key, request in pairs(wantedTiles) do
        if current >= (request.notBefore or 0) then
            choices[#choices + 1] = { key = key, request = request }
        end
    end
    table.sort(choices, function(a, b)
        if a.request.priority == b.request.priority then
            return a.key < b.key
        end
        return a.request.priority < b.request.priority
    end)
    while #choices > TILE_BATCH_SIZE do table.remove(choices) end
    return choices
end

function requestTiles()
    if not session or tilePending then return end
    local choices = nextTileBatch()
    if #choices == 0 then return end
    local requests = {}
    for _, choice in ipairs(choices) do
        requests[#requests + 1] = {
            dimension = choice.request.dimension,
            chunkX = choice.request.chunkX,
            chunkZ = choice.request.chunkZ
        }
        choice.request.notBefore = now() + TILE_TIMEOUT_MS
    end
    local requestId = sendCompanion("get_tiles", { tiles = requests })
    if requestId then
        tilePending = {
            requestId = requestId,
            sentAt = now()
        }
    end
end

function networkLoop()
    local timer = os.startTimer(NETWORK_SECONDS)
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            quitAll = true
            running = false
            return
        elseif event[1] == "rednet_message"
            and event[4] == atlas.PROTOCOL_COMPANION_LINK then
            handleNetworkMessage(event[2], event[3])
        elseif event[1] == "timer" and event[2] == timer then
            local current = now()
            if current - stateReceivedAt > STATE_LOST_MS then
                connected = false
                statusText = session and "LINK LOST" or "RECONNECTING"
            end
            if not session then
                requestHello()
            elseif current - lastStateRequest >= STATE_REQUEST_MS then
                sendCompanion("get_state", {})
                lastStateRequest = current
            end
            if tilePending
                and current - tilePending.sentAt > TILE_TIMEOUT_MS then
                tilePending = nil
            end
            inspectViewport()
            requestTiles()
            timer = os.startTimer(NETWORK_SECONDS)
        end
    end
end

function mapColorAt(dimension, worldX, worldZ)
    local blockX = math.floor(worldX)
    local blockZ = math.floor(worldZ)
    local chunkX = math.floor(blockX / 16)
    local chunkZ = math.floor(blockZ / 16)
    local tile = tiles[tileKey(dimension, chunkX, chunkZ)]
    if not tile then return BYTE[COLOR.unknown] end
    local localX = blockX - chunkX * 16
    local localZ = blockZ - chunkZ * 16
    return tile.pixels:sub(localZ * 16 + localX + 1,
        localZ * 16 + localX + 1)
end

function buildMapRows(request)
    local rows = {}
    for pixelY = 0, request.mapHeight - 1 do
        if mapBuildRequest ~= request
            and (not mapBuildRequest
                or mapBuildRequest.layoutSignature
                    ~= request.layoutSignature) then
            return nil
        end
        local row = {}
        local worldZ = request.mapViewZ
            + (pixelY - request.centerY) / request.pixelsPerBlock
        for pixelX = 0, request.width - 1 do
            local worldX = request.mapViewX
                + (pixelX - request.centerX) / request.pixelsPerBlock
            row[pixelX + 1] = mapColorAt(
                request.dimension, worldX, worldZ)
        end
        rows[pixelY + 1] = table.concat(row)
        if pixelY % 8 == 7 then
            os.queueEvent("atlas_companion_map_step")
            os.pullEvent("atlas_companion_map_step")
        end
    end
    return rows
end

function mapBuilderLoop()
    while running do
        local event = os.pullEventRaw()
        if event == "terminate" then return end
        if event == MAP_EVENT then
            while running and mapBuildRequest do
                local request = mapBuildRequest
                if mapCache.signature == request.signature then break end
                local rows = buildMapRows(request)
                local latest = mapBuildRequest
                if rows and (latest == request
                    or latest
                        and latest.layoutSignature
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
                    if latest == request then break end
                end
            end
        end
    end
end

function blankRows(width, height)
    local key = width .. ":" .. height
    if blankCache[key] then return blankCache[key] end
    local rows = {}
    local row = string.rep(BYTE[COLOR.unknown], width)
    for index = 1, height do rows[index] = row end
    blankCache[key] = rows
    return rows
end

function beginFrame(width, height, color)
    local row = string.rep(BYTE[color], width)
    local rows = {}
    for y = 1, height do rows[y] = row end
    activeFrame = {
        width = width,
        height = height,
        rows = rows,
        mutable = {}
    }
end

function mutableFrameRow(y)
    local frame = activeFrame
    local rowIndex = y + 1
    local mutable = frame.mutable[rowIndex]
    if mutable then return mutable end
    mutable = {}
    local source = frame.rows[rowIndex]
    for x = 1, frame.width do
        mutable[x] = source:sub(x, x)
    end
    frame.mutable[rowIndex] = mutable
    return mutable
end

function fillPixels(x, y, color, width, height)
    local frame = activeFrame
    if not frame then
        return term.drawPixels(x, y, color, width, height)
    end
    local left = math.max(0, math.floor(x))
    local top = math.max(0, math.floor(y))
    local right = math.min(
        frame.width - 1, math.floor(x + width - 1))
    local bottom = math.min(
        frame.height - 1, math.floor(y + height - 1))
    if right < left or bottom < top then return end
    local pixel = BYTE[color]
    for pixelY = top, bottom do
        local row = mutableFrameRow(pixelY)
        for pixelX = left, right do
            row[pixelX + 1] = pixel
        end
    end
end

function putFrameRows(x, y, rows, width, height)
    local frame = activeFrame
    if not frame then
        return term.drawPixels(x, y, rows, width, height)
    end
    if x == 0 and width == frame.width then
        for rowIndex = 1, height do
            local target = y + rowIndex
            local source = rows[rowIndex]
            if target >= 1 and target <= frame.height
                and source and #source == width then
                frame.rows[target] = source
                frame.mutable[target] = nil
            end
        end
        return
    end
    for sourceY = 0, height - 1 do
        local source = rows[sourceY + 1]
        if source then
            for sourceX = 0, width - 1 do
                local targetX = x + sourceX
                local targetY = y + sourceY
                if targetX >= 0 and targetX < frame.width
                    and targetY >= 0 and targetY < frame.height then
                    local row = mutableFrameRow(targetY)
                    row[targetX + 1] = source:sub(
                        sourceX + 1, sourceX + 1)
                end
            end
        end
    end
end

function abandonFrame()
    activeFrame = nil
    pcall(term.setFrozen, false)
end

function commitFrame()
    local frame = activeFrame
    if not frame then return end
    activeFrame = nil
    for rowIndex, mutable in pairs(frame.mutable) do
        frame.rows[rowIndex] = table.concat(mutable)
    end
    local frozen = false
    local ok, failure = xpcall(function()
        term.setFrozen(true)
        frozen = true
        term.drawPixels(
            0, 0, frame.rows, frame.width, frame.height)
    end, debug.traceback)
    if frozen then pcall(term.setFrozen, false) end
    if not ok then error(failure, 0) end
end

function drawPixel(x, y, color, width, height)
    if x >= 0 and x < width and y >= 0 and y < height then
        if activeFrame then
            local row = mutableFrameRow(math.floor(y))
            row[math.floor(x) + 1] = BYTE[color]
        else
            term.setPixel(x, y, color)
        end
    end
end

function drawText(x, y, text, color, width, height)
    text = tostring(text):upper()
    for index = 1, #text do
        local glyph = FONT[text:sub(index, index)] or FONT["?"]
        local glyphX = x + (index - 1) * 4
        for row = 0, 4 do
            local bits = glyph[row + 1]
            for column = 0, 2 do
                if math.floor(bits / 2 ^ (2 - column)) % 2 == 1 then
                    drawPixel(glyphX + column, y + row,
                        color, width, height)
                end
            end
        end
    end
end

function fitText(text, width)
    local maximum = math.max(0, math.floor((width - 4) / 4))
    text = tostring(text)
    if #text <= maximum then return text end
    return text:sub(1, math.max(0, maximum - 1)) .. "?"
end

function drawLine(x0, y0, x1, y1, color, width, height)
    x0 = math.floor(x0 + 0.5)
    y0 = math.floor(y0 + 0.5)
    x1 = math.floor(x1 + 0.5)
    y1 = math.floor(y1 + 0.5)
    local dx = math.abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math.abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local failure = dx + dy
    while true do
        drawPixel(x0, y0, color, width, height)
        if x0 == x1 and y0 == y1 then break end
        local doubled = failure * 2
        if doubled >= dy then failure = failure + dy; x0 = x0 + sx end
        if doubled <= dx then failure = failure + dx; y0 = y0 + sy end
    end
end

function worldToScreen(x, z, display)
    return display.centerX
            + (x - display.mapViewX) * display.pixelsPerBlock,
        display.mapTop + display.centerY
            + (z - display.mapViewZ) * display.pixelsPerBlock
end

function drawAircraft(x, y, heading, width, height)
    local radians = math.rad(heading or 0)
    local forwardX = math.sin(radians)
    local forwardY = -math.cos(radians)
    local rightX = math.cos(radians)
    local rightY = math.sin(radians)
    for longitudinal = -4, 7 do
        local integerWidth = math.floor(
            (7 - longitudinal) / 11 * 4 + 0.5)
        for lateral = -integerWidth, integerWidth do
            local pixelX = math.floor(
                x + forwardX * longitudinal + rightX * lateral + 0.5)
            local pixelY = math.floor(
                y + forwardY * longitudinal + rightY * lateral + 0.5)
            local edge = longitudinal == -4 or longitudinal == 7
                or math.abs(lateral) == integerWidth
            drawPixel(pixelX, pixelY,
                edge and COLOR.aircraftEdge or COLOR.aircraft,
                width, height)
        end
    end
end

function drawToolbarButton(buttons, x, y, label, action, width, height)
    local buttonWidth = #label * 4 + 7
    fillPixels(x, y, COLOR.panelEdge, buttonWidth, 7)
    drawText(x + 4, y + 1, label, COLOR.text, width, height)
    buttons[#buttons + 1] = {
        x1 = x, x2 = x + buttonWidth - 1,
        y1 = y, y2 = y + 6,
        action = action
    }
    return x + buttonWidth + 2
end

function drawRelinkDialog(width, height)
    if not linkDialog then return end
    local dialogWidth = math.min(292, width - 24)
    local dialogHeight = 92
    local left = math.floor((width - dialogWidth) / 2)
    local top = math.floor((height - dialogHeight) / 2)
    fillPixels(left, top, COLOR.panelEdge, dialogWidth, dialogHeight)
    fillPixels(left + 2, top + 2, COLOR.panel,
        dialogWidth - 4, dialogHeight - 4)
    drawText(left + 12, top + 11,
        "RE-LINK ATLAS COMPANION?",
        COLOR.text, width, height)
    drawText(left + 12, top + 27,
        "THIS WILL DISCONNECT FROM",
        COLOR.textDim, width, height)
    drawText(left + 12, top + 38,
        tostring(state and state.callsign
            or config.callsign or "CURRENT AIRCRAFT"),
        COLOR.route, width, height)
    drawText(left + 12, top + 50,
        "THE SAVED PAIRING WILL NOT BE DELETED",
        COLOR.textDim, width, height)

    local cancelWidth = 72
    local confirmWidth = 88
    local buttonTop = top + dialogHeight - 22
    local confirmLeft = left + dialogWidth - confirmWidth - 10
    local cancelLeft = confirmLeft - cancelWidth - 8
    fillPixels(cancelLeft, buttonTop,
        COLOR.panelEdge, cancelWidth, 13)
    fillPixels(confirmLeft, buttonTop,
        COLOR.warning, confirmWidth, 13)
    drawText(cancelLeft + 12, buttonTop + 4,
        "CANCEL", COLOR.text, width, height)
    drawText(confirmLeft + 12, buttonTop + 4,
        "RE-LINK", COLOR.text, width, height)
    linkDialog.cancel = {
        x1 = cancelLeft, x2 = cancelLeft + cancelWidth - 1,
        y1 = buttonTop, y2 = buttonTop + 12
    }
    linkDialog.confirm = {
        x1 = confirmLeft, x2 = confirmLeft + confirmWidth - 1,
        y1 = buttonTop, y2 = buttonTop + 12
    }
end

function confirmRelink()
    linkDialog = nil
    switchRequested = true
    running = false
end

function cancelRelink()
    linkDialog = nil
    statusText = "RE-LINK CANCELLED"
end

function handleRelinkEvent(event)
    if event[1] == "key" then
        if event[2] == keys.enter then
            confirmRelink()
        elseif event[2] == keys.escape then
            cancelRelink()
        end
    elseif event[1] == "char" then
        local character = event[2]:lower()
        if character == "y" then
            confirmRelink()
        elseif character == "n" then
            cancelRelink()
        end
    elseif event[1] == "mouse_click" then
        local x = event[3]
        local y = event[4]
        local cancel = linkDialog.cancel
        local confirm = linkDialog.confirm
        if confirm and x >= confirm.x1 and x <= confirm.x2
            and y >= confirm.y1 and y <= confirm.y2 then
            confirmRelink()
        elseif cancel and x >= cancel.x1 and x <= cancel.x2
            and y >= cancel.y1 and y <= cancel.y2 then
            cancelRelink()
        end
    end
end

function bearing(x1, z1, x2, z2)
    local radians
    if math.atan2 then
        radians = math.atan2(x2 - x1, -(z2 - z1))
    else
        radians = math.atan(x2 - x1, -(z2 - z1))
    end
    return (math.deg(radians) + 360) % 360
end

function distance(x1, z1, x2, z2)
    return math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
end

function drawOverlays(display, width, height)
    local craft = aircraft()
    if not craft then return end
    local routeValue = route()
    local waypointValues = type(routeValue.waypoints) == "table"
        and routeValue.waypoints or {}
    local previousX = craft.x
    local previousZ = craft.z
    for index = tonumber(routeValue.active) or 1, #waypointValues do
        local waypoint = waypointValues[index]
        local fromX, fromY = worldToScreen(previousX, previousZ, display)
        local toX, toY = worldToScreen(waypoint.x, waypoint.z, display)
        drawLine(fromX, fromY, toX, toY, COLOR.route, width, height)
        for offset = -2, 2 do
            drawPixel(math.floor(toX + 0.5) + offset,
                math.floor(toY + 0.5), COLOR.waypoint, width, height)
            drawPixel(math.floor(toX + 0.5),
                math.floor(toY + 0.5) + offset,
                COLOR.waypoint, width, height)
        end
        drawText(math.floor(toX + 4), math.floor(toY - 2),
            tostring(index), COLOR.waypoint, width, height)
        previousX = waypoint.x
        previousZ = waypoint.z
    end

    for _, poi in ipairs(pois()) do
        if poi.dimension == craft.dimension then
            local x, y = worldToScreen(poi.x, poi.z, display)
            x = math.floor(x + 0.5)
            y = math.floor(y + 0.5)
            for offset = -3, 3 do
                local across = 3 - math.abs(offset)
                for pixel = -across, across do
                    drawPixel(x + pixel, y + offset,
                        COLOR.poi, width, height)
                end
            end
            if poi.id == selectedPoiId then
                drawPixel(x, y - 5, COLOR.text, width, height)
                drawPixel(x - 5, y, COLOR.text, width, height)
                drawPixel(x + 5, y, COLOR.text, width, height)
            end
        end
    end

    for _, contact in ipairs(type(state.traffic) == "table"
        and state.traffic or {}) do
        if contact.dimension == craft.dimension
            and contact.callsign ~= state.callsign then
            local x, y = worldToScreen(contact.x, contact.z, display)
            drawPixel(math.floor(x), math.floor(y - 2),
                COLOR.traffic, width, height)
            drawPixel(math.floor(x - 2), math.floor(y),
                COLOR.traffic, width, height)
            drawPixel(math.floor(x + 2), math.floor(y),
                COLOR.traffic, width, height)
            drawPixel(math.floor(x), math.floor(y + 2),
                COLOR.traffic, width, height)
        end
    end

    local aircraftX, aircraftY = worldToScreen(craft.x, craft.z, display)
    drawAircraft(aircraftX, aircraftY, craft.heading,
        width, height)
end

function requestMapBuild(request)
    if mapCache.signature == request.signature
        or mapBuildRequest and mapBuildRequest.signature == request.signature then
        return
    end
    mapBuildRequest = request
    os.queueEvent(MAP_EVENT)
end

function renderFrame()
    local craft = aircraft()
    if not craft then return end
    if follow or not viewX then
        viewX = craft.x
        viewZ = craft.z
    end
    local width, height = term.getSize(2)
    if width ~= lastGraphicsWidth or height ~= lastGraphicsHeight then
        lastGraphicsWidth = width
        lastGraphicsHeight = height
        mapCache = {}
        mapBuildRequest = nil
        blankCache = {}
        lastDisplay = nil
        viewportPlan = nil
    end
    local mapTop = HEADER_HEIGHT
    local mapHeight = height - HEADER_HEIGHT - FOOTER_HEIGHT
    if mapHeight < 1 then
        error("Pocket terminal is too short for ATLAS Companion", 0)
    end
    local pixelsPerBlock = zoom()
    local centerX = (width - 1) / 2
    local centerY = (mapHeight - 1) / 2
    local blocksPerPixel = 1 / pixelsPerBlock
    local stepX = math.floor(viewX / blocksPerPixel + 0.5)
    local stepZ = math.floor(viewZ / blocksPerPixel + 0.5)
    local mapViewX = stepX * blocksPerPixel
    local mapViewZ = stepZ * blocksPerPixel
    local signature = table.concat({
        width, mapHeight, pixelsPerBlock, stepX, stepZ,
        craft.dimension, terrainRevision
    }, ":")
    local layoutSignature = table.concat({
        width, mapHeight, pixelsPerBlock, stepX, stepZ,
        craft.dimension
    }, ":")
    requestMapBuild({
        signature = signature,
        layoutSignature = layoutSignature,
        width = width,
        mapHeight = mapHeight,
        pixelsPerBlock = pixelsPerBlock,
        mapViewX = mapViewX,
        mapViewZ = mapViewZ,
        dimension = craft.dimension,
        centerX = centerX,
        centerY = centerY
    })

    local rows = blankRows(width, mapHeight)
    local displayViewX = mapViewX
    local displayViewZ = mapViewZ
    if mapCache.rows
        and mapCache.width == width
        and mapCache.mapHeight == mapHeight
        and mapCache.pixelsPerBlock == pixelsPerBlock
        and mapCache.dimension == craft.dimension then
        rows = mapCache.rows
        displayViewX = mapCache.mapViewX
        displayViewZ = mapCache.mapViewZ
    end
    local display = {
        width = width,
        height = height,
        mapTop = mapTop,
        mapHeight = mapHeight,
        pixelsPerBlock = pixelsPerBlock,
        mapViewX = displayViewX,
        mapViewZ = displayViewZ,
        centerX = centerX,
        centerY = centerY
    }
    lastDisplay = display

    beginFrame(width, height, COLOR.background)
    putFrameRows(0, mapTop, rows, width, mapHeight)
    drawOverlays(display, width, height)
    fillPixels(0, 0, COLOR.panel, width, HEADER_HEIGHT)
    fillPixels(0, HEADER_HEIGHT - 1, COLOR.panelEdge, width, 1)
    fillPixels(0, height - FOOTER_HEIGHT, COLOR.panelEdge, width, 1)
    fillPixels(0, height - FOOTER_HEIGHT + 1,
        COLOR.panel, width, FOOTER_HEIGHT - 1)

    local link = connected and "ONLINE" or "LOST"
    local header = ("ATLAS COMPANION %s LINK:%s"):format(
        tostring(state.callsign or config.callsign or "AIRCRAFT"), link)
    drawText(2, 2, fitText(header, width), COLOR.text, width, height)
    local headingLine = ("HDG:%03d TRK:%03d X:%d Y:%d Z:%d"):format(
        math.floor((craft.heading or 0) + 0.5) % 360,
        math.floor((craft.track or 0) + 0.5) % 360,
        math.floor(craft.x), math.floor(craft.y), math.floor(craft.z))
    drawText(2, 9, fitText(headingLine, width),
        COLOR.textDim, width, height)

    local footerY = height - FOOTER_HEIGHT + 3
    local routeValue = route()
    local nextPoint = routeValue.waypoints
        and routeValue.waypoints[routeValue.active or 1]
    local routeLine
    if nextPoint then
        routeLine = ("NEXT:%s BRG:%03d DIST:%d SPD:%.1f"):format(
            tostring(nextPoint.name or ("WP" .. routeValue.active)),
            math.floor(bearing(
                craft.x, craft.z, nextPoint.x, nextPoint.z) + 0.5),
            math.floor(distance(
                craft.x, craft.z, nextPoint.x, nextPoint.z) + 0.5),
            craft.speed or 0)
    else
        routeLine = ("NO ACTIVE ROUTE SPD:%.1f"):format(craft.speed or 0)
    end
    local detail = pointerDetails
        and now() - pointerDetails.at < 5000 and pointerDetails.text
    drawText(2, footerY, fitText(detail or routeLine, width),
        nextPoint and COLOR.text or COLOR.textDim, width, height)
    local cacheLine = ("MAP:%d QUEUE:%d POI:%d REV:%d %s"):format(
        count(tiles), count(wantedTiles), #pois(),
        tonumber(routeValue.revision) or 0, statusText)
    drawText(2, footerY + 7, fitText(cacheLine, width),
        COLOR.textDim, width, height)

    local buttons = {}
    local toolbarX = 2
    local toolbarY = footerY + 13
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "+", "zoom_in", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "-", "zoom_out", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "ADD", "add", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "GO", "poi_route", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "NEXT", "next", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "DEL", "delete", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "CTR", "center", width, height)
    toolbarX = drawToolbarButton(
        buttons, toolbarX, toolbarY, "LINK", "link", width, height)
    display.buttons = buttons
    drawText(width - 7, mapTop + 3, "N",
        COLOR.text, width, height)
    drawRelinkDialog(width, height)
    commitFrame()
end

function render()
    local ok, failure = xpcall(renderFrame, debug.traceback)
    abandonFrame()
    if ok then
        displayFailures = 0
        return
    end
    displayFailures = displayFailures + 1
    mapCache = {}
    mapBuildRequest = nil
    lastDisplay = nil
    statusText = "DISPLAY RECOVERING"
    if displayFailures >= 3 then
        error(failure, 0)
    end
end

function displayLoop()
    while running do
        if not modal then render() end
        local timer = os.startTimer(UPDATE_SECONDS)
        local event, identifier = os.pullEventRaw()
        while event ~= "terminate"
            and not (event == "timer" and identifier == timer) do
            event, identifier = os.pullEventRaw()
        end
        if event == "terminate" then return end
    end
end

function routeCommand(operation, payload)
    payload = payload or {}
    payload.baseRevision = tonumber(route().revision) or 0
    if not sendCompanion(operation, payload) then
        statusText = "AIRCRAFT LINK REQUIRED"
        return false
    end
    statusText = "SENDING ROUTE CHANGE"
    return true
end

function addWaypoint(x, z, y, name)
    local routeValue = route()
    routeCommand("route_add", {
        waypoint = {
            name = name or ("MOB" .. (#(routeValue.waypoints or {}) + 1)),
            x = math.floor(x + 0.5),
            y = y,
            z = math.floor(z + 0.5)
        }
    })
end

function exactWaypointEditor()
    modal = true
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, false)
    restorePalette()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("ATLAS COMPANION - ADD WAYPOINT")
    print()
    local routeValue = route()
    local defaultName = "MOB" .. (#(routeValue.waypoints or {}) + 1)
    write("Name [" .. defaultName .. "]: ")
    local name = read()
    if name == "" then name = defaultName end
    write("X coordinate (blank cancels): ")
    local xText = read()
    if xText ~= "" then
        write("Z coordinate: ")
        local zText = read()
        write("Altitude (optional): ")
        local yText = read()
        local x = tonumber(xText)
        local z = tonumber(zText)
        local y = yText ~= "" and tonumber(yText) or nil
        if x and z and (yText == "" or y) then
            addWaypoint(x, z, y, name)
        else
            statusText = "INVALID WAYPOINT"
        end
    end
    local ok, failure = pcall(term.setGraphicsMode, 2)
    if not ok then error(failure, 0) end
    configurePalette()
    mapCache = {}
    mapBuildRequest = nil
    modal = false
end

function waypointAt(mouseX, mouseY)
    if not lastDisplay then return nil end
    local routeValue = route()
    local best
    local bestDistance = 10
    for index, waypoint in ipairs(routeValue.waypoints or {}) do
        local x, y = worldToScreen(waypoint.x, waypoint.z, lastDisplay)
        local dx = x - mouseX
        local dy = y - mouseY
        local candidate = math.sqrt(dx * dx + dy * dy)
        if candidate < bestDistance then
            best = index
            bestDistance = candidate
        end
    end
    return best
end

function poiAt(mouseX, mouseY)
    if not lastDisplay then return nil end
    local best
    local bestDistance = 10
    for _, poi in ipairs(pois()) do
        local x, y = worldToScreen(poi.x, poi.z, lastDisplay)
        local dx = x - mouseX
        local dy = y - mouseY
        local candidate = math.sqrt(dx * dx + dy * dy)
        if candidate < bestDistance then
            best = poi
            bestDistance = candidate
        end
    end
    return best
end

function performAction(action)
    if action == "zoom_in" then
        zoomIndex = clamp(zoomIndex + 1, 1, #ZOOM_LEVELS)
        viewportPlan = nil
    elseif action == "zoom_out" then
        zoomIndex = clamp(zoomIndex - 1, 1, #ZOOM_LEVELS)
        viewportPlan = nil
    elseif action == "add" then
        exactWaypointEditor()
    elseif action == "poi_route" then
        local selected
        for _, poi in ipairs(pois()) do
            if poi.id == selectedPoiId then selected = poi; break end
        end
        if selected then
            addWaypoint(selected.x, selected.z, selected.y, selected.name)
        else
            statusText = "SELECT A POI FIRST"
        end
    elseif action == "next" then
        local routeValue = route()
        local nextIndex = (routeValue.active or 1) + 1
        if routeValue.waypoints and routeValue.waypoints[nextIndex] then
            routeCommand("route_set_active", { index = nextIndex })
        end
    elseif action == "delete" then
        local routeValue = route()
        if routeValue.waypoints
            and routeValue.waypoints[routeValue.active or 1] then
            routeCommand("route_delete", {
                index = routeValue.active or 1
            })
        end
    elseif action == "center" then
        follow = true
        local craft = aircraft()
        if craft then viewX = craft.x; viewZ = craft.z end
        viewportPlan = nil
    elseif action == "link" then
        linkDialog = {}
        statusText = "CONFIRM RE-LINK"
    end
end

function inspectMap(mouseX, mouseY)
    if not lastDisplay then return end
    local x = lastDisplay.mapViewX
        + (mouseX - lastDisplay.centerX)
            / lastDisplay.pixelsPerBlock
    local z = lastDisplay.mapViewZ
        + (mouseY - lastDisplay.mapTop - lastDisplay.centerY)
            / lastDisplay.pixelsPerBlock
    pointerDetails = {
        at = now(),
        text = ("X:%d Z:%d"):format(
            math.floor(x + 0.5), math.floor(z + 0.5))
    }
end

function pan(dx, dz)
    follow = false
    local amount = math.max(1, math.floor(24 / zoom()))
    viewX = (viewX or 0) + dx * amount
    viewZ = (viewZ or 0) + dz * amount
    viewportPlan = nil
end

function inputLoop()
    while running do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then
            quitAll = true
            running = false
        elseif event[1] == "term_resize" then
            abandonFrame()
            mapCache = {}
            mapBuildRequest = nil
            blankCache = {}
            lastDisplay = nil
            lastGraphicsWidth = nil
            lastGraphicsHeight = nil
            viewportPlan = nil
            statusText = "DISPLAY RESIZED"
        elseif linkDialog then
            handleRelinkEvent(event)
        elseif event[1] == "char" then
            local character = event[2]:lower()
            if character == "q" then
                quitAll = true
                running = false
            elseif character == "w" then
                exactWaypointEditor()
            elseif character == "n" then
                performAction("next")
            elseif character == "x" then
                performAction("delete")
            elseif character == "l" then
                performAction("link")
            elseif character == "+" or character == "=" then
                performAction("zoom_in")
            elseif character == "-" or character == "_" then
                performAction("zoom_out")
            end
        elseif event[1] == "key" then
            if event[2] == keys.left then pan(-1, 0)
            elseif event[2] == keys.right then pan(1, 0)
            elseif event[2] == keys.up then pan(0, -1)
            elseif event[2] == keys.down then pan(0, 1)
            elseif event[2] == keys.space
                or event[2] == keys.escape then
                performAction("center")
            end
        elseif event[1] == "mouse_scroll" then
            inspectMap(event[3], event[4])
            performAction(event[2] < 0 and "zoom_in" or "zoom_out")
        elseif event[1] == "mouse_click" and lastDisplay then
            local button = event[2]
            local mouseX = event[3]
            local mouseY = event[4]
            local handled = false
            for _, uiButton in ipairs(lastDisplay.buttons or {}) do
                if mouseX >= uiButton.x1 and mouseX <= uiButton.x2
                    and mouseY >= uiButton.y1
                    and mouseY <= uiButton.y2 then
                    performAction(uiButton.action)
                    handled = true
                    break
                end
            end
            if not handled
                and mouseY >= lastDisplay.mapTop
                and mouseY < lastDisplay.mapTop + lastDisplay.mapHeight then
                local poi = poiAt(mouseX, mouseY)
                if poi then
                    selectedPoiId = poi.id
                    pointerDetails = {
                        at = now(),
                        text = ("POI %s X:%d Z:%d"):format(
                            tostring(poi.name), poi.x, poi.z)
                    }
                    handled = true
                end
                if not handled and button == 2 then
                    local index = waypointAt(mouseX, mouseY)
                    if index then
                        routeCommand("route_delete", { index = index })
                        handled = true
                    end
                end
                if not handled and button == 1 then
                    local worldX = lastDisplay.mapViewX
                        + (mouseX - lastDisplay.centerX)
                            / lastDisplay.pixelsPerBlock
                    local worldZ = lastDisplay.mapViewZ
                        + (mouseY - lastDisplay.mapTop
                            - lastDisplay.centerY)
                            / lastDisplay.pixelsPerBlock
                    addWaypoint(worldX, worldZ)
                    handled = true
                elseif not handled then
                    viewX = lastDisplay.mapViewX
                        + (mouseX - lastDisplay.centerX)
                            / lastDisplay.pixelsPerBlock
                    viewZ = lastDisplay.mapViewZ
                        + (mouseY - lastDisplay.mapTop
                            - lastDisplay.centerY)
                            / lastDisplay.pixelsPerBlock
                    follow = false
                    viewportPlan = nil
                end
            end
            if not handled then inspectMap(mouseX, mouseY) end
        end
    end
end

function runGraphics()
    if not term.setGraphicsMode or not term.drawPixels
        or not term.setFrozen then
        error("CC: Graphics is required by ATLAS Companion", 0)
    end
    local ok, failure = pcall(term.setGraphicsMode, 2)
    if not ok then error("Cannot enter graphics mode: " .. tostring(failure), 0) end
    configurePalette()
    running = true
    switchRequested = false
    linkDialog = nil
    viewportPlan = nil
    mapCache = {}
    mapBuildRequest = nil
    lastGraphicsWidth = nil
    lastGraphicsHeight = nil
    displayFailures = 0
    parallel.waitForAny(
        inputLoop,
        displayLoop,
        mapBuilderLoop,
        networkLoop)
    running = false
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, false)
    restorePalette()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function main()
    math.randomseed(atlas.now() + os.getComputerID())
    capturePalette()
    local wireless = atlas.openWirelessRednet()
    if #wireless == 0 then
        error("ATLAS Companion requires a wireless or Ender Modem", 0)
    end

    local trySaved = true
    while not quitAll do
        session = nil
        connected = false
        state = nil
        stateReceivedAt = 0
        viewX = nil
        viewZ = nil
        if not trySaved or not connectSaved() then
            if not connectionMenu() then break end
        end
        trySaved = false
        runGraphics()
        if switchRequested then
            statusText = "SELECT AIRCRAFT"
        else
            break
        end
    end
end

local ok, failure = xpcall(main, debug.traceback)
pcall(term.setFrozen, false)
pcall(term.setGraphicsMode, false)
restorePalette()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok then
    printError(failure)
else
    print("ATLAS Companion closed.")
end
