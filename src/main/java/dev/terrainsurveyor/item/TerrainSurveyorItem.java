package dev.terrainsurveyor.item;

import java.util.List;
import net.minecraft.ChatFormatting;
import net.minecraft.network.chat.Component;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.TooltipFlag;
import net.minecraft.world.level.block.Block;

public final class TerrainSurveyorItem extends BlockItem {
    public TerrainSurveyorItem(Block block, Item.Properties properties) {
        super(block, properties);
    }

    @Override
    public void appendHoverText(
            ItemStack stack,
            Item.TooltipContext context,
            List<Component> tooltip,
            TooltipFlag flag) {
        tooltip.add(Component.translatable(
                "tooltip.terrain_surveyor.terrain_surveyor.passive")
                .withStyle(ChatFormatting.GRAY));
        tooltip.add(Component.translatable(
                "tooltip.terrain_surveyor.terrain_surveyor.resolution")
                .withStyle(ChatFormatting.DARK_GRAY));
        tooltip.add(Component.translatable(
                "tooltip.terrain_surveyor.terrain_surveyor.layers")
                .withStyle(ChatFormatting.DARK_GRAY));
    }
}
