# How to allow for resupply for ammo

# Let's track fuel for motorized units.

- being within 1 hex of a town or city (or on the town or city) gives you a 10% chance per 10 minutes of becoming fully refueled.
- being within 1 hex of a town or city gives you a 5% chance per 10 minutes of increasing your rifle ammo? or is that very unreallistic. discuss.

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
