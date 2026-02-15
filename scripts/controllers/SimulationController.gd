extends Node
class_name SimulationController

# Runtime simulation orchestration scaffold for refactor plan M4.
# Keeps timing/scheduling control out of Main over time.

signal runtime_bound

var _time_system: Node = null
var _simulation: Node = null
var _checkpoint: Node = null
var _max_tick_ms: float = 12.0
var _max_systems_per_tick: int = 2

func bind_runtime(time_system: Node, simulation: Node, checkpoint: Node = null) -> void:
	_time_system = time_system
	_simulation = simulation
	_checkpoint = checkpoint
	_apply_runtime_limits()
	emit_signal("runtime_bound")

func set_runtime_limits(max_tick_ms: float, max_systems_per_tick: int) -> void:
	_max_tick_ms = max(0.5, float(max_tick_ms))
	_max_systems_per_tick = max(1, int(max_systems_per_tick))
	_apply_runtime_limits()

func _apply_runtime_limits() -> void:
	if _simulation == null:
		return
	if "set_max_tick_time_ms" in _simulation:
		_simulation.set_max_tick_time_ms(_max_tick_ms)
	if "set_max_systems_per_tick" in _simulation:
		_simulation.set_max_systems_per_tick(_max_systems_per_tick)

func start() -> void:
	if _time_system != null and "start" in _time_system:
		_time_system.start()

func pause() -> void:
	if _time_system != null and "pause" in _time_system:
		_time_system.pause()

func reset_time() -> void:
	if _time_system != null and "reset" in _time_system:
		_time_system.reset()

func set_speed(speed_scale: float) -> void:
	if _time_system != null and "set_time_scale" in _time_system:
		_time_system.set_time_scale(max(1.0, float(speed_scale)))

func set_tick_days(days: float) -> void:
	if _time_system != null and "set_tick_days" in _time_system:
		_time_system.set_tick_days(max(0.0001, float(days)))

func step_once() -> void:
	if _time_system != null and "step_once" in _time_system:
		_time_system.step_once()

func maybe_checkpoint() -> void:
	if _checkpoint == null or _time_system == null:
		return
	if "maybe_checkpoint" in _checkpoint and "simulation_time_days" in _time_system:
		_checkpoint.maybe_checkpoint(float(_time_system.simulation_time_days))

func get_metrics() -> Dictionary:
	var out: Dictionary = {
		"max_tick_ms": _max_tick_ms,
		"max_systems_per_tick": _max_systems_per_tick,
	}
	if _time_system != null:
		out["time_scale"] = float(_time_system.time_scale) if "time_scale" in _time_system else 1.0
		out["tick_days"] = float(_time_system.tick_days) if "tick_days" in _time_system else 0.0
		out["sim_days"] = float(_time_system.simulation_time_days) if "simulation_time_days" in _time_system else 0.0
	return out
