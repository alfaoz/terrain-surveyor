package dev.terrainsurveyor.block.entity;

import dev.terrainsurveyor.TerrainSurveyorMod;
import dev.terrainsurveyor.peripheral.TerrainSurveyorPeripheral;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockState;

public final class TerrainSurveyorBlockEntity extends BlockEntity {
    private final TerrainSurveyorPeripheral peripheral = new TerrainSurveyorPeripheral(this);

    public TerrainSurveyorBlockEntity(BlockPos pos, BlockState state) {
        super(TerrainSurveyorMod.TERRAIN_SURVEYOR_BLOCK_ENTITY.get(), pos, state);
    }

    public TerrainSurveyorPeripheral peripheral() {
        return peripheral;
    }
}
