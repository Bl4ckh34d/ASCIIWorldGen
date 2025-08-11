# File: res://scripts/ui/RandomizeService.gd
extends RefCounted

## Centralized jitter for terrain/climate/sea-level based on current config.

func jitter_config(current_cfg: Object, now_usec: int) -> Dictionary:
    var jitter := RandomNumberGenerator.new()
    jitter.seed = int(now_usec) ^ int(current_cfg.rng_seed)
    var cfg2 := {}
    cfg2["frequency"] = max(0.001, current_cfg.frequency * (0.9 + 0.2 * jitter.randf()))
    cfg2["lacunarity"] = current_cfg.lacunarity * (0.9 + 0.2 * jitter.randf())
    cfg2["gain"] = clamp(current_cfg.gain * (0.85 + 0.3 * jitter.randf()), 0.1, 1.0)
    cfg2["warp"] = max(0.0, current_cfg.warp * (0.75 + 0.5 * jitter.randf()))
    # Sea level range is -1..1; randomize within [-0.35, 0.35]
    cfg2["sea_level"] = -0.35 + 0.70 * jitter.randf()
    # Climate baseline jitter
    cfg2["temp_base_offset"] = (jitter.randf() - 0.5) * 0.10
    cfg2["temp_scale"] = 0.95 + 0.1 * jitter.randf()
    cfg2["moist_base_offset"] = (jitter.randf() - 0.5) * 0.10
    cfg2["moist_scale"] = 0.95 + 0.1 * jitter.randf()
    cfg2["continentality_scale"] = 0.9 + 0.3 * jitter.randf()
    # Slight shift/expand of per-seed extreme temperatures
    var tmin: float = float(current_cfg.temp_min_c)
    var tmax: float = float(current_cfg.temp_max_c)
    var span: float = max(1.0, tmax - tmin)
    var shift: float = (jitter.randf() - 0.5) * 6.0
    var expand: float = 0.95 + 0.1 * jitter.randf()
    cfg2["temp_min_c"] = tmin + shift
    cfg2["temp_max_c"] = tmin + shift + span * expand
    return cfg2


