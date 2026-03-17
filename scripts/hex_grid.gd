class_name HexGrid extends RefCounted

var terrain_grid: Array
var elevation_grid: Array
var map_cols: int
var map_rows: int
var hex_size: float
var hex_width: float
var hex_height: float


func _init(p_terrain_grid: Array, p_elevation_grid: Array, p_map_cols: int, p_map_rows: int, p_hex_size: float) -> void:
	terrain_grid = p_terrain_grid
	elevation_grid = p_elevation_grid
	map_cols = p_map_cols
	map_rows = p_map_rows
	hex_size = p_hex_size
	hex_width = hex_size * 2.0
	hex_height = sqrt(3.0) * hex_size


func hex_distance(a: Vector2i, b: Vector2i) -> int:
	# Convert offset coords to cube coords then compute distance
	var ac: Vector3i = offset_to_cube(a)
	var bc: Vector3i = offset_to_cube(b)
	return (absi(ac.x - bc.x) + absi(ac.y - bc.y) + absi(ac.z - bc.z)) / 2


func offset_to_cube(hex: Vector2i) -> Vector3i:
	var q: int = hex.x
	var r: int = hex.y - (hex.x - (hex.x & 1)) / 2
	var s: int = -q - r
	return Vector3i(q, r, s)


func cube_to_offset(cube: Vector3i) -> Vector2i:
	var col: int = cube.x
	var row: int = cube.y + (cube.x - (cube.x & 1)) / 2
	return Vector2i(col, row)


func cube_round(fq: float, fr: float, fs: float) -> Vector3i:
	var q: int = roundi(fq)
	var r: int = roundi(fr)
	var s: int = roundi(fs)
	var q_diff: float = absf(float(q) - fq)
	var r_diff: float = absf(float(r) - fr)
	var s_diff: float = absf(float(s) - fs)
	if q_diff > r_diff and q_diff > s_diff:
		q = -r - s
	elif r_diff > s_diff:
		r = -q - s
	else:
		s = -q - r
	return Vector3i(q, r, s)


func has_los(origin: Vector2i, origin_elev: int, target: Vector2i) -> bool:
	# Walk a line from origin to target in cube coords, check each intermediate hex
	var oc: Vector3i = offset_to_cube(origin)
	var tc: Vector3i = offset_to_cube(target)
	var dist: int = hex_distance(origin, target)
	if dist <= 1:
		return true

	var target_elev: int = self.elevation_grid[target.y][target.x]

	# Lerp through cube coords
	for step in range(1, dist):
		var t: float = float(step) / float(dist)
		var fq: float = lerpf(float(oc.x) + 1e-6, float(tc.x) + 1e-6, t)
		var fr: float = lerpf(float(oc.y) + 1e-6, float(tc.y) + 1e-6, t)
		var fs: float = lerpf(float(oc.z) - 2e-6, float(tc.z) - 2e-6, t)
		var cube: Vector3i = cube_round(fq, fr, fs)
		var hex: Vector2i = cube_to_offset(cube)

		if hex.x < 0 or hex.x >= self.map_cols or hex.y < 0 or hex.y >= self.map_rows:
			return false

		var mid_elev: int = self.elevation_grid[hex.y][hex.x]
		var mid_terrain: String = self.terrain_grid[hex.y][hex.x]
		var hex_dist_from_origin: int = hex_distance(origin, hex)

		# Elevation blocking
		var expected_elev: float = lerpf(float(origin_elev), float(target_elev), t)
		if float(mid_elev) > expected_elev + 0.5:
			return false

		# Terrain blocking - adjacent hexes (distance 1) never block,
		# you can see into the tree line but not through it
		if hex_dist_from_origin <= 1:
			continue

		if mid_terrain == "W" or mid_terrain == "C":
			if origin_elev < mid_elev + 2:
				return false
		elif mid_terrain == "T":
			if origin_elev < mid_elev + 1:
				return false

	return true


func get_hex_neighbors(hex: Vector2i) -> Array[Vector2i]:
	var col: int = hex.x
	var row: int = hex.y
	var parity: int = col & 1
	var neighbors: Array[Vector2i] = []

	if parity == 0:
		neighbors.append(Vector2i(col + 1, row - 1))
		neighbors.append(Vector2i(col + 1, row))
		neighbors.append(Vector2i(col, row + 1))
		neighbors.append(Vector2i(col - 1, row))
		neighbors.append(Vector2i(col - 1, row - 1))
		neighbors.append(Vector2i(col, row - 1))
	else:
		neighbors.append(Vector2i(col + 1, row))
		neighbors.append(Vector2i(col + 1, row + 1))
		neighbors.append(Vector2i(col, row + 1))
		neighbors.append(Vector2i(col - 1, row + 1))
		neighbors.append(Vector2i(col - 1, row))
		neighbors.append(Vector2i(col, row - 1))

	return neighbors


func hex_to_pixel(col: int, row: int) -> Vector2:
	var x: float = col * self.hex_width * 0.75
	var y: float = row * self.hex_height
	if col % 2 == 1:
		y += self.hex_height * 0.5
	return Vector2(x, y)


func pixel_to_hex(pixel: Vector2) -> Vector2i:
	var approx_col: float = pixel.x / (self.hex_width * 0.75)
	var col: int = int(round(approx_col))
	var y_offset: float = 0.0
	if col % 2 == 1:
		y_offset = self.hex_height * 0.5
	var approx_row: float = (pixel.y - y_offset) / self.hex_height
	var row: int = int(round(approx_row))

	var best: Vector2i = Vector2i(col, row)
	var best_dist: float = pixel.distance_to(hex_to_pixel(col, row))
	for dc in range(-1, 2):
		for dr in range(-1, 2):
			var c: int = col + dc
			var r: int = row + dr
			if c < 0 or r < 0:
				continue
			var dist: float = pixel.distance_to(hex_to_pixel(c, r))
			if dist < best_dist:
				best_dist = dist
				best = Vector2i(c, r)
	return best


func is_valid_hex(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.x < self.map_cols and coord.y >= 0 and coord.y < self.map_rows


func find_open_hex_near(col: int, row: int) -> Vector2i:
	for radius in range(0, 10):
		for dc in range(-radius, radius + 1):
			for dr in range(-radius, radius + 1):
				var c: int = col + dc
				var r: int = row + dr
				if c >= 0 and c < self.map_cols and r >= 0 and r < self.map_rows:
					var code: String = self.terrain_grid[r][c]
					if code == "O" or code == "S":
						return Vector2i(c, r)
	return Vector2i(-1, -1)


func nearest_edge_hex(pos: Vector2i) -> Vector2i:
	# Find closest map edge hex
	var dist_left: int = pos.x
	var dist_right: int = self.map_cols - 1 - pos.x
	var dist_top: int = pos.y
	var dist_bottom: int = self.map_rows - 1 - pos.y
	var min_dist: int = dist_left
	var best: Vector2i = Vector2i(0, pos.y)
	if dist_right < min_dist:
		min_dist = dist_right
		best = Vector2i(self.map_cols - 1, pos.y)
	if dist_top < min_dist:
		min_dist = dist_top
		best = Vector2i(pos.x, 0)
	if dist_bottom < min_dist:
		best = Vector2i(pos.x, self.map_rows - 1)
	return best
