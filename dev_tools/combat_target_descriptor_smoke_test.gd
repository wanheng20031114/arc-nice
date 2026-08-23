extends SceneTree

const TargetDescriptor := preload(
	"res://scene/combat/targeting/combat_target_descriptor.gd"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_factories_and_clear()
	_test_value_copy_and_identity()
	_test_network_round_trip()
	_test_invalid_payloads_are_rejected()
	if failures.is_empty():
		print("COMBAT_TARGET_DESCRIPTOR_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_factories_and_clear() -> void:
	var empty := TargetDescriptor.create_none()
	var ordered_empty := TargetDescriptor.create_none(7)
	_expect(
		empty != null
		and empty.kind == TargetDescriptor.Kind.NONE
		and empty.is_valid()
		and ordered_empty != null
		and ordered_empty.revision == 7
		and ordered_empty.is_valid(),
		"NONE 工厂必须支持规范空描述符及带序列号的清空事件。"
	)
	var player := TargetDescriptor.create_player(7, 2, Vector2(10.5, -4.0))
	var plant := TargetDescriptor.create_plant(8, 3, Vector2(-2.0, 6.0))
	var enemy := TargetDescriptor.create_enemy(9, 4, Vector2(1.0, 2.0))
	_expect(
		player != null and player.kind == TargetDescriptor.Kind.PLAYER
		and plant != null and plant.kind == TargetDescriptor.Kind.PLANT
		and enemy != null and enemy.kind == TargetDescriptor.Kind.ENEMY,
		"三类目标工厂必须保留稳定 kind。"
	)
	enemy.clear()
	_expect(
		enemy.kind == TargetDescriptor.Kind.NONE
		and enemy.id == 0
		and enemy.revision == 0
		and enemy.fallback_position == Vector2.ZERO
		and enemy.is_valid(),
		"clear 必须恢复规范 NONE 状态。"
	)


func _test_value_copy_and_identity() -> void:
	var source := TargetDescriptor.create_enemy(922337, 4, Vector2(3.0, 9.0))
	var copied := source.duplicate()
	var copied_alias := source.copy()
	var assigned := TargetDescriptor.create_none()
	var copied_from := assigned.copy_from(source)
	_expect(
		copied != source
		and copied.same_identity(source)
		and copied_alias != source
		and copied_alias.same_identity(source)
		and copied_from
		and assigned.same_identity(source)
		and copied.get_stable_key() == "3:922337"
		and copied.stable_key() == copied.get_stable_key()
		and assigned.get_stable_key() == copied.get_stable_key(),
		"duplicate/copy_from 必须生成独立值副本，identity 与稳定键不得受 revision 影响。"
	)
	copied.revision = 99
	copied.fallback_position = Vector2.ZERO
	_expect(
		copied.same_identity(source)
		and source.revision == 4
		and source.fallback_position == Vector2(3.0, 9.0)
		and not TargetDescriptor.create_player(1).same_identity(source),
		"同一目标刷新 revision/fallback 后应保持身份连续，且不得回写源对象。"
	)
	var invalid := TargetDescriptor.new()
	invalid.kind = TargetDescriptor.Kind.ENEMY
	invalid.id = 0
	_expect(
		not assigned.copy_from(invalid),
		"copy_from 必须拒绝非法源值。"
	)


func _test_network_round_trip() -> void:
	var source := TargetDescriptor.create_enemy(314, 12, Vector2(8.25, -19.5))
	var payload: Dictionary = source.to_network_dictionary()
	var restored := TargetDescriptor.from_network_dictionary(payload)
	_expect(
		restored != null
		and restored != source
		and restored.kind == TargetDescriptor.Kind.ENEMY
		and restored.id == 314
		and restored.revision == 12
		and restored.fallback_position == Vector2(8.25, -19.5),
		"有效描述符必须无损往返，且不得返回原对象。"
	)
	var empty_payload: Dictionary = (
		TargetDescriptor.create_none(23).to_network_dictionary()
	)
	var restored_empty := TargetDescriptor.from_network_dictionary(empty_payload)
	_expect(
		restored_empty != null and restored_empty.is_valid()
		and restored_empty.kind == TargetDescriptor.Kind.NONE
		and restored_empty.revision == 23,
		"带 revision 的规范 NONE 描述符必须可序列化。"
	)


func _test_invalid_payloads_are_rejected() -> void:
	_expect(
		TargetDescriptor.create_enemy(0) == null
		and TargetDescriptor.create(99, 1) == null
		and TargetDescriptor.create_player(1, -1) == null
		and TargetDescriptor.create_plant(1, 0, Vector2(NAN, 0.0)) == null,
		"工厂必须拒绝非正 ID、未知 kind、负 revision 与非有限坐标。"
	)
	var valid_payload := {
		"kind": TargetDescriptor.Kind.PLAYER,
		"id": 5,
		"revision": 1,
		"fallback_position": Vector2.ZERO,
	}
	var missing_payload := valid_payload.duplicate()
	missing_payload.erase("revision")
	var wrong_type_payload := valid_payload.duplicate()
	wrong_type_payload["id"] = 5.0
	var non_finite_payload := valid_payload.duplicate()
	non_finite_payload["fallback_position"] = Vector2(0.0, INF)
	var invalid_none_payload := {
		"kind": TargetDescriptor.Kind.NONE,
		"id": 1,
		"revision": 0,
		"fallback_position": Vector2.ZERO,
	}
	_expect(
		TargetDescriptor.from_network_dictionary(missing_payload) == null
		and TargetDescriptor.from_network_dictionary(wrong_type_payload) == null
		and TargetDescriptor.from_network_dictionary(non_finite_payload) == null
		and TargetDescriptor.from_network_dictionary(invalid_none_payload) == null,
		"网络解码必须严格拒绝缺字段、错类型、非有限坐标和非规范 NONE。"
	)
	var invalid_descriptor := TargetDescriptor.new()
	invalid_descriptor.kind = TargetDescriptor.Kind.ENEMY
	invalid_descriptor.id = 0
	_expect(
		invalid_descriptor.to_network_dictionary().is_empty(),
		"非法本地描述符不得产生网络载荷。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
