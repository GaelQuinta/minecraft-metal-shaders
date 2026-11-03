# Rain regression

After `:metal:build`, run `JAVA_HOME=/path/to/jdk25 GRADLE_USER_HOME=/path/to/cache python3 tools/shade/raincheck/run.py /tmp/raincheck /path/to/upstream.jar` with GPU access. Runs actual old/new rain code in 28 cases covering full/budget paths, light/heavy/night rain, lightning, snow, media and dimensions, then compiles the actual ShadeMsl.weather patch. No game is launched.
