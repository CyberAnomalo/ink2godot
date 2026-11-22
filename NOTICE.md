# Third-party notices

This project is MIT licensed (see LICENSE). It bundles or derives from the following
MIT-licensed works.

## addons/gdgs — godot-gaussian-splatting

Copyright (c) ReconWorldLab
https://github.com/ReconWorldLab/godot-gaussian-splatting

Vendored, not used as a submodule, because this project modifies it: the raster shader gains
per-splat procedural animation and hard-edged flat discs, and the raster backend gains shader
uniform wiring. See `VENDOR-PATCHES.md` for the exact changes and the upgrade procedure.

## assets/ — Gaussian splat assets

Copyright (c) 2026 siliconjungle
https://github.com/siliconjungle/shapeshift-labs-ink-studio

The `.ply` files under `assets/` are baked output of ink-studio scenes using the exporter in
[art-pipeline](https://github.com/CyberAnomalo/art-pipeline). No ink-studio source code is
included in this repository.

## addons/inkpixel

Original work of this project. The palette-constraint dithering algorithm is a port of the one in
ink-studio's `src/webgl/shaders.mjs` (`constraintPalette`), reproduced for parity — see the
`SPEC-inkstudio-to-godot-ply.md` section on the pixel look for the algorithm and the reason it is
not naive nearest-match dithering.
