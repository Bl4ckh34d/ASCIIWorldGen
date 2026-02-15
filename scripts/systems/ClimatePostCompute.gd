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
    var chosen_version: Variant = null
    for v in versions:
        if v == null:
            continue
        if chosen_version == null:
            chosen_version = v
        if String(v) == "vulkan":
            chosen_version = v
            break
    if chosen_version == null:
        return null
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

func cleanup() -> void:
    if _rd != null:
        if _pipeline.is_valid():
            _rd.free_rid(_pipeline)
        if _shader.is_valid():
            _rd.free_rid(_shader)
    _pipeline = RID()
    _shader = RID()


