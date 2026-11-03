# Allow clear skies with smoothly changing cloud fronts

After `:metal:build`, run `JAVA_HOME=/path/to/jdk25 GRADLE_USER_HOME=/path/to/cache python3 tools/shade/cloudweathercheck/run.py /tmp/cloudweathercheck` on a Mac with GPU access. Produces four offscreen production cloud previews. Also samples 16 weather seeds and verifies a forced clear sky has no scattered light or cloud shadows. No game is launched.
