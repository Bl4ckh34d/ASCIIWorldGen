# File: res://scripts/systems/RiverPostCompute.gd
extends RefCounted

var DELTA_SHADER_FILE: RDShaderFile = load("res://shaders/river_delta.glsl")

var _rd: RenderingDevice
var _delta_shader: RID
var _delta_pipeline: RID
var _broken: bool = false

func _get_spirv(file: RDShaderFile) -> RDShaderSPIRV:
	if file == null:
		return null
	var versions: Array = file.get_version_list()
	if versions.is_empty():
		return null
	var chosen_version = versions[0]
	for v in versions:
		if String(v) == "vulkan":
			chosen_version = v
			break
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if not _delta_shader.is_valid() and not _broken:
		var s: RDShaderSPIRV = _get_spirv(DELTA_SHADER_FILE)
		if s == null:
			_broken = true
			return
		var sh := _rd.shader_create_from_spirv(s)
		if sh.is_valid():
			_delta_shader = sh
		else:
			_broken = true
	if not _delta_pipeline.is_valid() and _delta_shader.is_valid():
		_delta_pipeline = _rd.compute_pipeline_create(_delta_shader)

func widen_deltas(w: int, h: int, river_mask: PackedByteArray, is_land: PackedByteArray, water_distance: PackedFloat32Array, max_shore_dist: float) -> PackedByteArray:
	_ensure()
	if not _delta_pipeline.is_valid() or _broken:
		# CPU fallback: single-pass 3x3 dilation within near-shore band on land
		var fallback_size: int = max(0, w * h)
		var fallback_out := PackedByteArray(); fallback_out.resize(fallback_size)
		for y in range(h):
			for x in range(w):
				var i: int = x + y * w
				var rv: bool = (i < river_mask.size() and river_mask[i] != 0)
				if rv:
					fallback_out[i] = 1
					continue
				var land_ok: bool = (i < is_land.size() and is_land[i] != 0)
				var near_coast: bool = (i < water_distance.size() and water_distance[i] <= max_shore_dist)
				if not land_ok or not near_coast:
					fallback_out[i] = 0
					continue
				var grow: bool = false
				for dy in range(-1, 2):
					if grow: break
					for dx in range(-1, 2):
						if dx == 0 and dy == 0: continue
						var nx: int = x + dx
						var ny: int = y + dy
						if nx < 0 or ny < 0 or nx >= w or ny >= h:
							continue
						var j: int = nx + ny * w
						if j < river_mask.size() and river_mask[j] != 0:
							grow = true
							break
				fallback_out[i] = 1 if grow else 0
		return fallback_out
	var size: int = max(0, w * h)
	var river_u32 := PackedInt32Array(); river_u32.resize(size)
	var land_u32 := PackedInt32Array(); land_u32.resize(size)
	for i in range(size):
		river_u32[i] = 1 if (i < river_mask.size() and river_mask[i] != 0) else 0
		land_u32[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
	var buf_r_in := _rd.storage_buffer_create(river_u32.to_byte_array().size(), river_u32.to_byte_array())
	var buf_land := _rd.storage_buffer_create(land_u32.to_byte_array().size(), land_u32.to_byte_array())
	var buf_dist := _rd.storage_buffer_create(water_distance.to_byte_array().size(), water_distance.to_byte_array())
	var river_out := PackedInt32Array(); river_out.resize(size)
	var buf_r_out := _rd.storage_buffer_create(river_out.to_byte_array().size(), river_out.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_r_in); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_dist); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_r_out); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _delta_shader, 0)
	var pc := PackedByteArray(); var ints := PackedInt32Array([w, h]); var floats := PackedFloat32Array([max_shore_dist]);
	pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _delta_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	var bytes := _rd.buffer_get_data(buf_r_out)
	var out_u32: PackedInt32Array = bytes.to_int32_array()
	var out_b := PackedByteArray(); out_b.resize(size)
	for k in range(size): out_b[k] = 1 if (k < out_u32.size() and out_u32[k] != 0) else 0
	_rd.free_rid(u_set)
	_rd.free_rid(buf_r_in)
	_rd.free_rid(buf_land)
	_rd.free_rid(buf_dist)
	_rd.free_rid(buf_r_out)
	return out_b
