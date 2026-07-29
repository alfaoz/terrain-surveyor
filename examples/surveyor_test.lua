-- Terrain Surveyor diagnostic for CraftOS / CC:Tweaked.
--
-- Usage:
--   surveyor_test
--   surveyor_test <chunk dx> <chunk dz>
--
-- With wget:
--   wget run <raw gist URL>
--   wget run <raw gist URL> 1 -1

local args = { ... }
local dx = tonumber(args[1] or "0")
local dz = tonumber(args[2] or "0")

local function fail(message)
    printError("FAIL: " .. message)
    error(message, 0)
end

local function check(condition, message)
    if not condition then fail(message) end
    print("PASS: " .. message)
end

local function decodeHeight(tile, field, x, z)
    local data = tile[field]
    local sample = z * 16 + x
    local byteIndex = sample * 2 + 1
    local high, low = data:byte(byteIndex, byteIndex + 1)
    if not high or not low then return nil, "truncated " .. field .. " data" end

    local encoded = high * 256 + low
    if encoded == 0xffff then return nil end
    return tile.minY + encoded
end

if dx == nil or dz == nil or dx % 1 ~= 0 or dz % 1 ~= 0 then
    fail("chunk offsets must be whole numbers")
end

print("Terrain Surveyor test")
print(("Requested chunk offset: %d, %d"):format(dx, dz))
print()

local surveyor = peripheral.find("terrain_surveyor")
check(surveyor ~= nil, "terrain_surveyor peripheral found")

local side
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "terrain_surveyor" then
        side = name
        break
    end
end
check(side ~= nil, "peripheral attachment name found")
print("Peripheral name: " .. tostring(side))

local methods = peripheral.getMethods(side)
check(type(methods) == "table", "peripheral method list available")

local available = {}
for _, method in ipairs(methods) do available[method] = true end
check(available.getInfo, "getInfo() is exposed")
check(available.scanChunk, "scanChunk() is exposed")
check(available.scanBatch, "scanBatch() is exposed")

local infoOk, info = pcall(surveyor.getInfo)
check(infoOk, "getInfo() completed")
check(type(info) == "table", "getInfo() returned a table")
check(type(info.dimension) == "string", "dimension is present")
check(type(info.x) == "number"
    and type(info.y) == "number"
    and type(info.z) == "number", "world position is present")

print()
print("World position")
print(("  Dimension: %s"):format(info.dimension))
print(("  XYZ: %.2f, %.2f, %.2f"):format(info.x, info.y, info.z))
print(("  Chunk: %d, %d"):format(info.chunkX, info.chunkZ))
print(("  Radius: +/- %d chunks"):format(info.maxChunkRadius))
print(("  Native batch: up to %d chunks, %d requests, %dus budget"):format(
    info.maxBatchChunks, info.maxBatchRequests, info.maxScanBudgetMicros))

local rangeOk, rangeError = pcall(surveyor.scanChunk, info.maxChunkRadius + 1, 0)
check(not rangeOk, "out-of-range request was rejected")
print("  Rejection: " .. tostring(rangeError))

local started = os.clock()
local scanOk, tile = pcall(surveyor.scanChunk, dx, dz)
if not scanOk then fail("scanChunk failed: " .. tostring(tile)) end
local elapsed = os.clock() - started

check(type(tile) == "table", "scanChunk() returned a table")
check(tile.version == 1, "format version is 1")
check(tile.width == 16 and tile.depth == 16, "tile is 16x16 columns")
check(type(tile.surface) == "string" and #tile.surface == 512,
    "surface payload is 512 bytes")
check(type(tile.clearance) == "string" and #tile.clearance == 512,
    "clearance payload is 512 bytes")
check(type(tile.fluid) == "string" and #tile.fluid == 512,
    "fluid payload is 512 bytes")
check(type(tile.flags) == "string" and #tile.flags == 256,
    "flags payload is 256 bytes")
check(type(tile.checksum) == "string" and #tile.checksum == 8,
    "CRC-32 checksum is present")

local repeatOk, repeatedTile = pcall(surveyor.scanChunk, dx, dz)
check(repeatOk, "immediate repeat scan completed without a cooldown")
check(repeatedTile.checksum == tile.checksum,
    "repeat scan returned the same terrain checksum")

local batchOk, batch = pcall(surveyor.scanBatch, {
    { chunkX = info.chunkX, chunkZ = info.chunkZ },
    { chunkX = info.chunkX + 1, chunkZ = info.chunkZ },
    { chunkX = info.chunkX, chunkZ = info.chunkZ + 1 }
}, 3, info.maxScanBudgetMicros)
check(batchOk, "native batch scan completed")
check(type(batch.tiles) == "table"
    and type(batch.unloaded) == "table"
    and type(batch.deferred) == "table",
    "batch result separated scanned, unloaded, and deferred chunks")
check(#batch.tiles >= 1, "batch included the current loaded chunk")
print(("  Batch: %d scanned, %d unloaded, %d deferred in %dus"):format(
    #batch.tiles, #batch.unloaded, #batch.deferred, batch.elapsedMicros))

local minimumSurface
local maximumSurface
local obstacles = 0
local water = 0
local lava = 0
local otherFluid = 0
local unknown = 0
local rows = {}

for z = 0, 15 do
    local row = {}
    for x = 0, 15 do
        local surface = decodeHeight(tile, "surface", x, z)
        local clearance = decodeHeight(tile, "clearance", x, z)
        local flag = tile.flags:byte(z * 16 + x + 1)
        local fluidKind = flag % 4

        if not surface then
            unknown = unknown + 1
        else
            minimumSurface = minimumSurface and math.min(minimumSurface, surface) or surface
            maximumSurface = maximumSurface and math.max(maximumSurface, surface) or surface
        end

        if clearance and surface and clearance > surface then
            obstacles = obstacles + 1
        end

        if fluidKind == 1 then
            water = water + 1
        elseif fluidKind == 2 then
            lava = lava + 1
        elseif fluidKind == 3 then
            otherFluid = otherFluid + 1
        end

        if clearance and surface and clearance > surface then
            row[#row + 1] = "^"
        elseif fluidKind == 1 then
            row[#row + 1] = "~"
        elseif fluidKind == 2 then
            row[#row + 1] = "!"
        elseif not surface then
            row[#row + 1] = "?"
        else
            row[#row + 1] = "."
        end
    end
    rows[#rows + 1] = table.concat(row)
end

print()
print(("Scanned chunk %d, %d in %.3fs"):format(tile.chunkX, tile.chunkZ, elapsed))
print(("Y range: %d through %d"):format(tile.minY, tile.maxY))
print("Checksum: " .. tile.checksum)
print(("Surface min/max: %s / %s"):format(
    minimumSurface and tostring(minimumSurface) or "none",
    maximumSurface and tostring(maximumSurface) or "none"))
print(("Columns: %d obstacles, %d water, %d lava, %d other, %d unknown")
    :format(obstacles, water, lava, otherFluid, unknown))

if dx == 0 and dz == 0 then
    local localX = math.floor(info.x) % 16
    local localZ = math.floor(info.z) % 16
    print()
    print(("Surveyor column (%d, %d)"):format(localX, localZ))
    print("  Surface Y: " .. tostring(decodeHeight(tile, "surface", localX, localZ)))
    print("  Clearance Y: " .. tostring(decodeHeight(tile, "clearance", localX, localZ)))
    print("  Fluid Y: " .. tostring(decodeHeight(tile, "fluid", localX, localZ)))
end

print()
print("Tile key")
print("  . terrain  ^ obstacle  ~ water")
print("  ! lava     ? unknown")
for _, row in ipairs(rows) do print("  " .. row) end

print()
print("All Terrain Surveyor tests passed.")
