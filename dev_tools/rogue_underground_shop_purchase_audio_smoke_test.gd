extends SceneTree

const CONTROLLER_SCENE := preload(
	"res://scene/game_modes/rogue/shop/rogue_underground_shop_controller.tscn"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var controller := CONTROLLER_SCENE.instantiate() as RogueUndergroundShopController
	_expect(controller != null, "地下商店控制器必须能够实例化。")
	if controller == null:
		_finish()
		return
	root.add_child(controller)
	await process_frame
	# 该测试只审计交易反馈；锁住真实遮罩转场，避免计时器跨越测试退出。
	controller.set("_transition_active", true)

	var view := controller.view
	var purchase_audio := view.get_node_or_null("PurchaseSuccessAudio") as AudioStreamPlayer
	_expect(purchase_audio != null, "商店场景必须 authored PurchaseSuccessAudio。")
	if purchase_audio != null:
		_expect(
			purchase_audio.stream != null
			and purchase_audio.stream.resource_path.ends_with(
				"resources/audio/ui/rogue_shop_purchase_success.wav"
			),
			"购买成功播放器必须使用地下商店专属原创音效。"
		)
		_expect(
			purchase_audio.bus == &"SFX"
			and is_equal_approx(purchase_audio.volume_db, -7.0)
			and purchase_audio.max_polyphony == 1,
			"购买成功音效必须走 SFX、保持 -7 dB 且单实例播放。"
		)

	var purchased_snapshot := _make_snapshot(true, "purchased", 1)
	controller.call(&"_sync_local_presentation", purchased_snapshot)
	await process_frame
	if purchase_audio != null:
		_expect(purchase_audio.playing, "Host 确认购买成功后必须播放成功音效。")
		purchase_audio.stop()

	controller.call(&"_sync_local_presentation", purchased_snapshot)
	await process_frame
	if purchase_audio != null:
		_expect(
			not purchase_audio.playing,
			"重复收到同一成功快照不得重复播放购买音效。"
		)

	var next_purchase := _make_snapshot(true, "purchased", 2)
	controller.call(&"_sync_local_presentation", next_purchase)
	await process_frame
	if purchase_audio != null:
		_expect(purchase_audio.playing, "新的成功购买必须再次播放音效。")
		purchase_audio.stop()

	controller.call(
		&"_sync_local_presentation",
		_make_snapshot(false, "inventory_full", 3)
	)
	await process_frame
	if purchase_audio != null:
		_expect(not purchase_audio.playing, "购买失败不得播放成功音效。")

	controller.call(
		&"_sync_local_presentation",
		_make_snapshot(true, "sold", 4)
	)
	await process_frame
	if purchase_audio != null:
		_expect(not purchase_audio.playing, "成功出售不得误播购买成功音效。")

	controller.queue_free()
	await process_frame
	call_deferred(&"_finish")


func _make_snapshot(success: bool, result_code: String, revision: int) -> Dictionary:
	return {
		"occurrence_key": "shop:audio-smoke",
		"phase": RogueUndergroundShopSession.Phase.SHOPPING,
		"offers": [],
		"sell_slots": [],
		"target_exited": false,
		"transaction_result": {
			"success": success,
			"result_code": result_code,
			"offer_index": 0,
			"session_revision": revision,
			"shelf_revision": revision,
			"inventory_revision": revision,
			"xirang_revision": revision,
		},
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_UNDERGROUND_SHOP_PURCHASE_AUDIO_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
