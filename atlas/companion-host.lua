local LIBRARY = fs.exists("/atlas/lib.lua") and "/atlas/lib.lua" or "atlas/lib.lua"
local atlas = dofile(LIBRARY)
local host = {}
local Host = {}
Host.__index = Host

local STORE_PATH = "/atlas/companions.dat"
local SESSION_IDLE_MS = 15000
local STATE_PUSH_MS = 200
local MAX_TILE_REQUESTS = 14
local MAX_COVERAGE_REQUESTS = 16

local function now()
    return atlas.now()
end

local function copyWaypoint(value)
    return {
        name = tostring(value.name or "WP"),
        x = value.x,
        y = value.y,
        z = value.z
    }
end

local function validPeer(value)
    return type(value) == "table"
        and type(value.id) == "string"
        and type(value.secret) == "string"
        and type(value.computerId) == "number"
end

function Host:save()
    return atlas.writeTable(STORE_PATH, {
        format = 1,
        peers = self.peers
    })
end

function Host:reply(recipient, request, operation, payload)
    return atlas.replyProtocol(
        recipient, atlas.PROTOCOL_COMPANION_LINK,
        request, operation, payload)
end

function Host:host()
    if self.hosted then return true end
    local ok, failure = pcall(
        rednet.host,
        atlas.PROTOCOL_COMPANION_DISCOVERY,
        self.options.callsign())
    if ok then
        self.hosted = true
        return true
    end
    self.lastError = tostring(failure)
    return false
end

function Host:close()
    if self.hosted then
        pcall(rednet.unhost, atlas.PROTOCOL_COMPANION_DISCOVERY)
    end
    self.hosted = false
end

function Host:openPairing(durationMs)
    local value = math.random(0, 999999)
    self.pairing = {
        code = ("%03d-%03d"):format(
            math.floor(value / 1000), value % 1000),
        expiresAt = now() + (tonumber(durationMs) or 120000)
    }
    return self.pairing
end

function Host:cancelPairing()
    self.pairing = nil
end

function Host:pairingStatus()
    if self.pairing and now() >= self.pairing.expiresAt then
        self.pairing = nil
    end
    return self.pairing
end

function Host:peerCount()
    local count = 0
    for _ in pairs(self.peers) do count = count + 1 end
    return count
end

function Host:sessionCount()
    local count = 0
    for _, session in pairs(self.sessions) do
        if now() - session.lastSeen <= SESSION_IDLE_MS then
            count = count + 1
        end
    end
    return count
end

function Host:issueSession(peer, sender)
    local token = atlas.randomId("mobile-session")
    self.sessions[token] = {
        token = token,
        peerId = peer.id,
        sender = sender,
        lastSeen = now(),
        lastPush = 0
    }
    peer.lastSeen = now()
    self:save()
    return token
end

function Host:publicInfo()
    local pairing = self:pairingStatus()
    return {
        callsign = self.options.callsign(),
        computerId = os.getComputerID(),
        pairingOpen = pairing ~= nil,
        pairedDevices = self:peerCount(),
        activeDevices = self:sessionCount(),
        version = atlas.APP_VERSION
    }
end

function Host:state()
    local snapshot = self.options.snapshot()
    snapshot = type(snapshot) == "table" and snapshot or {}
    snapshot.callsign = self.options.callsign()
    snapshot.computerId = os.getComputerID()
    snapshot.version = atlas.APP_VERSION
    snapshot.serverTime = now()
    return snapshot
end

function Host:authenticate(sender, message)
    local session = type(message.session) == "string"
        and self.sessions[message.session] or nil
    if not session or session.sender ~= sender
        or now() - session.lastSeen > SESSION_IDLE_MS then
        if session then self.sessions[message.session] = nil end
        self:reply(sender, message, "auth_required", {})
        return nil
    end
    session.lastSeen = now()
    local peer = self.peers[session.peerId]
    if peer then peer.lastSeen = session.lastSeen end
    return session
end

function Host:handlePairRequest(sender, message)
    local pairing = self:pairingStatus()
    if not pairing or tostring(message.code or "") ~= pairing.code then
        self:reply(sender, message, "pair_rejected", {
            reason = pairing and "incorrect code" or "pairing is closed"
        })
        return
    end

    local peer = {
        id = atlas.randomId("mobile"),
        secret = table.concat({
            atlas.randomId("key"),
            atlas.randomId("key"),
            atlas.randomId("key")
        }, "."),
        computerId = sender,
        name = tostring(message.name or ("POCKET " .. sender)):sub(1, 32),
        createdAt = now(),
        lastSeen = now()
    }
    self.peers[peer.id] = peer
    self.pairing = nil
    local session = self:issueSession(peer, sender)
    self:reply(sender, message, "pair_accepted", {
        pairId = peer.id,
        secret = peer.secret,
        session = session,
        info = self:publicInfo(),
        state = self:state()
    })
end

function Host:handleHello(sender, message)
    local peer = type(message.pairId) == "string"
        and self.peers[message.pairId] or nil
    if not validPeer(peer)
        or peer.secret ~= message.secret
        or peer.computerId ~= sender then
        self:reply(sender, message, "pair_required", {
            info = self:publicInfo()
        })
        return
    end
    local session = self:issueSession(peer, sender)
    self:reply(sender, message, "hello_accepted", {
        session = session,
        info = self:publicInfo(),
        state = self:state()
    })
end

function Host:handleTiles(sender, message, session)
    local requests = type(message.tiles) == "table" and message.tiles or {}
    local items = {}
    for index = 1, math.min(#requests, MAX_TILE_REQUESTS) do
        local request = requests[index]
        if type(request) == "table"
            and type(request.dimension) == "string"
            and type(request.chunkX) == "number"
            and type(request.chunkZ) == "number" then
            local raw, status = self.options.getTile(
                request.dimension,
                math.floor(request.chunkX),
                math.floor(request.chunkZ))
            items[#items + 1] = {
                dimension = request.dimension,
                chunkX = math.floor(request.chunkX),
                chunkZ = math.floor(request.chunkZ),
                status = raw and "data" or status or "pending",
                tile = raw
            }
        end
    end
    self:reply(sender, message, "tiles_data", {
        session = session.token,
        items = items
    })
end

function Host:handleCoverage(sender, message, session)
    local requests = type(message.regions) == "table"
        and message.regions or {}
    local regions = {}
    for index = 1, math.min(#requests, MAX_COVERAGE_REQUESTS) do
        local request = requests[index]
        if type(request) == "table"
            and type(request.dimension) == "string"
            and type(request.regionX) == "number"
            and type(request.regionZ) == "number" then
            local regionX = math.floor(request.regionX)
            local regionZ = math.floor(request.regionZ)
            local data, revision = self.options.getCoverage(
                request.dimension, regionX, regionZ)
            if type(data) == "string" and #data == 128 then
                regions[#regions + 1] = {
                    dimension = request.dimension,
                    regionX = regionX,
                    regionZ = regionZ,
                    data = data,
                    revision = revision
                }
            end
        end
    end
    self:reply(sender, message, "coverage_data", {
        session = session.token,
        regions = regions
    })
end

function Host:handleRoute(sender, message, session)
    local ok, reason, snapshot = self.options.mutateRoute(
        message.op, message)
    self:reply(sender, message, ok and "route_updated" or "route_rejected", {
        session = session.token,
        reason = reason,
        route = snapshot
    })
end

function Host:handle(sender, message)
    if type(message) ~= "table" or message.atlas ~= atlas.VERSION then
        return false
    end
    if message.op == "info_request" then
        self:reply(sender, message, "aircraft_info", self:publicInfo())
        return true
    elseif message.op == "pair_request" then
        self:handlePairRequest(sender, message)
        return true
    elseif message.op == "hello" then
        self:handleHello(sender, message)
        return true
    end

    local session = self:authenticate(sender, message)
    if not session then return true end
    if message.op == "get_state" or message.op == "heartbeat" then
        self:reply(sender, message, "state", {
            session = session.token,
            state = self:state()
        })
    elseif message.op == "get_tiles" then
        self:handleTiles(sender, message, session)
    elseif message.op == "get_coverage" then
        self:handleCoverage(sender, message, session)
    elseif message.op == "route_add"
        or message.op == "route_delete"
        or message.op == "route_set_active" then
        self:handleRoute(sender, message, session)
    else
        self:reply(sender, message, "unsupported", {
            reason = "unsupported companion operation"
        })
    end
    return true
end

function Host:tick()
    local current = now()
    self:pairingStatus()
    for token, session in pairs(self.sessions) do
        if current - session.lastSeen > SESSION_IDLE_MS then
            self.sessions[token] = nil
        elseif current - session.lastPush >= STATE_PUSH_MS then
            atlas.sendProtocol(
                session.sender,
                atlas.PROTOCOL_COMPANION_LINK,
                "state",
                {
                    session = token,
                    state = self:state()
                })
            session.lastPush = current
        end
    end
end

function host.new(options)
    assert(type(options) == "table", "companion host options required")
    assert(type(options.callsign) == "function", "callsign callback required")
    assert(type(options.snapshot) == "function", "snapshot callback required")
    assert(type(options.getTile) == "function", "tile callback required")
    assert(type(options.getCoverage) == "function", "coverage callback required")
    assert(type(options.mutateRoute) == "function", "route callback required")
    local stored = atlas.readTable(STORE_PATH) or {}
    local peers = {}
    for id, peer in pairs(type(stored.peers) == "table"
        and stored.peers or {}) do
        if id == peer.id and validPeer(peer) then peers[id] = peer end
    end
    return setmetatable({
        options = options,
        peers = peers,
        sessions = {},
        hosted = false
    }, Host)
end

return host
