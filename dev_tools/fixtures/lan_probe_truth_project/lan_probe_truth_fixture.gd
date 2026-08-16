extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# 留出极短窗口，让 Windows 侧先记录启动进程的 CIM 创建时间。
	await create_timer(0.2).timeout
	var options := _parse_options()
	var role := str(options.get("role", ""))
	var fixture := str(options.get("truth_fixture", ""))
	var parts := fixture.split(":", false, 1)
	if parts.size() != 2:
		push_error("Truth fixture requires family:mode.")
		quit(64)
		return
	var marker := _expected_marker(str(parts[0]), role)
	if marker.is_empty():
		push_error("Truth fixture received an unsupported family or role.")
		quit(64)
		return

	match str(parts[1]):
		"pass":
			print(marker)
			quit()
		"missing_marker":
			quit()
		"nonzero_with_marker":
			print(marker)
			quit(23)
		"duplicate_marker":
			print(marker)
			print(marker)
			quit()
		"forbidden_stderr":
			push_error("Truth fixture emitted a forbidden error.")
			print(marker)
			quit()
		"forbidden_stdout":
			print("ERROR: Truth fixture emitted a forbidden stdout line.")
			print(marker)
			quit()
		"hang":
			await create_timer(60.0).timeout
			print(marker)
			quit()
		_:
			push_error("Truth fixture received an unsupported mode.")
			quit(64)


func _expected_marker(family: String, role: String) -> String:
	match family:
		"multiplayer":
			return "LAN_PROBE_OK"
		"rogue":
			if role in ["host", "client"]:
				return "MP_ROGUE_ROUTE_LAN_%s_OK" % role.to_upper()
	return ""


func _parse_options() -> Dictionary:
	var result := {}
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--probe-") or not argument.contains("="):
			continue
		var separator := argument.find("=")
		result[argument.substr(8, separator - 8)] = argument.substr(separator + 1)
	return result
