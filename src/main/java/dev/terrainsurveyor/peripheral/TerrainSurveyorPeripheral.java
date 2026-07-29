package dev.terrainsurveyor.peripheral;

import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;
import dan200.computercraft.api.peripheral.IPeripheral;
import dev.terrainsurveyor.TerrainSurveyorMod;
import dev.terrainsurveyor.block.entity.TerrainSurveyorBlockEntity;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.LinkedHashMap;
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
                int topY = Math.min(maxY, chunk.getHeight(Heightmap.Types.WORLD_SURFACE, localX, localZ));

                ColumnSample sample = scanColumn(level, chunk, cursor, worldX, worldZ, topY, minY);
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
            int topY,
            int minY) {
        int surfaceY = NO_HEIGHT;
        int clearanceY = NO_HEIGHT;
        int fluidY = NO_HEIGHT;
        int fluidFlag = 0;

        for (int y = topY; y >= minY; y--) {
            cursor.set(worldX, y, worldZ);
            BlockState state = chunk.getBlockState(cursor);
            if (state.isAir()) {
                continue;
            }

            FluidState fluidState = state.getFluidState();
            if (fluidY == NO_HEIGHT && !fluidState.isEmpty()) {
                fluidY = y;
                fluidFlag = fluidFlag(fluidState);
            }

            if (clearanceY == NO_HEIGHT
                    && fluidState.isEmpty()
                    && !state.is(CLEARANCE_IGNORED)
                    && !state.getCollisionShape(level, cursor).isEmpty()) {
                clearanceY = y;
            }

            if (surfaceY == NO_HEIGHT
                    && fluidState.isEmpty()
                    && !state.is(SURFACE_IGNORED)
                    && !state.getCollisionShape(level, cursor).isEmpty()) {
                surfaceY = y;
            }

            if (surfaceY != NO_HEIGHT && clearanceY != NO_HEIGHT) {
                break;
            }
        }

        return new ColumnSample(surfaceY, clearanceY, fluidY, fluidFlag);
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
}
