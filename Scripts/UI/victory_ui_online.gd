extends CanvasLayer
class_name VictoryUIOnline

@onready var title_label: Label = $Control/Container/TitleLabel
@onready var detail_label: Label = $Control/Container/DetailLabel
@onready var hint_label: Label = $Control/Container/HintLabel
@onready var return_button: Button = $Control/Container/ReturnButton

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if return_button and not return_button.pressed.is_connected(_on_return_pressed):
		return_button.pressed.connect(_on_return_pressed)

func show_result(result: String, detail: String = "") -> void:
	visible = true
	
	match result:
		"boss_win":
			title_label.text = "Boss 胜利"
		"players_win":
			title_label.text = "玩家胜利"
		"impostor_win":
			title_label.text = "内鬼胜利"
		_:
			title_label.text = "结算"
	
	detail_label.text = detail
	hint_label.text = "点击按钮返回关卡选择"

func _on_return_pressed() -> void:
	var tree := get_tree()
	# 立即关闭结算页（避免切场景/断网前这一帧仍显示）
	if return_button:
		return_button.disabled = true
	visible = false
	# 立即从父节点移除（用户期望点击后就从父节点树里删除）
	var parent := get_parent()
	if parent:
		parent.remove_child(self)

	# 客户端：断开与服务器连接；服务器：停止 host
	if NetworkManager and NetworkManager.has_method("stop_network"):
		NetworkManager.stop_network()
	if tree:
		tree.paused = false
	await SceneCleanupManager.change_scene_safely("res://scenes/UI/level_select.tscn")
	# 已经 remove_child(self) 不在场景树中，直接释放即可
	free()
