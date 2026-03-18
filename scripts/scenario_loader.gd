class_name ScenarioLoader
extends RefCounted

## Loads a scenario folder and provides all data the game needs.
##
## New conflict structure:
##   conflicts/<conflict>/
##     weapons.yaml, optics.yaml, comms.yaml
##     factions/<faction>.yaml
##     scenarios/<scenario>/
##       scenario.yaml, map.yaml, forces.yaml
##
## Legacy folder structure (still supported):
##   scenarios/<name>/
##     scenario.yaml, map.yaml, equipment.yaml, forces.yaml

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
var overrides: Dictionary = {}  # per-scenario game setting overrides (legacy)
var town_support: Array = []  # towns that provide spotting for factions
var map_labels: Array = []  # named locations on the map

# Equipment data (loaded from equipment files)
var weapons: Dictionary = {}
var optics: Dictionary = {}
var comms: Dictionary = {}

# Resolved unit templates (loaded from forces.yaml, expanded with equipment)
var templates: Dictionary = {}

# Conflict/faction hierarchy
var conflict_root: String = ""
var player_faction: Dictionary = {}
var enemy_faction: Dictionary = {}


func load_scenario(path: String) -> bool:
	# Determine folder path: accept either a folder or a scenario.yaml path
	if path.ends_with("/"):
		scenario_folder = path
	elif path.ends_with("scenario.yaml"):
		scenario_folder = path.get_base_dir() + "/"
	else:
		# Legacy: single-file scenario (e.g. res://config/scenarios/foo.yaml)
		return _load_legacy(path)

	# Detect new conflict structure: look for conflict root ancestor
	conflict_root = _find_conflict_root(scenario_folder)

	if conflict_root != "":
		return _load_conflict_scenario()
	else:
		return _load_folder_scenario()


func _find_conflict_root(scenario_path: String) -> String:
	## Walk up from the scenario folder to find a directory containing weapons.yaml.
	## Expected structure: conflicts/<conflict>/scenarios/<name>/
	## So from the scenario folder, go up 2 dirs to reach the conflict root.
	var parts: PackedStringArray = scenario_path.trim_suffix("/").split("/")
	# Try going up 2 directories (past scenarios/<name>)
	if parts.size() >= 3:
		var candidate: String = "/".join(parts.slice(0, parts.size() - 2)) + "/"
		if FileAccess.file_exists(candidate + "weapons.yaml"):
			return candidate
	# Try going up 1 directory (in case path points at scenarios/ itself)
	if parts.size() >= 2:
		var candidate: String = "/".join(parts.slice(0, parts.size() - 1)) + "/"
		if FileAccess.file_exists(candidate + "weapons.yaml"):
			return candidate
	return ""


func _load_conflict_scenario() -> bool:
	## Load a scenario using the new conflict/faction/scenario hierarchy.

	# Load conflict-level equipment files
	_load_equipment_from_conflict()

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

	# Load faction files based on scenario.yaml factions field
	var factions_dict = cfg.get_value("factions", {})
	if factions_dict is Dictionary:
		var player_faction_key: String = str(factions_dict.get("player", ""))
		var enemy_faction_key: String = str(factions_dict.get("enemy", ""))

		if player_faction_key != "":
			player_faction = _load_faction(player_faction_key)
		if enemy_faction_key != "":
			enemy_faction = _load_faction(enemy_faction_key)

	# Build overrides from faction data for backwards compatibility with hex_map
	overrides = _build_overrides_from_factions()

	# Load forces.yaml (templates reference conflict-level equipment)
	var forces_path: String = scenario_folder + "forces.yaml"
	var forces_cfg := Config.new()
	if forces_cfg.load_file(forces_path):
		var t = forces_cfg.get_value("templates", {})
		if t is Dictionary:
			templates = t
		for key in templates:
			templates[key] = _resolve_template(key)
	else:
		push_warning("ScenarioLoader: No forces.yaml found at %s" % forces_path)

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

	# Parse town support
	var ts = cfg.get_value("town_support", [])
	if ts is Array:
		town_support = ts

	# Parse map labels
	var ml = cfg.get_value("map_labels", [])
	if ml is Array:
		map_labels = ml

	# Parse victory conditions
	var vic = cfg.get_value("victory", {})
	if vic is Dictionary:
		victory = vic

	time_limit_hours = float(victory.get("time_limit_hours", 24.0))

	# Scenario-level overrides merge ON TOP of faction overrides
	# Priority: game.yaml < faction.yaml < scenario.yaml overrides
	var scenario_ov = cfg.get_value("overrides", {})
	if scenario_ov is Dictionary and not scenario_ov.is_empty():
		_merge_overrides(overrides, scenario_ov)

	return true


func _merge_overrides(base: Dictionary, overlay: Dictionary) -> void:
	## Deep merge overlay into base. Overlay values win.
	for key in overlay:
		if key in base and base[key] is Dictionary and overlay[key] is Dictionary:
			_merge_overrides(base[key], overlay[key])
		else:
			base[key] = overlay[key]


func _load_equipment_from_conflict() -> void:
	## Load weapons.yaml, optics.yaml, comms.yaml from the conflict root.
	var weapons_cfg := Config.new()
	if weapons_cfg.load_file(conflict_root + "weapons.yaml"):
		var w = weapons_cfg.get_value("weapons", {})
		if w is Dictionary:
			weapons = w

	var optics_cfg := Config.new()
	if optics_cfg.load_file(conflict_root + "optics.yaml"):
		var o = optics_cfg.get_value("optics", {})
		if o is Dictionary:
			optics = o

	var comms_cfg := Config.new()
	if comms_cfg.load_file(conflict_root + "comms.yaml"):
		var c = comms_cfg.get_value("comms", {})
		if c is Dictionary:
			comms = c


func _load_faction(faction_key: String) -> Dictionary:
	## Load a faction YAML from the conflict's factions/ directory.
	var faction_path: String = conflict_root + "factions/" + faction_key + ".yaml"
	var cfg := Config.new()
	if not cfg.load_file(faction_path):
		push_warning("ScenarioLoader: Failed to load faction file %s" % faction_path)
		return {}
	return cfg.data


func _build_overrides_from_factions() -> Dictionary:
	## Convert faction data into the overrides format that hex_map expects.
	## This bridges the new faction system with the existing _apply_scenario_overrides.
	var result: Dictionary = {}

	# OODA overrides
	var ooda: Dictionary = {}
	if "ooda_base_cycle_minutes" in player_faction:
		ooda["player_base_cycle_minutes"] = player_faction["ooda_base_cycle_minutes"]
	if "ooda_base_cycle_minutes" in enemy_faction:
		ooda["enemy_base_cycle_minutes"] = enemy_faction["ooda_base_cycle_minutes"]
	if not ooda.is_empty():
		result["ooda"] = ooda

	# Night overrides
	var night: Dictionary = {}
	var player_night = player_faction.get("night", {})
	if player_night is Dictionary:
		if "spotting_modifier" in player_night:
			night["player_spotting_modifier"] = player_night["spotting_modifier"]
		if "accuracy_modifier" in player_night:
			night["player_accuracy_modifier"] = player_night["accuracy_modifier"]
		if "range_modifier" in player_night:
			night["player_range_modifier"] = player_night["range_modifier"]
	var enemy_night = enemy_faction.get("night", {})
	if enemy_night is Dictionary:
		if "spotting_modifier" in enemy_night:
			night["enemy_spotting_modifier"] = enemy_night["spotting_modifier"]
		if "accuracy_modifier" in enemy_night:
			night["enemy_accuracy_modifier"] = enemy_night["accuracy_modifier"]
		if "range_modifier" in enemy_night:
			night["enemy_range_modifier"] = enemy_night["range_modifier"]
	if not night.is_empty():
		result["night"] = night

	# HQ overrides
	var hq: Dictionary = {}
	var player_hq = player_faction.get("hq", {})
	if player_hq is Dictionary:
		if "comms_order_buff" in player_hq:
			hq["player_comms_order_buff"] = player_hq["comms_order_buff"]
		if "los_order_buff" in player_hq:
			hq["player_los_order_buff"] = player_hq["los_order_buff"]
	var enemy_hq = enemy_faction.get("hq", {})
	if enemy_hq is Dictionary:
		if "comms_order_buff" in enemy_hq:
			hq["enemy_comms_order_buff"] = enemy_hq["comms_order_buff"]
		if "los_order_buff" in enemy_hq:
			hq["enemy_los_order_buff"] = enemy_hq["los_order_buff"]
	if not hq.is_empty():
		result["hq"] = hq

	return result


func _load_folder_scenario() -> bool:
	## Load a scenario from the legacy folder structure (equipment.yaml in scenario folder).

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

	# Parse overrides (legacy format)
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
