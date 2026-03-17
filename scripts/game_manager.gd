extends Node

var hex_map_scene: PackedScene
var current_map: Node2D


func _ready() -> void:
	hex_map_scene = load("res://scenes/hex_map.tscn")
	var menu := $MapMenu
	menu.map_selected.connect(_on_map_selected)
	menu.scenario_selected.connect(_on_scenario_selected)


func _on_map_selected(path: String) -> void:
	$MapMenu.hide()

	if current_map:
		current_map.queue_free()

	current_map = hex_map_scene.instantiate()
	current_map.map_file = path
	add_child(current_map)


func _on_scenario_selected(path: String) -> void:
	$MapMenu.hide()

	if current_map:
		current_map.queue_free()

	current_map = hex_map_scene.instantiate()
	current_map.scenario_file = path
	add_child(current_map)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F10:
		if current_map:
			current_map.queue_free()
			current_map = null
		$MapMenu.show()
