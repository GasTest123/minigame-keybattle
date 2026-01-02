extends CanvasLayer
class_name RoomUIOnline

## 等待房间UI
## 显示已连接的玩家和游戏倒计时

signal force_start_requested

@onready var title_label: Label = $Control/Container/TitleLabel
@onready var player_list: VBoxContainer = $Control/Container/PlayerList
@onready var status_label: Label = $Control/Container/StatusLabel
@onready var hint_label: Label = $Control/Container/HintLabel
@onready var force_start_button: Button = $Control/Container/ForceStartButton

const MAX_PLAYERS := 4

func _ready() -> void:
	# 服务器可以看到强制开始按钮
	if NetworkManager.is_server():
		force_start_button.visible = true
		force_start_button.pressed.connect(_on_force_start_pressed)
	
	# 初始状态
	update_player_count(0)

## 更新玩家数量显示
func update_player_count(count: int) -> void:
	status_label.text = "%d/%d 玩家" % [count, MAX_PLAYERS]
	
	if count >= MAX_PLAYERS:
		hint_label.text = "人数已满，即将开始游戏！"
		hint_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	else:
		hint_label.text = "等待更多玩家加入，人满后自动开始"
		hint_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

## 更新玩家列表
func update_player_list(players: Array) -> void:
	# 清空旧列表
	for child in player_list.get_children():
		child.queue_free()
	
	# 添加玩家条目
	for i in range(players.size()):
		var player_entry = _create_player_entry(players[i], i + 1)
		player_list.add_child(player_entry)
	
	# 更新数量
	update_player_count(players.size())

## 创建玩家条目
func _create_player_entry(player_data: Dictionary, index: int) -> HBoxContainer:
	var entry = HBoxContainer.new()
	entry.alignment = BoxContainer.ALIGNMENT_CENTER
	entry.add_theme_constant_override("separation", 15)
	
	# 序号
	var index_label = Label.new()
	index_label.text = "%d." % index
	index_label.add_theme_font_size_override("font_size", 26)
	index_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	entry.add_child(index_label)
	
	# 图标
	var icon_label = Label.new()
	icon_label.text = "🎮"
	icon_label.add_theme_font_size_override("font_size", 28)
	entry.add_child(icon_label)
	
	# 玩家名称
	var name_label = Label.new()
	name_label.text = player_data.display_name if player_data.has("display_name") else "Player"
	name_label.add_theme_font_size_override("font_size", 28)
	name_label.add_theme_color_override("font_color", Color(1, 1, 1))
	name_label.custom_minimum_size.x = 200
	entry.add_child(name_label)
	
	# 标记本地玩家
	var local_peer_id = NetworkManager.get_peer_id()
	if player_data.has("peer_id") and player_data.peer_id == local_peer_id:
		var you_label = Label.new()
		you_label.text = "(你)"
		you_label.add_theme_font_size_override("font_size", 22)
		you_label.add_theme_color_override("font_color", Color(0.3, 1, 0.3))
		entry.add_child(you_label)
	
	return entry

## 显示倒计时
func show_countdown(seconds: int) -> void:
	title_label.text = "游戏将在 %d 秒后开始!" % seconds
	title_label.add_theme_color_override("font_color", Color(1, 0.5, 0.3))
	status_label.text = "准备好了吗？"
	hint_label.text = "即将开始..."
	force_start_button.visible = false

## 强制开始按钮点击
func _on_force_start_pressed() -> void:
	force_start_requested.emit()
