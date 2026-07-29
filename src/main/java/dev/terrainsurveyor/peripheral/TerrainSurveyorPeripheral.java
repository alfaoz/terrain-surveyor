package dev.terrainsurveyor.peripheral;

import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.api.lua.IArguments;
import dan200.computercraft.api.lua.LuaTable;
import dan200.computercraft.api.peripheral.IPeripheral;
import dev.terrainsurveyor.TerrainSurveyorMod;
import dev.terrainsurveyor.block.entity.TerrainSurveyorBlockEntity;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.CRC32;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.TagKey;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.material.Fluids;
import net.minecraft.world.phys.Vec3;

public final class TerrainSurveyorPeripheral implements IPeripheral {
    public static final int FORMAT_VERSION = 1;
    public static final int MAX_CHUNK_RADIUS = 8;
    public static final int MAX_BATCH_REQUESTS = 96;
    public static final int DEFAULT_BATCH_CHUNKS = 8;
    public static final int MAX_BATCH_CHUNKS = 16;
    public static final int DEFAULT_SCAN_BUDGET_MICROS = 4_000;
    public static final int MIN_SCAN_BUDGET_MICROS = 500;
    public static final int MAX_SCAN_BUDGET_MICROS = 8_000;

    private static final int COLUMN_COUNT = 16 * 16;
    private static final int NO_HEIGHT = 0xFFFF;

    private static final int FLAG_FLUID_MASK = 0b0000_0011;
    private static final int FLAG_WATER = 0b0000_0001;
    private static final int FLAG_LAVA = 0b0000_0010;
    private static final int FLAG_OTHER_FLUID = 0b0000_0011;
    private static final int FLAG_CLEARANCE_OBSTACLE = 0b0000_0100;

    private static final TagKey<Block> SURFACE_IGNORED = TagKey.create(
            Registries.BLOCK,
            ResourceLocation.fromNamespaceAndPath(TerrainSurveyorMod.MOD_ID, "surface_ignored"));
    private static final TagKey<Block> CLEARANCE_IGNORED = TagKey.create(
            Registries.BLOCK,
            ResourceLocation.fromNamespaceAndPath(TerrainSurveyorMod.MOD_ID, "clearance_ignored"));

    private final TerrainSurveyorBlockEntity blockEntity;

    public TerrainSurveyorPeripheral(TerrainSurveyorBlockEntity blockEntity) {
        this.blockEntity = blockEntity;
    }

    @Override
    public String getType() {
        return "terrain_surveyor";
    }

    @Override
    public Object getTarget() {
        return blockEntity;
    }

    @Override
    public boolean equals(IPeripheral other) {
        return other instanceof TerrainSurveyorPeripheral surveyor
                && surveyor.blockEntity == blockEntity;
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> getInfo() throws LuaException {
        ServerLevel level = requireServerLevel();
        Vec3 worldPosition = worldPosition(level);
        ChunkPos chunk = new ChunkPos(BlockPos.containing(worldPosition));

        Map<String, Object> info = new LinkedHashMap<>();
        info.put("version", FORMAT_VERSION);
        info.put("dimension", level.dimension().location().toString());
        info.put("x", worldPosition.x);
        info.put("y", worldPosition.y);
        info.put("z", worldPosition.z);
        info.put("chunkX", chunk.x);
        info.put("chunkZ", chunk.z);
        info.put("maxChunkRadius", MAX_CHUNK_RADIUS);
        info.put("supportsBatch", true);
        info.put("maxBatchRequests", MAX_BATCH_REQUESTS);
        info.put("defaultBatchChunks", DEFAULT_BATCH_CHUNKS);
        info.put("maxBatchChunks", MAX_BATCH_CHUNKS);
        info.put("defaultScanBudgetMicros", DEFAULT_SCAN_BUDGET_MICROS);
        info.put("maxScanBudgetMicros", MAX_SCAN_BUDGET_MICROS);
        return info;
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> scanChunk(int dx, int dz) throws LuaException {
        if (dx < -MAX_CHUNK_RADIUS
                || dx > MAX_CHUNK_RADIUS
                || dz < -MAX_CHUNK_RADIUS
                || dz > MAX_CHUNK_RADIUS) {
            throw new LuaException("chunk offset must be between -"
                    + MAX_CHUNK_RADIUS + " and " + MAX_CHUNK_RADIUS);
        }

        ServerLevel level = requireServerLevel();
        Vec3 worldPosition = worldPosition(level);
        ChunkPos origin = new ChunkPos(BlockPos.containing(worldPosition));
        int chunkX = origin.x + dx;
        int chunkZ = origin.z + dz;

        ChunkAccess chunk = level.getChunk(chunkX, chunkZ, ChunkStatus.FULL, false);
        if (chunk == null) {
            throw new LuaException("chunk " + chunkX + "," + chunkZ + " is not loaded");
        }

        return scanLoadedChunk(level, chunk, chunkX, chunkZ);
    }

    @LuaFunction(mainThread = true)
    public final Map<String, Object> scanBatch(IArguments arguments) throws LuaException {
        LuaTable<?, ?> requestedOffsets = arguments.getTableUnsafe(0);
        int maxChunks = clamp(
                arguments.optInt(1, DEFAULT_BATCH_CHUNKS),
                1,
                MAX_BATCH_CHUNKS);
        int budgetMicros = clamp(
                arguments.optInt(2, DEFAULT_SCAN_BUDGET_MICROS),
                MIN_SCAN_BUDGET_MICROS,
                MAX_SCAN_BUDGET_MICROS);

        ServerLevel level = requireServerLevel();
        Vec3 position = worldPosition(level);
        ChunkPos origin = new ChunkPos(BlockPos.containing(position));
        int requestCount = Math.min(requestedOffsets.length(), MAX_BATCH_REQUESTS);
        long startedAt = System.nanoTime();
        long deadline = startedAt + budgetMicros * 1_000L;

        List<Map<String, Object>> tiles = new ArrayList<>();
        List<Map<String, Object>> unloaded = new ArrayList<>();
        List<Map<String, Object>> deferred = new ArrayList<>();
        int inspected = 0;

        for (int index = 1; index <= requestCount; index++) {
            ScanRequest request = readRequest(
                    requestedOffsets.get(index), index, origin);
            int dx = request.dx();
            int dz = request.dz();

            if (tiles.size() >= maxChunks
                    || (!tiles.isEmpty() && System.nanoTime() >= deadline)) {
                deferred.add(offsetResult(request));
                continue;
            }
            if (!validOffset(dx, dz)) {
                deferred.add(offsetResult(request));
                continue;
            }

            inspected++;
            int chunkX = request.chunkX();
            int chunkZ = request.chunkZ();
            ChunkAccess chunk = level.getChunk(chunkX, chunkZ, ChunkStatus.FULL, false);
            if (chunk == null) {
                unloaded.add(offsetResult(request));
                continue;
            }
            tiles.add(scanLoadedChunk(level, chunk, chunkX, chunkZ));
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("version", FORMAT_VERSION);
        result.put("dimension", level.dimension().location().toString());
        result.put("x", position.x);
        result.put("y", position.y);
        result.put("z", position.z);
        result.put("chunkX", origin.x);
        result.put("chunkZ", origin.z);
        result.put("requested", requestCount);
        result.put("inspected", inspected);
        result.put("tiles", tiles);
        result.put("unloaded", unloaded);
        result.put("deferred", deferred);
        result.put("elapsedMicros", (System.nanoTime() - startedAt) / 1_000L);
        result.put("budgetMicros", budgetMicros);
        return result;
    }

    private Map<String, Object> scanLoadedChunk(
            ServerLevel level, ChunkAccess chunk, int chunkX, int chunkZ) {
        int minY = level.getMinBuildHeight();
        int maxY = level.getMaxBuildHeight() - 1;
        int[] surfaceHeights = new int[COLUMN_COUNT];
        int[] clearanceHeights = new int[COLUMN_COUNT];
        int[] fluidHeights = new int[COLUMN_COUNT];
        byte[] flags = new byte[COLUMN_COUNT];
        BlockPos.MutableBlockPos cursor = new BlockPos.MutableBlockPos();

        for (int localZ = 0; localZ < 16; localZ++) {
            for (int localX = 0; localX < 16; localX++) {
                int index = localZ * 16 + localX;
                int worldX = (chunkX << 4) + localX;
                int worldZ = (chunkZ << 4) + localZ;
                int surfaceTopY = heightHint(
                        chunk, Heightmap.Types.MOTION_BLOCKING_NO_LEAVES,
                        localX, localZ, minY, maxY);
                int clearanceTopY = heightHint(
                        chunk, Heightmap.Types.MOTION_BLOCKING,
                        localX, localZ, minY, maxY);
                int fluidTopY = heightHint(
                        chunk, Heightmap.Types.WORLD_SURFACE,
                        localX, localZ, minY, maxY);

                ColumnSample sample = scanColumn(
                        level,
                        chunk,
                        cursor,
                        worldX,
                        worldZ,
                        surfaceTopY,
                        clearanceTopY,
                        fluidTopY,
                        minY);
                surfaceHeights[index] = sample.surfaceY();
                clearanceHeights[index] = sample.clearanceY();
                fluidHeights[index] = sample.fluidY();

                int columnFlags = sample.fluidFlag() & FLAG_FLUID_MASK;
                if (sample.clearanceY() != NO_HEIGHT
                        && sample.surfaceY() != NO_HEIGHT
                        && sample.clearanceY() > sample.surfaceY()) {
                    columnFlags |= FLAG_CLEARANCE_OBSTACLE;
                }
                flags[index] = (byte) columnFlags;
            }
        }

        byte[] surface = encodeHeights(surfaceHeights, minY);
        byte[] clearance = encodeHeights(clearanceHeights, minY);
        byte[] fluid = encodeHeights(fluidHeights, minY);

        CRC32 checksum = new CRC32();
        checksum.update(surface);
        checksum.update(clearance);
        checksum.update(fluid);
        checksum.update(flags);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("version", FORMAT_VERSION);
        result.put("dimension", level.dimension().location().toString());
        result.put("chunkX", chunkX);
        result.put("chunkZ", chunkZ);
        result.put("minY", minY);
        result.put("maxY", maxY);
        result.put("width", 16);
        result.put("depth", 16);
        result.put("order", "z_major");
        result.put("byteOrder", "big_endian");
        result.put("surface", surface);
        result.put("clearance", clearance);
        result.put("fluid", fluid);
        result.put("flags", flags);
        result.put("checksum", String.format("%08x", checksum.getValue()));
        return result;
    }

    private static ColumnSample scanColumn(
            ServerLevel level,
            ChunkAccess chunk,
            BlockPos.MutableBlockPos cursor,
            int worldX,
            int worldZ,
            int surfaceTopY,
            int clearanceTopY,
            int fluidTopY,
            int minY) {
        int surfaceY = findLayerHeight(
                level, chunk, cursor, worldX, worldZ, surfaceTopY, minY, true);
        int clearanceY = findLayerHeight(
                level, chunk, cursor, worldX, worldZ, clearanceTopY, minY, false);
        int fluidY = NO_HEIGHT;
        int fluidFlag = 0;

        int fluidFloor = minY;
        if (surfaceY != NO_HEIGHT) {
            fluidFloor = Math.max(fluidFloor, surfaceY);
        }
        if (clearanceY != NO_HEIGHT) {
            fluidFloor = surfaceY == NO_HEIGHT
                    ? Math.max(fluidFloor, clearanceY)
                    : Math.min(surfaceY, clearanceY);
        }

        for (int y = fluidTopY; y >= fluidFloor; y--) {
            cursor.set(worldX, y, worldZ);
            BlockState state = chunk.getBlockState(cursor);
            FluidState fluidState = state.getFluidState();
            if (!fluidState.isEmpty()) {
                fluidY = y;
                fluidFlag = fluidFlag(fluidState);
                break;
            }
        }

        return new ColumnSample(surfaceY, clearanceY, fluidY, fluidFlag);
    }

    private static int findLayerHeight(
            ServerLevel level,
            ChunkAccess chunk,
            BlockPos.MutableBlockPos cursor,
            int worldX,
            int worldZ,
            int topY,
            int minY,
            boolean surface) {
        for (int y = topY; y >= minY; y--) {
            cursor.set(worldX, y, worldZ);
            BlockState state = chunk.getBlockState(cursor);
            if (state.isAir() || !state.getFluidState().isEmpty()) {
                continue;
            }
            if (surface ? state.is(SURFACE_IGNORED) : state.is(CLEARANCE_IGNORED)) {
                continue;
            }
            if (!state.getCollisionShape(level, cursor).isEmpty()) {
                return y;
            }
        }
        return NO_HEIGHT;
    }

    private static int heightHint(
            ChunkAccess chunk,
            Heightmap.Types type,
            int localX,
            int localZ,
            int minY,
            int maxY) {
        return clamp(chunk.getHeight(type, localX, localZ), minY, maxY);
    }

    private static ScanRequest readRequest(
            Object value, int index, ChunkPos origin) throws LuaException {
        if (!(value instanceof Map<?, ?> offset)) {
            throw new LuaException("offset " + index + " must be a table");
        }
        Integer absoluteX = readOptionalCoordinate(offset, "chunkX");
        Integer absoluteZ = readOptionalCoordinate(offset, "chunkZ");
        if (absoluteX != null && absoluteZ != null) {
            return new ScanRequest(
                    absoluteX - origin.x,
                    absoluteZ - origin.z,
                    absoluteX,
                    absoluteZ);
        }

        int dx = readCoordinate(offset, "dx", 1, index);
        int dz = readCoordinate(offset, "dz", 2, index);
        validateOffset(dx, dz);
        return new ScanRequest(dx, dz, origin.x + dx, origin.z + dz);
    }

    private static int readCoordinate(
            Map<?, ?> offset, String name, int listIndex, int offsetIndex) throws LuaException {
        Object value = offset.get(name);
        if (value == null) {
            value = offset.get((double) listIndex);
        }
        if (value == null) {
            value = offset.get((long) listIndex);
        }
        if (!(value instanceof Number number)
                || number.doubleValue() != Math.rint(number.doubleValue())) {
            throw new LuaException(
                    "offset " + offsetIndex + " has an invalid " + name);
        }
        return number.intValue();
    }

    private static Integer readOptionalCoordinate(Map<?, ?> offset, String name)
            throws LuaException {
        Object value = offset.get(name);
        if (value == null) {
            return null;
        }
        if (!(value instanceof Number number)
                || number.doubleValue() != Math.rint(number.doubleValue())) {
            throw new LuaException("invalid " + name);
        }
        return number.intValue();
    }

    private static void validateOffset(int dx, int dz) throws LuaException {
        if (!validOffset(dx, dz)) {
            throw new LuaException("chunk offset must be between -"
                    + MAX_CHUNK_RADIUS + " and " + MAX_CHUNK_RADIUS);
        }
    }

    private static boolean validOffset(int dx, int dz) {
        return dx >= -MAX_CHUNK_RADIUS
                && dx <= MAX_CHUNK_RADIUS
                && dz >= -MAX_CHUNK_RADIUS
                && dz <= MAX_CHUNK_RADIUS;
    }

    private static Map<String, Object> offsetResult(ScanRequest request) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("dx", request.dx());
        result.put("dz", request.dz());
        result.put("chunkX", request.chunkX());
        result.put("chunkZ", request.chunkZ());
        return result;
    }

    private static int clamp(int value, int minimum, int maximum) {
        return Math.max(minimum, Math.min(maximum, value));
    }

    private static int fluidFlag(FluidState state) {
        if (state.is(Fluids.WATER)) {
            return FLAG_WATER;
        }
        if (state.is(Fluids.LAVA)) {
            return FLAG_LAVA;
        }
        return FLAG_OTHER_FLUID;
    }

    private static byte[] encodeHeights(int[] heights, int minY) {
        ByteBuffer output = ByteBuffer.allocate(heights.length * Short.BYTES)
                .order(ByteOrder.BIG_ENDIAN);
        for (int height : heights) {
            int encoded = height == NO_HEIGHT ? NO_HEIGHT : height - minY;
            output.putShort((short) encoded);
        }
        return output.array();
    }

    private ServerLevel requireServerLevel() throws LuaException {
        if (!(blockEntity.getLevel() instanceof ServerLevel level) || blockEntity.isRemoved()) {
            throw new LuaException("terrain surveyor is not available");
        }
        return level;
    }

    private Vec3 worldPosition(ServerLevel level) throws LuaException {
        try {
            return SablePositionBridge.toWorld(level, Vec3.atCenterOf(blockEntity.getBlockPos()));
        } catch (SablePositionBridge.BridgeException exception) {
            throw new LuaException(exception.getMessage());
        }
    }

    private record ColumnSample(int surfaceY, int clearanceY, int fluidY, int fluidFlag) {}

    private record ScanRequest(int dx, int dz, int chunkX, int chunkZ) {}
}
