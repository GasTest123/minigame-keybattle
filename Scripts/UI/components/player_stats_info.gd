extends PanelContainer
class_name PlayerStatsInfo

## 玩家属性实时显示UI
## 
## 显示玩家的所有属性数值，方便观察和调试

# 基础属性标签
@onready var max_hp_label: Label = %MaxHP
@onready var current_hp_label: Label = %CurrentHP
@onready var speed_label: Label = %Speed
@onready var defense_label: Label = %Defense
@onready var luck_label: Label = %Luck
@onready var key_pickup_range_label: Label = %KeyPickupRange

# 战斗属性标签
@onready var crit_chance_label: Label = %CritChance
@onready var crit_damage_label: Label = %CritDamage
@onready var damage_reduction_label: Label = %DamageReduction

# 异常效果系数标签
@onready var status_duration_mult_label: Label = %StatusDurationMult
@onready var status_effect_mult_label: Label = %StatusEffectMult
@onready var status_chance_mult_label: Label = %StatusChanceMult

# 全局武器属性标签
@onready var global_damage_mult_label: Label = %GlobalDamageMult
@onready var global_attack_speed_mult_label: Label = %GlobalAttackSpeedMult

# 近战武器属性标签
@onready var melee_damage_mult_label: Label = %MeleeDamageMult
@onready var melee_speed_mult_label: Label = %MeleeSpeedMult
@onready var melee_range_mult_label: Label = %MeleeRangeMult
@onready var melee_knockback_mult_label: Label = %MeleeKnockbackMult

# 远程武器属性标签
@onready var ranged_damage_mult_label: Label = %RangedDamageMult
@onready var ranged_speed_mult_label: Label = %RangedSpeedMult
@onready var ranged_range_mult_label: Label = %RangedRangeMult

# 魔法武器属性标签
@onready var magic_damage_mult_label: Label = %MagicDamageMult
@onready var magic_speed_mult_label: Label = %MagicSpeedMult
@onready var magic_range_mult_label: Label = %MagicRangeMult
@onready var magic_explosion_radius_mult_label: Label = %MagicExplosionRadiusMult

# 加成统计标签
@onready var permanent_modifiers_label: Label = %PermanentModifiers
@onready var temporary_modifiers_label: Label = %TemporaryModifiers

# 日志文本框
@onready var log_text: RichTextLabel = %LogText

# 玩家引用
var player: Node = null

# 更新定时器
var update_timer: Timer

func _ready():
	# 延迟查找玩家节点（确保场景已完全加载）
	await get_tree().create_timer(0.1).timeout
	
	# 查找玩家节点：
	# - 在线模式：必须以 local_player 为准（否则多人时 get_first_node_in_group("player") 不稳定）
	# - 单机模式：使用 group 查找即可
	if "current_mode_id" in GameMain and GameMain.current_mode_id == "online":
		player = NetworkPlayerManager.local_player
	else:
		player = get_tree().get_first_node_in_group("player")
	
	if not player:
		print("[PlayerStatsInfo] 警告：未找到玩家节点")
		return
	
	if player.has_node("AttributeManager"):
		var attribute_manager = player.get_node("AttributeManager")
		
		# 监听属性变化
		if not attribute_manager.stats_changed.is_connected(_on_stats_changed):
			attribute_manager.stats_changed.connect(_on_stats_changed)
			print("[PlayerStatsInfo] 已连接属性变化信号")
		
		# 监听日志信号
		if attribute_manager.has_signal("stats_log"):
			if not attribute_manager.stats_log.is_connected(_on_stats_log):
				attribute_manager.stats_log.connect(_on_stats_log)
				print("[PlayerStatsInfo] 已连接属性日志信号")
		
		# 初始更新
		if attribute_manager.final_stats:
			_on_stats_changed(attribute_manager.final_stats)
			print("[PlayerStatsInfo] 初始属性已更新")
	else:
		print("[PlayerStatsInfo] 警告：玩家没有 AttributeManager")
	
	# 创建定时器，定期更新（包括当前HP）
	update_timer = Timer.new()
	update_timer.name = "UpdateTimer"
	update_timer.wait_time = 0.5  # 每0.5秒更新一次
	update_timer.autostart = true
	update_timer.timeout.connect(_update_current_values)
	add_child(update_timer)

## 当属性变化时更新显示
func _on_stats_changed(stats: CombatStats) -> void:
	if not stats:
		return
	
	# 基础属性
	max_hp_label.text = "最大HP: %d" % stats.max_hp
	speed_label.text = "移动速度: %.1f" % stats.speed
	defense_label.text = "防御: %d" % stats.defense
	luck_label.text = "幸运: %.1f" % stats.luck
	if key_pickup_range_label:
		key_pickup_range_label.text = "钥匙拾取范围: ×%.2f" % stats.key_pickup_range_mult
	
	# 战斗属性
	crit_chance_label.text = "暴击率: %.1f%%" % (stats.crit_chance * 100)
	crit_damage_label.text = "暴击伤害: %.1f%%" % (stats.crit_damage * 100)
	# 显式类型：避免从 Variant 推断导致 “Warning treated as error”
	var a: float = maxf(0.0, float(stats.damage_reduction))
	var k: float = float(DamageCalculator.DAMAGE_REDUCTION_K)
	var b: float = 0.0
	if a > 0.0:
		b = a / (a + k)
	damage_reduction_label.text = "防御力：%.0f（%.1f%%）" % [a, b * 100.0]
	
	# 异常效果系数
	if status_duration_mult_label:
		status_duration_mult_label.text = "异常持续时间: ×%.2f" % stats.status_duration_mult
	if status_effect_mult_label:
		status_effect_mult_label.text = "异常效果加成: ×%.2f" % stats.status_effect_mult
	if status_chance_mult_label:
		status_chance_mult_label.text = "异常概率加成: ×%.2f" % stats.status_chance_mult
	
	# 全局武器属性
	global_damage_mult_label.text = "全局伤害: ×%.2f" % stats.global_damage_mult
	global_attack_speed_mult_label.text = "全局攻速: ×%.2f" % stats.global_attack_speed_mult
	melee_knockback_mult_label.text = "击退: ×%.2f" % stats.melee_knockback_mult
	
	# 近战武器属性
	melee_damage_mult_label.text = "近战伤害: ×%.2f" % stats.melee_damage_mult
	melee_speed_mult_label.text = "近战攻速: ×%.2f" % stats.melee_speed_mult
	melee_range_mult_label.text = "近战范围: ×%.2f" % stats.melee_range_mult

	
	# 远程武器属性
	ranged_damage_mult_label.text = "远程伤害: ×%.2f" % stats.ranged_damage_mult
	ranged_speed_mult_label.text = "远程攻速: ×%.2f" % stats.ranged_speed_mult
	ranged_range_mult_label.text = "远程范围: ×%.2f" % stats.ranged_range_mult
	
	# 魔法武器属性
	magic_damage_mult_label.text = "魔法伤害: ×%.2f" % stats.magic_damage_mult
	magic_speed_mult_label.text = "魔法攻速: ×%.2f" % stats.magic_speed_mult
	magic_range_mult_label.text = "魔法范围: ×%.2f" % stats.magic_range_mult
	magic_explosion_radius_mult_label.text = "爆炸范围: ×%.2f" % stats.magic_explosion_radius_mult
	
	# 更新加成统计
	_update_modifier_counts()
	
	# 高亮非默认值
	_highlight_modified_stats(stats)

## 当收到属性日志时
func _on_stats_log(message: String) -> void:
	if not log_text:
		return
		
	var time = Time.get_time_string_from_system()
	log_text.append_text("[color=#aaaaaa][%s][/color] %s\n" % [time, message])
	# 自动滚动到底部
	# log_text.scroll_to_line(log_text.get_line_count() - 1)

## 定期更新当前值（HP等）
func _update_current_values() -> void:
	if not player:
		return
	
	# 更新当前HP
	if player.has_method("get") and player.get("now_hp") != null:
		current_hp_label.text = "当前HP: %d" % player.now_hp
		
		# HP低于50%时变红
		if player.max_hp > 0:
			var hp_percent = float(player.now_hp) / float(player.max_hp)
			if hp_percent < 0.5:
				current_hp_label.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
			elif hp_percent < 0.8:
				current_hp_label.add_theme_color_override("font_color", Color(1, 1, 0.3))
			else:
				current_hp_label.remove_theme_color_override("font_color")

## 更新加成统计
func _update_modifier_counts() -> void:
	if not player or not player.has_node("AttributeManager"):
		return
	
	var attribute_manager = player.get_node("AttributeManager")
	permanent_modifiers_label.text = "永久加成: %d" % attribute_manager.permanent_modifiers.size()
	temporary_modifiers_label.text = "临时加成: %d" % attribute_manager.temporary_modifiers.size()

## 高亮修改过的属性
func _highlight_modified_stats(stats: CombatStats) -> void:
	# 钥匙拾取范围 - 如果不是1.0，则高亮
	if key_pickup_range_label:
		if stats.key_pickup_range_mult != 1.0:
			key_pickup_range_label.add_theme_color_override("font_color", Color(0.3, 1, 1))
		else:
			key_pickup_range_label.remove_theme_color_override("font_color")
	
	# 全局属性 - 如果不是1.0，则高亮
	if stats.global_damage_mult != 1.0:
		global_damage_mult_label.add_theme_color_override("font_color", Color(1, 1, 0.3))
	else:
		global_damage_mult_label.remove_theme_color_override("font_color")
	
	if stats.global_attack_speed_mult != 1.0:
		global_attack_speed_mult_label.add_theme_color_override("font_color", Color(1, 1, 0.3))
	else:
		global_attack_speed_mult_label.remove_theme_color_override("font_color")
	
	# 近战属性
	if stats.melee_damage_mult != 1.0:
		melee_damage_mult_label.add_theme_color_override("font_color", Color(1, 0.7, 0.3))
	else:
		melee_damage_mult_label.remove_theme_color_override("font_color")
	
	if stats.melee_speed_mult != 1.0:
		melee_speed_mult_label.add_theme_color_override("font_color", Color(1, 0.7, 0.3))
	else:
		melee_speed_mult_label.remove_theme_color_override("font_color")
	
	if stats.melee_range_mult != 1.0:
		melee_range_mult_label.add_theme_color_override("font_color", Color(1, 0.7, 0.3))
	else:
		melee_range_mult_label.remove_theme_color_override("font_color")
	
	if stats.melee_knockback_mult != 1.0:
		melee_knockback_mult_label.add_theme_color_override("font_color", Color(1, 0.7, 0.3))
	else:
		melee_knockback_mult_label.remove_theme_color_override("font_color")
	
	# 远程属性
	if stats.ranged_damage_mult != 1.0:
		ranged_damage_mult_label.add_theme_color_override("font_color", Color(0.3, 1, 0.3))
	else:
		ranged_damage_mult_label.remove_theme_color_override("font_color")
	
	if stats.ranged_speed_mult != 1.0:
		ranged_speed_mult_label.add_theme_color_override("font_color", Color(0.3, 1, 0.3))
	else:
		ranged_speed_mult_label.remove_theme_color_override("font_color")
	
	if stats.ranged_range_mult != 1.0:
		ranged_range_mult_label.add_theme_color_override("font_color", Color(0.3, 1, 0.3))
	else:
		ranged_range_mult_label.remove_theme_color_override("font_color")
	
	# 魔法属性
	if stats.magic_damage_mult != 1.0:
		magic_damage_mult_label.add_theme_color_override("font_color", Color(0.5, 0.5, 1))
	else:
		magic_damage_mult_label.remove_theme_color_override("font_color")
	
	if stats.magic_speed_mult != 1.0:
		magic_speed_mult_label.add_theme_color_override("font_color", Color(0.5, 0.5, 1))
	else:
		magic_speed_mult_label.remove_theme_color_override("font_color")
	
	if stats.magic_range_mult != 1.0:
		magic_range_mult_label.add_theme_color_override("font_color", Color(0.5, 0.5, 1))
	else:
		magic_range_mult_label.remove_theme_color_override("font_color")
	
	if stats.magic_explosion_radius_mult != 1.0:
		magic_explosion_radius_mult_label.add_theme_color_override("font_color", Color(0.5, 0.5, 1))
	else:
		magic_explosion_radius_mult_label.remove_theme_color_override("font_color")

## 切换显示/隐藏
func toggle_visibility() -> void:
	visible = not visible
