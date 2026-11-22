# ink2godot

[English](README.md) · [新人引导](ONBOARDING.md) · [运行命令](README-RUN.md) · [GDGS 补丁](VENDOR-PATCHES.md)

Godot 4 工程，用来渲染 ink-studio 烘焙出来的像素风高斯 splat。

资产由兄弟仓库 [art-pipeline](https://github.com/CyberAnomalo/art-pipeline) 产出：
**ink-studio 只做离线美术烘焙，游戏本身完全由 Godot 渲染**，不用它的 WebGL 渲染器。

> **新人先读 [`ONBOARDING.md`](ONBOARDING.md)**，然后 `./setup.ps1` —— 实测 25—55 秒从零到出图。

## 管线

```
ink-studio 场景 (JS)
      │  ../art-pipeline/inkstudio2ply{,-boned}.js
      ▼
Gaussian .ply (14 或 19 个 float32/顶点)  +  sidecar .json
      │  Godot 导入 → GDGS 转成 60 浮点/240 字节 GPU 布局
      ▼
GDGS addon（Raster 后端，已打补丁，见 VENDOR-PATCHES.md）
      │  平色硬边盘，去掉高斯衰减
      ▼
addons/inkpixel  像素风后处理（块化 → 调色板量化 → 投影抖动 → 可选描边）
      ▼
像素画
```

## 跑起来

```powershell
$GODOT = "D:/GithubSoftware/GameDev/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64.exe"
$G = "D:/GithubSoftware/GameDev/ink2godot"

& $GODOT --path $G res://main.tscn        # Die Watcher 主场景
& $GODOT --path $G res://courier.tscn     # 骨骼动画角色
& $GODOT --path $G res://vfx.tscn         # 程序化 VFX（雨 + 风）
& $GODOT --path $G res://overview.tscn    # 七个 diorama 总览
```

抓图（`--headless` 用的是 dummy 渲染器，出不了图，必须窗口模式）：

```powershell
& $GODOT --path $G --rendering-driver vulkan --resolution 1280x720 res://main.tscn -- --capture
```

详细命令见 `README-RUN.md`。

## 目录

| 路径 | 内容 |
|---|---|
| `project.godot` | Forward+ / 4.7 / Raster 后端 / `flat_alpha` / `alpha_cutoff` |
| `main.*` | 主场景：WorldEnvironment + Compositor + GaussianSplatNode |
| `courier.*` | 骨骼动画：10 个逐骨骼节点 + 每帧 12 浮点骨骼矩阵 |
| `vfx.*` | 程序化 VFX：纯 shader 驱动，零 CPU 每帧传输 |
| `overview.*` | 七个 diorama 逐个加载、按作者相机构图、抓图 |
| `addons/gdgs/` | GDGS 的**已打补丁副本** —— 改动见 `VENDOR-PATCHES.md` |
| `addons/inkpixel/` | 像素风后处理（compute shader + CompositorEffect） |
| `assets/` | 导出的 splat 资产，入库保证工程自包含 |

## 验证

| 测试 | 判据 |
|---|---|
| 七场景总览 + 调色板断言 | `../art-pipeline/overview-sheet.ps1`：**零个调色板外像素** |
| VFX 数学等价 | `node ../art-pipeline/test-vfx-math.js`：误差 `0.000e+0` |
| 帧间运动 | `vfx.tscn --capture` 会打印时间相隔帧的平均像素差（应 > 1/255） |

## 必须知道的几件事

1. **调色板字节序**：`world.pal` 是 `0xRRGGBB`（红在高位），而逐 splat 的 packedRGB lane
   是 `r | g<<8 | b<<16`（红在低位）—— **两者相反**。搞反会让冷色变暖并在轮廓上叠一圈假描边。
2. **节点必须摆到质心**：`Transform3D(Basis.IDENTITY, centroid)` 同时恢复世界坐标并抵消
   GDGS 默认的 180° Z 翻转。
3. **默认 fov 是 38°**，不是 45°。
4. **后处理必须挂 `POST_TRANSPARENT`**：Raster splat 在透明阶段绘制，
   全屏 QuadMesh + `hint_screen_texture` 拿不到它。
5. **平色盘要把 `alpha_cutoff` 调低**（盘变大），否则表面露缝。

## 版本

见 `VENDOR-PATCHES.md`（GDGS 上游 commit 与本地改动）和 `../art-pipeline/VERSIONS.md`
（ink-studio 固定 commit、工具链版本、关键契约锚点）。

## 许可

- GDGS（godot-gaussian-splatting）：MIT
- ink-studio：MIT（Copyright (c) 2026 siliconjungle）
