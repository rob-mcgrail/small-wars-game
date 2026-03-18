class_name GameClock
extends Node

signal time_advanced(game_minutes: float)

var paused: bool = true

# Game time in minutes from midnight
var game_time_minutes: float = 360.0  # 06:00

# Config
var seconds_per_game_minute: float = 0.5


func _ready() -> void:
	var cfg := Config.new()
	cfg.load_file("res://config/game.yaml")

	seconds_per_game_minute = cfg.get_float("time.seconds_per_minute", 0.5)
	game_time_minutes = cfg.get_float("time.start_hour", 6.0) * 60.0 + cfg.get_float("time.start_minute", 0.0)


func _process(delta: float) -> void:
	if paused:
		return

	var advance := delta / seconds_per_game_minute
	game_time_minutes += advance
	time_advanced.emit(advance)


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
