# Resupply

## Ammo types
Each weapon should have an `ammo_type` field (e.g. "7.62x39", "12.7x108") to determine compatibility. Units can only resupply weapons that share ammo types. This enables:
- Sharing ammo between friendly units with compatible weapons
- Scavenging from wrecks

## Scavenging from wrecked vehicles
When a friendly unit stops on a hex adjacent to a destroyed vehicle wreck (death marker), it should be able to scavenge remaining ammo. The wreck retains whatever ammo the vehicle had when destroyed. Only compatible ammo types can be taken. Takes time (10-15 minutes?), unit is stationary and vulnerable during resupply.

## Town/city resupply
- Being within 1 hex of a town or city gives a chance per 10 minutes of scavenging common ammo types (rifle ammo mainly)
- Fuel resupply near towns/cities for motorized units

## Fuel
Track fuel for motorized units. Running out immobilises the vehicle (different from combat immobilisation - crew is fine, just no fuel).

# ATTACK order

A formal ATTACK order is distinct from MOVE + fire at will. The player clicks a TARGET hex, not a destination hex. The unit autonomously:

1. Finds a firing position within effective weapon range of the target hex
2. Prefers positions with: cover (woods/town), high ground, good LOS to target
3. Pathfinds to that position using current posture rules
4. Stops and engages the target hex
5. If the target moves, repositions to maintain engagement
6. Respects pursuit settings if the target breaks/routs

This is different from MOVE because:
- The destination is computed by the unit, not specified by the player
- The unit needs terrain/LOS evaluation to pick a good firing position
- It creates emergent flanking behaviour if multiple units attack the same hex
- Staff formulation takes longer (attack orders are more complex to plan, already in game.yaml order_modifier)

Implementation needs:
- Firing position evaluation: score hexes near target for cover, elevation, LOS
- A* or similar pathfinding to chosen position (current greedy pathfinding may not route around obstacles well enough)
- Re-evaluation if position becomes untenable (suppressed, flanked, target moves)

Best implemented when we have more unit types (infantry, mortars) where coordinated attacks matter more.

# Screening order

A SCREEN order means the unit establishes a line of observation across a front. The unit:

1. Moves to a position and patrols between 2-3 waypoints defining the screen line
2. Reports enemy contacts (player gets notified)
3. Fires if ROE allows (usually return fire or fire at will)
4. Auto-withdraws when suppression or damage hits a configurable threshold
5. Never gets decisively engaged - trades space for time

Implementation: Screen as an Order.Type (not just a movement modifier). Player sets 2-3 waypoints defining the screen line. Unit patrols between them. Has a withdraw threshold config.
