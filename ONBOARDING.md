# 新人上手

两条路线，按你要做什么选。**绝大多数人只需要路线 A。**

| | 路线 A：看画面 / 做游戏 | 路线 B：重新烘焙美术 |
|---|---|---|
| 你将得到 | 能跑的全部四个场景 | 能从 ink-studio 场景导出新资产 |
| 需要 | git + Godot | 再加 Node 18+ + **私有仓库读权限** |
| 耗时 | **约 1 分钟** | 约 5 分钟 |
| 仓库 | `ink2godot` | 再加 `art-pipeline`、`ink-studio` |

---

## 路线 A：跑起来（1 分钟）

```powershell
git clone <ink2godot 仓库地址> ink2godot
cd ink2godot
./setup.ps1
```

脚本会依次检查 git、定位 Godot、校验资产、必要时重建导入缓存（约 52 秒 / 222 MB），
最后**真渲染一张图**确认显卡链路通。实测从零到出图 **53.8 秒**。

Godot 不装也行，用 portable 版：

```powershell
# 下 4.7.x portable 版解压到 ink2godot 的上级目录，setup.ps1 会自动找到
# 或者显式指定
./setup.ps1 -Godot "C:\path\to\Godot_v4.7.2-stable_win64.exe"
```

跑完会打印四个场景的命令。手抄一遍：

```powershell
$G = (Get-Location).Path
& godot --path $G res://main.tscn        # Die Watcher 主场景
& godot --path $G res://courier.tscn     # 骨骼动画角色
& godot --path $G res://vfx.tscn         # 程序化 VFX（雨 + 风）
& godot --path $G res://overview.tscn    # 七个 diorama 总览
```

**到此为止你不需要 Node，也不需要 ink-studio。** 仓库里带着 25.7 MB 已导出资产（18 个 `.ply`），
工程自包含 —— 这是刻意的设计，为了让人不用碰私有仓库就能上手。

### 抓图

```powershell
& godot --path $G res://main.tscn -- --capture     # -> artifacts/shot.png
```

`--headless` 用的是 dummy 渲染器，**出不了图**，必须开窗口。

### 确认环境没问题

```powershell
& godot --path $G res://overview.tscn -- --capture
cd ../art-pipeline && ./overview-sheet.ps1
```

最后会打印一张表，**七个场景 `offPalette` 和 `offPixels` 必须都是 0**。不是 0 说明调色板解码或
后处理挂了，见下面「踩过的坑」。

---

## 路线 B：重新烘焙美术（加 5 分钟）

只有要**改 ink-studio 里的场景**或**导出新资产**时才需要。核心门槛不是技术，是**权限**。

```powershell
# 1. 向项目负责人要 ink-studio 的读权限（私有仓库）
git clone <ink-studio 私有地址> ../shapeshift-labs-ink-studio
git -C ../shapeshift-labs-ink-studio checkout 1350b4f    # commit 见 art-pipeline/VERSIONS.md

# 2. 导出器仓库，放在同级
git clone <art-pipeline 仓库地址> ../art-pipeline

# 3. 验证
cd ../ink2godot && ./setup.ps1 -WithBaker
```

目录必须是这样（导出器靠兄弟目录找 ink-studio）：

```
随便哪个父目录/
  ink2godot/
  art-pipeline/
  shapeshift-labs-ink-studio/     <- 私有，按 commit 固定
```

放在别处也行，设环境变量：

```powershell
$env:INK_STUDIO_DIR = "D:/somewhere/ink-studio"
```

### ink-studio 需要编译吗？

**不需要。** 它没有构建步骤：`index.js` 的 `nodeBundlePath()` 会把 `src/` 里的源码就地拼成
`dist/standalone.js`（纯 Node，无 webpack/tsc）。克隆下来直接能用。

Node 版本要 **18+**（本项目在 Node 24 上验证）。

### 烘焙一条命令

```powershell
cd ../art-pipeline

# 内置七个 diorama 之一
node inkstudio2ply.js --scene watcher --out ../ink2godot/assets/dioramas/watcher.ply --stats

# 任意示例，带程序化 VFX
node inkstudio2ply.js --example motion-cadence.js --out ../ink2godot/assets/vfx/motion-cadence.ply --vfx --stats

# 骨骼动画角色（逐骨骼 PLY + anim.json）
node inkstudio2ply-boned.js --example pose-blocking.js --out ../ink2godot/assets/courier --fps 24 --seconds 2
```

改完资产后**必须**跑一遍验收，不要只靠眼睛：

```powershell
node test-vfx-math.js            # VFX 数学等价，误差必须 0.000e+0
./verify-all.ps1                 # 六个场景一起验，约 46 万 splat
```

---

## 仓库里没有什么，为什么

| 没入库 | 原因 | 你怎么办 |
|---|---|---|
| Godot 引擎（257 MB） | 二进制，且版本要自己对 | 下 portable 版，或 `-Godot` 指定 |
| `.godot/`（222 MB） | 导入缓存，能重建 | `setup.ps1` 自动重建，52 秒 |
| `art-pipeline/out/`（34 MB） | 导出中间产物，和 `assets/` 重复 | 重新导出即得 |
| ink-studio 源码 | **私有仓库** | 申请权限；不申请也能看图 |
| GDGS 上游仓库 | 第三方克隆 | 工程里 `addons/gdgs/` 是**已打补丁**的副本，直接用 |

`addons/gdgs/` 不是原始 GDGS —— 我们改了它的 shader 和渲染后端接线。改动清单在
`VENDOR-PATCHES.md`，**升级 GDGS 前必读**，否则平色盘和 VFX 动画会静默失效。

---

## 踩过的坑（都是实测踩出来的）

### 1. Godot 版本必须 4.7

`project.godot` 里写着 `config/features=PackedStringArray("4.7", ...)`。用 4.6 打开会提示升级工程
文件，可能改动 `.tscn`，污染 git。`setup.ps1` 会检查并警告。

### 2. 调色板字节序 —— 反着的

调色板数组是 `0xRRGGBB`（红在**高**位），而逐 splat 的颜色 lane 是 `r | g<<8 | b<<16`（红在**低**位）。
**同一个颜色的两个舞池用两种字节序。**

搞反的后果是画面整体偏暖、轮廓多一圈假描边，而且看起来非常"合理"，很容易当成美术问题查半天。
证据：watcher 的 112,465 个 splat 里，按 lane 序能对上调色板的 0 个，字节交换后对上 112,465 个。

### 3. 平色盘和盘半径是**反向**耦合的

`flat_alpha=true` 让每个 splat 变成实心硬边盘。此时 `alpha_cutoff` 要**调低**（盘变大），
否则表面露缝。当前 `project.godot` 用 `alpha_cutoff=0.1`（约 2.13σ）。

这和"让 splat 更硬"的直觉方向相反 —— 早期我把 cutoff 从 0.55 一路加到 0.98，结果只是盘变小、
表面更容易露缝。

### 4. 后处理必须挂在透明阶段之后

splat 在透明混合阶段绘制。全屏 QuadMesh + `hint_screen_texture` 拿不到它。所以像素后处理是
`CompositorEffect` + `EFFECT_CALLBACK_TYPE_POST_TRANSPARENT`，不是普通全屏 shader。

### 5. PowerShell 会掐断原生命令

```powershell
git add -A | Select-Object -First 5      # 五条 CRLF 警告后 git 被杀，暂存只做一半
godot --import | Select-Object -First 5  # 导入被杀，工程留锁，之后全部卡死
```

要截断就先转字符串：

```powershell
$out = (& git add -A 2>&1 | Out-String)
($out -split "`n") | Where-Object { $_ -match 'warning' }
```

### 6. `*>` 重定向会静默不执行

```powershell
godot --check-only --script res://x.gd *> $log    # 返回码空、耗时 0 秒、$log 还是旧的
```

它**假装成功**，比报错危险得多。用 `2>&1 | Out-String`，然后自己写文件。

### 7. `.ps1` 里有中文就存成 UTF-8 **带 BOM**

Windows PowerShell 5.1 会把无 BOM 的 UTF-8 按 ANSI 解析，中文全乱。
`setup.ps1` 已经是带 BOM 的。

### 8. 节点必须摆到质心

```gdscript
node.transform = Transform3D(Basis.IDENTITY, centroid)   # centroid 来自 sidecar
```

这一行同时做两件事：恢复世界坐标（GDGS 导入时会把位置减掉均值），和抵消 GDGS 默认的
180° Z 翻转。少了它会看到场景是正的但方向反了，或者位置偏。

---

## 需要帮忙找谁

| 问题 | 找 |
|---|---|
| ink-studio 仓库权限 | 项目负责人（私有仓库，无权限 = 只能走路线 A） |
| 资产对不对 / 颜色不对 | 先跑 `overview-sheet.ps1`，看是不是 `offPixels` 不为 0 |
| 渲染异常 / 掉帧 | 先确认后端是 Raster：日志里要有 `[gdgs] rendering backend: Raster` |
| 想升级 GDGS | 先读 `VENDOR-PATCHES.md`，按里面的补丁清单重新打一遍 |
