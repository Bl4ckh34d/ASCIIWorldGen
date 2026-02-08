extends SceneTree

func _init() -> void:
	var WG = load("res://scripts/WorldGenerator.gd")
	var TN = load("res://scripts/generation/TerrainNoise.gd")
	var gen = WG.new()
	gen.config.width = 275
	gen.config.height = 62
	gen.config.rng_seed = 1300716004
	var params = {
		"width": gen.config.width,
		"height": gen.config.height,
		"seed": gen.config.rng_seed,
		"frequency": gen.config.frequency,
		"octaves": gen.config.octaves,
		"lacunarity": gen.config.lacunarity,
		"gain": gen.config.gain,
		"warp": gen.config.warp,
		"sea_level": gen.config.sea_level,
		"wrap_x": true,
		"noise_x_scale": gen.config.noise_x_scale,
	}
	# CPU reference terrain
	var tn = TN.new()
	var cpu = tn.generate(params)
	var h_cpu: PackedFloat32Array = cpu.get("height", PackedFloat32Array())
	var l_cpu: PackedByteArray = cpu.get("is_land", PackedByteArray())
	var cpu_land := 0
	var cpu_min := 1e9
	var cpu_max := -1e9
	for i in range(h_cpu.size()):
		var v = h_cpu[i]
		if v < cpu_min: cpu_min = v
		if v > cpu_max: cpu_max = v
		if i < l_cpu.size() and l_cpu[i] != 0:
			cpu_land += 1
	print("CPU min/max/land=", cpu_min, " ", cpu_max, " ", cpu_land, "/", h_cpu.size())

	# GPU terrain pass
	gen._prepare_new_generation_state(gen.config.width * gen.config.height)
	gen.ensure_persistent_buffers(false)
	var hb: RID = gen.get_persistent_buffer("height")
	var lb: RID = gen.get_persistent_buffer("is_land")
	var tc = load("res://scripts/systems/TerrainCompute.gd").new()
	var ok = tc.generate_to_buffers(gen.config.width, gen.config.height, params, hb, lb)
	print("GPU terrain ok=", ok)
	if not ok:
		quit()
		return
	var bytes_h: PackedByteArray = gen._gpu_buffer_manager.read_buffer("height")
	var h_gpu: PackedFloat32Array = bytes_h.to_float32_array()
	var bytes_l: PackedByteArray = gen._gpu_buffer_manager.read_buffer("is_land")
	var l_gpu_i32: PackedInt32Array = bytes_l.to_int32_array()
	var gpu_land := 0
	var gpu_min := 1e9
	var gpu_max := -1e9
	for i in range(h_gpu.size()):
		var v2 = h_gpu[i]
		if v2 < gpu_min: gpu_min = v2
		if v2 > gpu_max: gpu_max = v2
		if i < l_gpu_i32.size() and l_gpu_i32[i] != 0:
			gpu_land += 1
	print("GPU min/max/land=", gpu_min, " ", gpu_max, " ", gpu_land, "/", h_gpu.size())
	quit()
