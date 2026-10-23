package mcopt.allocationbench;

import java.lang.management.ManagementFactory;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;
import mcopt.metal.alloc.PalettePacking;
import net.minecraft.core.IdMapper;
import net.minecraft.util.*;
import net.minecraft.world.level.chunk.*;

/** Checks against Minecraft's unchanged reencoder and round-trips actual pack results. */
public final class PalettePackingCheck {
    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static final Method REENCODE;
    static {
        try {
            REENCODE = PalettedContainer.class.getDeclaredMethod("reencodeContents", BitStorage.class, Palette.class, Palette.class);
            REENCODE.setAccessible(true);
        } catch (Exception e) { throw new ExceptionInInitializerError(e); }
    }

    static void buffers(long seed) throws Exception {
        Random random = new Random(seed);
        for (int round = 0; round < 100; round++) {
            int size = new int[]{4096, 64, 127}[round % 3];
            int bits = round % 10;
            int distinct = 1 << bits;
            List<Object> entries = new ArrayList<>();
            for (int i = 0; i < distinct; i++) entries.add(new Object());
            Palette<Object> from = new HashMapPalette<>(bits, entries);
            int[] raw = new int[size];
            for (int i = 0; i < size; i++) raw[i] = random.nextInt(distinct);
            BitStorage storage = bits == 0 ? new ZeroBitStorage(size) : new SimpleBitStorage(bits, size, raw);
            HashMapPalette<Object> ref = new HashMapPalette<>(bits), actual = new HashMapPalette<>(bits);
            int[] expected = (int[]) REENCODE.invoke(null, storage, from, ref);
            PalettePacking.enter();
            try {
                int[] ids = PalettePacking.reencode(storage, from, actual);
                check(Arrays.equals(ids, expected), "Remapped IDs");
                check(actual.getEntries().equals(ref.getEntries()), "Palette encounter order");
                int[] held = ids.clone();
                // Nested scopes beyond the retained limit must not change an outer call's IDs.
                nested(7, storage, from);
                check(Arrays.equals(ids, held), "Nested packing overwrote outer IDs");
                SimpleBitStorage packed = new SimpleBitStorage(Math.max(1, bits), size, ids);
                long[] saved = packed.getRaw().clone();
                Arrays.fill(ids, 0);
                check(Arrays.equals(packed.getRaw(), saved), "Packed data aliases scratch IDs");
            } finally { PalettePacking.exit(); }
        }
        // Simulate an exception unwinding through pack's finally, then reuse the worker.
        PalettePacking.enter();
        try { throw new IllegalStateException("fixture"); }
        catch (IllegalStateException expected) { }
        finally { PalettePacking.exit(); }
        nested(1, new ZeroBitStorage(4096), new HashMapPalette<>(0, List.of(new Object())));
    }
    static void nested(int depth, BitStorage storage, Palette<Object> from) {
        PalettePacking.enter();
        try {
            int[] ids = PalettePacking.reencode(storage, from, new HashMapPalette<>(storage.getBits()));
            int[] held = ids.clone();
            if (depth > 0) nested(depth - 1, storage, from);
            check(Arrays.equals(ids, held), "Recursive scope isolation");
            ids[0] ^= 1; // An inner scope must be free to overwrite its IDs without changing its caller.
        } finally { PalettePacking.exit(); }
    }

    public static void run(boolean transformed) throws Exception {
        try (ExecutorService pool = Executors.newFixedThreadPool(4)) {
            List<Future<?>> futures = new ArrayList<>();
            for (int i = 0; i < 4; i++) {
                final int seed = i;
                futures.add(pool.submit(() -> { try { buffers(seed); } catch (Exception e) { throw new RuntimeException(e); } }));
            }
            for (Future<?> f : futures) f.get();
        }
        IdMapper<Object> ids = new IdMapper<>();
        for (int i = 0; i < 1024; i++) ids.add(new Object());
        for (boolean biome : new boolean[]{false, true}) {
            Strategy<Object> strategy = biome ? Strategy.createForBiomes(ids) : Strategy.createForBlockStates(ids);
            int axis = biome ? 4 : 16, size = strategy.entryCount();
            for (int distinct : new int[]{1, 2, 16, 17, 256, 257, 900}) {
                PalettedContainer<Object> c = new PalettedContainer<>(ids.byId(0), strategy);
                Random random = new Random(distinct);
                Object[] expected = new Object[size];
                for (int y = 0, i = 0; y < axis; y++) for (int z = 0; z < axis; z++) for (int x = 0; x < axis; x++, i++) {
                    expected[i] = ids.byId(random.nextInt(distinct));
                    c.set(x, y, z, expected[i]);
                }
                var saved = c.pack(strategy);
                // Keep the LongStream alive while further calls overwrite the same worker scratch.
                for (int i = 0; i < 8; i++) new PalettedContainer<>(ids.byId(i), strategy).pack(strategy);
                var decoded = PalettedContainer.unpack(strategy, saved).getOrThrow();
                for (int y = 0, i = 0; y < axis; y++) for (int z = 0; z < axis; z++) for (int x = 0; x < axis; x++, i++)
                    check(decoded.get(x, y, z) == expected[i], "Saved section round trip");
            }
        }
        if (transformed) {
            var strategy = Strategy.createForBlockStates(ids);
            var c = new PalettedContainer<>(ids.byId(0), strategy);
            for (int i = 0; i < 2000; i++) c.pack(strategy);
            var bean = (com.sun.management.ThreadMXBean) ManagementFactory.getThreadMXBean();
            bean.setThreadAllocatedMemoryEnabled(true);
            long before = bean.getThreadAllocatedBytes(Thread.currentThread().threadId());
            for (int i = 0; i < 1000; i++) c.pack(strategy);
            long bytes = bean.getThreadAllocatedBytes(Thread.currentThread().threadId()) - before;
            check(bytes / 1000 < 8192, "Packing mixin was not applied: " + bytes / 1000 + " bytes/pack");
            System.out.println("PALETTE_PACKING_CHECK transformed bytes/pack=" + bytes / 1000);
        }
        System.out.println("PALETTE_PACKING_CHECK PASS");
    }
    public static void main(String[] args) throws Exception { run(false); }
}
