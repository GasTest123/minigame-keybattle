extends Control
class_name WeaponChooseUI

## 武器选择界面
## 让用户选择2把武器，然后开始游戏

# ========== UI 节点引用 ==========
# 标题区域
@onready var player_portrait: TextureRect = $TitleSection/PlayerNameContainer/QuestionMark/playerportrait
@onready var player_name_label: Label = $TitleSection/PlayerNameContainer/PlayerName

# 武器网格
@onready var weapon_grid: GridContainer = $MainContent/WeaponGridSection/WeaponGrid

# 武器1面板
@onready var weapon1_panel: TextureRect = $MainContent/WeaponDetailSection/Weapon1Panel
@onready var weapon1_name: Label = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/NameSection/Weapon1Name
@onready var weapon1_icon: TextureRect = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1IconContainer/Weapon1Icon
@onready var weapon1_caltype_label: Label = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/calSection/caltypeLabel
@onready var weapon1_damage_value: Label = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/DamageSection/DamageBar/DamageValue
@onready var weapon1_damage_bar: ProgressBar = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/DamageSection/DamageBar
@onready var weapon1_speed_value: Label = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/SpeedSection/SpeedBar/SpeedValue
@onready var weapon1_speed_bar: ProgressBar = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/SpeedSection/SpeedBar
@onready var weapon1_range_value: Label = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/RangeSection/RangeBar/RangeValue
@onready var weapon1_range_bar: ProgressBar = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/RangeSection/RangeBar
@onready var weapon1_effect_text: Label = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content/Weapon1Stats/EffectSection/EffectText
@onready var weapon1_content: HBoxContainer = $MainContent/WeaponDetailSection/Weapon1Panel/Weapon1Container/Weapon1Content

# 武器2面板
@onready var weapon2_panel: TextureRect = $MainContent/WeaponDetailSection/Weapon2Panel
@onready var weapon2_content: HBoxContainer = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content
@onready var weapon2_name: Label = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/NameSection/Weapon2Name
@onready var weapon2_icon: TextureRect = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2IconContainer/Weapon2Icon
@onready var weapon2_caltype_label: Label = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/calSection/caltypeLabel
@onready var weapon2_damage_value: Label = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/DamageSection/DamageBar/DamageValue
@onready var weapon2_damage_bar: ProgressBar = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/DamageSection/DamageBar
@onready var weapon2_speed_value: Label = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/SpeedSection/SpeedBar/SpeedValue
@onready var weapon2_speed_bar: ProgressBar = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/SpeedSection/SpeedBar
@onready var weapon2_range_value: Label = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/RangeSection/RangeBar/RangeValue
@onready var weapon2_range_bar: ProgressBar = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/RangeSection/RangeBar
@onready var weapon2_effect_text: Label = $MainContent/WeaponDetailSection/Weapon2Panel/Weapon2Container/Weapon2Content/Weapon2Stats/EffectSection/EffectText

# 底部按钮（TextureButton）
@onready var back_button: TextureButton = $BottomSection/BackButton
@onready var start_button: TextureButton = $BottomSection/NextButton

# ========== 资源引用 ==========
var weapon_option_scene: PackedScene = preload("res://scenes/UI/weapon_choose_option.tscn")

# 面板纹理资源
var tex_panel_choosed: Texture2D = preload("res://assets/UI/weapon_choose/weaponchoose-info-choosed-01.png")
var tex_panel_unchoosed: Texture2D = preload("res://assets/UI/weapon_choose/weaponchoose-info-unchoosed-01.png")

# ========== 状态变量 ==========
var weapon_ids: Array = []
var selected_weapon_ids: Array = []
var weapon_cards: Dictionary = {}  # weapon_id -> Control（weapon_choose_option 实例）

const MAX_WEAPONS = 2
const CLASS_CHOOSE_SCENE = "res://scenes/UI/Class_choose.tscn"

## 预定义的武器列表（10个武器，每行5个，共2行）
var available_weapons: Array = [
	"flame_sword","dagger", "machine_gun","shotgun","homing_missile",  # 第一行
	"rifle","lightning_chain","ice_shard","meteor","arcane_missile" # 第二行
]
#❌ 未显示的：pistol, sword,  fireball,

func _ready() -> void:
	# 初始化玩家信息显示
	_initialize_player_info()
	
	# 初始化武器网格
	_initialize_weapon_grid()
	
	# 连接按钮信号
	back_button.pressed.connect(_on_back_button_pressed)
	start_button.pressed.connect(_on_start_button_pressed)
	
	# 默认不选中任何武器
	selected_weapon_ids.clear()
	
	# 初始化开战按钮状态
	_update_start_button()
	
	# 初始化武器详情面板（空状态）
	_update_weapon_details()

## 初始化玩家信息显示
func _initialize_player_info() -> void:
	# 显示已选择的职业头像（与职业选择界面样式一致）
	var class_id = GameMain.selected_class_id
	if class_id != "":
		var class_data = ClassDatabase.get_class_data(class_id)
		if class_data and class_data.portrait:
			player_portrait.texture = class_data.portrait
	
	# 显示玩家名字（从存档读取）
	var saved_name = SaveManager.get_player_name()
	if saved_name != "":
		player_name_label.text = saved_name
	else:
		player_name_label.text = "Key Person"

## 初始化武器网格（使用 weapon_choose_option 组件）
func _initialize_weapon_grid() -> void:
	# 清空现有内容
	for child in weapon_grid.get_children():
		child.queue_free()
	
	weapon_ids.clear()
	weapon_cards.clear()
	
	# 获取所有可用武器（去重）
	var unique_weapons: Array = []
	for weapon_id in available_weapons:
		if not unique_weapons.has(weapon_id):
			unique_weapons.append(weapon_id)
	
	# 填充武器网格（2行5列 = 10个格子）
	var index = 0
	for weapon_id in unique_weapons:
		if index >= 10:
			break
		
		var weapon_data = WeaponDatabase.get_weapon(weapon_id)
		if weapon_data == null:
			continue
		
		# 实例化武器选项组件
		var option = weapon_option_scene.instantiate()
		_setup_weapon_option(option, weapon_id, weapon_data)
		
		weapon_grid.add_child(option)
		weapon_ids.append(weapon_id)
		weapon_cards[weapon_id] = option
		index += 1

## 设置武器选项组件
func _setup_weapon_option(option: Control, weapon_id: String, weapon_data: WeaponData) -> void:
	# 获取子节点引用
	var bg_choosed = option.get_node_or_null("bg_choosed")
	var background = option.get_node_or_null("background")
	
	if background:
		# 设置武器图标
		var weapon_icon = background.get_node_or_null("weapon_icon")
		if weapon_icon and weapon_data.texture_path != "":
			var tex = load(weapon_data.texture_path)
			if tex:
				weapon_icon.texture = tex
		
		# 设置武器名称
		var bg_weaponname = background.get_node_or_null("bg_weaponname")
		if bg_weaponname:
			var weapon_name_label = bg_weaponname.get_node_or_null("weapon_name")
			if weapon_name_label:
				weapon_name_label.text = weapon_data.weapon_name
		
		# 初始状态：未选中
		var choosed = background.get_node_or_null("choosed")
		if choosed:
			choosed.visible = false
	
	# 初始状态：bg_choosed 不可见
	if bg_choosed:
		bg_choosed.visible = false
	
	# 设置点击事件
	option.gui_input.connect(_on_weapon_option_clicked.bind(weapon_id))
	option.mouse_filter = Control.MOUSE_FILTER_STOP

## 切换武器选择
func _toggle_weapon(weapon_id: String) -> void:
	if selected_weapon_ids.has(weapon_id):
		# 取消选择
		selected_weapon_ids.erase(weapon_id)
	else:
		# 选择武器（最多2个）
		if selected_weapon_ids.size() < MAX_WEAPONS:
			selected_weapon_ids.append(weapon_id)
		else:
			return  # 已达上限，不做处理
	
	# 更新所有卡片的选中状态
	_update_card_selection()
	
	# 更新武器详情面板
	_update_weapon_details()
	
	# 更新开战按钮状态
	_update_start_button()

## 更新所有卡片的选中状态
func _update_card_selection() -> void:
	for weapon_id in weapon_cards.keys():
		var option = weapon_cards[weapon_id] as Control
		var is_selected = selected_weapon_ids.has(weapon_id)
		
		# 获取子节点
		var bg_choosed = option.get_node_or_null("bg_choosed")
		var background = option.get_node_or_null("background")
		
		# 更新 bg_choosed 可见性
		if bg_choosed:
			bg_choosed.visible = is_selected
		
		# 更新 choosed 标记可见性
		if background:
			var choosed = background.get_node_or_null("choosed")
			if choosed:
				choosed.visible = is_selected

## 更新武器详情面板
func _update_weapon_details() -> void:
	# 武器1面板
	if selected_weapon_ids.size() >= 1:
		var weapon_id = selected_weapon_ids[0]
		var weapon_data = WeaponDatabase.get_weapon(weapon_id)
		_update_weapon_panel(1, weapon_data)
		# 选中状态
		weapon1_panel.texture = tex_panel_choosed
		weapon1_content.visible = true
	else:
		_clear_weapon_panel(1)
		# 未选中状态
		weapon1_panel.texture = tex_panel_unchoosed
		weapon1_content.visible = false
	
	# 武器2面板
	if selected_weapon_ids.size() >= 2:
		var weapon_id = selected_weapon_ids[1]
		var weapon_data = WeaponDatabase.get_weapon(weapon_id)
		_update_weapon_panel(2, weapon_data)
		# 选中状态
		weapon2_panel.texture = tex_panel_choosed
		weapon2_content.visible = true
	else:
		_clear_weapon_panel(2)
		# 未选中状态
		weapon2_panel.texture = tex_panel_unchoosed
		weapon2_content.visible = false

## 更新武器面板
func _update_weapon_panel(slot: int, weapon_data: WeaponData) -> void:
	var name_label: Label
	var icon: TextureRect
	var caltype_label: Label
	var damage_value: Label
	var damage_bar: ProgressBar
	var speed_value: Label
	var speed_bar: ProgressBar
	var range_value: Label
	var range_bar: ProgressBar
	var effect_text: Label
	
	if slot == 1:
		name_label = weapon1_name
		icon = weapon1_icon
		caltype_label = weapon1_caltype_label
		damage_value = weapon1_damage_value
		damage_bar = weapon1_damage_bar
		speed_value = weapon1_speed_value
		speed_bar = weapon1_speed_bar
		range_value = weapon1_range_value
		range_bar = weapon1_range_bar
		effect_text = weapon1_effect_text
	else:
		name_label = weapon2_name
		icon = weapon2_icon
		caltype_label = weapon2_caltype_label
		damage_value = weapon2_damage_value
		damage_bar = weapon2_damage_bar
		speed_value = weapon2_speed_value
		speed_bar = weapon2_speed_bar
		range_value = weapon2_range_value
		range_bar = weapon2_range_bar
		effect_text = weapon2_effect_text
	
	# 更新数据
	if name_label:
		name_label.text = weapon_data.weapon_name
	
	# 加载图标
	if icon and weapon_data.texture_path != "":
		var tex = load(weapon_data.texture_path)
		if tex:
			icon.texture = tex
	
	# 更新武器类型显示
	if caltype_label:
		caltype_label.text = _get_calculation_type_text(weapon_data.calculation_type)
	
	# 伤害
	if damage_value:
		damage_value.text = str(weapon_data.damage)
	if damage_bar:
		damage_bar.value = weapon_data.damage
	
	# 攻速（转换为每分钟攻击次数）
	var attacks_per_minute = 60.0 / weapon_data.attack_speed if weapon_data.attack_speed > 0 else 0.0
	if speed_value:
		speed_value.text = str(int(attacks_per_minute))
	if speed_bar:
		speed_bar.value = attacks_per_minute
	
	# 击退（优先武器自身击退力，否则读取对应子弹击退力）
	var knockback_val := _get_weapon_knockback_force(weapon_data)
	if range_value:
		range_value.text = str(int(knockback_val))
	if range_bar:
		range_bar.value = knockback_val
	
	# 描述 + 特效
	var desc_and_effect = _get_description_and_effect_text(weapon_data)
	if effect_text:
		effect_text.text = desc_and_effect

## 获取武器的“基础击退力”（用于选择界面展示，不叠加玩家属性）
## 规则：武器 behavior_params.knockback_force > WeaponData.knockback_force（兼容字段）> bullet_id 对应子弹 knockback_force
func _get_weapon_knockback_force(weapon_data: WeaponData) -> float:
	if weapon_data == null:
		return 0.0
	
	# 1) 先看新版 behavior_params（近战武器通常在这里）
	var params := weapon_data.get_behavior_params()
	if params.has("knockback_force"):
		return max(0.0, float(params.get("knockback_force", 0.0)))
	
	# 2) 旧版兼容字段
	if weapon_data.knockback_force > 0.0:
		return max(0.0, float(weapon_data.knockback_force))
	
	# 3) 远程武器：取子弹击退
	if params.has("bullet_id"):
		var bullet_id := str(params.get("bullet_id", ""))
		if bullet_id != "":
			var bullet_data := BulletDatabase.get_bullet(bullet_id)
			if bullet_data:
				return max(0.0, float(bullet_data.knockback_force))
	
	return 0.0

## 获取结算类型的显示文字
func _get_calculation_type_text(calc_type: WeaponData.CalculationType) -> String:
	match calc_type:
		WeaponData.CalculationType.MELEE:
			return "近战武器"
		WeaponData.CalculationType.RANGED:
			return "远程武器"
		WeaponData.CalculationType.MAGIC:
			return "魔法武器"
		_:
			return "未知类型"

## 获取武器描述和特效文字（描述在前，特效在后，用换行分隔）
func _get_description_and_effect_text(weapon_data: WeaponData) -> String:
	var lines = []
	
	# 第一行：武器描述
	if weapon_data.description != "":
		lines.append(weapon_data.description)
	
	# 第二行开始：特效效果
	var effect_text = _get_weapon_effect_text(weapon_data)
	if effect_text != "":
		lines.append(effect_text)
	
	return "\n".join(lines)

## 获取武器特效文字
func _get_weapon_effect_text(weapon_data: WeaponData) -> String:
	if weapon_data.special_effects.is_empty():
		return ""
	
	# 新版结构：special_effects 直接是 Array
	var effects = weapon_data.special_effects

	var texts = []
	
	for effect in effects:
		var effect_type = effect.get("type", "")
		var params = effect.get("params", {})
		
		match effect_type:
			"lifesteal":
				var chance = params.get("chance", 0) * 100
				var percent = params.get("percent", 0) * 100
				texts.append("%d%%概率吸血%d%%" % [int(chance), int(percent)])
			"bleed":
				var chance = params.get("chance", 0) * 100
				texts.append("%d%%概率流血" % int(chance))
			"burn":
				var chance = params.get("chance", 0) * 100
				texts.append("%d%%概率燃烧" % int(chance))
			"freeze":
				var chance = params.get("chance", 0) * 100
				texts.append("%d%%概率冰冻" % int(chance))
	
	return "\n".join(texts)

## 清空武器面板
func _clear_weapon_panel(slot: int) -> void:
	if slot == 1:
		if weapon1_name:
			weapon1_name.text = ""
		if weapon1_icon:
			weapon1_icon.texture = null
		if weapon1_caltype_label:
			weapon1_caltype_label.text = ""
		if weapon1_damage_value:
			weapon1_damage_value.text = "0"
		if weapon1_damage_bar:
			weapon1_damage_bar.value = 0
		if weapon1_speed_value:
			weapon1_speed_value.text = "0"
		if weapon1_speed_bar:
			weapon1_speed_bar.value = 0
		if weapon1_range_value:
			weapon1_range_value.text = "0"
		if weapon1_range_bar:
			weapon1_range_bar.value = 0
		if weapon1_effect_text:
			weapon1_effect_text.text = ""
	else:
		if weapon2_name:
			weapon2_name.text = ""
		if weapon2_icon:
			weapon2_icon.texture = null
		if weapon2_caltype_label:
			weapon2_caltype_label.text = ""
		if weapon2_damage_value:
			weapon2_damage_value.text = "0"
		if weapon2_damage_bar:
			weapon2_damage_bar.value = 0
		if weapon2_speed_value:
			weapon2_speed_value.text = "0"
		if weapon2_speed_bar:
			weapon2_speed_bar.value = 0
		if weapon2_range_value:
			weapon2_range_value.text = "0"
		if weapon2_range_bar:
			weapon2_range_bar.value = 0
		if weapon2_effect_text:
			weapon2_effect_text.text = ""

## 更新开战按钮状态
func _update_start_button() -> void:
	var can_start = selected_weapon_ids.size() == MAX_WEAPONS
	start_button.disabled = not can_start

# ========== 信号回调 ==========

func _on_weapon_option_clicked(event: InputEvent, weapon_id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_toggle_weapon(weapon_id)

func _on_back_button_pressed() -> void:
	# 返回职业选择界面
	get_tree().change_scene_to_file(CLASS_CHOOSE_SCENE)

func _on_start_button_pressed() -> void:
	if selected_weapon_ids.size() != MAX_WEAPONS:
		return
	
	# 保存选择的武器
	GameMain.selected_weapon_ids = selected_weapon_ids.duplicate()
	
	# 根据当前mode_id选择目标场景
	var mode_id = GameMain.current_mode_id
	var target_scene = ""
	
	if mode_id == "multi":
		target_scene = "res://scenes/map/model_2_stage_1.tscn"
		GameMain.current_map_id = "model2_stage1"
		print("[WeaponChoose] 进入Multi模式地图: model2_stage1")
	else:  # survival或空字符串
		target_scene = "res://scenes/map/bg_map.tscn"
		GameMain.current_map_id = "default"
		print("[WeaponChoose] 进入Survival模式地图: bg_map")
	
	# 加载游戏场景
	var game_scene = load(target_scene)
	if game_scene:
		get_tree().change_scene_to_packed(game_scene)
	else:
		push_error("[WeaponChoose] 无法加载游戏场景: %s" % target_scene)
