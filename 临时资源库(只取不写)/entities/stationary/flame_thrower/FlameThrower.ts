/**
 * ============================================================
 * 喷火器单位
 * ============================================================
 * 第二个防御单位，近战范围攻击型
 * 
 * 特性：
 * - 只能攻击周围8格（近战范围 range=1）
 * - 连续发射红色小球作为火焰散射
 * - 每次攻击发射6-8个火焰粒子
 * - 每个粒子独立造成伤害
 * 
 * 属性设计：
 * - 80 生命值
 * - 15 防御力
 * - 5 法术抗性
 * - 2 攻击速度（每秒2次）
 * - 5 攻击力（每个火焰粒子）
 * - 1 攻击范围（只能攻击周围8格）
 */

import { Graphics, Sprite } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../../types';
import { Tower } from '../Tower';
import { AssetManager } from '../../../core/AssetManager';

/**
 * 喷火器攻击范围模板（周围 8 格）
 * 3x3 矩阵，炮台位于中心 (1,1)
 */
const FLAMETHROWER_RANGE_PATTERN = [
    [1, 1, 1],
    [1, 0, 1], // 中心格子不计入
    [1, 1, 1],
];

/**
 * 喷火器默认属性
 */
const FLAMETHROWER_STATS: TowerStats = {
    health: 3000,
    maxHealth: 3000,
    defense: 25,
    magicResist: 20,
    attack: 3,         // 每个火焰粒子的伤害
    attackSpeed: 5,    // 每秒攻击5次
    rangePattern: FLAMETHROWER_RANGE_PATTERN, // 使用内部定义的模板
};

/**
 * 喷火器类
 */
export class FlameThrower extends Tower {
    /** 火焰粒子发射回调 */
    private onFireFlames: ((particles: FlameSpawnData[]) => void) | null = null;

    /** 回调是否已设置的标志（用于Game类判断） */
    public _flameCallbackSet: boolean = false;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param tilePos 格子位置
     */
    constructor(id: string, tilePos: Position) {
        // 使用深拷贝确保每个喷火器有独立的属性
        const stats = { ...FLAMETHROWER_STATS };
        super(id, TowerType.FLAMETHROWER, tilePos, stats);

        // 初始化高清图片精灵
        this.setupSprite();
    }

    /**
     * 设置精灵图渲染
     */
    private setupSprite(): void {
        const texture = AssetManager.getInstance().getTexture('tower_flamethrower');
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
     * 获取名称
     */
    public getName(): string {
        return '喷火器';
    }

    /**
     * 创建喷火器图形
     * 使用橙红色方块主体，带有火焰喷嘴装饰
     */
    protected createGraphics(): Graphics {
        const graphics = new Graphics();

        // 喷火器主体（深红色底座）
        const size = 48;
        graphics.roundRect(-size / 2, -size / 2, size, size, 8);
        graphics.fill({ color: 0x8b0000 }); // 深红色
        graphics.stroke({ color: 0xff4500, width: 2 }); // 橙红色边框

        // 中央燃料罐（圆形）
        graphics.circle(0, 0, 14);
        graphics.fill({ color: 0xff4500 }); // 橙红色
        graphics.stroke({ color: 0xffa500, width: 2 }); // 橙色边框

        // 火焰喷嘴（四个方向的小矩形）
        const nozzleSize = 6;
        const nozzleOffset = 18;

        // 上方喷嘴
        graphics.rect(-nozzleSize / 2, -nozzleOffset - nozzleSize, nozzleSize, nozzleSize);
        graphics.fill({ color: 0xff6347 });

        // 下方喷嘴
        graphics.rect(-nozzleSize / 2, nozzleOffset, nozzleSize, nozzleSize);
        graphics.fill({ color: 0xff6347 });

        // 左方喷嘴
        graphics.rect(-nozzleOffset - nozzleSize, -nozzleSize / 2, nozzleSize, nozzleSize);
        graphics.fill({ color: 0xff6347 });

        // 右方喷嘴
        graphics.rect(nozzleOffset, -nozzleSize / 2, nozzleSize, nozzleSize);
        graphics.fill({ color: 0xff6347 });

        // 中心火焰图标
        graphics.circle(0, 0, 6);
        graphics.fill({ color: 0xffff00 }); // 黄色

        return graphics;
    }

    /**
     * 设置火焰发射回调
     * @param callback 回调函数，接收火焰粒子生成数据数组
     */
    public setOnFireFlames(callback: (particles: FlameSpawnData[]) => void): void {
        this.onFireFlames = callback;
    }

    /**
     * 更新喷火器
     * 重写父类方法以实现散射攻击
     * @param deltaTime 时间增量（秒）
     * @param enemies 敌人列表
     * @returns 发射信息（对于喷火器，shouldFire 表示是否发射火焰）
     */
    public update(
        deltaTime: number,
        enemies: { id: string; position: Position; isAlive: boolean }[]
    ): { shouldFire: boolean; targetId: string | null } {
        if (!this.isAlive()) {
            return { shouldFire: false, targetId: null };
        }

        // 更新攻击冷却
        if (this.attackCooldown > 0) {
            this.attackCooldown -= deltaTime;
        }

        // 检查是否可以攻击
        if (this.attackCooldown <= 0) {
            // 寻找范围内的任意敌人（只需要有敌人在范围内就触发攻击）
            const target = this.findTarget(enemies);

            if (target) {
                // 重置冷却时间
                this.attackCooldown = 1 / this.stats.attackSpeed;

                // 生成火焰粒子数据
                const flameParticles = this.generateFlameParticles();

                // 触发火焰发射回调
                if (this.onFireFlames) {
                    this.onFireFlames(flameParticles);
                }

                // 返回发射信号
                return { shouldFire: true, targetId: target.id };
            }
        }

        return { shouldFire: false, targetId: null };
    }

    /**
     * 生成火焰粒子数据
     * 每次攻击生成6-8个火焰粒子，向周围随机方向散射
     * @returns 火焰粒子生成数据数组
     */
    private generateFlameParticles(): FlameSpawnData[] {
        const particles: FlameSpawnData[] = [];

        // 随机生成6-8个粒子
        const particleCount = 6 + Math.floor(Math.random() * 3);

        for (let i = 0; i < particleCount; i++) {
            // 随机角度（0到360度）
            const angle = Math.random() * Math.PI * 2;

            // 计算方向单位向量
            const direction: Position = {
                x: Math.cos(angle),
                y: Math.sin(angle),
            };

            // 添加一些随机偏移到起始位置
            const offsetDistance = Math.random() * 10;
            const startOffset: Position = {
                x: direction.x * offsetDistance,
                y: direction.y * offsetDistance,
            };

            particles.push({
                startPos: {
                    x: this.getPosition().x + startOffset.x,
                    y: this.getPosition().y + startOffset.y,
                },
                direction,
                damage: this.stats.attack,
                speed: 120 + Math.random() * 60, // 120-180 像素/秒
            });
        }

        return particles;
    }

    /**
     * 获取喷火器信息描述
     */
    public getDescription(): string {
        return `${this.getName()}
生命值: ${this.stats.health}/${this.stats.maxHealth}
防御力: ${this.stats.defense}
法术抗性: ${this.stats.magicResist}
攻击力: ${this.stats.attack}/粒子
攻击速度: ${this.stats.attackSpeed}/秒
攻击范围: 周围8格`;
    }
}

/**
 * 火焰粒子生成数据接口
 * 用于传递给 Game 类创建实际的 FlameParticle 实例
 */
export interface FlameSpawnData {
    /** 起始位置 */
    startPos: Position;
    /** 飞行方向（单位向量） */
    direction: Position;
    /** 伤害值 */
    damage: number;
    /** 飞行速度 */
    speed: number;
}
