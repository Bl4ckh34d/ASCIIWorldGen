# File: res://scripts/core/JobSystem.gd
extends RefCounted

## Thin wrapper intended to stripe work across rows; sequential for now.

func run_rows(height: int, job: Callable) -> void:
	# Calls job(row_index) for each row sequentially.
	for y in range(max(0, height)):
		job.call(y)

func run_stripes(height: int, stripes: int, job: Callable) -> void:
	# Calls job(start_row, end_row) for each contiguous stripe sequentially.
	var total_h: int = max(0, height)
	var num: int = max(1, stripes)
	var rows_per: int = int(ceil(float(total_h) / float(num)))
	var start: int = 0
	while start < total_h:
		var end_i: int = min(total_h, start + rows_per)
		job.call(start, end_i)
		start = end_i
