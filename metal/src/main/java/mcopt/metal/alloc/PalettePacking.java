package mcopt.metal.alloc;

import net.minecraft.util.BitStorage;
import net.minecraft.world.level.chunk.Palette;
import net.minecraft.world.level.chunk.PaletteResize;

/** Scratch IDs used only while PalettedContainer.pack builds its independently owned packed longs. */
public final class PalettePacking {
	private static final int RETAINED_DEPTH = 4;
	private static final ThreadLocal<Scratch> LOCAL = ThreadLocal.withInitial(Scratch::new);

	private static final class Scratch {
		// Separate sizes avoid reallocating when block states and biomes are saved alternately.
		final int[][] blocks = new int[RETAINED_DEPTH][];
		final int[][] biomes = new int[RETAINED_DEPTH][];
		int depth;
	}

	private PalettePacking() { }

	public static void enter() { LOCAL.get().depth++; }
	public static void exit() { LOCAL.get().depth--; }

	private static int[] buffer(int size) {
		Scratch scratch = LOCAL.get();
		int slot = scratch.depth - 1;
		// Bound retained memory, including for unusual strategies or recursively invoked mod codecs.
		if (slot < 0 || slot >= RETAINED_DEPTH || size != 4096 && size != 64) return new int[size];
		int[][] buffers = size == 4096 ? scratch.blocks : scratch.biomes;
		if (buffers[slot] == null) buffers[slot] = new int[size];
		return buffers[slot];
	}

	/** Same order and palette IDs as vanilla reencodeContents; the caller holds the scope until packing completes. */
	public static <T> int[] reencode(BitStorage storage, Palette<T> from, Palette<T> to) {
		int[] ids = buffer(storage.getSize());
		storage.unpack(ids);
		PaletteResize<T> resize = PaletteResize.noResizeExpected();
		int previous = -1, mapped = -1;
		for (int i = 0; i < ids.length; i++) {
			int id = ids[i];
			if (id != previous) {
				previous = id;
				mapped = to.idFor(from.valueFor(id), resize);
			}
			ids[i] = mapped;
		}
		return ids;
	}
}
