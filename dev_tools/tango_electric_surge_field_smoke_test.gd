extends SceneTree

const FIELD_SCENE := preload(
	"res://scene/player/tango/tango_electric_surge_field.tscn"
)
const FIELD_SCRIPT_PATH := "res://scene/player/tango/tango_electric_surge_field.gd"
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)


class DamageDispatcherStub:
	extends Node

	var applied_damage_count := 0
	var last_damage_type := -1
	var last_show_hit_particles := true

	func apply_multiplayer_collectible_enemy_damage(
		enemy: Enemy,
		damage: int,
		impact_direction: Vector2,
		damage_type: int = EnemyConfig.DamageType.MAGIC,
		show_hit_particles: bool = true
	) -> bool:
		applied_damage_count += 1
		last_damage_type = damage_type
		last_show_hit_particles = show_hit_particles
		var request := DamageRequest.new(damage, damage_type)
		request.with_directions(impact_direction)
		request.with_flag(
			CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
			not show_hit_particles
		)
		return enemy.apply_combat_damage(request).accepted

var failures: Array[String] = []
var fixture: Node2D = null
var finished_fields: Array[Node] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "TangoElectricSurgeFieldSmokeFixture"
	root.add_child(fixture)
	current_scene = fixture

	await _test_authored_scene_contract()
	await _test_visual_only_contract()
	await _test_initial_overlap_signal_contract()
	await _test_eight_authoritative_ticks_and_status_cleanup()

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("TANGO_ELECTRIC_SURGE_FIELD_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_scene_contract() -> void:
	var field_source := FileAccess.get_file_as_string(FIELD_SCRIPT_PATH)
	_expect(
		not field_source.contains("func _process(")
		and not field_source.contains("func _physics_process(")
		and not field_source.contains("get_nodes_in_group")
		and field_source.count("get_overlapping_bodies()") == 1,
		"场域玩法不得逐帧或全场扫描；只允许启动时补捕一次既有重叠。"
	)
	var field := FIELD_SCENE.instantiate() as TangoElectricSurgeField
	_expect(field != null, "电能涌动必须能实例化为独立 Area2D 场景。")
	if field == null:
		return
	field.setup_multiplayer_visual_only(1001, 8.0)
	fixture.add_child(field)
	await process_frame

	var circle := field.collision_shape.shape as CircleShape2D
	var material := field.field_visual.material as ShaderMaterial
	_expect(
		field.top_level
		and circle != null
		and is_equal_approx(circle.radius, 72.0)
		and is_equal_approx(field.damage_tick_timer.wait_time, 1.0)
		and field.damage_tick_timer.one_shot
		and is_equal_approx(field.lifetime_timer.wait_time, 8.0)
		and field.lifetime_timer.one_shot
		and field.lifetime_timer.process_physics_priority
			< field.damage_tick_timer.process_physics_priority
		and field.collision_layer == 0
		and field.collision_mask == 0
		and not field.monitorable,
		"场域必须固定在世界坐标、使用半径72，并让共享寿命时钟先于伤害Timer更新。"
	)
	_expect(
		material != null
		and material.shader != null
		and material.shader.code.contains("outward_wave")
		and material.shader.code.contains("render_mode unshaded, blend_add")
		and material.shader.code.contains("boundary * 0.28")
		and material.shader.code.contains("alpha = min(alpha, 0.42)")
		and field.field_visual.polygon.size() == 4,
		"地面电涌必须由单 draw Shader 保持高透明，同时提供可辨识的72像素边界。"
	)
	_expect(
		field.night_light != null
		and is_equal_approx(field.night_light.texture_scale, 0.68)
		and is_equal_approx(field.night_light.night_energy, 0.34)
		and field.night_light.color == Color(0.12, 0.9, 1.0, 1.0),
		"场域必须带有低能量青色 NightPointLight2D，并只由夜间系统启用。"
	)
	_expect(
		field.damage_tick_timer.one_shot
		and is_equal_approx(field.damage_tick_timer.wait_time, 1.0)
		and field.lifetime_timer.one_shot
		and is_equal_approx(field.lifetime_timer.wait_time, 8.0),
		"场域必须只用一个1秒伤害Timer和一个8秒视觉寿命Timer。"
	)
	field.finish()
	await process_frame


func _test_visual_only_contract() -> void:
	var field := FIELD_SCENE.instantiate() as TangoElectricSurgeField
	field.global_position = Vector2(91.0, 37.0)
	field.setup_multiplayer_visual_only(1002, 3.5)
	fixture.add_child(field)
	await process_frame
	await physics_frame

	var enemy := _make_enemy()
	field.call("_on_body_entered", enemy)
	_expect(
		field.global_position == Vector2(91.0, 37.0)
		and not field.is_authoritative()
		and not field.monitoring
		and field.collision_mask == 0
		and field.collision_shape.disabled
		and field.get_tracked_enemy_count() == 0
		and not enemy.has_electric_element_attachment()
		and enemy.get_electric_surge_slow_source_count() == 0
		and field.lifetime_timer.time_left > 3.0
		and field.lifetime_timer.time_left <= 3.5,
		"客户端视觉副本必须停留在生成位置、按剩余时长播放，且完全不能监测或修改敌人。"
	)
	field.finish()
	enemy.queue_free()
	await process_frame


func _test_initial_overlap_signal_contract() -> void:
	var enemy := _make_enemy()
	enemy.global_position = Vector2(220.0, 160.0)
	var field := FIELD_SCENE.instantiate() as TangoElectricSurgeField
	fixture.add_child(field)
	field.global_position = enemy.global_position
	field.setup(null, 1501)
	for _physics_index in range(3):
		await physics_frame
	_expect(
		field.get_tracked_enemy_count() == 1
		and enemy.has_electric_element_attachment()
		and enemy.get_electric_surge_slow_source_count() == 1,
		"生成时已在圆内的敌人必须由Area2D首轮重叠事件立即纳入状态集合。"
	)
	field.finish()
	enemy.queue_free()
	await process_frame


func _test_eight_authoritative_ticks_and_status_cleanup() -> void:
	var damage_dispatcher := DamageDispatcherStub.new()
	fixture.add_child(damage_dispatcher)
	var field := FIELD_SCENE.instantiate() as TangoElectricSurgeField
	var overlapping_field := (
		FIELD_SCENE.instantiate() as TangoElectricSurgeField
	)
	field.global_position = Vector2(24.0, 40.0)
	overlapping_field.global_position = field.global_position
	_expect(
		field.set_authoritative_damage_dispatcher(damage_dispatcher),
		"权威场域必须接受显式多人伤害分发器，以便施术者断线后继续即时同步。"
	)
	field.setup(null, 2001)
	# Network activation sequences are per player, so identical public zone IDs
	# must still own independent local slow-source leases.
	overlapping_field.setup(null, 2001)
	field.finished.connect(_on_field_finished)
	overlapping_field.finished.connect(_on_field_finished)
	fixture.add_child(field)
	fixture.add_child(overlapping_field)
	await process_frame
	await physics_frame

	var enemy := _make_enemy()
	enemy.global_position = field.global_position + Vector2.RIGHT * 24.0
	var health_before := enemy.current_health
	field.call("_on_body_entered", enemy)
	overlapping_field.call("_on_body_entered", enemy)
	_expect(
		enemy.has_electric_element_attachment()
		and enemy.get_electric_surge_slow_source_count() == 2
		and field.get_tracked_enemy_count() == 1,
		"同一activation ID的两个场域必须各自持有减速来源，且永久电附着保持幂等。"
	)
	overlapping_field.call("_on_body_exited", enemy)
	_expect(
		enemy.get_electric_surge_slow_source_count() == 1
		and is_equal_approx(enemy.get_effective_move_speed_multiplier(), 0.65),
		"重叠场域退出一个后必须保留另一来源及35%减速，不能误删共享ID。"
	)
	overlapping_field.finish()
	_expect(
		finished_fields.has(overlapping_field),
		"场域主动结束时必须发出带自身节点的finished信号。"
	)

	# Simulate two long frames. Damage is keyed to the shared lifetime clock, so
	# 3.4 seconds catches up three ticks and 7.2 catches up to seven without
	# shifting every later tick by the hitch duration.
	field.call("_apply_scheduled_damage_through", 3.4)
	_expect(
		field.completed_damage_tick_count == 3
		and enemy.current_health == health_before - 60,
		"场域卡顿到3.4秒时必须一次补齐前三跳，不能把后续节拍整体后移。"
	)
	field.call("_apply_scheduled_damage_through", 3.9)
	field.call("_apply_scheduled_damage_through", 7.2)
	_expect(
		field.completed_damage_tick_count == 7
		and enemy.current_health == health_before - 140,
		"同一秒内重复唤醒不得重复伤害，后续长帧必须只补到应到的第7跳。"
	)
	field.damage_tick_timer.stop()
	field.lifetime_timer.stop()
	field.call("_on_lifetime_timeout")
	_expect(
		field.completed_damage_tick_count == 8
		and enemy.current_health == health_before - 160
		and damage_dispatcher.applied_damage_count == 8
		and damage_dispatcher.last_damage_type == EnemyConfig.DamageType.MAGIC
		and not damage_dispatcher.last_show_hit_particles
		and not field.is_active()
		and finished_fields.has(field)
		and field.is_queued_for_deletion(),
		"权威场域必须在t=1..8准确结算8次固定20点法术伤害，并由第8跳结束。"
	)
	_expect(
		enemy.has_electric_element_attachment()
		and enemy.get_electric_surge_slow_source_count() == 0,
		"场域结束只清理自己的减速来源，永久电元素附着必须保留。"
	)
	enemy.queue_free()
	damage_dispatcher.queue_free()
	await process_frame


func _make_enemy() -> Enemy:
	var config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	config.max_health = 500
	config.magic_defense = 0
	config.move_speed = 100.0
	var enemy := config.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(config, null, null)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	return enemy


func _on_field_finished(field: Node) -> void:
	finished_fields.append(field)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
