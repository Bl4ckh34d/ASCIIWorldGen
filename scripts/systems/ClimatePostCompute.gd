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
        _rd = RenderingServer.get_rendering_device()
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

    var temp_bytes: PackedByteArray = temperature.to_byte_array()
    var moist_bytes: PackedByteArray = moisture.to_byte_array()
    var biome_bytes: PackedByteArray = biomes.to_byte_array()
    var empty_out := PackedByteArray()
    empty_out.resize(size * 4)
    var buf_t_a := _rd.storage_buffer_create(temp_bytes.size(), temp_bytes)
    var buf_m_a := _rd.storage_buffer_create(moist_bytes.size(), moist_bytes)
    var buf_t_b := _rd.storage_buffer_create(empty_out.size(), empty_out)
    var buf_m_b := _rd.storage_buffer_create(empty_out.size(), empty_out)
    var buf_b := _rd.storage_buffer_create(biome_bytes.size(), biome_bytes)

    var pc := PackedByteArray()
    var ints := PackedInt32Array([w, h])
    var cool_per: float = cool_amp / float(max(1, passes))
    var wet_per: float = wet_amp / float(max(1, passes))
    var floats := PackedFloat32Array([cool_per, wet_per])
    pc.append_array(ints.to_byte_array()); pc.append_array(floats.to_byte_array())
    var pad := (16 - (pc.size() % 16)) % 16
    if pad > 0:
        var zeros := PackedByteArray(); zeros.resize(pad)
        pc.append_array(zeros)

    var gx: int = int(ceil(float(w) / 16.0))
    var gy: int = int(ceil(float(h) / 16.0))
    var read_from_a: bool = true
    for _p in range(max(1, passes)):
        var buf_t_in: RID = buf_t_a if read_from_a else buf_t_b
        var buf_m_in: RID = buf_m_a if read_from_a else buf_m_b
        var buf_t_out: RID = buf_t_b if read_from_a else buf_t_a
        var buf_m_out: RID = buf_m_b if read_from_a else buf_m_a

        var uniforms: Array = []
        var u: RDUniform
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t_in); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_m_in); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(buf_b); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_t_out); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_m_out); uniforms.append(u)
        var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

        var cl := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(cl, _pipeline)
        _rd.compute_list_bind_uniform_set(cl, u_set, 0)
        _rd.compute_list_set_push_constant(cl, pc, pc.size())
        _rd.compute_list_dispatch(cl, gx, gy, 1)
        _rd.compute_list_end()
        _rd.free_rid(u_set)
        read_from_a = not read_from_a

    var final_t_buf: RID = buf_t_a if read_from_a else buf_t_b
    var final_m_buf: RID = buf_m_a if read_from_a else buf_m_b
    var out_temp: PackedFloat32Array = _rd.buffer_get_data(final_t_buf).to_float32_array()
    var out_moist: PackedFloat32Array = _rd.buffer_get_data(final_m_buf).to_float32_array()

    _rd.free_rid(buf_t_a)
    _rd.free_rid(buf_m_a)
    _rd.free_rid(buf_t_b)
    _rd.free_rid(buf_m_b)
    _rd.free_rid(buf_b)

    return {"temperature": out_temp, "moisture": out_moist}

func apply_mountain_radiance_to_buffers(
        w: int,
        h: int,
        biome_buf: RID,
        temp_buf: RID,
        moist_buf: RID,
        temp_tmp_buf: RID,
        moist_tmp_buf: RID,
        cool_amp: float,
        wet_amp: float,
        passes: int
    ) -> Dictionary:
    _ensure()
    if not _pipeline.is_valid() or passes <= 0:
        return {"ok": true, "temp_in_primary": true, "moist_in_primary": true}
    if w <= 0 or h <= 0:
        return {"ok": false}
    if not biome_buf.is_valid() or not temp_buf.is_valid() or not moist_buf.is_valid():
        return {"ok": false}
    if not temp_tmp_buf.is_valid() or not moist_tmp_buf.is_valid():
        return {"ok": false}

    var pc := PackedByteArray()
    var ints := PackedInt32Array([w, h])
    var cool_per: float = cool_amp / float(max(1, passes))
    var wet_per: float = wet_amp / float(max(1, passes))
    var floats := PackedFloat32Array([cool_per, wet_per])
    pc.append_array(ints.to_byte_array())
    pc.append_array(floats.to_byte_array())
    var pad := (16 - (pc.size() % 16)) % 16
    if pad > 0:
        var zeros := PackedByteArray()
        zeros.resize(pad)
        pc.append_array(zeros)

    var gx: int = int(ceil(float(w) / 16.0))
    var gy: int = int(ceil(float(h) / 16.0))
    var read_from_primary: bool = true
    for _p in range(max(1, passes)):
        var buf_t_in: RID = temp_buf if read_from_primary else temp_tmp_buf
        var buf_m_in: RID = moist_buf if read_from_primary else moist_tmp_buf
        var buf_t_out: RID = temp_tmp_buf if read_from_primary else temp_buf
        var buf_m_out: RID = moist_tmp_buf if read_from_primary else moist_buf

        var uniforms: Array = []
        var u: RDUniform
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 0; u.add_id(buf_t_in); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 1; u.add_id(buf_m_in); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 2; u.add_id(biome_buf); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 3; u.add_id(buf_t_out); uniforms.append(u)
        u = RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = 4; u.add_id(buf_m_out); uniforms.append(u)
        var u_set := _rd.uniform_set_create(uniforms, _shader, 0)

        var cl := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(cl, _pipeline)
        _rd.compute_list_bind_uniform_set(cl, u_set, 0)
        _rd.compute_list_set_push_constant(cl, pc, pc.size())
        _rd.compute_list_dispatch(cl, gx, gy, 1)
        _rd.compute_list_end()
        _rd.free_rid(u_set)
        read_from_primary = not read_from_primary

    return {
        "ok": true,
        "temp_in_primary": read_from_primary,
        "moist_in_primary": read_from_primary
    }


