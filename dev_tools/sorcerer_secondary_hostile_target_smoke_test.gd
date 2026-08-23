extends SceneTree

const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const LIGHTNING_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer.tscn"
)
const LIGHTNING_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FROST_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer.tscn"
)
const FROST_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const TARGET_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)

var failures: Array[String] = []


class PlantQueryPort extends RefCounted:
	var plants: Array[PlantDefense] = []


	func resolve_plant(net_id: int) -> PlantDefense:
		for plant in plants:
			if int(plant.get_meta(&"net_id", 0)) == net_id:
				return plant
		return null


	func query_radius_into(
		center: Vector2,
		radius: float,
		result: Array[PlantDefense]
	) -> void:
		result.clear()
		var radius_squared := radius * radius
		for plant in plants:
			if center.distance_squared_to(plant.global_position) <= radius_squared:
				result.append(plant)


	func query_aabb_into(
		world_aabb: Rect2,
		result: Array[PlantDefense]
	) -> void:
		result.clear()
		for plant in plants:
			if world_aabb.has_point(plant.global_position):
				result.append(plant)


	func get_plant_id(plant: PlantDefense) -> int:
		return int(plant.get_meta(&"net_id", 0))


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_unified_query_priority_and_stable_order()
	await _test_lightning_enemy_to_enemy_chain()
	await _test_fire_reacquires_after_faction_change_and_death()
	await _test_frost_fallback_uses_hostile_query()
	if failures.is_empty():
		print("SORCERER_SECONDARY_HOSTILE_TARGET_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_unified_query_priority_and_stable_order() -> void:
	var runtime := await _create_runtime()
	var local_player := Player.new()
	local_player.peer_id = 1
	local_player.global_position = Vector2(16.0, 0.0)
	runtime.player = local_player
	var plant := PlantDefense.new()
	plant.global_position = Vector2(24.0, 0.0)
	plant.set_meta(&"net_id", 301)
	var plant_port := PlantQueryPort.new()
	plant_port.plants.append(plant)
	_expect(
		runtime.get_combat_query_facade().bind_plant_query_port(
			Callable(plant_port, &"resolve_plant"),
			Callable(plant_port, &"query_radius_into"),
			Callable(plant_port, &"query_aabb_into"),
			Callable(plant_port, &"get_plant_id")
		),
		"统一查询测试必须成功绑定独立植物索引端口。"
	)
	var stable_low := _spawn_target(
		runtime,
		401,
		Vector2(32.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	var stable_high := _spawn_target(
		runtime,
		402,
		Vector2(-32.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	var excluded: Dictionary = {}
	_expect(
		runtime.find_nearest_hostile_enemy_attack_target_world(
			Vector2.ZERO,
			64.0,
			CombatRelationService.HOSTILE_WAVE,
			excluded
		) == local_player,
		"统一敌对查询必须保留最近 Player 高于更远 Plant/Enemy 的规则。"
	)
	excluded[local_player.get_instance_id()] = true
	_expect(
		runtime.find_nearest_hostile_enemy_attack_target_world(
			Vector2.ZERO,
			64.0,
			CombatRelationService.HOSTILE_WAVE,
			excluded
		) == plant,
		"排除 Player 后必须继续选择最近 Plant，而不是跳到动态 Enemy。"
	)
	excluded[plant.get_instance_id()] = true
	_expect(
		runtime.find_nearest_hostile_enemy_attack_target_world(
			Vector2.ZERO,
			64.0,
			CombatRelationService.HOSTILE_WAVE,
			excluded
		) == stable_low,
		"等距 Enemy 必须按稳定网络 ID 选择较小者。"
	)
	excluded[stable_low.get_instance_id()] = true
	_expect(
		runtime.find_nearest_hostile_enemy_attack_target_world(
			Vector2.ZERO,
			64.0,
			CombatRelationService.HOSTILE_WAVE,
			excluded
		) == stable_high,
		"共享排除集合必须让二次查询稳定取得下一个 Enemy。"
	)
	runtime.player = null
	local_player.free()
	plant.free()
	await _dispose_runtime(runtime)


func _test_lightning_enemy_to_enemy_chain() -> void:
	var runtime := await _create_runtime()
	var caster := LIGHTNING_SCENE.instantiate() as LightningSorcerer
	runtime.enemy_container.add_child(caster)
	caster.global_position = Vector2.ZERO
	caster.setup(LIGHTNING_CONFIG, null, runtime.grid_pathfinder, runtime)
	caster.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	caster.set_physics_process(false)
	var first_target := _spawn_target(
		runtime,
		501,
		Vector2(40.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var friendly_decoy := _spawn_target(
		runtime,
		502,
		Vector2(48.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	var second_target := _spawn_target(
		runtime,
		503,
		Vector2(64.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var first_health := first_target.current_health
	var second_health := second_target.current_health
	var friendly_health := friendly_decoy.current_health
	caster.cast_damage_source_snapshot = caster.create_damage_source_snapshot(
		7501,
		&"lightning_sorcerer_chain"
	)
	var path := caster.call(
		"_resolve_chain_hits",
		first_target,
		LIGHTNING_CONFIG,
		7501
	) as PackedVector2Array
	_expect(
		path.size() == 3
		and first_target.current_health < first_health
		and second_target.current_health < second_health
		and friendly_decoy.current_health == friendly_health,
		"Lightning 必须从首个敌对 Enemy 连锁至第二个敌对 Enemy，并跳过更近友军。"
	)
	await _dispose_runtime(runtime)


func _test_fire_reacquires_after_faction_change_and_death() -> void:
	var runtime := await _create_runtime()
	var original := _spawn_target(
		runtime,
		601,
		Vector2(48.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var replacement := _spawn_target(
		runtime,
		602,
		Vector2(64.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var final_replacement := _spawn_target(
		runtime,
		603,
		Vector2(80.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var volley := FIREBALL_VOLLEY_SCENE.instantiate() as FireSorcererFireballVolley
	runtime.add_child(volley)
	volley.bind_gameplay_context(
		runtime,
		runtime.get_multiplayer_gameplay_gateway()
	)
	volley.global_position = Vector2.ZERO
	volley.setup(
		Vector2.RIGHT,
		10,
		100.0,
		3.0,
		original,
		6.0,
		runtime,
		1.0,
		1,
		DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			0,
			9001,
			7601,
			&"fire_sorcerer_fireball_volley"
		)
	)
	volley.set_physics_process(false)
	original.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	volley.call("_update_homing_target", 1.0 / 60.0)
	_expect(
		volley.target == replacement,
		"Fire 活目标转为友方后必须同 tick 放弃，并按冻结来源阵营重取敌对 Enemy。"
	)
	replacement.is_dead = true
	volley.call("_update_homing_target", 1.0 / 60.0)
	_expect(
		volley.target == final_replacement,
		"Fire 当前 Enemy 死亡后必须立即重取下一个存活敌对 Enemy。"
	)
	await _dispose_runtime(runtime)


func _test_frost_fallback_uses_hostile_query() -> void:
	var runtime := await _create_runtime()
	var caster := FROST_SCENE.instantiate() as FrostSorcerer
	runtime.enemy_container.add_child(caster)
	caster.global_position = Vector2.ZERO
	caster.setup(FROST_CONFIG, null, runtime.grid_pathfinder, runtime)
	caster.set_combat_faction_id(
		CombatRelationService.PLAYER_ALLIED,
		-1,
		true
	)
	caster.set_physics_process(false)
	_spawn_target(
		runtime,
		701,
		Vector2(16.0, 0.0),
		CombatRelationService.PLAYER_ALLIED
	)
	var hostile := _spawn_target(
		runtime,
		702,
		Vector2(32.0, 0.0),
		CombatRelationService.HOSTILE_WAVE
	)
	var selected := caster.call(
		"_select_nearest_attack_target",
		null,
		FROST_CONFIG,
		true
	) as Node2D
	_expect(
		selected == hostile,
		"Frost 家族备用搜索必须通过统一阵营查询跳过更近友军。"
	)
	await _dispose_runtime(runtime)


func _create_runtime() -> EnemyGameplayGatewayTestRuntime:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	return runtime


func _spawn_target(
	runtime: EnemyGameplayGatewayTestRuntime,
	net_id: int,
	position: Vector2,
	faction_id: int
) -> Enemy:
	var enemy := TARGET_CONFIG.enemy_scene.instantiate() as Enemy
	runtime.enemy_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(TARGET_CONFIG, null, runtime.grid_pathfinder, runtime)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.set_combat_faction_id(faction_id, -1, true)
	if not runtime.register_network_enemy(net_id, enemy):
		failures.append("测试敌人 %d 注册失败。" % net_id)
	return enemy


func _dispose_runtime(runtime: EnemyGameplayGatewayTestRuntime) -> void:
	runtime.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
