package dev.terrainsurveyor.peripheral;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.Vec3;

final class SablePositionBridge {
    private static final String API_CLASS = "dev.ryanhcode.sable.companion.SableCompanion";

    private static volatile Bridge bridge;

    private SablePositionBridge() {}

    static Vec3 toWorld(Level level, Vec3 localPosition) throws BridgeException {
        Bridge activeBridge = bridge;
        if (activeBridge == null) {
            synchronized (SablePositionBridge.class) {
                activeBridge = bridge;
                if (activeBridge == null) {
                    activeBridge = load();
                    bridge = activeBridge;
                }
            }
        }
        return activeBridge.project(level, localPosition);
    }

    private static Bridge load() throws BridgeException {
        try {
            Class<?> apiClass = Class.forName(API_CLASS);
            Field instanceField = apiClass.getField("INSTANCE");
            Object instance = instanceField.get(null);
            Method project = apiClass.getMethod("projectOutOfSubLevel", Level.class, Vec3.class);
            return new Bridge(instance, project);
        } catch (ReflectiveOperationException exception) {
            throw new BridgeException("Sable Companion position API is unavailable", exception);
        }
    }

    private record Bridge(Object instance, Method projectMethod) {
        Vec3 project(Level level, Vec3 localPosition) throws BridgeException {
            try {
                Object result = projectMethod.invoke(instance, level, localPosition);
                if (result instanceof Vec3 position) {
                    return position;
                }
                throw new BridgeException("Sable Companion returned an invalid world position");
            } catch (IllegalAccessException exception) {
                throw new BridgeException("Cannot access the Sable Companion position API", exception);
            } catch (InvocationTargetException exception) {
                Throwable cause = exception.getCause() == null ? exception : exception.getCause();
                throw new BridgeException("Sable Companion could not project the surveyor position", cause);
            }
        }
    }

    static final class BridgeException extends Exception {
        BridgeException(String message) {
            super(message);
        }

        BridgeException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
