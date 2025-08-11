# File: res://scripts/systems/DistanceTransform.gd
extends RefCounted

## Computes 8-neighbor chamfer distance using FieldMath DT.
## Provides helper for ocean distance to nearest land, with optional wrap-X.

const FieldMath = preload("res://scripts/core/FieldMath.gd")

func ocean_distance_to_land(width: int, height: int, is_land: PackedByteArray, wrap_x: bool = false) -> PackedFloat32Array:
    var w: int = width
    var h: int = height
    var inf: float = 1e9
    if not wrap_x:
        var dist := PackedFloat32Array()
        dist.resize(max(0, w * h))
        for i in range(dist.size()):
            dist[i] = 0.0 if is_land[i] != 0 else inf
        FieldMath.new().distance_transform_8(w, h, dist)
        return dist
    # Wrap-X: compute DT on a horizontally duplicated field and fold back
    var w2: int = w * 2
    var dist2 := PackedFloat32Array()
    dist2.resize(max(0, w2 * h))
    for y in range(h):
        for x in range(w):
            var i0: int = x + y * w
            var v: float = 0.0 if is_land[i0] != 0 else inf
            var j0: int = x + y * w2
            var j1: int = x + w + y * w2
            dist2[j0] = v
            dist2[j1] = v
    FieldMath.new().distance_transform_8(w2, h, dist2)
    var out := PackedFloat32Array()
    out.resize(max(0, w * h))
    for y2 in range(h):
        for x2 in range(w):
            var j0: int = x2 + y2 * w2
            var j1: int = x2 + w + y2 * w2
            out[x2 + y2 * w] = min(dist2[j0], dist2[j1])
    return out


