extends SceneTree

const SKILL3_ORB_SCENE := preload("res://scene/boss/linglan/linglan_skill3_light_orb.tscn")
const SKILL4_ORB_SCENE := preload("res://scene/boss/linglan/linglan_skill4_light_orb.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const SKILL3_ORB_SCRIPT_PATH := "res://scene/boss/linglan/linglan_skill3_light_orb.gd"
const SKILL4_ORB_SCRIPT_PATH := "res://scene/boss/linglan/linglan_skill4_light_orb.gd"
const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const TEST_RUNTIME_SCRIPT := preload(
	"res://dev_tools/fixtures/linglan_combat_test_runtime.gd"
)


class DamageReportHost:
	extends "res://dev_tools/fixtures/linglan_combat_test_runtime.gd"

	var damage_requests: Array[Dictionary] = []

	func request_multiplayer_player_damage(
		source_id: int,
		target_peer_id: int,
		damage: int,
		source_type: StringName,
		damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
		source_direction: Vector2 = Vector2.ZERO,
		is_ranged: bool = false,
		_contact_preconsumed: bool = false,
		source_snapshot: DamageSourceSnapshot = null
	) -> bool:
		damage_requests.append({
			"source_id": source_id,
			"target_peer_id": target_peer_id,
			"damage": damage,
			"source_type": source_type,
			"damage_type": damage_type,
			"source_direction": source_direction,
			"is_ranged": is_ranged,
			"source_snapshot": source_snapshot,
		})
		return true


var failures: Array[String] = []
var test_root: CombatRuntimeBase


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	if run_state != null:
		run_state.begin_new_run(&"weishidaier")
	test_root = TEST_RUNTIME_SCRIPT.new()
	test_root.name = "LinglanOrbEventSmokeTest"
	root.add_child(test_root)

	_test_query_frequency_contract()
	await _test_skill3_flying_body_entered_hit()
	await _test_skill3_expansion_capture_and_lifetime()
	await _test_skill4_flying_and_spawn_overlap_hits()
	await _test_skill4_lifetime()
	await _test_multiplayer_proxy_identity_and_deduplication()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("LINGLAN_ORB_EVENT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_query_frequency_contract() -> void:
	var skill3_source := FileAccess.get_file_as_string(SKILL3_ORB_SCRIPT_PATH)
	var skill3_physics_start := skill3_source.find("func _physics_process")
	var skill3_grow_start := skill3_source.find("func _grow", skill3_physics_start)
	_expect(
		skill3_physics_start >= 0 and skill3_grow_start > skill3_physics_start,
		"Skill3 orb process and growth methods must remain inspectable."
	)
	if skill3_physics_start >= 0 and skill3_grow_start > skill3_physics_start:
		var skill3_physics_source := skill3_source.substr(
			skill3_physics_start,
			skill3_grow_start - skill3_physics_start
		)
		_expect(
			not skill3_physics_source.contains("intersect_shape")
			and not skill3_physics_source.contains("_apply_expansion_overlap_damage"),
			"Skill3 orb must not perform an overlap query every physics frame."
		)
	_expect(
		skill3_source.count("intersect_shape(") == 1
		and skill3_source.count("_apply_expansion_overlap_damage()") == 2,
		"Skill3 orb must keep one expansion-only overlap query and one call site."
	)
	_expect(
		skill3_source.contains("body_entered.connect(_on_body_entered)"),
		"Skill3 flying hits must remain driven by Area2D.body_entered."
	)

	var skill4_source := FileAccess.get_file_as_string(SKILL4_ORB_SCRIPT_PATH)
	var skill4_physics_start := skill4_source.find("func _physics_process")
	var skill4_radius_start := skill4_source.find("func _apply_current_radius", skill4_physics_start)
	_expect(
		skill4_physics_start >= 0 and skill4_radius_start > skill4_physics_start,
		"Skill4 orb process method must remain inspectable."
	)
	if skill4_physics_start >= 0 and skill4_radius_start > skill4_physics_start:
		var skill4_physics_source := skill4_source.substr(
			skill4_physics_start,
			skill4_radius_start - skill4_physics_start
		)
		_expect(
			not skill4_physics_source.contains("overlap"),
			"Skill4 orb physics updates must not poll for overlaps."
		)
	_expect(
		skill4_source.count("intersect_shape(") == 0
		and skill4_source.contains("body_entered.connect(_on_body_entered)"),
		"Constant-radius Skill4 orbs must be purely Area2D.body_entered-driven."
	)


func _test_skill3_flying_body_entered_hit() -> void:
	var player := _spawn_player(test_root, Vector2(100.0, 0.0), 31, 200)
	var orb := SKILL3_ORB_SCENE.instantiate() as LinglanSkill3LightOrb
	orb.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill3_orb")
	)
	test_root.add_child(orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(orb)
	orb.global_position = Vector2.ZERO
	orb.setup(Vector2.RIGHT, 50, 90.0, 2.2)
	orb.set_physics_process(false)
	await physics_frame
	_set_player_health(player, 200)
	_expect(
		player.current_health == 200,
		"Skill3 pre-entry state changed: health=%d player=%s orb=%s radius=%.1f."
		% [player.current_health, player.global_position, orb.global_position, orb.get_current_radius()]
	)

	player.global_position = Vector2(31.5, 0.0)
	orb.call("_physics_process", 0.35)
	await physics_frame
	await process_frame
	var health_after_hit := player.current_health
	_expect(
		health_after_hit < 200,
		"A flying Skill3 orb must damage through body_entered after reaching the player."
	)
	orb.body_entered.emit(player)
	_expect(player.current_health == health_after_hit, "Skill3 body_entered must damage each player only once.")
	await _free_nodes([orb, player])


func _test_skill3_expansion_capture_and_lifetime() -> void:
	var player := _spawn_player(test_root, Vector2(30.0, 0.0), 32, 200)
	var orb := SKILL3_ORB_SCENE.instantiate() as LinglanSkill3LightOrb
	orb.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill3_orb")
	)
	test_root.add_child(orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(orb)
	orb.global_position = Vector2.ZERO
	orb.setup(Vector2.RIGHT, 50, 0.0, 5.0, 15.0, 3.0, 0.5, 2.0)
	orb.set_physics_process(false)
	await physics_frame
	_set_player_health(player, 200)
	_expect(
		player.current_health == 200,
		"Skill3 base-radius state changed: health=%d player=%s orb=%s radius=%.1f."
		% [player.current_health, player.global_position, orb.global_position, orb.get_current_radius()]
	)

	orb.call("_grow")
	var health_after_growth := player.current_health
	_expect(health_after_growth < 200, "Skill3 growth must synchronously capture players in the expanded radius.")
	_expect(orb.is_expanded(), "Skill3 orb must enter its expanded state.")
	_expect(is_equal_approx(orb.get_current_radius(), 45.0), "Skill3 expanded collision radius changed.")
	_expect(orb.get_visual_scale().is_equal_approx(Vector2(3.0, 3.0)), "Skill3 expansion visual scale changed.")
	await physics_frame
	_expect(player.current_health == health_after_growth, "Skill3 growth query and subsequent body signal must not double-hit.")

	orb.call("_physics_process", 0.51)
	await process_frame
	_expect(not is_instance_valid(orb), "Skill3 expanded orb lifetime cleanup changed.")
	await _free_nodes([player])


func _test_skill4_flying_and_spawn_overlap_hits() -> void:
	var flying_player := _spawn_player(test_root, Vector2(100.0, 0.0), 41, 200)
	var flying_orb := SKILL4_ORB_SCENE.instantiate() as LinglanSkill4LightOrb
	flying_orb.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill4_orb")
	)
	test_root.add_child(flying_orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(flying_orb)
	flying_orb.global_position = Vector2.ZERO
	flying_orb.setup(Vector2.RIGHT, 50, 40.0, 10.0, 8.0, 6.0)
	flying_orb.set_physics_process(false)
	await physics_frame
	_set_player_health(flying_player, 200)
	_expect(
		flying_player.current_health == 200,
		"Skill4 pre-entry state changed: health=%d player=%s orb=%s radius=%.1f."
		% [flying_player.current_health, flying_player.global_position, flying_orb.global_position, flying_orb.get_damage_radius()]
	)

	flying_player.global_position = Vector2(34.0, 0.0)
	flying_orb.call("_physics_process", 0.85)
	await physics_frame
	await process_frame
	await physics_frame
	await process_frame
	var health_after_hit := flying_player.current_health
	_expect(
		health_after_hit < 200,
		"A flying Skill4 orb must damage through body_entered after reaching the player."
	)
	flying_orb.body_entered.emit(flying_player)
	_expect(flying_player.current_health == health_after_hit, "Skill4 body_entered must damage each player only once.")
	await _free_nodes([flying_orb, flying_player])

	var spawn_player := _spawn_player(test_root, Vector2(4.0, 0.0), 42, 200)
	await physics_frame
	_set_player_health(spawn_player, 200)
	var spawn_orb := SKILL4_ORB_SCENE.instantiate() as LinglanSkill4LightOrb
	spawn_orb.set_damage_source_snapshot(
		_make_linglan_source_snapshot(&"linglan_skill4_orb")
	)
	test_root.add_child(spawn_orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(spawn_orb)
	spawn_orb.global_position = Vector2.ZERO
	spawn_orb.setup(Vector2.RIGHT, 50, 0.0, 10.0, 8.0, 6.0)
	spawn_orb.set_physics_process(false)
	await physics_frame
	_expect(spawn_player.current_health < 200, "Skill4 spawn overlap must be captured by the initial body_entered event.")
	await _free_nodes([spawn_orb, spawn_player])


func _test_skill4_lifetime() -> void:
	var orb := SKILL4_ORB_SCENE.instantiate() as LinglanSkill4LightOrb
	test_root.add_child(orb)
	(test_root as LinglanCombatTestRuntime).bind_linglan_node(orb)
	orb.setup(Vector2.LEFT, 50, 40.0, 0.25, 11.0, 9.0)
	orb.set_physics_process(false)
	_expect(is_equal_approx(orb.get_current_radius(), 11.0), "Skill4 visual radius configuration changed.")
	_expect(is_equal_approx(orb.get_damage_radius(), 9.0), "Skill4 damage radius configuration changed.")
	orb.call("_physics_process", 0.26)
	await process_frame
	_expect(
		is_instance_valid(orb)
		and orb.is_lifetime_despawning
		and orb.collision_layer == 0
		and orb.collision_mask == 0
		and is_zero_approx(orb.speed),
		"Skill4 expiry must disable damage and begin a stationary shrink."
	)
	if not is_instance_valid(orb):
		return
	orb.call("_physics_process", 0.2)
	_expect(
		orb.scale.x > 0.0 and orb.scale.x < 1.0,
		"Skill4 orb must visibly shrink during its 0.4s despawn."
	)
	orb.call("_physics_process", 0.21)
	await process_frame
	_expect(not is_instance_valid(orb), "Skill4 orb must disappear after its 0.4s shrink.")


func _test_multiplayer_proxy_identity_and_deduplication() -> void:
	var host := DamageReportHost.new()
	root.add_child(host)
	var player3 := _spawn_player(host, Vector2(80.0, 0.0), 73, 200)
	var orb3 := SKILL3_ORB_SCENE.instantiate() as LinglanSkill3LightOrb
	host.add_child(orb3)
	host.bind_linglan_node(orb3)
	orb3.setup(Vector2.RIGHT, 50, 0.0, 2.2)
	orb3.setup_multiplayer(7300123, 1, &"linglan_skill3_orb")
	MpProjectileCoordinator._apply_damage_source_snapshot_to_projectile(
		orb3,
		DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			7300,
			7300123,
			&"linglan_skill3_orb"
		)
	)
	orb3.set_physics_process(false)
	await process_frame
	_set_player_health(player3, 200)
	orb3.body_entered.emit(player3)
	orb3.body_entered.emit(player3)

	var player4 := _spawn_player(host, Vector2(96.0, 0.0), 74, 200)
	var orb4 := SKILL4_ORB_SCENE.instantiate() as LinglanSkill4LightOrb
	host.add_child(orb4)
	host.bind_linglan_node(orb4)
	orb4.setup(Vector2.LEFT, 50, 0.0, 10.0, 8.0, 6.0)
	orb4.setup_multiplayer(7400456, 1, &"linglan_skill4_orb")
	MpProjectileCoordinator._apply_damage_source_snapshot_to_projectile(
		orb4,
		DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			7400,
			7400456,
			&"linglan_skill4_orb"
		)
	)
	orb4.set_physics_process(false)
	await process_frame
	_set_player_health(player4, 200)
	orb4.body_entered.emit(player4)
	orb4.body_entered.emit(player4)

	_expect(host.damage_requests.size() == 2, "Multiplayer orb proxies must report each player exactly once.")
	_expect(player3.current_health == 200 and player4.current_health == 200, "Reporting proxies must not also apply fallback local damage.")
	if host.damage_requests.size() == 2:
		_expect_damage_request(host.damage_requests[0], 7300123, 73, &"linglan_skill3_orb")
		_expect_damage_request(host.damage_requests[1], 7400456, 74, &"linglan_skill4_orb")

	host.queue_free()
	await process_frame
	await physics_frame


func _expect_damage_request(
	request: Dictionary,
	expected_source_id: int,
	expected_peer_id: int,
	expected_source_type: StringName
) -> void:
	_expect(int(request.get("source_id", 0)) == expected_source_id, "Orb proxy projectile source identity changed.")
	_expect(int(request.get("target_peer_id", 0)) == expected_peer_id, "Orb proxy reported the wrong player peer.")
	_expect(request.get("source_type") == expected_source_type, "Orb proxy source type changed.")
	_expect(request.get("damage_type") == EnemyConfig.DamageType.MAGIC, "Orb proxy must report magic damage.")
	_expect(bool(request.get("is_ranged", false)), "Orb proxy damage must remain ranged.")
	var source_snapshot := request.get("source_snapshot") as DamageSourceSnapshot
	_expect(
		source_snapshot != null
		and source_snapshot.source_faction_id == CombatRelationService.HOSTILE_WAVE
		and source_snapshot.event_source_id == expected_source_id
		and source_snapshot.source_type == expected_source_type,
		"Orb proxy hit must retain the frozen hostile launch source."
	)


func _spawn_player(parent: Node, position: Vector2, peer_id: int, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.position = position
	parent.add_child(player)
	player.global_position = position
	player.peer_id = peer_id
	_set_player_health(player, health)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set_physics_process(false)
	return player


func _set_player_health(player: Player, health: int) -> void:
	player._base_max_health = health
	player.max_health = health
	player.current_health = health
	player._base_physical_defense = 0
	player._base_magic_defense = 0
	player.physical_defense = 0
	player.magic_defense = 0
	player.damage_reduction_modifiers.clear()
	if player.health_bar != null:
		player.health_bar.setup(player.max_health, player.current_health)


func _make_linglan_source_snapshot(source_type: StringName) -> DamageSourceSnapshot:
	return DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		0,
		9401,
		0,
		source_type
	)


func _free_nodes(nodes: Array) -> void:
	for node_variant in nodes:
		var node := node_variant as Node
		if node != null and is_instance_valid(node):
			node.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
