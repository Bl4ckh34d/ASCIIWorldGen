extends RefCounted
class_name CommodityCatalog

# Minimal commodity catalog for economy scaffolding.
# Keep this small and bottleneck-focused; expand later with tech/epoch variants.

const COMMODITIES: Array[String] = [
	"water",
	"food",
	"fuel",
	"medicine",
	"materials",
	"arms",
]

static func keys() -> Array[String]:
	return COMMODITIES.duplicate()

static func base_price(key: String) -> float:
	key = String(key)
	match key:
		"water":
			return 1.2
		"food":
			return 1.0
		"fuel":
			return 1.4
		"medicine":
			return 2.0
		"materials":
			return 0.8
		"arms":
			return 1.8
		_:
			return 1.0

