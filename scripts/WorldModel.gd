extends Node
class_name WorldModel
const WorldConfig = preload("res://scripts/WorldConfig.gd")
const Utils = preload("res://scripts/Utils.gd")

var w: int
var h: int
var cfg: WorldConfig

var height: Array = []
var base_rock: Array = []
var soil_depth: Array = []
var plate_id: Array = []
var plate_vx: Array = []
var plate_vy: Array = []
var plate_age: Array = []
var temperature: Array = []
var moisture: Array = []
var precip: Array = []
var river: Array = []
var flow_dir: Array = []
var flow_accum: Array = []
var volcanic: Array = []
var biome_id: Array = []
var vegetation: Array = []
var resources: Array = []

var height_buf: Array = []
var soil_buf: Array = []
var volcanic_buf: Array = []
var base_rock_buf: Array = []
var vegetation_buf: Array = []

func _init(width: int, height_: int, cfg_: WorldConfig) -> void:
	w = width
	h = height_
	cfg = cfg_
	_alloc()

func _alloc() -> void:
	var size = w * h
	height.resize(size); base_rock.resize(size); soil_depth.resize(size)
	plate_id.resize(size); plate_vx.resize(size); plate_vy.resize(size); plate_age.resize(size)
	temperature.resize(size); moisture.resize(size); precip.resize(size)
	river.resize(size); flow_dir.resize(size); flow_accum.resize(size)
	volcanic.resize(size); biome_id.resize(size); vegetation.resize(size)
	resources.resize(size)
	height_buf.resize(size); soil_buf.resize(size); volcanic_buf.resize(size)
	base_rock_buf.resize(size); vegetation_buf.resize(size)
	for i in range(size):
		height[i] = 0.0
		base_rock[i] = 0
		soil_depth[i] = 0.0
		plate_id[i] = 0
		plate_vx[i] = 0.0
		plate_vy[i] = 0.0
		plate_age[i] = 0.0
		temperature[i] = 0.0
		moisture[i] = 0.0
		precip[i] = 0.0
		river[i] = 0
		flow_dir[i] = i
		flow_accum[i] = 0.0
		volcanic[i] = 0.0
		biome_id[i] = 0
		vegetation[i] = 0.0
		resources[i] = {}
		height_buf[i] = 0.0
		soil_buf[i] = 0.0
		volcanic_buf[i] = 0.0
		base_rock_buf[i] = 0.0
		vegetation_buf[i] = 0.0

func idx(x: int, y: int) -> int:
	return Utils.idx(x, y, w)

func pos(i: int) -> Vector2i:
	return Vector2i(i % w, floori(float(i) / float(w)))
