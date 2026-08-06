extends SceneTree

var failures := PackedStringArray()


func _init() -> void:
	_expect(
		[
			MerchantPurchaseResult.SkillUpgrade.SUCCESS,
			MerchantPurchaseResult.SkillUpgrade.ALREADY_OWNED,
			MerchantPurchaseResult.SkillUpgrade.INSUFFICIENT_XIRANG,
			MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER,
			MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS,
			MerchantPurchaseResult.SkillUpgrade.UPGRADE_MAXED,
		] == [0, 1, 2, 3, 4, 5],
		"Merchant skill result codes changed."
	)
	_expect(
		[
			MerchantPurchaseResult.CollectibleClaim.SUCCESS,
			MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED,
			MerchantPurchaseResult.CollectibleClaim.INVENTORY_FULL,
			MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER,
			MerchantPurchaseResult.CollectibleClaim.STALE_OFFER,
		] == [0, 1, 2, 3, 4],
		"Luoxi collectible result codes changed."
	)
	_expect(
		[
			MerchantPurchaseResult.OfferRefresh.SUCCESS,
			MerchantPurchaseResult.OfferRefresh.LIMIT_REACHED,
			MerchantPurchaseResult.OfferRefresh.INSUFFICIENT_XIRANG,
			MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER,
			MerchantPurchaseResult.OfferRefresh.STALE_OFFER,
		] == [0, 1, 2, 3, 4],
		"Luoxi refresh result codes changed."
	)
	if failures.is_empty():
		print("MERCHANT_PURCHASE_RESULT_CONTRACT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
