extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const TOWER_GAME_SCENE := preload(
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
)
const SHARED_MERCHANT_SCRIPT_PATH := (
	"res://scene/merchants/luoxi/luoxi_merchant.gd"
)
const SHARED_MERCHANT_SCENE_PATH := (
	"res://scene/merchants/luoxi/luoxi_merchant.tscn"
)
const TOWER_MERCHANT_SCENE_PATH := (
	"res://scene/game_modes/tower_defense/merchants/luoxi/tower_defense_luoxi_merchant.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_source_boundaries()
	_test_runtime_composition()
	if failures.is_empty():
		print("MODE_MERCHANT_BOUNDARY_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_source_boundaries() -> void:
	var shared_source := FileAccess.get_file_as_string(SHARED_MERCHANT_SCRIPT_PATH)
	var shared_scene := FileAccess.get_file_as_string(SHARED_MERCHANT_SCENE_PATH)
	var standard_scene := FileAccess.get_file_as_string(
		"res://scene/game_modes/standard/standard_game.tscn"
	)
	var tower_scene := FileAccess.get_file_as_string(
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn"
	)
	_expect(
		not shared_source.contains("LuoxiSpecialGame")
		and not shared_source.contains("material_gambler_ticket")
		and not shared_scene.contains("luoxi_special_game"),
		"Shared Luoxi merchant must not load tower-only card-game code or assets."
	)
	_expect(
		standard_scene.contains(SHARED_MERCHANT_SCENE_PATH)
		and not standard_scene.contains("tower_defense/merchants/luoxi"),
		"StandardGame must compose only the shared collectible merchant."
	)
	_expect(
		tower_scene.contains(TOWER_MERCHANT_SCENE_PATH),
		"TowerDefenseGame must compose its explicit card-game merchant wrapper."
	)


func _test_runtime_composition() -> void:
	var standard := STANDARD_GAME_SCENE.instantiate() as StandardGame
	var tower := TOWER_GAME_SCENE.instantiate() as TowerDefenseGame
	_expect(standard != null, "StandardGame must instantiate for merchant boundary test.")
	_expect(tower != null, "TowerDefenseGame must instantiate for merchant boundary test.")
	if standard != null:
		var standard_merchant := standard.get_node_or_null("LuoxiMerchant")
		_expect(
			standard_merchant is LuoxiMerchant
			and not (standard_merchant is TowerDefenseLuoxiMerchant)
			and standard_merchant.get_node_or_null("LuoxiSpecialGameOverlay") == null,
			"StandardGame merchant must contain no tower card-game overlay."
		)
		standard.free()
	if tower != null:
		var tower_merchant := tower.get_node_or_null("LuoxiMerchant")
		_expect(
			tower_merchant is TowerDefenseLuoxiMerchant
			and tower_merchant.get_node_or_null("LuoxiSpecialGameOverlay")
			is LuoxiSpecialGameOverlay,
			"TowerDefenseGame merchant must own the card-game presentation."
		)
		tower.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
