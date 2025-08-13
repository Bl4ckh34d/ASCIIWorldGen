# File: res://scripts/style/WaterPalette.gd
extends RefCounted

func color_for_water(h_val: float, sea_level: float, is_turq: bool, turq_strength: float, _dist_to_land: float, _depth_scale: float, shelf_pattern: float) -> Color:
	var depth: float = max(0.0, sea_level - h_val)
	# Use actual depth to drive shade: shallow -> turquoise, deep -> dark blue
	var depth_norm: float = clamp(depth / 0.5, 0.0, 1.0)
	# Gentle shelf variation only in shallow water
	if shelf_pattern > 0.0:
		var shelf_influence := (1.0 - depth_norm) * 0.08
		depth_norm = clamp(depth_norm - shelf_pattern * shelf_influence, 0.0, 1.0)
	# Non-linear response so deep water darkens quickly (steeper gradient)
	var shade: float = pow(1.0 - depth_norm, 2.0)
	var deep := Color(0.02, 0.10, 0.25)
	var shallow := Color(0.05, 0.65, 0.80)
	var c := deep.lerp(shallow, shade)
	# Turquoise overlay fades with depth and local coastal strength
	if is_turq or turq_strength > 0.0:
		var overlay: float = float(clamp((1.0 - depth_norm) * turq_strength, 0.0, 0.85))
		c = c.lerp(Color(0.10, 0.85, 0.95), overlay)
	return c


