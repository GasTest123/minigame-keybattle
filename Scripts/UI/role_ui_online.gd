extends CanvasLayer
class_name RoleUIOnline

## 角色说明 UI
## 显示玩家被分配的角色信息和任务说明

signal intro_finished  # 介绍结束信号

const INTRO_COUNTDOWN := 10  # 角色介绍倒计时秒数

## 角色说明文本
const ROLE_DESCRIPTIONS := {
	"boss": {
		"title": "👹 Boss",
		"color": Color(0.9, 0.2, 0.2),
		"description": """你是 Boss！

【目标】
阻止 Player 和 Impostor 完成目标，
或在 20 波内杀死所有人！

【能力】
• 鼠标左键：冲撞攻击，对接触的玩家造成伤害
• 移动速度比普通玩家快
• 不会被怪物攻击

【提示】
追踪落单的玩家，利用冲撞造成伤害！
在关键时刻打断他们的战斗！"""
	},
	"impostor": {
		"title": "🎭 Impostor",
		"color": Color(0.8, 0.6, 0.2),
		"description": """你是 Impostor！

【目标】
独自击杀 15 波怪物，阻止 Player 完成目标！
你需要在合适时机叛变，成为最后的赢家。

【能力】
• 与普通玩家相同的战斗能力
• 按 B 键可以叛变（不可撤销）
• 叛变后可以攻击其他 Player

【提示】
前期假装合作，后期叛变抢夺胜利！
小心 Boss 的攻击！"""
	},
	"player": {
		"title": "🎮 Player",
		"color": Color(0.2, 0.7, 0.9),
		"description": """你是 Player！

【目标】
与队友合作，收集钥匙，击杀 15 波怪物！
小心 Boss 和潜在的 Impostor！

【能力】
• 攻击怪物获取钥匙掉落
• 使用技能击败敌人
• 与队友配合生存

【提示】
注意观察队友的行为，Impostor 可能随时叛变！
保持警惕，躲避 Boss 的攻击！"""
	}
}

var countdown_timer: float = 0.0
var is_counting: bool = false

@onready var bg: ColorRect = $Background
@onready var container: HBoxContainer = $Container
@onready var left_panel: Panel = $Container/LeftPanel
@onready var right_panel: Panel = $Container/RightPanel
@onready var sprite_container: Control = $Container/LeftPanel/SpriteContainer
@onready var player_sprite: AnimatedSprite2D = $Container/LeftPanel/SpriteContainer/PlayerSprite
@onready var role_title: Label = $Container/RightPanel/VBox/RoleTitle
@onready var role_description: RichTextLabel = $Container/RightPanel/VBox/RoleDescription
@onready var countdown_label: Label = $CountdownLabel


func _ready() -> void:
	hide()


func _process(delta: float) -> void:
	if is_counting:
		countdown_timer -= delta
		if countdown_timer <= 0:
			is_counting = false
			_on_intro_finished()
		else:
			_update_countdown_display()


## 显示角色介绍
func show_role_intro(role_id: String, sprite_frames: SpriteFrames) -> void:
	print("[RoleIntroUI] 显示角色介绍: role=%s" % role_id)
	
	# 设置角色动画
	if sprite_frames and player_sprite:
		player_sprite.sprite_frames = sprite_frames
		player_sprite.scale = Vector2(1.5, 1.5)  # 适中放大显示
		
		# 尝试播放动画：优先 "default"，其次 "walk"
		if sprite_frames.has_animation("default"):
			player_sprite.play("default")
		elif sprite_frames.has_animation("walk"):
			player_sprite.play("walk")
	
	# 显示 UI 后再设置位置（确保布局已计算）
	show()
	
	# 等待布局计算完成后居中角色
	await get_tree().process_frame
	await get_tree().process_frame
	
	# 使用 left_panel 的全局位置和大小来计算角色的居中位置
	if left_panel and player_sprite:
		var panel_rect = left_panel.get_global_rect()
		var center_pos = panel_rect.position + panel_rect.size / 2
		player_sprite.global_position = center_pos
		print("[RoleIntroUI] 面板全局矩形: %s, 角色全局位置: %s" % [panel_rect, player_sprite.global_position])
	
	# 设置角色说明
	var role_data = ROLE_DESCRIPTIONS.get(role_id, ROLE_DESCRIPTIONS["player"])
	
	if role_title:
		role_title.text = role_data["title"]
		role_title.add_theme_color_override("font_color", role_data["color"])
	
	if role_description:
		role_description.text = role_data["description"]


## 开始倒计时（由服务器同步调用）
func start_countdown(seconds: int = INTRO_COUNTDOWN) -> void:
	countdown_timer = float(seconds)
	is_counting = true
	_update_countdown_display()
	print("[RoleIntroUI] 开始倒计时: %d 秒" % seconds)


## 更新倒计时（由服务器同步调用）
func update_countdown(seconds: int) -> void:
	countdown_timer = float(seconds)
	_update_countdown_display()


func _update_countdown_display() -> void:
	if countdown_label:
		var secs = int(ceil(countdown_timer))
		countdown_label.text = "游戏将在 %d 秒后开始" % secs


func _on_intro_finished() -> void:
	print("[RoleIntroUI] 角色介绍结束")
	intro_finished.emit()
	hide()


## 强制关闭
func force_close() -> void:
	is_counting = false
	hide()
