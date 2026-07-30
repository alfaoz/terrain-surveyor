package dev.terrainsurveyor;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import org.squiddev.cobalt.LuaState;
import org.squiddev.cobalt.compiler.LuaC;

/**
 * Compiles distributed Lua programs with the same Cobalt compiler used by
 * CC:Tweaked. Desktop PUC Lua permits more active locals than CraftOS does, so
 * a regular luac syntax check is not sufficient.
 */
public final class CraftOsLuaCompilerCheck {
    private CraftOsLuaCompilerCheck() {}

    public static void main(String[] arguments) throws Exception {
        LuaState state = new LuaState();
        for (String argument : arguments) {
            Path path = Path.of(argument);
            try (InputStream input = Files.newInputStream(path)) {
                LuaC.compile(state, input, "@" + path);
            }
            System.out.println("CraftOS Lua OK: " + path);
        }
    }
}
