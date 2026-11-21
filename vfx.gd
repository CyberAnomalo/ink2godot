extends Node3D
## VFX 验证场景：加载一个带 --vfx 导出的 PLY，在 Godot 里实时播它的程序化动画。
##
## ink-studio 把逐 splat 的动画参数（kind / phase / speed / range / extra）塞在
## PLY 的五个空 f_rest 槽里，改过的 GDGS raster 着色器在顶点阶段用 TIME 重算。
## 所以这里不需要任何 C# / GDScript 动画逻辑——只要把 PLY 挂上去。

const NODE_SCRIPT := "res://addons/gdgs/runtime/nodes/gaussian_splat_node.gd"

var _ply := "res://assets/vfx/motion-cadence.ply"
var _sidecar := "res://assets/vfx/motion-cadence.ply.json"
var _centroid := Vector3.ZERO
var _capture := false
var _pixel: InkPixelLookEffect

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_capture = "--capture" in args
	var pixel_on := not ("--no-pixel" in args)
	var dither_override := -1.0
	var edge_override := -1.0
	var edge_thresh := -1.0
	var cutoff := -1.0
	for a in args:
		if a.begins_with("--ply="):
			_ply = a.substr(6)
			_sidecar = _ply + ".json"
		elif a.begins_with("--dither="):
			dither_override = float(a.substr(9))
		elif a.begins_with("--edge="):
			edge_override = float(a.substr(7))
		elif a.begins_with("--edge-thresh="):
			edge_thresh = float(a.substr(14))
		elif a.begins_with("--cutoff="):
			cutoff = float(a.substr(9))

	# splat 截断半径：必须在节点创建之前设好，材质是在赋值 gaussian 时生成的。
	# 调大 = 把高斯削成硬边实心盘 = 边缘没有混合渐变色 = 量化不会选中错的调色板色。
	if cutoff >= 0.0:
		ProjectSettings.set_setting("gdgs/rendering/raster/alpha_cutoff", clampf(cutoff, 0.0, 1.0))

	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_sidecar))
	var c: Array = meta["centroid"]
	_centroid = Vector3(float(c[0]), float(c[1]), float(c[2]))
	var lo: Array = meta["aabb"]["min"]
	var hi: Array = meta["aabb"]["max"]
	var size := Vector3(
		float(hi[0]) - float(lo[0]),
		float(hi[1]) - float(lo[1]),
		float(hi[2]) - float(lo[2]))

	var script: GDScript = load(NODE_SCRIPT)
	var node: Node3D = script.new()
	node.set("gaussian", load(_ply))
	add_child(node)
	# GDGS 导入时按自身质心做了居中，这里补回来。
	node.transform = Transform3D(Basis.IDENTITY, _centroid)

	var cam: Camera3D = $Camera3D
	var extent := maxf(maxf(size.x, size.y), size.z)
	var dist := maxf(extent * 1.15, 4.0)
	var yaw := 0.6
	var pitch := 0.14
	var target := _centroid
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)) * dist
	cam.transform = Transform3D(Basis.IDENTITY, target + offset)
	cam.look_at(target, Vector3.UP)

	print("[vfx] %s  %d splat  范围 %s  质心 %s" % [
		_ply.get_file(), int(meta["count"]), str(size), str(_centroid)])

	if pixel_on:
		_attach_pixel_look(meta, dither_override, edge_override, edge_thresh)

	if _capture:
		_capture_run()

## 把 ink-studio 的像素风后处理（调色板量化 + 有序抖动 + 描边）挂到世界环境的 Compositor 上。
## 参数都来自 sidecar 的 ink 块，和 ink-studio 自己渲染时用的同一份数据。
func _attach_pixel_look(meta: Dictionary, dither_override: float, edge_override: float, edge_thresh: float) -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null:
		print("[pixel] 没有 WorldEnvironment，跳过")
		return

	var ink: Dictionary = meta.get("ink", {})
	var fx := InkPixelLookEffect.new()
	fx.set_palette_from_packed(ink.get("palette", []))
	fx.dither = float(ink.get("dither", 0.0)) if dither_override < 0.0 else dither_override
	if edge_override >= 0.0:
		fx.edge_amount = edge_override
	if edge_thresh >= 0.0:
		fx.edge_threshold = edge_thresh

	var effects: Array[CompositorEffect] = []
	if we.compositor != null:
		for e in we.compositor.compositor_effects:
			effects.append(e)
	effects.append(fx)
	var comp := Compositor.new()
	comp.compositor_effects = effects
	we.compositor = comp
	_pixel = fx
	print("[pixel] 调色板 %d 色  dither %.2f  描边 %.2f (阈值 %.2f)  链上 %d 个 effect" % [
		fx.palette.size(), fx.dither, fx.edge_amount, fx.edge_threshold, effects.size()])

## 隔一段时间抓几帧，并打印帧间平均绝对差——雨/风应该让像素持续变化。
func _capture_run() -> void:
	var images: Array[Image] = []
	for i in 3:
		for _f in 90:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var dir := ProjectSettings.globalize_path("res://artifacts")
		DirAccess.make_dir_recursive_absolute(dir)
		var out := dir.path_join("shot_v%d.png" % i)
		img.save_png(out)
		images.append(img)
		print("[vfx] 第 %d 帧 -> %s  (TIME=%.2fs)" % [i, out, Time.get_ticks_msec() / 1000.0])

	for i in range(1, images.size()):
		print("[vfx] 帧 0 与帧 %d 平均像素差: %.2f / 255" % [i, _mad(images[0], images[i])])
	get_tree().quit()

func _mad(a: Image, b: Image) -> float:
	var da := a.get_data()
	var db := b.get_data()
	if da.size() != db.size() or da.is_empty():
		return -1.0
	var total := 0.0
	var count := 0
	# 每 4 字节取一个通道（跳过 RGB 冗余），够用了。
	for i in range(0, da.size(), 16):
		total += absf(float(da[i]) - float(db[i]))
		count += 1
	return total / float(count)
