package dev.terrainsurveyor;

import dan200.computercraft.api.peripheral.PeripheralCapability;
import dev.terrainsurveyor.block.TerrainSurveyorBlock;
import dev.terrainsurveyor.block.entity.TerrainSurveyorBlockEntity;
import dev.terrainsurveyor.item.TerrainSurveyorItem;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.item.CreativeModeTabs;
import net.minecraft.world.item.Item;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.BlockEntityType;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.capabilities.RegisterCapabilitiesEvent;
import net.neoforged.neoforge.event.BuildCreativeModeTabContentsEvent;
import net.neoforged.neoforge.registries.DeferredBlock;
import net.neoforged.neoforge.registries.DeferredHolder;
import net.neoforged.neoforge.registries.DeferredItem;
import net.neoforged.neoforge.registries.DeferredRegister;

@Mod(TerrainSurveyorMod.MOD_ID)
public final class TerrainSurveyorMod {
    public static final String MOD_ID = "terrain_surveyor";

    private static final DeferredRegister.Blocks BLOCKS = DeferredRegister.createBlocks(MOD_ID);
    private static final DeferredRegister.Items ITEMS = DeferredRegister.createItems(MOD_ID);
    private static final DeferredRegister<BlockEntityType<?>> BLOCK_ENTITY_TYPES =
            DeferredRegister.create(Registries.BLOCK_ENTITY_TYPE, MOD_ID);

    public static final DeferredBlock<TerrainSurveyorBlock> TERRAIN_SURVEYOR =
            BLOCKS.register("terrain_surveyor", () -> new TerrainSurveyorBlock(
                    BlockBehaviour.Properties.ofFullCopy(Blocks.ACACIA_BUTTON).noOcclusion()));

    public static final DeferredItem<TerrainSurveyorItem> TERRAIN_SURVEYOR_ITEM =
            ITEMS.register("terrain_surveyor", () -> new TerrainSurveyorItem(
                    TERRAIN_SURVEYOR.get(), new Item.Properties()));

    public static final DeferredItem<Item> INCOMPLETE_TERRAIN_IMAGING_CORE =
            ITEMS.registerSimpleItem("incomplete_terrain_imaging_core");
    public static final DeferredItem<Item> LAYERED_TERRAIN_IMAGING_ASSEMBLY =
            ITEMS.registerSimpleItem("layered_terrain_imaging_assembly");
    public static final DeferredItem<Item> TERRAIN_IMAGING_CORE =
            ITEMS.registerSimpleItem("terrain_imaging_core");

    public static final DeferredHolder<BlockEntityType<?>, BlockEntityType<TerrainSurveyorBlockEntity>>
            TERRAIN_SURVEYOR_BLOCK_ENTITY = BLOCK_ENTITY_TYPES.register(
                    "terrain_surveyor",
                    () -> BlockEntityType.Builder.of(TerrainSurveyorBlockEntity::new, TERRAIN_SURVEYOR.get())
                            .build(null));

    public TerrainSurveyorMod(IEventBus modEventBus) {
        BLOCKS.register(modEventBus);
        ITEMS.register(modEventBus);
        BLOCK_ENTITY_TYPES.register(modEventBus);

        modEventBus.addListener(this::registerCapabilities);
        modEventBus.addListener(this::addCreativeTabContents);
    }

    private void registerCapabilities(RegisterCapabilitiesEvent event) {
        event.registerBlockEntity(
                PeripheralCapability.get(),
                TERRAIN_SURVEYOR_BLOCK_ENTITY.get(),
                (blockEntity, side) -> blockEntity.peripheral());
    }

    private void addCreativeTabContents(BuildCreativeModeTabContentsEvent event) {
        if (event.getTabKey() == CreativeModeTabs.REDSTONE_BLOCKS) {
            event.accept(TERRAIN_SURVEYOR_ITEM);
        } else if (event.getTabKey() == CreativeModeTabs.INGREDIENTS) {
            event.accept(INCOMPLETE_TERRAIN_IMAGING_CORE);
            event.accept(LAYERED_TERRAIN_IMAGING_ASSEMBLY);
            event.accept(TERRAIN_IMAGING_CORE);
        }
    }
}
