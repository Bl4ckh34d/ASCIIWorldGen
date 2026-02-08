extends RefCounted
class_name SettingsStateModel

var encounter_rate_multiplier: float = 1.0
var auto_battle_enabled: bool = false
var text_speed: float = 1.0
var master_volume: float = 1.0
var music_volume: float = 0.0
var sfx_volume: float = 0.0

func reset_defaults() -> void:
	encounter_rate_multiplier = 1.0
	auto_battle_enabled = false
	text_speed = 1.0
	master_volume = 1.0
	music_volume = 0.0
	sfx_volume = 0.0

func apply_patch(data: Dictionary) -> void:
	if data.has("encounter_rate_multiplier"):
		encounter_rate_multiplier = clamp(float(data["encounter_rate_multiplier"]), 0.10, 2.00)
	if data.has("auto_battle_enabled"):
		auto_battle_enabled = bool(data["auto_battle_enabled"])
	if data.has("text_speed"):
		text_speed = clamp(float(data["text_speed"]), 0.50, 2.00)
	if data.has("master_volume"):
		master_volume = clamp(float(data["master_volume"]), 0.0, 1.0)
	if data.has("music_volume"):
		music_volume = clamp(float(data["music_volume"]), 0.0, 1.0)
	if data.has("sfx_volume"):
		sfx_volume = clamp(float(data["sfx_volume"]), 0.0, 1.0)

func to_dict() -> Dictionary:
	return {
		"encounter_rate_multiplier": encounter_rate_multiplier,
		"auto_battle_enabled": auto_battle_enabled,
		"text_speed": text_speed,
		"master_volume": master_volume,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
	}

static func from_dict(data: Dictionary) -> SettingsStateModel:
	var out := SettingsStateModel.new()
	out.apply_patch(data)
	return out

func summary_lines() -> PackedStringArray:
	return PackedStringArray([
		"Encounter Rate: x%.2f" % encounter_rate_multiplier,
		"Auto Battle: %s" % ("On" if auto_battle_enabled else "Off"),
		"Text Speed: x%.2f" % text_speed,
		"Master Volume: %d%%" % int(round(master_volume * 100.0)),
		"Music Volume: %d%%" % int(round(music_volume * 100.0)),
		"SFX Volume: %d%%" % int(round(sfx_volume * 100.0)),
	])
