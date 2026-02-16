# File: res://scripts/systems/PlateUpdateCompute.gd
extends RefCounted
const VariantCastsUtil = preload("res://scripts/core/VariantCasts.gd")

## GPU Plate boundary update: uplift/ridge/transform on boundary cells.
## Inputs: height (f32), cell_plate_id (i32), boundary_mask (i32), plate_vel_u/v (f32 per-plate)
## Output: updated height (f32)

const ComputeShaderBaseUtil = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferManager = preload("res://scripts/systems/GPUBufferManager.gd")

const PLATE_SHADER_PATH: String = "res://shaders/plate_update.glsl"
const PLATE_LABEL_SHADER_PATH: String = "res://shaders/plate_label.glsl"
const PLATE_BOUNDARY_SHADER_PATH: String = "res://shaders/plate_boundary_mask.glsl"

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _label_shader: RID
var _label_pipeline: RID
var _bnd_shader: RID
var _bnd_pipeline: RID
var _buf_mgr: GPUBufferManager = null

func _init() -> void:
	_buf_mgr = GPUBufferManager.new()

func _ensure() -> bool:
	var state_update: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		PLATE_SHADER_PATH,
		"plate_update"
	)
	_rd = state_update.get("rd", null)
	_shader = state_update.get("shader", RID())
	_pipeline = state_update.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(state_update.get("ok", false)):
		return false

	var state_label: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_label_shader,
		_label_pipeline,
		PLATE_LABEL_SHADER_PATH,
		"plate_label"
	)
	_label_shader = state_label.get("shader", RID())
	_label_pipeline = state_label.get("pipeline", RID())
	if not VariantCastsUtil.to_bool(state_label.get("ok", false)):
		return false

	var state_boundary: Dictionary = ComputeShaderBaseUtil.ensure_rd_and_pipeline(
		_rd,
		_bnd_shader,
		_bnd_pipeline,
		PLATE_BOUNDARY_SHADER_PATH,
		"plate_boundary_mask"
	)
	_bnd_shader = state_boundary.get("shader", RID())
	_bnd_pipeline = state_boundary.get("pipeline", RID())
	return VariantCastsUtil.to_bool(state_boundary.get("ok", false))

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
	if not _ensure():
		return false
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
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	var buf_sx: RID = _buf_mgr.ensure_buffer("plate_site_x", site_x.to_byte_array().size(), site_x.to_byte_array())
	var buf_sy: RID = _buf_mgr.ensure_buffer("plate_site_y", site_y.to_byte_array().size(), site_y.to_byte_array())
	var buf_sw: RID = _buf_mgr.ensure_buffer("plate_site_w", weights.to_byte_array().size(), weights.to_byte_array())
	if not (buf_sx.is_valid() and buf_sy.is_valid() and buf_sw.is_valid()):
		return false
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
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc1, 32, "PlateUpdateCompute.label"):
		_rd.free_rid(u_set1)
		return false
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
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc2, 16, "PlateUpdateCompute.boundary"):
		_rd.free_rid(u_set1)
		_rd.free_rid(u_set2)
		return false
	cl = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _bnd_pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set2, 0)
	_rd.compute_list_set_push_constant(cl, pc2, pc2.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set1)
	_rd.free_rid(u_set2)
	return true

func apply_gpu_buffers(w: int, h: int, height_in_buf: RID, plate_id_buf: RID, boundary_buf: RID, plate_vel_u: PackedFloat32Array, plate_vel_v: PackedFloat32Array, plate_buoyancy: PackedFloat32Array, dt_days: float, rates: Dictionary, boundary_band_cells: int, seed_phase: float, height_out_buf: RID) -> bool:
	if not _ensure():
		return false
	if not _pipeline.is_valid():
		return false
	if not height_in_buf.is_valid() or not plate_id_buf.is_valid() or not boundary_buf.is_valid() or not height_out_buf.is_valid():
		return false
	var size: int = max(0, w * h)
	if size == 0:
		return false
	if _buf_mgr == null:
		_buf_mgr = GPUBufferManager.new()
	var buf_pu: RID = _buf_mgr.ensure_buffer("plate_vel_u", plate_vel_u.to_byte_array().size(), plate_vel_u.to_byte_array())
	var buf_pv: RID = _buf_mgr.ensure_buffer("plate_vel_v", plate_vel_v.to_byte_array().size(), plate_vel_v.to_byte_array())
	var buoy: PackedFloat32Array = plate_buoyancy
	if buoy.size() != plate_vel_u.size():
		buoy = PackedFloat32Array()
		buoy.resize(plate_vel_u.size())
		buoy.fill(0.5)
	var buf_pb: RID = _buf_mgr.ensure_buffer("plate_buoyancy", buoy.to_byte_array().size(), buoy.to_byte_array())
	if not (buf_pu.is_valid() and buf_pv.is_valid() and buf_pb.is_valid()):
		return false
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
	var max_delta: float = float(rates.get("max_boundary_delta_per_day", 0.08))
	var divergence_response: float = float(rates.get("divergence_response", 1.0))
	var num_plates: int = int(max(0, plate_vel_u.size()))
	var pc := PackedByteArray()
	var ints := PackedInt32Array([w, h, num_plates, max(0, boundary_band_cells)])
	var floats := PackedFloat32Array([
		max(0.0, dt_days),
		clamp(upl, 0.0, 0.05),
		clamp(ridge, 0.0, 0.05),
		clamp(rough, 0.0, 0.05),
		clamp(subduct, 0.0, 0.05),
		clamp(trench, 0.0, 0.05),
		clamp(drift, 0.0, 0.2),
		seed_phase,
		sea_level,
		clamp(max_delta, 0.001, 0.5),
		clamp(divergence_response, 0.2, 2.5),
	])
	pc.append_array(ints.to_byte_array())
	pc.append_array(floats.to_byte_array())
	var pad := (16 - (pc.size() % 16)) % 16
	if pad > 0:
		var zeros := PackedByteArray(); zeros.resize(pad)
		pc.append_array(zeros)
	if not ComputeShaderBaseUtil.validate_push_constant_size(pc, 64, "PlateUpdateCompute.apply"):
		_rd.free_rid(u_set)
		return false
	var gx: int = int(ceil(float(w) / 16.0))
	var gy: int = int(ceil(float(h) / 16.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, u_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, gx, gy, 1)
	_rd.compute_list_end()
	_rd.free_rid(u_set)
	return true

func cleanup() -> void:
	if _buf_mgr != null:
		_buf_mgr.cleanup()
	ComputeShaderBaseUtil.free_rids(_rd, [
		_pipeline, _shader,
		_label_pipeline, _label_shader,
		_bnd_pipeline, _bnd_shader,
	])
	_pipeline = RID()
	_shader = RID()
	_label_pipeline = RID()
	_label_shader = RID()
	_bnd_pipeline = RID()
	_bnd_shader = RID()
