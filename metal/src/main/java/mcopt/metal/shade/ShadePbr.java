/* Copyright 2026 mcopt-shade contributors.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy at https://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software distributed
 * under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for details.
 */
package mcopt.metal.shade;

import com.mojang.blaze3d.platform.NativeImage;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import mcopt.metal.mixin.AtlasDoubleAtlasAccess;
import mcopt.metal.mixin.AtlasDoubleSpriteAccess;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.TextureAtlas;
import net.minecraft.resources.Identifier;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

/** Parallel labPBR 1.3 atlases. Render thread only; no allocations or lookups per frame once built.
 * Animated materials use their first frame. Height/POM, porosity and SSS are reserved for a later version.
 */
public final class ShadePbr {
	private record Sprite(Identifier name, int x, int y, int pad, int w, int h) {}
	private record Atlas(int w, int h, int mips, List<Sprite> sprites) {}
	private record Material(Sprite sprite, int[] pixels) {}
	private static Atlas pending, current;
	private static long normal, specular;
	private static boolean attempted;
	private static boolean enabled() { return Shade.ENABLED && ShadeConfig.HDR && Live.b("mcopt.shade.pbr", true); }

	public static void atlasUploaded(TextureAtlas atlas) {
		if (!Shade.ENABLED || !atlas.location().getPath().endsWith("atlas/blocks.png")) return;
		AtlasDoubleAtlasAccess a = (AtlasDoubleAtlasAccess) atlas;
		List<Sprite> sprites = new ArrayList<>();
		for (var s : a.mcopt$adSprites()) {
			sprites.add(new Sprite(s.contents().name(), s.getX(), s.getY(),
				((AtlasDoubleSpriteAccess) s).mcopt$adPadding(), s.contents().width(), s.contents().height()));
		}
		pending = new Atlas(a.mcopt$adWidth(), a.mcopt$adHeight(), a.mcopt$adMaxMip() + 1, List.copyOf(sprites));
		attempted = false;
	}

	/** Called after the resource ring advances, before the frame's strengths are packed. */
	static void frame() {
		if (ShadeBindings.ctx() == 0) return;
		if (pending != null) {
			clear();
			current = pending;
			pending = null;
			attempted = false;
		}
		// Keep loaded atlases cached when toggled off; only the packed strengths change.
		if (!enabled()) return;
		if (attempted || current == null) return;
		attempted = true;
		long start = System.nanoTime();
		Atlas a = current;
		// Includes both GPU mip chains; refuse giant allocations before loading any images.
		if (a.w > 8192 || a.h > 8192 || (long) a.w * a.h * 4 * 2 * 4 / 3 > 768L * 1024 * 1024) {
			System.out.println("[mcopt] shade: PBR: atlas " + a.w + "x" + a.h + " exceeds 768 MiB budget; skipped");
			return;
		}
		try {
			List<Material> ns = load(a, "_n"), ss = load(a, "_s");
			if (!ns.isEmpty()) normal = upload(a, ns, true);
			if (!ss.isEmpty()) specular = upload(a, ss, false);
			// Each slot needs valid defaults, even when a pack contains only one kind of map.
			if (!ns.isEmpty() || !ss.isEmpty()) {
				if (normal == 0) normal = defaultTexture(true);
				if (specular == 0) specular = defaultTexture(false);
				ShadeRender.resource(7, normal);
				ShadeRender.resource(8, specular);
			}
			System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: PBR: %d normal maps, %d specular maps (atlas %dx%d, %.0f ms)",
				ns.size(), ss.size(), a.w, a.h, (System.nanoTime() - start) / 1e6));
		} catch (Exception e) {
			clear();
			System.out.println("[mcopt] shade: PBR unavailable: " + e);
		}
	}

	private static void clear() {
		ShadeRender.resource(7, 0); ShadeRender.resource(8, 0);
		if (normal != 0) ShadeNative.textureRelease(normal);
		if (specular != 0) ShadeNative.textureRelease(specular);
		normal = specular = 0;
	}

	public static boolean active() {
		return enabled() && normal != 0 && (strength("normal") != 0 || strength("specular") > 0 || strength("emission") > 0);
	}

	static float strength(String key) {
		if (!enabled() || normal == 0) return 0;
		float v = Live.f("mcopt.shade.pbr." + key, 1f, 0f, 2f);
		return key.equals("normal") && Live.b("mcopt.shade.pbr.flipY", false) ? -v : v;
	}

	private static List<Material> load(Atlas a, String suffix) {
		List<Material> out = new ArrayList<>();
		var manager = Minecraft.getInstance().getResourceManager();
		for (Sprite s : a.sprites) {
			var file = s.name.withPath("textures/" + s.name.getPath() + suffix + ".png");
			var resource = manager.getResource(file);
			if (resource.isEmpty()) continue;
			try (var stream = resource.get().open(); NativeImage img = NativeImage.read(stream)) {
				// Limit each image too, including animation strips. Resource packs are untrusted inputs.
				if ((long) img.getWidth() * img.getHeight() > 16L * 1024 * 1024) continue;
				int[] src = img.getPixelsABGR(), dst = new int[s.w * s.h];
				int frameH = Math.min(img.getHeight(), Math.max(1, img.getWidth() * s.h / s.w));
				for (int y = 0; y < s.h; y++) for (int x = 0; x < s.w; x++)
					{ int v = src[(y * frameH / s.h) * img.getWidth() + x * img.getWidth() / s.w];
						// Decode the no-emission sentinel before hardware filtering/mips.
						if (suffix.equals("_s") && (v >>> 24) == 255) v &= 0x00ffffff;
						dst[y * s.w + x] = v; }
				out.add(new Material(s, dst));
			} catch (Exception e) {
				System.out.println("[mcopt] shade: PBR: skipping " + file + ": " + e);
			}
		}
		return out;
	}

	private static long create(int w, int h, int mips, String label) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long tex = ShadeNative.textureCpu(ShadeBindings.ctx(), w, h, mips, MemoryUtil.memAddress(stack.UTF8(label)));
			if (tex == 0) throw new IllegalStateException("PBR texture allocation failed");
			return tex;
		}
	}

	private static int empty(boolean n) { return n ? 0xffff8080 : 0x00000000; }
	private static long defaultTexture(boolean n) {
		long tex = create(1, 1, 1, "mcopt PBR default");
		ByteBuffer b = MemoryUtil.memAlloc(4);
		try { b.order(java.nio.ByteOrder.LITTLE_ENDIAN).putInt(0, empty(n));
			ShadeNative.textureUpload(tex, 0, 0, 0, 1, 1, MemoryUtil.memAddress(b), 4);
		} finally { MemoryUtil.memFree(b); }
		return tex;
	}

	private static long upload(Atlas a, List<Material> maps, boolean n) {
		long tex = create(a.w, a.h, a.mips, n ? "mcopt labPBR normals" : "mcopt labPBR specular");
		try {
			List<int[]> pixels = new ArrayList<>();
			for (Material m : maps) pixels.add(m.pixels);
			for (int level = 0; level < a.mips; level++) {
				int w = Math.max(1, a.w >> level), h = Math.max(1, a.h >> level);
				ByteBuffer b = MemoryUtil.memAlloc(w * h * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN);
				try {
					for (int i = 0; i < w * h; i++) b.putInt(i * 4, empty(n));
					for (int i = 0; i < maps.size(); i++) {
						Sprite s = maps.get(i).sprite;
						int sw = Math.max(1, s.w >> level), sh = Math.max(1, s.h >> level);
						int x0 = (s.x + s.pad) >> level, y0 = (s.y + s.pad) >> level;
						int pad = s.pad >> level;
						int[] p = pixels.get(i);
						for (int y = Math.max(0, y0 - pad); y < Math.min(h, y0 + sh + pad); y++)
							for (int x = Math.max(0, x0 - pad); x < Math.min(w, x0 + sw + pad); x++)
								b.putInt((y * w + x) * 4, p[Math.clamp(y-y0, 0, sh-1) * sw + Math.clamp(x-x0, 0, sw-1)]);
						if (level + 1 < a.mips) pixels.set(i, mip(p, sw, sh, n));
					}
					ShadeNative.textureUpload(tex, level, 0, 0, w, h, MemoryUtil.memAddress(b), w * 4);
				} finally { MemoryUtil.memFree(b); }
			}
			return tex;
		} catch (Throwable e) { ShadeNative.textureRelease(tex); throw e; }
	}

	/** Sprite-local mips avoid bleeding. Decode emission's 255 sentinel before filtering. */
	static int[] mip(int[] p, int w, int h, boolean normal) {
		int nw = Math.max(1, w / 2), nh = Math.max(1, h / 2);
		int[] out = new int[nw * nh];
		for (int y = 0; y < nh; y++) for (int x = 0; x < nw; x++) {
			int[] sum = new int[4];
			double sx = 0, sy = 0, sz = 0;
			for (int yy = 0; yy < 2; yy++) for (int xx = 0; xx < 2; xx++) {
				int v = p[Math.min(h-1, y*2+yy)*w + Math.min(w-1, x*2+xx)];
				if (normal) {
					double nx = (v & 255)/127.5-1, ny = ((v>>>8)&255)/127.5-1;
					sx += nx; sy += ny; sz += Math.sqrt(Math.max(0,1-nx*nx-ny*ny));
				}
				for (int c = 0; c < 4; c++) { int q = (v >>> (c*8)) & 255;
					sum[c] += q; }
			}
			int r = (sum[0]+2)/4, g = (sum[1]+2)/4, b = (sum[2]+2)/4, a = (sum[3]+2)/4;
			if (normal) {
				double len = Math.sqrt(sx*sx+sy*sy+sz*sz);
				if (len > 1e-8) { r = (int)Math.round((sx/len+1)*127.5); g = (int)Math.round((sy/len+1)*127.5); }
			} else {
				// G >= 230 is a material ID, not a scalar F0: keep the nearest material's category at boundaries.
				int first = (p[Math.min(h-1,y*2)*w + Math.min(w-1,x*2)] >>> 8) & 255;
				if (first >= 230 || g >= 230) g = first;

			}
			out[y*nw+x] = r | (g<<8) | (b<<16) | (a<<24);
		}
		return out;
	}
}
