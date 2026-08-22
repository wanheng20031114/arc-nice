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
	var family := str(parts[0])
	var marker := _expected_marker(family, role)
	if marker.is_empty():
		push_error("Truth fixture received an unsupported family or role.")
		quit(64)
		return
	if family == "relay":
		# Relay runner 必须从实时 stdout 精确解析 Host 身份，并在启动
		# 后续客户端前确认当前客户端已经进入拨号阶段。fixture 不伪造
		# 网络，只提供这两个有界的 runner 控制面标记。
		if role == "host":
			print("RELAY_PROBE_HOST_READY host_peer_id=123456789")
		elif role == "client":
			print("RELAY_PROBE_CLIENT_DIAL_STARTED")

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
		"engine_error":
			push_error("Truth fixture emitted a forbidden engine-log error.")
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
		"relay":
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
