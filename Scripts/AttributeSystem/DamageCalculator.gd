extends Node
class_name DamageCalculator

## 伤害计算器
## 
## 职责：统一所有伤害计算逻辑，确保计算规则一致性
## 
## 所有方法都是静态方法，可以直接调用
## 
## 计算公式：
##   武器伤害 = 基础伤害 × 等级倍数 × (1 + Σadd) × Πmult
##   点数减伤率 r = 减伤值 / (减伤值 + K)
##   实际受伤倍率 m = 1 - r = K / (减伤值 + K)
##   防御后伤害 = (原始伤害 - 防御力) × m
## 
## 使用示例（新版 - 推荐）：
##   var damage = DamageCalculator.calculate_damage_by_calc_type(
##       10, 3, WeaponData.CalculationType.MAGIC, player_stats
##   )
## 
## 使用示例（旧版 - 兼容）：
##   var damage = DamageCalculator.calculate_weapon_damage(
##       10, 3, WeaponData.WeaponType.MELEE, player_stats
##   )

## ========== 常量 ==========
## 点数减伤K值（用于伤害结算公式）
const DAMAGE_REDUCTION_K: float = 100.0

## ========== 新版方法（使用 CalculationType）==========

## 根据结算类型计算伤害
## 
## 这是推荐使用的方法，支持行为/结算分离
## 例如：火焰剑（近战行为 + 魔法结算）
## 
## @param base_damage 基础伤害
## @param weapon_level 武器等级（1-5）
## @param calculation_type 结算类型（决定使用哪种属性加成）
## @param attacker_stats 攻击者的战斗属性
## @return 最终伤害
static func calculate_damage_by_calc_type(
	base_damage: int,
	weapon_level: int,
	calculation_type: int,
	attacker_stats: CombatStats
) -> int:
	if base_damage <= 0:
		return base_damage
	
	if not attacker_stats:
		return base_damage
	
	var damage = float(base_damage)
	
	# 1. 武器等级倍数
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	damage *= level_mults.damage_multiplier
	
	# 2. 全局伤害（加法层 + 乘法层）
	damage = damage * (1.0 + attacker_stats.global_damage_add) * attacker_stats.global_damage_mult
	
	# 3. 根据结算类型应用属性加成
	match calculation_type:
		0:  # WeaponData.CalculationType.MELEE
			damage = damage * (1.0 + attacker_stats.melee_damage_add) * attacker_stats.melee_damage_mult
		1:  # WeaponData.CalculationType.RANGED
			damage = damage * (1.0 + attacker_stats.ranged_damage_add) * attacker_stats.ranged_damage_mult
		2:  # WeaponData.CalculationType.MAGIC
			damage = damage * (1.0 + attacker_stats.magic_damage_add) * attacker_stats.magic_damage_mult
	
	return int(max(1.0, damage))

## 根据结算类型计算攻击速度
static func calculate_attack_speed_by_calc_type(
	base_attack_speed: float,
	weapon_level: int,
	calculation_type: int,
	attacker_stats: CombatStats
) -> float:
	if not attacker_stats:
		return base_attack_speed
	
	var speed = base_attack_speed
	
	# 1. 武器等级倍数
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	speed /= level_mults.attack_speed_multiplier
	
	# 2. 全局攻速倍数
	var global_mult = (1.0 + attacker_stats.global_attack_speed_add) * attacker_stats.global_attack_speed_mult
	speed /= global_mult
	
	# 3. 根据结算类型应用攻速倍数
	var type_mult = 1.0
	match calculation_type:
		0:  # MELEE
			type_mult = (1.0 + attacker_stats.melee_speed_add) * attacker_stats.melee_speed_mult
		1:  # RANGED
			type_mult = (1.0 + attacker_stats.ranged_speed_add) * attacker_stats.ranged_speed_mult
		2:  # MAGIC
			type_mult = (1.0 + attacker_stats.magic_speed_add) * attacker_stats.magic_speed_mult
	
	speed /= type_mult
	
	return max(0.05, speed)

## 根据结算类型计算攻击范围
static func calculate_range_by_calc_type(
	base_range: float,
	weapon_level: int,
	calculation_type: int,
	attacker_stats: CombatStats
) -> float:
	if not attacker_stats:
		return base_range
	
	var range_val = base_range
	
	# 1. 武器等级倍数
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	range_val *= level_mults.range_multiplier
	
	# 2. 根据结算类型应用范围倍数
	var type_mult = 1.0
	match calculation_type:
		0:  # MELEE
			type_mult = (1.0 + attacker_stats.melee_range_add) * attacker_stats.melee_range_mult
		1:  # RANGED
			type_mult = (1.0 + attacker_stats.ranged_range_add) * attacker_stats.ranged_range_mult
		2:  # MAGIC
			type_mult = (1.0 + attacker_stats.magic_range_add) * attacker_stats.magic_range_mult
	
	range_val *= type_mult
	
	return max(10.0, range_val)

## ========== 旧版方法（保持兼容性）==========

## 计算武器伤害
## 
## 应用分层加成规则：
##   1. 武器基础伤害 × 武器等级倍数
##   2. × 全局伤害倍数（1 + add）× mult
##   3. × 武器类型伤害倍数（1 + add）× mult
## 
## @param weapon_base_damage 武器基础伤害
## @param weapon_level 武器等级（1-5）
## @param weapon_type 武器类型枚举
## @param attacker_stats 攻击者的战斗属性
## @return 最终武器伤害
static func calculate_weapon_damage(
	weapon_base_damage: int,
	weapon_level: int,
	weapon_type: int,
	attacker_stats: CombatStats
) -> int:
	# 如果原始伤害 <= 0，直接返回（不造成伤害）
	if weapon_base_damage <= 0:
		return weapon_base_damage
	
	if not attacker_stats:
		return weapon_base_damage
	
	var damage = float(weapon_base_damage)
	
	# 1. 武器等级倍数
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	damage *= level_mults.damage_multiplier
	
	# 2. 全局伤害（加法层 + 乘法层）
	damage = damage * (1.0 + attacker_stats.global_damage_add) * attacker_stats.global_damage_mult
	
	# 3. 武器类型伤害（加法层 + 乘法层）
	match weapon_type:
		0:  # WeaponData.WeaponType.RANGED
			damage = damage * (1.0 + attacker_stats.ranged_damage_add) * attacker_stats.ranged_damage_mult
		1:  # WeaponData.WeaponType.MELEE
			damage = damage * (1.0 + attacker_stats.melee_damage_add) * attacker_stats.melee_damage_mult
		2:  # WeaponData.WeaponType.MAGIC
			damage = damage * (1.0 + attacker_stats.magic_damage_add) * attacker_stats.magic_damage_mult
	
	# 保险：只要触发伤害（原始伤害 > 0），最终伤害最小为1
	# 即使经过削减后小于1，也至少造成1点伤害
	return int(max(1.0, damage))

## 计算防御减伤后的伤害
##
## 应用公式：
##   1. 固定减伤：伤害 - 防御力（最少1点）
##   2. 点数减伤：减伤率 r = 减伤值 / (减伤值 + K)，受伤倍率 m = 1 - r = K / (减伤值 + K)
##      最终：伤害 × m（最少1点）
##
## 说明：
## - damage_reduction 是“点数”，不是百分比
## - 当 damage_reduction = 0 时，倍率为 1.0（100% 受伤）
##
## @param raw_damage 原始伤害
## @param defender_stats 防御方的战斗属性
## @return 减伤后的最终伤害
static func calculate_defense_reduction(
	raw_damage: int,
	defender_stats: CombatStats
) -> int:
	# 如果原始伤害 <= 0，直接返回（不造成伤害）
	if raw_damage <= 0:
		return raw_damage
	
	if not defender_stats:
		return raw_damage
	
	var damage := float(raw_damage)
	
	# 1. 固定减伤（防御力）
	damage = max(1.0, damage - float(defender_stats.defense))
	
	# 2. 点数减伤（damage_reduction 是“点数”，不是百分比）
	var reduction_value: float = max(0.0, float(defender_stats.damage_reduction))
	var mult := 1.0
	if reduction_value > 0.0:
		# 0点 => 1.0；点数越高，倍率越低
		mult = DAMAGE_REDUCTION_K / (reduction_value + DAMAGE_REDUCTION_K)
	damage *= mult
	
	# 保险：只要触发伤害（原始伤害 > 0），最终伤害最小为1
	return int(max(1.0, damage))


## 暴击判定
## 
## 根据暴击率随机判定是否暴击
## 
## @param attacker_stats 攻击者的战斗属性
## @return 是否暴击
static func roll_critical(attacker_stats: CombatStats) -> bool:
	if not attacker_stats or attacker_stats.crit_chance <= 0:
		return false
	
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return rng.randf() <= attacker_stats.crit_chance

## 应用暴击伤害倍数
## 
## @param damage 基础伤害
## @param attacker_stats 攻击者的战斗属性
## @return 暴击后的伤害
static func apply_critical_multiplier(damage: int, attacker_stats: CombatStats) -> int:
	if not attacker_stats:
		return damage
	
	return int(damage * attacker_stats.crit_damage)

## 计算攻击速度
## 
## 应用公式：
##   基础攻速 / 等级倍数 / 全局倍数 / 类型倍数
## 
## @param base_attack_speed 武器基础攻速（攻击间隔）
## @param weapon_level 武器等级
## @param weapon_type 武器类型
## @param attacker_stats 攻击者的战斗属性
## @return 最终攻击间隔（秒）
static func calculate_attack_speed(
	base_attack_speed: float,
	weapon_level: int,
	weapon_type: int,
	attacker_stats: CombatStats
) -> float:
	if not attacker_stats:
		return base_attack_speed
	
	var speed = base_attack_speed
	
	# 1. 武器等级倍数
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	speed /= level_mults.attack_speed_multiplier
	
	# 2. 全局攻速倍数
	var global_mult = (1.0 + attacker_stats.global_attack_speed_add) * attacker_stats.global_attack_speed_mult
	speed /= global_mult
	
	# 3. 武器类型攻速倍数
	var type_mult = 1.0
	match weapon_type:
		0:  # RANGED
			type_mult = (1.0 + attacker_stats.ranged_speed_add) * attacker_stats.ranged_speed_mult
		1:  # MELEE
			type_mult = (1.0 + attacker_stats.melee_speed_add) * attacker_stats.melee_speed_mult
		2:  # MAGIC
			type_mult = (1.0 + attacker_stats.magic_speed_add) * attacker_stats.magic_speed_mult
	
	speed /= type_mult
	
	# 确保最小攻速（防止除零）
	return max(0.05, speed)

## 计算攻击范围
## 
## @param base_range 基础范围
## @param weapon_level 武器等级
## @param weapon_type 武器类型
## @param attacker_stats 攻击者的战斗属性
## @return 最终范围
static func calculate_range(
	base_range: float,
	weapon_level: int,
	weapon_type: int,
	attacker_stats: CombatStats
) -> float:
	if not attacker_stats:
		return base_range
	
	var range = base_range
	
	# 1. 武器等级倍数
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	range *= level_mults.range_multiplier
	
	# 2. 应用属性倍数
	var type_mult = attacker_stats.get_final_range_multiplier(weapon_type)
	range *= type_mult
	
	return max(10.0, range)  # 确保最小范围

## 计算近战击退力
## 
## @param base_knockback 基础击退力
## @param attacker_stats 攻击者的战斗属性
## @return 最终击退力
static func calculate_knockback(
	base_knockback: float,
	attacker_stats: CombatStats
) -> float:
	if not attacker_stats:
		return base_knockback
	
	var knockback = base_knockback
	knockback *= attacker_stats.get_final_knockback_multiplier()
	
	return max(0.0, knockback)

## 计算魔法爆炸范围
## 
## @param base_explosion_radius 基础爆炸范围
## @param attacker_stats 攻击者的战斗属性
## @return 最终爆炸范围
static func calculate_explosion_radius(
	base_explosion_radius: float,
	attacker_stats: CombatStats
) -> float:
	if not attacker_stats:
		return base_explosion_radius
	
	var radius = base_explosion_radius
	radius *= attacker_stats.get_final_explosion_radius_multiplier()
	
	return max(10.0, radius)  # 确保最小范围

## 调试输出：打印伤害计算详细信息
## 
## @param weapon_base_damage 武器基础伤害
## @param weapon_level 武器等级
## @param weapon_type 武器类型
## @param attacker_stats 攻击者属性
static func debug_print_damage_calculation(
	weapon_base_damage: int,
	weapon_level: int,
	weapon_type: int,
	attacker_stats: CombatStats
) -> void:
	print("=== 伤害计算详情 ===")
	print("基础伤害: ", weapon_base_damage)
	print("武器等级: ", weapon_level)
	
	var level_mults = WeaponData.get_level_multipliers(weapon_level)
	print("等级倍数: ", level_mults.damage_multiplier)
	
	var damage_after_level = weapon_base_damage * level_mults.damage_multiplier
	print("等级后伤害: ", damage_after_level)
	
	var global_mult = (1.0 + attacker_stats.global_damage_add) * attacker_stats.global_damage_mult
	print("全局倍数: ", global_mult)
	
	var damage_after_global = damage_after_level * global_mult
	print("全局后伤害: ", damage_after_global)
	
	var type_name = ["远程", "近战", "魔法"][weapon_type]
	print("武器类型: ", type_name)
	
	var final_damage = calculate_weapon_damage(weapon_base_damage, weapon_level, weapon_type, attacker_stats)
	print("最终伤害: ", final_damage)
	print("====================")
