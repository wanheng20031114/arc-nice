extends SceneTree

const RelationService := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_default_relations()
	_test_directed_overrides_and_reset()
	_test_invalid_relations_fail_closed()
	if failures.is_empty():
		print("COMBAT_RELATION_SERVICE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_relations() -> void:
	var relations := RelationService.new()
	for faction in range(RelationService.MAX):
		_expect(
			not relations.is_hostile(faction, faction),
			"默认同阵营必须友好：%d。" % faction
		)
		_expect(
			not relations.is_hostile(RelationService.NEUTRAL, faction)
			and not relations.is_hostile(faction, RelationService.NEUTRAL),
			"NEUTRAL 不得与任何阵营默认敌对：%d。" % faction
		)
	_expect(
		relations.is_hostile(
			RelationService.PLAYER_ALLIED,
			RelationService.HOSTILE_WAVE
		)
		and relations.is_hostile(
			RelationService.HOSTILE_WAVE,
			RelationService.PLAYER_ALLIED
		),
		"PLAYER_ALLIED 与 HOSTILE_WAVE 必须默认双向敌对。"
	)
	_expect(
		not RelationService.is_default_hostile(3, 4)
		and not relations.is_hostile(3, 4),
		"预留阵营不得在没有显式配置时自动敌对。"
	)
	_expect(
		RelationService.MAX_FACTION_COUNT == RelationService.MAX
		and RelationService.is_valid_faction_id(RelationService.MAX - 1)
		and not RelationService.is_valid_faction_id(RelationService.MAX)
		and RelationService.normalize_faction_id(3, 1) == 3
		and RelationService.normalize_faction_id(-1, 2) == 2
		and RelationService.normalize_faction_id(-1, 99) == RelationService.NEUTRAL,
		"阵营边界别名与 normalize_faction_id 必须保持稳定。"
	)


func _test_directed_overrides_and_reset() -> void:
	var relations := RelationService.new()
	_expect(
		relations.set_hostile(
			RelationService.PLAYER_ALLIED,
			RelationService.HOSTILE_WAVE,
			false
		),
		"合法有向关系必须可修改。"
	)
	_expect(
		not relations.is_hostile(
			RelationService.PLAYER_ALLIED,
			RelationService.HOSTILE_WAVE
		)
		and relations.is_hostile(
			RelationService.HOSTILE_WAVE,
			RelationService.PLAYER_ALLIED
		),
		"修改一个方向不得隐式修改反向关系。"
	)
	var hostile_mask := relations.get_hostile_mask(RelationService.HOSTILE_WAVE)
	_expect(
		(hostile_mask & (1 << RelationService.PLAYER_ALLIED)) != 0,
		"get_hostile_mask 必须返回对应有向关系位。"
	)
	relations.reset_default_relations()
	_expect(
		relations.is_hostile(
			RelationService.PLAYER_ALLIED,
			RelationService.HOSTILE_WAVE
		),
		"reset_default_relations 必须恢复默认关系。"
	)


func _test_invalid_relations_fail_closed() -> void:
	var relations := RelationService.new()
	var original_mask := relations.get_hostile_mask(RelationService.PLAYER_ALLIED)
	_expect(
		not relations.set_hostile(-1, RelationService.HOSTILE_WAVE)
		and not relations.set_hostile(
			RelationService.PLAYER_ALLIED,
			RelationService.MAX
		)
		and not relations.set_hostile(
			RelationService.PLAYER_ALLIED,
			RelationService.PLAYER_ALLIED
		),
		"非法 ID 与同阵营敌对写入必须被拒绝。"
	)
	_expect(
		relations.get_hostile_mask(RelationService.PLAYER_ALLIED) == original_mask
		and relations.get_hostile_mask(-1) == 0
		and not relations.is_hostile(-1, RelationService.HOSTILE_WAVE)
		and not relations.is_hostile(RelationService.HOSTILE_WAVE, RelationService.MAX),
		"非法查询必须 fail-closed，且不得污染合法关系。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
