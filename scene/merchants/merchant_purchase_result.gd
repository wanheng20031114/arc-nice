extends RefCounted
class_name MerchantPurchaseResult

## Stable local and wire result codes shared by mode-owned merchant flows.
## Keep every numeric assignment explicit: these values are serialized by the
## multiplayer transaction façade and must not change when enums are reordered.

enum SkillUpgrade {
	SUCCESS = 0,
	ALREADY_OWNED = 1,
	INSUFFICIENT_XIRANG = 2,
	INVALID_PLAYER = 3,
	UPGRADE_SUCCESS = 4,
	UPGRADE_MAXED = 5,
}

enum CollectibleClaim {
	SUCCESS = 0,
	ALREADY_CLAIMED = 1,
	INVENTORY_FULL = 2,
	INVALID_PLAYER = 3,
	STALE_OFFER = 4,
}

enum OfferRefresh {
	SUCCESS = 0,
	LIMIT_REACHED = 1,
	INSUFFICIENT_XIRANG = 2,
	INVALID_PLAYER = 3,
	STALE_OFFER = 4,
}
