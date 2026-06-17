/**
 * ============================================================
 * 僵尸敌人
 * ============================================================
 * 第一种敌人类型，具有以下属性：
 * - 移动速度：每秒 0.5 格
 * - 自动寻路走地面，高台无法穿过
 */

import { Graphics } from 'pixi.js';
import { Position, EnemyStats, EnemyType } from '../../../types';
import { Enemy } from '../Enemy';

/**
 * 僵尸默认属性
 */
const ZOMBIE_STATS: EnemyStats = {
    attack: 0,
    health: 100,
    maxHealth: 100,  // 与 health 保持一致
    defense: 1,
    magicResist: 0,
    moveSpeed: 0.5,  // 每秒移动0.5格
};

/**
 * 僵尸敌人类
 */
export class Zombie extends Enemy {
    /**
     * 构造函数
     * @param id 唯一ID
     * @param startPos 起始像素位置
     */
    constructor(id: string, startPos: Position) {
        // 使用深拷贝确保每个敌人有独立的属性
        const stats = { ...ZOMBIE_STATS };
        super(id, EnemyType.ZOMBIE, startPos, stats);
    }

    /**
     * 创建僵尸图形
     * 使用占位符图形（64x64 像素的绿色圆形）
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();

        // 僵尸身体（深绿色椭圆）
        graphics.ellipse(0, 5, 18, 22);
        graphics.fill({ color: 0x27ae60 });
        graphics.stroke({ color: 0x1e8449, width: 2 });

        // 僵尸头部（浅绿色圆形）
        graphics.circle(0, -15, 12);
        graphics.fill({ color: 0x2ecc71 });
        graphics.stroke({ color: 0x27ae60, width: 2 });

        // 眼睛（红色）
        graphics.circle(-5, -17, 3);
        graphics.fill({ color: 0xe74c3c });

        graphics.circle(5, -17, 3);
        graphics.fill({ color: 0xe74c3c });

        // 嘴巴（黑色横线）
        graphics.moveTo(-6, -10);
        graphics.lineTo(6, -10);
        graphics.stroke({ color: 0x000000, width: 2 });

        return graphics;
    }

    /**
     * 获取敌人信息描述
     */
    public getDescription(): string {
        return `僵尸
生命值: ${this.stats.health}/${this.stats.maxHealth}
防御力: ${this.stats.defense}
法术抗性: ${this.stats.magicResist}
移动速度: ${this.stats.moveSpeed}格/秒`;
    }
}
