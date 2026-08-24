extends CapooKnight
class_name CapooSwordsman


# Swordsman is a distinct combat family that only reuses Knight's authored base.
# Its rectangle + SegmentShape shell is admitted only through the non-convex
# compound proxy; indexed Player/Plant authority remains independently closed.
func supports_layered_area_authoritative_simulation() -> bool:
	return true


func supports_layered_contact_authoritative_simulation() -> bool:
	return true


func supports_indexed_touch_authority() -> bool:
	return false
