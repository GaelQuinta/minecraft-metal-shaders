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
package mcopt.metal.shade.taa;

/**
 * Dynamic resolution controller (shader bible E18): picks the render scale from the GPU time of finished frames, so the
 * frame fits the budget of the target frame rate. Pure logic (no game or Metal types), render thread only.
 *
 * <p>Input: each retired frame's command buffer GPU start/end (seconds, host clock). The busy time of a frame is the part
 * of its [start, end] not already covered by the previous frame's (two frames are in flight and may overlap), so it is the
 * GPU time the frame really added. An exponential average over ~12 frames is compared with the target, 86% of the frame
 * budget (headroom for the CPU side and other apps); the new scale follows s' = s * sqrt(target / time) (cost ~ pixels ~
 * s^2), quantised to 1/64, applied only when it moves more than 0.015 (or reaches a bound). Asymmetric, so it doesn't
 * hunt: it drops fast (up to -0.04 per step, 8 frames after the last change) and climbs slowly (up to +0.02 per step, 45
 * frames after the last change, and only while the frame is under 92% of the target, so a climb never lands right on the
 * edge). After a change the frames still in flight are skipped and the average starts afresh (12 frames), so it never mixes
 * two scales. Changes cost nothing: the world renders into a viewport sub-rect of targets allocated at the maximum scale.
 *
 * <p>M3.3 "hold" controller ({@code mcopt.shade.drsHold}, read every frame, default on; false = the controller above, M3.2).
 * Measured on M3.2 (balanced, perf route, M33_MISC.md): the frame was 8-10 ms of GPU time while the scale sat at the preset's
 * floor 0.60 (98-122 fps): the controller could not go lower, and ~7 ms of the frame do not shrink with the render scale at
 * all (T ~ 6.8 + 7 s^2 ms: clouds, shadow maps, the TAAU resolve and the final pass run at the output resolution), so its s^2
 * model also under-stepped. The hold controller: a floor of {@code mcopt.shade.drsFloor} (0.55 = the pause menu's lowest choice,
 * 1080p on the 1964-pixel panel; the misc branch had 0.50, but at 0.50 the world reads visibly softer than at 0.60, run mx4
 * scale shots, and Gael asked for resolution first: 0.55 holds ~120 fps on the heavy route instead of 127) on performance and balanced (quality and ultra keep theirs), a cost model T(s') = T (k + (1 - k) s'^2 / s^2) with k =
 * {@code mcopt.shade.drsFixed} (0.5: the part that does not scale; conservative, the measured part is 0.6-0.8) and a band on
 * the frame budget 1 / fps: down when the average is over 96.5 % of it (124 fps at 120), to the scale the model puts at 90 %
 * (133 fps), up to 0.08 per step after 8 frames; up when the model says the next step stays under 86 % (139 fps), up to
 * 0.03 per step after 30 frames. Between the two nothing moves (hysteresis: no hunting), so the frame rate stays above the
 * panel's 120 Hz with the most resolution that allows (mcopt's pacer shows one frame per refresh: frames beyond ~125/s are
 * never seen, so M3.2's target of 139-152 fps spent resolution on nothing).
 */
public final class DynamicResolution {
	private static final float STEP_DOWN = 0.04f, STEP_UP = 0.02f, QUANTUM = 1f / 64f, DEADBAND = 0.015f, UP_MARGIN = 0.92f;
	private static final int SETTLE_FRAMES = 8, SETTLE_UP_FRAMES = 45, AVERAGE_FRAMES = 12, IN_FLIGHT = Math.max(1, Integer.getInteger("mcopt.metal.inFlight", 2));

	/** M3.3 hold controller: band and steps (see the class comment). */
	private static final double HOLD_SET = 0.90, HOLD_DOWN = 0.965, HOLD_UP = 0.86;
	private static final float HOLD_STEP_DOWN = 0.08f, HOLD_STEP_UP = 0.03f;
	private static final int HOLD_SETTLE_UP = 30;
	/** M3.3: the hold controller's floor (mcopt.shade.drsFloor, 0.40-1; default 0.55, the pause menu's 1080p on the Retina panel). */
	public static final float HOLD_FLOOR = TaaConfig.clamp(floatProp("mcopt.shade.drsFloor", 0.55f), 0.4f, 1f);

	/** (1.1) live: the hold controller's floor this frame (mcopt.shade.drsFloor, 0.40-1; HOLD_FLOOR at startup). */
	static float holdFloor() {
		return mcopt.metal.shade.Live.f("mcopt.shade.drsFloor", HOLD_FLOOR, 0.4f, 1f);
	}
	/** M3.3: the share of the frame's GPU time that does not scale with the render scale, for the hold controller's model. */
	/** The player set mcopt.shade.scaleMin: the hold controller keeps it instead of its own floor. */
	private static final boolean USER_MIN = System.getProperty("mcopt.shade.scaleMin") != null;
	private static final double HOLD_FIXED = TaaConfig.clamp(floatProp("mcopt.shade.drsFixed", 0.5f), 0f, 0.9f);

	private final float min, max;
	/** (1.1) mutable: mcopt.shade.drsFps is live ({@link #retarget}). */
	private int fps;
	private double targetSeconds;
	private float scale;
	private double average, lastEnd;
	private int samples, sinceChange, skip, pinned, outlierStreak;
	private volatile boolean paused;
	/** M3.3 (mcopt.shade.drsLog): a status line about once a second: what the controller sees, frames and changes since. */
	private long statusStart;
	private int statusFrames, statusChanges;
	private float statusMin = Float.MAX_VALUE, statusMax;

	public DynamicResolution(float start, float min, float max, int fps) {
		this.min = min;
		this.max = max;
		this.scale = TaaConfig.clamp(start, min, max);
		this.fps = fps;
		this.targetSeconds = 0.86 / fps;
	}

	/** M3.3: the hold controller is on (mcopt.shade.drsHold, read every frame: bench A/B in one session; false = M3.2's). */
	public static boolean hold() {
		String v = System.getProperty("mcopt.shade.drsHold");
		return v == null || Boolean.parseBoolean(v.trim());
	}

	private static float floatProp(String key, float fallback) {
		String v = System.getProperty(key);
		if (v == null || v.isBlank()) return fallback;
		try {
			return Float.parseFloat(v.trim());
		} catch (NumberFormatException e) {
			return fallback;
		}
	}

	public float scale() {
		return this.scale;
	}

	/**
	 * (1.1) A new target frame rate (mcopt.shade.drsFps, live; ShadeTaa.jitter passes it every frame): the budget moves, the
	 * timing average stays (it is still this scale's GPU time), so the next update steps toward the new target.
	 */
	public void retarget(int fps) {
		if (fps == this.fps || fps <= 0) return;
		this.fps = fps;
		this.targetSeconds = 0.86 / fps;
		this.pinned = 0;
	}

	/** Average GPU time per frame (ms) as the controller sees it, 0 before any frame. */
	public double averageMs() {
		return this.average * 1e3;
	}

	/** (2.0.1e) Pause DRS timing updates while unfocused or paused/in a menu so non-gameplay GPU times don't skew render scale. */
	public void setPaused(boolean paused) {
		if (paused && !this.paused) {
			this.skip = Math.max(this.skip, IN_FLIGHT + 2);
		} else if (!paused && this.paused) {
			this.skip = Math.max(this.skip, IN_FLIGHT + 2);
			this.outlierStreak = 0;
			this.statusStart = 0;
			this.statusFrames = 0;
			this.statusChanges = 0;
			this.statusMin = Float.MAX_VALUE;
			this.statusMax = 0f;
		}
		this.paused = paused;
	}

	/** A retired frame's command buffer GPU times (seconds; 0 when unknown). */
	public void frame(double gpuStart, double gpuEnd) {
		if (!(gpuEnd > 0) || !(gpuStart > 0) || gpuEnd < gpuStart) return;
		double busy = gpuEnd - Math.max(gpuStart, this.lastEnd);
		this.lastEnd = Math.max(this.lastEnd, gpuEnd);
		if (this.paused || busy <= 0 || busy > 0.5) return; // unfocused, overlapped entirely, or a stall (loading, a hitch): not the steady cost
		if (this.skip > 0) {
			this.skip--;
			return;
		}
		// (2.0.1 fix) reject single-frame OS/screenshot/GC spikes (>2.5x EMA and >35 ms) unless sustained for 3 frames
		if (this.samples >= 4 && busy > Math.max(this.average * 2.5, 0.035)) {
			if (++this.outlierStreak < 3) return;
		} else {
			this.outlierStreak = 0;
		}
		this.average = this.samples == 0 ? busy : this.average + (busy - this.average) / AVERAGE_FRAMES;
		this.samples++;
	}

	/** Called once per frame before it renders: the scale for this frame. */
	public float update() {
		boolean hold = hold();
		if (TaaConfig.DRS_LOG) this.status(hold);
		this.sinceChange++;
		if (this.samples < AVERAGE_FRAMES || this.sinceChange < SETTLE_FRAMES) return this.scale;
		if (hold) return this.updateHold();
		// at the floor and still over budget: the preset can't hold its target here (mcopt.shade.drsLog says so every ~5 s)
		if (this.scale <= this.min && this.average > this.targetSeconds) {
			if (++this.pinned % 600 == 0 && TaaConfig.DRS_LOG) {
				System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: render scale pinned at its floor %.3f, GPU %.2f ms/frame over the %.2f ms target",
					this.scale, this.average * 1e3, this.targetSeconds * 1e3));
			}
		} else {
			this.pinned = 0;
		}
		float next = (float) (this.scale * Math.sqrt(this.targetSeconds / this.average));
		if (next > this.scale && (this.sinceChange < SETTLE_UP_FRAMES || this.average > UP_MARGIN * this.targetSeconds)) return this.scale;
		next = TaaConfig.clamp(next, this.scale - STEP_DOWN, this.scale + STEP_UP);
		next = TaaConfig.clamp(Math.round(next / QUANTUM) * QUANTUM, this.min, this.max);
		boolean toBound = (next == this.min || next == this.max) && next != this.scale;
		if (Math.abs(next - this.scale) <= DEADBAND && !toBound) return this.scale;
		return this.change(next);
	}

	private float change(float next) {
		this.scale = next;
		this.statusChanges++;
		// frames of the old scale are still in flight: skip them, then average afresh
		this.sinceChange = 0;
		this.samples = 0;
		this.skip = IN_FLIGHT + 1;
		return this.scale;
	}

	/**
	 * The hold controller's lowest scale: on the presets that hold the 120 Hz panel (performance, balanced) its floor, or the
	 * preset's minimum when that is lower; quality and ultra keep their own (they are for sharpness at 80 / 60 fps).
	 */
	private float holdMin() {
		// (an explicit mcopt.shade.scaleMin from the player is kept as the floor: code review M3.4)
		// ((1.1) the floor read live)
		return TaaConfig.PRESET.ordinal() <= TaaConfig.Preset.BALANCED.ordinal() && !USER_MIN ? Math.min(this.min, holdFloor()) : this.min;
	}

	/** The scale at which the model puts the frame at time goal (seconds), from time t at the current scale. */
	private float modelScale(double t, double goal) {
		double r = (goal / t - HOLD_FIXED) / (1.0 - HOLD_FIXED);
		return (float) (this.scale * Math.sqrt(Math.max(r, 0.0)));
	}

	/** M3.3 hold controller (class comment): a band on the frame budget, model-based steps, hysteresis. */
	private float updateHold() {
		double budget = 1.0 / this.fps, t = this.average;
		float lo = this.holdMin(), next;
		if (t > HOLD_DOWN * budget) {
			if (this.scale <= lo) {
				if (++this.pinned % 600 == 0 && TaaConfig.DRS_LOG) {
					System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: render scale pinned at its floor %.3f, GPU %.2f ms/frame over the %.2f ms limit (hold)",
						this.scale, t * 1e3, HOLD_DOWN * budget * 1e3));
				}
				return this.scale;
			}
			next = TaaConfig.clamp(this.modelScale(t, HOLD_SET * budget), this.scale - HOLD_STEP_DOWN, this.scale);
			next = (float) Math.floor(next / QUANTUM) * QUANTUM; // round down: the frame lands under the setpoint
		} else {
			this.pinned = 0;
			if (this.sinceChange < HOLD_SETTLE_UP || this.scale >= this.max) return this.scale;
			next = TaaConfig.clamp(this.modelScale(t, HOLD_UP * budget), this.scale, this.scale + HOLD_STEP_UP);
			next = (float) Math.floor(next / QUANTUM) * QUANTUM; // round down: the model keeps the climb under the upper limit
		}
		next = TaaConfig.clamp(next, lo, this.max);
		if (Math.abs(next - this.scale) < QUANTUM * 0.5f) return this.scale;
		return this.change(next);
	}

	/**
	 * M3.3 (mcbench A/B phases): starts over at a scale, as on the first frame (timing history dropped, the frames in flight
	 * skipped).
	 */
	public void restart(float start) {
		this.scale = TaaConfig.clamp(start, hold() ? this.holdMin() : this.min, this.max);
		this.samples = 0;
		this.sinceChange = 0;
		this.skip = IN_FLIGHT + 1;
	}

	/** mcopt.shade.drsLog: about once a second, the scale (and its range since the last line), the controller's GPU average and target, the frame rate. */
	private void status(boolean hold) {
		long now = System.nanoTime();
		if (this.statusStart == 0) this.statusStart = now;
		this.statusFrames++;
		this.statusMin = Math.min(this.statusMin, this.scale);
		this.statusMax = Math.max(this.statusMax, this.scale);
		double secs = (now - this.statusStart) * 1e-9;
		if (secs < 1.0) return;
		double budget = 1.0 / this.fps;
		float lo = hold ? this.holdMin() : this.min;
		double limit = hold ? HOLD_DOWN * budget : this.targetSeconds;
		System.out.println(String.format(java.util.Locale.ROOT, "[mcopt] shade: drs status %s scale %.3f (%.3f-%.3f) gpu %.2f ms target %.2f ms, %.1f fps, %d changes%s",
			hold ? "hold" : "m32", this.scale, this.statusMin, this.statusMax, this.average * 1e3, (hold ? HOLD_SET * budget : this.targetSeconds) * 1e3,
			this.statusFrames / secs, this.statusChanges, this.scale <= lo && this.average > limit ? ", at its floor" : ""));
		this.statusStart = now;
		this.statusFrames = 0;
		this.statusChanges = 0;
		this.statusMin = Float.MAX_VALUE;
		this.statusMax = 0f;
	}

	/** Forgets the timing history (e.g. after a pause or a world change). */
	public void reset() {
		this.samples = 0;
		this.average = 0;
		this.sinceChange = 0;
	}
}
