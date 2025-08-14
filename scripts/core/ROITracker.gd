# File: res://scripts/core/ROITracker.gd
extends RefCounted

## ROI (Region of Interest) tracking for selective updates
## Helps determine which areas need reprocessing after changes

var _changed_regions: Array = []
var _width: int = 0
var _height: int = 0

func initialize(width: int, height: int) -> void:
	_width = width
	_height = height
	clear()

func clear() -> void:
	_changed_regions.clear()

func mark_region_changed(x0: int, y0: int, x1: int, y1: int) -> void:
	# Add a rectangular region that has changed
	_changed_regions.append({
		"x0": max(0, x0),
		"y0": max(0, y0), 
		"x1": min(_width, x1),
		"y1": min(_height, y1)
	})

func mark_circle_changed(center_x: int, center_y: int, radius: int) -> void:
	# Mark a circular region as changed (converted to bounding box)
	var x0: int = max(0, center_x - radius)
	var y0: int = max(0, center_y - radius)
	var x1: int = min(_width, center_x + radius + 1)
	var y1: int = min(_height, center_y + radius + 1)
	mark_region_changed(x0, y0, x1, y1)

func get_merged_roi(expand_pixels: int = 8) -> Array:
	# Return a single bounding box that covers all changed regions
	# with optional expansion for processing margin
	if _changed_regions.is_empty():
		return []  # No ROI needed
	
	var min_x: int = _width
	var min_y: int = _height
	var max_x: int = 0
	var max_y: int = 0
	
	for region in _changed_regions:
		min_x = min(min_x, int(region["x0"]))
		min_y = min(min_y, int(region["y0"]))
		max_x = max(max_x, int(region["x1"]))
		max_y = max(max_y, int(region["y1"]))
	
	# Expand by margin
	min_x = max(0, min_x - expand_pixels)
	min_y = max(0, min_y - expand_pixels)
	max_x = min(_width, max_x + expand_pixels)
	max_y = min(_height, max_y + expand_pixels)
	
	return [min_x, min_y, max_x, max_y]

func get_roi_coverage_ratio() -> float:
	# Return what fraction of the map the ROI covers (0.0 to 1.0)
	var roi: Array = get_merged_roi()
	if roi.is_empty():
		return 0.0
	
	var roi_width: int = int(roi[2]) - int(roi[0])
	var roi_height: int = int(roi[3]) - int(roi[1])
	var roi_area: int = roi_width * roi_height
	var total_area: int = _width * _height
	
	return float(roi_area) / float(total_area) if total_area > 0 else 0.0

func should_use_roi(threshold: float = 0.6) -> bool:
	# Return true if ROI processing would be beneficial
	# (i.e., changed area is less than threshold of total area)
	return get_roi_coverage_ratio() < threshold and not _changed_regions.is_empty()

func mark_height_changes(old_height: PackedFloat32Array, new_height: PackedFloat32Array, threshold: float = 0.1) -> void:
	# Automatically detect height changes and mark affected regions
	if old_height.size() != new_height.size():
		return
	
	var size: int = min(old_height.size(), new_height.size())
	for i in range(size):
		var diff: float = abs(new_height[i] - old_height[i])
		if diff > threshold:
			var x: int = i % _width
			var y: int = i / _width
			mark_circle_changed(x, y, 3)  # Mark 3-pixel radius around change

func mark_flow_changes(old_flow: PackedInt32Array, new_flow: PackedInt32Array) -> void:
	# Detect flow direction changes and mark affected basins
	if old_flow.size() != new_flow.size():
		return
	
	var size: int = min(old_flow.size(), new_flow.size())
	for i in range(size):
		if old_flow[i] != new_flow[i]:
			var x: int = i % _width
			var y: int = i / _width
			mark_circle_changed(x, y, 5)  # Larger radius for flow changes

func get_debug_info() -> Dictionary:
	return {
		"changed_regions_count": _changed_regions.size(),
		"roi_coverage": get_roi_coverage_ratio(),
		"should_use_roi": should_use_roi(),
		"merged_roi": get_merged_roi()
	}
