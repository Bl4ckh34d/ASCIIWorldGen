extends RefCounted
class_name GpuMapView
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

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

func _cleanup_if_supported(obj: Variant) -> void:
	if obj == null:
		return
	if obj.has_method("cleanup"):
		obj.call("cleanup")

func configure(prefix_value: String, w: int, h: int, seed_value: int) -> void:
	cleanup()
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
	_cleanup_if_supported(_data1_pack)
	_cleanup_if_supported(_data2_pack)
	_cleanup_if_supported(_cloud_pack)
	_cleanup_if_supported(_light_compute)
	_cleanup_if_supported(_cloud_compute)
	_cleanup_if_supported(_buf_mgr)
	_data1_pack = null
	_data2_pack = null
	_cloud_pack = null
	_light_compute = null
	_cloud_compute = null
	_buf_mgr = null
	_data1_tex = null
	_data2_tex = null
	_cloud_tex = null
	width = 0
	height = 0

func _rid(name: String) -> RID:
	if _buf_mgr == null:
		return RID()
	return _buf_mgr.get_buffer("%s_%s" % [prefix, name])

func _update_buffer(name: String, bytes: PackedByteArray, offset_bytes: int = 0) -> void:
	if _buf_mgr == null:
		return
	_buf_mgr.update_buffer("%s_%s" % [prefix, name], bytes, offset_bytes)

func _extract_fields(fields: Dictionary) -> Dictionary:
	var size: int = width * height
	var height_raw: PackedFloat32Array = fields.get("height_raw", PackedFloat32Array())
	var temp: PackedFloat32Array = fields.get("temp", PackedFloat32Array())
	var moist: PackedFloat32Array = fields.get("moist", PackedFloat32Array())
	var biome: PackedInt32Array = fields.get("biome", PackedInt32Array())
	var land: PackedInt32Array = fields.get("land", PackedInt32Array())
	var beach: PackedInt32Array = fields.get("beach", PackedInt32Array())
	if height_raw.size() != size:
		return {}
	if temp.size() != size:
		return {}
	if moist.size() != size:
		return {}
	if biome.size() != size:
		return {}
	if land.size() != size:
		return {}
	if beach.size() != size:
		return {}
	return {
		"height_raw": height_raw,
		"temp": temp,
		"moist": moist,
		"biome": biome,
		"land": land,
		"beach": beach,
	}

func _upload_row_f32(name: String, source: PackedFloat32Array, row_y: int) -> void:
	if row_y < 0 or row_y >= height:
		return
	var row := PackedFloat32Array()
	row.resize(width)
	var base: int = row_y * width
	for x in range(width):
		row[x] = source[base + x]
	_update_buffer(name, row.to_byte_array(), base * 4)

func _upload_row_i32(name: String, source: PackedInt32Array, row_y: int) -> void:
	if row_y < 0 or row_y >= height:
		return
	var row := PackedInt32Array()
	row.resize(width)
	var base: int = row_y * width
	for x in range(width):
		row[x] = source[base + x]
	_update_buffer(name, row.to_byte_array(), base * 4)

func _upload_col_f32(name: String, source: PackedFloat32Array, col_x: int, skip_row: int = -1) -> void:
	if col_x < 0 or col_x >= width:
		return
	var one := PackedFloat32Array()
	one.resize(1)
	for y in range(height):
		if y == skip_row:
			continue
		var idx: int = col_x + y * width
		one[0] = source[idx]
		_update_buffer(name, one.to_byte_array(), idx * 4)

func _upload_col_i32(name: String, source: PackedInt32Array, col_x: int, skip_row: int = -1) -> void:
	if col_x < 0 or col_x >= width:
		return
	var one := PackedInt32Array()
	one.resize(1)
	for y in range(height):
		if y == skip_row:
			continue
		var idx: int = col_x + y * width
		one[0] = source[idx]
		_update_buffer(name, one.to_byte_array(), idx * 4)

func _update_base_fields_full(field_data: Dictionary) -> void:
	var height_raw: PackedFloat32Array = field_data.get("height_raw", PackedFloat32Array())
	var temp: PackedFloat32Array = field_data.get("temp", PackedFloat32Array())
	var moist: PackedFloat32Array = field_data.get("moist", PackedFloat32Array())
	var biome: PackedInt32Array = field_data.get("biome", PackedInt32Array())
	var land: PackedInt32Array = field_data.get("land", PackedInt32Array())
	var beach: PackedInt32Array = field_data.get("beach", PackedInt32Array())
	_update_buffer("height", height_raw.to_byte_array())
	_update_buffer("temp", temp.to_byte_array())
	_update_buffer("moist", moist.to_byte_array())
	_update_buffer("biome", biome.to_byte_array())
	_update_buffer("land", land.to_byte_array())
	_update_buffer("beach", beach.to_byte_array())

func _update_base_fields_partial(field_data: Dictionary, dx: int, dy: int) -> bool:
	if abs(dx) > 1 or abs(dy) > 1:
		return false
	var height_raw: PackedFloat32Array = field_data.get("height_raw", PackedFloat32Array())
	var temp: PackedFloat32Array = field_data.get("temp", PackedFloat32Array())
	var moist: PackedFloat32Array = field_data.get("moist", PackedFloat32Array())
	var biome: PackedInt32Array = field_data.get("biome", PackedInt32Array())
	var land: PackedInt32Array = field_data.get("land", PackedInt32Array())
	var beach: PackedInt32Array = field_data.get("beach", PackedInt32Array())
	if dx == 0 and dy == 0:
		return true

	var edge_y: int = -1
	if dy > 0:
		edge_y = height - 1
	elif dy < 0:
		edge_y = 0
	if edge_y >= 0:
		_upload_row_f32("height", height_raw, edge_y)
		_upload_row_f32("temp", temp, edge_y)
		_upload_row_f32("moist", moist, edge_y)
		_upload_row_i32("biome", biome, edge_y)
		_upload_row_i32("land", land, edge_y)
		_upload_row_i32("beach", beach, edge_y)

	var edge_x: int = -1
	if dx > 0:
		edge_x = width - 1
	elif dx < 0:
		edge_x = 0
	if edge_x >= 0:
		# If we already updated an edge row, skip the shared corner cell in column upload.
		_upload_col_f32("height", height_raw, edge_x, edge_y)
		_upload_col_f32("temp", temp, edge_x, edge_y)
		_upload_col_f32("moist", moist, edge_x, edge_y)
		_upload_col_i32("biome", biome, edge_x, edge_y)
		_upload_col_i32("land", land, edge_x, edge_y)
		_upload_col_i32("beach", beach, edge_x, edge_y)
	return true

func _draw_with_current_buffers(
	renderer: Node,
	solar: Dictionary,
	clouds: Dictionary,
	fixed_lon: float,
	fixed_phi: float,
	sea_level: float = 0.0,
	include_data2: bool = true
) -> void:
	if renderer == null or _buf_mgr == null:
		return
	var size: int = width * height
	var day_of_year: float = float(solar.get("day_of_year", 0.0))
	var time_of_day: float = float(solar.get("time_of_day", 0.0))
	var sim_days: float = float(solar.get("sim_days", 0.0))

	var ok_light: bool = false
	if _light_compute != null and _light_compute.has_method("evaluate_light_field_gpu"):
		ok_light = VariantCasts.to_bool(_light_compute.evaluate_light_field_gpu(
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

	var data1_tex: Texture2D = null
	if _data1_pack != null and _data1_pack.has_method("update_from_buffers"):
		data1_tex = _data1_pack.update_from_buffers(width, height, _rid("height"), _rid("temp"), _rid("moist"), _rid("light"))
	var data2_tex: Texture2D = null
	if include_data2 and _data2_pack != null and _data2_pack.has_method("update_from_buffers"):
		data2_tex = _data2_pack.update_from_buffers(width, height, _rid("biome"), _rid("land"), _rid("beach"))

	var cloud_tex: Texture2D = null
	var enable_clouds: bool = VariantCasts.to_bool(clouds.get("enabled", true))
	if enable_clouds and _cloud_compute != null and _cloud_compute.has_method("generate_clouds_gpu"):
		var ok_clouds: bool = VariantCasts.to_bool(_cloud_compute.generate_clouds_gpu(
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
		if ok_clouds and _cloud_pack != null and _cloud_pack.has_method("update_from_buffer"):
			cloud_tex = _cloud_pack.update_from_buffer(width, height, _rid("cloud"))

	if renderer.has_method("set_world_data_1_override") and data1_tex:
		renderer.set_world_data_1_override(data1_tex)
	if include_data2 and renderer.has_method("set_world_data_2_override") and data2_tex:
		renderer.set_world_data_2_override(data2_tex)
	if renderer.has_method("set_cloud_texture_override"):
		renderer.set_cloud_texture_override(cloud_tex)
	if renderer.has_method("set_solar_params"):
		renderer.set_solar_params(day_of_year, time_of_day)
	if renderer.has_method("set_fixed_lonlat"):
		renderer.set_fixed_lonlat(true, fixed_lon, fixed_phi)

	if renderer.has_method("update_ascii_display"):
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
	var field_data: Dictionary = _extract_fields(fields)
	if field_data.is_empty():
		return
	_update_base_fields_full(field_data)
	_draw_with_current_buffers(renderer, solar, clouds, fixed_lon, fixed_phi, sea_level, true)

func update_and_draw_partial(
	renderer: Node,
	fields: Dictionary,
	patch: Dictionary,
	solar: Dictionary,
	clouds: Dictionary,
	fixed_lon: float,
	fixed_phi: float,
	sea_level: float = 0.0
) -> bool:
	if renderer == null or _buf_mgr == null:
		return false
	_ensure_buffers()
	var field_data: Dictionary = _extract_fields(fields)
	if field_data.is_empty():
		return false
	var dx: int = int(patch.get("dx", 0))
	var dy: int = int(patch.get("dy", 0))
	if not _update_base_fields_partial(field_data, dx, dy):
		return false
	_draw_with_current_buffers(renderer, solar, clouds, fixed_lon, fixed_phi, sea_level, true)
	return true

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
	if _light_compute != null and _light_compute.has_method("evaluate_light_field_gpu"):
		ok_light = VariantCasts.to_bool(_light_compute.evaluate_light_field_gpu(
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
	if _data1_pack != null and _data1_pack.has_method("update_from_buffers"):
		data1_tex = _data1_pack.update_from_buffers(width, height, _rid("height"), _rid("temp"), _rid("moist"), _rid("light"))

	# Clouds: GPU compute -> buffer -> texture.
	var cloud_tex: Texture2D = null
	var enable_clouds: bool = VariantCasts.to_bool(clouds.get("enabled", true))
	if enable_clouds and _cloud_compute != null and _cloud_compute.has_method("generate_clouds_gpu"):
		var ok_clouds: bool = VariantCasts.to_bool(_cloud_compute.generate_clouds_gpu(
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
		if ok_clouds and _cloud_pack != null and _cloud_pack.has_method("update_from_buffer"):
			cloud_tex = _cloud_pack.update_from_buffer(width, height, _rid("cloud"))

	# Push textures + uniforms into the renderer.
	if renderer.has_method("set_world_data_1_override") and data1_tex:
		renderer.set_world_data_1_override(data1_tex)
	if renderer.has_method("set_cloud_texture_override"):
		renderer.set_cloud_texture_override(cloud_tex)
	if renderer.has_method("set_solar_params"):
		renderer.set_solar_params(day_of_year, time_of_day)
	if renderer.has_method("set_fixed_lonlat"):
		renderer.set_fixed_lonlat(true, fixed_lon, fixed_phi)
	# Keep sea level consistent in the shader uniforms (noop most of the time).
	if renderer.has_method("update_ascii_display"):
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
