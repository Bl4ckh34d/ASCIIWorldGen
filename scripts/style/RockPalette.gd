# File: res://scripts/style/RockPalette.gd
extends RefCounted

const ROCK_BASALTIC: int = 0
const ROCK_GRANITIC: int = 1
const ROCK_SEDIMENTARY_CLASTIC: int = 2
const ROCK_LIMESTONE: int = 3
const ROCK_METAMORPHIC: int = 4
const ROCK_VOLCANIC_ASH: int = 5

func color_for_rock(rock_type: int, is_water: bool) -> Color:
	if is_water:
		return Color(0.05, 0.22, 0.45)
	match rock_type:
		ROCK_BASALTIC:
			return Color(0.21, 0.22, 0.24)
		ROCK_GRANITIC:
			return Color(0.67, 0.62, 0.57)
		ROCK_SEDIMENTARY_CLASTIC:
			return Color(0.76, 0.66, 0.49)
		ROCK_LIMESTONE:
			return Color(0.83, 0.80, 0.70)
		ROCK_METAMORPHIC:
			return Color(0.46, 0.43, 0.40)
		ROCK_VOLCANIC_ASH:
			return Color(0.38, 0.34, 0.31)
		_:
			return Color(0.55, 0.52, 0.48)

