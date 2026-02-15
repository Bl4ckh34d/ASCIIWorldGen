extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

const ComputeShaderBase = preload("res://scripts/systems/ComputeShaderBase.gd")
const GPUBufferHelper = preload("res://scripts/systems/GPUBufferHelper.gd")

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipeline: RID = RID()
var _uniform_set: RID = RID()
var _buffers: Array[RID] = []

func _ensure() -> bool:
	var state: Dictionary = ComputeShaderBase.ensure_rd_and_pipeline(
		_rd,
		_shader,
		_pipeline,
		"res://shaders/society/trade_flow_tick.glsl",
		"trade_flow_tick"
	)
	_rd = state.get("rd", null)
	_shader = state.get("shader", RID())
	_pipeline = state.get("pipeline", RID())
	return VariantCasts.to_bool(state.get("ok", false))

func bind_buffers(neighbor_idx: RID, neighbor_cap: RID, stock_in: RID, stock_out: RID) -> bool:
	if not _ensure():
		return false
	var arr: Array[RID] = [neighbor_idx, neighbor_cap, stock_in, stock_out]
	for r in arr:
		if not (r is RID and r.is_valid()):
			push_error("TradeFlowTickCompute: missing buffer binding.")
			return false
	_buffers = arr
	ComputeShaderBase.free_uniform_set_if_alive(_rd, _uniform_set)
	_uniform_set = RID()
	_uniform_set = GPUBufferHelper.create_uniform_buffer_set(_rd, _shader, _buffers)
	return _uniform_set.is_valid()

func dispatch(settlement_count: int, commodity_count: int, max_neighbors: int, abs_day: int, dt_days: float) -> bool:
	if not _ensure():
		return false
	var total: int = max(0, int(settlement_count) * int(commodity_count))
	if total <= 0:
		return true
	if not _uniform_set.is_valid():
		push_error("TradeFlowTickCompute: uniform set not bound.")
		return false
	var pc := PackedByteArray()
	var ints := PackedInt32Array([int(settlement_count), int(commodity_count), int(max_neighbors), int(abs_day)])
	pc.append_array(ints.to_byte_array())
	var floats := PackedFloat32Array([float(dt_days), 0.0, 0.0, 0.0])
	pc.append_array(floats.to_byte_array())
	if not ComputeShaderBase.validate_push_constant_size(pc, 32, "TradeFlowTickCompute"):
		return false

	var groups_x: int = int(ceil(float(total) / 64.0))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, groups_x, 1, 1)
	_rd.compute_list_end()
	ComputeShaderBase.submit_if_local(_rd)
	return true

func cleanup() -> void:
	if _rd != null:
		ComputeShaderBase.free_uniform_set_if_alive(_rd, _uniform_set)
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)
		if _shader.is_valid():
			_rd.free_rid(_shader)
	_uniform_set = RID()
	_pipeline = RID()
	_shader = RID()


