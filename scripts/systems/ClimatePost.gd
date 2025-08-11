# File: res://scripts/systems/ClimatePost.gd
extends RefCounted

const BiomeClassifier = preload("res://scripts/generation/BiomeClassifier.gd")

func apply_mountain_radiance(w: int, h: int, biomes: PackedInt32Array, temperature: PackedFloat32Array, moisture: PackedFloat32Array, cool_amp: float, wet_amp: float, passes: int) -> Dictionary:
	var out_temp := temperature
	var out_moist := moisture
	if passes <= 0:
		return {"temperature": out_temp, "moisture": out_moist}
	if biomes.size() != w * h:
		# No-op when biomes aren't available (parity with previous behavior)
		return {"temperature": out_temp, "moisture": out_moist}
	for p in range(passes):
		var temp2 := out_temp.duplicate()
		var moist2 := out_moist.duplicate()
		for y in range(h):
			for x in range(w):
				var i: int = x + y * w
				var b: int = biomes[i]
				if b == BiomeClassifier.Biome.MOUNTAINS or b == BiomeClassifier.Biome.ALPINE:
					for dy in range(-2, 3):
						for dx in range(-2, 3):
							var nx: int = x + dx
							var ny: int = y + dy
							if nx < 0 or ny < 0 or nx >= w or ny >= h:
								continue
							var j: int = nx + ny * w
							var dist: float = sqrt(float(dx * dx + dy * dy))
							var fall: float = clamp(1.0 - dist / 3.0, 0.0, 1.0)
							temp2[j] = clamp(temp2[j] - cool_amp * fall / float(passes), 0.0, 1.0)
							moist2[j] = clamp(moist2[j] + wet_amp * fall / float(passes), 0.0, 1.0)
		out_temp = temp2
		out_moist = moist2
	return {"temperature": out_temp, "moisture": out_moist}


