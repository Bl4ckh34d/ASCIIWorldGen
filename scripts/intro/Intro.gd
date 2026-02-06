# File: res://scripts/intro/Intro.gd
extends Control

const IntroBigBangCompute = preload("res://scripts/intro/IntroBigBangCompute.gd")

const TARGET_VIEWPORT_SIZE := Vector2i(1770, 830)
const QUOTE_TEXT := "\"If you wish to make an apple pie from scratch,\nyou must first invent the universe\""
const QUOTE_AUTHOR_TEXT := "- Carl Sagan"
const STAR_PROMPT_TEXT := "Then there was light and this goddess of life had a name: "
const PLANET_PROMPT_TEXT := "A new world was born and her\nname was: "
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
const STAR_PROMPT_FADE_OUT_SEC := 0.95
const SPACE_REVEAL_SEC := 4.80
const CAMERA_PAN_SEC := 5.10
const PLANET_PROMPT_FADE_IN_SEC := 0.95
const PLANET_PROMPT_FADE_OUT_SEC := 0.95
const PLANET_ZOOM_SEC := 1.95
const TRANSITION_SEC := 0.18
const SUN_PROMPT_PAN_PROGRESS := 0.45
const GOLDILOCK_REFERENCE_SCALE := 2.35
const GOLDILOCK_DISTANCE_SCALE := GOLDILOCK_REFERENCE_SCALE * 2.0
const GOLDILOCK_SCREEN_CENTER_X := 0.50
const GOLDILOCK_BAND_WIDTH_FACTOR := 0.30
const GOLDILOCK_BAND_MIN_WIDTH_PX := 360.0
const MAX_MOONS := 3

const FANTASY_SINGLE_NAMES := [
	"Bel", "Trus", "Ash", "Keth", "Nyr", "Vorn", "Lun", "Tal", "Syr", "Ril",
	"Karn", "Myr", "Zel", "Orn", "Thal", "Brin", "Cyr", "Drus", "Fen", "Ith",
	"Jor", "Kyr", "Lor", "Morn", "Nesh", "Oth", "Prax", "Quor", "Ryn", "Sarn",
	"Tor", "Ulm", "Vesh", "Wren", "Xal", "Yor", "Zhin", "Ael", "Bael", "Cael",
	"Daen", "Eld", "Fael", "Grax", "Heth", "Ivar", "Jask", "Loth", "Khar", "Vor",
	"Ashk", "Bren", "Cald", "Dren", "Evor", "Fyrn", "Ghal", "Harn", "Irel", "Jurn",
	"Kest", "Lyrn", "Mesk", "Norn", "Oryn", "Phel", "Qarn", "Rusk", "Seth", "Tarn",
	"Ulth", "Varn", "Wyst", "Xern", "Yvyr", "Zarn", "Arix", "Bast", "Corth", "Dask",
	"Elyn", "Fask", "Grun", "Hyrn", "Inor", "Jyss", "Kroth", "Lask", "Myrk", "Nol",
	"Orr", "Pyrn", "Qeth", "Rhov", "Syth", "Tusk", "Urn", "Vesk", "Wor", "Xyr",
	"Yast", "Zeth", "Aurn", "Bryl", "Cask", "Dorn", "Erix", "Frin", "Gesk", "Hov",
	"Ixar", "Jarn", "Keld", "Lorn", "Malk", "Neth", "Osk", "Pran", "Qor", "Rald",
	"Siv", "Tov", "Urik", "Vyx", "Wesk", "Xarn", "Yorn", "Zyr", "Astrix", "Borth",
	"Cren", "Dyth", "Eskar", "Forn", "Gyr", "Hest", "Ilth", "Jorv", "Krail", "Lusk",
	"Morv", "Nyrn", "Orv", "Pesk", "Qirn", "Rask", "Surn", "Tyr", "Uven", "Vryk",
	"Warn", "Xoss", "Ysel", "Zorn", "Avar", "Brenk", "Cyrn", "Drel", "Fyr", "Gorn",
	"Hyr", "Istr", "Jeth", "Krys", "Lyr", "Morr", "Nysk", "Orel", "Pyr", "Quarn",
	"Reth", "Skar", "Thyr", "Uth", "Veld", "Wyr", "Xeth", "Yrik", "Zhul"
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
	"kel", "lor", "mor", "nar", "or", "pra", "quel", "ryn", "sar", "tor",
	"ur", "vor", "wyn", "xan", "yor", "zar", "drav", "khal", "loth", "myr",
	"neth", "thar", "varn", "bryn", "cald", "dren", "glyn", "hest", "jast", "krand",
	"asha", "aria", "bela", "cora", "dara", "elya", "fara", "gala", "hira", "iona",
	"jora", "kora", "lira", "mera", "nora", "oria", "pela", "qira", "rhea", "sora",
	"tala", "uria", "vela", "wira", "xera", "yara", "zora", "lyra", "nyra", "seva",
	"aeth", "ael", "aura", "avor", "azel", "baryn", "belor", "berin", "brava", "brin",
	"cael", "calen", "cair", "caren", "ceryn", "ceth", "cyra", "dair", "dalen", "davor",
	"deira", "delor", "dera", "dorin", "drava", "drin", "elyr", "enor", "eris", "felyn",
	"fera", "fira", "fora", "gael", "galen", "garon", "gora", "halen", "havor", "helor",
	"hera", "hyra", "iber", "idra", "ilar", "iren", "isra", "jalen", "jaro", "jovar",
	"kael", "kavor", "kera", "kiran", "korae", "krya", "laer", "larin", "lavor", "leira",
	"lenor", "lera", "maer", "mavor", "melor", "mira", "navor", "nelor", "nera", "nira",
	"oira", "orin", "ovar", "pael", "parin", "pera", "qalen", "qora", "rael", "ravyn",
	"relin", "riven", "savor", "selor", "sira", "tavor", "teira", "thora", "ulor", "uryn",
	"vael", "velor", "vera", "voryn", "wavor", "welor", "wirae", "xavor", "xelor", "xira",
	"yael", "yavor", "yelor", "zira", "zorin", "zoral"
]

const FANTASY_MIDDLE_VOWEL := [
	"a", "ae", "ia", "io", "oa", "ui", "ara", "eri", "ila", "ora",
	"une", "yri", "eon", "ula", "ira", "aya", "iri", "orae", "e", "i",
	"o", "u", "ai", "ao", "au", "ea", "ei", "eo", "eu", "ie",
	"iu", "oe", "oi", "oo", "ou", "ua", "ue", "uo", "aen", "ain",
	"aor", "eor", "iar", "ior", "iur", "oen", "oir", "our", "uar", "uer",
	"uin", "uor", "yth", "alia", "aria", "avia", "elia", "eria", "ilia", "inia",
	"iova", "olia", "onia", "oria", "ovia", "udia", "ulia", "unia", "uria", "ylia",
	"yria", "yora", "yuna", "aeo", "aio", "eio", "ioa", "oia", "uai", "eua",
	"iau", "oui", "aei"
]

const FANTASY_MIDDLE_CONSONANT := [
	"bar", "dar", "kar", "lor", "mir", "neth", "syl", "tor", "vash", "zen",
	"thal", "drin", "khar", "loth", "myr", "rend", "sarn", "tov", "wyr", "zhar",
	"bel", "cor", "dun", "fen", "gorn", "hyl", "jor", "kyr", "lax", "mond",
	"br", "dr", "gr", "kr", "pr", "tr", "vr", "zr", "st", "sk",
	"sp", "sm", "sn", "sl", "sr", "sh", "th", "kh", "gh", "ch",
	"ph", "xh", "nd", "nt", "ld", "lm", "ln", "rn", "rk", "rd",
	"rt", "rz", "lth", "rth", "nth", "mth", "vyr", "zyr", "ksh", "dsh",
	"gth", "phr", "xth", "ryn", "lorn", "morn", "drel", "dron", "grel", "gren",
	"kren", "krel", "brin", "bryn", "cryn", "dral", "dren", "fryn", "gral", "hrin",
	"jren", "larn", "lryn", "marn", "narn", "pryn", "qryn", "rald", "rask", "seld",
	"tarn", "vorn", "wryn", "xarn", "zarn", "besh", "desh", "gesh", "kesh", "lesh",
	"mesh", "nesh", "resh", "tesh", "veth", "weth", "xeth", "zeth", "cairn", "dairn",
	"fald", "gald", "hald", "jald", "kald", "lald", "mald", "nald", "pald", "qald",
	"raln", "sald", "tald", "vald", "wald", "xald", "yald", "zald"
]

const FANTASY_SUFFIX_VOWEL := [
	"a", "ae", "ia", "ara", "ora", "ira", "ena", "ona", "una", "elia",
	"iora", "itha", "orae", "yra", "eon", "uin", "aya", "irae", "ula", "eris",
	"ana", "ava", "ayae", "eia", "ela", "enae", "eria", "essa", "eva", "iae",
	"ila", "ilia", "ina", "iona", "iraa", "isa", "iva", "iya", "oae", "olia",
	"onae", "oraa", "oria", "osa", "ova", "oya", "uae", "ulae", "unae", "uria",
	"usa", "uva", "uya", "yla", "yria", "yrae", "yuna", "zea", "zora", "zuna",
	"arae", "eriae", "ulea", "anea", "ariel", "oriel", "uriel", "avel", "anel", "orra",
	"erra", "ilra", "ulra", "eya", "oyae", "iea", "uea", "alia", "arua", "elua",
	"irua", "orua", "urua", "ynia", "yriae", "yorae"
]

const FANTASY_SUFFIX_CONSONANT := [
	"desh", "veth", "kash", "rion", "thar", "dros", "mora", "lune", "var", "garde",
	"neth", "dris", "vorn", "taris", "bel", "kora", "vash", "thos", "zhar", "myr",
	"dran", "vyr", "lith", "nor", "rath", "shan", "glen", "dun", "rune", "xis",
	"qir", "brin", "dell", "gor", "hal", "jor", "kyr", "mond", "nox", "phar",
	"besh", "cresh", "fesh", "gesh", "hesh", "kesh", "lesh", "mesh", "pesh", "qesh",
	"resh", "sesh", "tesh", "wesh", "xesh", "yesh", "zesh", "bard", "card", "dard",
	"fard", "gard", "hard", "kard", "lard", "mard", "nard", "pard", "qard", "rard",
	"sard", "tard", "vard", "ward", "xard", "yard", "zard", "bryn", "cryn", "dryn",
	"fryn", "gryn", "hryn", "kryn", "lryn", "mryn", "nryn", "pryn", "qryn", "rryn",
	"sryn", "tryn", "vryn", "wryn", "xryn", "yryn", "zryn", "brol", "crol", "drol",
	"frol", "grol", "hrol", "krol", "lrol", "mrol", "nrol", "prol", "qrol", "rrol",
	"srol", "trol", "vrol", "wrol", "xrol", "yrol", "zrol", "bane", "dane", "fane",
	"gane", "hane", "kane", "lane", "mane", "nane", "pane", "rane", "sane", "tane",
	"vane", "wane", "xane", "yane", "zane", "bion", "cion", "dion", "fion", "gion",
	"hion", "kion", "lion", "mion", "nion", "pion", "sion", "tion", "vion", "wion",
	"xion", "yion", "zion", "bras", "cras", "dras", "fras", "gras", "kras", "lras",
	"mras", "nras", "pras", "qras", "rras", "sras", "tras", "vras", "wras", "xras",
	"yras", "zras"
]

var _phase: int = PHASE_QUOTE
var _phase_time: float = 0.0
var _intro_total_time: float = 0.0
var _sun_prompt_pan_progress: float = SUN_PROMPT_PAN_PROGRESS
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

var _bigbang_compute: RefCounted = null
var _bg_texture: Texture2D = null

var _quote_label: Label
var _quote_author_label: Label
var _terminal_label: Label
var _planet_hint_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_name_rng.randomize()
	_configure_pixel_viewport()
	_create_ui()
	_update_layout()
	_bigbang_compute = IntroBigBangCompute.new()
	_update_background_gpu()
	_update_ui_state()
	set_process(true)
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_layout()
		_update_background_gpu()
		queue_redraw()

func _process(delta: float) -> void:
	var dt: float = max(0.0, delta)
	_phase_time += dt
	_intro_total_time += dt

	match _phase:
		PHASE_QUOTE:
			if _phase_time >= QUOTE_START_DELAY_SEC + QUOTE_FADE_IN_SEC + QUOTE_HOLD_SEC:
				_set_phase(PHASE_BIG_BANG)
		PHASE_BIG_BANG:
			if _phase_time >= _bigbang_total_sec():
				_set_phase(PHASE_SPACE_REVEAL)
		PHASE_STAR_PROMPT_FADE_IN:
			if _phase_time >= STAR_PROMPT_FADE_IN_SEC:
				_set_phase(PHASE_STAR_PROMPT_INPUT)
		PHASE_STAR_PROMPT_FADE_OUT:
			if _phase_time >= STAR_PROMPT_FADE_OUT_SEC:
				_set_phase(PHASE_CAMERA_PAN)
		PHASE_SPACE_REVEAL:
			if _phase_time >= SPACE_REVEAL_SEC:
				_set_phase(PHASE_STAR_PROMPT_FADE_IN)
		PHASE_CAMERA_PAN:
			if _phase_time >= _camera_pan_duration:
				_set_phase(PHASE_PLANET_PLACE)
		PHASE_PLANET_PROMPT_FADE_IN:
			if _phase_time >= PLANET_PROMPT_FADE_IN_SEC:
				_set_phase(PHASE_PLANET_PROMPT_INPUT)
		PHASE_PLANET_PROMPT_FADE_OUT:
			if _phase_time >= PLANET_PROMPT_FADE_OUT_SEC:
				_set_phase(PHASE_PLANET_ZOOM)
		PHASE_PLANET_ZOOM:
			if _phase_time >= PLANET_ZOOM_SEC:
				_finalize_intro_selection()
				_set_phase(PHASE_TRANSITION)
		PHASE_TRANSITION:
			if _phase_time >= TRANSITION_SEC:
				get_tree().change_scene_to_file("res://scenes/Main.tscn")
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
			_set_phase(PHASE_STAR_PROMPT_FADE_IN)
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
	_quote_label.text = QUOTE_TEXT
	_quote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_quote_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quote_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_quote_label.add_theme_font_size_override("font_size", 32)
	_quote_label.add_theme_constant_override("line_spacing", -2)
	_quote_label.add_theme_color_override("font_color", Color(0.97, 0.97, 1.0, 1.0))
	add_child(_quote_label)

	_quote_author_label = Label.new()
	_quote_author_label.text = QUOTE_AUTHOR_TEXT
	_quote_author_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_quote_author_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quote_author_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_quote_author_label.add_theme_font_size_override("font_size", 22)
	_quote_author_label.add_theme_color_override("font_color", Color(0.90, 0.92, 1.0, 1.0))
	add_child(_quote_author_label)

	_terminal_label = Label.new()
	_terminal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_terminal_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_terminal_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_terminal_label.add_theme_font_size_override("font_size", 32)
	_terminal_label.add_theme_color_override("font_color", Color(0.99, 0.97, 0.90, 1.0))
	add_child(_terminal_label)

	_planet_hint_label = Label.new()
	_planet_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_planet_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_planet_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_planet_hint_label.add_theme_font_size_override("font_size", 18)
	_planet_hint_label.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0, 1.0))
	add_child(_planet_hint_label)

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
		_terminal_label.position = Vector2(w * 0.16, h * 0.28)
		_terminal_label.size = Vector2(w * 0.74, h * 0.36)
	if _planet_hint_label != null:
		_planet_hint_label.position = Vector2(w * 0.08, h * 0.78)
		_planet_hint_label.size = Vector2(w * 0.84, h * 0.18)

	_sun_start_center = Vector2(w * 1.38, h * 0.50)
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
	if absf(pan_denom) > 0.0001:
		_sun_prompt_pan_progress = clamp((w * 0.5 - _sun_start_center.x) / pan_denom, 0.0, 1.0)
	else:
		_sun_prompt_pan_progress = SUN_PROMPT_PAN_PROGRESS
	var ref_mid_radius: float = _sun_radius + base_mid_gap * GOLDILOCK_REFERENCE_SCALE
	var ref_end_x: float = w * GOLDILOCK_SCREEN_CENTER_X - ref_mid_radius
	var ref_denom: float = ref_end_x - _sun_start_center.x
	var ref_prompt_pan: float = SUN_PROMPT_PAN_PROGRESS
	if absf(ref_denom) > 0.0001:
		ref_prompt_pan = clamp((w * 0.5 - _sun_start_center.x) / ref_denom, 0.0, 1.0)
	var ref_remaining: float = absf(ref_denom) * max(0.0, 1.0 - ref_prompt_pan)
	var cur_remaining: float = absf(pan_denom) * max(0.0, 1.0 - _sun_prompt_pan_progress)
	var pan_ratio: float = cur_remaining / max(1.0, ref_remaining)
	_camera_pan_duration = CAMERA_PAN_SEC * clamp(pan_ratio, 1.0, 3.5)
	_orbit_y = h * 0.50
	_update_orbit_bounds()

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
		PHASE_STAR_PROMPT_FADE_IN, PHASE_STAR_PROMPT_INPUT, PHASE_STAR_PROMPT_FADE_OUT:
			_active_prompt_kind = PROMPT_STAR
			if _star_name.is_empty():
				_input_buffer = ""
			else:
				_input_buffer = _star_name
		PHASE_PLANET_PROMPT_FADE_IN, PHASE_PLANET_PROMPT_INPUT, PHASE_PLANET_PROMPT_FADE_OUT:
			_active_prompt_kind = PROMPT_PLANET
			if _planet_name.is_empty():
				if _planet_name_suggestion.is_empty():
					_planet_name_suggestion = _generate_planet_name(_name_rng)
				_input_buffer = _planet_name_suggestion
			else:
				_input_buffer = _planet_name
		PHASE_PLANET_PLACE:
			if _planet_preview_x < _orbit_x_min or _planet_preview_x > _orbit_x_max:
				_planet_preview_x = lerp(_orbit_x_min, _orbit_x_max, 0.5)
			_roll_planetary_setup()
		_:
			pass

	_update_ui_state()
	if _phase != PHASE_TRANSITION:
		_update_background_gpu()
	queue_redraw()

func _update_ui_state() -> void:
	var quote_visible: bool = (_phase == PHASE_QUOTE)
	_quote_label.visible = quote_visible
	_quote_author_label.visible = quote_visible
	if quote_visible:
		var q_alpha: float = _get_quote_alpha()
		var pulse: float = 0.92 + 0.08 * sin(_intro_total_time * 2.2)
		_quote_label.modulate = Color(pulse, pulse, pulse, q_alpha)
		_quote_author_label.modulate = Color(0.90, 0.92, 1.0, q_alpha * 0.95)

	var terminal_visible: bool = _is_prompt_visible_phase()
	_terminal_label.visible = terminal_visible
	if terminal_visible:
		var p_alpha: float = _get_prompt_alpha()
		_terminal_label.text = _build_prompt_display_text()
		_terminal_label.modulate = Color(1.0, 0.97, 0.90, p_alpha)

	_planet_hint_label.visible = false
	_planet_hint_label.text = ""

func _is_prompt_visible_phase() -> bool:
	return (
		_phase == PHASE_STAR_PROMPT_FADE_IN
		or _phase == PHASE_STAR_PROMPT_INPUT
		or _phase == PHASE_STAR_PROMPT_FADE_OUT
		or _phase == PHASE_PLANET_PROMPT_FADE_IN
		or _phase == PHASE_PLANET_PROMPT_INPUT
		or _phase == PHASE_PLANET_PROMPT_FADE_OUT
	)

func _is_prompt_input_phase() -> bool:
	return _phase == PHASE_STAR_PROMPT_INPUT or _phase == PHASE_PLANET_PROMPT_INPUT

func _get_prompt_alpha() -> float:
	match _phase:
		PHASE_STAR_PROMPT_FADE_IN:
			return clamp(_phase_time / STAR_PROMPT_FADE_IN_SEC, 0.0, 1.0)
		PHASE_STAR_PROMPT_INPUT:
			return 1.0
		PHASE_STAR_PROMPT_FADE_OUT:
			return clamp(1.0 - (_phase_time / STAR_PROMPT_FADE_OUT_SEC), 0.0, 1.0)
		PHASE_PLANET_PROMPT_FADE_IN:
			return clamp(_phase_time / PLANET_PROMPT_FADE_IN_SEC, 0.0, 1.0)
		PHASE_PLANET_PROMPT_INPUT:
			return 1.0
		PHASE_PLANET_PROMPT_FADE_OUT:
			return clamp(1.0 - (_phase_time / PLANET_PROMPT_FADE_OUT_SEC), 0.0, 1.0)
		_:
			return 0.0

func _build_prompt_display_text() -> String:
	var prompt: String = ""
	match _active_prompt_kind:
		PROMPT_STAR:
			prompt = STAR_PROMPT_TEXT
		PROMPT_PLANET:
			prompt = PLANET_PROMPT_TEXT
		_:
			return ""

	var value: String = _input_buffer
	var cursor: String = ""
	if _is_prompt_input_phase() and _cursor_visible():
		cursor = "_"
	var text: String = prompt + value + cursor
	if _active_prompt_kind == PROMPT_PLANET:
		text += "\n\n" + _build_moon_prompt_line()
	return text

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
	var cleaned: String = _input_buffer.strip_edges()
	if cleaned.is_empty():
		return
	if _phase == PHASE_STAR_PROMPT_INPUT:
		_star_name = _sanitize_name(cleaned, "Unnamed Star")
		_input_buffer = _star_name
		_set_phase(PHASE_STAR_PROMPT_FADE_OUT)
	elif _phase == PHASE_PLANET_PROMPT_INPUT:
		_planet_name = _sanitize_name(cleaned, "Unnamed World")
		_input_buffer = _planet_name
		_set_phase(PHASE_PLANET_PROMPT_FADE_OUT)

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
		var t: float = _ease_in_out(clamp(_phase_time / SPACE_REVEAL_SEC, 0.0, 1.0))
		return lerp(0.0, _sun_prompt_pan_progress, t)
	if _phase == PHASE_STAR_PROMPT_FADE_IN or _phase == PHASE_STAR_PROMPT_INPUT or _phase == PHASE_STAR_PROMPT_FADE_OUT:
		return _sun_prompt_pan_progress
	if _phase == PHASE_CAMERA_PAN:
		var t: float = _ease_in_out(clamp(_phase_time / max(0.0001, _camera_pan_duration), 0.0, 1.0))
		return lerp(_sun_prompt_pan_progress, 1.0, t)
	if _phase >= PHASE_PLANET_PLACE:
		return 1.0
	return 0.0

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

func _roll_name_syllable_count(rng: RandomNumberGenerator) -> int:
	var roll: float = rng.randf()
	if roll < 0.50:
		return 1
	if roll < 0.85:
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
	if _star_name.strip_edges().is_empty():
		_star_name = "Unnamed Star"
	if _planet_name.strip_edges().is_empty():
		if _planet_name_suggestion.is_empty():
			_planet_name_suggestion = _generate_planet_name(_name_rng)
		_planet_name = _planet_name_suggestion
	if not _planet_has_position:
		_planet_x = _planet_preview_x
		_planet_has_position = true

	var startup_state := get_node_or_null("/root/StartupState")
	if startup_state and "set_intro_selection" in startup_state:
		startup_state.set_intro_selection(_star_name, _current_orbit_norm(), _planet_name, _moon_count, _moon_seed)
