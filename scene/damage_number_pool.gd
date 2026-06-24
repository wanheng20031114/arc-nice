extends Node2D
class_name DamageNumberPool

const DAMAGE_NUMBER_SCRIPT := preload("res://scene/damage_number.gd")

@export_range(1, 256, 1, "or_greater") var pool_size: int = 96
@export_range(1, 120, 1, "or_greater") var max_numbers_per_second: int = 60
@export_range(1, 32, 1, "or_greater") var max_numbers_per_frame: int = 8

var pooled_numbers: Array[DamageNumber] = []
var budget_frame: int = -1
var shown_this_frame: int = 0
var budget_second_started_msec: int = 0
var shown_this_second: int = 0


func _ready() -> void:
	_prewarm_pool()


func show_damage_number(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
) -> bool:
	if amount <= 0:
		return false
	if not _consume_display_budget():
		return false

	var number := _get_available_number()
	if number == null:
		return false

	number.setup(amount, spawn_position, impact_direction, damage_type)
	return true


func _prewarm_pool() -> void:
	if not pooled_numbers.is_empty():
		return
	for _index in range(maxi(pool_size, 1)):
		var number := DAMAGE_NUMBER_SCRIPT.new() as DamageNumber
		if number == null:
			continue
		add_child(number)
		pooled_numbers.append(number)


func _consume_display_budget() -> bool:
	var current_frame := Engine.get_physics_frames()
	if current_frame != budget_frame:
		budget_frame = current_frame
		shown_this_frame = 0
	if shown_this_frame >= maxi(max_numbers_per_frame, 1):
		return false

	var now := Time.get_ticks_msec()
	if now - budget_second_started_msec >= 1000:
		budget_second_started_msec = now
		shown_this_second = 0
	if shown_this_second >= maxi(max_numbers_per_second, 1):
		return false

	shown_this_frame += 1
	shown_this_second += 1
	return true


func _get_available_number() -> DamageNumber:
	for number in pooled_numbers:
		if number != null and not number.is_active():
			return number

	var oldest_number: DamageNumber = null
	var oldest_elapsed := -INF
	for number in pooled_numbers:
		if number == null:
			continue
		if number.get_active_elapsed() > oldest_elapsed:
			oldest_elapsed = number.get_active_elapsed()
			oldest_number = number
	return oldest_number
