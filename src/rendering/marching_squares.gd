class_name MarchingSquares
extends RefCounted
## Marching squares algorithm. Generates smooth contour polygons from a density grid.

## Lookup table: for each of the 16 corner states, which edges have contour segments.
## Each edge is encoded as a pair of edge indices (0=top, 1=right, 2=bottom, 3=left).
const EDGE_TABLE: Array = [
	[],                 # 0000
	[[3, 2]],           # 0001
	[[2, 1]],           # 0010
	[[3, 1]],           # 0011
	[[1, 0]],           # 0100
	[[3, 0], [1, 2]],   # 0101 (ambiguous, use saddle)
	[[2, 0]],           # 0110
	[[3, 0]],           # 0111
	[[0, 3]],           # 1000
	[[0, 2]],           # 1001
	[[0, 1], [2, 3]],   # 1010 (ambiguous)
	[[0, 1]],           # 1011
	[[1, 3]],           # 1100
	[[1, 2]],           # 1101
	[[2, 3]],           # 1110
	[],                 # 1111
]


static func extract_contour_segments(density: PackedFloat32Array, w: int, h: int, threshold: float) -> PackedVector2Array:
	## Returns pairs of points (p1, p2, p1, p2, ...) forming contour line segments.
	var segments := PackedVector2Array()

	for y in range(h - 1):
		for x in range(w - 1):
			var tl := density[y * w + x]
			var tr := density[y * w + x + 1]
			var br := density[(y + 1) * w + x + 1]
			var bl := density[(y + 1) * w + x]

			var cell_index := 0
			if tl >= threshold: cell_index |= 8
			if tr >= threshold: cell_index |= 4
			if br >= threshold: cell_index |= 2
			if bl >= threshold: cell_index |= 1

			if cell_index == 0 or cell_index == 15:
				continue

			var edges: Array[Vector2] = [
				_lerp_edge(x, y, x + 1, y, tl, tr, threshold),
				_lerp_edge(x + 1, y, x + 1, y + 1, tr, br, threshold),
				_lerp_edge(x, y + 1, x + 1, y + 1, bl, br, threshold),
				_lerp_edge(x, y, x, y + 1, tl, bl, threshold),
			]

			var edge_pairs: Array = EDGE_TABLE[cell_index]
			for pair in edge_pairs:
				segments.append(edges[pair[0]])
				segments.append(edges[pair[1]])

	return segments


static func _lerp_edge(x1: int, y1: int, x2: int, y2: int, v1: float, v2: float, threshold: float) -> Vector2:
	var t := 0.5
	if absf(v2 - v1) > 0.001:
		t = clampf((threshold - v1) / (v2 - v1), 0.0, 1.0)
	return Vector2(
		float(x1) + t * float(x2 - x1),
		float(y1) + t * float(y2 - y1)
	)
