# File: res://scripts/systems/ClimateBase.gd
extends RefCounted

## Seed-stable climate primitives (noise instances, etc.).

func build(rng_seed: int) -> Dictionary:
    var temp_noise := FastNoiseLite.new()
    temp_noise.seed = rng_seed ^ 0x5151
    temp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    temp_noise.frequency = 0.02

    var moist_noise := FastNoiseLite.new()
    moist_noise.seed = rng_seed ^ 0xA1A1
    moist_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    moist_noise.frequency = 0.02

    var flow_u := FastNoiseLite.new()
    var flow_v := FastNoiseLite.new()
    flow_u.seed = rng_seed ^ 0xC0FE
    flow_v.seed = rng_seed ^ 0xF00D
    flow_u.noise_type = FastNoiseLite.TYPE_SIMPLEX
    flow_v.noise_type = FastNoiseLite.TYPE_SIMPLEX
    flow_u.frequency = 0.01
    flow_v.frequency = 0.01

    return {
        "temp_noise": temp_noise,
        "moist_noise": moist_noise,
        "flow_u": flow_u,
        "flow_v": flow_v,
    }


