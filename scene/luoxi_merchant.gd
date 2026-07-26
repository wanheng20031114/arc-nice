extends Node2D
class_name LuoxiMerchant

const DIALOGUE_LINES := [
	"我是终末地的爪牙！",
	"我能为你提供收藏品来强化自己。",
]
const CHOICE_COUNT := 3
const OFFER_ALL_COMMON_WEIGHT := 50
const OFFER_ALL_RARE_WEIGHT := 30
const OFFER_ALL_EPIC_WEIGHT := 12
const OFFER_ONE_LEGENDARY_WEIGHT := 3
const OFFER_TWO_LEGENDARY_WEIGHT := 3
const OFFER_ALL_LEGENDARY_WEIGHT := 2
const COLLECTIBLE_OFFER_ROLL_TOTAL := (
	OFFER_ALL_COMMON_WEIGHT
	+ OFFER_ALL_RARE_WEIGHT
	+ OFFER_ALL_EPIC_WEIGHT
	+ OFFER_ONE_LEGENDARY_WEIGHT
	+ OFFER_TWO_LEGENDARY_WEIGHT
	+ OFFER_ALL_LEGENDARY_WEIGHT
)
const COLLECTIBLE_CLAIMS_PER_ROUND := 1
const REFRESH_COSTS := [100, 200, 500, 1000]
const CLAIMED_LINE := "这段场间时间已经选择过一件收藏品。"
const SUCCESS_LINE := "拿好收藏品，可别小看它。"
const ALREADY_CLAIMED_LINE := "这段场间时间已经选择过一件收藏品。"
const INVENTORY_FULL_LINE := "背包已经满了，无法再继续获得收藏品。"
const INVALID_PLAYER_LINE := "现在还不能把收藏品交给你。"
const PLAYER_COLLISION_MASK := 2
const BODY_PUSH_QUERY_MAX_RESULTS := 16
const BODY_PUSH_DISTANCE := 22.0
const AUTHORITATIVE_REQUEST_TIMEOUT_SECONDS := 3.0
const AUTHORITATIVE_OFFER_TIMEOUT_LINE := "主机响应超时，请再次交互重试。"
const AUTHORITATIVE_REFRESH_TIMEOUT_STATUS := "刷新请求超时，请重试"

enum AuthoritativeRequestKind {
	NONE,
	OFFER,
	REFRESH,
}

const COLLECTIBLE_RESULT_SUCCESS := 0
const COLLECTIBLE_RESULT_ALREADY_CLAIMED := 1
const COLLECTIBLE_RESULT_INVENTORY_FULL := 2
const COLLECTIBLE_RESULT_INVALID_PLAYER := 3
const COLLECTIBLE_RESULT_STALE_OFFER := 4

const REFRESH_RESULT_SUCCESS := 0
const REFRESH_RESULT_LIMIT_REACHED := 1
const REFRESH_RESULT_INSUFFICIENT_XIRANG := 2
const REFRESH_RESULT_INVALID_PLAYER := 3
const REFRESH_RESULT_STALE_OFFER := 4

@onready var collision_shape: CollisionShape2D = $StaticBody2D/CollisionShape2D
@onready var interaction_area: Area2D = $InteractionArea
@onready var authoritative_request_timeout: Timer = $AuthoritativeRequestTimeout
@onready var dialogue_bubble: MerchantDialogueBubble = $MerchantDialogueBubble
@onready var choice_overlay: LuoxiCollectibleChoiceOverlay = $LuoxiCollectibleChoiceOverlay
@onready var night_light: NightPointLight2D = $NightLight

var is_active: bool = false
var nearby_players: Dictionary = {}
var active_player: Player = null
var dialogue_index: int = 0
var selected_choice_index: int = 0
var choice_visible: bool = false
var result_visible: bool = false
var dialogue_lines: Array = []
var claim_counts_by_player_key: Dictionary = {}
var refresh_counts_by_player_key: Dictionary = {}
var pending_choices_by_player_key: Dictionary = {}
var authoritative_offer_revision: int = 0
var authoritative_offer_paths: Array[String] = []
var authoritative_offer_pending: bool = false
var _authoritative_request_kind := AuthoritativeRequestKind.NONE

static func get_choice_count() -> int:
	return CHOICE_COUNT


static func get_refresh_limit() -> int:
	return REFRESH_COSTS.size()


static func get_refresh_cost(refresh_count: int) -> int:
	if refresh_count < 0 or refresh_count >= REFRESH_COSTS.size():
		return 0
	return int(REFRESH_COSTS[refresh_count])


static func get_collectible_pool() -> Array:
	return CollectibleRegistry.get_all()


static func get_collectible_for_choice(choice_index: int) -> PickupConfig:
	var pool := get_collectible_pool()
	if choice_index < 0 or choice_index >= pool.size():
		return null
	return pool[choice_index] as PickupConfig


static func get_collectible_for_path(config_path: String) -> PickupConfig:
	return CollectibleRegistry.get_for_path(config_path)


static func is_collectible_cache_ready() -> bool:
	return CollectibleRegistry.is_cache_ready()


static func get_collectible_config_paths() -> Array[String]:
	return CollectibleRegistry.get_config_paths()


static func cache_collectible_config(item: PickupConfig) -> void:
	CollectibleRegistry.cache_config(item)


static func finish_collectible_cache_warmup() -> void:
	CollectibleRegistry.finish_cache_warmup()


static func _ensure_collectible_cache() -> void:
	CollectibleRegistry.ensure_cache()


static func is_collectible_pool_path(config_path: String) -> bool:
	return CollectibleRegistry.is_collectible_path(config_path)


static func get_collectible_effect_key(item: PickupConfig) -> String:
	if item == null:
		return ""
	if not item.collectible_effect_id.is_empty():
		return item.collectible_effect_id
	return item.resource_path


static func can_collectible_repeat_effect(item: PickupConfig) -> bool:
	return item != null and item.collectible_stacks_by_copy


static func is_collectible_available_for_inventory(
	item: PickupConfig,
	_run_state: RunStateStore,
	_peer_id: int = 0
) -> bool:
	# Offer availability is independent from both the effect cap and current bag space.
	# The authoritative claim path performs the physical-capacity write atomically.
	return item != null


static func get_collectible_offer_rarity_pattern_for_roll(
	roll: int,
	mixed_rarity_position: int = 0
) -> Array[int]:
	var normalized_roll := posmod(roll, COLLECTIBLE_OFFER_ROLL_TOTAL)
	var roll_end := OFFER_ALL_COMMON_WEIGHT
	if normalized_roll < roll_end:
		return _build_uniform_rarity_pattern(PickupConfig.CollectibleRarity.COMMON)

	roll_end += OFFER_ALL_RARE_WEIGHT
	if normalized_roll < roll_end:
		return _build_uniform_rarity_pattern(PickupConfig.CollectibleRarity.RARE)

	roll_end += OFFER_ALL_EPIC_WEIGHT
	if normalized_roll < roll_end:
		return _build_uniform_rarity_pattern(PickupConfig.CollectibleRarity.EPIC)

	var featured_position := posmod(mixed_rarity_position, CHOICE_COUNT)
	roll_end += OFFER_ONE_LEGENDARY_WEIGHT
	if normalized_roll < roll_end:
		var one_legendary := _build_uniform_rarity_pattern(
			PickupConfig.CollectibleRarity.EPIC
		)
		one_legendary[featured_position] = PickupConfig.CollectibleRarity.LEGENDARY
		return one_legendary

	roll_end += OFFER_TWO_LEGENDARY_WEIGHT
	if normalized_roll < roll_end:
		var two_legendary := _build_uniform_rarity_pattern(
			PickupConfig.CollectibleRarity.LEGENDARY
		)
		two_legendary[featured_position] = PickupConfig.CollectibleRarity.EPIC
		return two_legendary

	return _build_uniform_rarity_pattern(PickupConfig.CollectibleRarity.LEGENDARY)


static func roll_collectible_offer_rarity_pattern(
	rng: RandomNumberGenerator
) -> Array[int]:
	if rng == null:
		return []
	return get_collectible_offer_rarity_pattern_for_roll(
		rng.randi_range(0, COLLECTIBLE_OFFER_ROLL_TOTAL - 1),
		rng.randi_range(0, CHOICE_COUNT - 1)
	)


static func _build_uniform_rarity_pattern(rarity: int) -> Array[int]:
	var result: Array[int] = []
	for _choice_index in range(CHOICE_COUNT):
		result.append(rarity)
	return result


static func get_result_line(result_code: int) -> String:
	match result_code:
		COLLECTIBLE_RESULT_SUCCESS:
			return SUCCESS_LINE
		COLLECTIBLE_RESULT_ALREADY_CLAIMED:
			return ALREADY_CLAIMED_LINE
		COLLECTIBLE_RESULT_INVENTORY_FULL:
			return INVENTORY_FULL_LINE
		_:
			return INVALID_PLAYER_LINE


func _ready() -> void:
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	choice_overlay.choice_selected.connect(_on_choice_overlay_choice_selected)
	choice_overlay.choice_closed.connect(_on_choice_overlay_choice_closed)
	choice_overlay.refresh_requested.connect(_on_choice_overlay_refresh_requested)
	authoritative_request_timeout.timeout.connect(
		_on_authoritative_request_timeout
	)
	set_active(visible)


func set_active(active: bool) -> void:
	is_active = active
	night_light.set_emission_allowed(active)
	visible = active
	interaction_area.set_deferred("monitoring", active)

	if not active:
		_clear_authoritative_request_wait(true)
		collision_shape.set_deferred("disabled", true)
		nearby_players.clear()
		active_player = null
		choice_visible = false
		result_visible = false
		choice_overlay.hide_choices()
		dialogue_bubble.hide_bubble()
		return

	collision_shape.set_deferred("disabled", false)
	call_deferred("_push_overlapping_players_out")


func _unhandled_input(event: InputEvent) -> void:
	if not is_active or active_player == null:
		return

	if choice_visible:
		if _handle_choice_input(event):
			get_viewport().set_input_as_handled()
		return

	if not event.is_action_pressed("interact"):
		return

	get_viewport().set_input_as_handled()
	_advance_dialogue()


func _start_dialogue(player: Player) -> void:
	if not is_active or player == null:
		return
	_clear_authoritative_request_wait(true)
	active_player = player
	dialogue_index = 0
	selected_choice_index = 0
	choice_visible = false
	result_visible = false
	choice_overlay.hide_choices()
	dialogue_lines = _build_dialogue_lines(player)
	dialogue_bubble.say(dialogue_lines[dialogue_index])


func _advance_dialogue() -> void:
	if dialogue_bubble.is_revealing:
		dialogue_bubble.finish_line()
		return

	if result_visible:
		_reset_dialogue_after_result()
		return

	if not dialogue_bubble.visible:
		_start_dialogue(active_player)
		return

	if dialogue_index < dialogue_lines.size() - 1:
		dialogue_index += 1
		dialogue_bubble.say(dialogue_lines[dialogue_index])
		return

	if _is_player_claimed(active_player):
		dialogue_bubble.hide_bubble()
		return

	_show_choice_offer()


func show_collectible_result(result_code: int) -> void:
	choice_visible = false
	result_visible = true
	choice_overlay.hide_choices()
	if result_code == COLLECTIBLE_RESULT_SUCCESS and active_player != null:
		var player_key := _get_player_claim_key(active_player)
		pending_choices_by_player_key.erase(player_key)
	dialogue_bubble.say(get_result_line(result_code))


func try_purchase_refresh_for_player(player: Player) -> int:
	if not is_active or player == null or not is_instance_valid(player):
		return REFRESH_RESULT_INVALID_PLAYER
	var player_key := _get_player_claim_key(player)
	if _get_player_claim_count(player_key) >= COLLECTIBLE_CLAIMS_PER_ROUND:
		return REFRESH_RESULT_INVALID_PLAYER
	var refresh_count := get_player_refresh_count(player_key)
	if refresh_count >= get_refresh_limit():
		return REFRESH_RESULT_LIMIT_REACHED
	var cost := get_refresh_cost(refresh_count)
	if cost <= 0:
		return REFRESH_RESULT_LIMIT_REACHED
	if player.current_xirang < cost:
		return REFRESH_RESULT_INSUFFICIENT_XIRANG
	player.current_xirang -= cost
	player.xirang_changed.emit(player.current_xirang, -cost)
	refresh_counts_by_player_key[player_key] = refresh_count + 1
	return REFRESH_RESULT_SUCCESS


func get_player_refresh_count(player_key: int) -> int:
	return int(refresh_counts_by_player_key.get(maxi(player_key, 0), 0))


func show_refresh_result(
	result_code: int,
	confirmed_refresh_count: int = -1,
	confirmed_current_xirang: int = -1
) -> void:
	if active_player == null:
		return
	var player_key := _get_player_claim_key(active_player)
	if confirmed_refresh_count >= 0:
		refresh_counts_by_player_key[player_key] = mini(
			confirmed_refresh_count,
			get_refresh_limit()
		)
	if confirmed_current_xirang >= 0 and active_player.current_xirang != confirmed_current_xirang:
		var xirang_delta := confirmed_current_xirang - active_player.current_xirang
		active_player.current_xirang = confirmed_current_xirang
		active_player.xirang_changed.emit(active_player.current_xirang, xirang_delta)
	if result_code == REFRESH_RESULT_SUCCESS:
		_replace_current_choices_after_refresh(player_key)
		return
	var status := "现在无法刷新"
	match result_code:
		REFRESH_RESULT_LIMIT_REACHED:
			status = "刷新次数已用尽，下次休整期重置"
		REFRESH_RESULT_INSUFFICIENT_XIRANG:
			status = "息壤不足，无法支付本次刷新费用"
	_update_refresh_ui(status)


func begin_authoritative_offer_request() -> void:
	authoritative_offer_pending = true
	_arm_authoritative_request_timeout(AuthoritativeRequestKind.OFFER)
	choice_visible = true
	dialogue_bubble.hide_bubble()
	choice_overlay.hide_choices()


func apply_authoritative_offer_state(
	offer_revision: int,
	config_paths: PackedStringArray,
	confirmed_refresh_count: int,
	confirmed_current_xirang: int,
	refresh_result_code: int = -1
) -> bool:
	if active_player == null or offer_revision <= 0:
		return false
	if offer_revision < authoritative_offer_revision:
		return false

	var choices: Array = []
	var normalized_paths: Array[String] = []
	for config_path_value in config_paths:
		var config_path := String(config_path_value)
		var item := get_collectible_for_path(config_path)
		if item == null or normalized_paths.has(config_path):
			return false
		normalized_paths.append(config_path)
		choices.append(item)
	if choices.size() != CHOICE_COUNT:
		return false
	if (
		offer_revision == authoritative_offer_revision
		and not authoritative_offer_paths.is_empty()
		and normalized_paths != authoritative_offer_paths
	):
		return false

	_clear_authoritative_request_wait()
	authoritative_offer_revision = offer_revision
	authoritative_offer_paths = normalized_paths
	var player_key := _get_player_claim_key(active_player)
	pending_choices_by_player_key[player_key] = choices
	refresh_counts_by_player_key[player_key] = clampi(
		confirmed_refresh_count,
		0,
		get_refresh_limit()
	)
	if confirmed_current_xirang >= 0 and active_player.current_xirang != confirmed_current_xirang:
		var xirang_delta := confirmed_current_xirang - active_player.current_xirang
		active_player.current_xirang = maxi(confirmed_current_xirang, 0)
		active_player.xirang_changed.emit(active_player.current_xirang, xirang_delta)

	selected_choice_index = clampi(selected_choice_index, 0, CHOICE_COUNT - 1)
	choice_visible = true
	dialogue_bubble.hide_bubble()
	var status := _get_authoritative_refresh_status(refresh_result_code)
	_update_refresh_ui(status)
	choice_overlay.show_choices(choices, selected_choice_index)
	return true


func get_authoritative_offer_revision() -> int:
	return authoritative_offer_revision


func build_authoritative_offer_paths(
	player: Player,
	excluded_paths: Array[String],
	rng: RandomNumberGenerator
) -> Array[String]:
	if player == null or rng == null:
		return []
	var pool := _get_collectible_pool_for_player(player)
	if not excluded_paths.is_empty():
		var filtered_pool: Array = []
		for item_variant in pool:
			var item := item_variant as PickupConfig
			if item != null and not excluded_paths.has(item.resource_path):
				filtered_pool.append(item)
		if filtered_pool.size() >= CHOICE_COUNT:
			pool = filtered_pool
	if pool.size() < CHOICE_COUNT:
		return []

	var selected_items := _build_collectible_choices_from_pool(pool, rng)
	if selected_items.size() != CHOICE_COUNT:
		return []
	var result: Array[String] = []
	for item_variant in selected_items:
		var item := item_variant as PickupConfig
		if item == null or item.resource_path.is_empty():
			return []
		result.append(item.resource_path)
	return result


func _get_authoritative_refresh_status(result_code: int) -> String:
	match result_code:
		REFRESH_RESULT_SUCCESS:
			return "刷新成功 · 新的收藏品已经出现"
		REFRESH_RESULT_LIMIT_REACHED:
			return "刷新次数已用尽，下次休整期重置"
		REFRESH_RESULT_INSUFFICIENT_XIRANG:
			return "息壤不足，无法支付本次刷新费用"
		REFRESH_RESULT_STALE_OFFER:
			return "报价已更新，已同步主机上的最新三张卡"
		_:
			return ""


func _show_choice_offer() -> void:
	var current_scene := get_tree().current_scene
	if (
		current_scene != null
		and current_scene.has_method("uses_authoritative_luoxi_offers")
		and bool(current_scene.call("uses_authoritative_luoxi_offers"))
	):
		begin_authoritative_offer_request()
		if current_scene.has_method("request_luoxi_collectible_offer"):
			current_scene.call("request_luoxi_collectible_offer")
		return
	choice_visible = true
	dialogue_bubble.hide_bubble()
	_update_refresh_ui()
	choice_overlay.show_choices(_build_collectible_choices(), selected_choice_index)


func _handle_choice_input(event: InputEvent) -> bool:
	if authoritative_offer_pending:
		return true
	if choice_overlay.handle_input(event):
		selected_choice_index = choice_overlay.selected_index
		return true

	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return false
	match key_event.physical_keycode:
		KEY_1:
			if choice_overlay.is_confirmation_locked():
				return true
			selected_choice_index = 0
			_try_claim_selected_collectible()
			return true
		KEY_2:
			if choice_overlay.is_confirmation_locked():
				return true
			selected_choice_index = 1
			_try_claim_selected_collectible()
			return true
		KEY_3:
			if choice_overlay.is_confirmation_locked():
				return true
			selected_choice_index = 2
			_try_claim_selected_collectible()
			return true
	return false


func _select_choice(choice_index: int) -> void:
	selected_choice_index = wrapi(choice_index, 0, CHOICE_COUNT)
	choice_overlay.select_choice(selected_choice_index)


func _try_claim_selected_collectible() -> void:
	if active_player == null:
		return
	var selected_item := _get_current_choice_item(selected_choice_index)
	if selected_item == null:
		show_collectible_result(COLLECTIBLE_RESULT_INVALID_PLAYER)
		return
	var config_path := selected_item.resource_path
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_luoxi_collectible_choice"):
		if (
			current_scene.has_method("uses_authoritative_luoxi_offers")
			and bool(current_scene.call("uses_authoritative_luoxi_offers"))
		):
			current_scene.call(
				"request_luoxi_collectible_choice",
				selected_choice_index,
				"",
				authoritative_offer_revision
			)
		else:
			current_scene.call("request_luoxi_collectible_choice", selected_choice_index, config_path)
		return
	show_collectible_result(_claim_local_collectible(active_player, config_path))


func _claim_local_collectible(player: Player, config_path: String) -> int:
	if player == null:
		return COLLECTIBLE_RESULT_INVALID_PLAYER
	var player_key := _get_player_claim_key(player)
	if _get_player_claim_count(player_key) >= COLLECTIBLE_CLAIMS_PER_ROUND:
		return COLLECTIBLE_RESULT_ALREADY_CLAIMED
	var item := get_collectible_for_path(config_path)
	if item == null:
		return COLLECTIBLE_RESULT_INVALID_PLAYER
	if not player.is_collectible_compatible(item):
		return COLLECTIBLE_RESULT_INVALID_PLAYER

	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return COLLECTIBLE_RESULT_INVALID_PLAYER
	if not is_collectible_available_for_inventory(item, run_state, player.peer_id):
		return COLLECTIBLE_RESULT_INVALID_PLAYER
	var stored := (
		run_state.try_add_item_for_peer(player.peer_id, item)
		if player.peer_id > 0
		else run_state.try_add_item(item)
	)
	if not stored:
		return COLLECTIBLE_RESULT_INVENTORY_FULL
	_record_player_claim(player_key)
	pending_choices_by_player_key.erase(player_key)
	return COLLECTIBLE_RESULT_SUCCESS


func _build_dialogue_lines(player: Player) -> Array:
	if _is_player_claimed(player):
		return [CLAIMED_LINE]
	return DIALOGUE_LINES.duplicate()


func _build_collectible_choices() -> Array:
	var player_key := _get_player_claim_key(active_player)
	if pending_choices_by_player_key.has(player_key):
		var pending_choices := pending_choices_by_player_key[player_key] as Array
		if _are_collectible_choices_available_for_player(pending_choices, active_player):
			return pending_choices.duplicate()
		pending_choices_by_player_key.erase(player_key)

	var choices := _build_random_collectible_choices()
	pending_choices_by_player_key[player_key] = choices
	return choices.duplicate()


func _build_random_collectible_choices(excluded_paths: Array[String] = []) -> Array:
	var pool := _get_collectible_pool_for_player(active_player)
	if not excluded_paths.is_empty():
		var filtered_pool: Array = []
		for item_variant in pool:
			var item := item_variant as PickupConfig
			if item != null and not excluded_paths.has(item.resource_path):
				filtered_pool.append(item)
		if filtered_pool.size() >= mini(CHOICE_COUNT, pool.size()):
			pool = filtered_pool
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return _build_collectible_choices_from_pool(pool, rng)


func _replace_current_choices_after_refresh(player_key: int) -> void:
	var previous_paths: Array[String] = []
	if pending_choices_by_player_key.has(player_key):
		var previous_choices := pending_choices_by_player_key[player_key] as Array
		for item_variant in previous_choices:
			var previous_item := item_variant as PickupConfig
			if previous_item != null:
				previous_paths.append(previous_item.resource_path)
	var choices := _build_random_collectible_choices(previous_paths)
	pending_choices_by_player_key[player_key] = choices
	selected_choice_index = clampi(selected_choice_index, 0, maxi(choices.size() - 1, 0))
	_update_refresh_ui("刷新成功 · 新的收藏品已经出现")
	choice_overlay.show_choices(choices, selected_choice_index)


func _update_refresh_ui(status_override: String = "") -> void:
	if active_player == null:
		return
	var refresh_count := get_player_refresh_count(_get_player_claim_key(active_player))
	choice_overlay.set_refresh_state(
		refresh_count,
		get_refresh_limit(),
		get_refresh_cost(refresh_count),
		active_player.current_xirang,
		status_override
	)


func _request_collectible_refresh() -> void:
	if active_player == null or not choice_visible:
		return
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_luoxi_collectible_refresh"):
		choice_overlay.set_refresh_pending(true)
		if (
			current_scene.has_method("uses_authoritative_luoxi_offers")
			and bool(current_scene.call("uses_authoritative_luoxi_offers"))
		):
			_arm_authoritative_request_timeout(
				AuthoritativeRequestKind.REFRESH
			)
			current_scene.call(
				"request_luoxi_collectible_refresh",
				authoritative_offer_revision
			)
		else:
			current_scene.call("request_luoxi_collectible_refresh")
		return
	var result_code := try_purchase_refresh_for_player(active_player)
	show_refresh_result(
		result_code,
		get_player_refresh_count(_get_player_claim_key(active_player)),
		active_player.current_xirang
	)


func _build_collectible_choices_from_pool(
	pool: Array,
	rng: RandomNumberGenerator
) -> Array:
	if pool.size() < CHOICE_COUNT or rng == null:
		return []
	var rarity_pattern := roll_collectible_offer_rarity_pattern(rng)
	var result: Array = []
	for rarity in rarity_pattern:
		var pool_index := _pick_collectible_index_for_rarity(pool, rarity, rng)
		if pool_index < 0:
			return []
		result.append(pool[pool_index])
		pool.remove_at(pool_index)
	return result


func _pick_collectible_index_for_rarity(
	pool: Array,
	rarity: int,
	rng: RandomNumberGenerator
) -> int:
	var matching_indices: Array[int] = []
	for index in range(pool.size()):
		var item := pool[index] as PickupConfig
		if item != null and int(item.collectible_rarity) == rarity:
			matching_indices.append(index)
	if matching_indices.is_empty():
		return -1
	return matching_indices[rng.randi_range(0, matching_indices.size() - 1)]


func _get_collectible_pool_for_player(player: Player) -> Array:
	var pool := get_collectible_pool()
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if player == null or run_state == null:
		return pool

	var filtered_pool: Array = []
	for item_variant in pool:
		var item := item_variant as PickupConfig
		if (
			player.is_collectible_compatible(item)
			and is_collectible_available_for_inventory(item, run_state, player.peer_id)
		):
			filtered_pool.append(item)
	return filtered_pool


func _are_collectible_choices_available_for_player(choices: Array, player: Player) -> bool:
	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if player == null or run_state == null:
		return true
	for item_variant in choices:
		var item := item_variant as PickupConfig
		if (
			not player.is_collectible_compatible(item)
			or not is_collectible_available_for_inventory(item, run_state, player.peer_id)
		):
			return false
	return true


func _get_current_choice_item(choice_index: int) -> PickupConfig:
	if choice_index < 0 or choice_index >= CHOICE_COUNT:
		return null
	if authoritative_offer_revision > 0 and choice_index < authoritative_offer_paths.size():
		return get_collectible_for_path(authoritative_offer_paths[choice_index])
	var choices := _build_collectible_choices()
	if choice_index >= choices.size():
		return null
	return choices[choice_index] as PickupConfig


func _reset_dialogue_after_result() -> void:
	dialogue_bubble.hide_bubble()
	result_visible = false
	choice_visible = false
	choice_overlay.hide_choices()
	dialogue_index = 0
	dialogue_lines = _build_dialogue_lines(active_player)


func _is_player_claimed(player: Player) -> bool:
	if player == null:
		return false
	var player_key := _get_player_claim_key(player)
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("has_luoxi_collectible_claimed"):
		return bool(current_scene.call("has_luoxi_collectible_claimed", player_key))
	return _get_player_claim_count(player_key) >= COLLECTIBLE_CLAIMS_PER_ROUND


func _get_player_claim_count(player_key: int) -> int:
	return int(claim_counts_by_player_key.get(player_key, 0))


func _record_player_claim(player_key: int) -> void:
	claim_counts_by_player_key[player_key] = mini(
		_get_player_claim_count(player_key) + 1,
		COLLECTIBLE_CLAIMS_PER_ROUND
	)


func _get_player_claim_key(player: Player) -> int:
	if player == null or player.peer_id <= 0:
		return 0
	return player.peer_id


func _on_interaction_area_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	if not player.uses_local_input:
		return
	nearby_players[player.get_instance_id()] = player
	if active_player == null:
		_start_dialogue(player)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	nearby_players.erase(player.get_instance_id())
	if player != active_player:
		return

	_clear_authoritative_request_wait(true)
	active_player = _pick_nearby_player()
	if active_player == null:
		dialogue_bubble.hide_bubble()
		choice_visible = false
		result_visible = false
		choice_overlay.hide_choices()
	else:
		_start_dialogue(active_player)


func _push_overlapping_players_out() -> void:
	if not is_active:
		return
	var shape := collision_shape.shape
	if shape == null:
		return

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = collision_shape.global_transform
	query.collision_mask = PLAYER_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var results := get_world_2d().direct_space_state.intersect_shape(
		query,
		BODY_PUSH_QUERY_MAX_RESULTS
	)
	for result in results:
		var player := result.get("collider") as Player
		if player == null:
			continue
		var push_direction := collision_shape.global_position.direction_to(player.global_position)
		if push_direction == Vector2.ZERO:
			push_direction = Vector2.DOWN
		player.global_position = collision_shape.global_position + push_direction * BODY_PUSH_DISTANCE


func _pick_nearby_player() -> Player:
	for player in nearby_players.values():
		if is_instance_valid(player):
			return player as Player
	return null


func reset_intermission_state() -> void:
	_clear_authoritative_request_wait(true)
	claim_counts_by_player_key.clear()
	refresh_counts_by_player_key.clear()
	pending_choices_by_player_key.clear()
	authoritative_offer_revision = 0
	authoritative_offer_paths.clear()
	selected_choice_index = 0
	choice_visible = false
	result_visible = false
	dialogue_index = 0
	choice_overlay.hide_choices()
	dialogue_bubble.hide_bubble()
	dialogue_lines = _build_dialogue_lines(active_player)


func reset_round_collectible_claims() -> void:
	reset_intermission_state()


func _on_choice_overlay_choice_selected(choice_index: int) -> void:
	selected_choice_index = choice_index
	_try_claim_selected_collectible()


func _on_choice_overlay_choice_closed() -> void:
	choice_visible = false


func _on_choice_overlay_refresh_requested() -> void:
	_request_collectible_refresh()


func _arm_authoritative_request_timeout(kind: AuthoritativeRequestKind) -> void:
	_authoritative_request_kind = kind
	authoritative_request_timeout.start(
		AUTHORITATIVE_REQUEST_TIMEOUT_SECONDS
	)


func _clear_authoritative_request_wait(clear_refresh_pending: bool = false) -> void:
	authoritative_request_timeout.stop()
	_authoritative_request_kind = AuthoritativeRequestKind.NONE
	authoritative_offer_pending = false
	if clear_refresh_pending and choice_overlay.refresh_pending:
		choice_overlay.set_refresh_pending(false)


func _on_authoritative_request_timeout() -> void:
	authoritative_request_timeout.stop()
	var expired_kind := _authoritative_request_kind
	_authoritative_request_kind = AuthoritativeRequestKind.NONE
	if expired_kind == AuthoritativeRequestKind.OFFER:
		authoritative_offer_pending = false
		choice_visible = false
		choice_overlay.hide_choices()
		if active_player != null:
			dialogue_bubble.say(AUTHORITATIVE_OFFER_TIMEOUT_LINE)
	elif expired_kind == AuthoritativeRequestKind.REFRESH:
		_update_refresh_ui(AUTHORITATIVE_REFRESH_TIMEOUT_STATUS)
