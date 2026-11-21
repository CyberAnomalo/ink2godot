# ink2godot — ink-studio 资产在 Godot 里渲染

## 一句话

```
D:/GithubSoftware/GameDev/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64.exe --path D:/GithubSoftware/GameDev/ink2godot
```

带自动截图（渲染 30 帧后存 `shot.png` 并退出）：

```
.../Godot_v4.7.2-stable_mono_win64.exe --path D:/GithubSoftware/GameDev/ink2godot -- --capture
```

## 当前状态

- 资产：`assets/dioramas/watcher.ply`（ink-studio 的 "Die Watcher"，112,600 splat，6.01 MB）
- 渲染：GDGS 3.3.0 **Compute 后端**（Forward+ / Vulkan / RTX 4080）
- 已验证：导入 + 渲染 1280×720 成功

## 换资产

```powershell
cd D:/GithubSoftware/GameDev/art-pipeline
node inkstudio2ply.js --list                      # 7 个内置 demo
node inkstudio2ply.js --scene 2 --out out/idol.ply
Copy-Item out/idol.ply,out/idol.ply.json D:/GithubSoftware/GameDev/ink2godot/assets/
```

然后改 `main.tscn` 的两处 `watcher` → `idol`（`1_gauss` 的 path 和 `main.gd` 里的 `SIDECAR` 常量）。

## 结构

```
ink2godot/
  project.godot        Forward Plus, 4.7, 启用 addons/gdgs
  main.tscn            WorldEnvironment + Compositor(CompositorEffect) + Splat + Camera3D
  main.gd              放置节点到 centroid、按 ink-studio 的 world.cam 取景、可选截图
  assets/dioramas/watcher.ply       ink-studio 烘的 splat（七个 diorama 之一）
  assets/dioramas/watcher.ply.json  sidecar（centroid / aabb / 调色板 / 相机）
  addons/gdgs/         GDGS 3.3.0
```

## 已知坑

1. `.tscn` 里的 splat 节点必须写 `type="VisualInstance3D"` + `script = ExtResource(...)`，
   **不能**写 `type="GaussianSplatNode"`（报 `Cannot get class`）。
2. 新建项目第一次 `--headless --import` 会报一次类不存在的错，跑第二遍就正常。
3. GDGS 导入时会把位置减去均值，所以节点必须放在 sidecar 的 `centroid` 上。
4. 导入时若节点 basis 是单位阵，插件会补一个 -180° 绕 Z 的旋转；`main.gd` 在父 `_ready` 里
   重设 transform 把它覆盖掉。

## 还没做的

像素风后处理（palette resolve + ordered dither + outline）。现在出来的是平滑渐变的
3DGS 混合，不是 ink-studio 的硬边像素块。

---

# 骨骼动画（courier.tscn）

```powershell
# 播放
.../Godot_v4.7.2-stable_mono_win64.exe --path D:/GithubSoftware/GameDev/ink2godot res://courier.tscn

# 截三帧（t = 0 / 0.8 / 1.6）
.../Godot_v4.7.2-stable_mono_win64.exe --path . --resolution 1000x700 res://courier.tscn -- --capture

# 只放 bind pose（诊断用）
.../Godot_v4.7.2-stable_mono_win64.exe --path . --resolution 1000x700 res://courier.tscn -- --capture --bind

# 测帧时间
.../Godot_v4.7.2-stable_mono_win64.exe --path . --resolution 1000x700 res://courier.tscn -- --bench
```

## 重新导出角色

```powershell
cd D:/GithubSoftware/GameDev/art-pipeline
node inkstudio2ply-boned.js --example pose-blocking.js --out out/courier --fps 24 --seconds 2
Copy-Item out/courier/* D:/GithubSoftware/GameDev/ink2godot/assets/courier/ -Force
```

产出：`bone_00.ply` … `bone_09.ply` + `anim.json`（每帧每骨 12 个 float）。
218 KB 总共。导出时会自检“bind 位置 + 骨骼矩阵”能否重建 `K.bones.posed()`，误差必须 < 1e-5。

## 结构

```
courier.tscn           WorldEnvironment + Compositor + Camera3D
courier.gd             运行时创建 10 个 GaussianSplatNode，每帧套骨骼矩阵
assets/courier/        10 个 PLY + anim.json
```

## ⚠ 关键坑：Basis 是列不是行

ink-studio 的骨骼矩阵是 **3x3 行主序**，但 Godot 的 `Basis(a,b,c)` 填的是**列**。
直接按顺序传等于用了转置矩阵 → 带枢轴旋转的部位反向旋转 → 手臂飞出身体。
`courier.gd` 里已按列重组，别改回去。

---

# VFX（逐 splat 程序化动画）

rain / wind / 浮动 / 自转这类逐 splat 动画，**零每帧 CPU 传输**，全部在顶点着色器里跑。
原理：ink-studio 颜色是平的，PLY 的 45 个空 SH 槽里拿 5 个装动画参数，
改过的 GDGS Raster 着色器用 `TIME` 重算。

## 必须切到 Raster 后端

VFX 只移植到了 Raster。`project.godot` 里：

```ini
[gdgs]

rendering/backend="Raster"
```

（Forward+ 的 `Auto` 会选 Compute，那样 VFX 不生效。）

## 导出带 VFX 的资产

```powershell
cd D:/GithubSoftware/GameDev/art-pipeline

# 纯场景/纯 VFX（无骨骼）
node inkstudio2ply-boned.js --example motion-cadence.js --out out/mcad --fps 24 --seconds 1

# 静态单文件（也可）
node inkstudio2ply.js --example motion-cadence.js --out ../ink2godot/assets/vfx/motion-cadence.ply --vfx

# 带骨骼的角色（非骨骼 bucket 自动带 VFX）
node inkstudio2ply-boned.js --example pose-blocking.js --out out/courier --fps 24 --seconds 2
```

## 跑起来

```powershell
$G = "D:/GithubSoftware/GameDev/ink2godot"
$GODOT = ".../Godot_v4.7.2-stable_mono_win64.exe"

# 播放（雨/风自己动）
& $GODOT --path $G res://vfx.tscn

# 抓三帧并打印帧间像素差
& $GODOT --path $G --resolution 1000x700 res://vfx.tscn -- --capture

# 指定别的资产
& $GODOT --path $G --resolution 1000x700 res://vfx.tscn -- --capture
```

## 验证

```powershell
cd D:/GithubSoftware/GameDev/art-pipeline
node test-vfx-math.js motion-cadence.js   # 必须三项均 0
node test-vfx-math.js windbreak.js
node test-vfx-math.js lantern-squall.js
```

这个测试把 GLSL 逐行镜像成 JS，对 400 多组 (splat × 时间 × kind) 和 ink-studio 的
`SplatFrames` 比位置/不透明度/协方差。改了着色器就跑一遍。

## 移植时踩过的三个坑

1. JS 解构 `[x,z]=[..x..,..x..]` 两边都用旧 x，GLSL 必须存临时量
   （**但 kind 11 的 p.y 故意用改写后的 p.x**）。
2. kind 15 **不**缩放协方差（只有 kind 2/3 缩放）。
3. `mat3(a,b,c)` 填列。kind 5 的旋转矩阵要转置着传，否则协方差反向转。

---

# 像素风后处理

把 GDGS 渲染出来的平滑渐变变成 ink-studio 的像素画：块化 + 调色板量化 + 抖动。

实现在 `addons/inkpixel/`：

| 文件 | 作用 |
|---|---|
| `shaders/pixel_look.glsl` | compute shader，三步：块平均 → 量化+投影抖动 → 可选描边 |
| `pixel_look_effect.gd` | `CompositorEffect`，挂在 `POST_TRANSPARENT` |
| `ink_pixel.gd` | 挂载助手，从 sidecar 读调色板 |

挂载点必须是 `POST_TRANSPARENT` 的 CompositorEffect —— Raster splat 是透明物体，
全屏 QuadMesh + `hint_screen_texture` 那个常见写法拿不到 splat。

## 跑起来

```powershell
$G = "D:/GithubSoftware/GameDev/ink2godot"
$GODOT = ".../Godot_v4.7.2-stable_mono_win64.exe"

# watcher 主场景，默认开像素后处理（调色板和抖动从 sidecar 读）
& $GODOT --path $G res://main.tscn

# 抓图
& $GODOT --path $G --resolution 1280x720 res://main.tscn -- --capture

# 关掉后处理做对比
& $GODOT --path $G --resolution 1280x720 res://main.tscn -- --capture --no-pixel

# 调参
& $GODOT --path $G res://main.tscn -- --px=3 --dither=0.4 --edge=0.6 --edge-thresh=0.14
```

参数：`--px=N` 像素块边长（默认 3；1=全分辨率，只有量化没有像素感）、
`--dither=` 抖动强度、`--edge=` 描边强度（默认 0=关）、`--edge-thresh=`、`--edge-darken=`。

## 两个必须知道的点

### ⚠ 调色板字节序和 splat lane 相反

`world.pal`（sidecar 的 `ink.palette`）= `0xRRGGBB`，**红在高位**；
逐 splat 的 packedRGB lane = `r | g<<8 | b<<16`，**红在低位**。

搞反的后果：冷色变暖（蓝灰→棕），并在轮廓上叠一圈不存在的暗色描边。
实测 112,465 个 lane 值全部对得上字节交换后的调色板项，不是猜的。
`pixel_look_effect.gd` 的 `set_palette_from_packed()` 里已经按 0xRRGGBB 解，别改回去。

### splat 要压成硬边实心盘

ink-studio 的 splat 是不透明圆盘，没有高斯衰减；GDGS 默认是平滑高斯，源图是连续渐变。
两个旋钮要一起调，而且方向反直觉：**开了 flat_alpha 反而要把 alpha_cutoff 调低（盘变大）**，
因为实心盘是画家算法，盘不够大就露缝。

```ini
[gdgs]
rendering/backend="Raster"
rendering/raster/flat_alpha=true
rendering/raster/alpha_cutoff=0.1     # ≈2.13σ 盘半径，实测无露缝
```

这两个 setting 是给 vendored 的 `raster_render_backend.gd` 加的 —— 原来 `alpha_cutoff`
只是个孤立的 shader uniform，没有 GDScript setter，永远停在默认值，改 project setting 无效。
注意生效时机是 GaussianSplatNode 创建时，所以不能用 `--cutoff=` 在父节点 `_ready` 里改
（子节点 `_ready` 早于父节点）。

### 背景不能被量化

清屏色不属于 splat 调色板。若也走量化会被抖到两个相邻调色板色之间，变成一片噪点。
做法是直接从颜色缓冲的**角落像素**取清屏色，等值像素原样返回 —— 不传 `ink.bg`，
也不做任何颜色空间转换，没有猜错的可能。

## 验证

`--capture` 出的图应该只有调色板里的几十种颜色，**没有一个是调色板外的**（背景清屏色除外）。
用 PowerShell + System.Drawing 统计全图像素即可断言之。

已知未做：真正的几何轮廓描边（GDGS raster 用 `depth_draw_never`，深度缓冲里没有 splat）；
计算后端的像素后处理未验证；调色板/抖动是全局一套，ink-studio 可按区域作用。

---

# 七个 diorama 总览

内置七个场景已全量导出到 `assets/dioramas/`（441,648 splats, 23.6 MB）。

```powershell
# 逐个渲染 + 抓图（按每个场景的作者相机构图）
& $GODOT --path $G --rendering-driver vulkan --resolution 640x360 res://overview.tscn -- --capture

# 只抓一个
& $GODOT --path $G res://overview.tscn -- --capture --only=cabinet

# 交互，第一个场景
& $GODOT --path $G res://overview.tscn

# 拼总览表 + 调色板断言
& D:/GithubSoftware/GameDev/art-pipeline/overview-sheet.ps1
```

产物：`overview_<id>.png`（七张）+ `overview_sheet.png`（4x2 总览表）。

## 相机：fov 是 38° 不是 45°

ink-studio 的默认垂直 fov 是 **38°**（`src/camera-lens.js:3`），且 `cam.fov` 存的是**弧度**。
用 45° 比作者视角更广，主体会显得偏小。sidecar 的 `ink.cam` 现在带
target / dist / pitch / yaw，优先用它构图 —— 不要拿 AABB 硬框，
watcher 的 AABB 里有 Y = -99 的背景哨兵。

## 各场景数据

| id | splat | 调色板 | worst aspect |
|---|---|---|---|
| watcher | 112,600 | 18 | 1.000 |
| burn | 46,902 | 24 | 1.000 |
| idol | 77,917 | 12 | 1.000 |
| bench | 78,942 | 19 | 1.000 |
| stuff | 33,820 | 25 | 1.000 |
| cabinet | 75,862 | 42 | 1.000 |
| rehearsal | 15,605 | 16 | **1.533** |

rehearsal 是唯一有各向异性 splat 的场景（也是唯一 alpha 全 0.999 的），
1.533 属于轻微各向异性，渲染正常。

