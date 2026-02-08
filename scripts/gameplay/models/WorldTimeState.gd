extends RefCounted
class_name WorldTimeStateModel

const SECONDS_PER_DAY: int = 24 * 60 * 60
const MINUTES_PER_DAY: int = 24 * 60
const MONTHS_PER_YEAR: int = 12
# 365-day calendar (no leap years).

var year: int = 1
var month: int = 1
var day: int = 1
var second_of_day: int = 8 * 60 * 60
# Cached minute for legacy call sites; kept in sync with `second_of_day`.
var minute_of_day: int = 8 * 60

func reset_defaults() -> void:
	year = 1
	month = 1
	day = 1
	second_of_day = 8 * 60 * 60
	minute_of_day = second_of_day / 60

func advance_minutes(minutes: int) -> void:
	advance_seconds(max(0, minutes) * 60)

func advance_seconds(seconds: int) -> void:
	if seconds <= 0:
		return
	second_of_day += seconds
	while second_of_day >= SECONDS_PER_DAY:
		second_of_day -= SECONDS_PER_DAY
		day += 1
		if day > days_in_month(month):
			day = 1
			month += 1
			if month > MONTHS_PER_YEAR:
				month = 1
				year += 1
	minute_of_day = clamp(int(second_of_day / 60), 0, MINUTES_PER_DAY - 1)

func season_name() -> String:
	if month <= 3:
		return "Spring"
	if month <= 6:
		return "Summer"
	if month <= 9:
		return "Autumn"
	return "Winter"

func clock_string() -> String:
	var hh: int = int(second_of_day / 3600)
	var mm: int = int((second_of_day / 60) % 60)
	var ss: int = int(second_of_day % 60)
	return "%02d:%02d:%02d" % [hh, mm, ss]

func date_string() -> String:
	return "Y%04d M%02d D%02d" % [year, month, day]

func format_compact() -> String:
	return "%s %s %s" % [date_string(), clock_string(), season_name()]

static func days_in_month(month_value: int) -> int:
	var m: int = clamp(int(month_value), 1, MONTHS_PER_YEAR)
	match m:
		1:
			return 31
		2:
			return 28
		3:
			return 31
		4:
			return 30
		5:
			return 31
		6:
			return 30
		7:
			return 31
		8:
			return 31
		9:
			return 30
		10:
			return 31
		11:
			return 30
		12:
			return 31
		_:
			return 30

func to_dict() -> Dictionary:
	return {
		"year": year,
		"month": month,
		"day": day,
		"second_of_day": second_of_day,
		"minute_of_day": minute_of_day,
	}

static func from_dict(data: Dictionary) -> WorldTimeStateModel:
	var state := WorldTimeStateModel.new()
	state.year = max(1, int(data.get("year", 1)))
	state.month = clamp(int(data.get("month", 1)), 1, MONTHS_PER_YEAR)
	state.day = clamp(int(data.get("day", 1)), 1, days_in_month(state.month))
	if data.has("second_of_day"):
		state.second_of_day = clamp(int(data.get("second_of_day", 8 * 60 * 60)), 0, SECONDS_PER_DAY - 1)
		state.minute_of_day = clamp(int(state.second_of_day / 60), 0, MINUTES_PER_DAY - 1)
	else:
		state.minute_of_day = clamp(int(data.get("minute_of_day", 8 * 60)), 0, MINUTES_PER_DAY - 1)
		state.second_of_day = clamp(state.minute_of_day * 60, 0, SECONDS_PER_DAY - 1)
	return state
