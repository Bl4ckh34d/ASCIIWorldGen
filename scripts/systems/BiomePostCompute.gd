# File: res://scripts/systems/BiomePostCompute.gd
extends RefCounted

## GPU version of BiomePost.apply_overrides_and_lava

var _rd: RenderingDevice
var _shader_file: RDShaderFile = load("res://shaders/biome_overrides_lava.glsl")
var _shader: RID
var _pipeline: RID

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
    if not _shader.is_valid() and _shader_file != null:
        var s: RDShaderSPIRV = _get_spirv(_shader_file)
        if s != null:
            _shader = _rd.shader_create_from_spirv(s)
    if not _pipeline.is_valid() and _shader.is_valid():
        _pipeline = _rd.compute_pipeline_create(_shader)

func apply_overrides_and_lava(w: int, h: int, is_land: PackedByteArray, temperature: PackedFloat32Array, moisture: PackedFloat32Array, biomes: PackedInt32Array, temp_min_c: float, temp_max_c: float, lava_temp_threshold_c: float, lake_mask: PackedByteArray = PackedByteArray()) -> Dictionary:
    _ensure()
    if not _pipeline.is_valid():
        return {"biomes": biomes, "lava": PackedByteArray()}
    var size: int = max(0, w * h)
    if size == 0:
        return {"biomes": biomes, "lava": PackedByteArray()}
    # Inputs
    var buf_b := _rd.storage_buffer_create(biomes.to_byte_array().size(), biomes.to_byte_array())
    var land_u := PackedInt32Array(); land_u.resize(size)
    for i in range(size): land_u[i] = 1 if (i < is_land.size() and is_land[i] != 0) else 0
    var buf_land := _rd.storage_buffer_create(land_u.to_byte_array().size(), land_u.to_byte_array())
    var buf_t := _rd.storage_buffer_create(temperature.to_byte_array().size(), temperature.to_byte_array())
    var buf_m := _rd.storage_buffer_create(moisture.to_byte_array().size(), moisture.to_byte_array())
    # Outputs
    var out_b := PackedInt32Array(); out_b.resize(size)
    var out_lava := PackedByteArray(); out_lava.resize(size)
    var buf_out_b := _rd.storage_buffer_create(out_b.to_byte_array().size(), out_b.to_byte_array())
    # Use u32 backing for lava mask to satisfy std430, then convert
    var lava_u32 := PackedInt32Array(); lava_u32.resize(size)
    for j in range(size): lava_u32[j] = 0
    var buf_lava := _rd.storage_buffer_create(lava_u32.to_byte_array().size(), lava_u32.to_byte_array())
    # Optional lake mask
    var lake_u := PackedInt32Array(); lake_u.resize(size)
    for k in range(size): lake_u[k] = 1 if (k < lake_mask.size() and lake_mask[k] != 0) else 0
    var buf_lake := _rd.storage_buffer_create(lake_u.to_byte_array().size(), lake_u.to_byte_array())

    # Uniforms
    var uniforms: Array = []
    var u: RDUniform
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_b); uniforms.append(u)
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_land); uniforms.append(u)
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_t); uniforms.append(u)
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_m); uniforms.append(u)
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_out_b); uniforms.append(u)
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 5; u.add_id(buf_lava); uniforms.append(u)
    u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 6; u.add_id(buf_lake); uniforms.append(u)
    var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

    # Push constants
    var pc := PackedByteArray()
    var ints := PackedInt32Array([w, h])
    var floats := PackedFloat32Array([temp_min_c, temp_max_c, lava_temp_threshold_c])
    pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
    var pad := (16 - (pc.size() % 16)) % 16
    if pad > 0:
        var zeros := PackedByteArray(); zeros.resize(pad)
        pc.append_array(zeros)

    # Dispatch
    var gx: int = int(ceil(float(w) / 16.0))
    var gy: int = int(ceil(float(h) / 16.0))
    var cl := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(cl, _pipeline)
    _rd.compute_list_bind_uniform_set(cl, u_set, 0)
    _rd.compute_list_set_push_constant(cl, pc, pc.size())
    _rd.compute_list_dispatch(cl, gx, gy, 1)
    _rd.compute_list_end()

    # Read back
    var b_bytes := _rd.buffer_get_data(buf_out_b)
    var l_bytes := _rd.buffer_get_data(buf_lava)
    var biomes_out := b_bytes.to_int32_array()
    var lava_read := l_bytes.to_int32_array()
    for k in range(size): out_lava[k] = 1 if lava_read[k] != 0 else 0

    _rd.free_rid(u_set)
    _rd.free_rid(buf_b)
    _rd.free_rid(buf_land)
    _rd.free_rid(buf_t)
    _rd.free_rid(buf_m)
    _rd.free_rid(buf_out_b)
    _rd.free_rid(buf_lava)
    _rd.free_rid(buf_lake)

    return {"biomes": biomes_out, "lava": out_lava}


