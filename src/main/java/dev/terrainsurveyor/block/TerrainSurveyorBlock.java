package dev.terrainsurveyor.block;

import com.mojang.serialization.MapCodec;
import dev.terrainsurveyor.block.entity.TerrainSurveyorBlockEntity;
import javax.annotation.Nullable;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.EntityBlock;
import net.minecraft.world.level.block.FaceAttachedHorizontalDirectionalBlock;
import net.minecraft.world.level.block.RenderShape;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.StateDefinition;
import net.minecraft.world.level.block.state.properties.AttachFace;
import net.minecraft.world.phys.shapes.CollisionContext;
import net.minecraft.world.phys.shapes.VoxelShape;

public final class TerrainSurveyorBlock extends FaceAttachedHorizontalDirectionalBlock implements EntityBlock {
    public static final MapCodec<TerrainSurveyorBlock> CODEC = simpleCodec(TerrainSurveyorBlock::new);

    private static final VoxelShape CEILING_X = Block.box(6.0, 14.0, 5.0, 10.0, 16.0, 11.0);
    private static final VoxelShape CEILING_Z = Block.box(5.0, 14.0, 6.0, 11.0, 16.0, 10.0);
    private static final VoxelShape FLOOR_X = Block.box(6.0, 0.0, 5.0, 10.0, 2.0, 11.0);
    private static final VoxelShape FLOOR_Z = Block.box(5.0, 0.0, 6.0, 11.0, 2.0, 10.0);
    private static final VoxelShape NORTH = Block.box(5.0, 6.0, 14.0, 11.0, 10.0, 16.0);
    private static final VoxelShape SOUTH = Block.box(5.0, 6.0, 0.0, 11.0, 10.0, 2.0);
    private static final VoxelShape WEST = Block.box(14.0, 6.0, 5.0, 16.0, 10.0, 11.0);
    private static final VoxelShape EAST = Block.box(0.0, 6.0, 5.0, 2.0, 10.0, 11.0);

    public TerrainSurveyorBlock(BlockBehaviour.Properties properties) {
        super(properties);
        registerDefaultState(stateDefinition.any()
                .setValue(FACING, Direction.NORTH)
                .setValue(FACE, AttachFace.WALL));
    }

    @Override
    protected MapCodec<? extends TerrainSurveyorBlock> codec() {
        return CODEC;
    }

    @Override
    protected VoxelShape getShape(
            BlockState state, BlockGetter level, BlockPos pos, CollisionContext context) {
        Direction facing = state.getValue(FACING);
        return switch (state.getValue(FACE)) {
            case FLOOR -> facing.getAxis() == Direction.Axis.X ? FLOOR_X : FLOOR_Z;
            case CEILING -> facing.getAxis() == Direction.Axis.X ? CEILING_X : CEILING_Z;
            case WALL -> switch (facing) {
                case EAST -> EAST;
                case WEST -> WEST;
                case SOUTH -> SOUTH;
                default -> NORTH;
            };
        };
    }

    @Override
    protected RenderShape getRenderShape(BlockState state) {
        return RenderShape.MODEL;
    }

    @Nullable
    @Override
    public BlockEntity newBlockEntity(BlockPos pos, BlockState state) {
        return new TerrainSurveyorBlockEntity(pos, state);
    }

    @Override
    protected void createBlockStateDefinition(StateDefinition.Builder<Block, BlockState> builder) {
        builder.add(FACING, FACE);
    }
}
