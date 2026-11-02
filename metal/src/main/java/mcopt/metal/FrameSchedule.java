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

package mcopt.metal;

import java.lang.foreign.Arena;

/** Experimental input-relative presentation deadline, adaptive pacing, and high-precision telemetry. Startup-only, disabled by default. */
public final class FrameSchedule {
	private static final double MILLIS = Double.parseDouble(System.getProperty("mcopt.metal.presentScheduleMs", "0"));
	private static final boolean TELEMETRY = Boolean.getBoolean("mcopt.metal.telemetry");
	private static final boolean ADAPTIVE_PACING = Boolean.getBoolean("mcopt.metal.adaptivePacing");
	private static final double ADAPTIVE_SAFETY_MARGIN_MS = Double.parseDouble(System.getProperty("mcopt.metal.adaptiveSafetyMarginMs", "1.5"));
	private static final int ADAPTIVE_WINDOW_SIZE = Integer.getInteger("mcopt.metal.adaptiveWindowSize", 8);
	private static boolean active;

	private FrameSchedule() {}

	static void initialize(boolean acquire) {
		if (TELEMETRY) {
			Native.telemetryEnable(1);
			System.out.println("[mcopt] metal: high-precision in-memory telemetry enabled");
			String telPath = System.getProperty("mcopt.metal.telemetryOutput");
			if (telPath != null) {
				Runtime.getRuntime().addShutdownHook(new Thread(() -> dumpTelemetry(telPath)));
			}
		}
		if (ADAPTIVE_PACING) {
			Native.adaptivePacingConfig(true, ADAPTIVE_SAFETY_MARGIN_MS, ADAPTIVE_WINDOW_SIZE);
			System.out.println("[mcopt] metal: GPU-readiness adaptive pacing enabled (margin=" + ADAPTIVE_SAFETY_MARGIN_MS + " ms, window=" + ADAPTIVE_WINDOW_SIZE + ")");
		}
		boolean scheduleValid = acquire && Double.isFinite(MILLIS) && MILLIS > 0 && MILLIS <= 50;
		Native.presentSchedule(scheduleValid ? MILLIS / 1000 : 0);
		if (scheduleValid) System.out.println("[mcopt] metal: experimental input-relative presentation deadline " + MILLIS + " ms");
		active = scheduleValid || TELEMETRY || ADAPTIVE_PACING;
	}

	public static void afterPoll() {
		if (active) Native.presentFrameStart();
	}

	public static void dumpTelemetry(String path) {
		if (Native.telemetryIsEnabled() && path != null) {
			try (Arena arena = Arena.ofConfined()) {
				var cStr = arena.allocateFrom(path);
				Native.telemetryDumpJson(cStr.address());
				System.out.println("[mcopt] metal: telemetry written to " + path);
			} catch (Throwable t) {
				System.err.println("[mcopt] metal: failed to dump telemetry: " + t.getMessage());
			}
		}
	}
}
