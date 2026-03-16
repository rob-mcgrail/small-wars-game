extends Control

signal map_selected(path: String)

@onready var map_list: VBoxContainer = %MapList
@onready var description_label: Label = %DescriptionLabel


func _ready() -> void:
	_scan_maps()


func _scan_maps() -> void:
	var dir := DirAccess.open("res://maps")
	if dir == null:
		push_error("MapMenu: Cannot open maps directory")
		return

	dir.list_dir_begin()
	var files: Array[String] = []
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".yaml"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	files.sort()

	for file in files:
		var path := "res://maps/" + file
		var cfg := Config.new()
		if not cfg.load_file(path):
			continue

		var btn := Button.new()
		btn.text = cfg.get_string("name", file)
		btn.custom_minimum_size = Vector2(400, 50)
		btn.add_theme_font_size_override("font_size", 20)

		var desc := cfg.get_string("description", "")
		var cols := cfg.get_int("cols", 0)
		var rows := cfg.get_int("rows", 0)
		var info := "%s (%dx%d)" % [desc, cols, rows]

		btn.pressed.connect(_on_map_button_pressed.bind(path, info))
		btn.mouse_entered.connect(_on_map_button_hover.bind(info))
		map_list.add_child(btn)


func _on_map_button_pressed(path: String, _info: String) -> void:
	map_selected.emit(path)


func _on_map_button_hover(info: String) -> void:
	description_label.text = info
