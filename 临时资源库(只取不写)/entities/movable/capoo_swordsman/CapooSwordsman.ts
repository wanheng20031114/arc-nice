/**
 * ============================================================
 * Capoo 剑士
 * ============================================================
 * 一种高级敌人类型，具有以下属性：
 * - 生命值：250
 * - 防御力：10
 * - 法术抗性：10
 * - 移动速度：每秒 0.8 格 (较快)
 */

import { Graphics, Sprite } from 'pixi.js';
import { Position, EnemyStats, EnemyType } from '../../../types';
import { Enemy } from '../Enemy';
import { AssetManager } from '../../../core/AssetManager';

/**
 * Capoo 剑士默认属性
 */
const CAPOO_STATS: EnemyStats = {
    health: 250,
    maxHealth: 250,
    attack: 0, // 剑士没有远程攻击，暂为0
    defense: 10,
    magicResist: 10,
    moveSpeed: 0.8, // 每秒移动0.8格，比僵尸快
};

/**
 * Capoo 剑士类
 */
export class CapooSwordsman extends Enemy {
    /**
     * 构造函数
     * @param id 唯一ID
     * @param startPos 起始像素位置
     */
    constructor(id: string, startPos: Position) {
        // 使用深拷贝确保每个敌人有独立的属性
        const stats = { ...CAPOO_STATS };
        super(id, EnemyType.CAPOO_SWORDSMAN, startPos, stats);

        // 尝试加载高清图片材质
        this.setupSprite();
    }

    /**
     * 设置精灵图渲染
     */
    private setupSprite(): void {
        const texture = AssetManager.getInstance().getTexture('enemy_capoo');
        if (texture) {
            // 创建精灵图
            const sprite = new Sprite(texture);

            // 设置锚点到中心，方便对齐
            sprite.anchor.set(0.5);

            // 自动缩放到格子大小 (64x64)
            sprite.width = 60;  // 稍微比格子小一点，留点缝隙感
            sprite.height = 60;

            // 将原来的占位图形隐藏或清除
            this.graphics.visible = false;

            // 添加到显示容器中
            this.container.addChild(sprite);
        }
    }

    /**
     * 创建敌人图形
     * 优先尝试使用 128x128 的图片纹理，若无则回退到蓝色球体
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();

        // 尝试从资源管理器获取纹理 (假设未来会注册为 'enemy_capoo')
        // 目前先实现蓝色球体作为默认占位
        this.drawPlaceholder(graphics);

        return graphics;
    }

    /**
     * 绘制占位蓝色球体
     */
    private drawPlaceholder(graphics: Graphics): void {
        // 外层淡蓝色发光
        graphics.circle(0, 0, 24);
        graphics.fill({ color: 0x3498db, alpha: 0.3 });

        // 核心深蓝色球体
        graphics.circle(0, 0, 18);
        graphics.fill({ color: 0x2980b9 });
        graphics.stroke({ color: 0x3498db, width: 3 });

        // 高光效果
        graphics.circle(-6, -6, 5);
        graphics.fill({ color: 0xffffff, alpha: 0.4 });
    }

    /**
     * 获取敌人信息描述
     */
    public getDescription(): string {
        return `Capoo 剑士
生命值: ${Math.floor(this.stats.health)}/${this.stats.maxHealth}
防御力: ${this.stats.defense}
法术抗性: ${this.stats.magicResist}
移动速度: ${this.stats.moveSpeed}格/秒`;
    }
}
