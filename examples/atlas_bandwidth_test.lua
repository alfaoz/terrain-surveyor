-- ATLAS Link Speedtest for CC:Tweaked
--
-- Computer 1:
--   wget run <url> server
--
-- Computer 2:
--   wget run <url> client
--
-- The client writes a paste-ready summary to /atlas-speedtest.txt and full
-- machine-readable measurements to /atlas-bench.txt.

local arguments = { ... }
local mode = (arguments[1] or ""):lower()
local PROTOCOL = "atlas.speedtest.v2"
local HOSTNAME = "atlas-speedtest"
local VERSION = 2
local PING_ROUNDS = 24
local PROBE_ROUNDS = 3
local TRANSFER_SECONDS = 8
local TRANSFER_WINDOW = 8
local TILE_BYTES_ESTIMATE = 6000
local PROBE_SIZES = {
    1024, 4096, 8192, 16384, 24576, 32768,
    49152, 65536, 81920, 98304, 114688, 122880
}

local function nowMs()
    if os.epoch then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function openModems()
    local opened = {}
    peripheral.find("modem", function(name, modem)
        if not rednet.isOpen(name) then rednet.open(name) end
        local ok, wireless = pcall(modem.isWireless)
        opened[#opened + 1] = {
            name = name,
            wireless = ok and wireless or false
        }
        return false
    end)
    if #opened == 0 then error("Attach a modem first", 0) end
    return opened
end

local function makePayload(size)
    local seed = "ATLAS0123456789abcdefghijklmnopqrstuvwxyz"
    return seed:rep(math.ceil(size / #seed)):sub(1, size)
end

local payloadCache = {}
local function payload(size)
    payloadCache[size] = payloadCache[size] or makePayload(size)
    return payloadCache[size]
end

local function average(values)
    if #values == 0 then return nil end
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    return total / #values
end

local function median(values)
    if #values == 0 then return nil end
    local sorted = {}
    for index, value in ipairs(values) do sorted[index] = value end
    table.sort(sorted)
    local middle = math.floor((#sorted + 1) / 2)
    if #sorted % 2 == 1 then return sorted[middle] end
    return (sorted[middle] + sorted[middle + 1]) / 2
end

local function jitter(values)
    if #values < 2 then return 0 end
    local changes = {}
    for index = 2, #values do
        changes[#changes + 1] = math.abs(values[index] - values[index - 1])
    end
    return average(changes) or 0
end

local function minimum(values)
    local result
    for _, value in ipairs(values) do
        result = not result and value or math.min(result, value)
    end
    return result
end

local function maximum(values)
    local result
    for _, value in ipairs(values) do
        result = not result and value or math.max(result, value)
    end
    return result
end

local function rateLabels(bytes, milliseconds)
    if not milliseconds or milliseconds <= 0 then return 0, 0 end
    local bytesPerSecond = bytes * 1000 / milliseconds
    return bytesPerSecond, bytesPerSecond * 8 / 1000000
end

local function progress(label, amount, detail)
    local width = term.getSize()
    local barWidth = math.max(8, math.min(24, width - 25))
    local filled = math.floor(math.max(0, math.min(1, amount)) * barWidth)
    term.setCursorPos(1, select(2, term.getCursorPos()))
    term.clearLine()
    write(("%-9s [%s%s] %s"):format(
        label,
        string.rep("#", filled),
        string.rep("-", barWidth - filled),
        detail or ""))
end

local function receiveMatch(serverId, operation, token, timeoutSeconds)
    local timer = os.startTimer(timeoutSeconds or 3)
    while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then error("Terminated", 0) end
        if event[1] == "timer" and event[2] == timer then return nil end
        if event[1] == "rednet_message"
            and event[2] == serverId
            and event[4] == PROTOCOL
            and type(event[3]) == "table"
            and event[3].version == VERSION
            and event[3].op == operation
            and event[3].token == token then
            return event[3]
        end
    end
end

local function sendMessage(recipient, message)
    message.version = VERSION
    local ok, sent = pcall(rednet.send, recipient, message, PROTOCOL)
    return ok and sent
end

local function runServer()
    local ok = pcall(rednet.host, PROTOCOL, HOSTNAME)
    if not ok then
        pcall(rednet.unhost, PROTOCOL, HOSTNAME)
        rednet.host(PROTOCOL, HOSTNAME)
    end

    local uploadSessions = {}
    term.clear()
    term.setCursorPos(1, 1)
    print("ATLAS LINK SPEEDTEST SERVER")
    print("Computer ID: " .. os.getComputerID())
    print("Waiting for a client. Ctrl+T stops.")

    while true do
        local sender, message, protocol = rednet.receive()
        if protocol == PROTOCOL
            and type(message) == "table"
            and message.version == VERSION then
            if message.op == "hello" then
                sendMessage(sender, {
                    op = "hello_ack",
                    token = message.token,
                    server = os.getComputerID()
                })
            elseif message.op == "ping" then
                sendMessage(sender, {
                    op = "pong",
                    token = message.token,
                    serverTime = nowMs()
                })
            elseif message.op == "probe"
                and type(message.size) == "number" then
                local size = math.max(0, math.floor(message.size))
                sendMessage(sender, {
                    op = "probe_data",
                    token = message.token,
                    data = payload(size)
                })
            elseif message.op == "download_burst"
                and type(message.size) == "number"
                and type(message.count) == "number" then
                local size = math.max(1, math.floor(message.size))
                local count = math.max(
                    1, math.min(32, math.floor(message.count)))
                local data = payload(size)
                local sent = 0
                for sequence = 1, count do
                    if sendMessage(sender, {
                        op = "download_data",
                        token = message.token,
                        sequence = sequence,
                        data = data
                    }) then
                        sent = sent + 1
                    end
                end
                sendMessage(sender, {
                    op = "download_done",
                    token = message.token,
                    attempted = count,
                    sent = sent
                })
            elseif message.op == "upload_begin" then
                uploadSessions[message.token] = {
                    packets = 0,
                    bytes = 0,
                    startedAt = nowMs()
                }
            elseif message.op == "upload_data" then
                local session = uploadSessions[message.token]
                if session and type(message.data) == "string" then
                    session.packets = session.packets + 1
                    session.bytes = session.bytes + #message.data
                end
            elseif message.op == "upload_end" then
                local session = uploadSessions[message.token]
                    or { packets = 0, bytes = 0, startedAt = nowMs() }
                sendMessage(sender, {
                    op = "upload_ack",
                    token = message.token,
                    packets = session.packets,
                    bytes = session.bytes,
                    serverElapsedMs = nowMs() - session.startedAt
                })
                uploadSessions[message.token] = nil
            end
        end
    end
end

local function testLatency(serverId)
    local samples = {}
    local lost = 0
    for round = 1, PING_ROUNDS do
        local token = ("ping-%d-%d"):format(round, nowMs())
        local started = nowMs()
        sendMessage(serverId, { op = "ping", token = token })
        local response = receiveMatch(serverId, "pong", token, 2)
        if response then
            samples[#samples + 1] = math.max(1, nowMs() - started)
        else
            lost = lost + 1
        end
        progress("PING", round / PING_ROUNDS,
            ("%d/%d"):format(round, PING_ROUNDS))
        sleep(0.05)
    end
    print()
    return {
        sent = PING_ROUNDS,
        received = #samples,
        lost = lost,
        lossPercent = lost / PING_ROUNDS * 100,
        minMs = minimum(samples),
        medianMs = median(samples),
        averageMs = average(samples),
        maxMs = maximum(samples),
        jitterMs = jitter(samples)
    }
end

local function testPayloadLimit(serverId)
    local results = {}
    local reliable = 0
    local largestDelivered = 0
    local stopped = false
    for sizeIndex, size in ipairs(PROBE_SIZES) do
        if stopped then break end
        local delivered = 0
        local latencies = {}
        for round = 1, PROBE_ROUNDS do
            local token = ("probe-%d-%d-%d"):format(
                size, round, nowMs())
            local started = nowMs()
            sendMessage(serverId, {
                op = "probe",
                token = token,
                size = size
            })
            local response = receiveMatch(
                serverId, "probe_data", token, 2)
            if response
                and type(response.data) == "string"
                and #response.data == size then
                delivered = delivered + 1
                latencies[#latencies + 1] =
                    math.max(1, nowMs() - started)
            end
            progress("PAYLOAD", sizeIndex / #PROBE_SIZES,
                ("%d KB %d/%d"):format(
                    math.floor(size / 1024), delivered, round))
        end
        print()
        results[#results + 1] = {
            bytes = size,
            delivered = delivered,
            attempted = PROBE_ROUNDS,
            medianMs = median(latencies)
        }
        if delivered > 0 then largestDelivered = size end
        if delivered == PROBE_ROUNDS then reliable = size end
        if delivered == 0 and size >= 32768 then stopped = true end
    end
    return {
        reliableBytes = reliable,
        largestDeliveredBytes = largestDelivered,
        probes = results
    }
end

local function receiveDownloadBurst(serverId, token, timeoutSeconds)
    local timer = os.startTimer(timeoutSeconds)
    local packets = {}
    local bytes = 0
    local done
    while true do
        local event = table.pack(os.pullEventRaw())
        if event[1] == "terminate" then error("Terminated", 0) end
        if event[1] == "timer" and event[2] == timer then break end
        if event[1] == "rednet_message"
            and event[2] == serverId
            and event[4] == PROTOCOL
            and type(event[3]) == "table"
            and event[3].version == VERSION
            and event[3].token == token then
            local message = event[3]
            if message.op == "download_data"
                and not packets[message.sequence]
                and type(message.data) == "string" then
                packets[message.sequence] = true
                bytes = bytes + #message.data
            elseif message.op == "download_done" then
                done = message
                break
            end
        end
    end
    local count = 0
    for _ in pairs(packets) do count = count + 1 end
    return count, bytes, done
end

local function testDownload(serverId, packetBytes)
    local started = nowMs()
    local deadline = started + TRANSFER_SECONDS * 1000
    local attempted = 0
    local received = 0
    local bytes = 0
    local bursts = 0
    while nowMs() < deadline do
        bursts = bursts + 1
        local token = ("down-%d-%d"):format(bursts, nowMs())
        sendMessage(serverId, {
            op = "download_burst",
            token = token,
            size = packetBytes,
            count = TRANSFER_WINDOW
        })
        local got, gotBytes = receiveDownloadBurst(serverId, token, 2)
        attempted = attempted + TRANSFER_WINDOW
        received = received + got
        bytes = bytes + gotBytes
        local elapsed = nowMs() - started
        local bytesPerSecond, mbps = rateLabels(bytes, elapsed)
        progress("DOWNLOAD", math.min(1, elapsed
            / (TRANSFER_SECONDS * 1000)),
            ("%.2f Mbit/s"):format(mbps))
    end
    print()
    local elapsed = math.max(1, nowMs() - started)
    local bytesPerSecond, mbps = rateLabels(bytes, elapsed)
    return {
        packetBytes = packetBytes,
        window = TRANSFER_WINDOW,
        elapsedMs = elapsed,
        attemptedPackets = attempted,
        receivedPackets = received,
        lostPackets = attempted - received,
        lossPercent = attempted > 0
            and (attempted - received) / attempted * 100 or 0,
        bytes = bytes,
        bytesPerSecond = bytesPerSecond,
        mbps = mbps,
        packetsPerSecond = received * 1000 / elapsed
    }
end

local function testUpload(serverId, packetBytes)
    local started = nowMs()
    local deadline = started + TRANSFER_SECONDS * 1000
    local attempted = 0
    local received = 0
    local receivedBytes = 0
    local bursts = 0
    local data = payload(packetBytes)
    while nowMs() < deadline do
        bursts = bursts + 1
        local token = ("up-%d-%d"):format(bursts, nowMs())
        sendMessage(serverId, {
            op = "upload_begin",
            token = token
        })
        for sequence = 1, TRANSFER_WINDOW do
            attempted = attempted + 1
            sendMessage(serverId, {
                op = "upload_data",
                token = token,
                sequence = sequence,
                data = data
            })
        end
        sendMessage(serverId, {
            op = "upload_end",
            token = token
        })
        local ack = receiveMatch(serverId, "upload_ack", token, 2)
        if ack then
            received = received + (tonumber(ack.packets) or 0)
            receivedBytes = receivedBytes + (tonumber(ack.bytes) or 0)
        end
        local elapsed = nowMs() - started
        local bytesPerSecond, mbps = rateLabels(receivedBytes, elapsed)
        progress("UPLOAD", math.min(1, elapsed
            / (TRANSFER_SECONDS * 1000)),
            ("%.2f Mbit/s"):format(mbps))
    end
    print()
    local elapsed = math.max(1, nowMs() - started)
    local bytesPerSecond, mbps = rateLabels(receivedBytes, elapsed)
    return {
        packetBytes = packetBytes,
        window = TRANSFER_WINDOW,
        elapsedMs = elapsed,
        attemptedPackets = attempted,
        receivedPackets = received,
        lostPackets = attempted - received,
        lossPercent = attempted > 0
            and (attempted - received) / attempted * 100 or 0,
        bytes = receivedBytes,
        bytesPerSecond = bytesPerSecond,
        mbps = mbps,
        packetsPerSecond = received * 1000 / elapsed
    }
end

local function formatNumber(value, decimals)
    if type(value) ~= "number" then return "n/a" end
    return ("%." .. (decimals or 1) .. "f"):format(value)
end

local function makeSummary(result)
    local latency = result.latency
    local payloadLimit = result.payloadLimit
    local download = result.download
    local upload = result.upload
    local recommendation = result.recommendation
    return table.concat({
        "ATLAS LINK SPEEDTEST v2",
        ("CLIENT %d -> SERVER %d"):format(result.client, result.server),
        ("PING median %s ms | min %s | max %s | jitter %s | loss %.1f%%")
            :format(
                formatNumber(latency.medianMs),
                formatNumber(latency.minMs),
                formatNumber(latency.maxMs),
                formatNumber(latency.jitterMs),
                latency.lossPercent),
        ("PAYLOAD reliable %d KB | largest delivered %d KB"):format(
            math.floor(payloadLimit.reliableBytes / 1024),
            math.floor(payloadLimit.largestDeliveredBytes / 1024)),
        ("DOWNLOAD %.2f Mbit/s | %.1f KB/s | %.1f pkt/s | loss %.1f%%")
            :format(
                download.mbps, download.bytesPerSecond / 1000,
                download.packetsPerSecond, download.lossPercent),
        ("UPLOAD   %.2f Mbit/s | %.1f KB/s | %.1f pkt/s | loss %.1f%%")
            :format(
                upload.mbps, upload.bytesPerSecond / 1000,
                upload.packetsPerSecond, upload.lossPercent),
        ("RECOMMEND response %d KB | %d tiles/batch | %d in-flight batches")
            :format(
                math.floor(recommendation.responseBytes / 1024),
                recommendation.tilesPerBatch,
                recommendation.inFlightBatches)
    }, "\n")
end

local function runClient(modems)
    term.clear()
    term.setCursorPos(1, 1)
    print("ATLAS LINK SPEEDTEST")
    print("Discovering server...")
    local serverId = tonumber(arguments[2])
        or rednet.lookup(PROTOCOL, HOSTNAME)
    if not serverId then error("No speedtest server found", 0) end

    local helloToken = "hello-" .. nowMs()
    sendMessage(serverId, { op = "hello", token = helloToken })
    if not receiveMatch(serverId, "hello_ack", helloToken, 3) then
        error("Server did not answer", 0)
    end

    print("Connected to computer " .. serverId)
    print()
    local latency = testLatency(serverId)
    local payloadLimit = testPayloadLimit(serverId)
    if payloadLimit.reliableBytes == 0 then
        error("No reliable payload size found", 0)
    end

    local transferPacketBytes = math.max(1024, math.min(
        49152,
        math.floor(payloadLimit.reliableBytes * 0.70 / 1024) * 1024))
    print(("Sustained transfer packet: %d KB"):format(
        math.floor(transferPacketBytes / 1024)))
    local download = testDownload(serverId, transferPacketBytes)
    local upload = testUpload(serverId, transferPacketBytes)

    local loss = math.max(download.lossPercent, upload.lossPercent)
    local safeFraction = loss > 2 and 0.45
        or latency.lossPercent > 0 and 0.55 or 0.70
    local responseBytes = math.max(4096,
        math.floor(payloadLimit.reliableBytes * safeFraction / 1024) * 1024)
    local tilesPerBatch = math.max(1, math.min(16,
        math.floor(responseBytes / TILE_BYTES_ESTIMATE)))
    local inFlightBatches = latency.medianMs
        and latency.medianMs > 300 and 1
        or loss > 1 and 1
        or download.mbps > 2 and 3
        or 2

    local result = {
        version = VERSION,
        testedAt = nowMs(),
        client = os.getComputerID(),
        server = serverId,
        modems = modems,
        latency = latency,
        payloadLimit = payloadLimit,
        download = download,
        upload = upload,
        recommendation = {
            responseBytes = responseBytes,
            tilesPerBatch = tilesPerBatch,
            inFlightBatches = inFlightBatches
        }
    }
    local summary = makeSummary(result)

    local rawHandle = fs.open("/atlas-bench.txt", "w")
    rawHandle.write(textutils.serialize(result))
    rawHandle.close()
    local summaryHandle = fs.open("/atlas-speedtest.txt", "w")
    summaryHandle.write(summary)
    summaryHandle.close()

    print()
    print(summary)
    print()
    print("Paste the report above back to me.")
    print("Saved: /atlas-speedtest.txt and /atlas-bench.txt")
end

local modems = openModems()
if mode == "server" then
    runServer()
elseif mode == "client" then
    runClient(modems)
else
    print("Usage:")
    print("  atlas-speedtest server")
    print("  atlas-speedtest client [server ID]")
end
