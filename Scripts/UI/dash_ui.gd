extends BaseSkillUI

## Dash UI 控制脚本
## 显示 Dash 技能的 CD 状态
## 支持普通模式和联网模式

var player_ref: CharacterBody2D = null

func _ready():
	super._ready()  # 调用基类初始化
	_try_init()


## 尝试初始化（带重试）
func _try_init() -> void:
	await get_tree().create_timer(0.2).timeout
	_find_player()
	
	if not player_ref:
		# 玩家还没生成，继续等待
		_try_init()


## 查找玩家引用（支持普通模式和联网模式）
func _find_player() -> void:
	# 联网模式：从 NetworkPlayerManager 获取本地玩家
	if GameMain.current_mode_id == "online":
		player_ref = NetworkPlayerManager.local_player
	else:
		# 普通模式：从 player 组获取
		player_ref = get_tree().get_first_node_in_group("player")

## 重写：获取Dash的CD剩余时间
func _get_remaining_cd() -> float:
	if not player_ref:
		return 0.0
	
	if not player_ref.dash_cooldown_timer:
		return 0.0
	
	var timer = player_ref.dash_cooldown_timer
	if timer.is_stopped():
		return 0.0
	
	return timer.time_left
