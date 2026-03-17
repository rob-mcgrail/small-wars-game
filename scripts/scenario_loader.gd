class_name ScenarioLoader
extends RefCounted

## Loads a scenario folder and provides all data the game needs.
## Folder structure:
##   scenario.yaml  - meta, victory, briefing, time, forces
##   map.yaml       - terrain grid
##   equipment.yaml - shared weapons, optics, comms definitions
##   forces.yaml    - unit templates referencing equipment

var scenario_data: Dictionary = {}
var map_path: String = ""
var scenario_folder: String = ""
var name: String = ""
var description: String = ""
var briefing: String = ""
var start_hour: int = 6
var start_minute: int = 0
var sunrise_hour: int = -1  # -1 = use game.yaml default
var sunset_hour: int = -1
var player_forces: Array = []
var enemy_forces: Array = []
var reinforcements: Array = []
var victory: Dictionary = {}
var time_limit_hours: float = 24.0
var overrides: Dictionary = {}  # per-scenario game setting overrides

# Equipment data (loaded from equipment.yaml)
var weapons: Dictionary = {}
var optics: Dictionary = {}
var comms: Dictionary = {}

# Resolved unit templates (loaded from forces.yaml, expanded with equipment)
var templates: Dictionary = {}


func load_scenario(path: String) -> bool:
	# Determine folder path: accept either a folder or a scenario.yaml path
	if path.ends_with("/"):
		scenario_folder = path
	elif path.ends_with("scenario.yaml"):
		scenario_folder = path.get_base_dir() + "/"
	else:
		# Legacy: single-file scenario (e.g. res://config/scenarios/foo.yaml)
		return _load_legacy(path)

	# Load equipment.yaml
	var equip_path: String = scenario_folder + "equipment.yaml"
	var equip_cfg := Config.new()
	if equip_cfg.load_file(equip_path):
		var w = equip_cfg.get_value("weapons", {})
		if w is Dictionary:
			weapons = w
		var o = equip_cfg.get_value("optics", {})
		if o is Dictionary:
			optics = o
		var c = equip_cfg.get_value("comms", {})
		if c is Dictionary:
			comms = c
	else:
		push_warning("ScenarioLoader: No equipment.yaml found at %s" % equip_path)

	# Load forces.yaml
	var forces_path: String = scenario_folder + "forces.yaml"
	var forces_cfg := Config.new()
	if forces_cfg.load_file(forces_path):
		var t = forces_cfg.get_value("templates", {})
		if t is Dictionary:
			templates = t
		# Resolve equipment references in all templates
		for key in templates:
			templates[key] = _resolve_template(key)
	else:
		push_warning("ScenarioLoader: No forces.yaml found at %s" % forces_path)

	# Load scenario.yaml
	var scenario_path: String = scenario_folder + "scenario.yaml"
	var cfg := Config.new()
	if not cfg.load_file(scenario_path):
		push_error("ScenarioLoader: Failed to load %s" % scenario_path)
		return false
	scenario_data = cfg.data

	name = cfg.get_string("name", "Unnamed Scenario")
	description = cfg.get_string("description", "")
	briefing = cfg.get_string("briefing", "")

	# Map path: map.yaml inside the scenario folder
	map_path = scenario_folder + "map.yaml"

	start_hour = cfg.get_int("start_hour", 6)
	start_minute = cfg.get_int("start_minute", 0)
	sunrise_hour = cfg.get_int("sunrise_hour", -1)
	sunset_hour = cfg.get_int("sunset_hour", -1)

	# Parse forces
	var pf = cfg.get_value("player_forces", [])
	if pf is Array:
		player_forces = pf
	var ef = cfg.get_value("enemy_forces", [])
	if ef is Array:
		enemy_forces = ef

	# Parse reinforcements
	var rf = cfg.get_value("reinforcements", [])
	if rf is Array:
		reinforcements = rf

	# Parse victory conditions
	var vic = cfg.get_value("victory", {})
	if vic is Dictionary:
		victory = vic

	time_limit_hours = float(victory.get("time_limit_hours", 24.0))

	# Parse overrides
	var ov = cfg.get_value("overrides", {})
	if ov is Dictionary:
		overrides = ov

	return true


func _load_legacy(path: String) -> bool:
	## Load a single-file scenario (backwards compatibility).
	var cfg := Config.new()
	if not cfg.load_file(path):
		push_error("ScenarioLoader: Failed to load %s" % path)
		return false
	scenario_data = cfg.data

	name = cfg.get_string("name", "Unnamed Scenario")
	description = cfg.get_string("description", "")
	map_path = cfg.get_string("map", "")
	briefing = cfg.get_string("briefing", "")

	start_hour = cfg.get_int("start_hour", 6)
	start_minute = cfg.get_int("start_minute", 0)
	sunrise_hour = cfg.get_int("sunrise_hour", -1)
	sunset_hour = cfg.get_int("sunset_hour", -1)

	var pf = cfg.get_value("player_forces", [])
	if pf is Array:
		player_forces = pf
	var ef = cfg.get_value("enemy_forces", [])
	if ef is Array:
		enemy_forces = ef

	var rf = cfg.get_value("reinforcements", [])
	if rf is Array:
		reinforcements = rf

	var vic = cfg.get_value("victory", {})
	if vic is Dictionary:
		victory = vic

	time_limit_hours = float(victory.get("time_limit_hours", 24.0))

	return true


func _resolve_template(template_key: String) -> Dictionary:
	## Expand equipment references in a template to full dictionaries.
	var template: Dictionary = templates[template_key].duplicate(true)

	# Expand weapons: array of string keys -> array of weapon dicts
	var weapon_keys = template.get("weapons", [])
	var expanded_weapons: Array = []
	if weapon_keys is Array:
		for key in weapon_keys:
			if key is String and key in weapons:
				expanded_weapons.append(weapons[key].duplicate(true))
			elif key is Dictionary:
				# Already a full dict (shouldn't happen but be safe)
				expanded_weapons.append(key)
			else:
				push_warning("ScenarioLoader: Unknown weapon key '%s' in template '%s'" % [str(key), template_key])
	template["weapons"] = expanded_weapons

	# Expand optics: string key -> optics dict
	var optics_key = template.get("optics", "")
	if optics_key is String and optics_key != "" and optics_key in optics:
		template["optics"] = optics[optics_key].duplicate(true)
	elif optics_key is Dictionary:
		pass  # Already expanded
	elif optics_key is String and optics_key != "":
		push_warning("ScenarioLoader: Unknown optics key '%s' in template '%s'" % [optics_key, template_key])

	# Expand comms: string key -> comms dict
	var comms_key = template.get("comms", "")
	if comms_key is String and comms_key != "" and comms_key in comms:
		template["comms"] = comms[comms_key].duplicate(true)
	elif comms_key is Dictionary:
		pass  # Already expanded
	elif comms_key is String and comms_key != "":
		push_warning("ScenarioLoader: Unknown comms key '%s' in template '%s'" % [comms_key, template_key])

	# Ensure icon_color is stored as a string (hex_map will parse it)
	return template


func get_resolved_template(template_key: String) -> Dictionary:
	## Return a deep copy of a resolved template, ready to register as a unit type.
	if template_key in templates:
		return templates[template_key].duplicate(true)
	push_warning("ScenarioLoader: Unknown template '%s'" % template_key)
	return {}
