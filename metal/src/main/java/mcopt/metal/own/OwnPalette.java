package mcopt.metal.own;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import net.minecraft.util.BitStorage;
import net.minecraft.world.level.chunk.Palette;
import net.minecraft.world.level.chunk.PalettedContainer;

/**
 * A PalettedContainer's raw contents in one go (-Dmcopt.own.mesh.prefill): its storage unpacked into palette ids (index order,
 * y << 8 | z << 4 | x) and its palette, through handles on the private data record (looked up once).
 */
public final class OwnPalette {
	private static final MethodHandle DATA, STORAGE, PALETTE;

	static {
		try {
			MethodHandles.Lookup l = MethodHandles.privateLookupIn(PalettedContainer.class, MethodHandles.lookup());
			Class<?> data = Class.forName(PalettedContainer.class.getName() + "$Data", false, PalettedContainer.class.getClassLoader());
			MethodHandles.Lookup d = MethodHandles.privateLookupIn(data, MethodHandles.lookup());
			DATA = l.findGetter(PalettedContainer.class, "data", data).asType(MethodType.methodType(Object.class, PalettedContainer.class));
			STORAGE = d.findVirtual(data, "storage", MethodType.methodType(BitStorage.class)).asType(MethodType.methodType(BitStorage.class, Object.class));
			PALETTE = d.findVirtual(data, "palette", MethodType.methodType(Palette.class)).asType(MethodType.methodType(Palette.class, Object.class));
		} catch (ReflectiveOperationException e) {
			throw new ExceptionInInitializerError(e);
		}
	}

	private OwnPalette() {
	}

	/** Unpacks c's 4096 ids into ids; returns the palette they index (read from the same data snapshot). */
	@SuppressWarnings("unchecked")
	public static <T> Palette<T> unpack(PalettedContainer<T> c, int[] ids) {
		try {
			Object data = (Object) DATA.invokeExact(c);
			((BitStorage) STORAGE.invokeExact(data)).unpack(ids);
			return (Palette<T>) (Palette<?>) PALETTE.invokeExact(data);
		} catch (Throwable t) {
			throw new IllegalStateException(t);
		}
	}
}
