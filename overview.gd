extends Node3D

## 七个 diorama 的总览：逐个加载 assets/dioramas/<id>.ply，按作者相机构图，
## 挂上像素风后处理，抓图后换下一个。
##
## 用法：
##   godot --path . res://overview.tscn                      # 交互，只显示第一个
##   godot --path . res://overview.tscn -- --capture         # 依次抓七个
##   godot --path . res://overview.tscn -- --capture --only=cabinet
## 额外参数和 main.tscn 一样（--no-pixel --px= --dither= ...）。

const NODE_SCRIPT := "res://addons/gdgs/runtime/nodes/gaussian_splat_node.gd"
const DIR := "res://assets/dioramas/"
const IDS := ["watcher", "burn", "idol", "bench", "stuff", "cabinet", "rehearsal"]

var _base_compositor: Compositor
var _capture := false
var _only := ""

func _ready() -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we:
		_base_compositor = we.compositor

	var args := OS.get_cmdline_user_args()
	_capture = "--capture" in args
	for a in args:
		if a.begins_with("--only="):
			_only = a.substr(7)

	if _capture:
		_capture_all(args)
	else:
		_show(_only if _only != "" else IDS[0], args)

## 载入一个场景并替换掉上一个
func _show(id: String, args: PackedStringArray) -> Node3D:
	for c in get_children():
		if c is VisualInstance3D:
			remove_child(c)
			c.queue_free()

	var meta := _meta(id)
	if meta.is_empty():
		push_error("[overview] 缺少 sidecar: %s%s.ply.json" % [DIR, id])
		return null

	var node: VisualInstance3D = load(NODE_SCRIPT).new()
	node.name = "Splat_" + id
	node.set("gaussian", load(DIR + id + ".ply"))
	add_child(node)

	# GDGS 导入时把位置减去质心；在这里把节点摆回质心恢复世界坐标。
	# identity basis 同时清掉 importer 的默认 -180°Z 翻转。
	var c: Array = meta.get("centroid", [0.0, 0.0, 0.0])
	node.transform = Transform3D(Basis.IDENTITY, Vector3(float(c[0]), float(c[1]), float(c[2])))

	_frame(meta)

	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and not ("--no-pixel" in args):
		# 每次都从干净的基线重建，否则调色板 effect 会被不断叠加
		we.compositor = _base_compositor
		InkPixel.attach(we, meta, InkPixel.opts_from_args(args))
	return node

## 用 sidecar 里的作者相机构图。没有 cam 才退回按 AABB 硬框 ——
## AABB 里有 (-99) 的哨兵值，直接框会毁掉构图，所以必须优先用 cam。
func _frame(meta: Dictionary) -> void:
	var ink: Dictionary = meta.get("ink", {})
	var cam_data = ink.get("cam", null)

	var target := Vector3(0.0, 2.0, 0.0)
	var dist := 20.0
	var yaw := 0.42
	var pitch := 0.16
	# ink-studio 的默认垂直 fov 是 38°（src/camera-lens.js:3），不是 45°。
	# 用 45° 会比作者视角更广，主体显得偏小。
	var fov_deg := 38.0

	if cam_data is Dictionary:
		var t = cam_data.get("target", [])
		if t is Array and t.size() == 3:
			target = Vector3(float(t[0]), float(t[1]), float(t[2]))
		dist = float(cam_data.get("dist", dist))
		yaw = float(cam_data.get("yaw", yaw))
		pitch = float(cam_data.get("pitch", pitch))
		# cam.fov 存的是弧度（kc-data.js 校验 fov < PI）
		if cam_data.has("fov"):
			fov_deg = rad_to_deg(float(cam_data["fov"]))
	else:
		var c: Array = meta.get("centroid", [0.0, 0.0, 0.0])
		target = Vector3(float(c[0]), float(c[1]), float(c[2]))

	var cam := get_node("Camera3D") as Camera3D
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * dist
	cam.transform = Transform3D(Basis.IDENTITY, target + offset)
	cam.look_at(target, Vector3.UP)
	cam.fov = fov_deg

func _meta(id: String) -> Dictionary:
	var p := DIR + id + ".ply.json"
	if not FileAccess.file_exists(p):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed if parsed is Dictionary else {}

func _capture_all(args: PackedStringArray) -> void:
	for id in IDS:
		if _only != "" and id != _only:
			continue
		var node := _show(id, args)
		if node == null:
			continue
		await _wait_frames(24)
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var dir := ProjectSettings.globalize_path("res://artifacts")
		DirAccess.make_dir_recursive_absolute(dir)
		var out := dir.path_join("overview_%s.png" % id)
		var err := image.save_png(out)
		print("[overview] %s -> %s (%dx%d) err=%s" % [
			id, out, image.get_width(), image.get_height(), err])
	get_tree().quit()

func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
