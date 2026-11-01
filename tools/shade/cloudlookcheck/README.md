# Cloud uniform byte order

With JDK 25 and `:metal:build` complete, run `python3 tools/shade/cloudlookcheck/run.py /tmp/cloud-look-check` (set `JAVA_HOME` and optionally `GRADLE_USER_HOME`).

This reproduces `ShadeBindings.currentLook()` returning a default-big-endian ByteBuffer slice, packs the real cloud uniforms, and executes the exact mode-store statement extracted from `ShadeClouds.update`. It checks both classic and stable history modes as little-endian shader values. The original cutoff update wrote `1`/`3` as big-endian bytes; the shader read near zero and skipped every cloud composite. Offscreen march previews alone do not cover this Java write.
