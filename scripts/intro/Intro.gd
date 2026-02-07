# File: res://scripts/intro/Intro.gd
extends Control

const IntroBigBangCompute = preload("res://scripts/intro/IntroBigBangCompute.gd")

const TARGET_VIEWPORT_SIZE := Vector2i(1770, 830)
const DEFAULT_INTRO_QUOTE_TEXT := "\"If you wish to make an apple pie from scratch,\nyou must first invent the universe\""
const DEFAULT_INTRO_QUOTE_AUTHOR := "- Carl Sagan"
const INTRO_FLAGS_PATH := "user://intro_flags.cfg"
const INTRO_FLAGS_SECTION := "intro"
const INTRO_FLAGS_KEY_FIRST_QUOTE_SHOWN := "first_quote_shown"
const MAIN_SCENE_PATH := "res://scenes/Main.tscn"
const INTRO_QUOTES := [
	{
		"text": DEFAULT_INTRO_QUOTE_TEXT,
		"author": DEFAULT_INTRO_QUOTE_AUTHOR
	},
	{
		"text": "\"Two things are infinite: the universe and human stupidity;\nand I'm not sure about the universe.\"",
		"author": "- Albert Einstein"
	},
	{
		"text": "\"Two possibilities exist: either we are alone in the Universe or we are not.\nBoth are equally terrifying.\"",
		"author": "- Arthur C. Clarke"
	},
	{
		"text": "\"I'm sure the universe is full of intelligent life.\nIt's just been too intelligent to come here.\"",
		"author": "- Arthur C. Clarke"
	},
	{
		"text": "\"The more clearly we can focus our attention on the wonders and realities\nof the universe about us, the less taste we shall have for destruction.\"",
		"author": "- Rachel Carson"
	},
	{
		"text": "\"Nothing happens until something moves.\"",
		"author": "- Albert Einstein"
	},
	{
		"text": "\"We are an impossibility in an impossible universe.\"",
		"author": "- Ray Bradbury"
	},
	{
		"text": "\"The universe is a pretty big place. If it's just us,\nseems like an awful waste of space.\"",
		"author": "- Carl Sagan"
	},
	{
		"text": "\"Do you think the universe fights for souls to be together?\nSome things are too strange and strong to be coincidences.\"",
		"author": "- Emery Allen"
	},
	{
		"text": "\"You are a function of what the whole universe is doing in the same way\nthat a wave is a function of what the whole ocean is doing.\"",
		"author": "- Alan Watts"
	},
	{
		"text": "\"The Universe is under no obligation to make sense to you.\"",
		"author": "- Neil deGrasse Tyson"
	},
	{
		"text": "\"If you think this Universe is bad,\nyou should see some of the others.\"",
		"author": "- Philip K. Dick"
	},
	{
		"text": "\"The universe doesn't give you what you ask for with your thoughts -\nit gives you what you demand with your actions.\"",
		"author": "- Steve Maraboli"
	},
	{
		"text": "\"The universe seems neither benign nor hostile, merely indifferent.\"",
		"author": "- Carl Sagan"
	},
	{
		"text": "\"We are the cosmos made conscious and life is the means by which\nthe universe understands itself.\"",
		"author": "- Brian Cox"
	},
	{
		"text": "\"You may think I'm small,\nbut I have a universe inside my mind.\"",
		"author": "- Yoko Ono"
	},
	{
		"text": "\"She who saves a single soul, saves the universe.\"",
		"author": "- American McGee"
	},
	{
		"text": "\"The Universe is not only queerer than we suppose,\nbut queerer than we can suppose.\"",
		"author": "- J.B.S. Haldane"
	},
	{
		"text": "\"I don't want to rule the universe.\nI just think it could be more sensibly organised.\"",
		"author": "- Eliezer Yudkowsky"
	},
	{
		"text": "\"...in an infinite universe, anything that could be imagined\nmight somewhere exist.\"",
		"author": "- Dean Koontz"
	},
	{
		"text": "\"The stars up there at night are closer than you think.\"",
		"author": "- Doug Dillon"
	}
]
const STAR_PROMPT_TEXT := "Space, time and gravity gave birth to %s \nand she in turn gave life to a tiny world."
const PLANET_PROMPT_TEXT := "This world was called %s by its inhabitants."
const MAX_NAME_LENGTH: int = 48

const PROMPT_NONE := 0
const PROMPT_STAR := 1
const PROMPT_PLANET := 2

const PHASE_QUOTE := 0
const PHASE_BIG_BANG := 1
const PHASE_STAR_PROMPT_FADE_IN := 2
const PHASE_STAR_PROMPT_INPUT := 3
const PHASE_STAR_PROMPT_FADE_OUT := 4
const PHASE_SPACE_REVEAL := 5
const PHASE_CAMERA_PAN := 6
const PHASE_PLANET_PLACE := 7
const PHASE_PLANET_PROMPT_FADE_IN := 8
const PHASE_PLANET_PROMPT_INPUT := 9
const PHASE_PLANET_PROMPT_FADE_OUT := 10
const PHASE_PLANET_ZOOM := 11
const PHASE_TRANSITION := 12

const QUOTE_FADE_IN_SEC := 3.0
const QUOTE_HOLD_SEC := 2.6
const QUOTE_START_DELAY_SEC := 1.00
const BIG_BANG_EXPLODE_SEC := 1.80
const BIG_BANG_PLASMA_FADE_SEC := 3.00
const BIG_BANG_STARFIELD_SEC := 5.80
const BIG_BANG_FADE_SEC := 1.00
const BIG_BANG_EXPANSION_DRIVE_SEC := 2.20
const BIG_BANG_SHAKE_START_DELAY_SEC := 0.30
const BIG_BANG_SHAKE_RISE_SEC := 0.50
const BIG_BANG_SHAKE_DECAY_SEC := 3.00
const STAR_PROMPT_FADE_IN_SEC := 1.20
const STAR_PROMPT_HOLD_SEC := 3.00
const STAR_PROMPT_FADE_OUT_SEC := 0.95
const SPACE_REVEAL_SEC := 4.80
const CAMERA_PAN_SEC := 5.10
const PLANET_PROMPT_FADE_IN_SEC := 0.95
const PLANET_PROMPT_FADE_OUT_SEC := 0.95
const PLANET_STORY_HOLD_SEC := 2.20
const MOON_STORY_FADE_IN_SEC := 0.90
const MOON_STORY_HOLD_SEC := 2.40
const MOON_STORY_FADE_OUT_SEC := 0.95
const HABITABLE_ZONE_LABEL_FADE_IN_SEC := 0.80
const SKIP_TO_PLANET_FADE_SEC := 0.75
const PLANET_ZOOM_SEC := 1.95
const TRANSITION_SEC := 0.18
const SUN_PROMPT_PAN_PROGRESS := 0.45
const SUN_START_X_FACTOR := 2.05
const SUN_REFERENCE_START_X_FACTOR := 1.38
const SUN_REST_SCREEN_X_FACTOR := 0.50
const GOLDILOCK_REFERENCE_SCALE := 2.35
const GOLDILOCK_DISTANCE_SCALE := GOLDILOCK_REFERENCE_SCALE * 2.0
const GOLDILOCK_SCREEN_CENTER_X := 0.50
const GOLDILOCK_BAND_WIDTH_FACTOR := 0.30
const GOLDILOCK_BAND_MIN_WIDTH_PX := 360.0
const MAX_MOONS := 3

const FANTASY_SINGLE_NAMES := [
	"Bel", "Ash", "Keth", "Vorn", "Lun", "Tal", "Ril", "Karn", "Orn", "Thal",
	"Brin", "Drus", "Fen", "Ith", "Jor", "Lor", "Morn", "Nesh", "Oth", "Ryn",
	"Sarn", "Tor", "Ulm", "Vesh", "Wren", "Ael", "Bael", "Cael", "Daen", "Eld",
	"Fael", "Heth", "Ivar", "Jask", "Loth", "Khar", "Vor", "Ashk", "Bren", "Cald",
	"Dren", "Evor", "Ghal", "Harn", "Irel", "Jurn", "Kest", "Mesk", "Norn", "Oryn",
	"Phel", "Rusk", "Seth", "Tarn", "Ulth", "Varn", "Aurn", "Bryl", "Cask", "Dorn",
	"Frin", "Gesk", "Hov", "Jarn", "Keld", "Lorn", "Malk", "Neth", "Osk", "Pran",
	"Rald", "Siv", "Tov", "Urik", "Wesk", "Aster", "Borth", "Cren", "Eskar", "Forn",
	"Hest", "Ilth", "Jorv", "Krail", "Lusk", "Morv", "Orv", "Pesk", "Rask", "Surn",
	"Uven", "Warn", "Zorn", "Avar", "Brenk", "Cyrn", "Drel", "Gorn", "Istr", "Jeth",
	"Krys", "Morr", "Orel", "Reth", "Skar", "Uth", "Veld", "Zhul", "Bjorn", "Eirik",
	"Leif", "Sten", "Hald", "Gunn", "Rurik", "Hakon", "Alrik", "Soren"
]

const FANTASY_CURATED_NAMES := [
	"Astrael", "Varnis", "Kordesh", "Belora", "Nythar", "Orimel", "Truvain", "Lunara", "Ashkiel", "Mordun",
	"Soryn", "Vaelith", "Draeven", "Thalora", "Yradesh", "Caldrin", "Mireth", "Rovara", "Zerath", "Elandor",
	"Kyralis", "Badesh", "Lotharda", "Fenor", "Neruva", "Qorath", "Averon", "Brivar", "Celesh", "Doreth",
	"Erivash", "Faryn", "Gorune", "Harovar", "Iskara", "Jorven", "Kelora", "Lyrath", "Morvane", "Nolira",
	"Orveth", "Praxora", "Quenor", "Rethys", "Sarune", "Tovaris", "Uraveth", "Virel", "Wynora", "Xerun",
	"Yalara", "Zorvain", "Ashael", "Brenor", "Corveth", "Dralune", "Elvaris", "Ferath", "Galorin", "Heskar",
	"Iralune", "Jastor", "Keldara", "Lorveth", "Myralis", "Nardesh", "Ophira", "Pellune", "Qirath", "Rulora",
	"Selvane", "Tarnel", "Umbrion", "Valeth", "Woralis", "Xandor", "Ylith", "Zarune", "Ardeth", "Briora",
	"Caldora", "Drethys", "Eryth", "Fendara", "Galenor", "Hyrune", "Ithara", "Jorath", "Kryndel", "Luneth",
	"Morash", "Nerath", "Oradis", "Praxel", "Quorune", "Rynora", "Sardel", "Thyra", "Uldara", "Varneth",
	"Weskar", "Xerath", "Yoralis", "Zyndra", "Aldune", "Boreth", "Cyralis", "Drathen", "Elyra", "Fornal",
	"Gryth", "Halune", "Iradesh", "Joralis", "Koveth", "Lareth", "Mirel", "Norune", "Orelith", "Pryndor"
]

const FANTASY_PREFIXES := [
	"ash", "bal", "cor", "dar", "el", "fen", "gal", "har", "isk", "jor",
	"kel", "lor", "mor", "nar", "or", "pra", "rin", "sar", "tor", "ur",
	"vor", "zar", "drav", "khal", "loth", "myr", "neth", "thar", "varn", "bryn",
	"cald", "dren", "glyn", "hest", "jast", "krand", "asha", "aria", "bela", "cora",
	"dara", "elya", "fara", "gala", "hira", "iona", "jora", "kora", "lira", "mera",
	"nora", "oria", "pela", "rhea", "sora", "tala", "uria", "vela", "zora", "seva",
	"aeth", "ael", "aura", "avor", "azel", "baryn", "belor", "berin", "brava", "brin",
	"cael", "calen", "cair", "caren", "ceryn", "ceth", "cyra", "dair", "dalen", "davor",
	"deira", "delor", "dera", "dorin", "drava", "drin", "elyr", "enor", "eris", "felyn",
	"fera", "fira", "fora", "gael", "galen", "garon", "gora", "halen", "havor", "helor",
	"hera", "hyra", "iber", "idra", "ilar", "iren", "isra", "jalen", "jaro", "jovar",
	"kael", "kavor", "kera", "kiran", "laer", "larin", "lavor", "leira", "lenor", "lera",
	"maer", "mavor", "melor", "mira", "navor", "nelor", "nera", "nira", "oira", "orin",
	"ovar", "pael", "parin", "pera", "rael", "relin", "riven", "savor", "selor", "sira",
	"tavor", "teira", "thora", "ulor", "uryn", "vael", "velor", "vera", "voryn", "wavor",
	"welor", "wira", "zorin", "zoral"
]

const FANTASY_MIDDLE_VOWEL := [
	"a", "ae", "ia", "io", "oa", "ui", "ara", "eri", "ila", "ora",
	"une", "eon", "ula", "ira", "aya", "iri", "orae", "e", "i", "o",
	"u", "ai", "ao", "au", "ea", "ei", "eo", "eu", "ie", "iu",
	"oe", "oi", "oo", "ou", "ua", "ue", "uo", "aen", "ain", "aor",
	"eor", "iar", "ior", "iur", "oen", "oir", "our", "uar", "uer", "uin",
	"uor", "alia", "aria", "avia", "elia", "eria", "ilia", "inia", "iova", "olia",
	"onia", "oria", "ovia", "udia", "ulia", "unia", "uria", "aeo", "aio", "eio",
	"ioa", "oia", "uai", "eua", "iau", "oui", "aei"
]

const FANTASY_MIDDLE_CONSONANT := [
	"bar", "dar", "kar", "lor", "mir", "neth", "syl", "tor", "vash", "zen",
	"thal", "drin", "khar", "loth", "myr", "rend", "sarn", "tov", "wyr", "zhar",
	"bel", "cor", "dun", "fen", "gorn", "hyl", "jor", "kyr", "mond", "br",
	"dr", "gr", "kr", "pr", "tr", "vr", "st", "sk", "sp", "sm",
	"sn", "sl", "sh", "th", "kh", "gh", "ch", "ph", "nd", "nt",
	"ld", "lm", "ln", "rn", "rk", "rd", "rt", "rz", "lth", "rth",
	"nth", "mth", "ksh", "dsh", "gth", "ryn", "lorn", "morn", "drel", "dron",
	"grel", "gren", "kren", "krel", "brin", "bryn", "dral", "dren", "fryn", "gral",
	"hrin", "larn", "marn", "narn", "pryn", "rald", "rask", "seld", "tarn", "vorn",
	"besh", "desh", "gesh", "kesh", "lesh", "mesh", "nesh", "resh", "tesh", "veth",
	"weth", "zeth", "cairn", "dairn", "fald", "gald", "hald", "jald", "kald", "lald",
	"mald", "nald", "pald", "raln", "sald", "tald", "vald", "wald"
]

const FANTASY_SUFFIX_VOWEL := [
	"a", "ae", "ia", "ara", "ora", "ira", "ena", "ona", "una", "elia",
	"iora", "itha", "orae", "eon", "uin", "aya", "irae", "ula", "eris", "ana",
	"ava", "ayae", "eia", "ela", "enae", "eria", "essa", "eva", "iae", "ila",
	"ilia", "ina", "iona", "iraa", "isa", "iva", "iya", "oae", "olia", "onae",
	"oraa", "oria", "osa", "ova", "oya", "uae", "ulae", "unae", "uria", "usa",
	"uva", "zea", "zora", "zuna", "arae", "eriae", "ulea", "anea", "ariel", "oriel",
	"uriel", "avel", "anel", "orra", "erra", "ilra", "ulra", "eya", "oyae", "iea",
	"uea", "alia", "arua", "elua", "irua", "orua", "urua"
]

const FANTASY_SUFFIX_CONSONANT := [
	"desh", "veth", "kash", "rion", "thar", "dros", "mora", "lune", "var", "garde",
	"neth", "dris", "vorn", "taris", "bel", "kora", "vash", "thos", "zhar", "myr",
	"dran", "vyr", "lith", "nor", "rath", "shan", "glen", "dun", "rune", "brin",
	"dell", "gor", "hal", "jor", "kyr", "mond", "phar", "besh", "cresh", "fesh",
	"gesh", "hesh", "kesh", "lesh", "mesh", "pesh", "resh", "sesh", "tesh", "wesh",
	"bard", "card", "dard", "fard", "gard", "hard", "kard", "lard", "mard", "nard",
	"pard", "rard", "sard", "tard", "vard", "ward", "bryn", "cryn", "dryn", "fryn",
	"gryn", "hryn", "kryn", "lryn", "mryn", "nryn", "pryn", "rryn", "sryn", "tryn",
	"vryn", "wryn", "brol", "crol", "drol", "frol", "grol", "hrol", "krol", "lrol",
	"mrol", "nrol", "prol", "rrol", "srol", "trol", "vrol", "wrol", "bane", "dane",
	"fane", "gane", "hane", "kane", "lane", "mane", "nane", "pane", "rane", "sane",
	"tane", "vane", "wane", "bion", "cion", "dion", "fion", "gion", "hion", "kion",
	"lion", "mion", "nion", "pion", "sion", "tion", "vion", "wion", "bras", "cras",
	"dras", "fras", "gras", "kras", "lras", "mras", "nras", "pras", "rras", "sras",
	"tras", "vras", "wras"
]

var _phase: int = PHASE_QUOTE
var _phase_time: float = 0.0
var _intro_total_time: float = 0.0
var _sun_prompt_pan_progress: float = SUN_PROMPT_PAN_PROGRESS
var _space_reveal_duration: float = SPACE_REVEAL_SEC
var _camera_pan_duration: float = CAMERA_PAN_SEC

var _star_name: String = ""
var _planet_name: String = ""
var _input_buffer: String = ""
var _active_prompt_kind: int = PROMPT_NONE

var _sun_start_center: Vector2 = Vector2.ZERO
var _sun_end_center: Vector2 = Vector2.ZERO
var _sun_radius: float = 1.0
var _zone_inner_radius: float = 1.0
var _zone_outer_radius: float = 1.0
var _orbit_y: float = 0.0
var _orbit_x_min: float = 0.0
var _orbit_x_max: float = 0.0
var _planet_x: float = 0.0
var _planet_preview_x: float = 0.0
var _planet_has_position: bool = false
var _moon_count: int = 0
var _moon_seed: float = 0.0
var _moon_names: Array[String] = []
var _planet_name_suggestion: String = ""
var _name_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _selected_quote_text: String = DEFAULT_INTRO_QUOTE_TEXT
var _selected_quote_author: String = DEFAULT_INTRO_QUOTE_AUTHOR
var _main_scene_preload_requested: bool = false
var _main_scene_packed: PackedScene = null

var _bigbang_compute: RefCounted = null
var _bg_texture: Texture2D = null
var _skip_to_planet_fade_alpha: float = 0.0
var _skip_to_planet_fade_time: float = 0.0
var _skip_to_planet_fade_active: bool = false

var _quote_label: Label
var _quote_author_label: Label
var _terminal_label: Label
var _planet_hint_label: Label
var _habitable_zone_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_name_rng.randomize()
	_select_intro_quote()
	_configure_pixel_viewport()
	_create_ui()
	_update_layout()
	_bigbang_compute = IntroBigBangCompute.new()
	_update_background_gpu()
	_update_ui_state()
	set_process(true)
	queue_redraw()

func _select_intro_quote() -> void:
	if INTRO_QUOTES.is_empty():
		_set_selected_quote({})
		return
	if _is_first_intro_quote_start():
		_set_selected_quote(INTRO_QUOTES[0])
		_mark_first_intro_quote_shown()
		return
	var idx: int = _name_rng.randi_range(0, INTRO_QUOTES.size() - 1)
	_set_selected_quote(INTRO_QUOTES[idx])

func _set_selected_quote(entry: Dictionary) -> void:
	_selected_quote_text = str(entry.get("text", "")).strip_edges()
	_selected_quote_author = str(entry.get("author", "")).strip_edges()
	if _selected_quote_text.is_empty():
		_selected_quote_text = DEFAULT_INTRO_QUOTE_TEXT
	if _selected_quote_author.is_empty():
		_selected_quote_author = DEFAULT_INTRO_QUOTE_AUTHOR

func _is_first_intro_quote_start() -> bool:
	var cfg := ConfigFile.new()
	var err: int = cfg.load(INTRO_FLAGS_PATH)
	if err != OK:
		return true
	return not bool(cfg.get_value(INTRO_FLAGS_SECTION, INTRO_FLAGS_KEY_FIRST_QUOTE_SHOWN, false))

func _mark_first_intro_quote_shown() -> void:
	var cfg := ConfigFile.new()
	var _err: int = cfg.load(INTRO_FLAGS_PATH)
	cfg.set_value(INTRO_FLAGS_SECTION, INTRO_FLAGS_KEY_FIRST_QUOTE_SHOWN, true)
	cfg.save(INTRO_FLAGS_PATH)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_layout()
		_update_background_gpu()
		queue_redraw()

func _process(delta: float) -> void:
	var dt: float = max(0.0, delta)
	_phase_time += dt
	_intro_total_time += dt
	if _skip_to_planet_fade_active:
		_skip_to_planet_fade_time += dt
		var fade_n: float = clamp(_skip_to_planet_fade_time / max(0.0001, SKIP_TO_PLANET_FADE_SEC), 0.0, 1.0)
		_skip_to_planet_fade_alpha = 1.0 - _ease_in_out(fade_n)
		if fade_n >= 1.0:
			_skip_to_planet_fade_active = false
			_skip_to_planet_fade_alpha = 0.0
	_poll_main_scene_preload()

	match _phase:
		PHASE_QUOTE:
			if _phase_time >= QUOTE_START_DELAY_SEC + QUOTE_FADE_IN_SEC + QUOTE_HOLD_SEC:
				_set_phase(PHASE_BIG_BANG)
		PHASE_BIG_BANG:
			if _phase_time >= _bigbang_total_sec():
				_set_phase(PHASE_SPACE_REVEAL)
		PHASE_SPACE_REVEAL:
			if _phase_time >= _space_reveal_duration:
				_set_phase(PHASE_CAMERA_PAN)
		PHASE_CAMERA_PAN:
			if _phase_time >= _camera_pan_duration:
				_set_phase(PHASE_PLANET_PLACE)
		PHASE_PLANET_PROMPT_FADE_IN:
			if _phase_time >= _planet_story_primary_total_sec():
				if _moon_count > 0:
					_set_phase(PHASE_PLANET_PROMPT_INPUT)
				else:
					_set_phase(PHASE_PLANET_ZOOM)
		PHASE_PLANET_PROMPT_INPUT:
			if _phase_time >= _moon_story_total_sec():
				_set_phase(PHASE_PLANET_ZOOM)
		PHASE_PLANET_PROMPT_FADE_OUT:
			if _phase_time >= PLANET_PROMPT_FADE_OUT_SEC:
				_set_phase(PHASE_PLANET_ZOOM)
		PHASE_PLANET_ZOOM:
			if _phase_time >= PLANET_ZOOM_SEC:
				_finalize_intro_selection()
				_set_phase(PHASE_TRANSITION)
		PHASE_TRANSITION:
			if _phase_time >= TRANSITION_SEC:
				if _main_scene_packed != null:
					get_tree().change_scene_to_packed(_main_scene_packed)
				else:
					get_tree().change_scene_to_file(MAIN_SCENE_PATH)
		_:
			pass

	_update_ui_state()
	if _phase != PHASE_TRANSITION:
		_update_background_gpu()
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if _phase != PHASE_PLANET_PLACE:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_update_planet_preview(mm.position.x)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_update_planet_preview(mb.position.x)
			_confirm_planet_position()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return

	if key.keycode == KEY_ESCAPE:
		if _phase == PHASE_QUOTE or _phase == PHASE_BIG_BANG:
			_skip_to_planet_place()
			return
		if _phase == PHASE_PLANET_PLACE:
			_confirm_planet_position()
			return

	if _is_prompt_input_phase():
		_handle_prompt_key(key)
		return

	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		if _phase == PHASE_PLANET_PLACE:
			_confirm_planet_position()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK, true)

	if _phase != PHASE_TRANSITION:
		_draw_intro_background()

	if _phase == PHASE_PLANET_ZOOM:
		var fade: float = clamp(_phase_time / PLANET_ZOOM_SEC, 0.0, 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, fade), true)
	elif _phase == PHASE_TRANSITION:
		draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK, true)
	if _skip_to_planet_fade_alpha > 0.001:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, _skip_to_planet_fade_alpha), true)

func _configure_pixel_viewport() -> void:
	var viewport_node := get_viewport()
	if viewport_node is SubViewport:
		var sv := viewport_node as SubViewport
		sv.disable_3d = true
		sv.handle_input_locally = true
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var p := get_parent()
	if p != null and p.get_parent() is SubViewportContainer:
		var svc := p.get_parent() as SubViewportContainer
		svc.stretch = true
		svc.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _create_ui() -> void:
	_quote_label = Label.new()
	_quote_label.text = _selected_quote_text
	_quote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_quote_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quote_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_quote_label.add_theme_font_size_override("font_size", 32)
	_quote_label.add_theme_constant_override("line_spacing", -2)
	_quote_label.add_theme_color_override("font_color", Color(0.97, 0.97, 1.0, 1.0))
	add_child(_quote_label)

	_quote_author_label = Label.new()
	_quote_author_label.text = _selected_quote_author
	_quote_author_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_quote_author_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quote_author_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_quote_author_label.add_theme_font_size_override("font_size", 22)
	_quote_author_label.add_theme_color_override("font_color", Color(0.90, 0.92, 1.0, 1.0))
	add_child(_quote_author_label)

	_terminal_label = Label.new()
	_terminal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_terminal_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_terminal_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_terminal_label.add_theme_font_size_override("font_size", 32)
	_terminal_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	add_child(_terminal_label)

	_planet_hint_label = Label.new()
	_planet_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_planet_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_planet_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_planet_hint_label.add_theme_font_size_override("font_size", 32)
	_planet_hint_label.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0, 1.0))
	add_child(_planet_hint_label)

	_habitable_zone_label = Label.new()
	_habitable_zone_label.text = "HABITABLE ZONE"
	_habitable_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_habitable_zone_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_habitable_zone_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_habitable_zone_label.add_theme_font_size_override("font_size", 34)
	_habitable_zone_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.58, 1.0))
	add_child(_habitable_zone_label)

func _update_layout() -> void:
	var w: float = max(1.0, size.x)
	var h: float = max(1.0, size.y)

	if _quote_label != null:
		_quote_label.position = Vector2(w * 0.01, h * 0.325)
		_quote_label.size = Vector2(w * 0.98, h * 0.30)
	if _quote_author_label != null:
		_quote_author_label.position = Vector2(w * 0.60, h * 0.54)
		_quote_author_label.size = Vector2(w * 0.40, h * 0.08)
	if _terminal_label != null:
		_terminal_label.position = Vector2(w * 0.08, h * 0.20)
		_terminal_label.size = Vector2(w * 0.84, h * 0.24)
	if _planet_hint_label != null:
		_planet_hint_label.position = Vector2(w * 0.08, h * 0.58)
		_planet_hint_label.size = Vector2(w * 0.84, h * 0.20)
	if _habitable_zone_label != null:
		_habitable_zone_label.size = Vector2(w * 0.30, h * 0.08)

	_sun_start_center = Vector2(w * SUN_START_X_FACTOR, h * 0.50)
	_sun_end_center = Vector2.ZERO
	_sun_radius = h * 0.95
	var base_inner: float = w * 1.08
	var base_outer: float = w * 1.36
	var base_mid_gap: float = max(0.0, ((base_inner + base_outer) * 0.5) - _sun_radius)
	var gap_scale: float = max(1.0, GOLDILOCK_DISTANCE_SCALE)
	var zone_mid_radius: float = _sun_radius + base_mid_gap * gap_scale
	var band_width: float = max(GOLDILOCK_BAND_MIN_WIDTH_PX, w * GOLDILOCK_BAND_WIDTH_FACTOR)
	var band_half: float = band_width * 0.5
	_zone_inner_radius = max(_sun_radius + 4.0, zone_mid_radius - band_half)
	_zone_outer_radius = _zone_inner_radius + band_width
	zone_mid_radius = (_zone_inner_radius + _zone_outer_radius) * 0.5
	_sun_end_center = Vector2(w * GOLDILOCK_SCREEN_CENTER_X - zone_mid_radius, h * 0.50)
	var pan_denom: float = _sun_end_center.x - _sun_start_center.x
	var sun_rest_x: float = w * SUN_REST_SCREEN_X_FACTOR
	if absf(pan_denom) > 0.0001:
		_sun_prompt_pan_progress = clamp((sun_rest_x - _sun_start_center.x) / pan_denom, 0.0, 1.0)
	else:
		_sun_prompt_pan_progress = SUN_PROMPT_PAN_PROGRESS
	var cur_to_sun: float = absf(sun_rest_x - _sun_start_center.x)
	var ref_to_sun: float = absf(sun_rest_x - w * SUN_REFERENCE_START_X_FACTOR)
	_space_reveal_duration = SPACE_REVEAL_SEC * clamp(cur_to_sun / max(1.0, ref_to_sun), 1.0, 3.5)
	var ref_mid_radius: float = _sun_radius + base_mid_gap * GOLDILOCK_REFERENCE_SCALE
	var ref_end_x: float = w * GOLDILOCK_SCREEN_CENTER_X - ref_mid_radius
	var ref_denom: float = ref_end_x - _sun_start_center.x
	var ref_prompt_pan: float = SUN_PROMPT_PAN_PROGRESS
	if absf(ref_denom) > 0.0001:
		ref_prompt_pan = clamp((sun_rest_x - _sun_start_center.x) / ref_denom, 0.0, 1.0)
	var ref_remaining: float = absf(ref_denom) * max(0.0, 1.0 - ref_prompt_pan)
	var cur_remaining: float = absf(pan_denom) * max(0.0, 1.0 - _sun_prompt_pan_progress)
	var pan_ratio: float = cur_remaining / max(1.0, ref_remaining)
	_camera_pan_duration = CAMERA_PAN_SEC * clamp(pan_ratio, 1.0, 3.5)
	_orbit_y = h * 0.50
	_update_orbit_bounds()
	_update_habitable_zone_label_position()

func _update_orbit_bounds() -> void:
	var inner_x: float = _circle_positive_x_at(_zone_inner_radius, _orbit_y, _sun_end_center)
	var outer_x: float = _circle_positive_x_at(_zone_outer_radius, _orbit_y, _sun_end_center)
	if is_nan(inner_x) or is_nan(outer_x):
		_orbit_x_min = size.x * 0.55
		_orbit_x_max = size.x * 0.82
	else:
		_orbit_x_min = min(inner_x, outer_x)
		_orbit_x_max = max(inner_x, outer_x)
	_orbit_x_min = clamp(_orbit_x_min, 0.0, size.x - 1.0)
	_orbit_x_max = clamp(_orbit_x_max, 0.0, size.x - 1.0)
	if _orbit_x_max <= _orbit_x_min:
		_orbit_x_max = min(size.x - 1.0, _orbit_x_min + 1.0)
	if _planet_preview_x <= 0.0:
		_planet_preview_x = lerp(_orbit_x_min, _orbit_x_max, 0.5)
	if not _planet_has_position:
		_planet_x = _planet_preview_x

func _set_phase(new_phase: int) -> void:
	_phase = new_phase
	_phase_time = 0.0
	_active_prompt_kind = PROMPT_NONE
	match new_phase:
		PHASE_STAR_PROMPT_FADE_IN, PHASE_STAR_PROMPT_INPUT, PHASE_STAR_PROMPT_FADE_OUT, PHASE_SPACE_REVEAL, PHASE_CAMERA_PAN:
			_active_prompt_kind = PROMPT_STAR
			_ensure_star_name_generated()
			_input_buffer = _star_name
			if new_phase == PHASE_CAMERA_PAN:
				_roll_planetary_setup()
		PHASE_PLANET_PROMPT_FADE_IN, PHASE_PLANET_PROMPT_INPUT, PHASE_PLANET_PROMPT_FADE_OUT:
			_active_prompt_kind = PROMPT_PLANET
			_ensure_planet_name_generated()
			_input_buffer = _planet_name
		PHASE_PLANET_PLACE:
			if _planet_preview_x < _orbit_x_min or _planet_preview_x > _orbit_x_max:
				_planet_preview_x = lerp(_orbit_x_min, _orbit_x_max, 0.5)
		_:
			pass

	_update_ui_state()
	if _phase != PHASE_TRANSITION:
		_update_background_gpu()
	queue_redraw()

func _skip_to_planet_place() -> void:
	# Preserve startup consistency normally established by camera-pan.
	_ensure_star_name_generated()
	_roll_planetary_setup()
	_planet_has_position = false
	_set_phase(PHASE_PLANET_PLACE)
	_skip_to_planet_fade_active = true
	_skip_to_planet_fade_time = 0.0
	_skip_to_planet_fade_alpha = 1.0

func _update_ui_state() -> void:
	_update_habitable_zone_label_position()

	var quote_visible: bool = (_phase == PHASE_QUOTE)
	_quote_label.visible = quote_visible
	_quote_author_label.visible = quote_visible
	if quote_visible:
		var q_alpha: float = _get_quote_alpha()
		var pulse: float = 0.92 + 0.08 * sin(_intro_total_time * 2.2)
		_quote_label.modulate = Color(pulse, pulse, pulse, q_alpha)
		_quote_author_label.modulate = Color(0.90, 0.92, 1.0, q_alpha * 0.95)

	_terminal_label.visible = false
	_planet_hint_label.visible = false
	_planet_hint_label.text = ""

	var star_text_visible: bool = (_phase == PHASE_SPACE_REVEAL or _phase == PHASE_CAMERA_PAN)
	if star_text_visible:
		var star_alpha: float = _get_prompt_alpha()
		_terminal_label.visible = star_alpha > 0.001
		if _terminal_label.visible:
			_terminal_label.text = _build_prompt_display_text()
			_terminal_label.modulate = Color(1.0, 1.0, 1.0, star_alpha)
	elif _phase == PHASE_PLANET_PROMPT_FADE_IN:
		var primary_alpha: float = _get_prompt_alpha()
		_terminal_label.visible = primary_alpha > 0.001
		if _terminal_label.visible:
			_terminal_label.text = _build_planet_story_primary_line()
			_terminal_label.modulate = Color(1.0, 0.97, 0.90, primary_alpha)
	elif _phase == PHASE_PLANET_PROMPT_INPUT and _moon_count > 0:
		var secondary_alpha: float = _get_prompt_alpha()
		_planet_hint_label.visible = secondary_alpha > 0.001
		if _planet_hint_label.visible:
			_planet_hint_label.text = _build_planet_story_secondary_line()
			_planet_hint_label.modulate = Color(0.96, 0.96, 1.0, secondary_alpha)
	var zone_label_visible: bool = (
		_phase == PHASE_PLANET_PLACE
		or _phase == PHASE_PLANET_PROMPT_FADE_IN
		or _phase == PHASE_PLANET_PROMPT_INPUT
		or _phase == PHASE_PLANET_PROMPT_FADE_OUT
	)
	var zone_label_alpha: float = 0.0
	if zone_label_visible:
		if _phase == PHASE_PLANET_PLACE:
			zone_label_alpha = clamp(_phase_time / max(0.0001, HABITABLE_ZONE_LABEL_FADE_IN_SEC), 0.0, 1.0)
		else:
			zone_label_alpha = 1.0
	_habitable_zone_label.visible = zone_label_alpha > 0.001
	if zone_label_alpha > 0.001:
		_habitable_zone_label.modulate = Color(1.0, 0.95, 0.74, 0.95 * zone_label_alpha)

func _update_habitable_zone_label_position() -> void:
	if _habitable_zone_label == null:
		return
	var sun_center: Vector2 = _sun_end_center
	var inner: float = _zone_inner_radius
	var outer: float = _zone_outer_radius
	var radial_x: float = (inner + outer) * 0.5
	var zone_label_x: float = sun_center.x + radial_x
	var outer_inside: float = outer * outer - radial_x * radial_x
	var inner_inside: float = inner * inner - radial_x * radial_x
	var outer_top_y: float = sun_center.y - sqrt(max(0.0, outer_inside))
	var zone_label_y: float = outer_top_y + max(1.0, outer - inner) * 0.30
	if inner_inside > 0.0:
		var inner_top_y: float = sun_center.y - sqrt(max(0.0, inner_inside))
		zone_label_y = lerp(outer_top_y, inner_top_y, 0.30)
	zone_label_x = clamp(zone_label_x, size.x * 0.04, size.x * 0.96)
	zone_label_y = clamp(zone_label_y, size.y * 0.04, size.y * 0.90)
	_habitable_zone_label.position = Vector2(
		zone_label_x - _habitable_zone_label.size.x * 0.5,
		zone_label_y - _habitable_zone_label.size.y * 0.5
	)

func _is_prompt_visible_phase() -> bool:
	return (
		_phase == PHASE_SPACE_REVEAL
		or _phase == PHASE_CAMERA_PAN
		or _phase == PHASE_PLANET_PROMPT_FADE_IN
		or _phase == PHASE_PLANET_PROMPT_INPUT
		or _phase == PHASE_PLANET_PROMPT_FADE_OUT
	)

func _is_prompt_input_phase() -> bool:
	return false

func _get_prompt_alpha() -> float:
	match _phase:
		PHASE_SPACE_REVEAL:
			if _active_prompt_kind == PROMPT_STAR:
				return _get_star_prompt_alpha_by_pan(_get_pan_progress())
			return 0.0
		PHASE_CAMERA_PAN:
			if _active_prompt_kind == PROMPT_STAR:
				return _get_star_prompt_alpha_by_pan(_get_pan_progress())
			return 0.0
		PHASE_PLANET_PROMPT_FADE_IN:
			return _story_alpha(_phase_time, PLANET_PROMPT_FADE_IN_SEC, PLANET_STORY_HOLD_SEC, PLANET_PROMPT_FADE_OUT_SEC)
		PHASE_PLANET_PROMPT_INPUT:
			return _story_alpha(_phase_time, MOON_STORY_FADE_IN_SEC, MOON_STORY_HOLD_SEC, MOON_STORY_FADE_OUT_SEC)
		PHASE_PLANET_PROMPT_FADE_OUT:
			return clamp(1.0 - (_phase_time / PLANET_PROMPT_FADE_OUT_SEC), 0.0, 1.0)
		_:
			return 0.0

func _build_prompt_display_text() -> String:
	if _active_prompt_kind == PROMPT_STAR:
		_ensure_star_name_generated()
		return STAR_PROMPT_TEXT % [_star_name]
	if _active_prompt_kind == PROMPT_PLANET:
		if _phase == PHASE_PLANET_PROMPT_FADE_IN:
			return _build_planet_story_primary_line()
		if _phase == PHASE_PLANET_PROMPT_INPUT:
			return _build_planet_story_secondary_line()
	return ""

func _cursor_visible() -> bool:
	return int(floor(_intro_total_time * 2.0)) % 2 == 0

func _handle_prompt_key(key: InputEventKey) -> void:
	if key.keycode == KEY_BACKSPACE:
		if _input_buffer.length() > 0:
			_input_buffer = _input_buffer.substr(0, _input_buffer.length() - 1)
			_update_ui_state()
			queue_redraw()
		return

	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		_commit_prompt_input()
		return

	if key.unicode >= 32 and key.unicode <= 126:
		if _input_buffer.length() < MAX_NAME_LENGTH:
			_input_buffer += char(key.unicode)
			_update_ui_state()
			queue_redraw()

func _commit_prompt_input() -> void:
	return

func _sanitize_name(value: String, fallback_name: String) -> String:
	var cleaned: String = value.strip_edges()
	if cleaned.is_empty():
		return fallback_name
	if cleaned.length() > MAX_NAME_LENGTH:
		return cleaned.substr(0, MAX_NAME_LENGTH)
	return cleaned

func _get_quote_alpha() -> float:
	var t: float = _phase_time - QUOTE_START_DELAY_SEC
	if t <= 0.0:
		return 0.0
	if t <= QUOTE_FADE_IN_SEC:
		return clamp(t / QUOTE_FADE_IN_SEC, 0.0, 1.0)
	return 1.0

func _update_background_gpu() -> void:
	if _bigbang_compute == null:
		return
	if _phase == PHASE_TRANSITION:
		return
	var w: int = max(1, int(size.x))
	var h: int = max(1, int(size.y))

	var phase_idx: int = 0
	var quote_alpha: float = 0.0
	var bigbang_progress: float = 0.0
	var star_alpha: float = 0.0
	var fade_alpha: float = 0.0
	var space_alpha: float = 0.0
	var pan_progress: float = 0.0
	var zoom_scale: float = 1.0

	if _phase == PHASE_QUOTE:
		phase_idx = 0
		quote_alpha = _get_quote_alpha()
	elif _phase == PHASE_BIG_BANG:
		phase_idx = 1
		var event_time: float = _bigbang_event_time(_phase_time)
		# Keep raw progress unbounded so shader can continue slow late expansion.
		bigbang_progress = event_time / max(0.0001, BIG_BANG_EXPANSION_DRIVE_SEC)
		# Reuse quote_alpha push-constant channel as plasma alpha during big bang.
		quote_alpha = _bigbang_plasma_alpha(event_time)
		star_alpha = _bigbang_star_alpha(event_time)
		fade_alpha = _bigbang_fade_alpha(event_time)
	else:
		phase_idx = 2
		space_alpha = _get_space_alpha()
		pan_progress = _get_pan_progress()
		zoom_scale = _get_zoom_scale()

	_bg_texture = _bigbang_compute.render(
		w,
		h,
		phase_idx,
		_phase,
		_phase_time,
		_intro_total_time,
		quote_alpha,
		bigbang_progress,
		star_alpha,
		fade_alpha,
		space_alpha,
		pan_progress,
		zoom_scale,
		_planet_x,
		_planet_preview_x,
		_orbit_y,
		_orbit_x_min,
		_orbit_x_max,
		_sun_start_center,
		_sun_end_center,
		_sun_radius,
		_zone_inner_radius,
		_zone_outer_radius,
		_planet_has_position,
		_moon_count,
		_moon_seed
	)

func _draw_intro_background() -> void:
	if _bg_texture == null:
		return
	if _phase != PHASE_BIG_BANG:
		draw_texture_rect(_bg_texture, Rect2(Vector2.ZERO, size), false)
		return
	var shake_amp: float = _bigbang_shake_amplitude(_bigbang_event_time(_phase_time))
	if shake_amp <= 0.0001:
		draw_texture_rect(_bg_texture, Rect2(Vector2.ZERO, size), false)
		return
	var t: float = _intro_total_time
	var jx: float = sin(t * 73.0) + sin(t * 121.0 + 1.3) + sin(t * 191.0 + 0.7)
	var jy: float = cos(t * 67.0 + 0.4) + sin(t * 149.0 + 2.1) + cos(t * 103.0 + 0.9)
	var px_amp: float = shake_amp * 10.0
	var off := Vector2(jx, jy) * (px_amp / 3.0)
	var margin: float = ceil(px_amp) + 2.0
	var rect := Rect2(Vector2(-margin, -margin) + off, size + Vector2(margin * 2.0, margin * 2.0))
	draw_texture_rect(_bg_texture, rect, false)

func _bigbang_star_alpha(time_sec: float) -> float:
	var ramp_end: float = BIG_BANG_EXPLODE_SEC * 0.55
	if time_sec <= ramp_end:
		var e: float = clamp(time_sec / max(0.0001, ramp_end), 0.0, 1.0)
		return _ease_in_out(e)
	return 1.0

func _bigbang_fade_alpha(time_sec: float) -> float:
	var fade_start: float = _bigbang_effect_total_sec() - BIG_BANG_FADE_SEC
	if time_sec <= fade_start:
		return 0.0
	return clamp((time_sec - fade_start) / max(0.0001, BIG_BANG_FADE_SEC), 0.0, 1.0)

func _bigbang_effect_total_sec() -> float:
	return BIG_BANG_EXPLODE_SEC + BIG_BANG_PLASMA_FADE_SEC + BIG_BANG_STARFIELD_SEC + BIG_BANG_FADE_SEC

func _bigbang_total_sec() -> float:
	return _bigbang_effect_total_sec()

func _bigbang_event_time(time_sec: float) -> float:
	return max(0.0, time_sec)

func _bigbang_plasma_alpha(time_sec: float) -> float:
	if time_sec <= BIG_BANG_EXPLODE_SEC:
		return 1.0
	var t: float = (time_sec - BIG_BANG_EXPLODE_SEC) / max(0.0001, BIG_BANG_PLASMA_FADE_SEC)
	return clamp(1.0 - t, 0.0, 1.0)

func _bigbang_shake_amplitude(time_sec: float) -> float:
	var shake_start: float = BIG_BANG_EXPLODE_SEC * 0.70 + BIG_BANG_SHAKE_START_DELAY_SEC
	var t: float = time_sec - shake_start
	if t <= 0.0:
		return 0.0
	if t < BIG_BANG_SHAKE_RISE_SEC:
		return _ease_in_out(t / BIG_BANG_SHAKE_RISE_SEC)
	var td: float = (t - BIG_BANG_SHAKE_RISE_SEC) / max(0.0001, BIG_BANG_SHAKE_DECAY_SEC)
	if td >= 1.0:
		return 0.0
	return pow(1.0 - td, 1.35)

func _get_space_alpha() -> float:
	if _phase == PHASE_SPACE_REVEAL:
		return 1.0
	if _phase == PHASE_STAR_PROMPT_FADE_IN or _phase == PHASE_STAR_PROMPT_INPUT or _phase == PHASE_STAR_PROMPT_FADE_OUT:
		return 1.0
	if _phase >= PHASE_CAMERA_PAN:
		return 1.0
	return 0.0

func _get_pan_progress() -> float:
	if _phase == PHASE_SPACE_REVEAL:
		# Ease out into the sun: fast-ish start, gentle slowdown while sun enters frame.
		var tn: float = clamp(_phase_time / max(0.0001, _space_reveal_duration), 0.0, 1.0)
		var t: float = 1.0 - pow(1.0 - tn, 2.30)
		return lerp(0.0, _sun_prompt_pan_progress, t)
	if _phase == PHASE_CAMERA_PAN:
		# Start slow after crossing the sun, accelerate, then ease out near habitable zone.
		var t: float = clamp(_phase_time / max(0.0001, _camera_pan_duration), 0.0, 1.0)
		var s: float = t * t * t * (t * (t * 6.0 - 15.0) + 10.0) # smootherstep
		return lerp(_sun_prompt_pan_progress, 1.0, s)
	if _phase >= PHASE_PLANET_PLACE:
		return 1.0
	return 0.0

func _get_star_prompt_alpha_by_pan(pan_progress: float) -> float:
	# Fade in while the sun comes into view, fade out shortly before habitable zone centers.
	var p: float = clamp(pan_progress, 0.0, 1.0)
	var fade_in_start: float = max(0.0, _sun_prompt_pan_progress - 0.10)
	var fade_in_end: float = min(1.0, _sun_prompt_pan_progress + 0.05)
	var fade_out_start: float = 0.80
	var fade_out_end: float = 0.94
	var in_a: float = smoothstep(fade_in_start, fade_in_end, p)
	var out_a: float = 1.0 - smoothstep(fade_out_start, fade_out_end, p)
	return clamp(in_a * out_a, 0.0, 1.0)

func _planet_story_primary_total_sec() -> float:
	return PLANET_PROMPT_FADE_IN_SEC + PLANET_STORY_HOLD_SEC + PLANET_PROMPT_FADE_OUT_SEC

func _moon_story_total_sec() -> float:
	return MOON_STORY_FADE_IN_SEC + MOON_STORY_HOLD_SEC + MOON_STORY_FADE_OUT_SEC

func _story_alpha(time_sec: float, fade_in_sec: float, hold_sec: float, fade_out_sec: float) -> float:
	if time_sec <= 0.0:
		return 0.0
	if time_sec < fade_in_sec:
		return clamp(time_sec / max(0.0001, fade_in_sec), 0.0, 1.0)
	var hold_end: float = fade_in_sec + hold_sec
	if time_sec < hold_end:
		return 1.0
	var fade_out_t: float = time_sec - hold_end
	return clamp(1.0 - fade_out_t / max(0.0001, fade_out_sec), 0.0, 1.0)

func _get_zoom_scale() -> float:
	if _phase != PHASE_PLANET_ZOOM:
		return 1.0
	var t: float = _ease_in_out(clamp(_phase_time / PLANET_ZOOM_SEC, 0.0, 1.0))
	return lerp(1.0, 3.8, t)

func _ease_in_out(t: float) -> float:
	var c: float = clamp(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

func _circle_positive_x_at(radius: float, yv: float, center: Vector2) -> float:
	var dy: float = yv - center.y
	var inside: float = radius * radius - dy * dy
	if inside <= 0.0:
		return NAN
	return center.x + sqrt(inside)

func _update_planet_preview(x_pos: float) -> void:
	_planet_preview_x = clamp(x_pos, _orbit_x_min, _orbit_x_max)
	queue_redraw()

func _confirm_planet_position() -> void:
	if _phase != PHASE_PLANET_PLACE:
		return
	_planet_x = _planet_preview_x
	_planet_has_position = true
	_ensure_planet_name_generated()
	_prepare_startup_world_config()
	_request_main_scene_preload()
	_set_phase(PHASE_PLANET_PROMPT_FADE_IN)

func _current_orbit_norm() -> float:
	var px: float = _planet_x if _planet_has_position else _planet_preview_x
	var denom: float = max(0.0001, _orbit_x_max - _orbit_x_min)
	return clamp((px - _orbit_x_min) / denom, 0.0, 1.0)

func _build_planet_hint_text() -> String:
	if not _planet_has_position:
		return "Move the proto-planet horizontally and click to place it in the goldilocks band."
	var orbit: float = _current_orbit_norm()
	var descriptor: String = "Temperate cradle"
	if orbit <= 0.15:
		descriptor = "Scorched desert world"
	elif orbit <= 0.35:
		descriptor = "Warm arid world"
	elif orbit <= 0.65:
		descriptor = "Balanced temperate world"
	elif orbit <= 0.85:
		descriptor = "Cool continental world"
	else:
		descriptor = "Glacial ice world"
	return "%s | Orbit %.2f (0=hot, 1=cold)." % [descriptor, orbit]

func _roll_planetary_setup() -> void:
	_moon_count = _roll_moon_count(_name_rng)
	_moon_seed = _name_rng.randf_range(1.0, 10000.0)
	_moon_names = _generate_unique_moon_names(_moon_count, _name_rng)
	_planet_name_suggestion = _generate_planet_name(_name_rng)
	_planet_name = _planet_name_suggestion

func _roll_moon_count(rng: RandomNumberGenerator) -> int:
	var roll: float = rng.randf()
	if roll < 0.30:
		return 0
	if roll < 0.70:
		return 1
	if roll < 0.90:
		return 2
	return 3

func _build_moon_prompt_line() -> String:
	if _moon_count <= 0:
		return "Moons: none"
	var parts: Array[String] = []
	for moon_name in _moon_names:
		parts.append(String(moon_name))
	var joined: String = ", ".join(parts)
	var suffix: String = "" if _moon_count == 1 else "s"
	return "Moon%s: %s" % [suffix, joined]

func _build_planet_story_primary_line() -> String:
	_ensure_planet_name_generated()
	return PLANET_PROMPT_TEXT % [_planet_name]

func _build_planet_story_secondary_line() -> String:
	if _moon_count <= 0:
		return ""
	_ensure_planet_name_generated()
	var count_word: String = _number_to_word(_moon_count)
	var noun: String = "moon" if _moon_count == 1 else "moons"
	var moon_names: Array[String] = []
	for moon_name in _moon_names:
		moon_names.append(String(moon_name))
	var joined_names: String = _join_with_and(moon_names)
	return "%s was circled by %s %s named %s." % [_planet_name, count_word, noun, joined_names]

func _join_with_and(items: Array[String]) -> String:
	if items.is_empty():
		return ""
	if items.size() == 1:
		return String(items[0])
	if items.size() == 2:
		return "%s and %s" % [items[0], items[1]]
	var all_but_last: Array[String] = []
	for i in range(items.size() - 1):
		all_but_last.append(String(items[i]))
	return "%s and %s" % [", ".join(all_but_last), items[items.size() - 1]]

func _number_to_word(value: int) -> String:
	match value:
		0:
			return "zero"
		1:
			return "one"
		2:
			return "two"
		3:
			return "three"
		4:
			return "four"
		5:
			return "five"
		_:
			return str(value)

func _generate_unique_moon_names(count: int, rng: RandomNumberGenerator) -> Array[String]:
	var target: int = int(clamp(count, 0, MAX_MOONS))
	var names: Array[String] = []
	if target <= 0:
		return names
	var used := {}
	var guard: int = 0
	while names.size() < target and guard < 256:
		guard += 1
		var candidate: String = _generate_moon_name(rng)
		if used.has(candidate):
			continue
		used[candidate] = true
		names.append(candidate)
	return names

func _generate_planet_name(rng: RandomNumberGenerator) -> String:
	return _generate_fantasy_name(rng, _roll_name_syllable_count(rng))

func _generate_moon_name(rng: RandomNumberGenerator) -> String:
	return _generate_fantasy_name(rng, _roll_name_syllable_count(rng))

func _generate_sun_name(rng: RandomNumberGenerator) -> String:
	return _generate_fantasy_name(rng, _roll_sun_syllable_count(rng))

func _roll_sun_syllable_count(rng: RandomNumberGenerator) -> int:
	if rng.randf() < 0.70:
		return 1
	return 2

func _ensure_star_name_generated() -> void:
	if not _star_name.strip_edges().is_empty():
		return
	_star_name = _generate_sun_name(_name_rng)

func _ensure_planet_name_generated() -> void:
	if not _planet_name.strip_edges().is_empty():
		return
	if _planet_name_suggestion.strip_edges().is_empty():
		_planet_name_suggestion = _generate_planet_name(_name_rng)
	_planet_name = _planet_name_suggestion

func _roll_name_syllable_count(rng: RandomNumberGenerator) -> int:
	var roll: float = rng.randf()
	if roll < 0.55:
		return 1
	if roll < 0.95:
		return 2
	return 3

func _generate_fantasy_name(rng: RandomNumberGenerator, syllables: int) -> String:
	var syl: int = int(clamp(syllables, 1, 3))
	if syl == 1:
		if FANTASY_SINGLE_NAMES.is_empty():
			return "Bel"
		var single_idx: int = rng.randi_range(0, FANTASY_SINGLE_NAMES.size() - 1)
		return String(FANTASY_SINGLE_NAMES[single_idx])

	var prefix: String = _pick_pool_item(FANTASY_PREFIXES, rng)
	var built_name: String = prefix
	if syl >= 3:
		var middle_pool: Array = FANTASY_MIDDLE_VOWEL
		if _ends_with_vowel(built_name):
			middle_pool = FANTASY_MIDDLE_CONSONANT
		built_name += _pick_pool_item(middle_pool, rng)
	var suffix_pool: Array = FANTASY_SUFFIX_VOWEL
	if _ends_with_vowel(built_name):
		suffix_pool = FANTASY_SUFFIX_CONSONANT
	built_name += _pick_pool_item(suffix_pool, rng)
	return _capitalize_name(built_name)

func _pick_pool_item(pool: Array, rng: RandomNumberGenerator) -> String:
	if pool.is_empty():
		return "na"
	var idx: int = rng.randi_range(0, pool.size() - 1)
	return String(pool[idx])

func _ends_with_vowel(value: String) -> bool:
	if value.is_empty():
		return false
	var c: String = value.substr(value.length() - 1, 1).to_lower()
	return c == "a" or c == "e" or c == "i" or c == "o" or c == "u" or c == "y"

func _capitalize_name(value: String) -> String:
	if value.is_empty():
		return value
	return value.substr(0, 1).to_upper() + value.substr(1).to_lower()

func _finalize_intro_selection() -> void:
	_ensure_star_name_generated()
	if _planet_name.strip_edges().is_empty():
		if _planet_name_suggestion.is_empty():
			_planet_name_suggestion = _generate_planet_name(_name_rng)
		_planet_name = _planet_name_suggestion
	if not _planet_has_position:
		_planet_x = _planet_preview_x
		_planet_has_position = true

	var startup_state := get_node_or_null("/root/StartupState")
	if startup_state:
		if "prepare_intro_world_config" in startup_state:
			startup_state.prepare_intro_world_config(_star_name, _current_orbit_norm(), _moon_count, _moon_seed)
		if "set_intro_planet_name" in startup_state:
			startup_state.set_intro_planet_name(_planet_name)
		elif "set_intro_selection" in startup_state:
			startup_state.set_intro_selection(_star_name, _current_orbit_norm(), _planet_name, _moon_count, _moon_seed)
	_request_main_scene_preload()

func _prepare_startup_world_config() -> void:
	var startup_state := get_node_or_null("/root/StartupState")
	if startup_state == null:
		return
	if not ("prepare_intro_world_config" in startup_state):
		return
	_ensure_star_name_generated()
	var prepared_star_name: String = _star_name.strip_edges()
	startup_state.prepare_intro_world_config(prepared_star_name, _current_orbit_norm(), _moon_count, _moon_seed)

func _request_main_scene_preload() -> void:
	if _main_scene_packed != null:
		return
	if _main_scene_preload_requested:
		return
	var req_err: int = ResourceLoader.load_threaded_request(MAIN_SCENE_PATH, "PackedScene")
	if req_err == OK:
		_main_scene_preload_requested = true
		return
	# Fallback when threaded loading is unavailable.
	var loaded: Resource = load(MAIN_SCENE_PATH)
	if loaded is PackedScene:
		_main_scene_packed = loaded as PackedScene

func _poll_main_scene_preload() -> void:
	if not _main_scene_preload_requested:
		return
	var status: int = ResourceLoader.load_threaded_get_status(MAIN_SCENE_PATH)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var loaded: Resource = ResourceLoader.load_threaded_get(MAIN_SCENE_PATH)
		if loaded is PackedScene:
			_main_scene_packed = loaded as PackedScene
		_main_scene_preload_requested = false
	elif status == ResourceLoader.THREAD_LOAD_FAILED:
		_main_scene_preload_requested = false
