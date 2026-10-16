// Copyright 2026 mcopt-shade contributors. Apache-2.0.
import java.nio.*;
import java.nio.file.*;
import mcopt.metal.shade.ShadeLook;
import mcopt.metal.shade.ShadeMsl;

/** Use the production Java curve solver and shader assembler in the GPU tests. */
public class HdrFixtures {
    public static void main(String[] args) throws Exception {
        Path out = Path.of(args[0]);
        Files.createDirectories(out);
        Files.writeString(out.resolve("post.metal"), ShadeMsl.post());
        ByteBuffer curves = ByteBuffer.allocate(5 * 6 * 16).order(ByteOrder.LITTLE_ENDIAN);
        ShadeLook look = new ShadeLook();
        for (float contrast : new float[] {0.8f, 1f, 1.4f, 1.8f, 2.1f}) {
            look.contrast = contrast;
            for (float peak : new float[] {1f, 1.2f, 2f, 4f, 8f, 16f}) {
                curves.putFloat(contrast).putFloat(peak);
                look.putHdrCurve(curves, peak);
            }
        }
        Files.write(out.resolve("curves.bin"), curves.array());
    }
}
