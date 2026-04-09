class_name TestPolygonRasterizer
extends RefCounted
## Unit tests for PolygonRasterizer.

const PR := preload("res://src/simulation/polygon_rasterizer.gd")


static func run_tests() -> Array:
	return [
		_test_axis_aligned_square(),
		_test_translated_square(),
		_test_rotated_square(),
		_test_irregular_pentagon(),
		_test_out_of_bounds_clamping(),
		_test_polygon_area_rectangle(),
	]


static func _count_mask(mask: PackedInt32Array) -> int:
	var count := 0
	for v in mask:
		if v == 1:
			count += 1
	return count


static func _test_axis_aligned_square() -> Dictionary:
	## 8x8 px square at (10,10), no rotation, 10x10 grid with 2px cells.
	## World verts: (6,6),(14,6),(14,14),(6,14).
	## Cell centers inside: x in {7,9,11,13}, y in {7,9,11,13} -> 16 cells.
	var poly := PackedVector2Array([
		Vector2(-4, -4), Vector2(4, -4),
		Vector2(4, 4), Vector2(-4, 4),
	])
	var gw := 10
	var gh := 10
	var mask := PackedInt32Array()
	mask.resize(gw * gh)
	mask.fill(0)

	PR.rasterize(poly, Vector2(10, 10), 0.0, gw, gh, 2.0, mask)
	var count := _count_mask(mask)

	var pass_ := count == 16
	return {
		"name": "axis_aligned_square",
		"pass": pass_,
		"msg": "expected 16, got %d" % count,
	}


static func _test_translated_square() -> Dictionary:
	## Same 8x8 square at (20,10), 20x10 grid, 2px cells.
	## World verts: (16,6),(24,6),(24,14),(16,14).
	## Cell centers inside: x in {17,19,21,23}, y in {7,9,11,13} -> 16 cells.
	## Also verify cell(8,3) is set: center (17,7) is inside.
	var poly := PackedVector2Array([
		Vector2(-4, -4), Vector2(4, -4),
		Vector2(4, 4), Vector2(-4, 4),
	])
	var gw := 20
	var gh := 10
	var mask := PackedInt32Array()
	mask.resize(gw * gh)
	mask.fill(0)

	PR.rasterize(poly, Vector2(20, 10), 0.0, gw, gh, 2.0, mask)
	var count := _count_mask(mask)

	var cell_8_3 := mask[3 * gw + 8] == 1
	var pass_ := count == 16 and cell_8_3
	var msg := "expected 16, got %d; cell(8,3)=%s" % [count, str(cell_8_3)]
	return {"name": "translated_square", "pass": pass_, "msg": msg}


static func _test_rotated_square() -> Dictionary:
	## 8x8 square rotated 45 deg at (10,10), 10x10 grid, 2px cells.
	## Rotated diamond covers a comparable number of cells to the aligned
	## square but fewer than the bounding box. Expect >=12 and <36.
	var poly := PackedVector2Array([
		Vector2(-4, -4), Vector2(4, -4),
		Vector2(4, 4), Vector2(-4, 4),
	])
	var gw := 10
	var gh := 10
	var mask := PackedInt32Array()
	mask.resize(gw * gh)
	mask.fill(0)

	PR.rasterize(poly, Vector2(10, 10), PI / 4.0, gw, gh, 2.0, mask)
	var count := _count_mask(mask)

	var pass_ := count >= 12 and count < 36
	return {
		"name": "rotated_square",
		"pass": pass_,
		"msg": "expected 12<=n<36, got %d" % count,
	}


static func _test_irregular_pentagon() -> Dictionary:
	## Wood polygon at (30,20), 40x30 grid, 2px cells.
	## Area ~620 px², cell area 4 px², so roughly 100-200 cells.
	var poly := PackedVector2Array([
		Vector2(-16, -10), Vector2(18, -12),
		Vector2(16, 11), Vector2(-4, 13), Vector2(-18, 8),
	])
	var gw := 40
	var gh := 30
	var mask := PackedInt32Array()
	mask.resize(gw * gh)
	mask.fill(0)

	PR.rasterize(poly, Vector2(30, 20), 0.0, gw, gh, 2.0, mask)
	var count := _count_mask(mask)

	var pass_ := count >= 100 and count <= 200
	return {
		"name": "irregular_pentagon",
		"pass": pass_,
		"msg": "expected 100-200, got %d" % count,
	}


static func _test_out_of_bounds_clamping() -> Dictionary:
	## 8x8 square at (20,10) — half outside a 10x10 grid at 2px cells.
	## Grid covers [0,20) px in x. World verts: (16,6)-(24,14).
	## Inside grid: x centers 17,19 (cells 8,9), y centers 7,9,11,13 (cells 3-6).
	## Expect 8 cells (±2 tolerance for boundary).
	var poly := PackedVector2Array([
		Vector2(-4, -4), Vector2(4, -4),
		Vector2(4, 4), Vector2(-4, 4),
	])
	var gw := 10
	var gh := 10
	var mask := PackedInt32Array()
	mask.resize(gw * gh)
	mask.fill(0)

	PR.rasterize(poly, Vector2(20, 10), 0.0, gw, gh, 2.0, mask)
	var count := _count_mask(mask)

	var pass_ := count >= 6 and count <= 10
	return {
		"name": "out_of_bounds_clamping",
		"pass": pass_,
		"msg": "expected 6-10, got %d" % count,
	}


static func _test_polygon_area_rectangle() -> Dictionary:
	## 8x8 square -> area should be exactly 64.0.
	var poly := PackedVector2Array([
		Vector2(-4, -4), Vector2(4, -4),
		Vector2(4, 4), Vector2(-4, 4),
	])
	var area := PR.polygon_area(poly)

	var pass_ := absf(area - 64.0) < 0.001
	return {
		"name": "polygon_area_rectangle",
		"pass": pass_,
		"msg": "expected 64.0, got %.3f" % area,
	}
