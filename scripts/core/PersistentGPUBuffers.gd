# File: res://scripts/core/PersistentGPUBuffers.gd
extends RefCounted

## Persistent GPU buffer management system
## Keeps all simulation data on GPU, eliminates constant CPU↔GPU transfers

var _rd: RenderingDevice
var _buffers: Dictionary = {}
var _buffer_sizes: Dictionary = {}
var _width: int = 0
var _height: int = 0

# Buffer types
enum BufferType {
	HEIGHT,           # PackedFloat32Array - terrain height
	IS_LAND,         # PackedInt32Array - land mask (0/1 as uint)
	DISTANCE,        # PackedFloat32Array - distance to coast
	TEMPERATURE,     # PackedFloat32Array - climate temperature
	MOISTURE,        # PackedFloat32Array - climate moisture  
	PRECIP,          # PackedFloat32Array - precipitation
	WIND_U,          # PackedFloat32Array - wind U component
	WIND_V,          # PackedFloat32Array - wind V component
	CLOUD_COV,       # PackedFloat32Array - cloud coverage
	BIOME_ID,        # PackedInt32Array - biome classification
	LAVA,            # PackedInt32Array - lava mask (0/1 as uint)
	RIVER,           # PackedInt32Array - river mask (0/1 as uint)
	LAKE,            # PackedInt32Array - lake mask (0/1 as uint)
	LAKE_ID,         # PackedInt32Array - lake label IDs
	LIGHT,           # PackedFloat32Array - day/night lighting
	TURQUOISE_WATER, # PackedInt32Array - turquoise water mask
	BEACH,           # PackedInt32Array - beach mask
	FLOW_DIR,        # PackedInt32Array - flow direction
	FLOW_ACCUM,      # PackedFloat32Array - flow accumulation
}

# Buffer metadata
var _buffer_info: Dictionary = {
	BufferType.HEIGHT: {"size": 4, "type": "f32"},
	BufferType.IS_LAND: {"size": 4, "type": "u32"},
	BufferType.DISTANCE: {"size": 4, "type": "f32"},
	BufferType.TEMPERATURE: {"size": 4, "type": "f32"},
	BufferType.MOISTURE: {"size": 4, "type": "f32"},
	BufferType.PRECIP: {"size": 4, "type": "f32"},
	BufferType.WIND_U: {"size": 4, "type": "f32"},
	BufferType.WIND_V: {"size": 4, "type": "f32"},
	BufferType.CLOUD_COV: {"size": 4, "type": "f32"},
	BufferType.BIOME_ID: {"size": 4, "type": "u32"},
	BufferType.LAVA: {"size": 4, "type": "u32"},
	BufferType.RIVER: {"size": 4, "type": "u32"},
	BufferType.LAKE: {"size": 4, "type": "u32"},
	BufferType.LAKE_ID: {"size": 4, "type": "u32"},
	BufferType.LIGHT: {"size": 4, "type": "f32"},
	BufferType.TURQUOISE_WATER: {"size": 4, "type": "u32"},
	BufferType.BEACH: {"size": 4, "type": "u32"},
	BufferType.FLOW_DIR: {"size": 4, "type": "u32"},
	BufferType.FLOW_ACCUM: {"size": 4, "type": "f32"},
}

func initialize(rd: RenderingDevice, width: int, height: int) -> void:
	_rd = rd
	_width = width
	_height = height
	
	var cell_count: int = width * height
	
	# Allocate all persistent buffers
	for buffer_type in BufferType.values():
		var info = _buffer_info[buffer_type]
		var byte_size: int = cell_count * info["size"]
		
		# Create zero-initialized buffer
		var zero_data := PackedByteArray()
		zero_data.resize(byte_size)
		zero_data.fill(0)
		
		var buffer_rid: RID = _rd.storage_buffer_create(byte_size, zero_data)
		_buffers[buffer_type] = buffer_rid
		_buffer_sizes[buffer_type] = byte_size
		
		print("PersistentGPUBuffers: Created buffer ", BufferType.keys()[buffer_type], " (", byte_size, " bytes)")

func get_buffer(buffer_type: BufferType) -> RID:
	return _buffers.get(buffer_type, RID())

func has_buffer(buffer_type: BufferType) -> bool:
	return _buffers.has(buffer_type) and _buffers[buffer_type].is_valid()

func upload_data(buffer_type: BufferType, data: PackedFloat32Array) -> void:
	if not has_buffer(buffer_type):
		return
	
	var buffer_rid: RID = _buffers[buffer_type]
	var byte_data: PackedByteArray = data.to_byte_array()
	
	# Ensure size matches
	if byte_data.size() != _buffer_sizes[buffer_type]:
		print("PersistentGPUBuffers: Size mismatch for ", BufferType.keys()[buffer_type])
		return
	
	# Update buffer data
	_rd.buffer_update(buffer_rid, 0, byte_data.size(), byte_data)

func upload_data_u32(buffer_type: BufferType, data: PackedInt32Array) -> void:
	if not has_buffer(buffer_type):
		return
	
	var buffer_rid: RID = _buffers[buffer_type]
	var byte_data: PackedByteArray = data.to_byte_array()
	
	# Ensure size matches
	if byte_data.size() != _buffer_sizes[buffer_type]:
		print("PersistentGPUBuffers: Size mismatch for ", BufferType.keys()[buffer_type])
		return
	
	# Update buffer data
	_rd.buffer_update(buffer_rid, 0, byte_data.size(), byte_data)

func upload_data_u8_as_u32(buffer_type: BufferType, data: PackedByteArray) -> void:
	if not has_buffer(buffer_type):
		return
	
	# Convert u8 to u32 for GPU
	var u32_data := PackedInt32Array()
	u32_data.resize(data.size())
	for i in range(data.size()):
		u32_data[i] = int(data[i])
	
	upload_data_u32(buffer_type, u32_data)

func download_data(buffer_type: BufferType) -> PackedFloat32Array:
	if not has_buffer(buffer_type):
		return PackedFloat32Array()
	
	var buffer_rid: RID = _buffers[buffer_type]
	var byte_data: PackedByteArray = _rd.buffer_get_data(buffer_rid)
	return byte_data.to_float32_array()

func download_data_u32(buffer_type: BufferType) -> PackedInt32Array:
	if not has_buffer(buffer_type):
		return PackedInt32Array()
	
	var buffer_rid: RID = _buffers[buffer_type]
	var byte_data: PackedByteArray = _rd.buffer_get_data(buffer_rid)
	return byte_data.to_int32_array()

func download_data_u32_as_u8(buffer_type: BufferType) -> PackedByteArray:
	var u32_data: PackedInt32Array = download_data_u32(buffer_type)
	var u8_data := PackedByteArray()
	u8_data.resize(u32_data.size())
	for i in range(u32_data.size()):
		u8_data[i] = int(clamp(u32_data[i], 0, 255))
	return u8_data

func get_cell_count() -> int:
	return _width * _height

func get_width() -> int:
	return _width

func get_height() -> int:
	return _height

func cleanup() -> void:
	if _rd != null:
		for buffer_rid in _buffers.values():
			if buffer_rid.is_valid():
				_rd.free_rid(buffer_rid)
	_buffers.clear()
	_buffer_sizes.clear()
	print("PersistentGPUBuffers: Cleaned up all buffers")

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		cleanup()
