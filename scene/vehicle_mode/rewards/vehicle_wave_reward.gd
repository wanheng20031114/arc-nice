extends Node
class_name VehicleWaveReward

signal reward_claimed(wave_number: int, item: PickupConfig)
signal inventory_requested
signal inventory_close_requested

const CHOICE_COUNT := 3
const CHOICE_INSTRUCTIONS := "从 3 件收藏品中免费选择 1 件 · 选择后继续突围"

@onready var choice_overlay: LuoxiCollectibleChoiceOverlay = $LuoxiChoiceOverlay
@onready var title_label: Label = $LuoxiChoiceOverlay/Root/Center/Content/Hint
@onready var hint_label: Label = $LuoxiChoiceOverlay/Root/Center/Content/SubHint
@onready var inventory_button: Button = $LuoxiChoiceOverlay/Root/Center/Content/InventoryButton

var _player: Player
var _run_state: RunStateStore
var _rng := RandomNumberGenerator.new()
var _choices: Array[PickupConfig] = []
var _wave_number := 0
var _last_claimed_wave := 0
var _open := false
var _claimed := false
var _inventory_open := false
var _owns_pause := false
var _previously_paused := false
var _pause_tree: SceneTree


func _ready() -> void:
	choice_overlay.choice_selected.connect(_on_choice_selected)
	inventory_button.pressed.connect(_on_inventory_pressed)
	choice_overlay.set_refresh_state(0, 0, 0, 0)
	set_process_input(false)


func setup(player: Player, run_state: RunStateStore) -> void:
	assert(player != null and run_state != null, "Vehicle rewards require a player and run state.")
	cancel()
	_player = player
	_run_state = run_state
	_last_claimed_wave = 0
	_rng.randomize()


func open_for_wave(wave_number: int) -> bool:
	if _open or wave_number <= _last_claimed_wave or wave_number < 1:
		return false
	if not is_instance_valid(_player) or _run_state == null:
		push_error("VehicleWaveReward.setup must be called before opening a reward.")
		return false
	_choices = _roll_choices()
	if _choices.size() != CHOICE_COUNT:
		push_error("Vehicle reward pool must provide three compatible collectibles per rarity.")
		_choices.clear()
		return false
	_wave_number = wave_number
	_claimed = false
	_inventory_open = false
	_open = true
	_pause_tree = get_tree()
	_previously_paused = _pause_tree.paused
	_owns_pause = true
	_pause_tree.paused = true
	choice_overlay.visible = true
	choice_overlay.set_refresh_state(0, 0, 0, 0)
	title_label.text = "第%d波完成 · 选择战利品" % wave_number
	hint_label.text = CHOICE_INSTRUCTIONS
	inventory_button.hide()
	choice_overlay.show_choices(_choices)
	set_process_input(true)
	return true


func is_open() -> bool:
	return _open


## The profile owns input while arranging inventory; the same offer remains pending.
func set_inventory_open(inventory_open: bool) -> void:
	_inventory_open = inventory_open
	if not _open:
		return
	choice_overlay.visible = not inventory_open
	if not inventory_open:
		hint_label.text = "整理完成后，选择一件收藏品领取 · 本次 3 件奖励保持不变"
		choice_overlay.select_choice(choice_overlay.selected_index)


func cancel() -> void:
	_open = false
	_claimed = false
	_inventory_open = false
	_wave_number = 0
	_choices.clear()
	set_process_input(false)
	if is_node_ready():
		choice_overlay.hide_choices()
		choice_overlay.choices.clear()
		choice_overlay.visible = true
		inventory_button.hide()
	_release_pause()


func _exit_tree() -> void:
	# Scene changes must not leave the next scene paused by this modal.
	_release_pause()
	_open = false
	_claimed = false
	_inventory_open = false
	_wave_number = 0
	_choices.clear()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	# Luoxi normally lets Escape close an offer. A wave reward stays pending
	# until its atomic inventory grant succeeds, so neither pause action escapes.
	if event.is_action(GameplayPauseController.PAUSE_ACTION) or event.is_action(&"quit"):
		if _inventory_open and event.is_action_pressed(&"quit") and not event.is_echo():
			inventory_close_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if _inventory_open:
		return
	if choice_overlay.handle_input(event):
		get_viewport().set_input_as_handled()


func _on_choice_selected(choice_index: int) -> void:
	if not _open or _claimed or _inventory_open:
		return
	if choice_index < 0 or choice_index >= _choices.size():
		return
	var item := _choices[choice_index]
	var completed_wave := _wave_number
	# inventory_changed emits synchronously: claim ownership before the write.
	_claimed = true
	if not _run_state.try_add_item(item):
		_claimed = false
		hint_label.text = "背包空间不足 · 整理背包后再领取，当前 3 件奖励会保留"
		inventory_button.show()
		inventory_button.grab_focus()
		return
	_last_claimed_wave = completed_wave
	cancel()
	reward_claimed.emit(completed_wave, item)


func _on_inventory_pressed() -> void:
	if _open and not _claimed and not _inventory_open:
		inventory_requested.emit()


func _release_pause() -> void:
	if not _owns_pause:
		return
	_owns_pause = false
	_pause_tree.paused = _previously_paused
	_pause_tree = null


func _roll_choices() -> Array[PickupConfig]:
	var pool: Array[PickupConfig] = []
	for item in CollectibleRegistry.get_standard_random_pool():
		if _player.is_collectible_compatible(item) and is_useful_for_vehicle(item):
			pool.append(item)
	var result: Array[PickupConfig] = []
	var rarity_pattern := LuoxiMerchant.roll_collectible_offer_rarity_pattern(_rng, CHOICE_COUNT)
	for rarity in rarity_pattern:
		var matching_indices: Array[int] = []
		for index in range(pool.size()):
			if int(pool[index].collectible_rarity) == rarity:
				matching_indices.append(index)
		if matching_indices.is_empty():
			return []
		var pool_index := matching_indices[_rng.randi_range(0, matching_indices.size() - 1)]
		result.append(pool[pool_index])
		pool.remove_at(pool_index)
	return result


## Vehicle speed is capped and dash is disabled. Only offer effects that can
## improve this run; mixed items remain eligible through their useful effects.
static func is_useful_for_vehicle(item: PickupConfig) -> bool:
	if item == null or item.pickup_type != PickupConfig.PickupType.COLLECTIBLE:
		return false
	if not item.can_store_in_inventory or not CollectibleRegistry.is_standard_random_collectible(item):
		return false
	return (
		item.collectible_attack_bonus > 0
		or item.collectible_max_health_bonus > 0
		or item.collectible_attack_speed_bonus > 0.0
		or item.collectible_physical_defense_bonus > 0
		or item.collectible_magic_defense_bonus > 0
		or item.collectible_physical_damage_bonus > 0
		or item.collectible_magic_damage_bonus > 0
		or item.collectible_skill_charge_bonus_per_second > 0.0
		or item.bullet_pierce_chance > 0.0
		or item.bullet_homing_chance > 0.0
		or item.ammo_free_shot_chance > 0.0
		or item.collectible_ammo_capacity_additive_bonus > 0
		or item.collectible_ammo_capacity_bonus_ratio > 0.0
		or item.collectible_reload_time_reduction > 0.0
		or item.skill_charge_preserve_chance > 0.0
		or item.damage_against_burning_multiplier > 1.0
		or item.damage_against_bleeding_multiplier > 1.0
		or item.incoming_ranged_front_damage_multiplier < 1.0
		or item.incoming_ranged_back_damage_multiplier < 1.0
		or item.incoming_ranged_dodge_chance > 0.0
		or item.attack_speed_bonus_per_xirang_step > 0.0
		or item.defense_bonus_per_xirang_step > 0
		or item.conditional_attack_bonus > 0
		or item.conditional_max_health_bonus > 0
		or item.conditional_physical_defense_bonus > 0
		or item.conditional_magic_defense_bonus > 0
		or item.conditional_physical_damage_bonus > 0
		or item.conditional_magic_damage_bonus > 0
		or item.conditional_skill_charge_bonus_per_second > 0.0
		or item.conditional_bullet_pierce_chance > 0.0
		or not item.periodic_effect_id.is_empty()
		or (not item.skill_effect_id.is_empty() and item.skill_effect_id != PickupConfig.SKILL_EFFECT_SWIFT)
		or not item.trigger_effect_id.is_empty()
		or not item.on_hit_effect_id.is_empty()
		or (not item.kill_effect_id.is_empty() and item.kill_effect_id != "haste")
	)
