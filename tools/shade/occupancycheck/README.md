# Occupancy regression

Run `JAVA_HOME=/path/to/jdk25 python3 tools/shade/occupancycheck/run_cpu.py /tmp/occupancycheck` after checkout. Exercises production Occupancy.java against an in-memory world API and compares bits, generations and ray hits to upstream 846d7e8. Covers updates, unloaded chunks, world changes, camera movement and periodic recovery. An optional second argument selects a baseline Java source file. Timings and allocations are fixture measurements, not in-game performance claims.
