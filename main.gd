extends Node3D

# Places the imported GaussianSplatNode back at the world centroid that
# ink-studio baked (GDGS re-centres positions on the mean during import) and
# frames the camera the way ink-studio's own scene camera would.
#
# Runs after the child GaussianSplatNode's _ready, so it also clears GDGS's
# default "-180 deg about Z" model-orientation correction.

const SIDECAR := "res://assets/dioramas/watcher.ply.json"

@export var camera_distance: float = 21.0
@export var camera_pitch: float = 0.16
@export var camera_yaw: float = 0.42

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var splat := get_node_or_null("Splat") as Node3D
	var centroid := Vector3.ZERO
	var target := Vector3(0, 3.4, 0)
	var meta := {}

	if FileAccess.file_exists(SIDECAR):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(SIDECAR))
		if parsed is Dictionary:
			meta = parsed
			var c = parsed.get("centroid", [])
			if c is Array and c.size() == 3:
				centroid = Vector3(float(c[0]), float(c[1]), float(c[2]))

	if splat:
		# identity basis clears the importer's default orientation correction
		splat.transform = Transform3D(Basis.IDENTITY, centroid)

	var cam := get_node_or_null("Camera3D") as Camera3D
	if cam:
		var look := target + centroid * 0.0
		var offset := Vector3(
			sin(camera_yaw) * cos(camera_pitch),
			sin(camera_pitch),
			cos(camera_yaw) * cos(camera_pitch)
		) * camera_distance
		cam.transform = Transform3D(Basis.IDENTITY, look + offset)
		cam.look_at(look, Vector3.UP)
		cam.fov = 45.0
		cam.near = 0.05
		cam.far = 500.0

	if not ("--no-pixel" in args):
		InkPixel.attach(get_node_or_null("WorldEnvironment") as WorldEnvironment, meta, InkPixel.opts_from_args(args))

	if "--capture" in args:
		_capture()

func _capture() -> void:
	# let the compute splat pass settle before reading the viewport back
	for i in 30:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	# 抓图统一放进 artifacts/（已 gitignore），不污染工程根目录
	var dir := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir.path_join("shot.png")
	var err := image.save_png(out)
	print("[ink2godot] capture %s -> %s (%dx%d)" % [err, out, image.get_width(), image.get_height()])
	get_tree().quit()
