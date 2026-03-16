class_name Order
extends RefCounted

enum Type { MOVE, ATTACK, DEFEND, WITHDRAW, HOLD }
enum Status { FORMULATING, PREPARING, EXECUTING, COMPLETE, COUNTERMANDED }
enum Posture { FAST, NORMAL, CAUTIOUS }
enum ROE { HOLD_FIRE, RETURN_FIRE, FIRE_AT_WILL, HALT_AND_ENGAGE }

var type: Type
var status: Status = Status.FORMULATING

# Waypoints: array of {hex: Vector2i, posture: Posture, roe: ROE}
var waypoints: Array[Dictionary] = []
var current_waypoint_index: int = 0

# Legacy single target - points to final waypoint
var target_hex: Vector2i:
	get:
		if waypoints.is_empty():
			return Vector2i(-1, -1)
		return waypoints[waypoints.size() - 1]["hex"]

# Current ROE - from current waypoint, persists after last waypoint
var roe: ROE:
	get:
		if current_waypoint_index < waypoints.size():
			return waypoints[current_waypoint_index].get("roe", ROE.RETURN_FIRE)
		elif not waypoints.is_empty():
			return waypoints[waypoints.size() - 1].get("roe", ROE.RETURN_FIRE)
		return ROE.RETURN_FIRE
	set(value):
		if current_waypoint_index < waypoints.size():
			waypoints[current_waypoint_index]["roe"] = value

# Current posture - from current waypoint
var posture: Posture:
	get:
		if current_waypoint_index < waypoints.size():
			return waypoints[current_waypoint_index]["posture"]
		return Posture.NORMAL
	set(value):
		if current_waypoint_index < waypoints.size():
			waypoints[current_waypoint_index]["posture"] = value

# Timing (in game minutes)
var issued_at: float = 0.0
var formulation_time: float = 0.0
var preparation_time: float = 0.0
var formulated_at: float = 0.0
var prepared_at: float = 0.0
var was_countermanded: bool = false

# The unit this order is for
var unit_name: String = ""


func add_waypoint(hex: Vector2i, wp_posture: Posture, wp_roe: ROE = ROE.RETURN_FIRE) -> void:
	waypoints.append({"hex": hex, "posture": wp_posture, "roe": wp_roe})


func remove_last_waypoint() -> bool:
	if waypoints.is_empty():
		return false
	waypoints.remove_at(waypoints.size() - 1)
	if current_waypoint_index >= waypoints.size():
		current_waypoint_index = maxi(0, waypoints.size() - 1)
	return true


func current_target() -> Vector2i:
	if current_waypoint_index < waypoints.size():
		return waypoints[current_waypoint_index]["hex"]
	return Vector2i(-1, -1)


func advance_waypoint() -> bool:
	current_waypoint_index += 1
	return current_waypoint_index < waypoints.size()


func waypoint_count() -> int:
	return waypoints.size()


func is_empty() -> bool:
	return waypoints.is_empty()


static func posture_to_string(p: Posture) -> String:
	match p:
		Posture.FAST: return "fast"
		Posture.NORMAL: return "normal"
		Posture.CAUTIOUS: return "cautious"
	return "normal"


static func posture_from_string(s: String) -> Posture:
	match s.to_lower():
		"fast": return Posture.FAST
		"cautious": return Posture.CAUTIOUS
	return Posture.NORMAL


static func roe_to_string(r: ROE) -> String:
	match r:
		ROE.HOLD_FIRE: return "hold fire"
		ROE.RETURN_FIRE: return "return fire"
		ROE.FIRE_AT_WILL: return "fire at will"
		ROE.HALT_AND_ENGAGE: return "halt & engage"
	return "return fire"


static func roe_from_string(s: String) -> ROE:
	match s.to_lower():
		"hold fire": return ROE.HOLD_FIRE
		"fire at will": return ROE.FIRE_AT_WILL
		"halt & engage", "halt and engage": return ROE.HALT_AND_ENGAGE
	return ROE.RETURN_FIRE


static func type_to_string(t: Type) -> String:
	match t:
		Type.MOVE: return "move"
		Type.ATTACK: return "attack"
		Type.DEFEND: return "defend"
		Type.WITHDRAW: return "withdraw"
		Type.HOLD: return "hold"
	return "unknown"


static func type_from_string(s: String) -> Type:
	match s.to_lower():
		"move": return Type.MOVE
		"attack": return Type.ATTACK
		"defend": return Type.DEFEND
		"withdraw": return Type.WITHDRAW
		"hold": return Type.HOLD
	return Type.HOLD


func status_string() -> String:
	match status:
		Status.FORMULATING: return "FORMULATING"
		Status.PREPARING: return "PREPARING"
		Status.EXECUTING: return "EXECUTING"
		Status.COMPLETE: return "COMPLETE"
		Status.COUNTERMANDED: return "COUNTERMANDED"
	return "?"


func total_delay() -> float:
	return formulation_time + preparation_time


func time_until_execution(current_time: float) -> float:
	var exec_start := issued_at + total_delay()
	return maxf(0.0, exec_start - current_time)


func update(current_time: float) -> void:
	var elapsed := current_time - issued_at

	match status:
		Status.FORMULATING:
			if elapsed >= formulation_time:
				status = Status.PREPARING
				formulated_at = issued_at + formulation_time
		Status.PREPARING:
			if elapsed >= total_delay():
				status = Status.EXECUTING
				prepared_at = issued_at + total_delay()
