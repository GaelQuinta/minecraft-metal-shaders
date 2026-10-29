# Tone regression

After `:metal:build`, run `JAVA_HOME=/path/to/jdk25 GRADLE_USER_HOME=/path/to/cache python3 tools/shade/tonecheck/run.py /tmp/tonecheck /path/to/upstream.jar` with GPU access. Compares 18 actual SDR/HDR tone cases across all looks, checks monotonic shadows, finite highlights, reduced dark texture contrast and a stable mid-gray anchor. No game is launched.
