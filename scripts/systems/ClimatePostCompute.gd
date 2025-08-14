# File: res://scripts/systems/ClimatePostCompute.gd
extends RefCounted

## GPU Mountain radiance diffusion using a single-pass neighborhood kernel.

var _rd: RenderingDevice
var _shader_file: RDShaderFile = load("res://shaders/mountain_radiance.glsl")
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
        _rd = RenderingServer.create_local_rendering_device()
    if not _shader.is_valid() and _shader_file != null:
        var s: RDShaderSPIRV = _get_spirv(_shader_file)
        if s != null:
            _shader = _rd.shader_create_from_spirv(s)
    if not _pipeline.is_valid() and _shader.is_valid():
        _pipeline = _rd.compute_pipeline_create(_shader)

func apply_mountain_radiance(w: int, h: int, biomes: PackedInt32Array, temperature: PackedFloat32Array, moisture: PackedFloat32Array, cool_amp: float, wet_amp: float, passes: int) -> Dictionary:
    _ensure()
    if not _pipeline.is_valid() or passes <= 0:
        return {"temperature": temperature, "moisture": moisture}
    var size: int = max(0, w * h)
    if size == 0 or biomes.size() != size or temperature.size() != size or moisture.size() != size:
        return {"temperature": temperature, "moisture": moisture}

    var temp_in := temperature
    var moist_in := moisture
    # Double-buffer across requested passes
    for p in range(max(1, passes)):
        var buf_t_in := _rd.storage_buffer_create(temp_in.to_byte_array().size(), temp_in.to_byte_array())
        var buf_m_in := _rd.storage_buffer_create(moist_in.to_byte_array().size(), moist_in.to_byte_array())
        var buf_b := _rd.storage_buffer_create(biomes.to_byte_array().size(), biomes.to_byte_array())
        var t_out := PackedFloat32Array(); t_out.resize(size)
        var m_out := PackedFloat32Array(); m_out.resize(size)
        var buf_t_out := _rd.storage_buffer_create(t_out.to_byte_array().size(), t_out.to_byte_array())
        var buf_m_out := _rd.storage_buffer_create(m_out.to_byte_array().size(), m_out.to_byte_array())

        var uniforms: Array = []
        var u: RDUniform
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t_in); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_m_in); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_b); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_t_out); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_m_out); uniforms.append(u)
        var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

        var pc := PackedByteArray()
        var ints := PackedInt32Array([w, h])
        var cool_per: float = cool_amp / float(max(1, passes))
        var wet_per: float = wet_amp / float(max(1, passes))
        var floats := PackedFloat32Array([cool_per, wet_per])
        pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
        # Align push constants to 16 bytes
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

        # Read back for next pass or final output
        var t_bytes := _rd.buffer_get_data(buf_t_out)
        var m_bytes := _rd.buffer_get_data(buf_m_out)
        temp_in = t_bytes.to_float32_array()
        moist_in = m_bytes.to_float32_array()

        _rd.free_rid(u_set)
        _rd.free_rid(buf_t_in)
        _rd.free_rid(buf_m_in)
        _rd.free_rid(buf_b)
        _rd.free_rid(buf_t_out)
        _rd.free_rid(buf_m_out)

    return {"temperature": temp_in, "moisture": moist_in}


