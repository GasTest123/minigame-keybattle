extends Control
class_name UpgradeShop

## 升级商店
## 每波结束后弹出，允许玩家购买升级
## 负责管理升级选项的生成、刷新、购买逻辑

@onready var upgrade_container: HBoxContainer = %UpgradeContainer
@onready var refresh_button: TextureButton = %RefreshButton
@onready var close_button: TextureButton = %CloseButton
@onready var refresh_label: RichTextLabel = $RefreshSection/RefreshButton/refreshLabel
@onready var close_button_label: Label = $BottomSection/CloseButton/Label

## 新版 UI 节点引用
@onready var player_portrait: TextureRect = %PlayerPortrait
@onready var player_name_label: Label = %PlayerName
@onready var weapon_container: GridContainer = %WeaponContainer

## WeaponCompact 场景预加载
var weapon_compact_scene: PackedScene = preload("res://scenes/UI/components/weapon_compact.tscn")

## 常量
const WEAPON_SPAWN_CHANCE := 0.25
const FLIP_ANIMATION_DELAY := 0.08
const SHOP_SLOTS := 4 # 商店槽位数量
const costbywave_multiA := 0.5 # 波次价格修正系数a
const costbywave_multiB := 0.05 # 波次价格修正系数b

## 当前显示的升级选项（最多4个）
var current_upgrades: Array[UpgradeData] = []
var refresh_cost: int = 2  # 刷新费用，每次x2
var base_refresh_cost: int = 2  # 基础刷新费用

## 锁定的升级选项（key: 位置索引 0-3, value: UpgradeData）
var locked_upgrades: Dictionary = {}

## 武器相关参数
var new_weapon_cost: int = 5 # 新武器基础价格
#var green_weapon_multi: int = 2 #绿色武器价格倍率

## 缓存的管理器引用
var _cached_weapons_manager: Node = null
var _cached_wave_manager: Node = null
var _cached_player: Node = null

## ===== 商店 hover 高亮：武器紧凑组件缓存 =====
var _weapon_compacts: Array[WeaponCompact] = []
var _shop_weapons: Array[BaseWeapon] = []
var _currently_hovered_upgrade: UpgradeData = null
var _hovered_option_ui: UpgradeOption = null

## ===== 联网模式：待处理的购买/刷新请求 =====
var _pending_purchase_upgrade: UpgradeData = null
var _pending_purchase_cost: int = 0
var _pending_refresh: bool = false

## ===== 服务器：商店倒计时显示（复用商店页面，隐藏全部内容）=====
var _server_countdown_label: Label = null

func _is_server_shop_mode() -> bool:
	return GameMain.current_mode_id == "online" and NetworkManager.is_server()

func _extract_int_from_text(text: String) -> int:
	var digits := ""
	for i in text.length():
		var ch := text[i]
		if ch >= "0" and ch <= "9":
			digits += ch
	if digits == "":
		return -1
	return int(digits)

func _show_server_countdown_only() -> void:
	# 隐藏商店所有交互/内容，只保留一个居中倒计时
	if upgrade_container: upgrade_container.visible = false
	if refresh_button: refresh_button.visible = false
	if close_button: close_button.visible = false
	if refresh_label: refresh_label.visible = false
	if weapon_container: weapon_container.visible = false
	if player_portrait: player_portrait.visible = false
	if player_name_label: player_name_label.visible = false
	
	var hp_bar := get_node_or_null("TitleSection/HPBar") as Control
	if hp_bar:
		hp_bar.visible = false
	var weapon_list_label := get_node_or_null("BottomSection/WeaponListLabel") as Control
	if weapon_list_label:
		weapon_list_label.visible = false
	
	if _server_countdown_label == null:
		_server_countdown_label = Label.new()
		_server_countdown_label.name = "ServerShopCountdownLabel"
		_server_countdown_label.process_mode = Node.PROCESS_MODE_ALWAYS
		_server_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_server_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_server_countdown_label.add_theme_font_size_override("font_size", 48)
		_server_countdown_label.add_theme_color_override("font_color", Color(1, 1, 1))
		_server_countdown_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		_server_countdown_label.add_theme_constant_override("shadow_offset_x", 2)
		_server_countdown_label.add_theme_constant_override("shadow_offset_y", 2)
		_server_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_server_countdown_label)
		
		# 屏幕居中：用 CENTER anchor + offsets，避免位置跑偏
		_server_countdown_label.set_anchors_preset(Control.PRESET_CENTER)
		_server_countdown_label.offset_left = -320
		_server_countdown_label.offset_top = -70
		_server_countdown_label.offset_right = 320
		_server_countdown_label.offset_bottom = 70
	
	_server_countdown_label.visible = true
	_server_countdown_label.text = "商店倒计时：--"

## 信号
signal upgrade_purchased(upgrade: UpgradeData)
signal shop_closed()

## 升级选项预制（用于UI显示）
var upgrade_option_scene = preload("res://scenes/UI/upgrade_option.tscn")

## 获取本地玩家（兼容单机和联网模式）
func _get_local_player() -> Node:
	if GameMain.current_mode_id == "online":
		return NetworkPlayerManager.local_player
	else:
		return get_tree().get_first_node_in_group("player")

## 获取本地玩家的武器管理器（兼容单机和联网模式）
func _get_local_weapons_manager() -> Node:
	if GameMain.current_mode_id == "online":
		var local_player = NetworkPlayerManager.local_player
		if local_player:
			return local_player.get_node_or_null("now_weapons")
		return null
	else:
		var weapons_manager = get_tree().get_first_node_in_group("weapons_manager")
		if not weapons_manager:
			weapons_manager = get_tree().get_first_node_in_group("weapons")
		return weapons_manager

## 计算带波次修正的价格
## 公式：最终价格 = floor(基础价格 + 波数 + (基础价格 × 0.1 × 波数))
## 静态版本，供 UpgradeOption 等外部调用
static func calculate_wave_adjusted_cost(base_cost: int) -> int:
	var wave_number: int = 0
	
	# 尝试获取场景树
	var main_loop = Engine.get_main_loop()
	if main_loop and main_loop is SceneTree:
		var scene_tree = main_loop as SceneTree
		
		# 尝试获取波次管理器
		var wave_system = scene_tree.get_first_node_in_group("wave_system")
		if not wave_system:
			wave_system = scene_tree.get_first_node_in_group("wave_manager")
		
		if wave_system and "current_wave" in wave_system:
			wave_number = wave_system.current_wave
	
	# 应用公式：最终价格 = floor(基础价格 + 波数 + (基础价格 × 0.1 × 波数))
	var adjusted_cost = float(base_cost) + float(wave_number)*costbywave_multiA + (float(base_cost) * costbywave_multiB * float(wave_number))
	return int(floor(adjusted_cost))

## 实例方法版本的价格计算（可利用缓存）
func _calculate_cost_instance(base_cost: int) -> int:
	var wave_number: int = _get_current_wave()
	var adjusted_cost = float(base_cost) + float(wave_number) + (float(base_cost) * 0.1 * float(wave_number))
	return int(floor(adjusted_cost))

func _ready() -> void:
	# 确保在组中
	if not is_in_group("upgrade_shop"):
		add_to_group("upgrade_shop")
		print("升级商店手动添加到组: upgrade_shop")
	
	# 等待一帧确保所有@onready变量都已初始化
	await get_tree().process_frame
	
	# 验证@onready变量是否初始化
	if not upgrade_container:
		push_error("upgrade_container 未初始化！")
		upgrade_container = get_node_or_null("%UpgradeContainer")
		if upgrade_container:
			print("手动找到 upgrade_container: ", upgrade_container.get_path())
		else:
			push_error("无法找到 UpgradeContainer 节点！")
	
	if refresh_button:
		refresh_button.pressed.connect(_on_refresh_button_pressed)
	else:
		refresh_button = get_node_or_null("%RefreshButton")
		if refresh_button:
			refresh_button.pressed.connect(_on_refresh_button_pressed)
	
	if close_button:
		close_button.pressed.connect(_on_close_button_pressed)
	else:
		close_button = get_node_or_null("%CloseButton")
		if close_button:
			close_button.pressed.connect(_on_close_button_pressed)
	
	# 缓存管理器引用
	_cache_managers()
	
	# 监听钥匙变化信号
	if GameMain.has_signal("gold_changed"):
		if not GameMain.gold_changed.is_connected(_on_gold_changed):
			GameMain.gold_changed.connect(_on_gold_changed)
	
	_update_refresh_cost_display()
	
	# 初始化玩家信息显示
	_initialize_player_info()
	
	hide()  # 初始隐藏
	print("升级商店 _ready() 完成，节点路径: ", get_path(), " 组: ", get_groups())
	print("upgrade_container: ", upgrade_container, " refresh_button: ", refresh_button, " close_button: ", close_button)
	print("weapon_container: ", weapon_container)

func _process(_delta: float) -> void:
	# 兜底：通过 viewport 获取当前鼠标悬停的控件，避免被子控件遮挡导致 hover 信号不触发
	if not visible:
		return
	_poll_hovered_upgrade_option()

func _poll_hovered_upgrade_option() -> void:
	var hovered: Control = get_viewport().gui_get_hovered_control()
	var option: UpgradeOption = null
	
	while hovered:
		if hovered is UpgradeOption:
			option = hovered as UpgradeOption
			break
		hovered = hovered.get_parent() as Control
	
	# 只认 UpgradeContainer 里的选项，避免误判到其他 UI
	if option and upgrade_container:
		var p: Node = option
		var is_child_of_container := false
		while p:
			if p == upgrade_container:
				is_child_of_container = true
				break
			p = p.get_parent()
		if not is_child_of_container:
			option = null
	
	var hovered_upgrade: UpgradeData = option.upgrade_data if option else null
	
	# 关键：UpgradeOption 节点会复用，购买/刷新后 upgrade_data 会变，但节点不变
	# 因此需要同时比较 upgrade_data 引用，确保能及时刷新箭头
	if option == _hovered_option_ui and hovered_upgrade == _currently_hovered_upgrade:
		return
	
	_hovered_option_ui = option
	if _hovered_option_ui and hovered_upgrade:
		_on_upgrade_option_hover_entered(hovered_upgrade, _hovered_option_ui.position_index)
	else:
		_on_upgrade_option_hover_exited(-1)

## 缓存常用的管理器引用
func _cache_managers() -> void:
	var tree = get_tree()
	
	# 缓存 WeaponsManager
	if not _cached_weapons_manager:
		_cached_weapons_manager = tree.get_first_node_in_group("weapons_manager")
		if not _cached_weapons_manager:
			_cached_weapons_manager = tree.get_first_node_in_group("weapons")
	
	# 缓存 WaveManager
	if not _cached_wave_manager:
		_cached_wave_manager = tree.get_first_node_in_group("wave_system")
		if not _cached_wave_manager:
			_cached_wave_manager = tree.get_first_node_in_group("wave_manager")
	
	# 缓存 Player
	if not _cached_player:
		_cached_player = tree.get_first_node_in_group("player")


## 获取玩家当前钥匙数量（兼容单机和联网模式）
func _get_player_gold() -> int:
	if GameMain.current_mode_id == "online":
		# 联网模式：从本地玩家获取
		var local_player = NetworkPlayerManager.local_player
		if local_player:
			var gold = local_player.get("gold")
			if gold != null:
				return gold
		return 0
	else:
		# 单机模式：从 GameMain 获取
		return GameMain.gold


## 扣除玩家钥匙（兼容单机和联网模式）
func _remove_player_gold(amount: int) -> bool:
	if GameMain.current_mode_id == "online":
		# 联网模式：从本地玩家扣除
		var local_player = NetworkPlayerManager.local_player
		if local_player and local_player.gold >= amount:
			local_player.gold -= amount
			return true
		return false
	else:
		# 单机模式：从 GameMain 扣除
		return GameMain.remove_gold(amount)


## 打开商店
func open_shop() -> void:
	print("升级商店 open_shop() 被调用")
	
	# 在线模式：服务器端复用商店页面，但只显示倒计时
	if _is_server_shop_mode():
		process_mode = Node.PROCESS_MODE_ALWAYS
		show()
		visible = true
		set_process(true)
		set_process_input(false)
		_show_server_countdown_only()
		return
	
	# 确保所有@onready变量都已初始化
	if not is_inside_tree():
		await get_tree().process_frame
	
	# 刷新缓存（以防场景重载）
	_cache_managers()
	
	# 设置进程模式为始终处理（即使在暂停时）
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# 显示商店（必须在暂停后）
	show()
	visible = true
	
	# 确保节点可见
	set_process(true)
	set_process_input(true)
	
	# 重置刷新费用
	refresh_cost = base_refresh_cost
	_update_refresh_cost_display()
	
	# 更新玩家信息
	_initialize_player_info()
	
	# 确保容器可用
	if not upgrade_container:
		upgrade_container = get_node_or_null("%UpgradeContainer")
		if upgrade_container:
			print("在open_shop中找到upgrade_container: ", upgrade_container.get_path())
		else:
			push_error("无法找到 UpgradeContainer 节点！")
			return
	
	print("容器子节点数（生成前）: ", upgrade_container.get_child_count())
	
	# 生成初始升级选项（异步，需要等待）
	# 注：Boss 玩家只会生成血量和移动速度相关的升级选项
	await generate_upgrades()
	
	# 更新武器列表显示
	_update_weapon_list()
	_clear_weapon_signups()
	
	print("升级商店已打开，选项数量: ", current_upgrades.size())

## 检查本地玩家是否是 Boss
func _is_local_player_boss() -> bool:
	if GameMain.current_mode_id != "online":
		return false

	var local_player = NetworkPlayerManager.local_player
	if not local_player:
		return false

	var role = local_player.get("player_role_id")
	return role == NetworkPlayerManager.ROLE_BOSS

## Boss 可购买的升级类型（对Boss有效的非武器类型）
## Boss的冲刺攻击和技能攻击现已使用属性系统，支持异常效果触发
const BOSS_ALLOWED_UPGRADE_TYPES := [
	UpgradeData.UpgradeType.HP_MAX,           # HP上限
	UpgradeData.UpgradeType.MOVE_SPEED,       # 移动速度
	UpgradeData.UpgradeType.HEAL_HP,          # 恢复HP
	UpgradeData.UpgradeType.DAMAGE_REDUCTION, # 防御力/减伤
	UpgradeData.UpgradeType.LUCK,             # 幸运（影响商店品质）
	UpgradeData.UpgradeType.KEY_PICKUP_RANGE, # 钥匙拾取范围
	UpgradeData.UpgradeType.STATUS_CHANCE,    # 异常触发概率（影响冲刺减速、技能燃烧）
	UpgradeData.UpgradeType.STATUS_DURATION,  # 异常持续时间
	UpgradeData.UpgradeType.STATUS_EFFECT,    # 异常效果强度
]

## 检查升级类型是否对 Boss 可用
func _is_upgrade_allowed_for_boss(upgrade_type: int) -> bool:
	return upgrade_type in BOSS_ALLOWED_UPGRADE_TYPES

## 检查当前玩家是否可以生成武器升级
func _can_generate_weapon_upgrade() -> bool:
	# Boss 玩家不能生成武器升级
	if _is_local_player_boss():
		return false
	return true

## 关闭商店
func close_shop() -> void:
	_clear_weapon_signups()
	_currently_hovered_upgrade = null
	# 重置关闭按钮显示
	if close_button_label:
		close_button_label.text = "关闭"
	if _server_countdown_label:
		_server_countdown_label.visible = false
	hide()
	shop_closed.emit()

## 设置关闭按钮启用状态（联网模式下始终禁用手动关闭）
func set_close_button_enabled(enabled: bool) -> void:
	# 联网模式下忽略此设置，始终不允许手动关闭
	if GameMain.current_mode_id == "online":
		return
	if close_button:
		close_button.disabled = not enabled

## 更新关闭按钮文字（用于显示倒计时）
func update_close_button_text(text: String) -> void:
	# 服务器：把倒计时显示在屏幕中间（复用 shop 页面）
	if _is_server_shop_mode():
		_show_server_countdown_only()
		var n := _extract_int_from_text(text)
		if n >= 0:
			_server_countdown_label.text = "商店倒计时：%d" % n
		else:
			_server_countdown_label.text = text
		return
	if close_button_label:
		close_button_label.text = text

## 生成升级选项（4个）
## 优化版：复用现有节点，消除闪烁
## 原理：
## 1. 先播放现有非锁定选项的翻出动画（Flip Out）
## 2. 更新数据，将锁定选项恢复，并生成新选项填补空位
## 3. 复用UI节点，只更新数据，避免 queue_free 造成的空帧闪烁
## 4. 对非锁定选项，设置 scale.x=0 后更新数据，再播放翻入动画（Flip In）
var _is_generating: bool = false  # 防止并发调用
func generate_upgrades() -> void:
	# 防止并发调用
	if _is_generating:
		return
	_is_generating = true

	# 选项会刷新/复用，先清空当前高亮，避免残留
	_clear_weapon_signups()
	_currently_hovered_upgrade = null

	# 等待一帧确保 queue_free() 的节点被完全删除
	await get_tree().process_frame

	# 1. 播放翻出动画（只对非锁定的选项）
	# 锁定的选项保持原样，非锁定的翻出并隐藏（scale.x -> 0）
	await _play_flip_out_animations()
	
	# 2. 准备新的数据列表
	var new_upgrades_list: Array[UpgradeData] = []
	new_upgrades_list.resize(SHOP_SLOTS)
	
	# 恢复锁定的升级到对应位置
	for position_index in range(SHOP_SLOTS):
		if locked_upgrades.has(position_index):
			var locked_upgrade = locked_upgrades[position_index]
			# 创建升级数据的副本（保留锁定价格）
			var upgrade_copy = locked_upgrade.clone()
			new_upgrades_list[position_index] = upgrade_copy
			# 同步更新字典中的引用为新副本
			locked_upgrades[position_index] = upgrade_copy
			# print("[UpgradeShop] 恢复锁定升级到位置 %d: %s" % [position_index, upgrade_copy.name])
	
	# 生成新升级填补空位
	for position_index in range(SHOP_SLOTS):
		if new_upgrades_list[position_index] != null:
			continue # 已被锁定占位
			
		var new_upgrade = _generate_single_upgrade(new_upgrades_list)
		if new_upgrade:
			new_upgrades_list[position_index] = new_upgrade
		else:
			print("[UpgradeShop] 警告: 无法生成位置 %d 的升级选项" % position_index)

	# --- 保底逻辑检查：确保至少有1个属性和1个武器（如果可能） ---
	# 仅在全刷新时执行，局部补货不执行
	# Boss 玩家跳过武器保底检查
	var can_weapon = _can_generate_weapon_upgrade()
	
	# 统计现有数量（包括锁定和新生成的）
	var weapon_count = 0
	var attribute_count = 0
	var non_locked_indices: Array[int] = []
	
	for i in range(SHOP_SLOTS):
		if new_upgrades_list[i]:
			if new_upgrades_list[i].upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON or new_upgrades_list[i].upgrade_type == UpgradeData.UpgradeType.WEAPON_LEVEL_UP:
				weapon_count += 1
			else:
				attribute_count += 1
		
		if not locked_upgrades.has(i):
			non_locked_indices.append(i)
	
	# 如果全是武器（且有非锁定槽位），强制将一个非锁定槽位改为属性
	if weapon_count == SHOP_SLOTS and non_locked_indices.size() > 0:
		var target_index = non_locked_indices.pick_random()
		var new_attribute = _generate_attribute_upgrade_force(new_upgrades_list)
		if new_attribute:
			new_upgrades_list[target_index] = new_attribute
			# 重新固定价格
			new_attribute.current_price = _calculate_cost_instance(new_attribute.actual_cost)
			print("[UpgradeShop] 保底触发：位置 %d 强制从武器改为属性" % target_index)
	
	# 如果全是属性（且有非锁定槽位，且允许生成武器），强制将一个非锁定槽位改为武器
	# 注意：如果已满6武器且满级，可能无法生成武器，此时跳过
	# Boss 玩家不触发武器保底
	elif attribute_count == SHOP_SLOTS and non_locked_indices.size() > 0 and can_weapon:
		# 尝试生成一个武器
		var dummy_salt = randi()
		var new_weapon = _generate_weapon_upgrade(new_upgrades_list, dummy_salt)
		if new_weapon:
			var target_index = non_locked_indices.pick_random()
			new_upgrades_list[target_index] = new_weapon
			# 重新固定价格
			new_weapon.current_price = _calculate_cost_instance(new_weapon.actual_cost)
			print("[UpgradeShop] 保底触发：位置 %d 强制从属性改为武器" % target_index)
	
	# 更新当前数据
	current_upgrades = new_upgrades_list
	
	# 3. 同步UI节点（对象池模式）
	# 确保容器中至少有4个节点
	if not upgrade_option_scene:
		push_error("升级选项场景未加载！")
		return
		
	while upgrade_container.get_child_count() < SHOP_SLOTS:
		var option_ui = upgrade_option_scene.instantiate() as UpgradeOption
		upgrade_container.add_child(option_ui)
		# 初始连接信号
		if option_ui.has_signal("purchased"):
			option_ui.purchased.connect(_on_upgrade_purchased)
		if option_ui.has_signal("lock_state_changed"):
			option_ui.lock_state_changed.connect(_on_upgrade_lock_state_changed)
		if option_ui.has_signal("hover_entered"):
			option_ui.hover_entered.connect(_on_upgrade_option_hover_entered)
		if option_ui.has_signal("hover_exited"):
			option_ui.hover_exited.connect(_on_upgrade_option_hover_exited)
	
	# 清理多余节点
	while upgrade_container.get_child_count() > SHOP_SLOTS:
		var child = upgrade_container.get_child(upgrade_container.get_child_count() - 1)
		child.queue_free()
	
	# 确保所有新添加的节点已进入树
	if not is_inside_tree():
		await get_tree().process_frame
	
	# 4. 更新每个节点的数据和状态
	for i in range(SHOP_SLOTS):
		var option_ui = upgrade_container.get_child(i) as UpgradeOption
		var slot_upgrade = new_upgrades_list[i]
		var is_locked = locked_upgrades.has(i)
		
		option_ui.position_index = i
		
		# 显式确保节点可见
		option_ui.visible = true
		
		# 更新数据
		# 注意：对于非锁定节点，此时 scale.x 应为 0（由 _play_flip_out_animations 设置）
		# 所以即使数据变了，玩家也暂时看不到，直到翻入动画播放
		if slot_upgrade:
			option_ui.set_upgrade_data(slot_upgrade)
		
		option_ui.set_lock_state(is_locked)
		
		if is_locked:
			# 锁定的节点：确保完全显示
			option_ui.scale.x = 1.0
			option_ui.modulate = Color.WHITE
		else:
			# 非锁定的节点：确保初始隐藏，然后播放翻入动画
			option_ui.scale.x = 0.0
			option_ui.modulate = Color(0.5, 0.5, 0.5) # 初始暗色
			
			var delay = i * FLIP_ANIMATION_DELAY
			if option_ui.has_method("play_flip_in_animation"):
				option_ui.play_flip_in_animation(delay)

	_is_generating = false
	print("[UpgradeShop] 升级选项生成完成 (优化模式), 数量: %d" % SHOP_SLOTS)

## 创建升级选项UI实例（辅助函数，仅用于补充节点）
## skip_animation: 如果为true，不设置初始 scale.x = 0（锁定的选项直接显示）
func _create_upgrade_option_instance(upgrade: UpgradeData, position_index: int, skip_animation: bool = false) -> UpgradeOption:
	if not upgrade_option_scene:
		return null
	
	var option_ui = upgrade_option_scene.instantiate() as UpgradeOption
	option_ui.position_index = position_index
	if not skip_animation:
		option_ui.scale.x = 0.0
	
	if option_ui.has_signal("purchased"):
		option_ui.purchased.connect(_on_upgrade_purchased)
	if option_ui.has_signal("lock_state_changed"):
		option_ui.lock_state_changed.connect(_on_upgrade_lock_state_changed)
	
	option_ui.upgrade_data = upgrade
	return option_ui

## 播放所有非锁定选项的翻出动画
func _play_flip_out_animations() -> void:
	if not upgrade_container:
		return
	
	var tweens: Array[Tween] = []
	
	# 遍历所有现有选项
	for child in upgrade_container.get_children():
		if child is UpgradeOption:
			var option = child as UpgradeOption
			# 只有非锁定的才播放翻出动画
			if not option.is_locked:
				if option.has_method("play_flip_out_animation"):
					var tween = option.play_flip_out_animation()
					if tween:
						tweens.append(tween)
	
	# 等待动画完成
	if tweens.size() > 0:
		await tweens[0].finished

## 清除所有升级选项
# 优化版不再频繁调用此函数，保留以备不时之需
func _clear_upgrades() -> void:
	if upgrade_container:
		for child in upgrade_container.get_children():
			child.queue_free()
	current_upgrades.clear()

## 处理锁定状态变化
func _on_upgrade_lock_state_changed(upgrade: UpgradeData, is_locked: bool, position_index: int) -> void:
	if is_locked:
		# 锁定：保存当前价格
		# 优先使用 current_price，如果没有则实时计算
		var adjusted_cost = upgrade.current_price if upgrade.current_price > 0 else _calculate_cost_instance(upgrade.actual_cost)
		upgrade.locked_cost = adjusted_cost
		locked_upgrades[position_index] = upgrade
		print("[UpgradeShop] 锁定升级: %s 在位置 %d, 锁定价格: %d" % [upgrade.name, position_index, adjusted_cost])
	else:
		# 解锁：清除锁定价格
		upgrade.locked_cost = -1
		if locked_upgrades.has(position_index):
			locked_upgrades.erase(position_index)
			print("[UpgradeShop] 解锁升级: %s 在位置 %d" % [upgrade.name, position_index])

## 复制升级数据（用于锁定升级的恢复）
func _duplicate_upgrade_data(source: UpgradeData) -> UpgradeData:
	return source.clone()

## 判断两个升级是否相同
func _is_same_upgrade(upgrade1: UpgradeData, upgrade2: UpgradeData) -> bool:
	if upgrade1.upgrade_type != upgrade2.upgrade_type:
		return false
	
	# 武器类型：比较weapon_id
	if upgrade1.upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON:
		return upgrade1.weapon_id == upgrade2.weapon_id
	
	# 武器升级：weapon_id + 目标等级（quality）共同决定唯一性
	# 这样同种武器不同等级（如 1->2 和 2->3）可以同时出现在商店里
	if upgrade1.upgrade_type == UpgradeData.UpgradeType.WEAPON_LEVEL_UP:
		return upgrade1.weapon_id == upgrade2.weapon_id and upgrade1.quality == upgrade2.quality
	
	# 属性类型：需要类型、品质、价格都相同才算重复
	# 这样允许不同品质的相同属性类型共存（例如：攻击速度+3%白色 和 攻击速度+5%绿色）
	if upgrade1.quality != upgrade2.quality:
		return false
	
	# 进一步检查价格，确保完全相同
	if upgrade1.actual_cost != upgrade2.actual_cost:
		return false
	
	return true

## 购买升级
## 优化版：只刷新被购买的那一个格子
## 流程：
## 1. 扣除钥匙
## 2. 移除锁定状态（如果已锁定）
## 3. 应用升级效果（武器升级需等待异步加载）
## 4. 局部刷新 UI（Flip Out -> 生成新数据 -> Flip In）
func _on_upgrade_purchased(upgrade: UpgradeData) -> void:
	# 如果有锁定价格，使用锁定价格；否则使用固定的 current_price
	var adjusted_cost: int
	if upgrade.locked_cost >= 0:
		adjusted_cost = upgrade.locked_cost
	elif upgrade.current_price > 0:
		adjusted_cost = upgrade.current_price
	else:
		# 兼容性保底：如果 current_price 未设置，才实时计算
		adjusted_cost = _calculate_cost_instance(upgrade.actual_cost)
	
	# 联网模式：发送购买请求到服务器
	if GameMain.current_mode_id == "online":
		_request_purchase_online(upgrade, adjusted_cost)
		return
	
	# 单机模式：直接处理
	_process_purchase_locally(upgrade, adjusted_cost)


## 联网模式：发送购买请求到服务器
func _request_purchase_online(upgrade: UpgradeData, cost: int) -> void:
	# 客户端先检查钥匙是否足够（仅用于 UI 反馈，服务器会再次验证）
	var player_gold = _get_player_gold()
	if player_gold < cost:
		print("[UpgradeShop] 客户端检查: 钥匙不足！需要 %d，当前 %d" % [cost, player_gold])
		return
	
	# 保存待处理的购买信息
	_pending_purchase_upgrade = upgrade
	_pending_purchase_cost = cost
	
	# 准备发送给服务器的数据
	var weapon_id = upgrade.weapon_id if upgrade.weapon_id else ""
	var custom_value = upgrade.custom_value if upgrade.custom_value else 0.0
	var stats_data = {}
	if upgrade.stats_modifier:
		# 使用 CombatStats 的实际属性名
		stats_data = {
			"max_hp": upgrade.stats_modifier.max_hp,
			"defense": upgrade.stats_modifier.defense,
			"speed": upgrade.stats_modifier.speed,
			"crit_chance": upgrade.stats_modifier.crit_chance,
			"crit_damage": upgrade.stats_modifier.crit_damage,
			"key_pickup_range_mult": upgrade.stats_modifier.key_pickup_range_mult,
			"global_damage_add": upgrade.stats_modifier.global_damage_add,
			"global_damage_mult": upgrade.stats_modifier.global_damage_mult,
			"global_attack_speed_add": upgrade.stats_modifier.global_attack_speed_add,
			"global_attack_speed_mult": upgrade.stats_modifier.global_attack_speed_mult,
		}
	
	print("[UpgradeShop] 发送购买请求: %s, cost=%d" % [upgrade.name, cost])
	
	# 发送 RPC 请求到服务器
	NetworkPlayerManager.rpc_id(1, "rpc_request_purchase", 
		upgrade.upgrade_type, upgrade.name, cost, weapon_id, custom_value, stats_data)


## 联网模式：服务器购买结果回调
func on_purchase_result(success: bool, message: String) -> void:
	print("[UpgradeShop] 收到购买结果: success=%s, message=%s" % [success, message])
	
	if not _pending_purchase_upgrade:
		print("[UpgradeShop] 警告: 没有待处理的购买请求")
		return
	
	var upgrade = _pending_purchase_upgrade
	var cost = _pending_purchase_cost
	_pending_purchase_upgrade = null
	_pending_purchase_cost = 0
	
	if success:
		# 购买成功：更新 UI（服务器已扣除钥匙并应用效果）
		_update_refresh_cost_display()
		print("[UpgradeShop] 购买成功: %s，消耗 %d 钥匙" % [upgrade.name, cost])
		
		# 移除锁定状态
		for position_index in locked_upgrades.keys():
			var locked_upgrade = locked_upgrades[position_index]
			if _is_same_upgrade(locked_upgrade, upgrade):
				locked_upgrades.erase(position_index)
				break
		
		# 武器升级需要刷新武器列表
		if upgrade.upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON or upgrade.upgrade_type == UpgradeData.UpgradeType.WEAPON_LEVEL_UP:
			await get_tree().process_frame
			_update_weapon_list()
		
		upgrade_purchased.emit(upgrade)
		
		# 刷新被购买的格子
		await _refresh_purchased_slot(upgrade)
	else:
		print("[UpgradeShop] 购买失败: %s" % message)


## 刷新被购买的格子
func _refresh_purchased_slot(upgrade: UpgradeData) -> void:
	# 找到被购买选项的UI节点和位置
	var purchased_option: UpgradeOption = null
	var purchased_index: int = -1
	
	for child in upgrade_container.get_children():
		if child is UpgradeOption:
			var option = child as UpgradeOption
			if option.upgrade_data == upgrade:
				purchased_option = option
				purchased_index = option.position_index
				break
	
	# 局部刷新逻辑：只针对被购买的那个格子
	if purchased_option:
		if purchased_option.has_method("play_flip_out_animation"):
			await purchased_option.play_flip_out_animation().finished
		
		if purchased_index >= 0 and purchased_index < current_upgrades.size():
			current_upgrades[purchased_index] = null
			var new_upgrade = _generate_single_upgrade(current_upgrades)
			
			if new_upgrade:
				current_upgrades[purchased_index] = new_upgrade
				purchased_option.set_upgrade_data(new_upgrade)
				purchased_option.position_index = purchased_index
				purchased_option.set_lock_state(false)
				purchased_option.visible = true
				
				if purchased_option.has_method("play_flip_in_animation"):
					purchased_option.play_flip_in_animation(0.0)
			else:
				purchased_option.visible = false
	
	if _currently_hovered_upgrade:
		_apply_weapon_signups_for_upgrade(_currently_hovered_upgrade)


## 单机模式：本地处理购买
func _process_purchase_locally(upgrade: UpgradeData, adjusted_cost: int) -> void:
	# 检查钥匙是否足够
	var player_gold = _get_player_gold()
	if player_gold < adjusted_cost:
		print("钥匙不足！需要 %d，当前 %d" % [adjusted_cost, player_gold])
		return
	
	# 扣除钥匙
	_remove_player_gold(adjusted_cost)
	_update_refresh_cost_display()
	
	print("[UpgradeShop] 购买升级: %s，消耗 %d 钥匙（基础价格 %d）" % [upgrade.name, adjusted_cost, upgrade.actual_cost])
	
	# 移除锁定状态
	for position_index in locked_upgrades.keys():
		var locked_upgrade = locked_upgrades[position_index]
		if _is_same_upgrade(locked_upgrade, upgrade):
			locked_upgrades.erase(position_index)
			print("[UpgradeShop] 已购买的升级从锁定列表中移除: %s" % upgrade.name)
			break
	
	# 应用升级效果
	if upgrade.upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON or upgrade.upgrade_type == UpgradeData.UpgradeType.WEAPON_LEVEL_UP:
		await UpgradeManager.apply_upgrade(upgrade, get_tree())
		await get_tree().process_frame
		_update_weapon_list()
	else:
		UpgradeManager.apply_upgrade(upgrade, get_tree())
	
	upgrade_purchased.emit(upgrade)
	
	# 刷新被购买的格子
	await _refresh_purchased_slot(upgrade)

## 刷新按钮
func _on_refresh_button_pressed() -> void:
	var player_gold = _get_player_gold()
	if player_gold < refresh_cost:
		print("[UpgradeShop] 刷新失败: 钥匙不足！需要 %d，当前 %d" % [refresh_cost, player_gold])
		return
	
	# 联网模式：发送刷新请求到服务器
	if GameMain.current_mode_id == "online":
		_request_refresh_online()
		return
	
	# 单机模式：直接处理
	_process_refresh_locally()


## 联网模式：发送刷新请求到服务器
func _request_refresh_online() -> void:
	_pending_refresh = true
	print("[UpgradeShop] 发送刷新请求: cost=%d" % refresh_cost)
	NetworkPlayerManager.rpc_id(1, "rpc_request_shop_refresh", refresh_cost)


## 联网模式：服务器刷新结果回调
func on_refresh_result(success: bool, message: String) -> void:
	print("[UpgradeShop] 收到刷新结果: success=%s, message=%s" % [success, message])
	
	if not _pending_refresh:
		print("[UpgradeShop] 警告: 没有待处理的刷新请求")
		return
	
	_pending_refresh = false
	
	if success:
		# 刷新成功：更新 UI（服务器已扣除钥匙）
		refresh_cost *= 2  # 下次刷新费用x2
		_update_refresh_cost_display()
		_clear_weapon_signups()
		_currently_hovered_upgrade = null
		await generate_upgrades()
	else:
		print("[UpgradeShop] 刷新失败: %s" % message)


## 单机模式：本地处理刷新
func _process_refresh_locally() -> void:
	_remove_player_gold(refresh_cost)
	refresh_cost *= 2  # 下次刷新费用x2
	_update_refresh_cost_display()
	_clear_weapon_signups()
	_currently_hovered_upgrade = null
	await generate_upgrades()

## 关闭按钮
func _on_close_button_pressed() -> void:
	# 联网模式：不允许手动关闭，必须等待倒计时结束
	if GameMain.current_mode_id == "online":
		print("[UpgradeShop] 联网模式下不允许手动关闭商店，请等待倒计时结束")
		return
	close_shop()

## 监听钥匙变化
func _on_gold_changed(_new_amount: int, _change: int) -> void:
	_update_refresh_cost_display()
	_update_all_buy_buttons()


## 更新刷新费用显示
func _update_refresh_cost_display() -> void:
	# 更新 refreshLabel 中的费用数字
	if refresh_label:
		refresh_label.text = "刷新  [img=20]res://assets/items/bbc-nkey.png[/img] %d" % refresh_cost
	
	# 检查钥匙是否足够刷新，不足时禁用按钮（兼容单机和联网模式）
	if refresh_button:
		var player_gold = _get_player_gold()
		var can_afford = player_gold >= refresh_cost
		refresh_button.disabled = not can_afford
	
	# 更新所有升级选项的购买按钮状态
	_update_all_buy_buttons()


## 更新所有升级选项的购买按钮状态
func _update_all_buy_buttons() -> void:
	if not upgrade_container:
		return
	for child in upgrade_container.get_children():
		if child is UpgradeOption:
			child._update_buy_button()

## 初始化玩家信息显示
func _initialize_player_info() -> void:
	# 获取职业ID（联网模式从 local_player 获取，单机模式从 GameMain 获取）
	var class_id = ""
	var player_display_name = ""
	
	if GameMain.current_mode_id == "online" and NetworkPlayerManager.local_player:
		# 联网模式：从本地玩家获取职业ID和显示名称
		class_id = NetworkPlayerManager.local_player.player_class_id
		player_display_name = NetworkPlayerManager.local_player.display_name
	else:
		# 单机模式：从 GameMain 获取
		class_id = GameMain.selected_class_id
	
	# 显示职业头像
	if class_id != "" and player_portrait:
		var class_data = ClassDatabase.get_class_data(class_id)
		if class_data and class_data.portrait:
			player_portrait.texture = class_data.portrait
	
	# 显示玩家名字
	if player_name_label:
		if player_display_name != "":
			# 联网模式：使用玩家显示名称
			player_name_label.text = player_display_name
		else:
			# 单机模式：从存档读取
			var saved_name = SaveManager.get_player_name()
			if saved_name != "":
				player_name_label.text = saved_name
			else:
				player_name_label.text = "玩家"

## 更新武器列表显示（使用 WeaponCompact 组件）
func _update_weapon_list() -> void:
	# 确保武器容器存在
	if not weapon_container:
		weapon_container = get_node_or_null("%WeaponContainer")
		if not weapon_container:
			print("[UpgradeShop] 无法找到武器容器")
			return
	
	# 清空现有武器显示
	for child in weapon_container.get_children():
		child.queue_free()
	_weapon_compacts.clear()
	_shop_weapons.clear()
	
	# 获取武器管理器（联网模式使用本地玩家的武器管理器）
	var weapons_manager = _get_local_weapons_manager()
	if not weapons_manager:
		# 回退到缓存的方式
		if not _cached_weapons_manager:
			_cached_weapons_manager = get_tree().get_first_node_in_group("weapons_manager")
			if not _cached_weapons_manager:
				_cached_weapons_manager = get_tree().get_first_node_in_group("weapons")
		weapons_manager = _cached_weapons_manager
	
	if not weapons_manager:
		print("[UpgradeShop] 无法找到武器管理器")
		return
	
	# 更新缓存
	_cached_weapons_manager = weapons_manager
	
	# 获取所有武器（按获得顺序）
	# 注意：get_all_weapons() 返回的是未类型化 Array，需要转换为 Array[BaseWeapon]
	var weapons_raw: Array = weapons_manager.get_all_weapons()
	var weapons: Array[BaseWeapon] = []
	for w in weapons_raw:
		if w is BaseWeapon:
			weapons.append(w)
	_shop_weapons = weapons
	# print("[UpgradeShop] 找到武器管理器，武器数量: ", weapons.size())
	
	# 显示6个武器槽位
	for i in range(6):
		if not weapon_compact_scene:
			continue
			
		var compact = weapon_compact_scene.instantiate()
		weapon_container.add_child(compact)
		if compact is WeaponCompact:
			_weapon_compacts.append(compact)
		
		if i < weapons.size() and weapons[i] is BaseWeapon:
			# 有武器 - 显示武器信息
			var weapon = weapons[i] as BaseWeapon
			var weapon_data = weapon.weapon_data
			var weapon_level = weapon.weapon_level
			
			if weapon_data:
				if compact.has_method("setup_weapon_from_data"):
					compact.setup_weapon_from_data(weapon_data, weapon_level)
				elif compact.has_method("setup_weapon"):
					compact.setup_weapon(weapon_data.weapon_id, weapon_level)
				
				# 绑定 weapon_id（WeaponData 本身不存 id，这里通过 name 反查）
				var wid = _get_weapon_id_from_data(weapon_data)
				if compact.has_method("set_weapon_id"):
					compact.set_weapon_id(wid)
		else:
			# 空槽位 - 显示"空缺"，不显示图片
			if compact.has_method("set_weapon_name"):
				compact.set_weapon_name("空缺")
			if compact.has_method("set_weapon_texture"):
				compact.set_weapon_texture(null)  # 不显示图片
			if compact.has_method("set_quality_level"):
				compact.set_quality_level(1)  # 灰色背景
			if compact.has_method("set_weapon_id"):
				compact.set_weapon_id("")
	
	print("[UpgradeShop] 武器列表已更新，当前武器数量: ", weapons.size())

	# 武器列表重建后，如果仍在 hover 某个升级，恢复高亮
	if _currently_hovered_upgrade:
		_apply_weapon_signups_for_upgrade(_currently_hovered_upgrade)

## ===== Hover 逻辑：高亮受益武器 =====

func _on_upgrade_option_hover_entered(upgrade: UpgradeData, _position_index: int) -> void:
	_currently_hovered_upgrade = upgrade
	_apply_weapon_signups_for_upgrade(upgrade)

func _on_upgrade_option_hover_exited(_position_index: int) -> void:
	_currently_hovered_upgrade = null
	_clear_weapon_signups()

func _clear_weapon_signups() -> void:
	for c in _weapon_compacts:
		if c and is_instance_valid(c) and c.has_method("set_sign_up_active"):
			c.set_sign_up_active(false)

func _apply_weapon_signups_for_upgrade(upgrade: UpgradeData) -> void:
	_clear_weapon_signups()
	if not upgrade:
		return
	
	var benefited_indices = _compute_benefited_weapon_indices(upgrade)
	for idx in benefited_indices:
		if idx >= 0 and idx < _weapon_compacts.size():
			var c = _weapon_compacts[idx]
			if c and is_instance_valid(c) and c.has_method("set_sign_up_active"):
				c.set_sign_up_active(true)

func _compute_benefited_weapon_indices(upgrade: UpgradeData) -> Array[int]:
	var result: Array[int] = []
	if not upgrade:
		return result
	
	# 4) 武器升级类：指向对应武器
	if upgrade.upgrade_type == UpgradeData.UpgradeType.WEAPON_LEVEL_UP and upgrade.weapon_id != "":
		# 规则：只指向“会被升级的那一把”
		# - 若持有多把同种类且品质不一致：根据 upgrade.quality（目标等级）匹配当前等级 = quality-1
		# - 若多把同品质：选择排序靠前的那一把
		var desired_current_level = clamp(upgrade.quality - 1, 1, 4)
		for i in range(min(_shop_weapons.size(), 6)):
			var w = _shop_weapons[i]
			if not (w is BaseWeapon) or not w.weapon_data:
				continue
			if _get_weapon_id_from_data(w.weapon_data) != upgrade.weapon_id:
				continue
			if w.weapon_level == desired_current_level:
				result.append(i)
				return result
		
		# 兜底：找不到精确匹配时，指向同种类里“低于目标等级的最高等级”且靠前优先
		var best_idx := -1
		var best_level := -1
		for i in range(min(_shop_weapons.size(), 6)):
			var w = _shop_weapons[i]
			if not (w is BaseWeapon) or not w.weapon_data:
				continue
			if _get_weapon_id_from_data(w.weapon_data) != upgrade.weapon_id:
				continue
			if w.weapon_level < upgrade.quality and w.weapon_level > best_level and w.weapon_level < 5:
				best_level = w.weapon_level
				best_idx = i
		if best_idx >= 0:
			result.append(best_idx)
		return result
	
	# 其他类型：根据 stats_modifier 判断（全局/结算/异常）
	var stats: CombatStats = upgrade.stats_modifier
	if not stats:
		return result
	
	# 1) 全局攻击 / 全局攻速：所有武器都加（只要这类字段发生变化就全亮）
	var affects_all := false
	if not is_equal_approx(stats.global_damage_add, 0.0) or not is_equal_approx(stats.global_damage_mult, 1.0):
		affects_all = true
	if not is_equal_approx(stats.global_attack_speed_add, 0.0) or not is_equal_approx(stats.global_attack_speed_mult, 1.0):
		affects_all = true
	
	if affects_all:
		for i in range(min(_shop_weapons.size(), 6)):
			if _shop_weapons[i] is BaseWeapon:
				result.append(i)
		return result

	# 精确匹配：逐武器判断该 stats 是否真的会影响它（参考 Behavior/Calculator 的真实使用逻辑）
	for i in range(min(_shop_weapons.size(), 6)):
		var w = _shop_weapons[i]
		if not (w is BaseWeapon) or not w.weapon_data:
			continue
		if _weapon_benefits_from_stats(w.weapon_data, stats):
			result.append(i)

	return result

func _stats_affects_melee(stats: CombatStats) -> bool:
	return (not is_equal_approx(stats.melee_damage_add, 0.0)
		or not is_equal_approx(stats.melee_damage_mult, 1.0)
		or not is_equal_approx(stats.melee_speed_add, 0.0)
		or not is_equal_approx(stats.melee_speed_mult, 1.0)
		or not is_equal_approx(stats.melee_range_add, 0.0)
		or not is_equal_approx(stats.melee_range_mult, 1.0)
		or not is_equal_approx(stats.melee_knockback_add, 0.0)
		or not is_equal_approx(stats.melee_knockback_mult, 1.0))

func _stats_affects_ranged(stats: CombatStats) -> bool:
	return (not is_equal_approx(stats.ranged_damage_add, 0.0)
		or not is_equal_approx(stats.ranged_damage_mult, 1.0)
		or not is_equal_approx(stats.ranged_speed_add, 0.0)
		or not is_equal_approx(stats.ranged_speed_mult, 1.0)
		or not is_equal_approx(stats.ranged_range_add, 0.0)
		or not is_equal_approx(stats.ranged_range_mult, 1.0)
		or stats.ranged_penetration != 0
		or stats.ranged_projectile_count != 0)

func _stats_affects_magic(stats: CombatStats) -> bool:
	return (not is_equal_approx(stats.magic_damage_add, 0.0)
		or not is_equal_approx(stats.magic_damage_mult, 1.0)
		or not is_equal_approx(stats.magic_speed_add, 0.0)
		or not is_equal_approx(stats.magic_speed_mult, 1.0)
		or not is_equal_approx(stats.magic_range_add, 0.0)
		or not is_equal_approx(stats.magic_range_mult, 1.0)
		or not is_equal_approx(stats.magic_explosion_radius_add, 0.0)
		or not is_equal_approx(stats.magic_explosion_radius_mult, 1.0))

func _stats_affects_status(stats: CombatStats) -> bool:
	# 只要涉及异常强度/概率/持续时间，或直接加异常触发/吸血，就认为是异常类
	if not is_equal_approx(stats.lifesteal_percent, 0.0):
		return true
	if not is_equal_approx(stats.burn_chance, 0.0) or not is_equal_approx(stats.freeze_chance, 0.0) or not is_equal_approx(stats.poison_chance, 0.0):
		return true
	if not is_equal_approx(stats.status_duration_mult, 1.0) or not is_equal_approx(stats.status_effect_mult, 1.0) or not is_equal_approx(stats.status_chance_mult, 1.0):
		return true
	return false

func _weapon_has_special_effect(weapon_data: WeaponData, required_types: Array[String]) -> bool:
	if not weapon_data:
		return false
	if weapon_data.special_effects.is_empty():
		return false
	
	# 没指定类型：只要有特殊效果就算
	if required_types.is_empty():
		return true
	
	for e in weapon_data.special_effects:
		if e is Dictionary:
			var t = e.get("type", "")
			if required_types.has(t):
				return true
	return false

## 精确判定：某个 stats_modifier 是否会对该 weapon_data 产生实际影响
func _weapon_benefits_from_stats(weapon_data: WeaponData, stats: CombatStats) -> bool:
	if not weapon_data or not stats:
		return false
	
	var calc_type = weapon_data.calculation_type
	var behavior_type = weapon_data.behavior_type
	var params: Dictionary = weapon_data.get_behavior_params()
	
	# ===== 结算类型相关（Damage/AttackSpeed/Range 走 CalculationType）=====
	# 近战结算
	if calc_type == WeaponData.CalculationType.MELEE:
		if not is_equal_approx(stats.melee_damage_add, 0.0) or not is_equal_approx(stats.melee_damage_mult, 1.0):
			return true
		if not is_equal_approx(stats.melee_speed_add, 0.0) or not is_equal_approx(stats.melee_speed_mult, 1.0):
			return true
		if not is_equal_approx(stats.melee_range_add, 0.0) or not is_equal_approx(stats.melee_range_mult, 1.0):
			return true
	
	# 远程结算
	if calc_type == WeaponData.CalculationType.RANGED:
		if not is_equal_approx(stats.ranged_damage_add, 0.0) or not is_equal_approx(stats.ranged_damage_mult, 1.0):
			return true
		if not is_equal_approx(stats.ranged_speed_add, 0.0) or not is_equal_approx(stats.ranged_speed_mult, 1.0):
			return true
		if not is_equal_approx(stats.ranged_range_add, 0.0) or not is_equal_approx(stats.ranged_range_mult, 1.0):
			return true
	
	# 魔法结算
	if calc_type == WeaponData.CalculationType.MAGIC:
		if not is_equal_approx(stats.magic_damage_add, 0.0) or not is_equal_approx(stats.magic_damage_mult, 1.0):
			return true
		if not is_equal_approx(stats.magic_speed_add, 0.0) or not is_equal_approx(stats.magic_speed_mult, 1.0):
			return true
		if not is_equal_approx(stats.magic_range_add, 0.0) or not is_equal_approx(stats.magic_range_mult, 1.0):
			return true
	
	# ===== 行为相关（某些属性只被特定 Behavior 读取）=====
	# 远程穿透/额外弹药：只在 RangedBehavior 中读取（与 calculation_type 无关）
	if behavior_type == WeaponData.BehaviorType.RANGED:
		if stats.ranged_penetration != 0:
			return true
		if stats.ranged_projectile_count != 0:
			return true
		
		# 击退：子弹系统支持 knockback_force 时，远程武器也会受击退加成影响
		# 生效条件：该武器使用的子弹配置 knockback_force > 0
		if (not is_equal_approx(stats.melee_knockback_add, 0.0) or not is_equal_approx(stats.melee_knockback_mult, 1.0)):
			var bullet_id = String(params.get("bullet_id", "normal_bullet"))
			var bullet_data = BulletDatabase.get_bullet(bullet_id)
			if bullet_data and bullet_data.knockback_force > 0.0:
				return true
	
	# 近战击退：只在 MeleeBehavior 中读取，且要求武器本身有基础击退力度
	if behavior_type == WeaponData.BehaviorType.MELEE:
		var base_knockback = float(params.get("knockback_force", 0.0))
		if base_knockback > 0.0:
			if not is_equal_approx(stats.melee_knockback_add, 0.0) or not is_equal_approx(stats.melee_knockback_mult, 1.0):
				return true
	
	# 魔法爆炸范围：只在 MagicBehavior 中读取，且要求武器本身启用爆炸并且有半径
	if behavior_type == WeaponData.BehaviorType.MAGIC:
		var has_explosion = bool(params.get("has_explosion_damage", true))
		var base_radius = float(params.get("explosion_radius", 0.0))
		if has_explosion and base_radius > 0.0:
			if not is_equal_approx(stats.magic_explosion_radius_add, 0.0) or not is_equal_approx(stats.magic_explosion_radius_mult, 1.0):
				return true
	
	# ===== 异常/特殊效果：只对带 special_effects 的武器生效 =====
	if _stats_affects_status(stats):
		var required_effect_types: Array[String] = []
		# 如果升级直接改了某个异常触发率，只命中对应异常的武器
		if not is_equal_approx(stats.burn_chance, 0.0):
			required_effect_types.append("burn")
		if not is_equal_approx(stats.freeze_chance, 0.0):
			required_effect_types.append("freeze")
		if not is_equal_approx(stats.poison_chance, 0.0):
			required_effect_types.append("poison")
		
		# 进一步精细化：
		# - 异常持续时间：只影响有“持续时间”的异常（burn/bleed/freeze/slow/poison），不影响 lifesteal
		# - 异常概率/异常效果强度：影响所有带特殊效果的武器（lifesteal 也会受 status_chance_mult / status_effect_mult 影响）
		if required_effect_types.is_empty() and not is_equal_approx(stats.status_duration_mult, 1.0):
			required_effect_types = ["burn", "bleed", "freeze", "slow", "poison"]
		
		if _weapon_has_special_effect(weapon_data, required_effect_types):
			return true
	
	return false

## WeaponData 本身不存 weapon_id，这里通过 weapon_name 反查 WeaponDatabase 的 key
func _get_weapon_id_from_data(weapon_data: WeaponData) -> String:
	if not weapon_data:
		return ""
	for wid in WeaponDatabase.get_all_weapon_ids():
		var d = WeaponDatabase.get_weapon(wid)
		if d and d.weapon_name == weapon_data.weapon_name:
			return wid
	return ""

## ========== 新的商店刷新系统 ==========

## 获取当前波数
func _get_current_wave() -> int:
	if _cached_wave_manager and "current_wave" in _cached_wave_manager:
		return _cached_wave_manager.current_wave
	
	# Fallback attempt
	var wave_manager = get_tree().get_first_node_in_group("wave_system")
	if wave_manager and "current_wave" in wave_manager:
		_cached_wave_manager = wave_manager
		return wave_manager.current_wave
		
	return 1

## 获取玩家幸运值
func _get_player_luck() -> float:
	if _cached_player and _cached_player.current_class:
		return _cached_player.current_class.luck
	return 0.0

## 统计商店中的new weapon数量（包括锁定的）
func _count_new_weapons_in_shop() -> int:
	var count = 0
	
	# 统计当前显示的
	for upgrade in current_upgrades:
		if upgrade != null and upgrade.upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON:
			count += 1
	
	# 统计锁定的
	for position_index in locked_upgrades.keys():
		var locked_upgrade = locked_upgrades[position_index]
		if locked_upgrade.upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON:
			count += 1
	
	return count

## 根据幸运值和波数计算品质
## 返回品质等级（1-5对应WHITE-ORANGE）
func _get_quality_by_luck(luck_value: float, current_wave: int) -> int:
	# 品质配置表
	var quality_configs = [
		# [品质, 最低波数, 基础概率, 每波增加, 最高概率]
		[UpgradeData.Quality.ORANGE, 10, 0.0, 0.23, 8.0],    # Tier 5
		[UpgradeData.Quality.PURPLE, 8, 0.0, 2.0, 25.0],     # Tier 4
		[UpgradeData.Quality.BLUE, 4, 0.0, 6.0, 60.0],       # Tier 3
		[UpgradeData.Quality.GREEN, 2, 0.0, 8.0, 80.0],      # Tier 2
		[UpgradeData.Quality.WHITE, 1, 100.0, 0.0, 100.0],   # Tier 1
	]
	
	# 幸运值转换为百分比倍率（luck值 / 100）
	var luck_multiplier = 1.0 + (luck_value / 100.0)
	
	# 计算每个品质的概率
	var quality_probabilities = []
	for config in quality_configs:
		var quality = config[0]
		var min_wave = config[1]
		var base_prob = config[2]
		var wave_increase = config[3]
		var max_prob = config[4]
		
		# 如果当前波数低于最低出现波数，概率为0
		if current_wave < min_wave:
			quality_probabilities.append([quality, 0.0])
			continue
		
		# 计算概率：((每波增加 × (当前波数 - 最低波数 - 1)) + 基础概率) × 幸运倍率
		var wave_bonus = wave_increase * float(current_wave - min_wave - 1)
		var probability = (base_prob + wave_bonus) * luck_multiplier
		
		# 限制在最高概率
		probability = min(probability, max_prob)
		
		quality_probabilities.append([quality, probability])
	
	# 从高到低检查品质，使用递减概率
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(Time.get_ticks_msec() + current_wave + int(luck_value))
	var roll = rng.randf_range(0.0, 100.0)
	
	var accumulated_prob = 0.0
	for i in range(quality_probabilities.size()):
		var quality = quality_probabilities[i][0]
		var prob = quality_probabilities[i][1]
		
		# 计算实际可用概率（从剩余概率中分配）
		var available_prob = 100.0 - accumulated_prob
		var actual_prob = min(prob, available_prob)
		
		if roll < accumulated_prob + actual_prob:
			return quality
		
		accumulated_prob += actual_prob
	
	# 保底返回白色
	return UpgradeData.Quality.WHITE

## 生成单个upgrade选项（独立判定）
func _generate_single_upgrade(existing_upgrades: Array[UpgradeData]) -> UpgradeData:
	var rng = RandomNumberGenerator.new()
	var current_wave = _get_current_wave()
	rng.seed = hash(Time.get_ticks_msec() + current_wave + existing_upgrades.size())
	
	# Boss 玩家只能生成属性升级，不能生成武器
	var can_weapon = _can_generate_weapon_upgrade()
	
	# 决定生成类型
	var is_weapon = false
	
	# 移除旧的强制保底逻辑，回归纯随机（受基础概率限制）
	# 只有在全刷新 generate_upgrades 中才进行整体平衡检查
	if can_weapon:
		is_weapon = rng.randf() < WEAPON_SPAWN_CHANCE
	else:
		is_weapon = false  # Boss 玩家强制不生成武器
	
	var attempts = 0
	var max_attempts = 50
	
	while attempts < max_attempts:
		attempts += 1
		
		# Generate a unique salt for this attempt to prevent same-seed RNG in fast loops
		var attempt_salt = randi()
		
		var upgrade: UpgradeData = null
		
		if is_weapon and can_weapon:
			upgrade = _generate_weapon_upgrade(existing_upgrades, attempt_salt)
		else:
			# 获取当前波数和幸运值
			var luck_value = _get_player_luck()
			
			# 根据幸运值决定品质
			var quality = _get_quality_by_luck(luck_value, current_wave)
			
			upgrade = _generate_attribute_upgrade(quality, attempt_salt)
			# 如果指定品质生成失败（可能该品质没有对应升级），尝试保底使用白色品质
			if upgrade == null:
				upgrade = _generate_attribute_upgrade(UpgradeData.Quality.WHITE, attempt_salt)
		
		if upgrade == null:
			# 如果生成失败，尝试切换类型
			if is_weapon and can_weapon:
				# 武器生成失败，尝试生成属性
				var fallback_luck_value = _get_player_luck()
				var fallback_quality = _get_quality_by_luck(fallback_luck_value, current_wave)
				upgrade = _generate_attribute_upgrade(fallback_quality, attempt_salt)
				# 保底策略
				if upgrade == null:
					upgrade = _generate_attribute_upgrade(UpgradeData.Quality.WHITE, attempt_salt)
			elif can_weapon:
				# 属性生成失败，尝试生成武器（只有非Boss玩家可以）
				upgrade = _generate_weapon_upgrade(existing_upgrades, attempt_salt)
			
			if upgrade == null:
				continue
		
		# 检查是否与已有选项重复
		var is_duplicate = false
		for existing in existing_upgrades:
			if existing == null:
				continue
			if _is_same_upgrade(existing, upgrade):
				is_duplicate = true
				break
		
		if not is_duplicate:
			# 计算并固定当前波次的最终售价
			# 这样即使后续 current_wave 发生变化（如进入下一关），该商品价格也保持不变
			upgrade.current_price = _calculate_cost_instance(upgrade.actual_cost)
			return upgrade
	
	# print("[UpgradeShop] 警告: 尝试 %d 次后仍无法生成不重复的升级" % max_attempts)
	return null

## 辅助函数：强制生成属性（用于保底）
func _generate_attribute_upgrade_force(existing_upgrades: Array[UpgradeData]) -> UpgradeData:
	var current_wave = _get_current_wave()
	var luck_value = _get_player_luck()
	var quality = _get_quality_by_luck(luck_value, current_wave)
	
	var attempts = 0
	while attempts < 10:
		attempts += 1
		var salt = randi()
		var upgrade = _generate_attribute_upgrade(quality, salt)
		if not upgrade:
			upgrade = _generate_attribute_upgrade(UpgradeData.Quality.WHITE, salt)
			
		if upgrade:
			var is_duplicate = false
			for existing in existing_upgrades:
				if existing == null: continue
				if _is_same_upgrade(existing, upgrade):
					is_duplicate = true
					break
			if not is_duplicate:
				return upgrade
	return null

## 生成武器相关upgrade
func _generate_weapon_upgrade(existing_upgrades: Array[UpgradeData], salt: int = 0) -> UpgradeData:
	# 使用缓存的 WeaponsManager
	if not _cached_weapons_manager:
		_cached_weapons_manager = get_tree().get_first_node_in_group("weapons_manager")
		if not _cached_weapons_manager:
			_cached_weapons_manager = get_tree().get_first_node_in_group("weapons")
	
	if not _cached_weapons_manager:
		return null
	
	var weapon_count = 0
	if _cached_weapons_manager.has_method("get_weapon_count"):
		weapon_count = _cached_weapons_manager.get_weapon_count()
	
	# 统计商店中的new weapon数量（包括锁定的和当前生成的）
	var new_weapon_count_in_shop = 0
	for up in existing_upgrades:
		if up and up.upgrade_type == UpgradeData.UpgradeType.NEW_WEAPON:
			new_weapon_count_in_shop += 1
	
	# 检查是否可以生成新武器
	var can_generate_new_weapon = (weapon_count + new_weapon_count_in_shop) < 6
	
	# 检查是否所有武器都满级
	var all_weapons_max_level = false
	if _cached_weapons_manager.has_method("has_all_weapons_max_level"):
		all_weapons_max_level = _cached_weapons_manager.has_all_weapons_max_level()
	
	var rng = RandomNumberGenerator.new()
	var current_wave = _get_current_wave()
	rng.seed = hash(Time.get_ticks_msec() + current_wave + weapon_count + salt)
	
	# 决定生成NEW_WEAPON还是WEAPON_LEVEL_UP
	var can_level_up = weapon_count > 0 and not all_weapons_max_level
	
	if not can_generate_new_weapon and not can_level_up:
		# 既不能生成新武器，也不能升级武器
		return null
	
	if can_generate_new_weapon and not can_level_up:
		# 只能生成新武器
		return _generate_new_weapon_upgrade(salt)
	
	if not can_generate_new_weapon and can_level_up:
		# 只能升级武器
		return _generate_weapon_level_up_upgrade(_cached_weapons_manager, salt)
	
	# 两者都可以，随机选择
	if rng.randf() < 0.5:
		return _generate_new_weapon_upgrade(salt)
	else:
		return _generate_weapon_level_up_upgrade(_cached_weapons_manager, salt)

## 生成新武器upgrade
func _generate_new_weapon_upgrade(salt: int = 0) -> UpgradeData:
	var all_weapon_ids = WeaponDatabase.get_all_weapon_ids()
	if all_weapon_ids.is_empty():
		return null
	
	var rng = RandomNumberGenerator.new()
	var current_wave = _get_current_wave()
	rng.seed = hash(Time.get_ticks_msec() + current_wave + all_weapon_ids.size() + salt)
	var weapon_id = all_weapon_ids[rng.randi_range(0, all_weapon_ids.size() - 1)]
	
	var weapon_data = WeaponDatabase.get_weapon(weapon_id)
	var upgrade = UpgradeData.new(
		UpgradeData.UpgradeType.NEW_WEAPON,
		"新武器: " + weapon_data.weapon_name,
		new_weapon_cost,
		weapon_data.texture_path,
		weapon_id
	)
	upgrade.description = weapon_data.description
	upgrade.quality = UpgradeData.Quality.WHITE
	upgrade.actual_cost = upgrade.cost
	
	return upgrade

## 生成武器升级upgrade
func _generate_weapon_level_up_upgrade(weapons_manager, salt: int = 0) -> UpgradeData:
	if not weapons_manager.has_method("get_upgradeable_weapon_types"):
		return null
	
	# 新规则：按 (weapon_id, 当前等级) 作为可升级目标
	# 这样当玩家持有同种武器不同品质/等级时，对应的多个升级选项都有概率出现
	var targets: Array = []
	if weapons_manager.has_method("get_upgradeable_weapon_targets"):
		targets = weapons_manager.get_upgradeable_weapon_targets()
	
	# 兼容旧接口：退化为只按 weapon_id
	var weapon_id: String = ""
	var current_level: int = 1
	if not targets.is_empty():
		var rng = RandomNumberGenerator.new()
		var current_wave = _get_current_wave()
		rng.seed = hash(Time.get_ticks_msec() + current_wave + targets.size() + salt)
		var t = targets[rng.randi_range(0, targets.size() - 1)]
		weapon_id = String(t.get("weapon_id", ""))
		current_level = int(t.get("current_level", 1))
	else:
		var upgradeable_weapons = weapons_manager.get_upgradeable_weapon_types()
		if upgradeable_weapons.is_empty():
			return null
		var rng = RandomNumberGenerator.new()
		var current_wave = _get_current_wave()
		rng.seed = hash(Time.get_ticks_msec() + current_wave + upgradeable_weapons.size() + salt)
		weapon_id = upgradeable_weapons[rng.randi_range(0, upgradeable_weapons.size() - 1)]
		# 旧逻辑：默认选择“应该升级哪一把”的武器来决定 current_level
		var chosen_weapon = null
		if weapons_manager.has_method("get_best_weapon_for_level_up"):
			chosen_weapon = weapons_manager.get_best_weapon_for_level_up(weapon_id)
		elif weapons_manager.has_method("get_lowest_level_weapon_of_type"):
			chosen_weapon = weapons_manager.get_lowest_level_weapon_of_type(weapon_id)
		if not chosen_weapon:
			return null
		current_level = int(chosen_weapon.weapon_level)
	
	var weapon_data = WeaponDatabase.get_weapon(weapon_id)
	
	var target_level = current_level + 1  # 目标等级
	
	var upgrade = UpgradeData.new(
		UpgradeData.UpgradeType.WEAPON_LEVEL_UP,
		"升级: " + weapon_data.weapon_name,
		new_weapon_cost,
		weapon_data.texture_path,
		weapon_id
	)
	upgrade.description = "提升武器等级 (当前等级: %d)" % current_level
	
	# 动态设置品质和价格（品质 = 目标等级）
	upgrade.quality = target_level
	upgrade.base_cost = new_weapon_cost
	upgrade.calculate_weapon_upgrade_cost()
	
	return upgrade

## 生成指定品质的属性upgrade
func _generate_attribute_upgrade(quality: int, salt: int = 0) -> UpgradeData:
	# 获取所有upgrade ID
	var all_upgrade_ids = UpgradeDatabase.get_all_upgrade_ids()
	
	# Boss 玩家只能生成允许的升级类型
	var is_boss = _is_local_player_boss()
	
	# 筛选出指定品质的upgrade，同时收集权重信息（跳过权重<=0的升级）
	var quality_upgrades: Array[Dictionary] = []  # [{id: String, weight: int}]
	var total_weight: int = 0
	
	for upgrade_id in all_upgrade_ids:
		var base_upgrade_data = UpgradeDatabase.get_upgrade_data(upgrade_id)
		if not base_upgrade_data or base_upgrade_data.quality != quality:
			continue
		
		# Boss 玩家：检查升级类型是否允许
		if is_boss and not _is_upgrade_allowed_for_boss(base_upgrade_data.upgrade_type):
			continue
		
		# 检查权重：权重必须>0才会出现在商店中（0、负数都会被跳过）
		# 注意：int类型不能为null，未设置时默认值为0，也会被跳过
		var weight = base_upgrade_data.weight
		if weight <= 0:
			continue
		
		quality_upgrades.append({"id": upgrade_id, "weight": weight})
		total_weight += weight
	
	if quality_upgrades.is_empty():
		# print("[UpgradeShop] 警告: 没有品质为 %s 的升级选项" % UpgradeData.get_quality_name(quality))
		return null
	
	# 使用加权随机选择
	var current_wave = _get_current_wave()
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(Time.get_ticks_msec() + current_wave + quality_upgrades.size() + salt)
	
	# 生成0到总权重之间的随机数
	var random_value = rng.randi_range(0, total_weight - 1)

	
	# 累加权重，找到对应的升级
	var accumulated_weight = 0
	var selected_upgrade_id: String = ""
	for upgrade_info in quality_upgrades:
		accumulated_weight += upgrade_info["weight"]
		if random_value < accumulated_weight:
			selected_upgrade_id = upgrade_info["id"]
			break
	
	# 如果由于浮点误差没有选中，选择最后一个
	if selected_upgrade_id == "":
		selected_upgrade_id = quality_upgrades[-1]["id"]
	
	var selected_upgrade_data = UpgradeDatabase.get_upgrade_data(selected_upgrade_id)
	
	# 创建副本
	var upgrade_copy = UpgradeData.new(
		selected_upgrade_data.upgrade_type,
		selected_upgrade_data.name,
		selected_upgrade_data.cost,
		selected_upgrade_data.icon_path,
		selected_upgrade_data.weapon_id
	)
	upgrade_copy.description = selected_upgrade_data.description
	upgrade_copy.quality = selected_upgrade_data.quality
	upgrade_copy.actual_cost = selected_upgrade_data.actual_cost
	upgrade_copy.weight = selected_upgrade_data.weight
	upgrade_copy.attribute_changes = selected_upgrade_data.attribute_changes.duplicate(true)
	
	# ⭐ 关键：复制stats_modifier（新属性系统）
	if selected_upgrade_data.stats_modifier:
		upgrade_copy.stats_modifier = selected_upgrade_data.stats_modifier.clone()
	
	# 复制自定义值
	upgrade_copy.custom_value = selected_upgrade_data.custom_value
	
	return upgrade_copy
