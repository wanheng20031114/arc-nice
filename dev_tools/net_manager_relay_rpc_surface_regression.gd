extends SceneTree

const MAIN_NET_MANAGER_PATH := "res://scene/multiplayer/net_manager.gd"
const RELAY_NET_MANAGER_PATH := (
	"res://relay_servers/relay_godot_project/relay_net_manager_stub.gd"
)
const MAIN_CONSTANTS_PATH := "res://scene/multiplayer/net_constants.gd"
const RELAY_SERVER_PATH := (
	"res://relay_servers/relay_godot_project/relay_server.gd"
)
const EXPECTED_PROTOCOL_VERSION := 96
const EXPECTED_NET_MANAGER_RPC_COUNT := 18

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var main_surface := _extract_rpc_surface(MAIN_NET_MANAGER_PATH)
	var relay_surface := _extract_rpc_surface(RELAY_NET_MANAGER_PATH)
	_expect(
		main_surface.size() == EXPECTED_NET_MANAGER_RPC_COUNT,
		"Main NetManager RPC count changed: expected %d, got %d."
			% [EXPECTED_NET_MANAGER_RPC_COUNT, main_surface.size()]
	)
	_expect(
		relay_surface.size() == EXPECTED_NET_MANAGER_RPC_COUNT,
		"Relay NetManager RPC count changed: expected %d, got %d."
			% [EXPECTED_NET_MANAGER_RPC_COUNT, relay_surface.size()]
	)
	for method_name_variant in main_surface:
		var method_name := String(method_name_variant)
		_expect(
			relay_surface.has(method_name),
			"Relay NetManager is missing RPC %s." % method_name
		)
		if not relay_surface.has(method_name):
			continue
		_expect(
			main_surface[method_name] == relay_surface[method_name],
			"RPC %s annotation/signature differs: main=%s relay=%s."
				% [
					method_name,
					main_surface[method_name],
					relay_surface[method_name],
				]
		)
	for method_name_variant in relay_surface:
		var method_name := String(method_name_variant)
		_expect(
			main_surface.has(method_name),
			"Relay NetManager has an RPC absent from main: %s." % method_name
		)

	var main_protocol := _extract_integer_constant(
		MAIN_CONSTANTS_PATH,
		"PROTOCOL_VERSION"
	)
	var relay_protocol := _extract_integer_constant(
		RELAY_SERVER_PATH,
		"PROTOCOL_VERSION"
	)
	_expect(
		main_protocol == EXPECTED_PROTOCOL_VERSION
		and relay_protocol == EXPECTED_PROTOCOL_VERSION,
		"Protocol deployment must remain v%d on both nodes; main=%d relay=%d."
			% [EXPECTED_PROTOCOL_VERSION, main_protocol, relay_protocol]
	)

	if failures.is_empty():
		print(
			"NET_MANAGER_RELAY_RPC_SURFACE_REGRESSION_OK rpc_count=%d protocol=v%d"
			% [main_surface.size(), main_protocol]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _extract_rpc_surface(source_path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(source_path)
	_expect(not source.is_empty(), "Could not read %s." % source_path)
	var lines := source.split("\n")
	var surface := {}
	var line_index := 0
	while line_index < lines.size():
		var stripped := String(lines[line_index]).strip_edges()
		if not stripped.begins_with("@rpc("):
			line_index += 1
			continue
		var annotation := stripped
		while not annotation.ends_with(")") and line_index + 1 < lines.size():
			line_index += 1
			annotation += String(lines[line_index]).strip_edges()
		line_index += 1
		while line_index < lines.size():
			stripped = String(lines[line_index]).strip_edges()
			if stripped.is_empty() or stripped.begins_with("#"):
				line_index += 1
				continue
			break
		if line_index >= lines.size() or not stripped.begins_with("func "):
			_expect(false, "%s has @rpc without a following function." % source_path)
			continue
		var declaration := ""
		var parenthesis_depth := 0
		var saw_open_parenthesis := false
		while line_index < lines.size():
			var declaration_line := String(lines[line_index]).strip_edges()
			declaration += declaration_line
			for character in declaration_line:
				if character == "(":
					parenthesis_depth += 1
					saw_open_parenthesis = true
				elif character == ")":
					parenthesis_depth -= 1
			line_index += 1
			if saw_open_parenthesis and parenthesis_depth == 0:
				break
		var open_parenthesis := declaration.find("(")
		var method_name := declaration.substr(
			5,
			open_parenthesis - 5
		)
		_expect(
			not method_name.is_empty() and not surface.has(method_name),
			"%s has an invalid or duplicate RPC declaration %s."
				% [source_path, method_name]
		)
		surface[method_name] = "%s|%s" % [
			_remove_whitespace(annotation),
			_remove_whitespace(declaration),
		]
	return surface


func _extract_integer_constant(source_path: String, constant_name: String) -> int:
	var source := FileAccess.get_file_as_string(source_path)
	for line_variant in source.split("\n"):
		var line := String(line_variant).strip_edges()
		var prefix := "const %s :=" % constant_name
		if line.begins_with(prefix):
			return line.trim_prefix(prefix).strip_edges().to_int()
	_expect(false, "%s does not declare %s." % [source_path, constant_name])
	return -1


func _remove_whitespace(value: String) -> String:
	var normalized := ""
	for character in value:
		if character in [" ", "\t", "\r", "\n"]:
			continue
		normalized += character
	return normalized


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
