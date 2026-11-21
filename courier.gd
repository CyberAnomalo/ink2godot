extends Node3D

# 骨骼动画驱动：每个 ink-studio 骨骼对应一个 GaussianSplatNode，
# 每帧用 anim.json 里烘好的 12 float 骨骼矩阵去摆它。
#
# ink-studio 侧语义（src/kit/k1-stage.js:625-628、src/splat-frames.js）：
#   P' = M行主序 · P + T
# GDGS 导入时把 PLY 位置减掉了各自 centroid，所以节点变换要补回来：
#   Transform3D(Basis(rows = M), M · centroid + T)

const DIR := "res://assets/courier/"
const NODE_SCRIPT := "res://addons/gdgs/runtime/nodes/gaussian_splat_node.gd"

var _parts: Array[Dictionary] = []
var _frames: Array = []
var _fps: float = 24.0
var _t: float = 0.0
var _playing: bool = true
var _bind_only: bool = false
var _bench: bool = false
var _bench_frames: int = 0
var _bench_acc: float = 0.0

func _ready() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + "anim.json"))
	_fps = float(meta.get("fps", 24))
	_frames = meta.get("frames", [])
	_bind_only = "--bind" in OS.get_cmdline_user_args()

	var node_script: GDScript = load(NODE_SCRIPT)
	for b in meta.get("bones", []):
		var node: VisualInstance3D = node_script.new()
		node.name = "bone_%s" % str(b["index"])
		node.gaussian = load(DIR + String(b["file"]))
		add_child(node)
		var c: Array = b["centroid"]
		_parts.append({
			"node": node,
			"index": int(b["index"]),
			"fixed": bool(b.get("fixed", false)),
			"centroid": Vector3(float(c[0]), float(c[1]), float(c[2])),
		})

	print("[courier] %d 个骨骼节点, %d 帧 @ %.0f fps" % [_parts.size(), _frames.size(), _fps])
	_apply(0)
	_setup_camera()

	# 像素风后处理：调色板/抖动从导出器写进 anim.json 的 ink 块读。
	if not ("--no-pixel" in OS.get_cmdline_user_args()):
		InkPixel.attach(get_node_or_null("WorldEnvironment") as WorldEnvironment, meta,
			InkPixel.opts_from_args(OS.get_cmdline_user_args()))

	if "--capture" in OS.get_cmdline_user_args():
		_capture_times([0.0, 0.8, 1.6])
	elif "--bench" in OS.get_cmdline_user_args():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_bench = true

func _process(delta: float) -> void:
	if not _playing or _frames.is_empty():
		return
	_t = fmod(_t + delta, _frames.size() / _fps)
	_apply_at_time(_t)
	if _bench:
		_bench_frames += 1
		_bench_acc += delta
		if _bench_frames == 60:
			_bench_acc = 0.0   # 跳过前 60 帧的着色器预热
		elif _bench_frames > 360:
			var avg := _bench_acc / 300.0
			print("[courier] 性能: %.2f ms/帧 = %.0f fps（%d 个骨骼节点, 3920 splat, 1000x700）" % [avg * 1000.0, 1.0 / avg, _parts.size()])
			get_tree().quit()

func _apply_at_time(t: float) -> void:
	var idx: int = clampi(int(round(t * _fps)), 0, _frames.size() - 1)
	_apply(idx)

func _apply(frame_index: int) -> void:
	if _frames.is_empty():
		return
	var m: Array = _frames[frame_index]["m"]
	for p in _parts:
		var node: VisualInstance3D = p["node"]
		var centroid: Vector3 = p["centroid"]
		if p["fixed"] or _bind_only:
			node.transform = Transform3D(Basis.IDENTITY, centroid)
			continue
		var k: int = int(p["index"]) * 12
		# anim.json 里的 12 个数是 3x3 **行主序**（ink-studio 的 posed() 算 M·P + T）。
		# Godot 的 Basis(a, b, c) 三个参数填的是**列**，所以要按列重组：
		#   行 (a,b,c) (d,e,f) (g,h,i)  ->  列 (a,d,g) (b,e,h) (c,f,i)
		var basis := Basis(
			Vector3(float(m[k]), float(m[k + 3]), float(m[k + 6])),
			Vector3(float(m[k + 1]), float(m[k + 4]), float(m[k + 7])),
			Vector3(float(m[k + 2]), float(m[k + 5]), float(m[k + 8])))
		var translation := Vector3(float(m[k + 9]), float(m[k + 10]), float(m[k + 11]))
		node.transform = Transform3D(basis, basis * centroid + translation)

func _setup_camera() -> void:
	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		return
	var target := Vector3(0.0, 1.55, 0.0)
	var dist := 6.2
	var pitch := 0.10
	var yaw := 0.55
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)) * dist
	cam.transform = Transform3D(Basis.IDENTITY, target + offset)
	cam.look_at(target, Vector3.UP)
	cam.fov = 42.0
	cam.near = 0.05
	cam.far = 200.0

func _capture_times(times: Array) -> void:
	_playing = false
	var i := 0
	for t in times:
		_apply_at_time(float(t))
		for _f in 24:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var out := ProjectSettings.globalize_path("res://shot_f%d.png" % i)
		image.save_png(out)
		print("[courier] t=%.2fs -> %s" % [float(t), out])
		i += 1
	get_tree().quit()
