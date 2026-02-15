# File: res://scripts/core/JobSystem.gd
extends RefCounted
const VariantCasts = preload("res://scripts/core/VariantCasts.gd")

## Thin wrapper intended to stripe work across rows; sequential for now.
var worker_threads_enabled: bool = false
var max_worker_threads: int = 0
var min_rows_per_worker: int = 32

func configure_threads(enabled: bool, max_workers: int = 0, min_rows: int = 32) -> void:
	worker_threads_enabled = VariantCasts.to_bool(enabled)
	max_worker_threads = max(0, int(max_workers))
	min_rows_per_worker = max(1, int(min_rows))

func run_rows(height: int, job: Callable) -> void:
	# Calls job(row_index) for each row sequentially.
	for y in range(max(0, height)):
		job.call(y)

func run_stripes(height: int, stripes: int, job: Callable) -> void:
	# Calls job(start_row, end_row) for each contiguous stripe.
	# Threaded mode is opt-in and intended for CPU fallback paths only.
	var total_h: int = max(0, height)
	var num: int = max(1, stripes)
	if total_h <= 0:
		return
	if worker_threads_enabled and num > 1 and total_h >= min_rows_per_worker * 2:
		if _run_stripes_threaded(total_h, num, job):
			return
	var rows_per: int = int(ceil(float(total_h) / float(num)))
	var start: int = 0
	while start < total_h:
		var end_i: int = min(total_h, start + rows_per)
		job.call(start, end_i)
		start = end_i

func _build_stripe_tasks(total_h: int, stripes: int) -> Array[Dictionary]:
	var tasks: Array[Dictionary] = []
	var rows_per: int = int(ceil(float(total_h) / float(max(1, stripes))))
	var start: int = 0
	while start < total_h:
		var end_i: int = min(total_h, start + rows_per)
		tasks.append({"start": start, "end": end_i})
		start = end_i
	return tasks

func _recommended_workers(task_count: int, total_h: int) -> int:
	var cpu_workers: int = max(1, OS.get_processor_count() - 1)
	if max_worker_threads > 0:
		cpu_workers = min(cpu_workers, max_worker_threads)
	var row_bound: int = max(1, int(floor(float(total_h) / float(max(1, min_rows_per_worker)))))
	return clamp(min(task_count, row_bound), 1, cpu_workers)

func _thread_run_task_batch(job: Callable, tasks: Array[Dictionary], worker_idx: int, worker_count: int) -> void:
	var i: int = worker_idx
	while i < tasks.size():
		var t: Dictionary = tasks[i]
		job.call(int(t.get("start", 0)), int(t.get("end", 0)))
		i += worker_count

func _run_stripes_threaded(total_h: int, stripes: int, job: Callable) -> bool:
	var tasks: Array[Dictionary] = _build_stripe_tasks(total_h, stripes)
	if tasks.size() <= 1:
		return false
	var worker_count: int = _recommended_workers(tasks.size(), total_h)
	if worker_count <= 1:
		return false
	var threads: Array[Thread] = []
	for worker_idx in range(worker_count):
		var thread := Thread.new()
		var call: Callable = Callable(self, "_thread_run_task_batch").bind(job, tasks, worker_idx, worker_count)
		var err: int = thread.start(call)
		if err != OK:
			for t in threads:
				t.wait_to_finish()
			return false
		threads.append(thread)
	for t in threads:
		t.wait_to_finish()
	return true
