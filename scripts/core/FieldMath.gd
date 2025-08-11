# File: res://scripts/core/FieldMath.gd
extends RefCounted

## Hot kernels used by multiple systems. Pure functions operating on
## PackedArrays. Keep allocations outside call-sites.

const DIAG_COST: float = 1.41421356237

func distance_transform_8(width: int, height: int, dist: PackedFloat32Array) -> void:
    # Two-pass chamfer DT. Caller must set seeds with dist=0 and others to large value.
    if width <= 0 or height <= 0:
        return
    var w: int = width
    var h: int = height
    # Forward pass
    for y in range(h):
        for x in range(w):
            var i: int = x + y * w
            var d: float = dist[i]
            # West
            if x > 0:
                d = min(d, dist[i - 1] + 1.0)
                # North-West
                if y > 0:
                    d = min(d, dist[i - 1 - w] + DIAG_COST)
            # North
            if y > 0:
                d = min(d, dist[i - w] + 1.0)
                # North-East
                if x < w - 1:
                    d = min(d, dist[i - w + 1] + DIAG_COST)
            dist[i] = d
    # Backward pass
    for y2 in range(h - 1, -1, -1):
        for x2 in range(w - 1, -1, -1):
            var j: int = x2 + y2 * w
            var d2: float = dist[j]
            # East
            if x2 < w - 1:
                d2 = min(d2, dist[j + 1] + 1.0)
                # South-East
                if y2 < h - 1:
                    d2 = min(d2, dist[j + 1 + w] + DIAG_COST)
            # South
            if y2 < h - 1:
                d2 = min(d2, dist[j + w] + 1.0)
                # South-West
                if x2 > 0:
                    d2 = min(d2, dist[j + w - 1] + DIAG_COST)
            dist[j] = d2

func mode_filter_3x3_int(width: int, height: int, src: PackedInt32Array) -> PackedInt32Array:
    # 3x3 majority vote filter. For ties, keep center value.
    var w: int = width
    var h: int = height
    var out := PackedInt32Array()
    out.resize(max(0, w * h))
    for y in range(h):
        for x in range(w):
            var counts := {}
            var center_idx: int = x + y * w
            var center_val: int = src[center_idx]
            for dy in range(-1, 2):
                for dx in range(-1, 2):
                    var nx: int = x + dx
                    var ny: int = y + dy
                    if nx < 0 or ny < 0 or nx >= w or ny >= h:
                        continue
                    var v: int = src[nx + ny * w]
                    counts[v] = int(counts.get(v, 0)) + 1
            var best_val: int = center_val
            var best_count: int = -1
            for k in counts.keys():
                var cnt: int = counts[k]
                if cnt > best_count:
                    best_count = cnt
                    best_val = k
            out[center_idx] = best_val
    return out


