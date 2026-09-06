extends CharacterBody2D
class_name PvpPlayer

const Rules := preload("res://scene/pvp/pvp_rules.gd")

var peer_id := 0
var team := "CT"
var display_name := "维什戴尔"
var health := Rules.PLAYER_HEALTH
var alive := true
var money := Rules.START_MONEY
var current_weapon := "deagle"
var loadout: Dictionary = {"deagle": Rules.new_weapon("deagle")}
var kills := 0
var deaths := 0
var aim_direction := Vector2.RIGHT
var move_input := Vector2.ZERO
var fire_held := false
var input_time := 0.0
var fire_cooldown := 0.0
var shot_sequence := 0
var last_shot_weapon := "deagle"
var reload_remaining := 0.0
var network_position := Vector2.ZERO
var is_local := false
var ammo: int:
	get:
		return int(loadout[current_weapon].ammo) if loadout.has(current_weapon) else 0
var reserve: int:
	get:
		return int(loadout[current_weapon].reserve) if loadout.has(current_weapon) else 0

@onready var body_sprite: AnimatedSprite2D = $BodySprite
@onready var body_hitbox: Area2D = $BodyHitbox
@onready var head_hitbox: Area2D = $HeadHitbox
@onready var weapon_view: Node2D = $WeaponPivot
@onready var team_ring: Polygon2D = $TeamRing
@onready var name_label: Label = $NameLabel
@onready var camera: Camera2D = $Camera2D

func _ready() -> void:
	name_label.text = display_name
	team_ring.color = Color("59b8ed") if team == "CT" else Color("eeb965")
	camera.enabled = is_local
	if is_local:
		camera.make_current()
	_update_presentation()

func reset_round(spawn_position: Vector2) -> void:
	# Survivors keep their weapons; dead players receive their sidearm again.
	if not alive:
		loadout = {"deagle": Rules.new_weapon("deagle")}
	if not loadout.has("deagle"):
		loadout["deagle"] = Rules.new_weapon("deagle")
	for weapon: String in loadout:
		loadout[weapon] = Rules.new_weapon(weapon)
	current_weapon = "ak" if loadout.has("ak") else "deagle"
	health = Rules.PLAYER_HEALTH
	alive = true
	global_position = spawn_position
	network_position = spawn_position
	velocity = Vector2.ZERO
	move_input = Vector2.ZERO
	fire_held = false
	fire_cooldown = 0.0
	reload_remaining = 0.0
	_set_hitboxes_active(true)
	_update_presentation()

func authority_tick(delta: float, movement_allowed: bool) -> void:
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	if reload_remaining > 0.0:
		reload_remaining = maxf(0.0, reload_remaining - delta)
		if reload_remaining == 0.0 and loadout.has(current_weapon):
			var needed := int(Rules.WEAPONS[current_weapon].magazine) - ammo
			var amount := mini(needed, reserve)
			loadout[current_weapon].ammo = ammo + amount
			loadout[current_weapon].reserve = reserve - amount
	velocity = move_input.limit_length() * Rules.MOVE_SPEED if alive and movement_allowed else Vector2.ZERO
	move_and_slide()
	_update_presentation()

func client_tick(delta: float, movement_allowed: bool) -> void:
	if is_local and alive and movement_allowed:
		velocity = move_input.limit_length() * Rules.MOVE_SPEED
		move_and_slide()
		# Keep local movement responsive without allowing it to become authoritative.
		var error := network_position - global_position
		if error.length() > 42.0:
			global_position = network_position
		elif error.length() > 5.0:
			global_position += error * minf(delta * 7.0, 1.0)
	else:
		global_position = global_position.lerp(network_position, minf(delta * 18.0, 1.0))
	_update_presentation()

func start_reload() -> bool:
	if not alive or not loadout.has(current_weapon) or reload_remaining > 0.0:
		return false
	if reserve <= 0 or ammo >= int(Rules.WEAPONS[current_weapon].magazine):
		return false
	reload_remaining = float(Rules.WEAPONS[current_weapon].reload_seconds)
	return true

func equip(weapon: String) -> bool:
	if not alive or not loadout.has(weapon):
		return false
	current_weapon = weapon
	reload_remaining = 0.0
	fire_cooldown = maxf(fire_cooldown, 0.15)
	return true

func take_damage(amount: int) -> bool:
	if not alive:
		return false
	health = maxi(0, health - amount)
	if health > 0:
		$HitFlashTimer.start()
		body_sprite.modulate = Color(2.0, 0.7, 0.6)
		return false
	alive = false
	deaths += 1
	velocity = Vector2.ZERO
	fire_held = false
	reload_remaining = 0.0
	_set_hitboxes_active(false)
	_update_presentation()
	return true

func get_loadout() -> Dictionary:
	return loadout.duplicate(true)

func get_weapon_display_name() -> String:
	return str(Rules.WEAPONS[current_weapon].name) if Rules.WEAPONS.has(current_weapon) else "空手"

func serialize() -> Dictionary:
	return {"peer_id": peer_id, "team": team, "display_name": display_name,
		"position": global_position, "velocity": velocity, "aim": aim_direction,
		"health": health, "alive": alive, "money": money, "current_weapon": current_weapon,
		"ammo": ammo, "reserve": reserve, "reloading": reload_remaining > 0.0,
		"reload_remaining": reload_remaining, "kills": kills, "deaths": deaths,
		"shot_sequence": shot_sequence, "last_shot_weapon": last_shot_weapon,
		"loadout": get_loadout()}

func apply_snapshot(state: Dictionary, first_snapshot: bool = false) -> void:
	network_position = state.position
	if first_snapshot or not bool(state.alive) or global_position.distance_to(network_position) > 100.0:
		global_position = network_position
	velocity = state.velocity
	if not is_local:
		aim_direction = state.aim
	if int(state.health) < health and int(state.health) > 0:
		$HitFlashTimer.start()
		body_sprite.modulate = Color(2.0, 0.7, 0.6)
	health = int(state.health)
	var alive_changed := alive != bool(state.alive)
	alive = bool(state.alive)
	money = int(state.money)
	current_weapon = str(state.current_weapon)
	loadout = state.loadout.duplicate(true)
	reload_remaining = float(state.reload_remaining)
	kills = int(state.kills)
	deaths = int(state.deaths)
	shot_sequence = int(state.shot_sequence)
	last_shot_weapon = str(state.last_shot_weapon)
	if alive_changed:
		_set_hitboxes_active(alive)
	_update_presentation()

func _set_hitboxes_active(active: bool) -> void:
	body_hitbox.set_deferred("collision_layer", 4 if active else 0)
	head_hitbox.set_deferred("collision_layer", 8 if active else 0)
	$MovementShape.set_deferred("disabled", not active)

func _update_presentation() -> void:
	if not is_node_ready():
		return
	weapon_view.visible = alive and current_weapon != "empty"
	$WeaponPivot/Deagle.visible = current_weapon == "deagle"
	$WeaponPivot/AK.visible = current_weapon == "ak"
	$WeaponPivot/Deagle.flip_v = aim_direction.x < 0.0
	$WeaponPivot/AK.flip_v = aim_direction.x < 0.0
	weapon_view.rotation = aim_direction.angle()
	team_ring.visible = alive
	name_label.modulate.a = 1.0 if alive else 0.35
	if not alive:
		if body_sprite.animation != &"death":
			body_sprite.play(&"death")
		return
	var direction := "right"
	if absf(aim_direction.y) > absf(aim_direction.x):
		direction = "down" if aim_direction.y >= 0.0 else "up"
	else:
		direction = "right" if aim_direction.x >= 0.0 else "left"
	var animation := StringName("normal_" + direction)
	if velocity.length_squared() > 1.0:
		body_sprite.play(animation)
	else:
		body_sprite.animation = animation
		body_sprite.pause()
		body_sprite.frame = 0

func _on_hit_flash_timer_timeout() -> void:
	body_sprite.modulate = Color.WHITE

func play_fire_effect(weapon: String) -> void:
	$WeaponPivot/MuzzleFlash.position.x = 25.0 if weapon == "ak" else 15.0
	$WeaponPivot/MuzzleFlash.show()
	$MuzzleFlashTimer.start()

func _on_muzzle_flash_timer_timeout() -> void:
	$WeaponPivot/MuzzleFlash.hide()
