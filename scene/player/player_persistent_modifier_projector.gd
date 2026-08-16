extends RefCounted
class_name PlayerPersistentModifierProjector


## 场景 Player 只向强类型持久投影器提供当前身份；具体账本仍由模式
## owner 持有。返回 false 表示身份或权威账本不完整，场景必须拒绝发布该 Player。
func apply_to_player(_player: Player, _ledger_peer_id: int) -> bool:
	return false
