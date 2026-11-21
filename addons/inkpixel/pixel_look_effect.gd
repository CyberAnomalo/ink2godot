@tool
class_name InkPixelLookEffect
extends CompositorEffect

## ink-studio 的像素风后处理：调色板量化 + 有序抖动 + 描边。
##
## 挂在 WorldEnvironment 的 Compositor 上，在 POST_TRANSPARENT 阶段跑一个 compute shader。
## 必须挂在透明阶段之后 —— GDGS 的 Raster splat 是混合绘制的，只有到 POST_TRANSPARENT
## 整帧才是完整的。
##
## 用法（在场景脚本里）：
##   var fx := InkPixelLookEffect.new()
##   fx.set_palette_from_packed(sidecar.ink.palette)
##   fx.dither = sidecar.ink.dither
##   var comp := Compositor.new()
##   comp.compositor_effects = [gdgs_effect, fx]   # 顺序无关，阶段不同
##   $WorldEnvironment.compositor = comp
##
## 注意：GDGS 的 Raster 后端用 depth_draw_never，深度缓冲里没有 splat 的深度，
## 所以描边只能从亮度突变求，不是真正的几何轮廓。

const WORKGROUP_SIZE := 16
const SHADER_PATH := "res://addons/inkpixel/shaders/pixel_look.glsl"
const MAX_PALETTE := 64

@export var pixel_enabled := true

## 抖动强度，对应 ink-studio 的 world.dither
@export_range(0.0, 1.0, 0.005) var dither := 0.16

## 描边强度，0 = 关
@export_range(0.0, 1.0, 0.01) var edge_amount := 0.0

## 亮度突变阈值：低了会把表面明暗过渡也描上
@export_range(0.0, 1.0, 0.005) var edge_threshold := 0.14

## 描边把颜色压暗到多少
@export_range(0.0, 1.0, 0.01) var edge_darken := 0.35

## 像素块边长：1 = 全分辨率（只有量化，没有“像素感”）。
## 3 = 1280x720 变成 ~427x240 的硬边方形像素。这才是像素画观感的主因。
@export_range(1, 16, 1) var pixel_size := 3

## 调色板（sRGB，0..1）。空 = 不做量化，只抖动（基本没用，留作调试）
var palette: Array[Color] = []

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var _palette_buffer: RID
var _palette_dirty := true


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if rd != null:
		if _palette_buffer.is_valid():
			rd.free_rid(_palette_buffer)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
	_palette_buffer = RID()
	pipeline = RID()
	shader = RID()


## 从 ink-studio sidecar 的 ink.palette 灌调色板。
##
## ⚠ 字节序陷阱（已实测确认，不是猜测）：
##   调色板表的项是 0xRRGGBB —— **红色在高字节**（world.pal[2] = 0x2a2e36 = rgb(42,46,54)）。
##   但逐 splat 的 packedRGB lane 是 r | g<<8 | b<<16 —— **红色在低字节**。
##   两者相反。实测 watcher 的 112,465 个 lane 值全部等于某个调色板项
##   按字节交换后的值（112465/112465），所以这里必须按 0xRRGGBB 解。
##   搞反的后果：蓝灰变棕，且量化会在边缘选出错的颜色（暗色描边）。
func set_palette_from_packed(packed: Array) -> void:
	var next: Array[Color] = []
	for v in packed:
		var i := int(v)
		next.append(Color(
			float((i >> 16) & 255) / 255.0,
			float((i >> 8) & 255) / 255.0,
			float(i & 255) / 255.0,
			1.0))
	palette = next
	_palette_dirty = true


func _initialize() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		return

	var glsl: RDShaderFile = load(SHADER_PATH)
	if glsl == null:
		push_error("[inkpixel] 载入着色器失败: " + SHADER_PATH)
		return
	var spirv := glsl.get_spirv()
	if spirv == null:
		push_error("[inkpixel] 着色器编译失败: " + SHADER_PATH)
		return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	_palette_buffer = _create_palette_buffer()
	_palette_dirty = true


func _create_palette_buffer() -> RID:
	# 64 个 vec4 = 1024 字节，std430 下 vec4 步长 16
	var bytes := PackedFloat32Array()
	bytes.resize(MAX_PALETTE * 4)
	return rd.storage_buffer_create(bytes.to_byte_array().size(), bytes.to_byte_array())


func _upload_palette() -> void:
	_palette_dirty = false
	if not _palette_buffer.is_valid():
		return
	var data := PackedFloat32Array()
	data.resize(MAX_PALETTE * 4)
	for i in range(min(palette.size(), MAX_PALETTE)):
		var c := palette[i]
		data[i * 4 + 0] = c.r
		data[i * 4 + 1] = c.g
		data[i * 4 + 2] = c.b
		data[i * 4 + 3] = 1.0
	rd.buffer_update(_palette_buffer, 0, data.to_byte_array().size(), data.to_byte_array())


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not pixel_enabled:
		return
	if rd == null or not shader.is_valid() or not pipeline.is_valid():
		return

	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	if _palette_dirty:
		_upload_palette()
	if not _palette_buffer.is_valid():
		return

	var push := PackedFloat32Array([
		float(size.x),
		float(size.y),
		dither,
		float(min(palette.size(), MAX_PALETTE)),
		edge_amount,
		edge_threshold,
		edge_darken,
		float(pixel_size),
	]).to_byte_array()

	var groups_x := int(ceili(size.x / float(WORKGROUP_SIZE)))
	var groups_y := int(ceili(size.y / float(WORKGROUP_SIZE)))

	for view in buffers.get_view_count():
		var color_rid := buffers.get_color_layer(view)
		if not color_rid.is_valid():
			continue

		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(color_rid)

		var pal_uniform := RDUniform.new()
		pal_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		pal_uniform.binding = 1
		pal_uniform.add_id(_palette_buffer)

		var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [color_uniform, pal_uniform])
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, groups_x, groups_y, 1)
		rd.compute_list_end()
