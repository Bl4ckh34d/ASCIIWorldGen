extends RefCounted
class_name EconomySim

const EconomyStateModel = preload("res://scripts/gameplay/models/EconomyState.gd")
const CommodityCatalog = preload("res://scripts/gameplay/catalog/CommodityCatalog.gd")

# Background daily economy tick.
# This is a minimal deterministic "plumbing" pass to prove save/load + ticking.

static func tick_day(_world_seed_hash: int, econ: EconomyStateModel, abs_day: int) -> void:
	if econ == null:
		return
	# If nothing is defined yet, this is a no-op by design.
	for k in econ.settlements.keys():
		var st: Variant = econ.settlements.get(k)
		if typeof(st) != TYPE_DICTIONARY:
			continue
		var s: Dictionary = (st as Dictionary).duplicate(true)
		_tick_settlement_day(s)
		s["last_update_abs_day"] = abs_day
		econ.settlements[k] = s

static func _tick_settlement_day(s: Dictionary) -> void:
	# v0: stockpiles drift by (production - consumption); prices follow scarcity.
	var prod: Dictionary = s.get("production", {})
	var cons: Dictionary = s.get("consumption", {})
	var stock: Dictionary = s.get("stockpile", {})
	var prices: Dictionary = s.get("prices", {})
	var scarcity: Dictionary = s.get("scarcity", {})

	if typeof(prod) != TYPE_DICTIONARY:
		prod = {}
	if typeof(cons) != TYPE_DICTIONARY:
		cons = {}
	if typeof(stock) != TYPE_DICTIONARY:
		stock = {}
	if typeof(prices) != TYPE_DICTIONARY:
		prices = {}
	if typeof(scarcity) != TYPE_DICTIONARY:
		scarcity = {}

	# Union keys from prod/cons/stock for a stable update.
	var keys: Array = []
	for kk in prod.keys():
		keys.append(kk)
	for kk in cons.keys():
		if not keys.has(kk):
			keys.append(kk)
	for kk in stock.keys():
		if not keys.has(kk):
			keys.append(kk)

	for kk in keys:
		var p: float = float(prod.get(kk, 0.0))
		var c: float = float(cons.get(kk, 0.0))
		var v: float = float(stock.get(kk, 0.0))
		v = max(0.0, v + p - c)
		stock[kk] = v
		# Scarcity proxy: if stockpile is small compared to daily consumption, scarcity rises.
		var denom: float = max(0.001, c)
		var days_cover: float = v / denom
		var sc: float = clamp(1.0 - (days_cover / 7.0), 0.0, 1.0) # 0 when >= 7 days cover
		scarcity[kk] = sc
		# Price proxy: base 1.0, inflated by scarcity.
		var base_price: float = float(prices.get(kk, CommodityCatalog.base_price(String(kk))))
		var target: float = 1.0 + sc * 1.25
		prices[kk] = clamp(lerp(base_price, target, 0.20), 0.05, 50.0)

	s["production"] = prod
	s["consumption"] = cons
	s["stockpile"] = stock
	s["prices"] = prices
	s["scarcity"] = scarcity
