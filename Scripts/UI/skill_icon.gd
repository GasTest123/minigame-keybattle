extends BaseSkillUI

## 职业技能图标UI组件
## 显示技能图标、名称和CD倒计时
## 支持普通模式和联网模式

@onready var skill_des_label: Label = $Skill_des

var skill_data: ClassData = null
var player_ref: CharacterBody2D = null

func _ready() -> void:
	super._ready()  # 调用基类初始化
	_try_init()


## 尝试初始化（带重试）
func _try_init() -> void:
	await get_tree().create_timer(0.2).timeout
	_find_player()
	
	if player_ref:
		_auto_init_skill_data()
	else:
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
	
	# 监听职业变更信号（联网模式分配角色时会触发）
	if player_ref and player_ref.has_signal("class_changed"):
		if not player_ref.class_changed.is_connected(_on_class_changed):
			player_ref.class_changed.connect(_on_class_changed)


## 职业变更回调
func _on_class_changed(class_data: ClassData) -> void:
	set_skill_data(class_data)


## 自动初始化技能数据（联网模式）
func _auto_init_skill_data() -> void:
	if not player_ref or not is_instance_valid(player_ref):
		return
	
	# 如果已经有技能数据，跳过
	if skill_data:
		return
	
	# 获取玩家的职业数据
	if player_ref.class_manager and player_ref.class_manager.current_class:
		set_skill_data(player_ref.class_manager.current_class)

## 设置技能数据
func set_skill_data(class_data: ClassData) -> void:
	skill_data = class_data
	
	if not class_data or not class_data.skill_data:
		visible = false
		return
	
	var actual_skill_data: SkillData = class_data.skill_data
	visible = true
	
	# 设置技能名称
	if name_label:
		name_label.text = actual_skill_data.name
	
	# 加载技能图标（从 SkillData 资源中读取）
	if icon and actual_skill_data.icon:
		icon.texture = actual_skill_data.icon
	
	# 设置技能描述
	if skill_des_label:
		skill_des_label.text = _generate_skill_description(actual_skill_data)

## 重写：获取技能CD剩余时间
func _get_remaining_cd() -> float:
	if not player_ref or not skill_data or not skill_data.skill_data:
		return 0.0
	
	# 联网模式下，Boss 角色使用自定义技能冷却（通过 PvP 系统）
	if GameMain.current_mode_id == "online":
		if player_ref.player_role_id == "boss" and player_ref.pvp_system:
			return player_ref.pvp_system.get_boss_skill_cooldown()
	
	# 其他角色使用 class_manager
	if not player_ref.class_manager:
		return 0.0
	
	var class_manager = player_ref.class_manager
	return class_manager.get_skill_cooldown(skill_data.skill_data.name)

## 获取技能剩余持续时间
func _get_remaining_duration() -> float:
	if not player_ref or not player_ref.class_manager or not skill_data or not skill_data.skill_data:
		return 0.0
	
	var class_manager = player_ref.class_manager
	var skill_name = skill_data.skill_data.name
	return class_manager.get_skill_remaining_duration(skill_name)

## 重写：更新CD显示（自定义显示逻辑）
func _update_cd_display():
	if not skill_data or not skill_data.skill_data:
		# 隐藏CD相关元素
		if cd_mask:
			cd_mask.visible = false
		if cd_text:
			cd_text.visible = false
		return
	
	var class_manager = player_ref.class_manager if player_ref else null
	if not class_manager:
		return
	
	# 联网模式下，Boss 角色使用简化的 CD 显示（无持续时间，只有冷却）
	if GameMain.current_mode_id == "online":
		if player_ref and player_ref.player_role_id == "boss":
			var remaining_cooldown = _get_remaining_cd()
			if remaining_cooldown > 0:
				if cd_mask:
					cd_mask.visible = true
				if cd_text:
					cd_text.visible = true
					cd_text.text = str(ceili(remaining_cooldown))
					cd_text.modulate = Color.WHITE
			else:
				if cd_mask:
					cd_mask.visible = false
				if cd_text:
					cd_text.visible = false
			return
	
	var skill_name = skill_data.skill_data.name
	
	# 检查技能是否激活
	var is_active = class_manager.is_skill_active(skill_name)
	var remaining_duration = _get_remaining_duration()
	var remaining_cooldown = _get_remaining_cd()
	
	if is_active and remaining_duration > 0:
		# 技能激活中：显示黄色文本倒计时（duration），cdmask 不可见
		if cd_mask:
			cd_mask.visible = false
		if cd_text:
			cd_text.visible = true
			cd_text.text = str(ceili(remaining_duration))
			# 设置黄色文本
			cd_text.modulate = Color.YELLOW
	elif remaining_cooldown > 0:
		# 技能持续时间结束后：cdmask 可见，显示白色倒计时（cooldown）
		if cd_mask:
			cd_mask.visible = true
		if cd_text:
			cd_text.visible = true
			cd_text.text = str(ceili(remaining_cooldown))
			# 设置白色文本
			cd_text.modulate = Color.WHITE
	else:
		# 技能可用：隐藏CD相关元素
		if cd_mask:
			cd_mask.visible = false
		if cd_text:
			cd_text.visible = false

## 生成技能描述文本
func _generate_skill_description(skill_data_resource: SkillData) -> String:
	if not skill_data_resource:
		return ""
	
	var lines = []
	
	# 持续时间
	if skill_data_resource.duration > 0:
		lines.append("持续时间：%.1f秒" % skill_data_resource.duration)
	
	# 冷却时间
	if skill_data_resource.cooldown > 0:
		lines.append("冷却：%.1f秒" % skill_data_resource.cooldown)
	
	# 技能描述
	if skill_data_resource.description and not skill_data_resource.description.is_empty():
		lines.append(skill_data_resource.description)
	
	return "\n".join(lines)

## 处理点击激活技能（可选功能）
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if player_ref and player_ref.has_method("activate_class_skill"):
				player_ref.activate_class_skill()
