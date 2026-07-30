package dev.terrainsurveyor.mixin;

import com.mojang.blaze3d.vertex.PoseStack;
import com.sashafiesta.ccgraphics.client.GraphicsRenderTypes;
import com.sashafiesta.ccgraphics.client.GraphicsTexture;
import com.sashafiesta.ccgraphics.duck.IGraphicsTerminal;
import dan200.computercraft.client.pocket.ClientPocketComputers;
import dan200.computercraft.client.render.ComputerBorderRenderer;
import dan200.computercraft.client.render.PocketItemRenderer;
import dan200.computercraft.core.terminal.Terminal;
import net.minecraft.client.renderer.LightTexture;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.world.item.ItemStack;
import org.joml.Matrix4f;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.atomic.AtomicInteger;

@Mixin(PocketItemRenderer.class)
public abstract class PocketItemRendererMixin {
    @Unique
    private static final long terrainSurveyor$refreshNanos = 50_000_000L;
    @Unique
    private static final AtomicInteger terrainSurveyor$textureIds =
            new AtomicInteger();
    @Unique
    private static final Map<Terminal, PocketTexture> terrainSurveyor$textures =
            new WeakHashMap<>();

    @Inject(
            method = "renderItem",
            at = @At(
                    value = "INVOKE",
                    target = "Ldan200/computercraft/client/render/text/FixedWidthFontRenderer;"
                            + "drawTerminal(Ldan200/computercraft/client/render/text/"
                            + "FixedWidthFontRenderer$QuadEmitter;FFLdan200/computercraft/"
                            + "core/terminal/Terminal;FFFF)V"),
            cancellable = true)
    private void terrainSurveyor$renderGraphics(
            PoseStack transform,
            MultiBufferSource bufferSource,
            ItemStack stack,
            int light,
            CallbackInfo callback) {
        var computer = ClientPocketComputers.get(stack);
        var terminal = computer == null ? null : computer.getTerminal();
        if (terminal == null) return;

        var graphics = (IGraphicsTerminal) (Object) terminal;
        if (graphics.ccgraphics$getGraphicsMode() <= 0) return;

        var texture = terrainSurveyor$textures.computeIfAbsent(
                terminal,
                ignored -> new PocketTexture(new GraphicsTexture(
                        "terrain_surveyor_pocket_"
                                + terrainSurveyor$textureIds.incrementAndGet())));
        var now = System.nanoTime();
        var redraw = texture.lastRefresh == 0
                || now - texture.lastRefresh >= terrainSurveyor$refreshNanos;
        var location = texture.texture.update(terminal, redraw);
        if (redraw) texture.lastRefresh = now;

        var margin = ComputerBorderRenderer.MARGIN;
        var width = terminal.getWidth() * 6 + margin * 2;
        var height = terminal.getHeight() * 9 + margin * 2;
        var consumer = bufferSource.getBuffer(
                GraphicsRenderTypes.fullbright(location));
        var matrix = transform.last().pose();
        var fullBright = LightTexture.pack(15, 15);
        terrainSurveyor$vertex(
                consumer, matrix, margin, margin, 0, 0, fullBright);
        terrainSurveyor$vertex(
                consumer, matrix, margin, height - margin, 0, 1, fullBright);
        terrainSurveyor$vertex(
                consumer, matrix, width - margin, height - margin,
                1, 1, fullBright);
        terrainSurveyor$vertex(
                consumer, matrix, width - margin, margin, 1, 0, fullBright);

        transform.popPose();
        callback.cancel();
    }

    @Unique
    private static void terrainSurveyor$vertex(
            com.mojang.blaze3d.vertex.VertexConsumer consumer,
            Matrix4f matrix,
            float x,
            float y,
            float u,
            float v,
            int light) {
        consumer.addVertex(matrix, x, y, 0.0001f)
                .setColor(-1)
                .setUv(u, v)
                .setLight(light);
    }

    @Unique
    private static final class PocketTexture {
        private final GraphicsTexture texture;
        private long lastRefresh;

        private PocketTexture(GraphicsTexture texture) {
            this.texture = texture;
        }
    }
}
