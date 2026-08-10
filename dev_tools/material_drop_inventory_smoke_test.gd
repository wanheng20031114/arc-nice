extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const PICKUP_SCENE := preload("res://scene/combat/pickups/pickup.tscn")
const PROFILE_PANEL_SCENE := preload(
	"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
)
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const SPEED := preload("res://resources/config/pickup_triggered_items/speed_boots.tres")
const RAPID := preload("res://resources/config/pickup_triggered_items/rapid_magazine.tres")
const TEMPURA := preload("res://resources/config/pickup_triggered_items/tenpura.tres")
const SPIRAL := preload("res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const WHITE_CRYSTAL := preload(
	"res://resources/config/materials/material_white_crystal.tres"
)
const CAPOO_BLUE_CRYSTAL := preload(
	"res://resources/config/materials/material_capoo_blue_crystal.tres"
)
const SORCERER_VIOLET_POWDER := preload(
	"res://resources/config/materials/material_sorcerer_violet_powder.tres"
)
const GEL := preload("res://resources/config/materials/material_gel.tres")
const SMALL_STONE := preload(
	"res://resources/config/materials/material_small_stone.tres"
)
const DEFAULT_ENEMY_DROP_TABLE: EnemyDropTable = preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)
const STONE_GOLEM_DROP_TABLE: EnemyDropTable = preload(
	"res://resources/config/enemies/stone_golem_drop_table.tres"
)
const STONE_GOLEM_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/stone_golem.tres"
)
const STONE_GOLEM_ELITE_CONFIG: EnemyConfig = preload(
	"res://resources/config/enemies/stone_golem_elite.tres"
)
const EnemyDropRuleScript := preload(
	"res://resources/config/enemies/enemy_drop_rule.gd"
)
const ALL_MATERIALS: Array[PickupConfig] = [
	WOOD,
	SAPLING,
	WHITE_CRYSTAL,
	CAPOO_BLUE_CRYSTAL,
	SORCERER_VIOLET_POWDER,
	GEL,
	SMALL_STONE,
]
const GLOBAL_DROP_CONFIGS: Array[PickupConfig] = [
	WOOD,
	WHITE_CRYSTAL,
	SAPLING,
	SPEED,
	RAPID,
	TEMPURA,
	SPIRAL,
]

var failures: Array[String] = []
var test_root: Node2D
var run_state: RunStateStore


class DropAllowingGameplayGateway:
	extends MultiplayerGameplayGateway

	func allows_enemy_pickup_drops() -> bool:
		return true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "MaterialDropInventorySmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	run_state = root.get_node("RunState") as RunStateStore

	await _test_tempura_attack_buff()
	await _test_pickup_single_consumption()
	_test_material_config_and_icons()
	_test_deterministic_independent_drop_resolution()
	_test_local_and_peer_stack_limits()
	await _test_authoritative_death_drop_gate()
	await _test_material_drop_batch_spawn()
	await _test_material_inventory_detail()

	test_root.queue_free()
	for _cleanup_frame in range(12):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("MATERIAL_DROP_INVENTORY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_tempura_attack_buff() -> void:
	run_state.begin_new_run()
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await process_frame
	await physics_frame
	var base_attack := player.attack_damage
	var base_move_multiplier := player.current_move_speed_multiplier
	_expect(player.apply_pickup(TEMPURA), "Tempura must apply an immediate temporary buff.")
	_expect(player.attack_damage == ceili(float(base_attack) * 1.1), "Tempura must raise attack by 10%, rounded up to the integer stat.")
	_expect(is_equal_approx(player.current_move_speed_multiplier, base_move_multiplier), "Tempura must not change movement speed.")
	player.call("_update_pickup_effects", 2.0)
	_expect(is_equal_approx(player.attack_buff_time_left, 3.0), "Tempura duration must count down from five seconds.")
	_expect(player.apply_pickup(TEMPURA), "A second Tempura must refresh the existing buff.")
	_expect(player.attack_damage == ceili(float(base_attack) * 1.1), "Multiple Tempura buffs must not multiply or add together.")
	_expect(is_equal_approx(player.attack_buff_time_left, 5.0), "A second Tempura must refresh, not extend, the duration.")
	player.call("_update_pickup_effects", 5.1)
	_expect(player.attack_damage == base_attack, "Tempura attack must return to its base value after expiry.")
	_stop_audio_players(player)
	player.queue_free()
	await process_frame
	await physics_frame


func _test_pickup_single_consumption() -> void:
	run_state.begin_new_run(&"weishidaier", false)
	var first_player := PLAYER_SCENE.instantiate() as Player
	var second_player := PLAYER_SCENE.instantiate() as Player
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	pickup.config = WOOD
	first_player.position = Vector2(1000.0, 0.0)
	second_player.position = Vector2(1200.0, 0.0)
	test_root.add_child(first_player)
	test_root.add_child(second_player)
	test_root.add_child(pickup)
	await process_frame
	await physics_frame

	var consumed_peer_ids: Array[int] = []
	pickup.consumed.connect(
		func(_pickup: Pickup, peer_id: int, _applied_immediately: bool) -> void:
			consumed_peer_ids.append(peer_id)
			# Re-enter synchronously from the signal as well as through the second
			# same-frame overlap below. Neither path may mutate authority twice.
			pickup.call("_on_body_entered", second_player)
	)
	pickup.call("_on_body_entered", first_player)
	pickup.call("_on_body_entered", second_player)
	_expect(
		pickup.lifecycle == Pickup.Lifecycle.CONSUMED
		and pickup.is_queued_for_deletion()
		and consumed_peer_ids.size() == 1
		and run_state.get_inventory_item_total(WOOD) == 1,
		"同一掉落物在同步信号重入和同帧双玩家重叠下都必须只写入一次。"
	)
	_expect(
		first_player.powerup_audio.playing
		and not second_player.powerup_audio.playing,
		"成功收集资源掉落的玩家必须播放现有拾取声，未收集者不能误播。"
	)

	_stop_audio_players(first_player)
	_stop_audio_players(second_player)
	first_player.queue_free()
	second_player.queue_free()
	await process_frame
	await physics_frame


func _test_material_config_and_icons() -> void:
	for material in ALL_MATERIALS:
		_expect(material.pickup_type == PickupConfig.PickupType.MATERIAL, "%s must use the material pickup category." % material.display_name)
		_expect(material.can_store_in_inventory and material.stackable, "%s must be a stackable inventory item." % material.display_name)
		_expect(material.inventory_stack_limit == 999, "%s must cap each slot at 999." % material.display_name)
		_expect(material.icon_scale == Vector2(0.625, 0.625), "%s world drop must match the visual size of ordinary pickups." % material.display_name)
		_expect(is_equal_approx(material.world_lifetime, 24.0), "%s world drop must survive for 24 seconds." % material.display_name)
	_audit_material_icon(WOOD, 8, 115.0)
	# The legacy sapling source predates the binary-alpha material contract.
	# Keep auditing it without making this unrelated task rewrite its artwork.
	_audit_material_icon(SAPLING, 32, 115.0, false)
	_audit_material_icon(WHITE_CRYSTAL, 32, 90.0, true, "white")
	_audit_material_icon(CAPOO_BLUE_CRYSTAL, 32, 65.0, true, "blue")
	_audit_material_icon(
		SORCERER_VIOLET_POWDER,
		32,
		50.0,
		true,
		"violet"
	)
	_expect(
		GEL.icon_texture != null
		and GEL.icon_texture.resource_path
		== "res://resources/texture/materials/gel.png",
		"Gel must use its dedicated generated material icon."
	)
	_audit_material_icon(GEL, 32, 65.0, true, "blue")
	_expect(
		SMALL_STONE.icon_texture != null
		and SMALL_STONE.icon_texture.resource_path
		== "res://resources/texture/materials/small_stone.png",
		"Small stone must use its dedicated generated material icon."
	)
	_audit_material_icon(SMALL_STONE, 32, 45.0)
	_audit_refined_generated_icon(
		CAPOO_BLUE_CRYSTAL,
		Rect2i(10, 3, 12, 25)
	)
	_audit_refined_generated_icon(
		WHITE_CRYSTAL,
		Rect2i(8, 1, 16, 29)
	)
	_audit_refined_generated_icon(
		SORCERER_VIOLET_POWDER,
		Rect2i(7, 8, 18, 16)
	)
	_expect(is_equal_approx(TEMPURA.world_lifetime, 12.0), "Ordinary pickups must retain the default 12-second lifetime.")


func _test_deterministic_independent_drop_resolution() -> void:
	for rule in DEFAULT_ENEMY_DROP_TABLE.rules:
		_expect(
			rule != null
			and rule.pickup_config != null
			and not rule.pickup_config.is_consumable_item(),
			"普通敌人默认掉落表不得包含任何消耗品。"
		)
	var global_rules := DEFAULT_ENEMY_DROP_TABLE.get_eligible_rules(
		PackedStringArray()
	)
	_expect(
		global_rules.size() == 7,
		"An untagged enemy must independently evaluate three common materials and four pickup-triggered items, with no consumables."
	)

	var successful_rolls: Array[float] = []
	var boundary_rolls: Array[float] = []
	for rule in global_rules:
		successful_rolls.append(rule.chance * 0.5)
		boundary_rolls.append(rule.chance)
	var simultaneous_drops := (
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			PackedStringArray(),
			successful_rolls
		)
	)
	_expect(
		simultaneous_drops.size() == global_rules.size(),
		"Independent rolls must allow one enemy to drop every eligible item at once."
	)
	for expected_config in GLOBAL_DROP_CONFIGS:
		_expect(
			expected_config in simultaneous_drops,
			"Successful independent global rolls must include %s."
			% expected_config.resource_path
		)
	_expect(
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			PackedStringArray(),
			boundary_rolls
		).is_empty(),
		"A roll equal to its configured chance must fail the strict probability boundary."
	)
	var production_rng := RandomNumberGenerator.new()
	var reference_rng := RandomNumberGenerator.new()
	production_rng.seed = 20260720
	reference_rng.seed = production_rng.seed
	var seeded_rolls: Array[float] = []
	for _rule in global_rules:
		seeded_rolls.append(reference_rng.randf())
	var expected_seeded_drops := (
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			PackedStringArray(),
			seeded_rolls
		)
	)
	var actual_seeded_drops := DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs(
		PackedStringArray(),
		production_rng
	)
	_expect(
		actual_seeded_drops == expected_seeded_drops,
		"The production RNG path must use the same independent resolver as deterministic tests."
	)
	_expect(
		production_rng.state == reference_rng.state,
		"The production RNG path must consume exactly one roll per eligible rule."
	)

	var endpoint_table := EnemyDropTable.new()
	var never_rule := EnemyDropRuleScript.new()
	never_rule.pickup_config = WOOD
	never_rule.chance = 0.0
	endpoint_table.rules.append(never_rule)
	var always_rule := EnemyDropRuleScript.new()
	always_rule.pickup_config = WHITE_CRYSTAL
	always_rule.chance = 1.0
	endpoint_table.rules.append(always_rule)
	_expect(
		endpoint_table.resolve_drop_configs_from_rolls(
			PackedStringArray(),
			[0.0, 1.0]
		) == [WHITE_CRYSTAL],
		"Zero-percent rules must always fail and 100-percent rules must always succeed, including RNG endpoints."
	)

	var capoo_drops := DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
		PackedStringArray(["capoo"]),
		_zero_rolls(8)
	)
	_expect(
		capoo_drops.size() == 8
		and CAPOO_BLUE_CRYSTAL in capoo_drops
		and SORCERER_VIOLET_POWDER not in capoo_drops
		and GEL not in capoo_drops
		and SMALL_STONE not in capoo_drops,
		"Capoo tags must add only the independent blue-crystal rule."
	)
	var sorcerer_drops := (
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			PackedStringArray(["sorcerer"]),
			_zero_rolls(8)
		)
	)
	_expect(
		sorcerer_drops.size() == 8
		and SORCERER_VIOLET_POWDER in sorcerer_drops
		and CAPOO_BLUE_CRYSTAL not in sorcerer_drops
		and GEL not in sorcerer_drops
		and SMALL_STONE not in sorcerer_drops,
		"Sorcerer tags must add only the independent violet-powder rule."
	)
	var slime_tags := PackedStringArray(["slime"])
	var slime_drops := DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
		slime_tags,
		_zero_rolls(8)
	)
	_expect(
		slime_drops.size() == 8
		and GEL in slime_drops
		and CAPOO_BLUE_CRYSTAL not in slime_drops
		and SORCERER_VIOLET_POWDER not in slime_drops
		and SMALL_STONE not in slime_drops,
		"Slime tags must add only the independent gel rule."
	)
	var gel_only_rolls: Array[float] = []
	var gel_boundary_rolls: Array[float] = []
	for rule in DEFAULT_ENEMY_DROP_TABLE.get_eligible_rules(slime_tags):
		var is_gel_rule := rule.pickup_config == GEL
		gel_only_rolls.append(0.0 if is_gel_rule else 1.0)
		gel_boundary_rolls.append(rule.chance if is_gel_rule else 1.0)
	_expect(
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			slime_tags,
			gel_only_rolls
		) == [GEL],
		"The slime gel roll must succeed independently of every other eligible rule."
	)
	_expect(
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			slime_tags,
			gel_boundary_rolls
		).is_empty(),
		"A gel roll equal to its 2% chance must fail the strict probability boundary."
	)
	var artificial_creation_tags := PackedStringArray(["artificial_creation"])
	var default_artificial_drops := (
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			artificial_creation_tags,
			_zero_rolls(7)
		)
	)
	_expect(
		default_artificial_drops.size() == 7
		and SMALL_STONE not in default_artificial_drops,
		"The shared table must not grant small stone to arbitrary artificial creations."
	)
	var stone_golem_rules := STONE_GOLEM_DROP_TABLE.get_eligible_rules(
		artificial_creation_tags
	)
	_expect(
		stone_golem_rules.size() == 8
		and stone_golem_rules.slice(0, 7)
		== DEFAULT_ENEMY_DROP_TABLE.get_eligible_rules(artificial_creation_tags)
		and stone_golem_rules[7].pickup_config == SMALL_STONE,
		"The stone-golem table must expand the shared base rules first and append its local small-stone rule."
	)
	var small_stone_only_rolls: Array[float] = []
	var small_stone_boundary_rolls: Array[float] = []
	for rule in stone_golem_rules:
		var is_small_stone_rule := rule.pickup_config == SMALL_STONE
		small_stone_only_rolls.append(0.0 if is_small_stone_rule else 1.0)
		small_stone_boundary_rolls.append(
			rule.chance if is_small_stone_rule else 1.0
		)
	_expect(
		STONE_GOLEM_DROP_TABLE.resolve_drop_configs_from_rolls(
			artificial_creation_tags,
			small_stone_only_rolls
		) == [SMALL_STONE],
		"The stone-golem small-stone roll must succeed independently of every other eligible rule."
	)
	_expect(
		STONE_GOLEM_DROP_TABLE.resolve_drop_configs_from_rolls(
			artificial_creation_tags,
			small_stone_boundary_rolls
		).is_empty(),
		"A small-stone roll equal to its 50% chance must fail the strict probability boundary."
	)
	_expect(
		CAPOO_BLUE_CRYSTAL not in simultaneous_drops
		and SORCERER_VIOLET_POWDER not in simultaneous_drops
		and GEL not in simultaneous_drops
		and SMALL_STONE not in simultaneous_drops,
		"Untagged enemies must not receive any tag-exclusive material rule."
	)
	var all_tagged_drops := (
		DEFAULT_ENEMY_DROP_TABLE.resolve_drop_configs_from_rolls(
			PackedStringArray(
				["capoo", "sorcerer", "slime", "artificial_creation"]
			),
			_zero_rolls(10)
		)
	)
	_expect(
		all_tagged_drops.size() == 10
		and CAPOO_BLUE_CRYSTAL in all_tagged_drops
		and SORCERER_VIOLET_POWDER in all_tagged_drops
		and GEL in all_tagged_drops
		and SMALL_STONE not in all_tagged_drops,
		"Tag filters must remain composable without turning the table into a weighted choice."
	)

	var violet_rule = _find_drop_rule(SORCERER_VIOLET_POWDER)
	_expect(
		violet_rule != null
		and is_equal_approx(violet_rule.chance, 0.01)
		and violet_rule.required_tags == PackedStringArray(["sorcerer"]),
		"The documented assumption must keep violet powder at a sorcerer-only 1% chance."
	)
	var gel_rule = _find_drop_rule(GEL)
	_expect(
		gel_rule != null
		and is_equal_approx(gel_rule.chance, 0.02)
		and gel_rule.required_tags == PackedStringArray(["slime"]),
		"Gel must remain an independent slime-only 2% drop."
	)
	var small_stone_rule = _find_drop_rule(
		SMALL_STONE,
		STONE_GOLEM_DROP_TABLE
	)
	_expect(
		small_stone_rule != null
		and is_equal_approx(small_stone_rule.chance, 0.5)
		and small_stone_rule.required_tags.is_empty()
		and STONE_GOLEM_CONFIG.drop_table == STONE_GOLEM_DROP_TABLE
		and STONE_GOLEM_ELITE_CONFIG.drop_table == STONE_GOLEM_DROP_TABLE,
		"Both stone golems must explicitly use the inherited table with its local 50% small-stone rule."
	)
	var powder_rule_count := 0
	for rule in DEFAULT_ENEMY_DROP_TABLE.rules:
		if (
			rule != null
			and rule.pickup_config != null
			and rule.pickup_config.resource_path.contains("powder")
		):
			powder_rule_count += 1
			_expect(
				rule.pickup_config == SORCERER_VIOLET_POWDER,
				"The reserved pale-blue powder must not appear in an active enemy drop rule."
			)
	_expect(
		powder_rule_count == 1,
		"Only the violet sorcerer powder may have an active powder drop rule."
	)


func _test_local_and_peer_stack_limits() -> void:
	run_state.begin_new_run()
	for material_index in range(ALL_MATERIALS.size()):
		var material := ALL_MATERIALS[material_index]
		_expect(
			run_state.try_add_item(material)
			and run_state.try_add_item(material),
			"%s must accept repeated inventory copies." % material.display_name
		)
		_expect(
			run_state.get_item(material_index) == material
			and run_state.get_item_count(material_index)
			== (RunStateStore.STARTING_WOOD_COUNT + 2 if material == WOOD else 2),
			"%s copies must share one material stack." % material.display_name
		)
		_expect(
			not run_state.try_use_item(material_index, null),
			"%s must remain non-consumable." % material.display_name
		)

	run_state.begin_new_run()
	for _index in range(999 - RunStateStore.STARTING_WOOD_COUNT):
		_expect(run_state.try_add_item(WOOD), "Wood copy must fit before the first stack reaches 999.")
	_expect(run_state.get_item(0) == WOOD and run_state.get_item_count(0) == 999, "The first wood slot must hold exactly 999 items.")
	_expect(run_state.try_add_item(WOOD), "Wood copy 1000 must spill into another free slot.")
	_expect(run_state.get_item(1) == WOOD and run_state.get_item_count(1) == 1, "A full wood stack must spill into a new slot.")
	for _index in range(20):
		_expect(run_state.try_add_item(SAPLING), "Saplings must stack in their own slot.")
	_expect(run_state.get_item(2) == SAPLING and run_state.get_item_count(2) == 20, "Saplings must not merge with wood.")
	_expect(not run_state.try_use_item(2, null), "Materials must not be consumable.")
	_expect(run_state.discard_item(0), "Deleting a material stack must succeed.")
	_expect(run_state.get_item(0) == null and run_state.get_item_count(0) == 0, "Deleting a material stack must clear the whole selected slot.")

	run_state.ensure_multiplayer_peer_state(7)
	for _index in range(999):
		_expect(run_state.try_add_item_for_peer(7, SAPLING), "Peer sapling copy must fit before 999.")
	_expect(run_state.get_item_count_for_peer(7, 1) == 999, "Peer material stacks must use the same 999 limit.")
	_expect(run_state.try_add_item_for_peer(7, SAPLING), "Peer material copy 1000 must spill into another slot.")
	_expect(run_state.get_item_count_for_peer(7, 2) == 1, "Peer material overflow must use a second slot.")


func _test_material_drop_batch_spawn() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	test_root.add_child(player)
	test_root.add_child(enemy)
	enemy.setup(BASIC_ENEMY_CONFIG, player, null)
	await process_frame
	var spawn_position := Vector2(12.0, 18.0)
	var drop_configs: Array[PickupConfig] = [
		WOOD,
		WHITE_CRYSTAL,
		CAPOO_BLUE_CRYSTAL,
		SORCERER_VIOLET_POWDER,
		GEL,
		SMALL_STONE,
	]
	enemy.call("_spawn_dropped_pickups", drop_configs, spawn_position)
	await process_frame
	_expect(
		enemy.call("_get_dropped_pickup_offset", 0, 1) == Vector2.ZERO,
		"A single drop must stay exactly at the defeated enemy position."
	)
	var spawned_by_path: Dictionary = {}
	var spawned_materials: Array[Pickup] = []
	for child in test_root.get_children():
		var pickup := child as Pickup
		if pickup == null or pickup.config not in drop_configs:
			continue
		spawned_materials.append(pickup)
		var config_path := pickup.config.resource_path
		spawned_by_path[config_path] = int(
			spawned_by_path.get(config_path, 0)
		) + 1
	_expect(
		spawned_materials.size() == drop_configs.size(),
		"The base Enemy batch path must instantiate every independently resolved drop."
	)
	for drop_config in drop_configs:
		_expect(
			int(spawned_by_path.get(drop_config.resource_path, 0)) == 1,
			"Batch spawning must create exactly one pickup for %s."
			% drop_config.resource_path
		)
	var unique_positions: Dictionary = {}
	var position_sum := Vector2.ZERO
	for spawned_material in spawned_materials:
		unique_positions[spawned_material.global_position] = true
		position_sum += spawned_material.global_position
		_expect(
			spawned_material.global_position.distance_to(spawn_position)
			<= Enemy.ENEMY_DROP_OUTER_RING_RADIUS + 0.01,
			"Every material pickup must remain in a compact ring around the defeated enemy."
		)
		_expect(spawned_material.sprite.scale == spawned_material.config.icon_scale, "Each spawned material must apply its world-only icon scale.")
		_expect(
			spawned_material.sprite.modulate == Color.WHITE
			and spawned_material.sprite.self_modulate == Color.WHITE,
			"The spawned material must render its native texture colors without runtime brightness compensation."
		)
		_expect(is_equal_approx(spawned_material.lifetime_timer.wait_time, 24.0), "The spawned material timer must use the configured 24-second lifetime.")
		var blink_material := spawned_material.sprite.material as ShaderMaterial
		_expect(blink_material != null and not bool(blink_material.get_shader_parameter(&"blink_enabled")), "The pickup blink shader must stay visually inactive before expiry.")
		spawned_material.queue_free()
	_expect(
		unique_positions.size() == spawned_materials.size(),
		"Independent simultaneous drops must use distinct deterministic positions instead of hiding under one another."
	)
	if not spawned_materials.is_empty():
		_expect(
			(position_sum / float(spawned_materials.size())).distance_to(
				spawn_position
			) <= 0.01,
			"The deterministic drop spread must remain centered on the defeated enemy."
		)
	enemy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_authoritative_death_drop_gate() -> void:
	var always_drop_table := EnemyDropTable.new()
	for drop_config in [WOOD, WHITE_CRYSTAL]:
		var rule := EnemyDropRuleScript.new()
		rule.pickup_config = drop_config
		rule.chance = 1.0
		always_drop_table.rules.append(rule)
	var always_drop_config := BASIC_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	always_drop_config.drop_table = always_drop_table
	always_drop_config.xirang_kill_reward = 0

	var player := PLAYER_SCENE.instantiate() as Player
	var enemy := always_drop_config.enemy_scene.instantiate() as Enemy
	var gameplay_gateway := DropAllowingGameplayGateway.new()
	test_root.add_child(player)
	test_root.add_child(gameplay_gateway)
	test_root.add_child(enemy)
	player.global_position = Vector2(1000.0, 1000.0)
	enemy.global_position = Vector2(100.0, 100.0)
	enemy.setup(always_drop_config, player, null)
	enemy.bind_gameplay_gateway(gameplay_gateway)
	await process_frame
	enemy.call("_die")
	enemy.call("_die")
	await process_frame
	var authoritative_drop_count := _count_pickups_for_configs(
		[WOOD, WHITE_CRYSTAL]
	)
	_expect(
		authoritative_drop_count == 2,
		(
			"One authoritative death must defer exactly one batch, and repeated death "
			+ "calls must not duplicate it (actual=%d)." % authoritative_drop_count
		)
	)

	var proxy_enemy := always_drop_config.enemy_scene.instantiate() as Enemy
	test_root.add_child(proxy_enemy)
	proxy_enemy.global_position = Vector2(200.0, 100.0)
	proxy_enemy.setup(always_drop_config, player, null)
	proxy_enemy.bind_gameplay_gateway(gameplay_gateway)
	proxy_enemy.is_multiplayer_proxy = true
	await process_frame
	proxy_enemy.call("_die")
	await process_frame
	_expect(
		_count_pickups_for_configs([WOOD, WHITE_CRYSTAL])
		== authoritative_drop_count,
		"A multiplayer proxy death must never perform a local drop roll or spawn."
	)
	for child in test_root.get_children():
		var pickup := child as Pickup
		if pickup != null and pickup.config in [WOOD, WHITE_CRYSTAL]:
			pickup.queue_free()
	enemy.queue_free()
	proxy_enemy.queue_free()
	gameplay_gateway.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _count_pickups_for_configs(configs: Array) -> int:
	var count := 0
	for child in test_root.get_children():
		var pickup := child as Pickup
		if pickup != null and pickup.config in configs:
			count += 1
	return count


func _zero_rolls(count: int) -> Array[float]:
	var rolls: Array[float] = []
	rolls.resize(count)
	rolls.fill(0.0)
	return rolls


func _find_drop_rule(
	pickup_config: PickupConfig,
	table: EnemyDropTable = DEFAULT_ENEMY_DROP_TABLE
):
	for rule in table.rules:
		if rule != null and rule.pickup_config == pickup_config:
			return rule
	return null


func _audit_material_icon(
	material: PickupConfig,
	max_visible_colors: int,
	minimum_mean_luminance: float,
	require_binary_alpha: bool = true,
	color_family: String = ""
) -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(material.icon_texture.resource_path))
	_expect(image != null and image.get_size() == Vector2i(32, 32), "%s icon must remain a native 32x32 texture." % material.display_name)
	if image == null:
		return
	var visible_colors: Dictionary = {}
	var visible_pixel_count := 0
	var luminance_sum := 0.0
	var red_sum := 0.0
	var green_sum := 0.0
	var blue_sum := 0.0
	var has_partial_alpha := false
	var has_dirty_transparent_rgb := false
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if is_zero_approx(pixel.a):
				has_dirty_transparent_rgb = has_dirty_transparent_rgb or not Vector3(pixel.r, pixel.g, pixel.b).is_zero_approx()
				continue
			if not is_equal_approx(pixel.a, 1.0):
				has_partial_alpha = true
			visible_colors[pixel.to_rgba32()] = true
			visible_pixel_count += 1
			luminance_sum += (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) * 255.0
			red_sum += pixel.r * 255.0
			green_sum += pixel.g * 255.0
			blue_sum += pixel.b * 255.0
	_expect(visible_pixel_count > 0, "%s icon must contain visible pixels." % material.display_name)
	_expect(visible_colors.size() <= max_visible_colors, "%s icon must use a compact pixel-art palette." % material.display_name)
	_expect(
		not require_binary_alpha or not has_partial_alpha,
		"%s icon must keep binary alpha for crisp nearest-neighbour rendering."
		% material.display_name
	)
	_expect(not has_dirty_transparent_rgb, "%s icon must keep transparent RGB clear." % material.display_name)
	if visible_pixel_count > 0:
		_expect(luminance_sum / float(visible_pixel_count) >= minimum_mean_luminance, "%s icon source palette must be bright enough without runtime compensation." % material.display_name)
		var mean_red := red_sum / float(visible_pixel_count)
		var mean_green := green_sum / float(visible_pixel_count)
		var mean_blue := blue_sum / float(visible_pixel_count)
		match color_family:
			"blue":
				_expect(
					mean_blue > mean_red + 30.0
					and mean_green > mean_red + 20.0,
					"%s must retain its cyan-blue crystal color family."
					% material.display_name
				)
			"white":
				_expect(
					minf(mean_red, minf(mean_green, mean_blue)) > 120.0,
					"%s must retain bright near-neutral opalescent facets."
					% material.display_name
				)
			"violet":
				_expect(
					mean_blue > mean_green + 35.0
					and mean_red > mean_green + 15.0,
					"%s must remain violet rather than reverting to reserved pale blue."
					% material.display_name
				)


func _audit_refined_generated_icon(
	material: PickupConfig,
	expected_bbox: Rect2i
) -> void:
	var image := Image.load_from_file(
		ProjectSettings.globalize_path(material.icon_texture.resource_path)
	)
	if image == null:
		return
	_expect(
		image.get_used_rect() == expected_bbox,
		"%s must retain the approved generated subject size and centering."
		% material.display_name
	)
	if image.get_used_rect() != expected_bbox:
		return
	var mixed_alpha_blocks := 0
	for local_y in range(0, expected_bbox.size.y - 1, 2):
		for local_x in range(0, expected_bbox.size.x - 1, 2):
			var alpha_states: Dictionary = {}
			for offset_y in range(2):
				for offset_x in range(2):
					var pixel_position := (
						expected_bbox.position
						+ Vector2i(local_x + offset_x, local_y + offset_y)
					)
					alpha_states[
						image.get_pixelv(pixel_position).a > 0.5
					] = true
			if alpha_states.size() > 1:
				mixed_alpha_blocks += 1
	_expect(
		mixed_alpha_blocks > 0,
		(
			"%s silhouette must keep the refined generated edge instead of "
			+ "collapsing into mechanically duplicated 2x pixels."
		)
		% material.display_name
	)


func _test_material_inventory_detail() -> void:
	run_state.begin_new_run()
	_expect(run_state.try_add_item(WOOD) and run_state.try_add_item(WOOD), "UI setup must create a two-item wood stack.")
	var player := PLAYER_SCENE.instantiate() as Player
	var profile := PROFILE_PANEL_SCENE.instantiate() as StandardPlayerProfilePanel
	test_root.add_child(player)
	test_root.add_child(profile)
	await process_frame
	await physics_frame
	profile.bind_player(player)
	profile.open()
	await process_frame
	profile.slots[0].emit_signal("pressed")
	await process_frame
	_expect(profile.slots[0].stack_count_label.visible and profile.slots[0].stack_count_label.text == "7", "A material slot must include the five starting wood in its stack count.")
	_expect(profile.item_detail_title.text == "木头 ×7", "Material detail must include the selected stack count.")
	_expect(profile.item_detail_category_label.text == "物资", "Material detail must show the new material category.")
	_expect(profile.item_detail_description.text.contains(WOOD.description), "Material detail must show its description.")
	_expect(profile.slots[0].item_icon.modulate == Color.WHITE, "Inventory material icons must preserve their original color instead of inheriting the world tint.")
	_expect(not profile.item_detail_use_button.visible, "Materials must not show a use button.")
	_expect(not profile.item_detail_hint.visible, "Materials must not show a double-click use hint.")
	_expect(profile.item_detail_discard_button.visible and profile.item_detail_discard_button.text == "删除", "Materials must show only a delete action.")
	_simulate_double_click(profile.slots[0])
	await process_frame
	_expect(run_state.get_item_count(0) == 7, "Double-clicking a material must not consume it.")
	profile.item_detail_discard_button.emit_signal("pressed")
	await process_frame
	_expect(run_state.get_item(0) == null, "The material delete button must remove the whole selected stack.")
	profile.close()
	profile.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _simulate_double_click(slot: InventorySlot) -> void:
	for _click_index in 2:
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = Vector2(24.0, 24.0)
		slot._on_gui_input(press)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = press.position
		slot._on_gui_input(release)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		(node as AudioStreamPlayer).stop()
	elif node is AudioStreamPlayer2D:
		(node as AudioStreamPlayer2D).stop()
	for child in node.get_children():
		_stop_audio_players(child)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
