extends SceneTree

const GOLEM_SCENE := preload("res://scene/enemy/artificial_creation/stone_golem.tscn")
const GOLEM_CONFIG := preload("res://resources/config/enemies/stone_golem.tres")
const LATE_WAVES := [
	preload("res://resources/config/waves/wave_11.tres"),
	preload("res://resources/config/waves/wave_12.tres"),
]
const EXPECTED_GOLEM_COUNTS := [6, 8]
const EXPECTED_LATE_WAVE_TOTALS := [480, 560]
const CAMPAIGN_LATE_WAVES := [
	preload(
		"res://resources/config/campaigns/standard/singleplayer/wave_11.tres"
	),
	preload(
		"res://resources/config/campaigns/standard/singleplayer/wave_12.tres"
	),
	preload(
		"res://resources/config/campaigns/standard/multiplayer/wave_11.tres"
	),
	preload(
		"res://resources/config/campaigns/standard/multiplayer/wave_12.tres"
	),
	preload(
		"res://resources/config/campaigns/tower_defense/formal/wave_09.tres"
	),
	preload(
		"res://resources/config/campaigns/tower_defense/formal/wave_10.tres"
	),
	preload(
		"res://resources/config/campaigns/tower_defense/performance/waves/wave_11.tres"
	),
	preload(
		"res://resources/config/campaigns/tower_defense/performance/waves/wave_12.tres"
	),
]
const EXPECTED_CAMPAIGN_GOLEM_COUNTS := [6, 8, 6, 8, 20, 20, 15, 17]
const EXPECTED_CAMPAIGN_TOTALS := [
	480,
	560,
	480,
	560,
	3120,
	3780,
	1200,
	1200,
]
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const FRAME_SIZE := Vector2(64.0, 64.0)
const FRAME_GRID_SIZE := 4
const REQUIRED_FRAME_PADDING := 4
const MIN_ACTION_TOP_PADDING := 14
const MOVE_FOOT_BAND_TOP := 48
const MOVE_FOOT_BAND_BOTTOM := 58
const MIN_FOOT_RUN_WIDTH := 4
const TEST_HEALTH := 1000
const DENSE_TARGET_COUNT := 70

var failures: Array[String] = []
var test_root: Node


class BroadcastCaptureRoot:
	extends MultiplayerGameplayGateway

	var enemy_actions: Array[Dictionary] = []

	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		enemy_actions.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"position": action_position,
			"action_id": action_id,
		})


class TestPlant:
	extends PlantDefense


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = BroadcastCaptureRoot.new()
	test_root.name = "StoneGolemSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_contract()
	_test_wave_integration()
	await _test_defense_contract()
	await _test_contact_does_not_bypass_slam()
	await _test_windup_and_physical_slam()
	await _test_committed_slam_preserves_cooldown_and_impact()
	await _test_radial_range_and_single_hit()
	await _test_dense_slam_pagination()
	await _test_target_removal_cancels_windup()
	await _test_death_interrupts_windup()
	await _test_proxy_visual_contract()
	await _test_reused_attack_resources()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("STONE_GOLEM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(
		GOLEM_CONFIG is StoneGolemConfig,
		"Stone golem config must use StoneGolemConfig."
	)
	_expect(GOLEM_CONFIG.display_name == "石头人", "Display name mismatch.")
	_expect(GOLEM_CONFIG.enemy_scene == GOLEM_SCENE, "Enemy scene mismatch.")
	_expect(GOLEM_CONFIG.max_health == 1000, "Maximum health must be 1000.")
	_expect(GOLEM_CONFIG.attack_damage == 100, "Attack damage must be 100.")
	_expect(
		GOLEM_CONFIG.physical_defense == 50,
		"Physical defense must be 50."
	)
	_expect(GOLEM_CONFIG.magic_defense == 0, "Magic defense must be 0.")
	_expect(
		is_equal_approx(GOLEM_CONFIG.move_speed, 15.0),
		"Stone golem must use the authored slow movement speed."
	)
	_expect(
		GOLEM_CONFIG.slam_damage_type == EnemyConfig.DamageType.PHYSICAL,
		"Ground slam damage type must be physical."
	)
	_expect(
		is_equal_approx(GOLEM_CONFIG.attack_windup, 0.8),
		"Ground slam windup must be 0.8 seconds."
	)
	_expect(
		is_equal_approx(GOLEM_CONFIG.slam_radius, 44.0),
		"Ground slam radius must be 44 pixels."
	)
	_expect(
		is_equal_approx(GOLEM_CONFIG.initial_attack_stagger, 0.35),
		"Initial attack staggering must stay at 0.35 seconds."
	)

	var texture := load("res://resources/texture/enemy/artificial_creation/stone_golem.png") as Texture2D
	_expect(
		texture != null and texture.get_size() == Vector2(256.0, 256.0),
		"Stone golem sheet must be a native 4x4 grid of 64 px frames."
	)
	if texture != null:
		var texture_image := texture.get_image()
		_test_frame_alpha_padding(texture_image)
		_test_move_leg_silhouette(texture_image)

	var instance := GOLEM_SCENE.instantiate() as StoneGolem
	_expect(instance != null, "Stone golem scene must instantiate StoneGolem.")
	if instance == null:
		return
	var sprite := instance.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var warning := instance.get_node("WindupWarning") as Polygon2D
	var impact_ring := instance.get_node("SlamImpactRing") as Line2D
	var body_shape := (
		instance.get_node("CollisionShape2D") as CollisionShape2D
	)
	var touch_shape := (
		instance.get_node("TouchDamageArea/CollisionShape2D")
		as CollisionShape2D
	)
	_expect(
		sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Stone golem must use Nearest texture filtering."
	)
	_expect(
		sprite.scale == Vector2.ONE,
		"Stone golem sprite scale must stay at the lossless integer scale 1."
	)
	_expect(
		sprite.position == Vector2(0.0, -6.0),
		"Stone golem sprite must retain the reviewed core-aligned offset."
	)
	_expect(
		warning != null and impact_ring != null,
		"Warning and reusable impact nodes must be authored in the scene."
	)
	_expect(
		warning.position == Vector2.ZERO
		and impact_ring.position == Vector2.ZERO,
		"Slam warning and impact ring must stay centered on the damage query."
	)
	_expect(
		body_shape.shape is RectangleShape2D
		and touch_shape.shape is RectangleShape2D
		and body_shape.shape != touch_shape.shape,
		"Body and touch rectangles must be independent scene resources."
	)
	var body_rect := body_shape.shape as RectangleShape2D
	var touch_rect := touch_shape.shape as RectangleShape2D
	_expect(
		body_rect.size == Vector2(20.0, 20.0)
		and touch_rect.size == Vector2(20.0, 20.0)
		and body_shape.position == touch_shape.position
		and body_shape.position.length() <= 2.0,
		"Stone golem must retain the medium Capoo-like navigation footprint."
	)
	_expect(
		body_rect.size.x <= 64.0 and body_rect.size.y <= 64.0,
		"Navigation footprint must stay inside four 16 px cells."
	)
	_expect(
		instance.navigation_update_interval_frames == 8,
		"Slow stone golems must use the profiled 7.5 Hz navigation cadence."
	)

	var frames := sprite.sprite_frames
	_expect(frames != null, "Stone golem SpriteFrames are missing.")
	if frames != null:
		for animation_name in [&"move", &"windup", &"attack", &"death"]:
			_expect(
				frames.has_animation(animation_name),
				"Missing %s animation." % animation_name
			)
			_expect(
				frames.get_frame_count(animation_name) == 4,
				"%s must contain four authored frames." % animation_name
			)
			for frame_index in range(
				frames.get_frame_count(animation_name)
			):
				var frame_texture := frames.get_frame_texture(
					animation_name,
					frame_index
				) as AtlasTexture
				_expect(
					frame_texture != null
					and frame_texture.get_size() == FRAME_SIZE,
					"%s frame %d must be exactly 64x64."
					% [animation_name, frame_index]
				)
		_expect(
			frames.get_animation_loop(&"move")
			and not frames.get_animation_loop(&"windup")
			and not frames.get_animation_loop(&"attack")
			and not frames.get_animation_loop(&"death"),
			"Only the movement animation may loop."
		)
	instance.free()


func _test_wave_integration() -> void:
	for wave_index in range(LATE_WAVES.size()):
		_expect_wave_composition(
			LATE_WAVES[wave_index] as WaveConfig,
			EXPECTED_GOLEM_COUNTS[wave_index],
			EXPECTED_LATE_WAVE_TOTALS[wave_index],
			"authored late wave %d" % [wave_index + 11]
		)
	for campaign_index in range(CAMPAIGN_LATE_WAVES.size()):
		_expect_wave_composition(
			CAMPAIGN_LATE_WAVES[campaign_index] as WaveConfig,
			EXPECTED_CAMPAIGN_GOLEM_COUNTS[campaign_index],
			EXPECTED_CAMPAIGN_TOTALS[campaign_index],
			"campaign late-wave snapshot %d" % campaign_index
		)


func _expect_wave_composition(
	wave: WaveConfig,
	expected_golem_count: int,
	expected_total_count: int,
	label: String
) -> void:
	var golem_count := 0
	var total_count := 0
	for entry in wave.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		total_count += entry.count
		if entry.enemy_config.resource_path == GOLEM_CONFIG.resource_path:
			golem_count += entry.count
	_expect(
		golem_count == expected_golem_count,
		"%s must contain %d stone golems." % [label, expected_golem_count]
	)
	_expect(
		total_count == expected_total_count,
		"%s total must stay at %d." % [label, expected_total_count]
	)


func _test_frame_alpha_padding(image: Image) -> void:
	_expect(
		image != null and image.get_size() == Vector2i(256, 256),
		"Imported stone golem image is unavailable."
	)
	if image == null or image.get_size() != Vector2i(256, 256):
		return
	for row in range(FRAME_GRID_SIZE):
		for column in range(FRAME_GRID_SIZE):
			var minimum := Vector2i(64, 64)
			var maximum := Vector2i(-1, -1)
			for local_y in range(64):
				for local_x in range(64):
					var pixel := image.get_pixel(
						column * 64 + local_x,
						row * 64 + local_y
					)
					if pixel.a <= 0.0:
						continue
					minimum.x = mini(minimum.x, local_x)
					minimum.y = mini(minimum.y, local_y)
					maximum.x = maxi(maximum.x, local_x)
					maximum.y = maxi(maximum.y, local_y)
			_expect(
				maximum.x >= 0,
				"Frame %d,%d must contain visible pixels." % [row, column]
			)
			if maximum.x < 0:
				continue
			var padding := mini(
				mini(minimum.x, minimum.y),
				mini(63 - maximum.x, 63 - maximum.y)
			)
			_expect(
				padding >= REQUIRED_FRAME_PADDING,
				"Frame %d,%d safety padding is %d px; expected at least %d."
				% [row, column, padding, REQUIRED_FRAME_PADDING]
			)
			if row == 1 or row == 2:
				_expect(
					minimum.y >= MIN_ACTION_TOP_PADDING,
					"Action frame %d,%d contains cross-row ghost pixels at y=%d."
					% [row, column, minimum.y]
				)


func _test_move_leg_silhouette(image: Image) -> void:
	if image == null or image.get_size() != Vector2i(256, 256):
		return
	for frame_index in range(4):
		var occupied_columns: Array[bool] = []
		occupied_columns.resize(64)
		occupied_columns.fill(false)
		for local_x in range(64):
			for local_y in range(MOVE_FOOT_BAND_TOP, MOVE_FOOT_BAND_BOTTOM):
				if image.get_pixel(frame_index * 64 + local_x, local_y).a > 0.0:
					occupied_columns[local_x] = true
					break
		var meaningful_runs := 0
		var run_start := -1
		for local_x in range(65):
			var occupied := (
				local_x < 64 and occupied_columns[local_x]
			)
			if occupied and run_start < 0:
				run_start = local_x
			elif not occupied and run_start >= 0:
				if local_x - run_start >= MIN_FOOT_RUN_WIDTH:
					meaningful_runs += 1
				run_start = -1
		_expect(
			meaningful_runs >= 2,
			"Move frame %d must retain two separated lower-leg/foot silhouettes."
			% frame_index
		)


func _test_defense_contract() -> void:
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	enemy.hit_audio.stream = null
	var expected_stagger := (
		GOLEM_CONFIG.initial_attack_stagger
		* float(int(enemy.get_instance_id()) % 23)
		/ 22.0
	)
	_expect(
		is_equal_approx(enemy.attack_cooldown_left, expected_stagger),
		"Initial attack stagger must use the deterministic 23-phase schedule."
	)
	enemy.current_health = TEST_HEALTH
	enemy.apply_damage(
		100,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		enemy.current_health == 950,
		"50 physical defense must reduce 100 physical damage to 50."
	)
	enemy.apply_damage(
		100,
		Vector2.ZERO,
		EnemyConfig.DamageType.MAGIC,
		false
	)
	_expect(
		enemy.current_health == 850,
		"0 magic defense must leave 100 magic damage unchanged."
	)
	enemy.queue_free()
	await process_frame


func _test_contact_does_not_bypass_slam() -> void:
	var plant := _spawn_test_plant(Vector2.ZERO, 30, 0)
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	await _wait_physics_frames(2)
	_expect(
		enemy.touching_plants.has(plant.get_instance_id()),
		"Stone-golem contact fixture must register the overlapping plant."
	)
	_expect(
		not bool(enemy.call("_uses_inherited_touch_damage"))
		and plant.current_health == TEST_HEALTH
		and is_zero_approx(enemy.touch_damage_cooldown_left),
		"Stone golems must reserve damage for their authored slam, not contact."
	)
	enemy.call("_try_deal_touch_damage")
	enemy.call("_try_deal_touch_damage")
	_expect(
		plant.current_health == TEST_HEALTH
		and is_zero_approx(enemy.touch_damage_cooldown_left),
		"Repeated contact dispatch must not bypass the stone-golem slam state machine."
	)
	enemy.queue_free()
	plant.queue_free()
	await _wait_physics_frames(2)

	var player := _spawn_player(Vector2(96.0, 0.0))
	var player_enemy := _spawn_golem(Vector2(96.0, 0.0), player)
	player_enemy.set_physics_process(false)
	await _wait_physics_frames(2)
	_expect(
		player_enemy.touching_players.has(player.get_instance_id()),
		"Stone-golem contact fixture must register the overlapping player."
	)
	player_enemy.call("_try_deal_touch_damage")
	_expect(
		player.current_health == TEST_HEALTH
		and player.last_damage_taken == 0
		and is_zero_approx(player_enemy.touch_damage_cooldown_left),
		"Player contact must not bypass the stone-golem slam state machine."
	)
	player_enemy.queue_free()
	player.queue_free()
	await _wait_physics_frames(2)


func _test_windup_and_physical_slam() -> void:
	var plant := _spawn_test_plant(Vector2(36.0, 0.0), 30, 80)
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	enemy.attack_cooldown_left = 0.0
	await _wait_physics_frames(2)
	var health_before := plant.current_health
	_expect(
		plant.current_health == health_before,
		"A target outside the 20 px core must not take contact damage."
	)
	_expect(
		bool(enemy.call("_try_start_windup")),
		"Stone golem must enter windup against a nearby plant."
	)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.WINDUP
		and enemy.windup_warning.visible
		and enemy.animated_sprite.animation == &"windup",
		"Windup must stop movement, show its radius, and play windup animation."
	)
	enemy.call("_update_windup", GOLEM_CONFIG.attack_windup * 0.5)
	_expect(
		plant.current_health == health_before,
		"Ground slam must deal no damage during early windup."
	)
	enemy.call("_update_windup", GOLEM_CONFIG.attack_windup * 0.5)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.SLASH
		and enemy.animated_sprite.animation == &"attack",
		"Stone golem must enter its attack animation after windup."
	)
	enemy.call("_update_slash", GOLEM_CONFIG.slash_damage_delay * 0.9)
	_expect(
		plant.current_health == health_before,
		"Ground slam must wait for its authored contact frame."
	)
	enemy.call("_update_slash", GOLEM_CONFIG.slash_damage_delay * 0.2)
	var health_after_slam := plant.current_health
	_expect(
		health_after_slam == health_before - 70,
		"100 physical slam damage must become 70 against 30 physical defense."
	)
	enemy.call("_update_slash", 0.0)
	_expect(
		plant.current_health == health_after_slam,
		"One slam action must damage each target exactly once."
	)
	_expect(
		enemy.slam_impact_ring.visible,
		"The reusable impact ring must begin on the actual damage frame."
	)
	enemy.call("_finish_slash")
	_expect(
		is_equal_approx(
			enemy.attack_cooldown_left,
			GOLEM_CONFIG.attack_interval
		),
		"Attack cooldown must begin after the slam action finishes."
	)
	_expect(
		not bool(enemy.call("_try_start_windup")),
		"Stone golem must not attack again during cooldown."
	)
	enemy.queue_free()
	plant.queue_free()
	await _wait_physics_frames(2)


func _test_committed_slam_preserves_cooldown_and_impact() -> void:
	var plant := _spawn_test_plant(Vector2(30.0, 0.0))
	plant.current_health = GOLEM_CONFIG.attack_damage
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	enemy.attack_cooldown_left = 0.0
	await _wait_physics_frames(2)
	_expect(
		bool(enemy.call("_try_start_windup")),
		"Committed-slam fixture must begin windup."
	)
	enemy.call("_update_windup", GOLEM_CONFIG.attack_windup)
	enemy.call("_update_slash", GOLEM_CONFIG.slash_damage_delay)
	_expect(
		enemy.slash_damage_done and enemy.slam_impact_ring.visible,
		"A committed killing slam must show its impact."
	)
	enemy.call("_physics_process", 0.0)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.SLASH
		and enemy.animated_sprite.animation == &"attack",
		"Killing the current target must not truncate a committed attack."
	)
	_expect(
		enemy.slam_impact_ring.visible,
		"Target death must not erase an already committed impact visual."
	)
	enemy.call("_physics_process", GOLEM_CONFIG.slash_duration)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.CHASE
		and is_equal_approx(
			enemy.attack_cooldown_left,
			GOLEM_CONFIG.attack_interval
		),
		"A committed killing slam must finish into the full attack cooldown."
	)
	enemy.queue_free()
	if is_instance_valid(plant):
		plant.queue_free()
	await _wait_physics_frames(2)


func _test_radial_range_and_single_hit() -> void:
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	var front := _spawn_test_plant(Vector2(30.0, 0.0))
	var behind := _spawn_test_plant(Vector2(-30.0, 0.0))
	var edge := _spawn_test_plant(Vector2(42.0, 0.0))
	var outside := _spawn_test_plant(Vector2(52.0, 0.0))
	await _wait_physics_frames(2)
	enemy.slash_direction = Vector2.RIGHT
	enemy.action_sequence = 1
	enemy.call("_apply_slash_damage")
	_expect(
		front.current_health == 900
		and behind.current_health == 900
		and edge.current_health == 900,
		"Ground slam must hit front, back, and near-edge targets in its circle."
	)
	_expect(
		outside.current_health == TEST_HEALTH,
		"Ground slam must not hit a target outside its small radius."
	)
	for node in [enemy, front, behind, edge, outside]:
		node.queue_free()
	await _wait_physics_frames(2)


func _test_dense_slam_pagination() -> void:
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	var plants: Array[TestPlant] = []
	for target_index in range(DENSE_TARGET_COUNT):
		var angle := TAU * float(target_index) / float(DENSE_TARGET_COUNT)
		var radius := 18.0 + float(target_index % 4) * 4.0
		plants.append(
			_spawn_test_plant(Vector2.from_angle(angle) * radius)
		)
	await _wait_physics_frames(2)
	StoneGolem.set_slam_performance_metrics_enabled(true)
	enemy.action_sequence = 2
	enemy.call("_apply_slash_damage")
	var damaged_count := 0
	for plant in plants:
		if plant.current_health == 900:
			damaged_count += 1
	_expect(
		damaged_count == DENSE_TARGET_COUNT,
		"Dense ground slam must not truncate after one physics-query page."
	)
	var metrics := StoneGolem.get_slam_performance_metrics(true)
	StoneGolem.set_slam_performance_metrics_enabled(false)
	_expect(
		int(metrics["slam_query_calls"]) == 1
		and int(metrics["slam_unique_targets"]) == DENSE_TARGET_COUNT
		and int(metrics["slam_damage_dispatches"]) == DENSE_TARGET_COUNT
		and int(metrics["slam_physics_queries"]) >= 2,
		"Dense slam metrics must prove complete paging and unique dispatches: %s."
		% [metrics]
	)
	_expect(
		int(metrics["slam_total_usec"]) >= int(metrics["slam_query_usec"]),
		"Total slam time must include the isolated shape-query time."
	)
	enemy.queue_free()
	for plant in plants:
		plant.queue_free()
	await _wait_physics_frames(2)


func _test_target_removal_cancels_windup() -> void:
	var plant := _spawn_test_plant(Vector2(30.0, 0.0))
	var enemy := _spawn_golem(Vector2.ZERO, null)
	var capture_root := test_root as BroadcastCaptureRoot
	var actions_before := capture_root.enemy_actions.size()
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	enemy.attack_cooldown_left = 0.0
	await _wait_physics_frames(2)
	_expect(
		bool(enemy.call("_try_start_windup")),
		"Removal fixture must begin a windup."
	)
	var health_before := plant.current_health
	plant.is_removing = true
	enemy.call("_physics_process", 0.0)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.CHASE
		and not enemy.windup_warning.visible
		and plant.current_health == health_before,
		"Removing the objective must cancel windup without damage."
	)
	_expect(
		capture_root.enemy_actions.size() >= actions_before + 2
		and (
			capture_root.enemy_actions.back()["action_name"]
			as StringName
		) == &"cancel",
		"Authoritative target removal must broadcast proxy cancellation."
	)
	enemy.queue_free()
	plant.queue_free()
	await _wait_physics_frames(2)


func _test_death_interrupts_windup() -> void:
	var player := _spawn_player(Vector2(30.0, 0.0))
	var enemy := _spawn_golem(Vector2.ZERO, player)
	enemy.attack_cooldown_left = 0.0
	await _wait_physics_frames(2)
	_expect(
		bool(enemy.call("_try_start_windup")),
		"Death fixture must begin a windup."
	)
	var health_before := player.current_health
	enemy.apply_damage(
		GOLEM_CONFIG.max_health + GOLEM_CONFIG.physical_defense,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	await _wait_physics_frames(45)
	_expect(
		player.current_health == health_before,
		"A dead stone golem must never finish its pending slam."
	)
	if is_instance_valid(enemy):
		enemy.queue_free()
	player.queue_free()
	await _wait_physics_frames(2)


func _test_proxy_visual_contract() -> void:
	var proxy := _spawn_golem(Vector2.ZERO, null)
	proxy.configure_multiplayer_proxy()
	proxy.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(
		proxy.animated_sprite.animation == &"windup"
		and proxy.windup_warning.visible,
		"Multiplayer proxy must reproduce the windup animation and warning."
	)
	proxy.play_multiplayer_enemy_action(&"slash", Vector2.RIGHT, 2)
	await process_frame
	_expect(
		proxy.animated_sprite.animation == &"attack"
		and not proxy.windup_warning.visible,
		"Multiplayer proxy must reproduce the slam animation."
	)
	await _wait_physics_frames(
		ceili(GOLEM_CONFIG.slash_damage_delay * 60.0) + 2
	)
	_expect(
		proxy.slam_impact_ring.visible,
		"Multiplayer proxy must show the impact ring at the damage frame."
	)
	await _wait_physics_frames(
		ceili(GOLEM_CONFIG.impact_visual_duration * 60.0) + 3
	)
	_expect(
		not proxy.slam_impact_ring.visible,
		"Multiplayer proxy impact must fade and hide without physics processing."
	)
	proxy.play_multiplayer_enemy_action(&"windup", Vector2.LEFT, 3)
	await process_frame
	proxy.play_multiplayer_enemy_action(&"cancel", Vector2.LEFT, 4)
	await process_frame
	_expect(
		proxy.animated_sprite.animation == &"move"
		and not proxy.windup_warning.visible
		and not proxy.slam_impact_ring.visible,
		"Multiplayer proxy cancellation must clear false danger visuals."
	)
	proxy.play_multiplayer_death_sequence()
	_expect(
		not proxy.windup_warning.visible
		and not proxy.slam_impact_ring.visible,
		"Proxy death must clear all slam visuals."
	)
	proxy.queue_free()
	await process_frame


func _test_reused_attack_resources() -> void:
	var enemy := _spawn_golem(Vector2.ZERO, null)
	enemy.set_physics_process(false)
	await _wait_physics_frames(2)
	var child_count := enemy.get_child_count()
	var query_id := enemy.slam_query.get_instance_id()
	var shape_id := enemy.slash_query_shape.get_instance_id()
	for _attack_index in range(12):
		enemy.call("_apply_slash_damage")
		enemy.call("_update_slam_impact_visual", 1.0)
	_expect(
		enemy.get_child_count() == child_count
		and enemy.slam_query.get_instance_id() == query_id
		and enemy.slash_query_shape.get_instance_id() == shape_id,
		"Repeated slams must reuse query, shape, warning, and impact nodes."
	)
	enemy.queue_free()
	await _wait_physics_frames(2)


func _spawn_golem(position: Vector2, player: Player) -> StoneGolem:
	var enemy := GOLEM_SCENE.instantiate() as StoneGolem
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(GOLEM_CONFIG, player)
	enemy.bind_gameplay_gateway(test_root as BroadcastCaptureRoot)
	return enemy


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_physics_process(false)
	return player


func _spawn_test_plant(
	position: Vector2,
	physical_defense := 0,
	magic_defense := 0
) -> TestPlant:
	var plant := TestPlant.new()
	plant.collision_layer = 1 << 9
	plant.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 1.0
	shape_node.shape = circle
	plant.add_child(shape_node)
	test_root.add_child(plant)
	plant.global_position = position
	plant.max_health = TEST_HEALTH
	plant.current_health = TEST_HEALTH
	plant.physical_defense = physical_defense
	plant.magic_defense = magic_defense
	plant.is_dead = false
	plant.is_removing = false
	plant.is_multiplayer_proxy = false
	return plant


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
