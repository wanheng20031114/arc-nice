/**
 * ============================================================
 * 原型炮台
 * ============================================================
 * 第一个防御单位，具有以下属性：
 * - 100 生命值
 * - 20 防御力
 * - 10 法术抗性
 * - 1 攻击速度（每秒1次）
 * - 10 攻击力
 * - 只能放置在高台上
 */

import { Graphics, Sprite } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../../types';
import { Tower } from '../Tower';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 原型炮台攻击范围模板（半径为3的圆形/菱形）
 * 7x7 矩阵，炮台位于中心 (3,3)
 */
const PROTOTYPE_RANGE_PATTERN = [
    [0, 0, 1, 1, 1, 0, 0],
    [0, 1, 1, 1, 1, 1, 0],
    [1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1], // 中心行
    [1, 1, 1, 1, 1, 1, 1],
    [0, 1, 1, 1, 1, 1, 0],
    [0, 0, 1, 1, 1, 0, 0],
];

/**
 * 原型炮台默认属性
 */
const PROTOTYPE_TOWER_STATS: TowerStats = {
    health: 2000,
    maxHealth: 2000,
    defense: 10,
    magicResist: 10,
    attack: 20,
    attackSpeed: 1,  // 每秒攻击1次
    rangePattern: PROTOTYPE_RANGE_PATTERN, // 使用内部定义的模板
};

/**
 * 原型炮台类
 */
export class PrototypeTower extends Tower {
    /**
     * 构造函数
     * @param id 唯一ID
     * @param tilePos 格子位置
     */
    constructor(id: string, tilePos: Position) {
        // 使用深拷贝确保每个炮台有独立的属性
        const stats = { ...PROTOTYPE_TOWER_STATS };
        super(id, TowerType.PROTOTYPE, tilePos, stats);

        // 初始化高清图片精灵
        this.setupSprite();
    }

    /**
     * 设置精灵图渲染
     */
    private setupSprite(): void {
        const texture = AssetManager.getInstance().getTexture('tower_prototype');
        if (texture) {
            // 创建精灵图
            const sprite = new Sprite(texture);

            // 设置锚点到中心，方便对齐
            sprite.anchor.set(0.5);

            // 自动缩放到格子大小 (64x64)
            sprite.width = 64;
            sprite.height = 64;

            // 将原来的占位图形隐藏
            this.graphics.visible = false;

            // 添加到显示容器中
            this.container.addChild(sprite);
        }
    }

    /**
     * 创建原型炮台图形
     * 使用占位符图形（64x64 像素的蓝色方块）
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();

        // 炮台主体（深蓝色底座）
        const size = 48;
        graphics.roundRect(-size / 2, -size / 2, size, size, 8);
        graphics.fill({ color: 0x2c3e50 });
        graphics.stroke({ color: 0x3498db, width: 2 });

        // 炮塔（中央圆形）
        graphics.circle(0, 0, 16);
        graphics.fill({ color: 0x3498db });
        graphics.stroke({ color: 0x2980b9, width: 2 });

        // 炮管（向上的矩形）
        graphics.rect(-4, -28, 8, 20);
        graphics.fill({ color: 0x2c3e50 });
        graphics.stroke({ color: 0x3498db, width: 1 });

        return graphics;
    }

    /**
     * 获取名称
     */
    public getName(): string {
        return '原型炮台';
    }

    /**
     * 获取炮台信息描述
     */
    public getDescription(): string {
        return `${this.getName()}
生命值: ${this.stats.health}/${this.stats.maxHealth}
防御力: ${this.stats.defense}
法术抗性: ${this.stats.magicResist}
攻击力: ${this.stats.attack}
攻击速度: ${this.stats.attackSpeed}/秒
攻击范围: 自定义`;
    }
}
