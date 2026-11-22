# ink2godot

**Rendering pixel-art Gaussian splats in Godot 4 — with no custom engine build, no C#, and no CPU per-frame uploads.**

[中文](README.zh-CN.md) · [Onboarding](ONBOARDING.md) · [Run commands](README-RUN.md) · [Vendor patches](VENDOR-PATCHES.md)

---

## What this is

A Godot 4.7 project that renders scenes baked by [ink-studio](https://github.com/siliconjungle/shapeshift-labs-ink-studio)
— an SDF sculpting / Gaussian-splat art tool — as **pixel art**.

ink-studio only ever runs offline as an art baker. Everything you see is rendered by Godot:
no WebGL, no browser, no ink-studio runtime.

It is a **rendering pipeline proof**, not a game. Seven dioramas, one rigged character and one
VFX scene, each verified by automated pixel tests rather than by eye.

<p align="center"><i>441,648 splats across seven dioramas · 18 assets · 25.7 MB</i></p>

## Why this exists

Two real gaps, both filled here:

| Gap | What this repo does |
|---|---|
| Godot has **no native Gaussian splat renderer** | Uses [GDGS](https://github.com/ReconWorldLab/godot-gaussian-splatting) (MIT), vendored and patched |
| Off-the-shelf splat renderers produce **smooth gradients, not pixel art** | Adds a flat-disc splat pass + palette-quantisation post effect |

GDGS gives you correct splat projection and sorting. It does not give you hard-edged discs,
palette constraint, or ordered dither — so those are implemented here, in a vendored shader patch
plus one small addon (`addons/inkpixel`).

## How it works

```
ink-studio scene (JS)
      │  ../art-pipeline/inkstudio2ply.js
      ▼
Gaussian .ply  (14 or 19 float32 per splat)  +  JSON sidecar
      │  Godot import → GDGS converts to its 60-float GPU layout
      ▼
GDGS addon, Raster backend  (patched: hard-edged discs, per-splat VFX animation)
      │
      ▼
addons/inkpixel — CompositorEffect, POST_TRANSPARENT
      ├─ block average (chunky pixels, 3×3 default)
      ├─ palette constraint dither (ink-studio's own algorithm, not naive nearest-match)
      └─ optional luminance-based outline
      ▼
pixel art
```

The exporter emits a minimal binary-little-endian PLY (no list properties), so GDGS's decoder
accepts it directly. Colour is written as `f_dc` in sRGB space; the five VFX animation floats ride
in unused `f_rest_*` slots, which costs no buffer-layout change.

## Quick start

Requires **Godot 4.7.x** (portable build is fine). Windows scripts (PowerShell).

```powershell
git clone https://github.com/CyberAnomalo/ink2godot.git
cd ink2godot
./setup.ps1
```

`setup.ps1` checks your toolchain, locates Godot, rebuilds the import cache if needed, and then
**actually renders an image** as proof — from clone to first render measured at **25–55 s**.

No Godot on PATH? Point at one:

```powershell
./setup.ps1 -Godot "C:\path\to\Godot_v4.7.2-stable_win64.exe"
```

Then:

```powershell
$G = (Get-Location).Path
& godot --path $G res://main.tscn        # Die Watcher — hero diorama
& godot --path $G res://courier.tscn     # rigged character, bone-driven animation
& godot --path $G res://vfx.tscn         # procedural VFX (rain + wind)
& godot --path $G res://overview.tscn    # all seven dioramas, auto-framed
```

Capture a frame (`--headless` uses a dummy renderer and **cannot produce an image**):

```powershell
& godot --path $G res://main.tscn -- --capture     # -> artifacts/shot.png
```

You do **not** need Node or ink-studio for any of the above — the exported assets ship with the
repo. That is deliberate: it means art changes go through one person (or CI), and nobody else
needs access to a private tool to open the project.

## What is actually implemented

- **Static splats** — 7 ink-studio dioramas, author camera reproduced exactly.
- **Skeletal animation** — one PLY per bone (10 bones) + baked 12-float bone matrices per frame.
  Runs at ~0.4 ms/frame CPU with 3,920 splats.
- **Procedural VFX** — 12 per-splat animation kinds driven entirely in the vertex shader
  (rain fall, orbit, flap, ripple, wind sway, opacity fades…), zero per-frame CPU transfer.
  Verified against ink-studio's own CPU solver at **exactly zero error** over 461,535 splats.
- **Pixel-look post pass** — chunky pixels, palette constraint, ordered dither, optional outline.
- **Automated art QA** — every rendered scene is census-checked for off-palette pixels.

## Verification, not vibes

| Check | Result |
|---|---|
| Palette census across all 7 scenes | **0 off-palette pixels, 0 off-palette colours** |
| VFX shader vs ink-studio CPU solver | **0.000e+0** max error, 461,535 splats |
| Bone reconstruction self-check | **1.19e-7** |
| Fresh clone → first render | 25–55 s, unattended |

The VFX harness re-implements the GLSL line-for-line in JS and compares position, opacity and
covariance against ink-studio's authoritative solver — catching things visual inspection cannot,
such as a `mat3` column/row mix-up that rotates covariance *opposite* to position.

## Five things that will bite you

1. **Palette byte order is reversed between the two encodings.** `world.pal` is `0xRRGGBB`
   (red high); the per-splat colour lane is `r | g<<8 | b<<16` (red low). Getting this wrong
   shifts the whole image warm and adds a fake outline — and it looks plausible enough to send
   you hunting for an art bug.
2. **Place the node at the centroid.** `Transform3D(Basis.IDENTITY, centroid)` both restores
   world coordinates (GDGS subtracts the mean on import) and cancels GDGS's default 180° Z flip.
3. **ink-studio's default FOV is 38°**, stored in radians — not 45°.
4. **The post pass must be `POST_TRANSPARENT`.** Splats draw in the transparent blend pass, so a
   fullscreen quad with `hint_screen_texture` never sees them.
5. **Flat discs and disc radius are inversely coupled.** `flat_alpha = true` needs a *lower*
   `alpha_cutoff` (bigger disc) or surfaces develop gaps — the opposite of the intuitive direction.

## Layout

| Path | Contents |
|---|---|
| `project.godot` | Forward+, Godot 4.7, Raster backend, `flat_alpha`, `alpha_cutoff` |
| `main.*`, `courier.*`, `vfx.*`, `overview.*` | The four scenes |
| `addons/gdgs/` | GDGS **with local patches** — see `VENDOR-PATCHES.md` before upgrading |
| `addons/inkpixel/` | The pixel-look compositor effect (compute shader + GDScript) |
| `assets/` | Exported splat assets, committed so the project is self-contained |
| `setup.ps1` | Bootstrap: toolchain → Godot → import → render proof |

## Limitations

- **Windows-only scripts.** The Godot project itself is portable; `setup.ps1` and the capture
  scripts assume PowerShell. Linux/macOS would need small shell equivalents.
- **Raster backend only, in practice.** The pixel pass has not been validated on the Compute
  backend; the Compute backend also requires desktop Forward+. Raster's 1–2 frame sort lag is
  acceptable for weather but would show on fast camera work.
- **Outline is luminance-based, not depth-based.** Splats use `depth_draw_never`, so there is no
  depth buffer to derive silhouettes from at post-processing time.
- **6 of 12 VFX kinds are exercised by shipped scenes.** The rest are implemented and pass the
  numeric harness but have no authored scene.
- **Deeper docs are in Chinese** (`SPEC-inkstudio-to-godot-ply.md` in the exporter repo,
  `ONBOARDING.md`, `VENDOR-PATCHES.md`). The English READMEs cover the parts a newcomer needs.

## Related

- [art-pipeline](https://github.com/CyberAnomalo/art-pipeline) — the exporter that produces these assets.
- [ink-studio](https://github.com/siliconjungle/shapeshift-labs-ink-studio) — the art baker (MIT).
- [GDGS](https://github.com/ReconWorldLab/godot-gaussian-splatting) — Gaussian splatting for Godot (MIT).

## License

The project code is released under the MIT License. Vendored dependencies keep their own licenses:
GDGS (MIT) and ink-studio (MIT, © 2026 siliconjungle).
