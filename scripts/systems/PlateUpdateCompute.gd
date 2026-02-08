# File: res://scripts/systems/PlateUpdateCompute.gd
extends RefCounted

## GPU Plate boundary update: uplift/ridge/transform on boundary cells.
## Inputs: height (f32), cell_plate_id (i32), boundary_mask (i32), plate_vel_u/v (f32 per-plate)
## Output: updated height (f32)

var PLATE_SHADER_FILE: RDShaderFile = load("res://shaders/plate_update.glsl")
var PLATE_LABEL_SHADER_FILE: RDShaderFile = load("res://shaders/plate_label.glsl")
var PLATE_BOUNDARY_SHADER_FILE: RDShaderFile = load("res://shaders/plate_boundary_mask.glsl")

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _label_shader: RID
var _label_pipeline: RID
var _bnd_shader: RID
var _bnd_pipeline: RID

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
	if chosen_version == null:
		return null
	return file.get_spirv(chosen_version)

func _ensure() -> void:
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	if not _shader.is_valid():
		var spirv: RDShaderSPIRV = _get_spirv(PLATE_SHADER_FILE)
		if spirv == null:
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	if not _pipeline.is_valid() and _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)
	# label pipeline
	if not _label_shader.is_valid():
		var s2: RDShaderSPIRV = _get_spirv(PLATE_LABEL_SHADER_FILE)
		if s2 != null:
			_label_shader = _rd.shader_create_from_spirv(s2)
	if not _label_pipeline.is_valid() and _label_shader.is_valid():
		_label_pipeline = _rd.compute_pipeline_create(_label_shader)
	# boundary pipeline
	if not _bnd_shader.is_valid():
		var s3: RDShaderSPIRV = _get_spirv(PLATE_BOUNDARY_SHADER_FILE)
		if s3 != null:
			_bnd_shader = _rd.shader_create_from_spirv(s3)
	if not _bnd_pipeline.is_valid() and _bnd_shader.is_valid():
		_bnd_pipeline = _rd.compute_pipeline_create(_bnd_shader)

func build_voronoi_and_boundary_gpu_buffers(
		w: int,
		h: int,
		site_x: PackedInt32Array,
		site_y: PackedInt32Array,
		out_plate_id_buf: RID,
		out_boundary_buf: RID,
		site_weight: PackedFloat32Array = PackedFloat32Array(),
		rng_seed: int = 0,
		warp_strength_cells: float = 8.5,
		warp_frequency: float = 0.013,
		lat_anisotropy: float = 1.2
	) -> bool:
	_ensure()
	if not _label_pipeline.is_valid() or not _bnd_pipeline.is_valid():
		return false
	if not out_plate_id_buf.is_valid() or not out_boundary_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size <= 0:
		return false
	var weights: PackedFloat32Array = site_weight
	if weights.size() != site_x.size():
		weights = PackedFloat32Array()
		weights.resize(site_x.size())
		weights.fill(1.0)
	var buf_sx := _rd.storage_buffer_create(site_x.to_byte_array().size(), site_x.to_byte_array())
	var buf_sy := _rd.storage_buffer_create(site_y.to_byte_array().size(), site_y.to_byte_array())
	var buf_sw := _rd.storage_buffer_create(weights.to_byte_array().size(), weights.to_byte_array())
	# label dispatch
	var uniforms1: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_sx); uniforms1.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_sy); uniforms1.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_sw); uniforms1.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(out_plate_id_buf); uniforms1.append(u)
	var u_set1 := _rd.uniform_set_create(uniforms1, _label_shader, 0)
	var pc1 := PackedByteArray()
	var ints1 := PackedInt32Array([w, h, site_x.size(), rng_seed])
	var floats1 := PackedFloat32Array([
		warp_strength_cells,
		warp_frequency,
		lat_anisotropy,
		0.0
	])
	pc1.append_array(ints1.to_byte_array())
	pc1.append_array(floats1.to_byte_array())
	var pad1 := (16 - (pc1.size() % 16)) % 16
	if pad1 > 0:
		var zeros1 := PackedByteArray(); zeros1.resize(pad1)
		pc1.append_array(zeros1)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _label_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set1, 0)
	_rd.compute_list_set_push_constant(cl, pc1, pc1.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	# boundary dispatch
	var uniforms2: Array = []
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(out_plate_id_buf); uniforms2.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(out_boundary_buf); uniforms2.append(u)
	var u_set2 := _rd.uniform_set_create(uniforms2, _bnd_shader, 0)
	var pc2 := PackedByteArray(); var ints2 := PackedInt32Array([w, h]); pc2.append_array(ints2.to_byte_array())
	var pad2 := (16 - (pc2.size() % 16)) % 16
	if pad2 > 0:
		var zeros2 := PackedByteArray(); zeros2.resize(pad2)
		pc2.append_array(zeros2)
	cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _bnd_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set2, 0)
	_rd.compute_list_set_push_constant(cl, pc2, pc2.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set1)
	_rd.free_rid(u_set2)
	_rd.free_rid(buf_sx)
	_rd.free_rid(buf_sy)
	_rd.free_rid(buf_sw)
	return true

func apply_gpu_buffers(w: int, h: int, height_in_buf: RID, plate_id_buf: RID, boundary_buf: RID, plate_vel_u: PackedFloat32Array, plate_vel_v: PackedFloat32Array, plate_buoyancy: PackedFloat32Array, dt_days: float, rates: Dictionary, boundary_band_cells: int, seed_phase: float, height_out_buf: RID) -> bool:
	_ensure()
	if not _pipeline.is_valid():
		return false
	if not height_in_buf.is_valid() or not plate_id_buf.is_valid() or not boundary_buf.is_valid() or not height_out_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	var buf_pu := _rd.storage_buffer_create(plate_vel_u.to_byte_array().size(), plate_vel_u.to_byte_array())
	var buf_pv := _rd.storage_buffer_create(plate_vel_v.to_byte_array().size(), plate_vel_v.to_byte_array())
	var buoy: PackedFloat32Array = plate_buoyancy
	if buoy.size() != plate_vel_u.size():
		buoy = PackedFloat32Array()
		buoy.resize(plate_vel_u.size())
		buoy.fill(0.5)
	var buf_pb := _rd.storage_buffer_create(buoy.to_byte_array().size(), buoy.to_byte_array())
	var uniforms: Array = []
	var u: RDUniform
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(height_in_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(plate_id_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(boundary_buf); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_pu); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_pv); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_pb); uniforms.append(u)
	u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(height_out_buf); uniforms.append(u)
	var u_set := _rd.uniform_set_create(uniforms, _shader, 0)
	var upl: float = float(rates.get("uplift_rate_per_day", 0.002))
	var ridge: float = float(rates.get("ridge_rate_per_day", 0.0008))
	var rough: float = float(rates.get("transform_roughness_per_day", 0.0004))
	var subduct: float = float(rates.get("subduction_rate_per_day", 0.0016))
	var trench: float = float(rates.get("trench_rate_per_day", 0.0012))
	var drift: float = float(rates.get("drift_cells_per_day", 0.02))
	var sea_level: float = float(rates.get("sea_level", 0.0))
	var num_plates: int = int(max(0, plate_vel_u.size()))
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, num_plates, max(0, boundary_band_cells)])
	var floats := PackedFloat32Array([dt_days, upl, ridge, rough, subduct, trench, drift, seed_phase, sea_level])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	_rd.free_rid(buf_pu)
	_rd.free_rid(buf_pv)
	_rd.free_rid(buf_pb)
	return true
