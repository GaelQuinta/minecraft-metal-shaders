# Cave lighting

Build `:metal:build` with JDK 25, then run `python3 tools/shade/cavecheck/run.py /tmp/cave-check` with `JAVA_HOME` set. This executes production lighting, the irradiance-volume writer and the low-light colour transform on Metal. It checks neutral cave visibility, gentle surface-normal response, torch falloff, localised warmth and coloured-light preservation.

`CAVE_BASELINE=<fixture directory>` additionally compares outdoor day/night/storm grading and explicit torch Kelvin against recorded measurements. `CAVE_STONE=<stone.png>` writes `tunnel.png` using the real irradiance volume and display curve; this is a synthetic tunnel, without gameplay or bloom.
