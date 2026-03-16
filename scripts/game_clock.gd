class_name GameClock
extends Node

signal phase_changed(phase: String)
signal time_advanced(game_minutes: float)
signal orders_phase_started()

enum Phase { ORDERS, EXECUTING }

var current_phase: Phase = Phase.ORDERS

# Game time in minutes from midnight
var game_time_minutes: float = 360.0  # 06:00
var next_orders_at: float = 0.0

# Config
var ooda_cycle_minutes: float = 15.0
var seconds_per_game_minute: float = 0.5

# Execution speed
var executing := false


func _ready() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/game.yaml")

	ooda_cycle_minutes = cfg.get_float("ooda.base_cycle_minutes", 15.0)
	seconds_per_game_minute = cfg.get_float("time.seconds_per_minute", 0.5)
	game_time_minutes = cfg.get_float("time.start_hour", 6.0) * 60.0 + cfg.get_float("time.start_minute", 0.0)

	next_orders_at = game_time_minutes + ooda_cycle_minutes
	current_phase = Phase.ORDERS


func _process(delta: float) -> void:
	if current_phase != Phase.EXECUTING:
		return

	var advance := delta / seconds_per_game_minute
	game_time_minutes += advance
	time_advanced.emit(advance)

	if game_time_minutes >= next_orders_at:
		game_time_minutes = next_orders_at
		current_phase = Phase.ORDERS
		next_orders_at = game_time_minutes + ooda_cycle_minutes
		phase_changed.emit("ORDERS")
		orders_phase_started.emit()


func end_orders_phase() -> void:
	if current_phase != Phase.ORDERS:
		return
	current_phase = Phase.EXECUTING
	phase_changed.emit("EXECUTING")


func get_time_string() -> String:
	var total := int(game_time_minutes)
	var hours := (total / 60) % 24
	var minutes := total % 60
	var ampm := "AM"
	if hours >= 12:
		ampm = "PM"
	var display_hours := hours % 12
	if display_hours == 0:
		display_hours = 12
	return "%d:%02d %s" % [display_hours, minutes, ampm]


func get_phase_string() -> String:
	match current_phase:
		Phase.ORDERS:
			return "ORDERS"
		Phase.EXECUTING:
			return "EXECUTING"
	return ""


func get_minutes_until_orders() -> float:
	if current_phase == Phase.ORDERS:
		return 0.0
	return next_orders_at - game_time_minutes


func is_orders_phase() -> bool:
	return current_phase == Phase.ORDERS
