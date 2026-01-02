extends Control
class_name HPBar

## HP条组件
## 显示玩家血量，支持自动连接到玩家

@onready var hp_value_bar: ProgressBar = $HBoxContainer/hp_value_bar
@onready var hp_label: Label = $HBoxContainer/hp_value_bar/Label

var player_ref: CharacterBody2D = null

func _ready() -> void:
	# 等待一帧确保场景加载完成
	await get_tree().process_frame
	
	# 尝试自动连接玩家
	auto_connect_player()

## 自动连接玩家
func auto_connect_player() -> void:
	# 在线模式：必须绑定本地玩家（场景里会有多个 player，get_first_node_in_group 不稳定）
	# 单机模式：继续使用 group 查找
	var tries := 0
	var target: Node = _resolve_target_player()
	while (not target or not is_instance_valid(target)) and tries < 30:
		tries += 1
		await get_tree().create_timer(0.1).timeout
		target = _resolve_target_player()
	
	if target and is_instance_valid(target):
		connect_to_player(target)


func _resolve_target_player() -> CharacterBody2D:
	# 约定：online 模式以 NetworkPlayerManager.local_player 为准
	if "current_mode_id" in GameMain and GameMain.current_mode_id == "online":
		if NetworkPlayerManager and NetworkPlayerManager.local_player and is_instance_valid(NetworkPlayerManager.local_player):
			return NetworkPlayerManager.local_player as CharacterBody2D
		
		# 兜底：从 players 字典里按本地 peer_id 找
		if NetworkPlayerManager and NetworkPlayerManager.players and NetworkManager:
			var pid := int(NetworkManager.get_peer_id())
			var p = NetworkPlayerManager.players.get(pid)
			if p and is_instance_valid(p):
				return p as CharacterBody2D
	
	# 单机/兜底：取第一个 player（只有单机应当唯一）
	return get_tree().get_first_node_in_group("player") as CharacterBody2D

## 连接到玩家
func connect_to_player(player: CharacterBody2D) -> void:
	if not player:
		return
	
	# 如果之前绑定了别的玩家，先断开信号，避免旧玩家 hp_changed 干扰显示
	if player_ref and is_instance_valid(player_ref) and player_ref != player:
		if player_ref.has_signal("hp_changed") and player_ref.hp_changed.is_connected(_on_player_hp_changed):
			player_ref.hp_changed.disconnect(_on_player_hp_changed)
	
	player_ref = player
	
	# 连接玩家血量变化信号
	if player.has_signal("hp_changed"):
		if not player.hp_changed.is_connected(_on_player_hp_changed):
			player.hp_changed.connect(_on_player_hp_changed)
	
	# 初始化显示
	var now_hp_v = player.get("now_hp")
	var max_hp_v = player.get("max_hp")
	if now_hp_v != null and max_hp_v != null:
		update_hp(int(now_hp_v), int(max_hp_v))

## 更新血量显示
func update_hp(current: int, maximum: int) -> void:
	if not hp_value_bar or not hp_label:
		return
	
	# 更新ProgressBar
	hp_value_bar.max_value = maximum
	hp_value_bar.value = current
	
	# 更新Label文本
	hp_label.text = "%d / %d" % [current, maximum]

## 玩家血量变化回调
func _on_player_hp_changed(current_hp: int, max_hp: int) -> void:
	update_hp(current_hp, max_hp)
