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

	private static boolean vsyncDirect;
	private static int vsyncRefreshHz;
	private static boolean presentedVsync;

	private FrameWait() {
	}

	static void setVsync(boolean direct, int refreshHz) {
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

	public static void sleep(long nanos) {
		Native.sleepPrecise(nanos);
	}
}
