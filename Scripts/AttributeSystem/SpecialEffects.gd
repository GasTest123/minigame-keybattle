extends Node
class_name SpecialEffects

## 特殊效果处理器（重构版）
## 
## 职责：统一管理所有特殊战斗效果
## 支持：燃烧、流血、冰冻、减速、中毒、吸血、治愈
## 
## 所有方法都是静态方法，可以直接调用
## 
## 使用示例：
##   SpecialEffects.try_apply_status_effect(
##       attacker_stats, 
##       target, 
##       "burn", 
##       {"chance": 0.3, "tick_interval": 1.0, "damage": 10, "duration": 5.0}
##   )

## ========== 异常效果颜色配置（统一管理） ==========
## 
## 所有异常效果的颜色、shader参数都在这里统一配置
## 包括：浮动文字颜色、shader颜色、shader透明度

static var STATUS_COLORS: Dictionary = {
	"burn": {
		"text_color": Color(1.0, 0.5, 0.0),      # 橙色 - 浮动文字颜色
		"shader_color": Color(1.0, 0.5, 0.0, 1.0), # 橙色 - shader颜色
		"shader_opacity": 0.9                      # shader透明度
	},
	"bleed": {
		"text_color": Color(1.0, 0.0, 0.0),      # 红色 - 浮动文字颜色
		"shader_color": Color(1.0, 0.0, 0.0, 1.0), # 红色 - shader颜色
		"shader_opacity": 0.8                      # shader透明度
	},
	"freeze": {
		"text_color": Color(0.3, 0.8, 1.0),      # 蓝色 - 浮动文字颜色
		"shader_color": Color(0.3, 0.8, 1.0, 1.0), # 蓝色 - shader颜色
		"shader_opacity": 1.0                      # shader透明度（冰冻效果最明显）
	},
	"slow": {
		"text_color": Color(0.3, 0.6, 1.0, 0.8), # 半透明蓝色 - 浮动文字颜色
		"shader_color": Color(0.3, 0.6, 1.0, 0.6), # 半透明蓝色 - shader颜色
		"shader_opacity": 0.7                      # shader透明度
	},
	"poison": {
		"text_color": Color(0.5, 1.0, 0.0),      # 绿色 - 浮动文字颜色
		"shader_color": Color(0.5, 1.0, 0.0, 1.0), # 绿色 - shader颜色
		"shader_opacity": 0.7                      # shader透明度
	}
}

## 获取异常效果的颜色配置
## 
## @param status_id 异常效果ID（"burn", "bleed", "freeze", "slow", "poison"）
## @return 颜色配置字典，包含text_color、shader_color、shader_opacity
static func get_status_color_config(status_id: String) -> Dictionary:
	return STATUS_COLORS.get(status_id, {
		"text_color": Color.WHITE,
		"shader_color": Color.WHITE,
		"shader_opacity": 0.0
	})

## 异常效果类型枚举
enum StatusEffectType {
	BURN,      ## 燃烧
	BLEED,     ## 流血
	FREEZE,    ## 冰冻
	SLOW,      ## 减速
	POISON,    ## 中毒
	LIFESTEAL, ## 吸血
	HEAL       ## 治愈
}

## 统一应用异常效果
## 
## @param attacker_stats 攻击者的战斗属性
## @param target 目标对象
## @param effect_type 效果类型（字符串："burn", "bleed", "freeze", "slow", "poison", "lifesteal", "heal"）
## @param effect_params 效果参数字典
##   - 燃烧/流血/中毒: {"chance": float, "tick_interval": float, "damage": float, "duration": float}
##   - 冰冻: {"chance": float, "duration": float}
##   - 减速: {"chance": float, "duration": float, "slow_percent": float}
##   - 吸血/治愈: {"amount": float} 或 {"percent": float}
## @return 是否成功应用效果
static func try_apply_status_effect(
	attacker_stats: CombatStats, 
	target, 
	effect_type: String, 
	effect_params: Dictionary
) -> bool:
	if not attacker_stats:
		return false
	
	# 吸血效果不需要target（敌人），只需要attacker（玩家）
	if effect_type.to_lower() != "lifesteal" and not target:
		return false
	
	# 根据效果类型调用对应的处理方法
	match effect_type.to_lower():
		"burn":
			return _apply_burn(attacker_stats, target, effect_params)
		"bleed":
			return _apply_bleed(attacker_stats, target, effect_params)
		"freeze":
			return _apply_freeze(attacker_stats, target, effect_params)
		"slow":
			return _apply_slow(attacker_stats, target, effect_params)
		"poison":
			return _apply_poison(attacker_stats, target, effect_params)
		"lifesteal":
			return _apply_lifesteal(attacker_stats, target, effect_params)
		"heal":
			return _apply_heal(attacker_stats, target, effect_params)
		_:
			push_warning("[SpecialEffects] 未知的效果类型: %s" % effect_type)
			return false

## 应用燃烧效果
static func _apply_burn(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var chance = params.get("chance", 0.0)
	var tick_interval = params.get("tick_interval", 1.0)
	var damage = params.get("damage", 0.0)
	var duration = params.get("duration", 3.0)
	
	# 应用异常概率加成
	chance *= attacker_stats.status_chance_mult
	
	# 概率判定
	if chance <= 0 or not _roll_chance(chance):
		return false
	
	# 应用异常持续时间系数
	duration *= attacker_stats.status_duration_mult
	
	# 应用异常效果加成
	damage *= attacker_stats.status_effect_mult
	
	# 检查目标是否有BuffSystem
	var buff_system = _get_buff_system(target)
	if not buff_system:
		return false
	
	# 应用燃烧Buff
	buff_system.add_buff("burn", duration, {
		"dps": damage / tick_interval,  # 转换为每秒伤害
		"tick_interval": tick_interval,
		"damage": damage
	}, tick_interval)
	
	# 显示效果名称浮动文字
	if FloatingText:
		var color_config = get_status_color_config("burn")
		FloatingText.create_floating_text(
			target.global_position + Vector2(0, -50),
			"燃烧",
			color_config["text_color"],
			false
		)
	
	#print("[SpecialEffects] 燃烧效果触发！伤害: %.1f/%.1fs, 持续: %.1fs" % [damage, tick_interval, duration])
	return true

## 应用流血效果
static func _apply_bleed(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var chance = params.get("chance", 0.0)
	var tick_interval = params.get("tick_interval", 1.0)
	var damage = params.get("damage", 0.0)
	var duration = params.get("duration", 5.0)
	
	# 应用异常概率加成
	chance *= attacker_stats.status_chance_mult
	
	# 概率判定
	if chance <= 0 or not _roll_chance(chance):
		return false
	
	# 应用异常持续时间系数
	duration *= attacker_stats.status_duration_mult
	
	# 应用异常效果加成
	damage *= attacker_stats.status_effect_mult
	
	# 检查目标是否有BuffSystem
	var buff_system = _get_buff_system(target)
	if not buff_system:
		return false
	
	# 应用流血Buff
	buff_system.add_buff("bleed", duration, {
		"dps": damage / tick_interval,
		"tick_interval": tick_interval,
		"damage": damage
	}, tick_interval, true)  # 允许堆叠
	
	# 显示效果名称浮动文字
	if FloatingText:
		var color_config = get_status_color_config("bleed")
		FloatingText.create_floating_text(
			target.global_position + Vector2(0, -50),
			"流血",
			color_config["text_color"],
			false
		)
	
	#print("[SpecialEffects] 流血效果触发！目标: %s, 伤害: %.1f/%.1fs, 持续: %.1fs" % [target.name if target.has_method("get") and "name" in target else "未知", damage, tick_interval, duration])
	return true

## 应用冰冻效果
static func _apply_freeze(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var chance = params.get("chance", 0.0)
	var duration = params.get("duration", 2.0)
	
	# 应用异常概率加成
	chance *= attacker_stats.status_chance_mult
	
	# 概率判定
	if chance <= 0 or not _roll_chance(chance):
		return false
	
	# 应用异常持续时间系数
	duration *= attacker_stats.status_duration_mult
	
	# 检查目标是否有BuffSystem
	var buff_system = _get_buff_system(target)
	if not buff_system:
		return false
	
	# 应用冰冻Buff（无法移动）
	buff_system.add_buff("freeze", duration, {
		"can_move": false
	})
	
	# 显示效果名称浮动文字
	if FloatingText:
		var color_config = get_status_color_config("freeze")
		FloatingText.create_floating_text(
			target.global_position + Vector2(0, -50),
			"冰冻",
			color_config["text_color"],
			false
		)
	
	#print("[SpecialEffects] 冰冻效果触发！目标: %s, 持续: %.1fs" % [target.name if target.has_method("get") and "name" in target else "未知", duration])
	return true

## 应用减速效果
static func _apply_slow(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var chance = params.get("chance", 0.0)
	var duration = params.get("duration", 3.0)
	var slow_percent = params.get("slow_percent", 0.5)  # 默认减速50%
	
	# 应用异常概率加成
	chance *= attacker_stats.status_chance_mult
	
	# 概率判定
	if chance <= 0 or not _roll_chance(chance):
		return false
	
	# 应用异常持续时间系数
	duration *= attacker_stats.status_duration_mult
	
	# 应用异常效果加成（影响减速效果）
	slow_percent *= attacker_stats.status_effect_mult
	slow_percent = clamp(slow_percent, 0.0, 1.0)  # 限制在0-100%之间
	
	# 检查目标是否有BuffSystem
	var buff_system = _get_buff_system(target)
	if not buff_system:
		return false
	
	# 应用减速Buff
	buff_system.add_buff("slow", duration, {
		"slow_multiplier": 1.0 - slow_percent  # 移动速度倍数
	})
	
	# 显示效果名称浮动文字
	if FloatingText:
		var color_config = get_status_color_config("slow")
		FloatingText.create_floating_text(
			target.global_position + Vector2(0, -50),
			"减速",
			color_config["text_color"],
			false
		)
	
	#print("[SpecialEffects] 减速效果触发！减速: %.1f%%, 持续: %.1fs" % [slow_percent * 100, duration])
	return true

## 应用中毒效果
static func _apply_poison(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var chance = params.get("chance", 0.0)
	var tick_interval = params.get("tick_interval", 1.0)
	var damage = params.get("damage", 5.0)
	var duration = params.get("duration", 5.0)
	
	# 应用异常概率加成
	chance *= attacker_stats.status_chance_mult
	
	# 概率判定
	if chance <= 0 or not _roll_chance(chance):
		return false
	
	# 应用异常持续时间系数
	duration *= attacker_stats.status_duration_mult
	
	# 应用异常效果加成
	damage *= attacker_stats.status_effect_mult
	
	# 检查目标是否有BuffSystem
	var buff_system = _get_buff_system(target)
	if not buff_system:
		return false
	
	# 应用中毒Buff（可堆叠）
	buff_system.add_buff("poison", duration, {
		"dps": damage / tick_interval,
		"tick_interval": tick_interval,
		"damage": damage
	}, tick_interval, true)  # 允许堆叠
	
	# 显示效果名称浮动文字
	if FloatingText:
		var color_config = get_status_color_config("poison")
		FloatingText.create_floating_text(
			target.global_position + Vector2(0, -50),
			"中毒",
			color_config["text_color"],
			false
		)
	
	#print("[SpecialEffects] 中毒效果触发！伤害: %.1f/%.1fs, 持续: %.1fs" % [damage, tick_interval, duration])
	return true

## 应用吸血效果
static func _apply_lifesteal(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var damage_dealt = params.get("damage_dealt", 0)
	var lifesteal_percent = params.get("percent", attacker_stats.lifesteal_percent if attacker_stats else 0.0)
	var chance = params.get("chance", 1.0)  # 默认100%触发
	
	if damage_dealt <= 0:
		return false
	
	if lifesteal_percent <= 0:
		return false
	
	# 应用异常概率加成
	if attacker_stats:
		chance *= attacker_stats.status_chance_mult
	
	# 概率判定
	if chance <= 0 or not _roll_chance(chance):
		return false
	
	# 获取攻击者（通常是玩家）
	var attacker = params.get("attacker", null)
	if not attacker:
		return false
	
	# 应用异常效果加成（影响吸血百分比）
	if attacker_stats:
		lifesteal_percent *= attacker_stats.status_effect_mult
	
	# 计算吸血量
	var heal_amount = int(damage_dealt * lifesteal_percent)
	# 确保至少恢复1点HP
	if heal_amount < 1:
		heal_amount = 1
	
	# 恢复生命值
	if not "now_hp" in attacker or not "max_hp" in attacker:
		return false
	
	# 联网模式：通过 RPC 恢复血量，确保同步
	if GameMain.current_mode_id == "online" and attacker.has_method("rpc_heal") and "peer_id" in attacker:
		# 服务器通知客户端恢复血量
		if NetworkManager.is_server():
			attacker.rpc_id(attacker.peer_id, "rpc_heal", heal_amount)
		return true

	# 单机模式：直接修改
	var old_hp = attacker.now_hp
	attacker.now_hp = min(attacker.now_hp + heal_amount, attacker.max_hp)
	var actual_heal = attacker.now_hp - old_hp
	
	# 发送血量变化信号
	if attacker.has_signal("hp_changed"):
		attacker.hp_changed.emit(attacker.now_hp, attacker.max_hp)
	
	if actual_heal > 0:
		# 显示吸血跳字（使用统一方法）
		show_heal_floating_text(attacker, actual_heal)
		
		#print("[SpecialEffects] 吸血效果触发！恢复: +%d HP (伤害: %d, 比例: %.1f%%)" % [actual_heal, damage_dealt, lifesteal_percent * 100])
	
	return true

## 显示HP恢复的浮动文字（统一方法）
## 
## 当now_hp增加时调用此方法显示恢复效果
## 
## @param target 恢复HP的目标（通常是玩家）
## @param heal_amount 恢复的HP数量
static func show_heal_floating_text(target: Node, heal_amount: int) -> void:
	if not target or heal_amount <= 0:
		return
	
	if FloatingText:
		FloatingText.create_floating_text(
			target.global_position + Vector2(0, -40),
			"+%d" % heal_amount,
			Color(0.0, 1.0, 0.0),  # 绿色
			true  # is_critical=true，使用大字体
		)

## 应用治愈效果
static func _apply_heal(attacker_stats: CombatStats, target, params: Dictionary) -> bool:
	var heal_amount = params.get("amount", 0.0)
	var heal_percent = params.get("percent", 0.0)
	
	# 应用异常效果加成
	if heal_amount > 0:
		heal_amount *= attacker_stats.status_effect_mult
	elif heal_percent > 0:
		heal_percent *= attacker_stats.status_effect_mult
	
	# 检查目标是否有生命值属性
	if not "now_hp" in target or not "max_hp" in target:
		return false
	
	# 计算治愈量
	var actual_heal = 0
	if heal_amount > 0:
		actual_heal = int(heal_amount)
	elif heal_percent > 0:
		actual_heal = int(target.max_hp * heal_percent)
	
	if actual_heal <= 0:
		return false
	
	# 恢复生命值
	var old_hp = target.now_hp
	target.now_hp = min(target.now_hp + actual_heal, target.max_hp)
	actual_heal = target.now_hp - old_hp
	
	# 发送血量变化信号
	if target.has_signal("hp_changed"):
		target.hp_changed.emit(target.now_hp, target.max_hp)
	
	if actual_heal > 0:
		# 显示治愈跳字（使用统一方法）
		show_heal_floating_text(target, actual_heal)
		
		#print("[SpecialEffects] 治愈: +%d HP" % actual_heal)
	
	return true

## 获取目标的BuffSystem
static func _get_buff_system(target) -> Node:
	if not target:
		return null
	
	var buff_system = null
	if target.has_node("BuffSystem"):
		buff_system = target.get_node("BuffSystem")
	elif "buff_system" in target:
		buff_system = target.buff_system
	
	return buff_system

## 概率判定
static func _roll_chance(chance: float) -> bool:
	if chance <= 0:
		return false
	if chance >= 1.0:
		return true
	
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return rng.randf() <= chance

## 处理Buff Tick伤害（用于燃烧、流血、中毒等DoT效果）
## 
## 应该在监听BuffSystem.buff_tick信号的函数中调用
## 
## @param target 受伤的目标
## @param tick_data Buff tick数据
static func apply_dot_damage(target, tick_data: Dictionary) -> void:
	if not target:
		return
	
	if not tick_data.has("effects"):
		return
	
	var effects = tick_data["effects"]
	var stacks = tick_data.get("stacks", 1)
	var buff_id = tick_data.get("buff_id", "unknown")
	
	# 检查是否有DPS数据
	if not effects.has("dps"):
		return
	
	var dps = effects["dps"]
	var damage = int(dps * stacks)  # 堆叠层数影响伤害
	
	if damage <= 0:
		return
	
	# 根据buff_id确定DoT伤害颜色（与效果名称颜色一致）
	var color_config = get_status_color_config(buff_id)
	var dot_color = color_config.get("text_color", Color(1.0, 0.0, 0.0))
	
	# 对目标造成伤害（DoT伤害颜色与效果名称一致）
	if target.has_method("enemy_hurt"):
		# 直接减少HP，不调用enemy_hurt（避免重复显示伤害数字和flash效果）
		if "enemyHP" in target and not target.is_dead:
			# 检查无敌状态
			if target.is_invincible:
				return
			
			target.enemyHP -= damage
			
			# 显示DoT伤害数字（颜色与效果名称一致，字体大一倍）
			if FloatingText:
				FloatingText.create_floating_text(
					target.global_position + Vector2(randf_range(-20, 20), -30),
					"-" + str(damage),
					dot_color,
					true  # is_critical=true，使用大字体
				)
			
			# 检查死亡
			if target.enemyHP <= 0:
				target.enemyHP = 0
				if not target.is_dead:
					target.enemy_dead()

	elif target.has_method("player_hurt"):
		# 玩家DoT伤害 - 通过 player_hurt 处理，确保联网模式下正确同步
		target.player_hurt(damage)
		
		# 显示DoT伤害数字（颜色与效果名称一致，字体大一倍）
		# 注意：在联网模式下，player_hurt 会处理伤害文字显示，这里可能重复
		# 但为了单机模式兼容，仍然保留
		if FloatingText and GameMain.current_mode_id != "online":
			FloatingText.create_floating_text(
				target.global_position + Vector2(randf_range(-20, 20), -30),
				"-" + str(damage),
				dot_color,
				true  # is_critical=true，使用大字体
			)
	
	#print("[SpecialEffects] DoT伤害: %s - %d (层数: %d)" % [buff_id, damage, stacks])

## 应用吸血效果（兼容性方法）
## 
## 保留此方法以兼容旧代码
## 新代码应使用 try_apply_status_effect() 方法
static func apply_lifesteal(attacker, damage_dealt: int, lifesteal_percent: float) -> void:
	if not attacker:
		return
	
	# 创建临时CombatStats用于传递参数
	var temp_stats = CombatStats.new()
	temp_stats.lifesteal_percent = lifesteal_percent
	temp_stats.status_effect_mult = 1.0  # 默认值
	temp_stats.status_chance_mult = 1.0  # 默认值
	temp_stats.status_duration_mult = 1.0  # 默认值
	
	try_apply_status_effect(temp_stats, null, "lifesteal", {
		"attacker": attacker,
		"damage_dealt": damage_dealt,
		"percent": lifesteal_percent
	})
