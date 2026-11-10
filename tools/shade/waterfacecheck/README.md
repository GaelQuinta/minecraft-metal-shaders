# Water side classification

Run `python3 tools/shade/waterfacecheck/run.py /tmp/water-face-check` on macOS with Metal. This offscreen GPU check executes the production waterfall predicate for source/falling side and top faces. The former predicate fails because it treats a source block’s vertical face as a waterfall whenever moving water is nearby.

The mesher now carries the actual falling-fluid state in water’s unused vertex alpha (254); water still composites at alpha one. Tops and ordinary source sides keep their existing shading. Requires a world reload to rebuild existing chunk meshes.
