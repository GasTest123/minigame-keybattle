extends BaseGameMode
class_name SurvivalMode

## 生存模式 - 当前游戏的默认模式

func _init() -> void:
	mode_id = "survival"
	mode_name = "生存模式"
	mode_description = "消灭所有敌人以获得胜利，可以复活"
	total_waves = GameConfig.total_waves
	#victory_condition_type = "keys"
	victory_condition_type = "waves"
	wave_config_id = "stage1"  # 使用默认波次配置（从JSON加载）
	victory_waves = 30  # 生存模式胜利条件：完成30波（阶段1）
	self.victory2_waves = 100  # 生存模式胜利条件：完成100波（阶段2）
	#victory_keys = 200  # 生存模式胜利条件：收集200把钥匙
	#victory_keys = GameConfig.keys_required  # 从GameConfig读取胜利钥匙数
	allow_revive = true  # 生存模式允许复活
	initial_gold = 10  # 生存模式初始gold数量
	initial_master_key = 5  # 生存模式初始masterkey数量
	spawn_indicator_delay = 0.5  # 敌人刷新预警延迟（秒）

## 注意：波次配置已由wave_system_v3从JSON文件（wave_config_id）加载，不再使用硬编码配置
## 注意：胜利失败判定已由base_game_mode统一实现，通过配置参数控制

## Survival 二阶段：动态目标波数
func get_victory_waves_target() -> int:
	if GameMain.current_session and "survival_stage" in GameMain.current_session:
		var stage := int(GameMain.current_session.survival_stage)
		if stage >= 2:
			return self.victory2_waves
	return victory_waves
