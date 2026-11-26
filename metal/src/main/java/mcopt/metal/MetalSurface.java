package mcopt.metal;

import com.mojang.renderpearl.api.device.GpuSurface;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.GpuSurfaceBackend;
import java.util.Collection;
import java.util.List;
import org.lwjgl.sdl.SDLMetal;

/**
 * A CAMetalLayer on the SDL window. The drawable is fetched at blit time rather than frame start: holding it for
 * the whole frame only adds latency and can stall on a drawable the display hasn't released yet.
 */
final class MetalSurface implements GpuSurfaceBackend {
	/** With vsync off, present only the last frame that makes each refresh (see mc_pace); -Dmcopt.metal.pace=false presents every frame. */
	private static final boolean PACE = Boolean.parseBoolean(System.getProperty("mcopt.metal.pace", "true"));
	/** How long before a refresh a finished frame has to reach the compositor to be shown on it. */
	/** -Dmcopt.metal.paceMarginMs: how long before a refresh the paced present must be done (the compositor's latch); default 2. */
	private static final double PACE_MARGIN_S = Double.parseDouble(System.getProperty("mcopt.metal.paceMarginMs", "2")) / 1000;
	/** -Dmcopt.metal.drawables=2|3: the layer's maximumDrawableCount (default 3). */
	private static final int DRAWABLES = Integer.getInteger("mcopt.metal.drawables", 0);
	/**
	 * -Dmcopt.metal.paceSync=true: the paced presents (vsync off) go out with display sync on, so each latches at a vblank. On
	 * the laptop's 120 Hz 5K display at ~1800 fps, paced presents without display sync reach the screen in pairs ~1.9 ms apart
	 * every 16.7 ms (a 60 Hz cadence); with vsync the grid is a clean 8.33 ms.
	 */
	private static final boolean PACE_SYNC = Boolean.getBoolean("mcopt.metal.paceSync");
	/**
	 * -Dmcopt.metal.paceAdapt=true: the pacer's margin learns the compositor's latch from scanout times (mc_pace in mcmetal.m): a
	 * paced frame shown more than half a refresh after the refresh it was aimed at adds lead, a frame on time takes a little away.
	 */
	static final boolean PACE_ADAPT = Boolean.getBoolean("mcopt.metal.paceAdapt");
	/**
	 * (1.1.1) -Dmcopt.metal.paceFollow=true: the pacer's refresh grid comes from the display the window is on, not the main display
	 * (mc_pace_follow in mcmetal.m). Native shading turns it on unless set (Shade.init).
	 */
	private static final boolean PACE_FOLLOW = Boolean.getBoolean("mcopt.metal.paceFollow");
	/**
	 * (2.0.1e) -Dmcopt.metal.vsyncDirect=true (set by Shade.init unless specified): with VSync (FIFO) on, acquire the drawable
	 * and present directly on the frame's command buffer instead of routing through presentQueue=acquire, so FIFO back-pressure
	 * paces the render thread cleanly without silently dropping/skipping presents. VSync-off is unchanged.
	 */
	private static final boolean VSYNC_DIRECT = Boolean.getBoolean("mcopt.metal.vsyncDirect");
	/**
	 * (2.0.1g) -Dmcopt.metal.paceMinRatio=0..1 (set to 0.55 by Shade.init unless specified): with VSync off, never let
	 * mc_pace drop presents when frameInterval >= period * ratio (i.e. near or below display refresh, such as maxFps=120
	 * on 120 Hz or shaded ~100-150 fps); instead let the presentQueue mailbox deliver every refresh cleanly.
	 */
	private static final double PACE_MIN_RATIO = parseNonNegDouble("mcopt.metal.paceMinRatio");
	/**
	 * (2.0.1g) -Dmcopt.metal.presentFreshAcquire=true (set by Shade.init unless specified): in presentQueue=acquire, acquire
	 * the CAMetalDrawable before popping the latest pqHandoff slot and scan all 4 staging slots in pqFill so VSync-off
	 * presents never stall stale frames or falsely skip.
	 */
	private static final boolean PRESENT_FRESH_ACQUIRE = Boolean.getBoolean("mcopt.metal.presentFreshAcquire");

	private static double parseNonNegDouble(String key) {
		String raw = System.getProperty(key);
		if (raw == null || raw.isBlank()) return 0.0;
		try {
			double v = Double.parseDouble(raw.trim());
			return v > 0.0 ? Math.min(v, 1.0) : 0.0;
		} catch (NumberFormatException e) {
			return 0.0;
		}
	}
	private boolean paced, vsync;
	/** (1.1.1) the display whose refreshes the pacer follows, as last logged (PACE_FOLLOW), and a frame counter for the check. */
	private int loggedDisplay, paceFrames, refreshFrames;
	private final long ctx;
	private final MetalEncoder encoder;
	private final long view;
	private final long layer;

	MetalSurface(long ctx, MetalEncoder encoder, long window) {
		this.ctx = ctx;
		this.encoder = encoder;
		this.view = SDLMetal.SDL_Metal_CreateView(window);
		this.layer = SDLMetal.SDL_Metal_GetLayer(this.view);
	}

	@Override
	public void configure(GpuSurface.Configuration config) {
		boolean vsync = config.presentMode() == GpuSurface.PresentMode.FIFO;
		this.vsync = vsync;
		this.paced = !vsync && PACE;
		if (PACE_ADAPT) Native.paceAdapt(this.paced ? 1 : 0);
		if (PACE_FOLLOW) Native.paceFollow(1);
		if (PACE_MIN_RATIO > 0.0) Native.paceMinRatio(this.paced ? PACE_MIN_RATIO : 0.0);
		if (PRESENT_FRESH_ACQUIRE) Native.presentFreshAcquire(1);
		// native shading's XDR output (mcopt.shade.xdr): decided before the layer's format is set; a constant false without shading
		if (mcopt.metal.shade.Shade.ENABLED) mcopt.metal.shade.dims.ShadeXdr.configure(this.layer);
		Native.layerConfigure(this.ctx, this.layer, config.width(), config.height(), (vsync || PACE_SYNC && this.paced ? 1 : 0) | DRAWABLES << 8);
		boolean directVsync = vsync && VSYNC_DIRECT;
		FrameWait.setVsync(directVsync, directVsync ? Native.layerRefreshHz(this.layer) : 0);
	}

	@Override
	public boolean isSuboptimal() {
		return false;
	}

	@Override
	public void acquireNextTexture() {
		FrameWait.markPresentedVsync(false);
	}

	@Override
	public void blitFromTexture(CommandEncoderBackend commandEncoder, GpuTextureView textureView) {
		// mcopt.rec hook: the opt-in recorder (-Dmcopt.rec, mcopt.metal.rec) takes the finished frame, GUI included. Rec.ON is a constant false without it.
		if (mcopt.metal.rec.Rec.ON) mcopt.metal.rec.Rec.frame(this.encoder, textureView);
		boolean directVsync = this.vsync && VSYNC_DIRECT;
		if (directVsync && (this.refreshFrames++ & 255) == 0) {
			int hz = Native.layerRefreshHz(this.layer);
			if (hz > 0) FrameWait.setVsync(true, hz);
		}
		if (this.paced && PACE_FOLLOW && (this.paceFrames++ & 255) == 0) {
			int display = Native.paceDisplay();
			if (display != 0 && display != this.loggedDisplay) {
				System.out.println("[mcopt] metal: frames paced to the refreshes of display " + Integer.toUnsignedString(display));
				this.loggedDisplay = display;
			}
		}
		long t0 = WaitStats.ON ? System.nanoTime() : 0;
		if (this.paced && !Native.pace(PACE_MARGIN_S)) {
			if (WaitStats.ON) WaitStats.wait(WaitStats.PACE, System.nanoTime() - t0, 0);
			return;
		}
		long t1 = WaitStats.ON ? System.nanoTime() : 0;
		if (WaitStats.ON && this.paced) WaitStats.wait(WaitStats.PACE, t1 - t0, 0);
		if (MetalEncoder.PRESENT_ACQUIRE && !directVsync) {
			this.encoder.presentAcquire(this.layer, textureView); // no nextDrawable here: the present side acquires it
			return;
		}
		MetalEvents.Operation event = MetalEvents.begin("nextDrawable", -1, 0);
		long drawable;
		try {
			drawable = Native.layerNext(this.layer);
		} finally {
			MetalEvents.end(event);
		}
		if (WaitStats.ON) WaitStats.wait(WaitStats.DRAWABLE, System.nanoTime() - t1, 0);
		if (drawable == 0) return; // no drawable (window hidden): skip the frame's present
		this.encoder.presentTexture(drawable, textureView, directVsync);
		this.encoder.afterGpuFinishes(() -> Native.release(drawable));
		if (directVsync) FrameWait.markPresentedVsync(true);
	}

	@Override
	public void present() {
		// The present was scheduled on the frame's command buffer in blitFromTexture and happens when it's committed.
		if (this.vsync && VSYNC_DIRECT) FrameWait.paceVsync();
	}

	@Override
	public Collection<GpuSurface.PresentMode> supportedPresentModes() {
		return List.of(GpuSurface.PresentMode.IMMEDIATE, GpuSurface.PresentMode.FIFO);
	}

	@Override
	public void close() {
		FrameWait.setVsync(false, 0);
		SDLMetal.SDL_Metal_DestroyView(this.view);
	}
}
