/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.shade.dims;

import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.invoke.MethodHandle;
import java.nio.ByteBuffer;
import mcopt.metal.MetalBridge;
import org.jspecify.annotations.Nullable;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

import static java.lang.foreign.ValueLayout.JAVA_FLOAT;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/**
 * XDR / EDR output (bible E23; native side mcxdr.m, which documents the frame). Decided once, when the game first configures
 * its surface ({@link #configure}, from MetalSurface): mcopt.shade.xdr = auto (on when a screen can show EDR), on or off
 * (until 1.1 never with upstream's frame generation, which mcopt 0.3 removed). While on, the final pass (ShadePost) writes the SDR image into main (alpha 0) plus the highlights'
 * excess above SDR white into its own RG11B10Float target, and the present composes them into the RGBA16Float extended
 * linear Display P3 drawable. The highlight peak follows the screen's current EDR headroom (smoothed, capped by
 * mcopt.shade.xdrPeak), so the brightness slider never makes highlights jump. Render thread only.
 */
public final class ShadeXdr {
	private static final Linker LINKER = Linker.nativeLinker();
	private static @Nullable MethodHandle enable, isOn, supported, headroom, frame, pso2, pass2, systemInfo, e5, fullFrame;
	private static boolean decided, on, confirmed, edrHere = true;
	private static long layer;
	private static float loggedHeadroom = -1f, peak = 1f, sinceQuery = 1f, target = 1f, headroomNow = 1f, potential = 1f;
	/** The scene luminance (pre-tonemap, exposed) where highlights start to use the headroom, and how many octaves above it they reach the peak. */
	// knee 3 / 4 octaves (the first cut) left lava, glowstone and torches under SDR white in every dumped scene (max 1.2x):
	// 2.0 / 3.5 lets emissive cores and the sun use the headroom while lit surfaces (snow at noon) stay within ~1.1x
	static final float KNEE = DimsConfig.floatFlag("mcopt.shade.xdrKnee", 2.0f, 0.5f, 16f), RANGE = 3.5f;
	private static float testClock;

	/** (1.1) live: mcopt.shade.xdrKnee (KNEE at startup; 0.5..16): the final pass's knee and the bloom's hot flag follow it. */
	static float knee() {
		return mcopt.metal.shade.Live.f("mcopt.shade.xdrKnee", KNEE, 0.5f, 16f);
	}

	private ShadeXdr() {
	}

	private static MethodHandle fn(String name, MemoryLayout result, MemoryLayout... args) {
		FunctionDescriptor d = result == null ? FunctionDescriptor.ofVoid(args) : FunctionDescriptor.of(result, args);
		var symbol = MetalBridge.library().find(name).orElseThrow(() -> new IllegalStateException("missing native symbol " + name));
		return LINKER.downcallHandle(symbol, d);
	}

	private static void link() {
		if (enable != null) return;
		enable = fn("mc_xdr_enable", null, JAVA_INT);
		isOn = fn("mc_xdr_on", JAVA_INT);
		supported = fn("mc_xdr_supported", JAVA_INT);
		headroom = fn("mc_xdr_headroom", JAVA_FLOAT, JAVA_LONG, JAVA_INT);
		frame = fn("mc_xdr_frame", null, JAVA_LONG, JAVA_LONG);
		fullFrame = fn("mc_xdr_full_frame", null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_FLOAT, JAVA_FLOAT);
		pso2 = fn("mc_xdr_pso2", JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT);
		pass2 = fn("mc_xdr_pass2", null, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_LONG, JAVA_INT, JAVA_LONG, JAVA_INT, JAVA_LONG);
		systemInfo = fn("mc_system_info", null, JAVA_LONG, JAVA_LONG, JAVA_INT);
		e5 = fn("mc_xdr_e5", null, JAVA_INT);
	}

	/** MetalSurface.configure, before the layer's format is set (every configure; the decision is taken the first time). */
	public static void configure(long metalLayer) {
		layer = metalLayer;
		if (decided) return;
		decided = true;
		try {
			link();
			// (1.1.1) the OS build and the screens, for bug reports (e.g. from macOS 27)
			try (MemoryStack stack = MemoryStack.stackPush()) {
				long buf = stack.nmalloc(1, 1024);
				systemInfo.invokeExact(metalLayer, buf, 1024);
				System.out.println("[mcopt] shade: system: " + MemoryUtil.memUTF8(buf));
			}
			int mode = DimsConfig.XDR;
			boolean can = (int) supported.invokeExact() != 0;
			potential = (float) headroom.invokeExact(metalLayer, 1);
			on = mode == 2 || mode == 1 && can;
			enable.invokeExact(on ? 1 : 0);
			// (v12-opt, mcopt.shade.xdrDirectE5, default true; false = 1.2) without the present queue (-Dmcopt.metal.presentQueue=false) the
			// compose writes the drawable itself: rounded as the queue's RGB9E5 slot, both paths present the same pixels
			e5.invokeExact(Boolean.parseBoolean(System.getProperty("mcopt.shade.xdrDirectE5", "true")) ? 1 : 0);
			System.out.println("[mcopt] shade: XDR output " + (on ? "on" : "off") + " (mcopt.shade.xdr=" + new String[] {"off", "auto", "on"}[mode]
				+ ", EDR screen " + can + ", this screen's potential headroom " + potential + ")");
		} catch (Throwable t) {
			on = false;
			System.out.println("[mcopt] shade: XDR output unavailable: " + t);
		}
	}

	/** Whether the surface presents EDR (the final pass then writes the excess image). */
	public static boolean active() {
		return on;
	}

	/** Once per world frame (ShadeFrameUpdater): follows the screen's EDR headroom. */
	public static void frame(float dt) {
		if (on && !confirmed) { // the layer configure may have turned it off (pipelines unavailable): follow the native side
			confirmed = true;
			try {
				if ((int) isOn.invokeExact() == 0) {
					on = false;
					System.out.println("[mcopt] shade: XDR output off (the EDR present pipelines could not be built)");
				}
			} catch (Throwable t) {
				on = false;
			}
		}
		sinceQuery += dt;
		if (sinceQuery >= 0.25f) {
			sinceQuery = 0f;
			float here;
			try {
				headroomNow = (float) headroom.invokeExact(layer, 0);
				here = (float) headroom.invokeExact(layer, 1);
			} catch (Throwable t) {
				headroomNow = 1f;
				here = 1f;
			}
			// the window's screen can't show EDR at all (an SDR monitor such as a 1080p external one): the final pass goes back
			// to the plain SDR variant (no excess written, the compose is a plain conversion) until it is on an EDR screen again
			// dev test of the SDR-screen fallback without an SDR monitor (read live: the bench's in-session A/B sets it per phase):
			// mcopt.shade.xdrTest = sdr (this screen counts as SDR only) or flip (SDR / EDR alternating every 10 s)
			String test = System.getProperty("mcopt.shade.xdrTest", "");
			testClock += 0.25f;
			if (test.equals("sdr") || test.equals("flip") && ((int) (testClock / 10f) & 1) == 1) here = 1f;
			boolean nowHere = here > 1.01f;
			if (nowHere != edrHere) {
				edrHere = nowHere;
				System.out.println("[mcopt] shade: XDR " + (edrHere ? "resumed (EDR screen, potential " : "paused (this screen is SDR only, potential ") + here + ")");
			}
			// (1.1) mcopt.shade.xdrPeak live (1..16): applies at the next query (0.25 s), eased like a headroom change
			float cap = mcopt.metal.shade.Live.f("mcopt.shade.xdrPeak", DimsConfig.XDR_PEAK, 1f, 16f);
			target = edrHere ? Math.max(1f, Math.min(headroomNow, cap)) : 1f;
			if (Math.abs(headroomNow - loggedHeadroom) > 0.1f) {
				loggedHeadroom = headroomNow;
				System.out.println("[mcopt] shade: XDR headroom " + headroomNow + " (potential " + potential + "), highlight peak " + target);
			}
		}
		peak += (target - peak) * (1f - (float) Math.exp(-dt / 0.5f));
		if (on) updateSkip(dt);
	}

	/** Live display transform selection; highlight-only remains the default. */
	public static boolean fullScene() {
		return mcopt.metal.shade.Live.s("mcopt.shade.hdrMode", "highlights").equals("scene");
	}

	/** No threshold/empty-highlight skipping: all world pixels use the HDR curve. */
	public static boolean fullSceneFrame() {
		var mc = net.minecraft.client.Minecraft.getInstance();
		var screen = mc != null ? mc.gui.screen() : null;
		return fullScene() && on && edrHere && displayPeak() > 1.00001f
			&& (screen == null || screen instanceof net.minecraft.client.gui.screens.ChatScreen);
	}

	public static float sceneBrightness() {
		return mcopt.metal.shade.Live.f("mcopt.shade.hdrSceneBrightness", 1f, 0.5f, 2f);
	}

	private static float displayPeak() {
		// Respond immediately to shrinking headroom; ease increases without exceeding the display.
		return Math.max(1f, Math.min(peak, headroomNow));
	}

	public static boolean highlights() {
		if (fullScene()) return fullSceneFrame();
		// (v12-opt, mcopt.shade.xdrPeakSkip, live, default true; false = 1.2) with a peak of SDR white (the screen reports no EDR
		// headroom: maximumExtendedDynamicRangeColorComponentValue 1, as in many bench runs; or mcopt.shade.xdrPeak=1) the XDR final
		// pass writes an excess of 0 (shade_final_xdr: boost = (peak - 1) x ... only where peak > 1) and the compose adds it: the SDR
		// final pass and a compose without the excess present the same pixels (tools: fcmp, 0 texels differ in rgb), without the
		// RG11B10F write and its read. 1 + 1e-5: the eased peak can stop an ulp above 1 after the headroom falls back to 1; an
		// excess of at most ~1e-5 x the pixel there changes no RGB9E5 / half value of a pixel above the knee
		return on && edrHere && (!skip || hot) && !(peak <= 1.00001f && mcopt.metal.shade.Live.b("mcopt.shade.xdrPeakSkip", true));
	}

	// M3.3 (mcopt.shade.xdrSkip, live, default true; false = M3.2): the XDR final pass and compose only while something on
	// screen nears the knee (the bloom's first downsample flags it on the GPU, ShadeGpu.xdrHot), held HOLD seconds after the
	// last such frame so it never flickers; otherwise the frame takes the SDR path (as on an SDR-only screen).
	private static boolean skip, hot = true;
	private static float sinceHot;
	private static long framesXdr, framesSdr;
	static final float HOLD = 1.5f, MARGIN = 0.5f;

	/** The bloom's first downsample flags pixels above this (pre-exposed scene luminance), 0 = don't flag (ShadePost). */
	public static float hotThreshold() {
		if (fullScene() || !(on && edrHere && skip)) return 0f;
		asked = true;
		return knee() * MARGIN; // (1.1) live
	}

	/** The last frame's bloom flagged (no bloom pass, e.g. bloom off: no detection, the highlights stay on). */
	private static boolean asked;

	private static void updateSkip(float dt) {
		skip = !"false".equals(System.getProperty("mcopt.shade.xdrSkip"));
		if (mcopt.metal.shade.ShadeBindings.takeXdrHot() || !asked) sinceHot = 0f;
		else sinceHot += dt;
		asked = false;
		boolean was = hot;
		hot = sinceHot < HOLD;
		if (highlights()) framesXdr++;
		else if (on && edrHere) framesSdr++;
		if (was != hot && LOG_SKIP) System.out.println("[mcopt] shade: XDR " + (hot ? "highlights on" : "skipped (nothing near the knee)"));
		if (LOG_SKIP && (framesXdr + framesSdr) % 2000 == 0 && framesXdr + framesSdr > 0)
			System.out.println("[mcopt] shade: XDR skip: " + framesXdr + " frames with highlights, " + framesSdr + " skipped");
	}

	private static final boolean LOG_SKIP = Boolean.getBoolean("mcopt.shade.xdrSkip.log"); // (M3.4: off by default, it logged every transition)

	/** The highlight peak this frame, in multiples of SDR white (1 = SDR). */
	public static float peak() {
		return peak;
	}

	/** The screen's EDR headroom as last queried, for logs. */
	public static float headroom() {
		return headroomNow;
	}

	/** ShadeFinalParams.x: highlights (1, peak, knee, range), full scene (2, peak, curve b, curve beta). */
	public static void params(ByteBuffer b) {
		if (fullScene()) {
			b.putFloat(2f).putFloat(displayPeak());
			mcopt.metal.shade.ShadeFrameUpdater.look().putHdrCurve(b, displayPeak());
		} else b.putFloat(on ? 1f : 0f).putFloat(peak).putFloat(knee()).putFloat(RANGE);
	}

	/** Called after output upscaling, before the hand/HUD modify main. */
	public static void fullFrame(long enc, long hdr, long main) {
		try {
			float ui = mcopt.metal.shade.Live.f("mcopt.shade.hdrUiBrightness", 1f, 0.25f, 2f);
			fullFrame.invokeExact(enc, hdr, main, ui, displayPeak());
		} catch (Throwable t) {
			throw new IllegalStateException("Full-scene HDR compose setup", t);
		}
	}

	/** A full-screen pipeline with two color targets (the final pass: main RGBA8 + the RG11B10F excess). */
	public static long pipeline2(long ctx, long library, String vertex, String fragment, int format0, int format1) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			long err = stack.nmalloc(1, 4096);
			MemoryUtil.memPutByte(err, (byte) 0);
			long pso = (long) pso2.invokeExact(ctx, library, MemoryUtil.memAddress(stack.UTF8(vertex)), MemoryUtil.memAddress(stack.UTF8(fragment)), format0, format1,
				err, 4096);
			if (pso == 0) throw new IllegalStateException("shade pipeline " + fragment + ": " + MemoryUtil.memUTF8(err));
			return pso;
		} catch (RuntimeException | Error e) {
			throw e;
		} catch (Throwable t) {
			throw new IllegalStateException(t);
		}
	}

	/** ShadeRender.pass with two targets, then hands the excess (t1) to this frame's present. */
	public static void finalPass(long enc, long pipeline, long t0, long t1, long[] textures, @Nullable ByteBuffer params, String label) {
		try (MemoryStack stack = MemoryStack.stackPush()) {
			int n = textures.length;
			long t = stack.nmalloc(8, Math.max(1, n) * 8);
			for (int i = 0; i < n; i++) MemoryUtil.memPutAddress(t + i * 8L, textures[i]);
			pass2.invokeExact(enc, pipeline, t0, t1, t, n, params == null ? 0L : MemoryUtil.memAddress(params), params == null ? 0 : params.remaining(),
				MemoryUtil.memAddress(stack.UTF8(label)));
			// with a screen open (pause menu, inventory...) the world behind it is blurred / dimmed by passes that keep main's alpha:
			// no highlights then (they would show unblurred through the menu). The chat screen draws no background (the world
			// stays as it is, its text box is GUI coverage in main's alpha): highlights stay on, no brightness jump on opening it.
			var mc = net.minecraft.client.Minecraft.getInstance();
			var screen = mc != null ? mc.gui.screen() : null;
			// Full-scene registration happens after output upscaling has completed. Until
			// then, never let the presenter treat the complete world image as excess.
			frame.invokeExact(enc, fullScene() || screen != null && !(screen instanceof net.minecraft.client.gui.screens.ChatScreen) ? 0L : t1);
		} catch (RuntimeException | Error e) {
			throw e;
		} catch (Throwable th) {
			throw new IllegalStateException(th);
		}
	}
}
