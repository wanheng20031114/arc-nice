extends SceneTree

const Rules := preload("res://scene/pvp/pvp_rules.gd")
const Arena := preload("res://scene/pvp/tests/pvp_test_arena.tscn")
var failures: Array[String] = []
var checks := 0
var game: MiragePvp

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("PVP TEST: " + message)

func _run() -> void:
	game = Arena.instantiate() as MiragePvp
	root.add_child(game)
	game.set_physics_process(false)
	await physics_frame
	await physics_frame
	var ct: PvpPlayer = game.players[1]
	var terrorist: PvpPlayer = game.players[2]
	_check(game.is_runtime_preparation_complete() and game.get_runtime_preparation_generation() > 0, "Typed loading preparation reaches READY")
	_check(Rules.BULLET_SPEED == 500.0, "Bullet speed must be exactly 500")
	_check(Rules.damage("deagle", false) == 25 and Rules.damage("deagle", true) == 100, "Deagle damage contract")
	_check(Rules.damage("ak", false) == 20 and Rules.damage("ak", true) == 100, "AK damage contract")
	_check(ct.health == 100 and ct.current_weapon == "deagle" and ct.ammo == 7, "Spawn health and sidearm")
	_check(ct.body_sprite.sprite_frames.resource_path.ends_with("player_weishidaier.tres"), "Fixed weishidaier appearance")
	_check(ct.body_hitbox.collision_layer == 4 and ct.head_hitbox.collision_layer == 8, "Separate native hit areas")
	_check(not game._try_fire(ct) and ct.ammo == 7, "Freeze blocks shooting without consuming ammo")
	_check(game._perform_action(ct, "buy_ak"), "AK buy succeeds in own freeze zone")
	_check(ct.money == 1300 and ct.current_weapon == "ak" and ct.ammo == 30, "AK purchase accounting and equipment")
	_check(not game._perform_action(ct, "buy_ak") and ct.money == 1300, "Duplicate purchase rejected")
	ct.loadout.erase("ak")
	ct.current_weapon = "deagle"
	ct.money = 4000
	ct.global_position = game.map.get_spawn_position("T", 0)
	_check(not game._perform_action(ct, "buy_ak") and ct.money == 4000, "Enemy buy zone rejected")
	ct.global_position = game.map.get_spawn_position("CT", 0)
	game.phase = "live"
	_check(not game._perform_action(ct, "buy_ak"), "Buying after freeze rejected")
	game.phase = "buy"
	ct.money = 100
	_check(not game._perform_action(ct, "buy_ak"), "Insufficient money rejected")
	ct.money = 4000
	game._perform_action(ct, "buy_ak")
	ct.loadout.ak.ammo = 11
	ct.loadout.ak.reserve = 42
	ct.aim_direction = Vector2.RIGHT
	_check(game._perform_action(ct, "drop") and not ct.loadout.has("ak") and ct.current_weapon == "deagle", "G drops held weapon and selects sidearm")
	_check(game.pickups.size() == 1 and game.pickups.values()[0].ammunition.ammo == 11, "Dropped magazine preserved")
	_check(game._perform_action(ct, "pickup") and ct.ammo == 11 and ct.reserve == 42, "F restores dropped gun ammunition")
	_check(game.pickups.is_empty(), "Pickup consumed exactly once")
	ct.loadout.ak.ammo = 0
	ct.loadout.ak.reserve = 10
	_check(ct.start_reload(), "Reload starts")
	ct.authority_tick(3.0, false)
	_check(ct.ammo == 10 and ct.reserve == 0 and ct.reload_remaining == 0.0, "Reload conserves ammunition")
	ct.loadout.ak.ammo = 1
	ct.loadout.ak.reserve = 15
	ct.start_reload()
	ct.equip("deagle")
	ct.authority_tick(3.0, false)
	_check(ct.loadout.ak.ammo == 1 and ct.reload_remaining == 0.0, "Switch cancels pending reload")
	game._accept_input(1, 10, Vector2(999, 0), Vector2(1, 0), false)
	game._accept_input(1, 9, Vector2.LEFT, Vector2.LEFT, true)
	game._consume_requests()
	_check(ct.move_input == Vector2.RIGHT and not ct.fire_held, "Host normalizes movement and rejects stale input")
	game._accept_input(1, 11, Vector2(NAN, 0), Vector2.RIGHT, false)
	_check(game._input_queue.is_empty(), "Non-finite input rejected")
	game._accept_action(1, 1, "give_money")
	_check(game._action_queue.is_empty(), "Unsupported client action rejected")
	ct.global_position = Vector2(405, 180)
	ct.move_input = Vector2.RIGHT
	for frame in range(20):
		ct.authority_tick(1.0 / 60.0, true)
		await physics_frame
	_check(ct.global_position.x < 413.1, "CharacterBody2D movement cannot cross walls")
	ct.move_input = Vector2.ZERO
	game.phase = "live"
	ct.equip("deagle")
	ct.fire_cooldown = 0
	ct.global_position = Vector2(300, 180)
	terrorist.global_position = Vector2(500, 179)
	ct.aim_direction = Vector2.RIGHT
	await physics_frame
	game._try_fire(ct)
	for frame in range(40):
		game._step_projectiles(1.0 / 60.0)
		await physics_frame
	_check(terrorist.health == 100 and game.projectiles.is_empty(), "Wall blocks complete swept bullet path")
	ct.global_position = Vector2(300, 401)
	terrorist.global_position = Vector2(380, 397)
	ct.fire_cooldown = 0
	await physics_frame
	game._try_fire(ct)
	for frame in range(12):
		game._step_projectiles(1.0 / 60.0)
		await physics_frame
	_check(terrorist.health == 75, "Physical body ray applies 25 Deagle damage")
	ct.global_position = Vector2(300, 401)
	terrorist.global_position = Vector2(380, 408)
	ct.fire_cooldown = 0
	await physics_frame
	game._try_fire(ct)
	for frame in range(12):
		game._step_projectiles(1.0 / 60.0)
		await physics_frame
	_check(not terrorist.alive and terrorist.health == 0, "Physical head area causes lethal 100 damage")
	_check(ct.kills == 1 and terrorist.deaths == 1, "Kill attribution and scoreboard")
	_check(game.phase == "round_end" and game.scores.CT == 1, "Elimination awards round")
	_check(game.pickups.size() == 1, "Death drops carried sidearm")
	game._advance_phase()
	_check(game.phase == "buy" and game.round_number == 2 and terrorist.alive, "Round restart respawns both teams")
	_check(game.pickups.is_empty() and terrorist.current_weapon == "deagle", "Round reset clears drops and restores dead sidearm")
	game.phase = "live"
	ct.global_position = Vector2(100, 401)
	terrorist.global_position = Vector2(260, 397)
	ct.loadout.ak = Rules.new_weapon("ak")
	ct.current_weapon = "ak"
	ct.fire_cooldown = 0.0
	ct.aim_direction = Vector2.RIGHT
	var ally := game._create_player(3, "CT", "同队测试")
	ally.global_position = Vector2(180, 397)
	await physics_frame
	game._try_fire(ct)
	_check(not game._try_fire(ct) and ct.ammo == 29, "Fire rate and ammunition enforced by host")
	game._step_projectiles(0.40)
	_check(ally.health == 100 and terrorist.health == 80, "500-speed long sweep hits enemy body for 20 and passes friendly player")
	terrorist.global_position = Vector2(260, 408)
	ct.fire_cooldown = 0.0
	await physics_frame
	game._try_fire(ct)
	game._step_projectiles(0.40)
	_check(not terrorist.alive and terrorist.health == 0, "AK physical headshot applies lethal 100 damage")
	_check(ally.health == 100, "Friendly fire never damages allied hit areas")
	game.players.erase(3)
	ally.queue_free()
	game.phase = "live"
	game.scores.CT = 6
	game._advance_phase()
	_check(game.phase == "match_end" and game.scores.CT == 7, "90-second CT timeout and first-to-seven match victory")
	var snapshot := game._make_snapshot()
	_check(snapshot.players.size() == 2 and snapshot.phase == "match_end", "Complete authoritative state serialization")
	var stress_bullets: Array[Dictionary] = []
	for index: int in range(192):
		stress_bullets.append({"id": index, "shooter": index % 8 + 1, "team": "CT" if index % 2 == 0 else "T",
			"weapon": "ak", "position": Vector2(index * 7.23, index * 5.71), "direction": Vector2.from_angle(index * 0.12)})
	snapshot.projectiles = stress_bullets
	var payload := var_to_bytes(snapshot).compress(FileAccess.COMPRESSION_DEFLATE)
	var chunks := ceili(float(payload.size()) / game.SNAPSHOT_CHUNK_BYTES)
	_check(chunks > 1 and chunks <= game.MAX_SNAPSHOT_CHUNKS, "Eight-user 192-bullet snapshot uses bounded MTU fragments")
	var reconstructed: Dictionary = {}
	for index: int in range(chunks - 1, -1, -1):
		var part := payload.slice(index * game.SNAPSHOT_CHUNK_BYTES, (index + 1) * game.SNAPSHOT_CHUNK_BYTES)
		reconstructed = game._receive_snapshot_chunk(100, index, chunks, part)
	_check(reconstructed.get("projectiles", []).size() == 192 and reconstructed.get("phase", "") == "match_end", "Compressed fragments reconstruct complete state out of order")
	_check(game._receive_snapshot_chunk(99, 0, chunks, payload.slice(0, 1024)).is_empty(), "Stale snapshot fragment rejected")
	_check(game._receive_snapshot_chunk(101, 0, 999, payload.slice(0, 1024)).is_empty(), "Unbounded fragment count rejected")
	game.phase = "live"
	ct.global_position = Vector2(408, 180)
	ct.aim_direction = Vector2.RIGHT
	ct.current_weapon = "deagle"
	ct.loadout.deagle.ammo = 7
	ct.fire_cooldown = 0.0
	var client_view := Arena.instantiate() as MiragePvp
	root.add_child(client_view)
	client_view.set_physics_process(false)
	client_view._host = false
	client_view._started = false
	var presented_shots: Array[Dictionary] = []
	client_view.shot_presented.connect(func(id: int, weapon: String): presented_shots.append({"id": id, "weapon": weapon}))
	client_view._apply_snapshot(game._make_snapshot())
	_check(presented_shots.is_empty(), "Initial snapshot does not replay historical gunshots")
	await physics_frame
	var previous_shot := ct.shot_sequence
	_check(game._try_fire(ct) and game.projectiles.is_empty(), "Near-wall shot is accepted even though muzzle collision creates no bullet")
	_check(ct.shot_sequence == previous_shot + 1 and ct.loadout.deagle.ammo == 6, "Accepted wall shot advances authoritative sequence once")
	ct.equip("ak")
	var wall_shot_snapshot := game._make_snapshot()
	client_view._apply_snapshot(wall_shot_snapshot)
	_check(presented_shots.size() == 1 and presented_shots[0].weapon == "deagle", "Client presents vanished wall shot using last fired weapon after weapon switch")
	client_view._apply_snapshot(wall_shot_snapshot)
	_check(presented_shots.size() == 1, "Repeated shot sequence never duplicates presentation")
	client_view._sync_projectiles([{"id": 999, "shooter": 1, "team": "CT", "weapon": "ak", "position": Vector2(150, 400), "direction": Vector2.RIGHT}])
	_check(presented_shots.size() == 1, "Projectile creation no longer produces duplicate gunshot sounds")
	var dying_player: PvpPlayer = client_view.players[1]
	dying_player.play_fire_effect("deagle")
	var death_snapshot := dying_player.serialize()
	death_snapshot.health = 0
	death_snapshot.alive = false
	dying_player.apply_snapshot(death_snapshot, true)
	_check(not dying_player.weapon_view.visible and not dying_player.get_node("MuzzleFlashTimer").is_stopped(), "First death snapshot safely hides an active muzzle flash")
	await create_timer(0.08).timeout
	_check(not dying_player.get_node("WeaponPivot/MuzzleFlash").visible, "Muzzle timer completes safely after death")
	client_view.queue_free()
	game.queue_free()
	await process_frame
	if failures.is_empty():
		print("PVP_TESTS_PASSED: %d checks" % checks)
	else:
		print("PVP_TESTS_FAILED: %d/%d: %s" % [failures.size(), checks, str(failures)])
	quit(0 if failures.is_empty() else 1)
