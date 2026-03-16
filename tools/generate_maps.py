#!/usr/bin/env python3
"""
Map generator for the wargame.
Run with: python3 tools/generate_maps.py
Use --clean to destroy existing maps first.
"""

import argparse
import math
import os
import random
import shutil
import sys

MAPS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "maps")

# Terrain codes
OPEN = "O"
WOODED = "W"
RIVER = "R"
STREET = "S"
TOWN = "T"
CITY = "C"


def value_noise_2d(x, y, seed=0):
    """Simple value noise using hash."""
    n = int(x) + int(y) * 57 + seed * 131
    n = (n << 13) ^ n
    return 1.0 - ((n * (n * n * 15731 + 789221) + 1376312589) & 0x7FFFFFFF) / 1073741824.0


def smoothed_noise(x, y, seed=0):
    """Interpolated value noise."""
    ix = int(math.floor(x))
    iy = int(math.floor(y))
    fx = x - ix
    fy = y - iy
    # Smoothstep
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)

    v00 = value_noise_2d(ix, iy, seed)
    v10 = value_noise_2d(ix + 1, iy, seed)
    v01 = value_noise_2d(ix, iy + 1, seed)
    v11 = value_noise_2d(ix + 1, iy + 1, seed)

    top = v00 + fx * (v10 - v00)
    bot = v01 + fx * (v11 - v01)
    return top + fy * (bot - top)


def fractal_noise(x, y, octaves=4, persistence=0.5, scale=1.0, seed=0):
    """Multi-octave fractal noise."""
    total = 0.0
    amplitude = 1.0
    freq = scale
    max_val = 0.0
    for _ in range(octaves):
        total += smoothed_noise(x * freq, y * freq, seed) * amplitude
        max_val += amplitude
        amplitude *= persistence
        freq *= 2.0
    return total / max_val


def generate_elevation(cols, rows, seed):
    """Generate elevation map (0-9 integer levels)."""
    elev = []
    scale = 0.06
    for row in range(rows):
        r = []
        for col in range(cols):
            n = fractal_noise(col, row, octaves=5, persistence=0.5, scale=scale, seed=seed)
            # Map from [-1,1] to [0,9]
            level = int((n + 1) * 0.5 * 9.9)
            level = max(0, min(9, level))
            r.append(level)
        elev.append(r)
    return elev


def generate_rivers(cols, rows, elevation, seed, num_rivers=3):
    """Generate rivers that flow from high to low elevation."""
    rng = random.Random(seed + 100)
    river_cells = set()

    for _ in range(num_rivers):
        # Start from a high point on an edge
        starts = []
        for col in range(cols):
            for row in [0, rows - 1]:
                if elevation[row][col] >= 5:
                    starts.append((col, row))
        for row in range(rows):
            for col in [0, cols - 1]:
                if elevation[row][col] >= 5:
                    starts.append((col, row))

        if not starts:
            continue

        cx, cy = rng.choice(starts)
        visited = set()

        for _ in range(cols + rows):
            river_cells.add((cx, cy))
            visited.add((cx, cy))

            # Find lowest neighbor
            neighbors = []
            for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < cols and 0 <= ny < rows and (nx, ny) not in visited:
                    neighbors.append((nx, ny, elevation[ny][nx]))

            if not neighbors:
                break

            # Prefer downhill, add some randomness
            neighbors.sort(key=lambda n: n[2] + rng.random() * 2)
            cx, cy, _ = neighbors[0]

            # Stop if we hit an edge
            if cx <= 0 or cx >= cols - 1 or cy <= 0 or cy >= rows - 1:
                river_cells.add((cx, cy))
                break

    return river_cells


def generate_towns_and_cities(cols, rows, elevation, river_cells, seed, num_cities=2, num_towns=6):
    """Place towns and cities - preferring flat areas near rivers."""
    rng = random.Random(seed + 200)
    settlements = []  # (col, row, type)

    # Score each cell
    scores = []
    for row in range(2, rows - 2):
        for col in range(2, cols - 2):
            if (col, row) in river_cells:
                continue
            # Prefer flat areas
            local_elev = [elevation[row + dy][col + dx]
                          for dx in range(-1, 2) for dy in range(-1, 2)]
            flatness = 10 - (max(local_elev) - min(local_elev))
            # Prefer near rivers
            river_dist = min(
                (abs(col - rx) + abs(row - ry) for rx, ry in river_cells),
                default=99
            )
            river_bonus = max(0, 5 - river_dist) * 2
            # Prefer mid elevation
            elev_score = 5 - abs(elevation[row][col] - 4)
            score = flatness + river_bonus + elev_score + rng.random() * 3
            scores.append((score, col, row))

    scores.sort(reverse=True)

    min_dist = 8
    placed = []

    # Place cities first
    for score, col, row in scores:
        if len([s for s in placed if s[2] == CITY]) >= num_cities:
            break
        too_close = any(abs(col - px) + abs(row - py) < min_dist * 2
                        for px, py, _ in placed)
        if not too_close:
            placed.append((col, row, CITY))

    # Then towns
    for score, col, row in scores:
        if len([s for s in placed if s[2] == TOWN]) >= num_towns:
            break
        too_close = any(abs(col - px) + abs(row - py) < min_dist
                        for px, py, _ in placed)
        if not too_close:
            placed.append((col, row, TOWN))

    return placed


def generate_streets(cols, rows, settlements, terrain_grid):
    """Connect settlements with streets using simple pathfinding."""
    street_cells = set()
    if len(settlements) < 2:
        return street_cells

    # Connect each settlement to its nearest neighbor
    connected = {0}
    unconnected = set(range(1, len(settlements)))

    while unconnected:
        best_dist = float('inf')
        best_pair = None
        for ci in connected:
            for ui in unconnected:
                cx, cy, _ = settlements[ci]
                ux, uy, _ = settlements[ui]
                d = abs(cx - ux) + abs(cy - uy)
                if d < best_dist:
                    best_dist = d
                    best_pair = (ci, ui)

        if best_pair is None:
            break

        ci, ui = best_pair
        cx, cy, _ = settlements[ci]
        ux, uy, _ = settlements[ui]

        # Simple walk from one to the other
        x, y = cx, cy
        while x != ux or y != uy:
            if x < ux:
                x += 1
            elif x > ux:
                x -= 1
            if y < uy:
                y += 1
            elif y > uy:
                y -= 1
            if terrain_grid[y][x] == OPEN:
                street_cells.add((x, y))

        connected.add(ui)
        unconnected.remove(ui)

    return street_cells


def generate_woods(cols, rows, elevation, seed):
    """Generate wooded areas using noise - more woods at mid elevations."""
    rng = random.Random(seed + 300)
    wood_cells = set()
    for row in range(rows):
        for col in range(cols):
            n = fractal_noise(col, row, octaves=3, persistence=0.6, scale=0.1, seed=seed + 50)
            elev = elevation[row][col]
            # More woods at mid elevations
            elev_factor = 1.0 - abs(elev - 5) / 5.0
            threshold = 0.15 + elev_factor * 0.25
            if n > threshold:
                wood_cells.add((col, row))
    return wood_cells


def generate_map(name, description, cols, rows, seed):
    """Generate a complete map."""
    rng = random.Random(seed)

    elevation = generate_elevation(cols, rows, seed)
    river_cells = generate_rivers(cols, rows, elevation, seed, num_rivers=rng.randint(2, 4))
    wood_cells = generate_woods(cols, rows, elevation, seed)

    # Start with open terrain
    terrain = [[OPEN] * cols for _ in range(rows)]

    # Place woods first
    for col, row in wood_cells:
        terrain[row][col] = WOODED

    # Place rivers (overwrite woods)
    for col, row in river_cells:
        terrain[row][col] = RIVER

    # Place settlements
    settlements = generate_towns_and_cities(cols, rows, elevation, river_cells, seed)
    for col, row, stype in settlements:
        terrain[row][col] = stype
        # Cities get a small cluster
        if stype == CITY:
            for dx in range(-1, 2):
                for dy in range(-1, 2):
                    nx, ny = col + dx, row + dy
                    if 0 <= nx < cols and 0 <= ny < rows:
                        if terrain[ny][nx] == OPEN or terrain[ny][nx] == WOODED:
                            terrain[ny][nx] = CITY
        elif stype == TOWN:
            for dx, dy in [(0, 1), (0, -1), (1, 0), (-1, 0)]:
                nx, ny = col + dx, row + dy
                if 0 <= nx < cols and 0 <= ny < rows:
                    if terrain[ny][nx] == OPEN and rng.random() > 0.4:
                        terrain[ny][nx] = TOWN

    # Place streets connecting settlements
    street_cells = generate_streets(cols, rows, settlements, terrain)
    for col, row in street_cells:
        terrain[row][col] = STREET

    return terrain, elevation


def write_map_yaml(path, name, description, cols, rows, terrain, elevation):
    """Write map data to YAML file."""
    with open(path, "w") as f:
        f.write(f"name: \"{name}\"\n")
        f.write(f"description: \"{description}\"\n")
        f.write(f"cols: {cols}\n")
        f.write(f"rows: {rows}\n")
        f.write(f"\n")
        f.write(f"terrain:\n")
        for row in terrain:
            f.write(f"  - \"{''.join(row)}\"\n")
        f.write(f"\n")
        f.write(f"elevation:\n")
        for row in elevation:
            f.write(f"  - \"{' '.join(str(e) for e in row)}\"\n")


MAP_DEFS = [
    {
        "filename": "river_valley.yaml",
        "name": "River Valley",
        "description": "A broad river valley with scattered settlements and wooded hills",
        "cols": 80,
        "rows": 60,
        "seed": 42,
    },
    {
        "filename": "highland_crossing.yaml",
        "name": "Highland Crossing",
        "description": "Rugged highlands with sparse cover and few roads",
        "cols": 80,
        "rows": 60,
        "seed": 137,
    },
    {
        "filename": "coastal_plains.yaml",
        "name": "Coastal Plains",
        "description": "Flat coastal terrain with dense urban areas and river networks",
        "cols": 80,
        "rows": 60,
        "seed": 2024,
    },
]


def main():
    parser = argparse.ArgumentParser(description="Generate wargame maps")
    parser.add_argument("--clean", action="store_true",
                        help="Destroy all existing maps before generating")
    args = parser.parse_args()

    if args.clean:
        if os.path.exists(MAPS_DIR):
            shutil.rmtree(MAPS_DIR)
            print(f"Cleaned {MAPS_DIR}")

    os.makedirs(MAPS_DIR, exist_ok=True)

    for m in MAP_DEFS:
        print(f"Generating {m['name']}...")
        terrain, elevation = generate_map(
            m["name"], m["description"], m["cols"], m["rows"], m["seed"]
        )
        path = os.path.join(MAPS_DIR, m["filename"])
        write_map_yaml(path, m["name"], m["description"],
                       m["cols"], m["rows"], terrain, elevation)
        print(f"  -> {path}")

    print(f"\nGenerated {len(MAP_DEFS)} maps.")


if __name__ == "__main__":
    main()
