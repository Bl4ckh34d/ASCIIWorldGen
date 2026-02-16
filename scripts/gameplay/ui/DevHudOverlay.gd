extends CanvasLayer
class_name DevHudOverlay

# Minimal dev HUD scaffolding (perf/observability).
# Toggle with F3.

var _label: Label = null
var _panel: PanelContainer = null
var _accum: float = 0.0
const REFRESH_SEC: float = 0.25

func _ready() -> void:
	layer = 2000
	_build_ui()
	visible = false
	set_process_unhandled_input(true)
	set_process(true)

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 10
	_panel.offset_top = 10
	_panel.offset_right = 620
	_panel.offset_bottom = 420
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_label.text = ""
	margin.add_child(_label)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F3:
			visible = not visible
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not visible:
		return
	_accum += max(0.0, delta)
	if _accum < REFRESH_SEC:
		return
	_accum = 0.0
	_refresh_text()

func _refresh_text() -> void:
	if _label == null:
		return
	var gs: Node = get_node_or_null("/root/GameState")
	var fps: float = Engine.get_frames_per_second()
	var lines: PackedStringArray = PackedStringArray()
	lines.append("DEV HUD (F3)")
	lines.append("FPS: %.1f" % fps)
	if gs != null:
		var loc: Dictionary = gs.get_location() if gs.has_method("get_location") else {}
		var wt: String = gs.get_time_label() if gs.has_method("get_time_label") else ""
		lines.append("Time: %s" % wt)
		lines.append("Location: %s" % str(loc))
		lines.append("Seed: %d" % int(gs.world_seed_hash))
		if gs.has_method("get_society_gpu_stats"):
			var sgs: Dictionary = gs.get_society_gpu_stats()
			var b: Variant = sgs.get("buffers", {})
			if typeof(b) == TYPE_DICTIONARY:
				var bd: Dictionary = b as Dictionary
				lines.append("GPU buffers: %d (%.2f MB)" % [int(bd.get("active_buffers", 0)), float(bd.get("total_mb", 0.0))])
			var io: Variant = sgs.get("io", {})
			if typeof(io) == TYPE_DICTIONARY:
				var iod: Dictionary = io as Dictionary
				lines.append("GPU alloc: %d (%.2f MB) | readback: %d (%.2f MB)" % [
					int(iod.get("alloc_count", 0)),
					float(iod.get("alloc_mb", 0.0)),
					int(iod.get("readback_count", 0)),
					float(iod.get("readback_mb", 0.0)),
				])
		if gs.has_method("get_regional_cache_stats"):
			var rv: Variant = gs.get_regional_cache_stats()
			if typeof(rv) == TYPE_DICTIONARY:
				var rs: Dictionary = rv as Dictionary
				if not rs.is_empty():
					var cached: int = int(rs.get("chunks_cached", 0))
					var max_chunks: int = max(1, int(rs.get("max_chunks", 1)))
					var chunk_size: int = int(rs.get("chunk_size", 0))
					var hits: int = int(rs.get("cache_hits_total", 0))
					var misses: int = int(rs.get("cache_misses_total", 0))
					var generated_total: int = int(rs.get("chunks_generated_total", 0))
					var generated_prefetch: int = int(rs.get("chunks_generated_last_prefetch", -1))
					var requested_prefetch: int = int(rs.get("chunks_requested_last_prefetch", -1))
					var lookups: int = hits + misses
					var hit_pct: float = (100.0 * float(hits) / float(lookups)) if lookups > 0 else 0.0
					lines.append("Regional cache: %d/%d chunks (%dm)" % [cached, max_chunks, chunk_size])
					lines.append("Regional cache hit: %.1f%% (%d/%d) | generated: %d" % [hit_pct, hits, lookups, generated_total])
					if generated_prefetch >= 0:
						lines.append("Regional prefetch: %d/%d generated (%.3f ms last | %.3f ms avg)" % [
							generated_prefetch,
							max(0, requested_prefetch),
							float(rs.get("prefetch_ms_last", 0.0)),
							float(rs.get("prefetch_ms_avg", 0.0)),
						])
					var redraw_mode: String = String(rs.get("redraw_mode", ""))
					if not redraw_mode.is_empty():
						lines.append("Regional redraw: %s dx:%d dy:%d %.3f ms | fresh:%d reused:%d" % [
							redraw_mode,
							int(rs.get("redraw_dx", 0)),
							int(rs.get("redraw_dy", 0)),
							float(rs.get("redraw_ms", 0.0)),
							int(rs.get("redraw_fresh_cells", 0)),
							int(rs.get("redraw_reused_cells", 0)),
						])
					var gpu_upload_mode: String = String(rs.get("gpu_upload_mode", ""))
					if not gpu_upload_mode.is_empty():
						lines.append("Regional GPU upload: %s %.3f ms" % [
							gpu_upload_mode,
							float(rs.get("gpu_upload_ms", 0.0)),
						])
					var redraw_samples: int = int(rs.get("redraw_sample_count", 0))
					if redraw_samples > 0:
						lines.append("Regional redraw p50/p95/p99: %.3f / %.3f / %.3f ms (%d samples)" % [
							float(rs.get("redraw_p50_ms", 0.0)),
							float(rs.get("redraw_p95_ms", 0.0)),
							float(rs.get("redraw_p99_ms", 0.0)),
							redraw_samples,
						])
					var chunk_gen_avg_ms: float = float(rs.get("chunk_gen_ms_avg", 0.0))
					if chunk_gen_avg_ms > 0.0:
						lines.append("Regional chunk gen avg/max: %.3f / %.3f ms | evicted: %d" % [
							chunk_gen_avg_ms,
							float(rs.get("chunk_gen_ms_max", 0.0)),
							int(rs.get("chunks_evicted_total", 0)),
						])
					var seam_checks: int = int(rs.get("seam_checks_total", 0))
					if seam_checks > 0:
						lines.append("Regional seams step avg/max: %.4f / %.4f | anomalies: %.2f%% (%d)" % [
							float(rs.get("seam_step_avg", 0.0)),
							float(rs.get("seam_step_max", 0.0)),
							float(rs.get("seam_anomaly_ratio", 0.0)) * 100.0,
							seam_checks,
						])
					lines.append("Regional center: tile(%d,%d) local(%d,%d)" % [
						int(rs.get("world_x", -1)),
						int(rs.get("world_y", -1)),
						int(rs.get("local_x", -1)),
						int(rs.get("local_y", -1)),
					])
		var es: Variant = gs.get("economy_state")
		if es != null:
			lines.append("Economy: settlements %d" % (es.settlements.size() if es != null else 0))
			lines.append("Economy: routes %d" % (es.routes.size() if es != null else 0))
		var ps: Variant = gs.get("politics_state")
		if ps != null:
			lines.append("Politics: states %d provinces %d" % [
				(ps.states.size() if ps != null else 0),
				(ps.provinces.size() if ps != null else 0),
			])
			lines.append("Politics: wars %d treaties %d events %d" % [
				(ps.wars.size() if ps != null else 0),
				(ps.treaties.size() if ps != null else 0),
				(ps.event_log.size() if ps != null else 0),
			])
		var ns: Variant = gs.get("npc_world_state")
		if ns != null:
			lines.append("NPCs: important %d" % (ns.important_npcs.size() if ns != null else 0))
		if gs.has_method("get_civilization_epoch_info"):
			var ei: Variant = gs.get_civilization_epoch_info()
			if typeof(ei) == TYPE_DICTIONARY:
				var ed: Dictionary = ei as Dictionary
				lines.append("Epoch: %s (%s) tech %.2f dev %.2f" % [
					String(ed.get("epoch_id", "prehistoric")),
					String(ed.get("epoch_variant", "stable")),
					float(ed.get("tech_level", 0.0)),
					float(ed.get("global_devastation", 0.0)),
				])
				var te: String = String(ed.get("epoch_target_id", ""))
				if not te.is_empty():
					lines.append("Epoch queued: %s at day %d" % [te, int(ed.get("epoch_shift_due_abs_day", -1))])
		var wf: Variant = gs.get("world_flags")
		if wf != null:
			lines.append("Visited tiles: %d" % int(wf.visited_world_tiles.size()))
	_label.text = "\n".join(lines)
