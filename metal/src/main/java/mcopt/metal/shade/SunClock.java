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
package mcopt.metal.shade;

/**
 * (1.2.7, issue #19) The sun's and the moon's angle as the shading uses them: the game's angle, never stepping back. The client
 * ticks its own clock and the sky lerps it per frame, but about once a second the server's time packet resets that clock to the
 * server's, a tick or so behind or ahead (a remote server: more, and irregular). With a low sun a one-tick step moves the tip of a
 * canopy's shadow (and the god-ray shafts through it) by half a block, so the shade "ticked" back and forth once a second.
 * Here the angle advances at the rate the game's angle has been moving and is pulled onto it over PULL_S; while the sun moves it
 * never goes back (a small correction behind it is waited out), once the game's time stands still it settles onto the game's
 * value; a real jump (/time set, sleeping, joining, a new dimension) is taken at once. ShadeFrameUpdater (sky, sun and moon
 * directions) and ShadowPass (the light the maps are drawn from) both call it every frame with the same raw angle, so they
 * agree; a second call in a frame moves it by that call's few microseconds. mcopt.shade.sunClock=false (live): the game's angle.
 * Idea and first version: derrekharrisstudios' SunClock in the ray tracing starter attached to issue #22 (Apache-2.0); this one
 * also lets the angle settle back when the game's time stops (frozen daylight cycle, a paused game).
 */
public final class SunClock {
	private SunClock() {
	}

	private static final double JUMP = Math.toRadians(3.0); // farther than this apart: a real jump, taken at once
	private static final double PULL_S = 1.0;               // seconds: how fast a gap to the game's angle closes
	private static final double STILL_S = 0.3;              // the game's angle unchanged this long: its time stands still
	private static final double TWO_PI = 2 * Math.PI;

	private static final double[] angle = {Double.NaN, Double.NaN}, rate = new double[2], lastRaw = new double[2];
	private static final long[] lastNs = new long[2], lastRawNs = new long[2];
	// mcopt.shade.sunClock.log: the game's own steps back (a server correction) over the last 10 s
	private static int backSteps;
	private static double backMax;
	private static long logNs;

	/** The angle (radians) the shading uses for the game's raw angle; which: 0 sun, 1 moon. */
	public static synchronized double angle(double raw, int which) {
		long now = System.nanoTime();
		if (!Live.b("mcopt.shade.sunClock", true) || !Double.isFinite(raw)) {
			angle[which] = Double.NaN;
			return raw;
		}
		double s = angle[which];
		if (Double.isNaN(s)) {
			angle[which] = lastRaw[which] = raw;
			lastNs[which] = lastRawNs[which] = now;
			rate[which] = 0;
			return raw;
		}
		if (raw != lastRaw[which]) {
			double ch = Math.IEEEremainder(raw - lastRaw[which], TWO_PI), interval = (now - lastRawNs[which]) * 1e-9;
			if (ch >= 0 && ch < JUMP && interval > 1e-4 && interval < 1.0) rate[which] += (ch / interval - rate[which]) * 0.1;
			else if (ch < 0 && ch > -JUMP && which == 0) {
				backSteps++;
				backMax = Math.max(backMax, -ch);
			}
			lastRaw[which] = raw;
			lastRawNs[which] = now;
		} else if ((now - lastRawNs[which]) * 1e-9 > STILL_S) {
			rate[which] = 0;
		}
		double dt = Math.min((now - lastNs[which]) * 1e-9, 0.25);
		lastNs[which] = now;
		double gap = Math.IEEEremainder(raw - s, TWO_PI);
		if (Math.abs(gap) > JUMP) {
			s = raw;
		} else {
			double step = rate[which] * dt + gap * (1 - Math.exp(-dt / PULL_S));
			if (step > 0 || rate[which] == 0) s += step;
			s = raw + Math.IEEEremainder(s - raw, TWO_PI);
		}
		angle[which] = s;
		if (which == 0 && Live.b("mcopt.shade.sunClock.log", false) && now - logNs > 10_000_000_000L) {
			// one tick of the day clock is 2 pi / 24000 of the angle at noon; near the horizon the sun moves up to ~1.4x that
			System.out.println(String.format("[mcopt] shade: sun clock: %d steps back in 10 s, largest %.2f ticks; rate %.3f deg/s, gap %.4f deg",
				backSteps, backMax / (TWO_PI / 24000), Math.toDegrees(rate[0]), Math.toDegrees(gap)));
			backSteps = 0;
			backMax = 0;
			logNs = now;
		}
		return s;
	}
}
