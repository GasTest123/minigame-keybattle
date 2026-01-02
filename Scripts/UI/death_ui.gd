extends CanvasLayer
class_name DeathUI

## 死亡UI
## 显示死亡界面，提供放弃和复活选项

@onready var death_panel: TextureRect = $Panel
@onready var title_label: Label = $Panel/TitleLabel
@onready var warning_label: Label = $Panel/VBoxContainer/warningLable
@onready var revive_button: TextureButton = $Panel/VBoxContainer/ButtonContainer/ReviveButton
@onready var revive_label: RichTextLabel = $Panel/VBoxContainer/ButtonContainer/ReviveButton/reviveLabel
@onready var give_up_button: TextureButton = $Panel/VBoxContainer/ButtonContainer/GiveUpButton
@onready var restart_button: TextureButton = $Panel/VBoxContainer/ButtonContainer/RestartButton
@onready var dead_poster: TextureRect = $Panel/dead_poster

## 信号
signal revive_requested  # 请求复活
signal give_up_requested  # 请求放弃
signal restart_requested  # 请求再战

var revive_cost: int = 0
var can_afford: bool = false

func _ready() -> void:
	# 添加到组（用于场景清理）
	add_to_group("death_ui")
	
	# 连接按钮信号
	revive_button.pressed.connect(_on_revive_pressed)
	give_up_button.pressed.connect(_on_give_up_pressed)
	restart_button.pressed.connect(_on_restart_pressed)
	
	# 默认隐藏
	hide()

## 显示死亡界面
func show_death_screen(revive_count: int, mode_id: String = "survival") -> void:
	# 固定复活费用：2个masterkey
	revive_cost = 2
	var current_master_key = GameMain.master_key
	can_afford = current_master_key >= revive_cost
	
	# 更新死亡海报
	_update_dead_poster()
	
	# Multi模式下隐藏复活相关UI
	if mode_id == "multi":
		revive_button.visible = false
		restart_button.visible = true
		warning_label.visible = false
		print("[DeathUI] Multi模式 - 隐藏复活选项")
	else:
		# Survival模式：正常显示复活选项
		revive_button.visible = true
		restart_button.visible = true
		
		# 更新复活按钮状态
		if can_afford:
			revive_button.disabled = false
			warning_label.visible = false
		else:
			revive_button.disabled = true
			warning_label.visible = true
	
	# 显示界面
	show()
	
	print("[DeathUI] 显示死亡界面 | 模式:", mode_id, " 复活次数:", revive_count, " 费用:", revive_cost, " 当前生命钥匙:", current_master_key)

## 更新死亡海报
func _update_dead_poster() -> void:
	# 获取当前玩家的职业ID
	var class_id = GameMain.selected_class_id
	if class_id == "":
		class_id = "balanced"  # 默认职业
	
	var class_data = ClassDatabase.get_class_data(class_id)
	if class_data:
		if class_data.dead_poster:
			dead_poster.texture = class_data.dead_poster
		elif class_data.poster:
			# 如果没有 dead_poster，使用 poster 作为备用
			dead_poster.texture = class_data.poster

## 复活按钮按下
func _on_revive_pressed() -> void:
	if can_afford:
		print("[DeathUI] 玩家选择复活")
		revive_requested.emit()
		hide()

## 放弃按钮按下
func _on_give_up_pressed() -> void:
	print("[DeathUI] 玩家选择放弃")
	give_up_requested.emit()
	hide()

## 隐藏界面
func hide_death_screen() -> void:
	hide()


func _on_restart_pressed() -> void:
	var current_mode = GameMain.current_mode_id
	print("[DeathUI] 玩家选择再战，当前模式:", current_mode)
	restart_requested.emit()
	hide()
	# 注意：不清除mode_id，让StartMenu继续使用当前模式


## 联网模式：显示死亡界面（使用玩家自己的 master_key）
func show_death_screen_online(player_master_key: int) -> void:
	# 固定复活费用：1个masterkey
	revive_cost = NetworkPlayerManager.REVIVE_COST_MASTER_KEY
	can_afford = player_master_key >= revive_cost

	# 联网模式：显示复活选项，隐藏再战和放弃按钮
	revive_button.visible = true
	restart_button.visible = false
	give_up_button.visible = false

	# 更新警告标签显示费用信息
	warning_label.text = "复活费用：%d 生命钥匙 (当前: %d)" % [revive_cost, player_master_key]
	warning_label.visible = true

	# 更新复活按钮状态
	if can_afford:
		revive_button.disabled = false
		revive_label.text = "复活 -%d生命钥匙" % revive_cost
	else:
		revive_button.disabled = true
		revive_label.text = "生命钥匙不足"

	# 显示界面
	show()

	print("[DeathUI] 联网模式显示死亡界面 | 费用:", revive_cost, " 当前生命钥匙:", player_master_key)
