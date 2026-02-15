extends RefCounted
class_name LocalAreaTiles

# Canonical local-area tile/object/actor ids used by interior generation.
# Rendering marker ids (>=200) are kept here so LocalAreaScene can map gameplay
# entities to GPU palette ids consistently.

enum Tile {
	WALL = 0,
	FLOOR = 1,
	DOOR = 2,
}

enum Obj {
	NONE = 0,
	BOSS = 1,
	MAIN_CHEST = 2,
	BED = 3,
	TABLE = 4,
	HEARTH = 5,
}

enum Actor {
	NONE = 0,
	MAN = 1,
	WOMAN = 2,
	CHILD = 3,
	SHOPKEEPER = 4,
}

const MARKER_WALL: int = 210
const MARKER_FLOOR: int = 211
const MARKER_DOOR: int = 212
const MARKER_MAIN_CHEST: int = 213
const MARKER_BOSS: int = 214
const MARKER_BED: int = 215
const MARKER_TABLE: int = 216
const MARKER_HEARTH: int = 217
const MARKER_NPC_MAN: int = 218
const MARKER_NPC_WOMAN: int = 219
const MARKER_NPC_CHILD: int = 221
const MARKER_NPC_SHOPKEEPER: int = 222
const MARKER_UNKNOWN: int = 254
