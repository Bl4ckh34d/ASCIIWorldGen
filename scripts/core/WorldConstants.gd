# File: res://scripts/core/WorldConstants.gd
extends RefCounted

# Centralized constants to replace magic numbers throughout the codebase
# Provides clear documentation and easier maintenance

# === WORLD GENERATION CONSTANTS ===

# Default world dimensions
const DEFAULT_WORLD_WIDTH: int = 275
const DEFAULT_WORLD_HEIGHT: int = 62

# Terrain generation
const DEFAULT_OCTAVES: int = 5
const DEFAULT_FREQUENCY: float = 0.02
const DEFAULT_LACUNARITY: float = 2.0
const DEFAULT_GAIN: float = 0.5
const DEFAULT_WARP: float = 24.0

# Sea level and water constants
const DEFAULT_SEA_LEVEL: float = 0.0
const SHALLOW_WATER_THRESHOLD: float = 0.20
const SHORE_BAND_WIDTH: float = 6.0
const SHORE_NOISE_MULTIPLIER: float = 4.0

# === CLIMATE CONSTANTS ===

# Temperature ranges (Celsius)
const DEFAULT_TEMP_MIN_C: float = -40.0
const DEFAULT_TEMP_MAX_C: float = 70.0
const LAVA_TEMP_THRESHOLD_C: float = 120.0

# Climate scaling
const TEMP_BASE_OFFSET: float = 0.25
const TEMP_SCALE: float = 1.0
const MOISTURE_BASE_OFFSET: float = 0.1
const MOISTURE_SCALE: float = 1.0
const CONTINENTALITY_SCALE: float = 1.2

# Seasonal and diurnal cycles
const SEASON_AMP_EQUATOR: float = 0.10
const SEASON_AMP_POLE: float = 0.25
const SEASON_OCEAN_DAMP: float = 0.60
const DIURNAL_AMP_EQUATOR: float = 0.15  # Enhanced for visibility
const DIURNAL_AMP_POLE: float = 0.08     # Enhanced for visibility
const DIURNAL_OCEAN_DAMP: float = 0.3

# Day-night visual settings
const DAY_NIGHT_CONTRAST: float = 0.75
const DAY_NIGHT_BASE: float = 0.25

# === PERFORMANCE CONSTANTS ===

# Simulation timing
const DEFAULT_SIMULATION_FPS: float = 60.0
const DEFAULT_TIME_SCALE: float = 0.2
const TICK_DAYS_PER_MINUTE: float = 1.0 / 1440.0  # 1 minute = 1 day

# Frame budget management
const TARGET_FRAME_TIME_MS: float = 16.67  # 60 FPS
const MAX_BUDGET_PERCENTAGE: float = 0.8   # Use 80% of frame time
const UI_PRIORITY_BUDGET: float = 0.95     # More generous for UI responsiveness

# ASCII rendering performance
const ASCII_REDRAW_CADENCE_SMALL: int = 1    # Every tick for <=4000 cells
const ASCII_REDRAW_CADENCE_MEDIUM: int = 2   # Every 2 ticks for <=10000 cells
const ASCII_REDRAW_CADENCE_LARGE: int = 3    # Every 3 ticks for <=25000 cells
const ASCII_REDRAW_CADENCE_XLARGE: int = 4   # Every 4 ticks for >25000 cells

const MAP_SIZE_SMALL: int = 4000
const MAP_SIZE_MEDIUM: int = 10000
const MAP_SIZE_LARGE: int = 25000

# Chunk processing
const ASYNC_ASCII_CHUNK_SIZE: int = 500      # Process ~22x22 chunks
const ARRAY_PROCESSING_CHUNK_SIZE: int = 10000  # 10k elements per chunk

# === SYSTEM CADENCES ===

# How often (in simulation days) each system updates
const CADENCE_CLIMATE: int = 1        # Climate: every day (real-time changes)
const CADENCE_HYDRO: int = 30         # Hydro: monthly changes
const CADENCE_CLOUDS: int = 7         # Clouds: weekly weather patterns
const CADENCE_BIOMES: int = 30        # Biomes: slower vegetation/ecoregion drift
const CADENCE_CRYOSPHERE: int = 5     # Cryosphere: faster seasonal ice advance/recede
const CADENCE_PLATES: int = 365       # Plates: yearly geological changes
const CADENCE_VOLCANISM: int = 3      # Volcanism: rapid geological events

# === GPU COMPUTE CONSTANTS ===

# Local work group sizes for compute shaders
const GPU_LOCAL_SIZE_X: int = 16
const GPU_LOCAL_SIZE_Y: int = 16
const GPU_LOCAL_SIZE_Z: int = 1

# Buffer alignment
const VULKAN_PUSH_CONSTANT_ALIGNMENT: int = 16
const GPU_BUFFER_ALIGNMENT: int = 16

# === GEOLOGICAL CONSTANTS ===

# Mountain and elevation
const HEIGHT_SCALE_METERS: float = 6000.0
const LAPSE_RATE_C_PER_KM: float = 5.5
const MOUNTAIN_COOL_AMP: float = 0.15
const MOUNTAIN_WET_AMP: float = 0.10
const MOUNTAIN_RADIANCE_PASSES: int = 3

# Plate tectonics
const PLATE_COUNT_DEFAULT: int = 12
const PLATE_COUNT_MIN: int = 2
const PLATE_COUNT_MAX: int = 128

# Uplift rates (normalized height units per day)
const PLATE_UPLIFT_RATE: float = 0.002
const PLATE_RIDGE_RATE: float = 0.0008
const PLATE_SUBSIDENCE_RATE: float = 0.001
const PLATE_TRANSFORM_ROUGHNESS: float = 0.0004
const PLATE_BOUNDARY_BAND_CELLS: int = 1

# Volcanism rates (per simulated day)
const LAVA_DECAY_RATE: float = 0.02
const LAVA_SPAWN_BOUNDARY_RATE: float = 0.01
const LAVA_HOTSPOT_RATE: float = 0.002
const LAVA_HOTSPOT_THRESHOLD: float = 0.999
const LAVA_BOUNDARY_SPAWN_THRESHOLD: float = 0.999

# === BIOME CONSTANTS ===

const FREEZE_TEMP_THRESHOLD: float = 0.16
const POLAR_CAP_FRACTION: float = 0.12

# Biome noise and jitter
const BIOME_NOISE_STRENGTH: float = 0.8
const BIOME_MOISTURE_JITTER: float = 0.06
const BIOME_MOISTURE_JITTER2: float = 0.03
const BIOME_MOISTURE_ISLANDS: float = 0.35
const BIOME_MOISTURE_ELEV_DRY: float = 0.35

# === HYDROLOGICAL CONSTANTS ===

# Flow and rivers
const FLOW_ACCUMULATION_THRESHOLD: int = 50
const RIVER_WIDTH_SCALE: float = 1.5
const RIVER_MEANDER_STRENGTH: float = 0.3

# Lakes and pooling
const LAKE_MIN_SIZE: int = 3
const OUTFLOW_MAX_FORCED: int = 3
const OUTFLOW_PROB_0: float = 0.50
const OUTFLOW_PROB_1: float = 0.35
const OUTFLOW_PROB_2: float = 0.10
const OUTFLOW_PROB_3: float = 0.05

# === VISUAL CONSTANTS ===

# Font and display
const MIN_FONT_SIZE: int = 8
const CHAR_WIDTH_FALLBACK: float = 8.0
const CHAR_HEIGHT_FALLBACK: float = 16.0

# Color and lighting
const CLOUD_OVERLAY_ALPHA: float = 0.25
const TWILIGHT_ZONE_THRESHOLD: float = 0.02
const NIGHT_BRIGHTNESS_MIN: float = 0.05
const SUMMER_BRIGHTNESS_BOOST: float = 2.0

# === ERROR HANDLING CONSTANTS ===

# Retry and timeout limits
const MAX_SHADER_LOAD_RETRIES: int = 3
const GPU_OPERATION_TIMEOUT_MS: float = 5000.0
const CHECKPOINT_SAVE_TIMEOUT_MS: float = 10000.0

# Memory limits
const MAX_WORLD_CELLS: int = 1000000  # 1M cells max (e.g., 1000x1000)
const MAX_CHECKPOINT_SIZE_MB: int = 500  # 500MB checkpoint limit

# === HELPER FUNCTIONS ===

static func get_adaptive_redraw_cadence(map_size: int) -> int:
	"""Get redraw cadence based on map size"""
	if map_size <= MAP_SIZE_SMALL:
		return ASCII_REDRAW_CADENCE_SMALL
	elif map_size <= MAP_SIZE_MEDIUM:
		return ASCII_REDRAW_CADENCE_MEDIUM
	elif map_size <= MAP_SIZE_LARGE:
		return ASCII_REDRAW_CADENCE_LARGE
	else:
		return ASCII_REDRAW_CADENCE_XLARGE

static func get_system_cadence(system_name: String) -> int:
	"""Get standard cadence for simulation systems"""
	match system_name.to_lower():
		"climate", "seasonal":
			return CADENCE_CLIMATE
		"hydro", "hydrological":
			return CADENCE_HYDRO
		"clouds", "wind":
			return CADENCE_CLOUDS
		"biomes", "biome":
			return CADENCE_BIOMES
		"cryosphere", "ice":
			return CADENCE_CRYOSPHERE
		"plates", "tectonic":
			return CADENCE_PLATES
		"volcanism", "volcanic":
			return CADENCE_VOLCANISM
		_:
			push_warning("Unknown system name: " + system_name)
			return CADENCE_CLIMATE  # Default to daily

static func validate_world_size(width: int, height: int) -> bool:
	"""Validate world dimensions are reasonable"""
	var total_cells = width * height
	return total_cells > 0 and total_cells <= MAX_WORLD_CELLS

static func clamp_temperature_params(temp_offset: float, temp_scale: float) -> Dictionary:
	"""Clamp temperature parameters to prevent extreme values"""
	return {
		"temp_offset": clamp(temp_offset, -0.3, 0.3),
		"temp_scale": clamp(temp_scale, 0.6, 1.4)
	}
