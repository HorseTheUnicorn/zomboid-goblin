import java.nio.file.Files;
import java.nio.file.Path;
import se.krka.kahlua.luaj.compiler.LuaCompiler;

/** Compile mod Lua with the installed game's compiler without executing it. */
public class CheckLuaSyntax {
    public static void main(String[] args) throws Exception {
        int count = 0;
        try (var paths = Files.walk(Path.of(args[0]))) {
            for (Path path : paths.filter(p -> p.toString().endsWith(".lua")).toList()) {
                try (var reader = Files.newBufferedReader(path)) {
                    LuaCompiler.loadis(reader, path.toString(), null);
                    count++;
                }
            }
        }
        System.out.println("PZ Lua syntax OK: " + count + " files (not executed)");
    }
}
