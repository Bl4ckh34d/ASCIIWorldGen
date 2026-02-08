extends SceneTree

func _fraction(seedv: int, sea: float) -> float:
	var TN = load("res://scripts/generation/TerrainNoise.gd")
	var tn = TN.new()
	var params = {
		"width": 275,
		"height": 62,
		"seed": seedv,
		"frequency": 0.02,
		"octaves": 5,
		"lacunarity": 2.0,
		"gain": 0.5,
		"warp": 24.0,
		"sea_level": sea,
		"wrap_x": true,
		"noise_x_scale": 0.5,
	}
	var out = tn.generate(params)
	var land: PackedByteArray = out.get("is_land", PackedByteArray())
	if land.is_empty():
		return 0.0
	var c := 0
	for i in range(land.size()):
		if land[i] != 0:
			c += 1
	return float(c) / float(land.size())

func _init() -> void:
	var n := 40
	var seas = [0.0, 0.08, 0.16]
	for s in seas:
		var minf := 1.0
		var maxf := 0.0
		var sum := 0.0
		for i in range(n):
			var seedv = 100000 + i * 7919
			var f = _fraction(seedv, s)
			if f < minf:
				minf = f
			if f > maxf:
				maxf = f
			sum += f
		print("sea=", s, " min=", minf, " avg=", (sum / float(n)), " max=", maxf)
	quit()
