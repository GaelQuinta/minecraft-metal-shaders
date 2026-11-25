package mcopt.metal;

/** The frame limiter's wait, on a timer macOS can't defer; see mc_sleep_precise and FramerateLimiterMixin. */
public final class FrameWait {
	/** -Dmcopt.preciseLimiter=false keeps vanilla's park-then-spin wait. */
	public static final boolean ENABLED = Boolean.parseBoolean(System.getProperty("mcopt.preciseLimiter", "true"));
	/**
	 * (2.0.1e) -Dmcopt.metal.vsyncLimiter=true (set by Shade.init unless specified): skip redundant software sleeping when
	 * direct FIFO VSync already paced this frame and framerateLimit >= the display's refresh rate, and phase-lock software
	 * waits so kernel timer wake latency (~30 us) doesn't drift a 120 fps cap down to 119.6 fps.
	 */
	public static final boolean VSYNC_LIMITER = Boolean.getBoolean("mcopt.metal.vsyncLimiter");
	/**
	 * (2.0.1f) -Dmcopt.metal.vsyncMinPace=0..0.99 (set to 0.96 by Shade.init unless specified): minimum frame interval floor
	 * as a fraction of the display refresh period under direct FIFO VSync (e.g. 8.0 ms at 120 Hz). Breaks the 2 ms + 14 ms
	 * 60 Hz pairing limit cycle when a 3-drawable queue frees two drawables in a burst, while remaining below 1.0 so hardware
	 * VSync still locks the exact display rate without drifting to 119.4 fps.
	 */
	private static final double VSYNC_MIN_PACE = parseMinPace();

	private static double parseMinPace() {
		String raw = System.getProperty("mcopt.metal.vsyncMinPace");
		if (raw == null || raw.isBlank()) return 0.0;
		try {
			double v = Double.parseDouble(raw.trim());
			return v > 0.0 ? Math.min(v, 0.99) : 0.0;
		} catch (NumberFormatException e) {
			return 0.0;
		}
	}

	private static boolean vsyncDirect;
	private static int vsyncRefreshHz;
	private static boolean presentedVsync;
	private static long lastVsyncEndNs;

	private FrameWait() {
	}

	static void setVsync(boolean direct, int refreshHz) {
		if (vsyncDirect != direct || vsyncRefreshHz != (direct ? refreshHz : 0)) lastVsyncEndNs = 0;
		vsyncDirect = direct;
		vsyncRefreshHz = direct ? refreshHz : 0;
		if (!direct) presentedVsync = false;
	}

	static void markPresentedVsync(boolean presented) {
		presentedVsync = presented;
	}

	static boolean isVsyncDirect() {
		return vsyncDirect;
	}

	/** True when hardware VSync already paced this frame at or below framerateLimit, so software waiting would only fight vblank. */
	public static boolean skipForVsync(int framerateLimit) {
		return VSYNC_LIMITER && vsyncDirect && presentedVsync && vsyncRefreshHz > 0 && framerateLimit >= vsyncRefreshHz;
	}

	/**
	 * (2.0.1f) Enforces the minimum inter-frame spacing floor after submit() under direct FIFO VSync so DeltaTracker and input
	 * are never sampled back-to-back (~2 ms apart) followed by a ~14 ms stall.
	 */
	static void paceVsync() {
		if (!vsyncDirect || !presentedVsync || vsyncRefreshHz <= 0 || VSYNC_MIN_PACE <= 0.0) {
			lastVsyncEndNs = 0;
			return;
		}
		long now = System.nanoTime();
		long minPeriod = (long) (1_000_000_000.0 * VSYNC_MIN_PACE / vsyncRefreshHz);
		if (lastVsyncEndNs != 0) {
			long remaining = (lastVsyncEndNs + minPeriod) - now;
			if (remaining > 0 && remaining < minPeriod) {
				Native.sleepPrecise(remaining);
				now = System.nanoTime();
			}
		}
		lastVsyncEndNs = now;
	}

	/** Keeps paceVsync's anchor aligned when FramerateLimiter ran a lower cap (e.g. 60 fps or AFK 10 fps). */
	public static void onLimiterEnd(long nowNs) {
		if (vsyncDirect) lastVsyncEndNs = nowNs;
	}

	public static void sleep(long nanos) {
		Native.sleepPrecise(nanos);
	}
}
