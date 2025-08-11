# File: res://scripts/systems/ContinentalShelf.gd
extends RefCounted

## Coastline, shallow water, beaches, and continental shelf helpers.
## Implements behavior equivalent to the inlined logic in WorldGenerator.gd.

const DistanceTransform = preload("res://scripts/systems/DistanceTransform.gd")

func compute(w: int, h: int, height: PackedFloat32Array, is_land: PackedByteArray, sea_level: float, shore_noise_field: PackedFloat32Array, shallow_threshold: float, shore_band: float, wrap_x: bool = true) -> Dictionary:
    var n: int = max(0, w * h)
    var turquoise_water := PackedByteArray()
    var beach := PackedByteArray()
    var water_distance := PackedFloat32Array()
    var turquoise_strength := PackedFloat32Array()
    turquoise_water.resize(n)
    beach.resize(n)
    water_distance.resize(n)
    turquoise_strength.resize(n)
    # 1) Distance from ocean to land using DT
    water_distance = DistanceTransform.new().ocean_distance_to_land(w, h, is_land, wrap_x)
    # 2) Mark turquoise and beaches near coast within shallow threshold
    for y in range(h):
        for x in range(w):
            var idx: int = x + y * w
            turquoise_water[idx] = 0
            beach[idx] = 0
            turquoise_strength[idx] = 0.0
            if is_land[idx] != 0:
                continue
            var depth: float = sea_level - height[idx]
            if depth < 0.0 or depth > shallow_threshold:
                continue
            # if neighbor is land, mark turquoise and neighboring beaches
            var near_land: bool = false
            for dy in range(-1, 2):
                if near_land: break
                for dx in range(-1, 2):
                    if dx == 0 and dy == 0:
                        continue
                    var nx: int = (x + dx + w) % w if wrap_x else x + dx
                    var ny: int = y + dy
                    if nx < 0 or ny < 0 or nx >= w or ny >= h:
                        continue
                    var ni: int = nx + ny * w
                    if is_land[ni] != 0:
                        near_land = true
                        break
            if near_land:
                var nval: float = shore_noise_field[idx]
                if nval > 0.55:
                    turquoise_water[idx] = 1
                    for dy2 in range(-1, 2):
                        for dx2 in range(-1, 2):
                            if dx2 == 0 and dy2 == 0:
                                continue
                            var nx2: int = (x + dx2 + w) % w if wrap_x else x + dx2
                            var ny2: int = y + dy2
                            if nx2 < 0 or ny2 < 0 or nx2 >= w or ny2 >= h:
                                continue
                            var ni2: int = nx2 + ny2 * w
                            if is_land[ni2] != 0:
                                beach[ni2] = 1
    # 3) Continuous turquoise strength blending depth and DT with shore noise
    for y2 in range(h):
        for x2 in range(w):
            var j: int = x2 + y2 * w
            if is_land[j] != 0:
                turquoise_strength[j] = 0.0
                continue
            var depth2: float = sea_level - height[j]
            if depth2 < 0.0:
                depth2 = 0.0
            var s_depth: float = clamp(1.0 - depth2 / shallow_threshold, 0.0, 1.0)
            var s_dist: float = 1.0 - clamp(water_distance[j] / shore_band, 0.0, 1.0)
            var nval2: float = shore_noise_field[j]
            var t: float = clamp((nval2 - 0.45) / 0.15, 0.0, 1.0)
            var s_noise: float = t * t * (3.0 - 2.0 * t)
            var strength: float = clamp(s_depth * s_dist * s_noise, 0.0, 1.0)
            turquoise_strength[j] = strength
            turquoise_water[j] = 1 if strength > 0.5 else turquoise_water[j]
    return {
        "turquoise_water": turquoise_water,
        "beach": beach,
        "water_distance": water_distance,
        "turquoise_strength": turquoise_strength,
    }


