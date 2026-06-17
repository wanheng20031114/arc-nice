/**
 * ============================================================
 * 战斗系统
 * ============================================================
 * 管理游戏中的战斗逻辑，包括：
 * - 伤害计算（物理防御、法术抗性）
 * - 碰撞检测
 * - 敌人与子弹的交互
 */

import { Position, Enemy, Tower, Projectile } from '../types';

/**
 * 伤害类型枚举
 */
export enum DamageType {
    PHYSICAL = 'physical',  // 物理伤害
    MAGICAL = 'magical',    // 法术伤害
    TRUE = 'true',          // 真实伤害（无视防御）
}

/**
 * 战斗系统类
 */
export class CombatSystem {
    /**
     * 计算最终伤害值
     * 公式：
     * - 物理伤害 = 攻击力 × (100 / (100 + 防御力))
     * - 法术伤害 = 攻击力 × (100 / (100 + 法术抗性))
     * - 真实伤害 = 攻击力（不受减免）
     * 
     * @param baseDamage 基础伤害值
     * @param damageType 伤害类型
     * @param defense 目标防御力
     * @param magicResist 目标法术抗性
     * @returns 最终伤害值
     */
    public calculateDamage(
        baseDamage: number,
        damageType: DamageType,
        defense: number,
        magicResist: number
    ): number {
        let finalDamage: number;

        // 保底伤害逻辑（参考明日方舟：伤害不低于原攻击力的 5%）
        const minimumDamage = Math.max(1, Math.floor(baseDamage * 0.05));

        switch (damageType) {
            case DamageType.PHYSICAL:
                // 物理伤害：减算公式 [基础攻击 - 防御力]
                // 高防敌人可以大幅削减物理伤害
                finalDamage = Math.max(minimumDamage, baseDamage - defense);
                break;
            case DamageType.MAGICAL:
                // 法术伤害：乘算公式 [基础攻击 * (1 - 抗性/100)]
                // 法术抗性作为百分比减免，Res=50 表示减免 50%
                const resistReduction = Math.min(100, Math.max(0, magicResist)) / 100;
                finalDamage = Math.max(minimumDamage, baseDamage * (1 - resistReduction));
                break;
            case DamageType.TRUE:
                // 真实伤害：不受任何减免
                finalDamage = baseDamage;
                break;
            default:
                finalDamage = baseDamage;
        }

        // 最终伤害取整，且不低于 1
        return Math.max(1, Math.floor(finalDamage));
    }

    /**
     * 计算两点之间的距离（像素）
     * @param pos1 位置1
     * @param pos2 位置2
     * @returns 距离（像素）
     */
    public getDistance(pos1: Position, pos2: Position): number {
        const dx = pos2.x - pos1.x;
        const dy = pos2.y - pos1.y;
        return Math.sqrt(dx * dx + dy * dy);
    }

    /**
     * 检查目标是否在攻击范围内
     * @param attacker 攻击者位置
     * @param target 目标位置
     * @param range 攻击范围（像素）
     * @returns 是否在范围内
     */
    public isInRange(attacker: Position, target: Position, range: number): boolean {
        return this.getDistance(attacker, target) <= range;
    }

    /**
     * 检查圆形碰撞
     * @param pos1 位置1
     * @param radius1 半径1
     * @param pos2 位置2
     * @param radius2 半径2
     * @returns 是否碰撞
     */
    public checkCircleCollision(
        pos1: Position,
        radius1: number,
        pos2: Position,
        radius2: number
    ): boolean {
        const distance = this.getDistance(pos1, pos2);
        return distance < radius1 + radius2;
    }

    /**
     * 检查点是否在矩形内
     * @param point 点位置
     * @param rectX 矩形左上角X
     * @param rectY 矩形左上角Y
     * @param rectWidth 矩形宽度
     * @param rectHeight 矩形高度
     * @returns 是否在矩形内
     */
    public isPointInRect(
        point: Position,
        rectX: number,
        rectY: number,
        rectWidth: number,
        rectHeight: number
    ): boolean {
        return (
            point.x >= rectX &&
            point.x <= rectX + rectWidth &&
            point.y >= rectY &&
            point.y <= rectY + rectHeight
        );
    }

    /**
     * 在敌人列表中查找距离指定位置最近的敌人
     * @param position 参考位置
     * @param enemies 敌人列表
     * @param maxRange 最大搜索范围（可选）
     * @returns 最近的敌人，如果没有则返回 null
     */
    public findNearestEnemy(
        position: Position,
        enemies: { id: string; position: Position; isAlive: boolean }[],
        maxRange?: number
    ): { id: string; position: Position; isAlive: boolean } | null {
        let nearest: { id: string; position: Position; isAlive: boolean } | null = null;
        let nearestDistance = Infinity;

        for (const enemy of enemies) {
            // 跳过死亡的敌人
            if (!enemy.isAlive) continue;

            const distance = this.getDistance(position, enemy.position);

            // 如果设置了最大范围，检查是否在范围内
            if (maxRange !== undefined && distance > maxRange) continue;

            if (distance < nearestDistance) {
                nearestDistance = distance;
                nearest = enemy;
            }
        }

        return nearest;
    }

    /**
     * 计算从起点到目标的移动向量（单位向量）
     * @param from 起点
     * @param to 目标点
     * @returns 单位向量 { x, y }
     */
    public getDirectionVector(from: Position, to: Position): Position {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        if (distance === 0) {
            return { x: 0, y: 0 };
        }

        return {
            x: dx / distance,
            y: dy / distance,
        };
    }
}
