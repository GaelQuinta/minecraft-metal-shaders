package mcopt.metal.own;

import java.util.*;
import java.security.MessageDigest;
import org.lwjgl.system.MemoryUtil;

/** Run against release and candidate jars; compare digests across every ordering mode. */
public final class MeshOrderCheck {
    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static void hash(MessageDigest digest, long address, int length) {
        for (int i = 0; i < length; i++) digest.update(MemoryUtil.memGetByte(address + i));
    }
    static void hash(MessageDigest digest, int n) {
        for (int i = 0; i < 4; i++) digest.update((byte)(n >>> (i * 8)));
    }
    public static void main(String[] args) throws Exception {
        var digest = MessageDigest.getInstance("SHA-256");
        var layer = new OwnQuads.Layer();
        Random random = new Random(413);
        for (int round = 0; round < 80; round++) {
            layer.reset();
            for (int b = 0; b < 7; b++) {
                int n = new int[]{0, 1, 2, 63, 65, 800, 7, 300}[round % 8];
                if (n > layer.cap[b]) {
                    layer.cap[b] = n;
                    layer.addr[b] = MemoryUtil.nmemRealloc(layer.addr[b], (long)n * OwnQuads.QUAD);
                    if (OwnQrec.ON) layer.qaddr[b] = MemoryUtil.nmemRealloc(layer.qaddr[b], (long)n * OwnQrec.BYTES);
                    layer.plane[b] = new float[n];
                    layer.lo[b] = new int[n]; layer.hi[b] = new int[n]; layer.mat[b] = new int[n]; layer.cls[b] = new byte[n];
                }
                layer.count[b] = n; layer.total += n;
                for (int q = 0; q < n; q++) {
                    layer.plane[b][q] = random.nextInt(17);
                    int x = 16 + random.nextInt(16), y = 16 + random.nextInt(16), z = 16 + random.nextInt(16);
                    layer.lo[b][q] = x | y << 8 | z << 16;
                    layer.hi[b][q] = x + 1 | (y + 1) << 8 | (z + 1) << 16;
                    layer.mat[b][q] = random.nextInt(); layer.cls[b][q] = (byte)random.nextInt(6);
                    for (int k = 0; k < OwnQuads.QUAD; k++) MemoryUtil.memPutByte(layer.addr[b] + (long)q * OwnQuads.QUAD + k, (byte)random.nextInt());
                    if (OwnQrec.ON) for (int k = 0; k < OwnQrec.BYTES; k++) MemoryUtil.memPutByte(layer.qaddr[b] + (long)q * OwnQrec.BYTES + k, (byte)random.nextInt());
                }
            }
            int[] runs = layer.runs(32);
            check(layer.runs(32) == runs, "Memoized runs");
            for (int value : runs) hash(digest, value);
            layer.order(); // repeated call must not sort twice
            for (int b = 0; b < 7; b++) for (int q = 0; q < layer.count[b]; q++) {
                hash(digest, Float.floatToIntBits(layer.plane[b][q])); hash(digest, layer.lo[b][q]); hash(digest, layer.hi[b][q]);
                hash(digest, layer.mat[b][q]); hash(digest, layer.cls[b][q]);
                hash(digest, layer.addr[b] + (long)q * OwnQuads.QUAD, OwnQuads.QUAD);
                if (OwnQrec.ON) hash(digest, layer.qaddr[b] + (long)q * OwnQrec.BYTES, OwnQrec.BYTES);
            }
        }
        System.out.println("MESH_ORDER_CHECK " + HexFormat.of().formatHex(digest.digest()));
    }
}
