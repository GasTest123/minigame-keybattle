extends CanvasLayer

## 联网模式游戏内HUD界面
## 负责显示所有玩家的状态信息

# ===== 资源（尽量复用模式1风格）=====
const KEY_NORMAL_TEX: Texture2D = preload("res://assets/items/nkey.png")
const KEY_MASTER_TEX: Texture2D = preload("res://assets/items/mkey.png")
const HP_FILL_STYLE: StyleBox = preload("res://scenes/UI/class_state_bar_fill.tres")
const BOSS_HP_BAR_SCENE: PackedScene = preload("res://scenes/UI/components/BOSS_HPbar.tscn")

# ===== 玩家条目尺寸（统一在这里调）=====
const PLAYER_ENTRY_WIDTH: int = 510
const PLAYER_ENTRY_HEIGHT: int = 96
const PLAYER_ICON_SIZE: int = 80
const HP_LABEL_WIDTH: int = 60
const HBOX_SEP: int = 10
const HP_SEP: int = 5
const REMOTE_HP_RATIO: float = 0.8
const PLAYER_LIST_SEP: int = 8
const HP_BAR_HEIGHT: int = 24
const HP_BG_SKEW_X: float = 0.4

# UI组件引用
@onready var players_container: VBoxContainer = $PlayersPanel/MarginContainer/VBoxContainer/PlayersContainer
@onready var server_info_label: Label = $ServerInfoLabel
@onready var wave_label: Label = %WaveLabel
@onready var skill_icon: Control = %SkillIcon
@onready var dash_ui: Control = %Dash_ui
@onready var gold_counter: ResourceCounter = $gold_counter
@onready var master_key_counter: ResourceCounter = $master_key_counter
@onready var damage_flash: DamageFlash = %DamageFlash
@onready var warning_ui: Control = $WarningUi
@onready var warning_animation: AnimationPlayer = $WarningUi/AnimationPlayer
@onready var boss_bar_container: VBoxContainer = null  # 动态创建/复用：BOSSbar_root/VBoxContainer

# 玩家信息项场景（动态创建）
var player_info_items: Dictionary = {}  # peer_id -> Control

# 波次管理器引用
var wave_manager_ref = null

# 调试用名字列表
var _debug_label: Label = null

# 角色提示面板
var _role_hint_panel: PanelContainer = null

# Impostor 叛变提示框（屏幕下方）
var _betrayal_hint_panel: PanelContainer = null

# 更新间隔
var _update_timer: float = 0.0
const UPDATE_INTERVAL: float = 0.1  # 每0.1秒更新一次

# ===== BOSS 血条管理（联网版）=====
var _boss_bars_by_enemy: Dictionary = {}  # enemy_instance_id -> BossHPBar
var _boss_scan_timer: float = 0.0
const BOSS_SCAN_INTERVAL: float = 0.2

# 初始化完成标志
var _initialized: bool = false

## UI 视角下的“当前玩家”：
## - 客户端：本地 peer_id
## - 服务器：当前追踪的 peer_id（Tab 切换），追踪为空则回退到第一个有效玩家
func _get_ui_current_peer_id() -> int:
	if not NetworkManager.is_server():
		return int(NetworkManager.get_peer_id())
	
	var fid := 0
	if NetworkPlayerManager.has_method("get_following_peer_id"):
		fid = int(NetworkPlayerManager.get_following_peer_id())
	if fid > 0 and NetworkPlayerManager.players.has(fid):
		return fid
	
	# 回退：选择最小的有效 peer_id
	var peer_ids: Array = NetworkPlayerManager.players.keys()
	peer_ids.sort()
	for pid in peer_ids:
		if int(pid) > 0:
			return int(pid)
	return 0


func _is_ui_current_player(peer_id: int) -> bool:
	return peer_id == _get_ui_current_peer_id()

func _ready() -> void:
	# 设置 HUD
	_setup_hud()

	# 创建调试标签
	_create_debug_label()
	
	# 创建角色提示面板
	_create_role_hint_panel()
	
	# 创建叛变提示框
	_create_betrayal_hint_panel()

	# 创建/复用 BOSS 血条容器（联网版场景默认没有放节点）
	_setup_boss_bar_ui()
	
	# 连接叛变信号
	NetworkPlayerManager.impostor_betrayal_triggered.connect(_on_impostor_betrayed)
	
	# 延迟初始化，等待玩家加载
	await get_tree().create_timer(0.5).timeout
	_sync_players_panel_size()
	_init_player_list()
	
	# 显示服务器信息
	_update_server_info()
	
	# 更新角色提示
	_update_role_hint()
	
	# 更新叛变提示
	_update_betrayal_hint()
	
	# 设置波次显示
	_setup_wave_display()
	
	_initialized = true


## 播放波次开始警告动画（与单机版 game_ui.gd 保持一致）
func _play_wave_begin_animation() -> void:
	if warning_animation and is_instance_valid(warning_animation):
		warning_animation.stop()
		warning_animation.play("wave_begin")


## 同步左上角面板尺寸：宽度跟随条目宽度，高度跟随当前玩家数量（避免裁切导致“看起来没变化”）
func _sync_players_panel_size() -> void:
	var panel := get_node_or_null("PlayersPanel") as Control
	if not panel:
		return
	
	# 宽度 = 1 个条目的宽度
	panel.offset_right = panel.offset_left + float(PLAYER_ENTRY_WIDTH)
	
	# 高度：按真实内容的最小高度来（避免因为字体/图标变大导致被裁切）
	var content_h := 0.0
	if players_container:
		content_h = float(players_container.get_combined_minimum_size().y)
	# 空列表时至少给一个条目的高度
	var target_h := maxf(float(PLAYER_ENTRY_HEIGHT), content_h)
	panel.offset_bottom = panel.offset_top + target_h


func _process(delta: float) -> void:
	if not _initialized:
		return
	
	_update_timer += delta
	if _update_timer >= UPDATE_INTERVAL:
		_update_timer = 0.0
		_update_all_players()
		_update_role_hint()  # 定期更新角色提示
		_update_betrayal_hint()  # 定期更新叛变提示
		_update_wave_display()  # 更新波次显示

	# BOSS 血条：不需要每 0.1s 扫一次，单独节流
	_boss_scan_timer += delta
	if _boss_scan_timer >= BOSS_SCAN_INTERVAL:
		_boss_scan_timer = 0.0
		_scan_and_update_boss_bars()


## 设置 HUD
func _setup_hud() -> void:
	if not NetworkManager.is_server():
		# 商店开启时会 tree.paused = true（WaveSystemOnline），
		# 为了让右上角钥匙/HP闪红等 HUD 在暂停期间也能刷新，UI 必须可在暂停时继续运行。
		process_mode = Node.PROCESS_MODE_ALWAYS

	# 服务器端：右上角钥匙 UI 不应压在商店之上（商店自身 z_index=100）
	# 通过降低 z_index，使其和其它 HUD 一致：被商店遮挡。
	if NetworkManager.is_server():
		if gold_counter:
			gold_counter.z_index = 95
		if master_key_counter:
			master_key_counter.z_index = 95


## 创建/复用 BOSS 血条容器（与单机版节点结构一致：BOSSbar_root/VBoxContainer）
func _setup_boss_bar_ui() -> void:
	# 优先复用场景中已有节点（如果未来直接放进 tscn）
	var existing_root := get_node_or_null("BOSSbar_root") as Control
	if not existing_root:
		existing_root = Control.new()
		existing_root.name = "BOSSbar_root"
		add_child(existing_root)
		
		# 位置/锚点：屏幕顶部居中；显式给足尺寸，避免动态创建时“看不见/0 尺寸”
		existing_root.set_anchors_preset(Control.PRESET_CENTER_TOP)
		existing_root.anchor_left = 0.5
		existing_root.anchor_right = 0.5
		existing_root.anchor_top = 0.0
		existing_root.anchor_bottom = 0.0
		# 宽度 600，高度 120
		existing_root.offset_left = -300.0
		existing_root.offset_right = 300.0
		existing_root.offset_top = 90.0
		existing_root.offset_bottom = 210.0
		existing_root.grow_horizontal = Control.GROW_DIRECTION_BOTH
		existing_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var vb := existing_root.get_node_or_null("VBoxContainer") as VBoxContainer
	if not vb:
		vb = VBoxContainer.new()
		vb.name = "VBoxContainer"
		existing_root.add_child(vb)
		# 让容器铺满父节点，避免因为默认 0/40 尺寸导致子节点被挤没
		vb.set_anchors_preset(Control.PRESET_FULL_RECT)
		vb.offset_left = 0.0
		vb.offset_top = 0.0
		vb.offset_right = 0.0
		vb.offset_bottom = 0.0
		vb.add_theme_constant_override("separation", 10)
	
	boss_bar_container = vb


## 扫描场景中的敌人实例，发现 BOSS 则创建血条；死亡/销毁则自动清理
func _scan_and_update_boss_bars() -> void:
	if not boss_bar_container or not is_instance_valid(boss_bar_container):
		return
	if not BOSS_HP_BAR_SCENE:
		return
	
	# 清理无效引用
	var to_erase: Array[int] = []
	for k in _boss_bars_by_enemy.keys():
		var bar = _boss_bars_by_enemy.get(k)
		if not bar or not is_instance_valid(bar):
			to_erase.append(int(k))
	for k in to_erase:
		_boss_bars_by_enemy.erase(k)
	
	# 发现新的 Boss
	var enemies: Array = get_tree().get_nodes_in_group("enemy")
	for e in enemies:
		if not e or not is_instance_valid(e):
			continue
		# 兼容：Enemy / EnemyOnline
		if not ("enemy_id" in e):
			continue
		var eid := str(e.enemy_id)
		if eid.is_empty():
			continue
		if not BossHPBar.is_boss_enemy(eid):
			continue
		
		var inst_id := int(e.get_instance_id())
		if _boss_bars_by_enemy.has(inst_id):
			continue
		
		_create_boss_hp_bar(e, eid)


## 创建 BOSS 血条（复用 BossHPBar 脚本；现在支持 EnemyOnline）
func _create_boss_hp_bar(enemy: Node, enemy_id: String) -> void:
	if not boss_bar_container:
		return
	var boss_bar := BOSS_HP_BAR_SCENE.instantiate()
	if not boss_bar:
		return
	boss_bar_container.add_child(boss_bar)
	
	# 连接自清理回调，避免字典残留
	var inst_id := int(enemy.get_instance_id())
	if boss_bar.has_signal("enemy_died"):
		boss_bar.enemy_died.connect(_on_boss_bar_enemy_died.bind(inst_id))
	
	# 绑定敌人
	if boss_bar.has_method("set_enemy"):
		boss_bar.set_enemy(enemy, enemy_id)
	
	_boss_bars_by_enemy[inst_id] = boss_bar
	print("[GameUIOnline] 创建 BOSS 血条: ", enemy_id)


func _on_boss_bar_enemy_died(_bar: Node, enemy_instance_id: int) -> void:
	if _boss_bars_by_enemy.has(enemy_instance_id):
		_boss_bars_by_enemy.erase(enemy_instance_id)


func _exit_tree() -> void:
	# 断开可能的信号连接，清空引用（避免切场景时残留）
	for k in _boss_bars_by_enemy.keys():
		var bar = _boss_bars_by_enemy.get(k)
		if bar and is_instance_valid(bar) and bar.has_signal("enemy_died"):
			if bar.enemy_died.is_connected(_on_boss_bar_enemy_died):
				bar.enemy_died.disconnect(_on_boss_bar_enemy_died)
	_boss_bars_by_enemy.clear()


## 初始化玩家列表
func _init_player_list() -> void:
	# 清空现有列表
	_clear_player_list()
	
	var local_peer_id: int = int(NetworkManager.get_peer_id())
	print("[GameUIOnline] 初始化玩家列表, local_peer_id=%d, players=%s" % [local_peer_id, str(NetworkPlayerManager.players.keys())])
	
	# 为每个玩家创建信息项：
	# - 客户端：排序（稳定显示）
	# - 服务器：保持加入顺序（切换追踪目标时列表顺序不变化）
	var peer_ids: Array = NetworkPlayerManager.players.keys()
	if not NetworkManager.is_server():
		peer_ids.sort()
	for peer_id in peer_ids:
		# 只跳过无效 peer_id（允许 peer_id=1 的主机玩家显示）
		if peer_id <= 0:
			print("[GameUIOnline] 跳过无效 peer_id: %d" % peer_id)
			continue
		var player = NetworkPlayerManager.players[peer_id]
		if player and is_instance_valid(player):
			_add_player_info(peer_id, player)
	
	_sort_players_container()
	_sync_players_panel_size()


## 清空玩家列表
func _clear_player_list() -> void:
	# 清空字典中的引用
	for peer_id in player_info_items.keys():
		var item = player_info_items[peer_id]
		if item and is_instance_valid(item):
			item.queue_free()
	player_info_items.clear()
	
	# 同时清理容器中的所有子节点（防止残留）
	if players_container:
		for child in players_container.get_children():
			child.queue_free()
	
	_sync_players_panel_size()


## 添加玩家信息项
func _add_player_info(peer_id: int, player: Node) -> void:
	if player_info_items.has(peer_id):
		return
	
	var item = _create_player_info_item(peer_id, player)
	players_container.add_child(item)
	player_info_items[peer_id] = item
	
	# 标记 peer_id 方便排序
	item.set_meta("peer_id", peer_id)
	item.set_meta("is_current", _is_ui_current_player(peer_id))
	
	# 尝试监听职业变化，及时刷新 icon（UI 也会在 _update_player_info 里兜底刷新）
	if player and is_instance_valid(player) and player.has_signal("class_changed"):
		if not player.class_changed.is_connected(_on_player_class_changed):
			player.class_changed.connect(_on_player_class_changed.bind(peer_id))
	
	_sort_players_container()
	_sync_players_panel_size()


## 玩家职业变化回调：更新 icon
func _on_player_class_changed(_class_data: ClassData, peer_id: int) -> void:
	_update_player_icon(peer_id)


## 对 PlayersContainer 子节点按 peer_id 排序
func _sort_players_container() -> void:
	# 服务器端：保持加入顺序，不排序
	if NetworkManager.is_server():
		return
	if not players_container:
		return
	
	var items: Array = []
	for child in players_container.get_children():
		if child and is_instance_valid(child):
			items.append(child)
	
	items.sort_custom(func(a, b):
		var al := bool(a.get_meta("is_current", false))
		var bl := bool(b.get_meta("is_current", false))
		if al != bl:
			return al and not bl
		var pa := int(a.get_meta("peer_id", 0))
		var pb := int(b.get_meta("peer_id", 0))
		return pa < pb
	)
	
	for child in items:
		players_container.remove_child(child)
	for child in items:
		players_container.add_child(child)


## 创建玩家信息项
func _create_player_info_item(peer_id: int, player: Node) -> Control:
	var item = PanelContainer.new()
	item.name = "PlayerInfo_%d" % peer_id
	item.custom_minimum_size = Vector2(PLAYER_ENTRY_WIDTH, PLAYER_ENTRY_HEIGHT)
	
	# 创建样式
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.2, 0)
	# style.corner_radius_top_left = 0
	# style.corner_radius_top_right = 0
	# style.corner_radius_bottom_left = 0
	# style.corner_radius_bottom_right = 0
	# style.border_width_left = 0
	# style.border_width_right = 1
	# style.border_width_top = 0
	# style.border_width_bottom = 1
	# style.border_color = Color.WHITE
	item.add_theme_stylebox_override("panel", style)
	
	# 主容器
	var margin = MarginContainer.new()
	margin.name = "MarginContainer"
	# 统一：不额外留白（与模式1布局一致）
	margin.add_theme_constant_override("margin_left", 0)
	margin.add_theme_constant_override("margin_right", 0)
	margin.add_theme_constant_override("margin_top", 0)
	margin.add_theme_constant_override("margin_bottom", 0)
	item.add_child(margin)
	
	var hbox = HBoxContainer.new()
	hbox.name = "HBoxContainer"
	hbox.add_theme_constant_override("separation", 10)
	margin.add_child(hbox)
	
	# 角色 icon（复用职业 portrait）
	var icon = TextureRect.new()
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(80, 80)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = player.get_class_portrait() if player.has_method("get_class_portrait") else null
	hbox.add_child(icon)
	
	# 信息容器
	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)
	hbox.add_child(vbox)
	
	# 玩家名称
	var name_label = Label.new()
	name_label.name = "NameLabel"
	name_label.text = player.display_name if "display_name" in player else "Player %d" % peer_id
	name_label.add_theme_font_size_override("font_size", 24)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	
	# 标记本地玩家（使用 NetworkManager.get_peer_id() 确保准确）
	var local_peer_id = NetworkManager.get_peer_id()
	if NetworkManager.is_server():
		if _is_ui_current_player(peer_id):
			name_label.text += " (当前)"
			name_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	else:
		if peer_id == local_peer_id:
			name_label.text += " (你)"
			name_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	
	vbox.add_child(name_label)
	
	# HP 条
	var hp_container = HBoxContainer.new()
	hp_container.name = "HBoxContainer"
	hp_container.add_theme_constant_override("separation", 5)
	vbox.add_child(hp_container)
	
	var hp_label = Label.new()
	hp_label.name = "HPLabel"
	hp_label.text = "HP:"
	hp_label.add_theme_font_size_override("font_size", 20)
	hp_label.custom_minimum_size = Vector2(HP_LABEL_WIDTH, 0)
	hp_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_container.add_child(hp_label)
	
	var hp_bar = ProgressBar.new()
	hp_bar.name = "HPBar"
	hp_bar.custom_minimum_size = Vector2(0, HP_BAR_HEIGHT)
	# 注意：HP 背景使用 skew，会在右侧“多画出一截”（约 skew_x * height）
	# 这里用固定宽度（SIZE_FILL + custom_minimum_size.x）并扣除 skew_extra，确保不会越界
	hp_bar.size_flags_horizontal = Control.SIZE_FILL
	hp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hp_bar.max_value = player.max_hp if "max_hp" in player else 100
	hp_bar.value = player.now_hp if "now_hp" in player else 100
	hp_bar.show_percentage = false
	
	# HP条样式：仿照模式1（skew + 绿色 fill）
	var bg_style = StyleBoxFlat.new()
	bg_style.bg_color = Color(0.2901961, 0.2901961, 0.2901961, 1)
	bg_style.skew = Vector2(HP_BG_SKEW_X, 0)
	bg_style.border_width_left = 6
	bg_style.border_width_top = 6
	bg_style.border_width_right = 6
	bg_style.border_width_bottom = 6
	bg_style.border_color = Color(0, 0, 0, 1)
	# 在线列表条目空间紧凑：不要用 expand_margin 扩展绘制区域（会导致越界/裁切争议）
	bg_style.expand_margin_left = 0.0
	bg_style.expand_margin_right = 0.0
	hp_bar.add_theme_stylebox_override("background", bg_style)
	hp_bar.add_theme_stylebox_override("fill", HP_FILL_STYLE)
	
	hp_container.add_child(hp_bar)
	
	# HP 数值（放在条内居中，仿照模式1）
	var hp_text = Label.new()
	hp_text.name = "HPText"
	hp_text.text = "%d / %d" % [int(hp_bar.value), int(hp_bar.max_value)]
	hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_text.add_theme_font_size_override("font_size", 18)
	hp_text.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	hp_text.add_theme_constant_override("shadow_offset_x", 1)
	hp_text.add_theme_constant_override("shadow_offset_y", 1)
	hp_bar.add_child(hp_text)
	# 让文字铺满进度条区域，通过 alignment 实现真正居中（避免锚点/position 叠加导致偏移）
	hp_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	hp_text.offset_left = 0
	hp_text.offset_top = 0
	hp_text.offset_right = 0
	hp_text.offset_bottom = 0
	hp_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# 尺寸策略：
	# - 本地玩家：HPBar 使用“可用宽度 - skew_extra”，保证右侧斜边不越界
	# - 其他玩家：仅 HPBar 长度缩短为比例（同样扣除 skew_extra）
	var is_current: bool = _is_ui_current_player(peer_id)
	var hp_available := PLAYER_ENTRY_WIDTH - PLAYER_ICON_SIZE - HBOX_SEP - HP_LABEL_WIDTH - HP_SEP
	var skew_extra := int(ceil(absf(HP_BG_SKEW_X) * float(HP_BAR_HEIGHT)))
	var hp_local := maxi(0, int(hp_available) - skew_extra)
	var hp_w := hp_local if is_current else int(round(float(hp_local) * REMOTE_HP_RATIO))
	hp_bar.custom_minimum_size = Vector2(hp_w, HP_BAR_HEIGHT)
	
	# 钥匙信息容器
	var keys_container = HBoxContainer.new()
	keys_container.name = "KeysContainer"
	keys_container.add_theme_constant_override("separation", 15)
	vbox.add_child(keys_container)
	
	# 普通钥匙（Gold）
	var gold_container = HBoxContainer.new()
	gold_container.name = "GoldContainer"
	gold_container.add_theme_constant_override("separation", 3)
	keys_container.add_child(gold_container)
	
	var gold_icon = TextureRect.new()
	gold_icon.name = "GoldIcon"
	gold_icon.custom_minimum_size = Vector2(36, 36)
	gold_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gold_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	gold_icon.texture = KEY_NORMAL_TEX
	gold_container.add_child(gold_icon)
	
	var gold_label = Label.new()
	gold_label.name = "GoldLabel"
	gold_label.text = "%d" % (player.gold if "gold" in player else 0)
	gold_label.add_theme_font_size_override("font_size", 20)
	gold_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))  # 金色
	gold_label.custom_minimum_size = Vector2(45, 0)
	gold_container.add_child(gold_label)
	
	# 大师钥匙（Master Key）
	var master_container = HBoxContainer.new()
	master_container.name = "MasterContainer"
	master_container.add_theme_constant_override("separation", 3)
	keys_container.add_child(master_container)
	
	var master_icon = TextureRect.new()
	master_icon.name = "MasterIcon"
	master_icon.custom_minimum_size = Vector2(36, 36)
	master_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	master_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	master_icon.texture = KEY_MASTER_TEX
	master_container.add_child(master_icon)
	
	var master_label = Label.new()
	master_label.name = "MasterKeyLabel"
	master_label.text = "%d" % (player.master_key if "master_key" in player else 0)
	master_label.add_theme_font_size_override("font_size", 21)
	master_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))  # 蓝色
	master_label.custom_minimum_size = Vector2(45, 0)
	master_container.add_child(master_label)

	# 最终兜底：如果内容实际高度 > 常量高度，提升条目高度，避免裁切（例如 hp_label 字号较大时）
	var min_y := maxf(float(PLAYER_ENTRY_HEIGHT), float(item.get_combined_minimum_size().y))
	item.custom_minimum_size = Vector2(float(PLAYER_ENTRY_WIDTH), min_y)
	return item


## 更新所有玩家信息
func _update_all_players() -> void:
	# 更新调试标签
	_update_debug_label()
	
	# 检查是否有新玩家加入（允许 peer_id=1）
	# - 客户端：排序，保证稳定
	# - 服务器：保持加入顺序
	var peer_ids: Array = NetworkPlayerManager.players.keys()
	if not NetworkManager.is_server():
		peer_ids.sort()
	for peer_id in peer_ids:
		if peer_id <= 0:
			continue
		if not player_info_items.has(peer_id):
			var player = NetworkPlayerManager.players[peer_id]
			if player and is_instance_valid(player):
				_add_player_info(peer_id, player)
	
	# 检查是否有玩家离开
	var to_remove: Array = []
	for peer_id in player_info_items.keys():
		if not NetworkPlayerManager.players.has(peer_id) or not is_instance_valid(NetworkPlayerManager.players[peer_id]):
			to_remove.append(peer_id)
	
	for peer_id in to_remove:
		_remove_player_info(peer_id)
	
	# 更新每个玩家的信息
	for peer_id in player_info_items.keys():
		_update_player_info(peer_id)
	
	_sort_players_container()


## 更新玩家 icon（职业头像）
func _update_player_icon(peer_id: int) -> void:
	if not NetworkPlayerManager.players.has(peer_id):
		return
	var player = NetworkPlayerManager.players[peer_id]
	if not player or not is_instance_valid(player):
		return
	
	var item = player_info_items.get(peer_id)
	if not item or not is_instance_valid(item):
		return
	
	var icon = item.get_node_or_null("MarginContainer/HBoxContainer/Icon")
	if icon and icon is TextureRect:
		var tex: Texture2D = null
		if player.has_method("get_class_portrait"):
			tex = player.get_class_portrait()
		icon.texture = tex


## 更新单个玩家信息
func _update_player_info(peer_id: int) -> void:
	if not NetworkPlayerManager.players.has(peer_id):
		return
	var player = NetworkPlayerManager.players[peer_id]
	if not player or not is_instance_valid(player):
		return
	
	var item = player_info_items.get(peer_id)
	if not item or not is_instance_valid(item):
		return
	
	# 尺寸：本地玩家和模式1一致；其他玩家不缩放，仅 HPBar 变短
	var local_peer_id: int = int(NetworkManager.get_peer_id())
	var current_peer_id: int = _get_ui_current_peer_id()
	var is_local: bool = peer_id == local_peer_id
	var is_current: bool = peer_id == current_peer_id
	item.set_meta("is_current", is_current)
	
	# 统一条目尺寸（不整体缩放）
	item.scale = Vector2.ONE
	# 兜底：按真实内容高度调整，避免进度条/文字被裁切
	var min_y := maxf(float(PLAYER_ENTRY_HEIGHT), float(item.get_combined_minimum_size().y))
	item.custom_minimum_size = Vector2(float(PLAYER_ENTRY_WIDTH), min_y)
	# 非本地玩家：只缩短 HPBar 宽度为 70%
	var hp_bar_for_size = item.get_node_or_null("MarginContainer/HBoxContainer/VBoxContainer/HBoxContainer/HPBar")
	if hp_bar_for_size and hp_bar_for_size is ProgressBar:
		var pb := hp_bar_for_size as ProgressBar
		pb.size_flags_horizontal = Control.SIZE_FILL
		var hp_available := PLAYER_ENTRY_WIDTH - PLAYER_ICON_SIZE - HBOX_SEP - HP_LABEL_WIDTH - HP_SEP
		var skew_extra := int(ceil(absf(HP_BG_SKEW_X) * float(HP_BAR_HEIGHT)))
		var hp_local := maxi(0, int(hp_available) - skew_extra)
		var hp_w := hp_local if is_current else int(round(float(hp_local) * REMOTE_HP_RATIO))
		pb.custom_minimum_size = Vector2(hp_w, HP_BAR_HEIGHT)
	
	var player_role = player.get("player_role_id")
	var is_betrayed_impostor = NetworkPlayerManager.impostor_betrayed and peer_id == NetworkPlayerManager.impostor_peer_id
	
	# 更新名字标签
	var name_label = item.get_node_or_null("MarginContainer/HBoxContainer/VBoxContainer/NameLabel")
	if name_label and "display_name" in player:
		var new_name = player.display_name if player.display_name != "" else "Player %d" % peer_id
		
		# 添加角色标记
		if is_betrayed_impostor:
			new_name = "🔪 " + new_name + " [内鬼]"
		elif player_role == NetworkPlayerManager.ROLE_BOSS:
			new_name = "👹 " + new_name + " [BOSS]"
		else:
			new_name = "🎮 " + new_name
		
		# 客户端：本地玩家标记“你”；服务器：跟随目标标记“当前”
		if NetworkManager.is_server():
			if peer_id == current_peer_id:
				new_name += " (当前)"
		else:
			if peer_id == local_peer_id:
				new_name += " (你)"
		
		if name_label.text != new_name:
			name_label.text = new_name
		
		# 更新颜色
		if is_betrayed_impostor:
			name_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.0))  # 橙色
		elif player_role == NetworkPlayerManager.ROLE_BOSS:
			name_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))  # 红色
		elif peer_id == local_peer_id:
			name_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))  # 绿色
		else:
			name_label.add_theme_color_override("font_color", Color.WHITE)
	
	# 更新图标颜色（skin 可能在游戏开始时更新）
	var icon = item.get_node_or_null("MarginContainer/HBoxContainer/Icon")
	if icon and icon is TextureRect:
		# 每次刷新一次，避免职业晚于 UI 创建导致 icon 为空
		var tex: Texture2D = null
		if player.has_method("get_class_portrait"):
			tex = player.get_class_portrait()
		if icon.texture != tex:
			icon.texture = tex
	
	# 更新边框颜色
	var style = item.get_theme_stylebox("panel") as StyleBoxFlat
	if style:
		if is_betrayed_impostor:
			style.border_color = Color(1.0, 0.5, 0.0)  # 橙色边框
		elif player_role == NetworkPlayerManager.ROLE_BOSS:
			style.border_color = Color(1.0, 0.3, 0.3)  # 红色边框
		else:
			style.border_color = Color.WHITE
	
	# 更新 HP
	var hp_bar = item.get_node_or_null("MarginContainer/HBoxContainer/VBoxContainer/HBoxContainer/HPBar")
	var hp_text = null
	if hp_bar:
		hp_text = hp_bar.get_node_or_null("HPText")
	
	if hp_bar and "now_hp" in player and "max_hp" in player:
		# HP 下降即触发受伤全屏效果
		# 在线版：
		# - 客户端：仅本地玩家触发
		# - 服务器：仅当前跟随目标（current_peer_id）触发
		if is_local or is_current:
			var old_hp := float(hp_bar.value)
			var new_hp := float(max(0, int(player.now_hp)))
			if new_hp < old_hp and damage_flash:
				damage_flash.flash()

		hp_bar.max_value = player.max_hp
		hp_bar.value = max(0, player.now_hp)
	
	if hp_text and "now_hp" in player and "max_hp" in player and hp_text is Label:
		var lbl := hp_text as Label
		lbl.text = "%d / %d" % [max(0, player.now_hp), player.max_hp]
		# 确保布局为 full-rect，避免某些情况下节点被重排后文字不居中
		lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl.offset_left = 0
		lbl.offset_top = 0
		lbl.offset_right = 0
		lbl.offset_bottom = 0
	
	# 更新钥匙数量
	var gold_label = item.get_node_or_null("MarginContainer/HBoxContainer/VBoxContainer/KeysContainer/GoldContainer/GoldLabel")
	if gold_label and "gold" in player:
		gold_label.text = "%d" % player.gold
	
	var master_key_label = item.get_node_or_null("MarginContainer/HBoxContainer/VBoxContainer/KeysContainer/MasterContainer/MasterKeyLabel")
	if master_key_label and "master_key" in player:
		master_key_label.text = "%d" % player.master_key

	# 同步右上角钥匙显示：直接复用“玩家列表当前行”已拿到的数据
	# 参考 HP flash 的客户端/服务器判定：
	# - 客户端：仅本地玩家触发
	# - 服务器：仅当前跟随目标（current_peer_id）触发
	if gold_counter and master_key_counter:
		if is_local or is_current:
			var gold := int(player.gold) if "gold" in player else 0
			var mk := int(player.master_key) if "master_key" in player else 0
			gold_counter.set_value(gold, 0)
			master_key_counter.set_value(mk, 0)


## 移除玩家信息项
func _remove_player_info(peer_id: int) -> void:
	if not player_info_items.has(peer_id):
		return
	
	var item = player_info_items[peer_id]
	if item and is_instance_valid(item):
		item.queue_free()
	player_info_items.erase(peer_id)
	_sync_players_panel_size()


## 更新服务器信息
func _update_server_info() -> void:
	if not server_info_label:
		return
	
	if NetworkManager.is_server():
		server_info_label.text = "服务器 | 按 Tab 切换视角"
	else:
		server_info_label.text = "客户端 | Peer ID: %d" % NetworkManager.get_peer_id()


## ==================== 波次显示系统 ====================

## 设置波次显示
func _setup_wave_display() -> void:
	if not wave_label:
		return
	
	# 查找波次管理器
	wave_manager_ref = get_tree().get_first_node_in_group("wave_system")
	if not wave_manager_ref:
		wave_manager_ref = get_tree().get_first_node_in_group("wave_manager")
	
	if wave_manager_ref:
		# 连接波次信号
		if wave_manager_ref.has_signal("wave_started"):
			if not wave_manager_ref.wave_started.is_connected(_on_wave_started):
				wave_manager_ref.wave_started.connect(_on_wave_started)
		if wave_manager_ref.has_signal("wave_ended"):
			if not wave_manager_ref.wave_ended.is_connected(_on_wave_ended):
				wave_manager_ref.wave_ended.connect(_on_wave_ended)
		
		_update_wave_display()
	else:
		# 如果没找到，延迟查找
		_find_wave_manager_periodically()


## 定期查找波次管理器
func _find_wave_manager_periodically() -> void:
	var attempts = 0
	while wave_manager_ref == null and attempts < 10:
		await get_tree().create_timer(0.5).timeout
		attempts += 1
		wave_manager_ref = get_tree().get_first_node_in_group("wave_system")
		if not wave_manager_ref:
			wave_manager_ref = get_tree().get_first_node_in_group("wave_manager")
		
		if wave_manager_ref:
			if wave_manager_ref.has_signal("wave_started"):
				if not wave_manager_ref.wave_started.is_connected(_on_wave_started):
					wave_manager_ref.wave_started.connect(_on_wave_started)
			if wave_manager_ref.has_signal("wave_ended"):
				if not wave_manager_ref.wave_ended.is_connected(_on_wave_ended):
					wave_manager_ref.wave_ended.connect(_on_wave_ended)
			_update_wave_display()
			break


## 波次开始回调
func _on_wave_started(_wave_number: int) -> void:
	_update_wave_display()
	_play_wave_begin_animation()


## 波次结束回调
func _on_wave_ended(_wave_number: int) -> void:
	_update_wave_display()


## 更新波次显示
func _update_wave_display() -> void:
	if not wave_label:
		return
	
	if not wave_manager_ref:
		wave_manager_ref = get_tree().get_first_node_in_group("wave_system")
		if not wave_manager_ref:
			wave_manager_ref = get_tree().get_first_node_in_group("wave_manager")
	
	if not wave_manager_ref:
		wave_label.text = "等待中..."
		return
	
	var current_wave = 0
	var total_waves = 1
	var killed := 0
	var total := 0
	
	if "current_wave" in wave_manager_ref:
		current_wave = wave_manager_ref.current_wave
	
	# 联网模式使用 total_waves 作为总波次
	if "total_waves" in wave_manager_ref:
		total_waves = wave_manager_ref.total_waves
	elif "wave_configs" in wave_manager_ref and wave_manager_ref.wave_configs is Array:
		total_waves = wave_manager_ref.wave_configs.size()

	# 击杀/总计（兼容 WaveSystemOnline / WaveManager）
	if "enemies_killed_this_wave" in wave_manager_ref:
		killed = int(wave_manager_ref.enemies_killed_this_wave)
	if "enemies_total_this_wave" in wave_manager_ref:
		total = int(wave_manager_ref.enemies_total_this_wave)
	
	wave_label.text = "第 %d / %d 波 (消灭: %d / 总计: %d)" % [current_wave, total_waves, killed, total]


## ==================== 角色提示系统 ====================

## 创建角色提示面板
func _create_role_hint_panel() -> void:
	_role_hint_panel = PanelContainer.new()
	_role_hint_panel.name = "RoleHintPanel"
	
	# 位置：屏幕上方中央
	_role_hint_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_role_hint_panel.position = Vector2(-150, 20)
	_role_hint_panel.custom_minimum_size = Vector2(300, 60)
	
	# 样式
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.9)
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	style.corner_radius_bottom_left = 10
	style.corner_radius_bottom_right = 10
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_width_top = 3
	style.border_width_bottom = 3
	style.border_color = Color(0.5, 0.5, 0.5)
	_role_hint_panel.add_theme_stylebox_override("panel", style)
	
	# 内容容器
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_role_hint_panel.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.add_theme_constant_override("separation", 5)
	margin.add_child(vbox)
	
	# 角色标签
	var role_label = Label.new()
	role_label.name = "RoleLabel"
	role_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	role_label.add_theme_font_size_override("font_size", 20)
	vbox.add_child(role_label)
	
	# 提示标签
	var hint_label = Label.new()
	hint_label.name = "HintLabel"
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_font_size_override("font_size", 14)
	hint_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(hint_label)
	
	add_child(_role_hint_panel)
	_role_hint_panel.visible = false


## 更新角色提示
func _update_role_hint() -> void:
	if not _role_hint_panel:
		return
	
	var local_player = NetworkPlayerManager.local_player
	if not local_player or not is_instance_valid(local_player):
		_role_hint_panel.visible = false
		return
	
	var role_id = local_player.player_role_id
	var role_label = _role_hint_panel.get_node_or_null("MarginContainer/VBoxContainer/RoleLabel")
	var hint_label = _role_hint_panel.get_node_or_null("MarginContainer/VBoxContainer/HintLabel")
	var style = _role_hint_panel.get_theme_stylebox("panel") as StyleBoxFlat
	
	if not role_label or not hint_label:
		return
	
	match role_id:
		NetworkPlayerManager.ROLE_BOSS:
			role_label.text = "👹 你是 BOSS"
			role_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			hint_label.text = "消灭所有玩家！"
			if style:
				style.border_color = Color(1.0, 0.3, 0.3)
			_role_hint_panel.visible = true
		
		NetworkPlayerManager.ROLE_IMPOSTOR:
			if NetworkPlayerManager.impostor_betrayed:
				role_label.text = "🔪 你是叛变者"
				role_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.0))
				hint_label.text = "消灭所有玩家！"
				if style:
					style.border_color = Color(1.0, 0.5, 0.0)
			else:
				role_label.text = "🎭 你是内鬼"
				role_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.0))
				hint_label.text = "按 B 键叛变（不可撤销）"
				if style:
					style.border_color = Color(1.0, 0.5, 0.0)
			_role_hint_panel.visible = true
		
		NetworkPlayerManager.ROLE_PLAYER:
			role_label.text = "🎮 你是玩家"
			role_label.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
			hint_label.text = "击败 BOSS，小心内鬼！"
			if style:
				style.border_color = Color(0.4, 0.8, 1.0)
			_role_hint_panel.visible = true
		
		_:
			_role_hint_panel.visible = false


## 本地玩家职业分配完成回调（初始化技能 UI）
func _on_local_player_class_assigned(player: Node) -> void:
	print("[GameUIOnline] 本地玩家职业分配完成，初始化技能 UI")
	
	# 初始化 Dash UI
	if dash_ui and dash_ui.has_method("init_with_player"):
		dash_ui.init_with_player(player)
	
	# 初始化技能图标 UI
	if skill_icon and skill_icon.has_method("init_with_player"):
		skill_icon.init_with_player(player)


## 叛变事件处理
func _on_impostor_betrayed(impostor_peer_id: int) -> void:
	print("[GameUIOnline] 收到叛变通知: peer_id=%d" % impostor_peer_id)
	
	# 更新角色提示
	_update_role_hint()
	
	# 更新叛变提示（隐藏）
	_update_betrayal_hint()
	
	# 更新玩家列表中的 Impostor 显示
	_update_player_info(impostor_peer_id)


## 创建叛变提示框（屏幕下方居中，只有 Impostor 可见）
func _create_betrayal_hint_panel() -> void:
	_betrayal_hint_panel = PanelContainer.new()
	_betrayal_hint_panel.name = "BetrayalHintPanel"
	
	# 样式 - 醒目的橙色边框
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.1, 0.05, 0.95)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.border_width_left = 4
	style.border_width_right = 4
	style.border_width_top = 4
	style.border_width_bottom = 4
	style.border_color = Color(1.0, 0.5, 0.0)  # 橙色边框
	style.shadow_color = Color(1.0, 0.5, 0.0, 0.3)
	style.shadow_size = 8
	_betrayal_hint_panel.add_theme_stylebox_override("panel", style)
	
	# 内容容器
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 30)
	margin.add_theme_constant_override("margin_right", 30)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	_betrayal_hint_panel.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)
	
	# 标题
	var title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "🎭 你是内鬼"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 24)
	title_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
	vbox.add_child(title_label)
	
	# 按键提示
	var key_hint = Label.new()
	key_hint.name = "KeyHintLabel"
	key_hint.text = "按 [ B ] 键叛变"
	key_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_hint.add_theme_font_size_override("font_size", 28)
	key_hint.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	vbox.add_child(key_hint)
	
	# 警告提示
	var warning_label = Label.new()
	warning_label.name = "WarningLabel"
	warning_label.text = "⚠ 叛变后不可撤销，所有人都会知道你是叛变者"
	warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning_label.add_theme_font_size_override("font_size", 14)
	warning_label.add_theme_color_override("font_color", Color(0.8, 0.6, 0.4))
	vbox.add_child(warning_label)
	
	add_child(_betrayal_hint_panel)
	_betrayal_hint_panel.visible = false
	
	# 延迟设置位置（等待布局完成）
	call_deferred("_position_betrayal_hint")


## 设置叛变提示框位置（屏幕下方居中）
func _position_betrayal_hint() -> void:
	if not _betrayal_hint_panel:
		return
	
	var viewport_size = get_viewport().get_visible_rect().size
	var panel_size = _betrayal_hint_panel.size
	
	# 如果还没有计算出大小，使用预估值
	if panel_size.x <= 0:
		panel_size = Vector2(400, 120)
	
	_betrayal_hint_panel.position = Vector2(
		(viewport_size.x - panel_size.x) / 2,
		viewport_size.y - panel_size.y - 80  # 距离底部 80 像素
	)


## 更新叛变提示框显示状态
func _update_betrayal_hint() -> void:
	if not _betrayal_hint_panel:
		return
	
	# 只有 Impostor 且未叛变时才显示
	var should_show = NetworkPlayerManager.can_betray()
	
	if _betrayal_hint_panel.visible != should_show:
		_betrayal_hint_panel.visible = should_show
		if should_show:
			# 重新定位
			call_deferred("_position_betrayal_hint")


## ==================== 调试功能 ====================

## 创建调试标签
func _create_debug_label() -> void:
	_debug_label = Label.new()
	_debug_label.name = "DebugLabel"
	_debug_label.position = Vector2(20, 680)
	_debug_label.add_theme_font_size_override("font_size", 16)
	_debug_label.add_theme_color_override("font_color", Color(1, 1, 0))
	_debug_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_debug_label)


## 更新调试标签
func _update_debug_label() -> void:
	if not _debug_label:
		return
	
	var local_peer_id: int = int(NetworkManager.get_peer_id())
	var current_peer_id: int = _get_ui_current_peer_id()
	var lines: Array = []
	lines.append("=== 调试: 玩家名字列表 ===")
	lines.append("本地 peer_id: %d" % local_peer_id)
	lines.append("players.keys(): %s" % str(NetworkPlayerManager.players.keys()))
	lines.append("player_info_items.keys(): %s" % str(player_info_items.keys()))
	lines.append("---")
	
	for peer_id in NetworkPlayerManager.players.keys():
		var player = NetworkPlayerManager.players[peer_id]
		if player and is_instance_valid(player):
			var name = player.display_name if "display_name" in player else "???"
			var is_local = " (本地)" if peer_id == local_peer_id else ""
			var is_current = " (当前)" if peer_id == current_peer_id else ""
			var is_skipped = " [跳过]" if peer_id <= 1 else ""
			lines.append("peer_%d: %s%s%s%s" % [peer_id, name, is_local, is_current, is_skipped])
		else:
			lines.append("peer_%d: [无效]" % peer_id)
	
	_debug_label.text = "\n".join(lines)
