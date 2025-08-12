# File: res://scripts/SettingsDialog.gd
extends Window

signal settings_applied(config: Dictionary)

@onready var width_spin: SpinBox = $VBox/Tabs/General/Grid/Width
@onready var height_spin: SpinBox = $VBox/Tabs/General/Grid/Height
@onready var octaves_spin: SpinBox = $VBox/Tabs/Continents/Grid/Octaves
@onready var freq_spin: SpinBox = $VBox/Tabs/Continents/Grid/Frequency
@onready var lacunarity_spin: SpinBox = $VBox/Tabs/Continents/Grid/Lacunarity
@onready var gain_spin: SpinBox = $VBox/Tabs/Continents/Grid/Gain
@onready var warp_spin: SpinBox = $VBox/Tabs/Continents/Grid/Warp
@onready var sea_spin: SpinBox = $VBox/Tabs/Ocean/Grid/SeaLevel

@onready var apply_button: Button = $VBox/Buttons/Apply
@onready var close_button: Button = $VBox/Buttons/Close

# Advanced groups (created in scene): rivers and visuals
@onready var river_enabled: CheckBox = $VBox/Tabs/Rivers/Grid/RiverEnabled
@onready var river_droplets: SpinBox = $VBox/Tabs/Rivers/Grid/RiverDropletsFactor
@onready var river_thresh: SpinBox = $VBox/Tabs/Rivers/Grid/RiverThresholdFactor
@onready var river_erosion: SpinBox = $VBox/Tabs/Rivers/Grid/RiverErosion
@onready var river_min_start_h: SpinBox = $VBox/Tabs/Rivers/Grid/RiverMinStartHeight
@onready var river_polar_cutoff: SpinBox = $VBox/Tabs/Rivers/Grid/RiverPolarCutoff
@onready var river_delta_widening: CheckBox = $VBox/Tabs/Rivers/Grid/RiverDeltaWidening
@onready var shallow_threshold: SpinBox = $VBox/Tabs/Ocean/Grid/ShallowThreshold
@onready var shore_band: SpinBox = $VBox/Tabs/Ocean/Grid/ShoreBand
@onready var shore_noise_mult: SpinBox = $VBox/Tabs/Ocean/Grid/ShoreNoiseMult
@onready var polar_cap_frac: SpinBox = $VBox/Tabs/Climate/Grid/PolarCapFrac
@onready var gpu_all: CheckBox = $VBox/Tabs/General/Grid/GPUAll

func _ready() -> void:
    apply_button.pressed.connect(_on_apply)
    close_button.pressed.connect(_on_close)
    close_requested.connect(_on_close)

func _on_apply() -> void:
    var cfg := {
        # seed removed from dialog; controlled from top bar
        "width": int(width_spin.value),
        "height": int(height_spin.value),
        "octaves": int(octaves_spin.value),
        "frequency": float(freq_spin.value),
        "lacunarity": float(lacunarity_spin.value),
        "gain": float(gain_spin.value),
        "warp": float(warp_spin.value),
        "sea_level": float(sea_spin.value),
        # shoreline & polar
        "shallow_threshold": float(shallow_threshold.value),
        "shore_band": float(shore_band.value),
        "shore_noise_mult": float(shore_noise_mult.value),
        "polar_cap_frac": float(polar_cap_frac.value),
        # compute toggles
        "use_gpu_all": bool(gpu_all.button_pressed),
        # rivers
        "river_enabled": bool(river_enabled.button_pressed),
        "river_droplets_factor": float(river_droplets.value),
        "river_threshold_factor": float(river_thresh.value),
        "river_erosion_strength": float(river_erosion.value),
        "river_min_start_height": float(river_min_start_h.value),
        "river_polar_cutoff": float(river_polar_cutoff.value),
        "river_delta_widening": bool(river_delta_widening.button_pressed),
    }
    emit_signal("settings_applied", cfg)

func _on_close() -> void:
    hide()


