class_name InkPixel
extends RefCounted

## ink-studio 像素风后处理的挂载助手。
##
## 把 InkPixelLookEffect 追加到 WorldEnvironment 的 Compositor 链上。
## 参数（调色板、抖动强度）全部来自 PLY 的 sidecar，和 ink-studio 自己渲染时
## 用的是同一份数据 —— 不手抄色值，避免两边漂移。
##
##   InkPixel.attach($WorldEnvironment, meta)
##   InkPixel.attach($WorldEnvironment, meta, {"dither": 0.3, "edge": 0.5})


## 从 sidecar 的 ink 块挂上像素后处理，返回 effect 以便运行时调参。
## opts 支持 dither / edge / edge_threshold / edge_darken / palette_only。
static func attach(world_env: WorldEnvironment, meta: Dictionary, opts: Dictionary = {}) -> InkPixelLookEffect:
	if world_env == null:
		push_warning("[inkpixel] 没有 WorldEnvironment，跳过像素后处理")
		return null

	var ink: Dictionary = meta.get("ink", {})
	var fx := InkPixelLookEffect.new()
	if not ink.is_empty():
		fx.set_palette_from_packed(ink.get("palette", []))
		fx.dither = float(ink.get("dither", fx.dither))
	if opts.has("dither"):
		fx.dither = float(opts["dither"])
	if opts.has("edge"):
		fx.edge_amount = float(opts["edge"])
	if opts.has("edge_threshold"):
		fx.edge_threshold = float(opts["edge_threshold"])
	if opts.has("edge_darken"):
		fx.edge_darken = float(opts["edge_darken"])
	if opts.has("pixel_size"):
		fx.pixel_size = int(opts["pixel_size"])

	var effects: Array[CompositorEffect] = []
	if world_env.compositor != null:
		for e in world_env.compositor.compositor_effects:
			effects.append(e)
	effects.append(fx)
	var comp := Compositor.new()
	comp.compositor_effects = effects
	world_env.compositor = comp

	print("[pixel] 调色板 %d 色%s  dither %.2f  描边 %.2f (阈值 %.2f)  effect 链 %d" % [
		fx.palette.size(),
		"" if ink.is_empty() else " (" + str(ink.get("palName", "?")) + ")",
		fx.dither, fx.edge_amount, fx.edge_threshold, effects.size()])
	return fx


## 命令行覆盖，形如 --dither=0.3 --edge=0.5 --edge-thresh=0.14
## 返回一个只含被显式指定项的表。
static func opts_from_args(args: PackedStringArray) -> Dictionary:
	var out := {}
	for a in args:
		if a.begins_with("--dither="):
			out["dither"] = float(a.substr(9))
		elif a.begins_with("--edge="):
			out["edge"] = float(a.substr(7))
		elif a.begins_with("--edge-thresh="):
			out["edge_threshold"] = float(a.substr(14))
		elif a.begins_with("--edge-darken="):
			out["edge_darken"] = float(a.substr(14))
		elif a.begins_with("--px="):
			out["pixel_size"] = int(a.substr(5))
	return out
