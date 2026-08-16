extends RefCounted
class_name MultiplayerReconnectTypes

## 重连完成不是单一步骤：身份账本先提交，随后运行时明确报告 Player 已恢复、
## 本轮安全转为旁观，或不可恢复。NetManager 只在前两种终态后发布 ready。
enum RuntimeProjectionOutcome {
	RESTORED,
	SUSPENDED,
	FAILED,
}

## Host 重连事务的三个有界阶段。PREPARING_DELIVERY 只允许会话根节点
## 同步补发重连所需的完整快照；普通玩法输入仍保持关闭。
enum PendingPhase {
	LOADING,
	PROJECTING,
	PREPARING_DELIVERY,
}


static func is_valid_runtime_projection_outcome(outcome: int) -> bool:
	return outcome in [
		RuntimeProjectionOutcome.RESTORED,
		RuntimeProjectionOutcome.SUSPENDED,
		RuntimeProjectionOutcome.FAILED,
	]
