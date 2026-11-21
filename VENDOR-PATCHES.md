# GDGS 本地补丁记录

`addons/gdgs/` 是 [GDGS](https://github.com/ReconWorldLab/godot-gaussian-splatting)
上游 commit `c22024b` 的副本，**带本地修改**。

改这两处的原因是：ink-studio 的 splat 带程序化动画（VFX），且它的 splat 是硬边实心盘，
而 GDGS 默认既没有动画通道、也是平滑高斯。上游没有接口，只能改。

升级 GDGS 时：重新拷贝上游 `addons/gdgs/`，然后把下面两处补丁重新应用，再跑一遍验证。

---

## 补丁 1 — `runtime/render/raster/raster_render_backend.gd`

**位置**：`_populate_entry()` 里创建 `ShaderMaterial` 之后（`use_order` 那几行之后）。

**问题**：`gaussian_raster.gdshader` 里的 `alpha_cutoff` / `flat_alpha` 是**孤立 shader
uniform，没有任何 GDScript setter**，所以永远停在默认值，改 project setting 完全无效。
（曾经因此浪费了一轮排查：以为调 cutoff 有变化，其实是空操作。）

**修改**：从 project setting 读两个值并写进材质。

```gdscript
material.set_shader_parameter("alpha_cutoff", float(ProjectSettings.get_setting(
	"gdgs/rendering/raster/alpha_cutoff", 0.00392)))
material.set_shader_parameter("flat_alpha", 1.0 if bool(ProjectSettings.get_setting(
	"gdgs/rendering/raster/flat_alpha", false)) else 0.0)
```

**生效时机**：GaussianSplatNode 创建 / 赋值 `gaussian` 时。所以父节点 `_ready` 里改
project setting 已经太晚（子节点 `_ready` 早于父节点）。

---

## 补丁 2 — `runtime/render/raster/materials/gaussian_raster.gdshader`

### 2a. 逐 splat 程序化动画（VFX）

ink-studio 的 splat 行有四个动画字段（kind / phase / speed / range / extra），GDGS 没有
通道传它们。利用"ink-studio 颜色是平色 → 45 个高阶 SH 槽全空"这一点，把它们塞进
`f_rest_*`：

`standard_ply_decoder.gd` 按**通道交错**映射 `f_rest`（0-14 是 R，15-29 是 G，30-44 是 B），
所以五个值分别落在 `f_rest_0` / `f_rest_15` / `f_rest_30` / `f_rest_1` / `f_rest_16`，
即 shader 里的 `c[3]` / `c[4]` / `c[5]` / `c[6]` / `c[7]`。

`vertex()` 里：

1. 提前取出 `c[3..7]` 作为 `ink0` / `ink1`（基础索引命名成 `ink_sh_base`，避开后面 `c[48]` 循环）
2. `kind > 0` 时调用 `ink_anim(inout p, inout cov, inout alpha, kind, ph, sp, rg, ex, TIME)`
3. 重新 clamp opacity
4. 在 `eval_sh` 之前把 `c[3..7]` 清零，否则注入的值会污染 SH 颜色

`ink_anim()` 是 `src/splat-frames.js` 的逐行移植，覆盖 kind 1/2/3/5/6/7/8/9/10/11/14/15。
时钟用 Godot 的 `TIME` builtin，**不需要每帧从 CPU 注入**。

数值等价性由 `art-pipeline/test-vfx-math.js` 把关：六个场景约 46 万 splat，
位置/不透明度/协方差误差全部 `0.000e+0`。

三个移植陷阱（踩过）：

| 陷阱 | 说明 |
|---|---|
| kind 5 的 `[x,z] = [c*x+s*z, c*z-s*x]` | JS 解构会先算完右边再赋值；GLSL 里必须先存 `ox`/`oz` 再写 |
| kind 11 的 y 项要读**已修改**的 x | 这个是 ink-studio 的有意行为，不要"修正" |
| kind 15 不参与协方差放大 | 放大只对 kind 2/3 生效，漏了会让龙灯场景协方差误差到 3.479e-1 |

`mat3(a,b,c)` 填的是**列**，ink-studio 的行主序旋转矩阵要转置着传。

### 2b. 平色硬边盘（`flat_alpha`）

ink-studio 的 splat 是不透明圆盘，没有高斯衰减。`fragment()` 末尾：

```glsl
uniform float flat_alpha = 0.0;   // 加在 uniform 区
...
ALPHA = flat_alpha > 0.5 ? 1.0 : clamp(a, 0.0, 1.0);
```

保留 `alpha_cutoff` 的 discard 来定义盘形，只把盘内 alpha 拉满。

**注意耦合**：开了平色反而要把 `alpha_cutoff` **调低**（盘变大）——
实心盘是画家算法，前面完全遮住后面，盘不够大就在表面上露背景缝。
实测 0.98 不透明度下 0.1 约等于 2.13σ 盘半径，无露缝。

---

## 未修改但必须知道的 GDGS 行为

1. **默认朝向修正**：`get_model_orientation_correction()` 在 basis 近似 identity 时
   乘上绕 Z 转 180° 的矩阵。所以必须把 GaussianSplatNode 摆到质心
   （`Transform3D(Basis.IDENTITY, centroid)`）来同时恢复坐标和抵消翻转。
2. **导入时位置被减去质心**：所以 sidecar 里的 centroid 是必需的。
3. **SH 颜色按 sRGB 处理**：`f_dc` 要用 sRGB 字节反算，不是线性化后的颜色。
4. **Raster 后端用 `depth_draw_never`**：深度缓冲里没有 splat，所以基于深度的
   轮廓描边对 splat 完全无效，只能用屏幕空间亮度差分近似。
5. **CompositorEffect 必须挂在 `POST_TRANSPARENT`**：Raster splat 是透明阶段绘制的，
   全屏 QuadMesh + `hint_screen_texture` 拿不到它。
