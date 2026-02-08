extends RefCounted
class_name GpuMapView

const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")
const WorldData1TextureCompute = preload("res://scripts/systems/WorldData1TextureCompute.gd")
const WorldData2TextureCompute = preload("res://scripts/systems/WorldData2TextureCompute.gd")
const CloudTextureCompute = preload("res://scripts/systems/CloudTextureCompute.gd")
const LocalLightCompute = preload("res://scripts/systems/LocalLightCompute.gd")
const CloudNoiseCompute = preload("res://scripts/systems/CloudNoiseCompute.gd")

var width: int = 0
var height: int = 0
var seed_hash: int = 1
var prefix: String = "view"

var _buf_mgr: Object = null
var _data1_tex: Object = null
var _data2_tex: Object = null
var _cloud_tex: Object = null
var _light_compute: Object = null
var _cloud_compute: Object = null
var _data1_pack: Object = null
var _data2_pack: Object = null
var _cloud_pack: Object = null

func configure(prefix_value: String, w: int, h: int, seed_value: int) -> void:
	prefix = prefix_value if not prefix_value.is_empty() else "view"
	width = max(1, int(w))
	height = max(1, int(h))
	seed_hash = int(seed_value) if int(seed_value) != 0 else 1
	_buf_mgr = GPUBufferManager.new()
	_data1_pack = WorldData1TextureCompute.new()
	_data2_pack = WorldData2TextureCompute.new()
	_cloud_pack = CloudTextureCompute.new()
	_light_compute = LocalLightCompute.new()
	_cloud_compute = CloudNoiseCompute.new()
	_ensure_buffers()

func _ensure_buffers() -> void:
	if _buf_mgr == null:
		return
	var size: int = width * height
	var bytes_f32: int = size * 4
	var bytes_i32: int = size * 4
	_buf_mgr.ensure_buffer("%s_height" % prefix, bytes_f32)
	_buf_mgr.ensure_buffer("%s_temp" % prefix, bytes_f32)
	_buf_mgr.ensure_buffer("%s_moist" % prefix, bytes_f32)
	_buf_mgr.ensure_buffer("%s_light" % prefix, bytes_f32)
	_buf_mgr.ensure_buffer("%s_biome" % prefix, bytes_i32)
	_buf_mgr.ensure_buffer("%s_land" % prefix, bytes_i32)
	_buf_mgr.ensure_buffer("%s_beach" % prefix, bytes_i32)
	_buf_mgr.ensure_buffer("%s_cloud" % prefix, bytes_f32)

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	_buf_mgr = null

func _rid(name: String) -> RID:
	if _buf_mgr == null:
		return RID()
	return _buf_mgr.get_buffer("%s_%s" % [prefix, name])

func _update_buffer(name: String, bytes: PackedByteArray) -> void:
	if _buf_mgr == null:
		return
	_buf_mgr.update_buffer("%s_%s" % [prefix, name], bytes)

func update_and_draw(
	renderer: Node,
	fields: Dictionary,
	solar: Dictionary,
	clouds: Dictionary,
	fixed_lon: float,
	fixed_phi: float,
	sea_level: float = 0.0
) -> void:
	if renderer == null or _buf_mgr == null:
		return
	_ensure_buffers()

	var size: int = width * height
	var height_raw: PackedFloat32Array = fields.get("height_raw", PackedFloat32Array())
	var temp: PackedFloat32Array = fields.get("temp", PackedFloat32Array())
	var moist: PackedFloat32Array = fields.get("moist", PackedFloat32Array())
	var biome: PackedInt32Array = fields.get("biome", PackedInt32Array())
	var land: PackedInt32Array = fields.get("land", PackedInt32Array())
	var beach: PackedInt32Array = fields.get("beach", PackedInt32Array())
	if height_raw.size() != size:
		return
	if temp.size() != size:
		return
	if moist.size() != size:
		return
	if biome.size() != size:
		return
	if land.size() != size:
		return
	if beach.size() != size:
		return

	_update_buffer("height", height_raw.to_byte_array())
	_update_buffer("temp", temp.to_byte_array())
	_update_buffer("moist", moist.to_byte_array())
	_update_buffer("biome", biome.to_byte_array())
	_update_buffer("land", land.to_byte_array())
	_update_buffer("beach", beach.to_byte_array())

	var day_of_year: float = float(solar.get("day_of_year", 0.0))
	var time_of_day: float = float(solar.get("time_of_day", 0.0))
	var sim_days: float = float(solar.get("sim_days", 0.0))

	# Light compute (GPU): writes into light buffer, then gets packed into world_data_1 alpha.
	var ok_light: bool = false
	if _light_compute != null and "evaluate_light_field_gpu" in _light_compute:
		ok_light = bool(_light_compute.evaluate_light_field_gpu(
			width,
			height,
			{
				"day_of_year": day_of_year,
				"time_of_day": time_of_day,
				"base": float(solar.get("base", 0.008)),
				"contrast": float(solar.get("contrast", 0.992)),
				"fixed_lon": float(fixed_lon),
				"fixed_phi": float(fixed_phi),
				"sim_days": sim_days,
				"relief_strength": float(solar.get("relief_strength", 0.12)),
			},
			_rid("height"),
			_rid("light")
		))
	if not ok_light:
		# If compute fails, default to "daylight" (still GPU rendered; this is just a data fallback).
		var fallback_light := PackedFloat32Array()
		fallback_light.resize(size)
		fallback_light.fill(1.0)
		_update_buffer("light", fallback_light.to_byte_array())

	# Pack data textures directly from GPU buffers (GPU-only).
	var data1_tex: Texture2D = null
	if _data1_pack != null and "update_from_buffers" in _data1_pack:
		data1_tex = _data1_pack.update_from_buffers(width, height, _rid("height"), _rid("temp"), _rid("moist"), _rid("light"))
	var data2_tex: Texture2D = null
	if _data2_pack != null and "update_from_buffers" in _data2_pack:
		data2_tex = _data2_pack.update_from_buffers(width, height, _rid("biome"), _rid("land"), _rid("beach"))

	# Clouds: GPU compute -> buffer -> texture.
	var cloud_tex: Texture2D = null
	var enable_clouds: bool = bool(clouds.get("enabled", true))
	if enable_clouds and _cloud_compute != null and "generate_clouds_gpu" in _cloud_compute:
		var ok_clouds: bool = bool(_cloud_compute.generate_clouds_gpu(
			width,
			height,
			{
				"origin_x": int(clouds.get("origin_x", 0)),
				"origin_y": int(clouds.get("origin_y", 0)),
				"world_period_x": int(clouds.get("world_period_x", width)),
				"world_height": int(clouds.get("world_height", height)),
				"seed": seed_hash ^ int(clouds.get("seed_xor", 0)),
				"sim_days": sim_days,
				"scale": float(clouds.get("scale", 0.020)),
				"wind_x": float(clouds.get("wind_x", 0.15)),
				"wind_y": float(clouds.get("wind_y", 0.05)),
				"coverage": float(clouds.get("coverage", 0.55)),
				"contrast": float(clouds.get("contrast", 1.35)),
			},
			_rid("cloud")
		))
		if ok_clouds and _cloud_pack != null and "update_from_buffer" in _cloud_pack:
			cloud_tex = _cloud_pack.update_from_buffer(width, height, _rid("cloud"))

	# Push textures + uniforms into the renderer.
	if "set_world_data_1_override" in renderer and data1_tex:
		renderer.set_world_data_1_override(data1_tex)
	if "set_world_data_2_override" in renderer and data2_tex:
		renderer.set_world_data_2_override(data2_tex)
	if "set_cloud_texture_override" in renderer:
		renderer.set_cloud_texture_override(cloud_tex)
	if "set_solar_params" in renderer:
		renderer.set_solar_params(day_of_year, time_of_day)
	if "set_fixed_lonlat" in renderer:
		renderer.set_fixed_lonlat(true, fixed_lon, fixed_phi)

	# Ensure the palette texture exists and uniforms are refreshed.
	if "update_ascii_display" in renderer:
		renderer.update_ascii_display(
			width,
			height,
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedInt32Array(),
			PackedInt32Array(),
			PackedByteArray(),
			PackedByteArray(),
			seed_hash,
			false,
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedByteArray(),
			PackedByteArray(),
			PackedByteArray(),
			PackedByteArray(),
			PackedByteArray(),
			PackedInt32Array(),
			float(sea_level),
			"",
			true,
			true
		)

func update_dynamic_layers(
	renderer: Node,
	solar: Dictionary,
	clouds: Dictionary,
	fixed_lon: float,
	fixed_phi: float,
	sea_level: float = 0.0
) -> void:
	# Update only time-dependent GPU layers (light + optional clouds) without re-uploading base fields.
	if renderer == null or _buf_mgr == null:
		return
	_ensure_buffers()

	var size: int = width * height
	var day_of_year: float = float(solar.get("day_of_year", 0.0))
	var time_of_day: float = float(solar.get("time_of_day", 0.0))
	var sim_days: float = float(solar.get("sim_days", 0.0))

	var ok_light: bool = false
	if _light_compute != null and "evaluate_light_field_gpu" in _light_compute:
		ok_light = bool(_light_compute.evaluate_light_field_gpu(
			width,
			height,
			{
				"day_of_year": day_of_year,
				"time_of_day": time_of_day,
				"base": float(solar.get("base", 0.008)),
				"contrast": float(solar.get("contrast", 0.992)),
				"fixed_lon": float(fixed_lon),
				"fixed_phi": float(fixed_phi),
				"sim_days": sim_days,
				"relief_strength": float(solar.get("relief_strength", 0.12)),
			},
			_rid("height"),
			_rid("light")
		))
	if not ok_light:
		var fallback_light := PackedFloat32Array()
		fallback_light.resize(size)
		fallback_light.fill(1.0)
		_update_buffer("light", fallback_light.to_byte_array())

	# Re-pack data1 (height/temp/moist/light) since light changed.
	var data1_tex: Texture2D = null
	if _data1_pack != null and "update_from_buffers" in _data1_pack:
		data1_tex = _data1_pack.update_from_buffers(width, height, _rid("height"), _rid("temp"), _rid("moist"), _rid("light"))

	# Clouds: GPU compute -> buffer -> texture.
	var cloud_tex: Texture2D = null
	var enable_clouds: bool = bool(clouds.get("enabled", true))
	if enable_clouds and _cloud_compute != null and "generate_clouds_gpu" in _cloud_compute:
		var ok_clouds: bool = bool(_cloud_compute.generate_clouds_gpu(
			width,
			height,
			{
				"origin_x": int(clouds.get("origin_x", 0)),
				"origin_y": int(clouds.get("origin_y", 0)),
				"world_period_x": int(clouds.get("world_period_x", width)),
				"world_height": int(clouds.get("world_height", height)),
				"seed": seed_hash ^ int(clouds.get("seed_xor", 0)),
				"sim_days": sim_days,
				"scale": float(clouds.get("scale", 0.020)),
				"wind_x": float(clouds.get("wind_x", 0.15)),
				"wind_y": float(clouds.get("wind_y", 0.05)),
				"coverage": float(clouds.get("coverage", 0.55)),
				"contrast": float(clouds.get("contrast", 1.35)),
			},
			_rid("cloud")
		))
		if ok_clouds and _cloud_pack != null and "update_from_buffer" in _cloud_pack:
			cloud_tex = _cloud_pack.update_from_buffer(width, height, _rid("cloud"))

	# Push textures + uniforms into the renderer.
	if "set_world_data_1_override" in renderer and data1_tex:
		renderer.set_world_data_1_override(data1_tex)
	if "set_cloud_texture_override" in renderer:
		renderer.set_cloud_texture_override(cloud_tex)
	if "set_solar_params" in renderer:
		renderer.set_solar_params(day_of_year, time_of_day)
	if "set_fixed_lonlat" in renderer:
		renderer.set_fixed_lonlat(true, fixed_lon, fixed_phi)
	# Keep sea level consistent in the shader uniforms (noop most of the time).
	if "update_ascii_display" in renderer:
		renderer.update_ascii_display(
			width,
			height,
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedInt32Array(),
			PackedInt32Array(),
			PackedByteArray(),
			PackedByteArray(),
			seed_hash,
			false,
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedByteArray(),
			PackedByteArray(),
			PackedByteArray(),
			PackedByteArray(),
			PackedByteArray(),
			PackedInt32Array(),
			float(sea_level),
			"",
			true,
			true
		)
