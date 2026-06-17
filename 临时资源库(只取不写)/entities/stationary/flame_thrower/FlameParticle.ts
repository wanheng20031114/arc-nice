/**
 * ============================================================
 * 火焰粒子类
 * ============================================================
 * 喷火器发射的火焰粒子，表现为红色小球
 * 特性：
 * - 红色圆形小球（半径4-6像素）
 * - 直线飞行，无追踪
 * - 有限生命时间，超时自动消失
 * - 与敌人碰撞后消失并造成伤害
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../../types';

/**
 * 火焰粒子类
 */
export class FlameParticle {
    /** 粒子唯一ID */
    public readonly id: string;

    /** 当前像素位置 */
    private position: Position;

    /** 移动方向（单位向量） */
    private direction: Position;

    /** 移动速度（像素/秒） */
    private speed: number;

    /** 伤害值 */
    private damage: number;

    /** 发射者ID（炮台） */
    public readonly ownerId: string;

    /** 生命时间计时器（秒） */
    private lifeTime: number;

    /** 最大生命时间（秒） */
    private readonly maxLifeTime: number = 0.5;

    /** 是否存活 */
    private alive: boolean = true;

    /** PixiJS 显示容器 */
    private container: Container;

    /** 粒子图形 */
    private graphics: Graphics;

    /** 粒子半径 */
    private radius: number;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param startPos 起始像素位置
     * @param direction 飞行方向（单位向量）
     * @param damage 伤害值
     * @param speed 飞行速度（像素/秒）
     * @param ownerId 发射者ID
     */
    constructor(
        id: string,
        startPos: Position,
        direction: Position,
        damage: number,
        speed: number,
        ownerId: string
    ) {
        this.id = id;
        this.position = { ...startPos };
        this.direction = { ...direction };
        this.damage = damage;
        this.speed = speed;
        this.ownerId = ownerId;
        this.lifeTime = 0;

        // 随机半径（4-6像素）
        this.radius = 4 + Math.random() * 2;

        // 创建显示容器
        this.container = new Container();
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 创建火焰粒子图形
        this.graphics = this.createGraphics();
        this.container.addChild(this.graphics);
    }

    /**
     * 创建火焰粒子图形
     * 红色/橙色小球，带有发光效果
     */
    private createGraphics(): Graphics {
        const graphics = new Graphics();

        // 外层发光效果（橙色，半透明）
        graphics.circle(0, 0, this.radius + 2);
        graphics.fill({ color: 0xff6600, alpha: 0.4 });

        // 核心火焰（红色）
        graphics.circle(0, 0, this.radius);
        graphics.fill({ color: 0xff3300 });

        // 中心亮点（黄色）
        graphics.circle(0, 0, this.radius * 0.4);
        graphics.fill({ color: 0xffff00, alpha: 0.8 });

        return graphics;
    }

    /**
     * 更新粒子状态
     * @param deltaTime 时间增量（秒）
     * @returns 是否仍然存活
     */
    public update(deltaTime: number): boolean {
        if (!this.alive) {
            return false;
        }

        // 更新生命时间
        this.lifeTime += deltaTime;
        if (this.lifeTime >= this.maxLifeTime) {
            this.alive = false;
            return false;
        }

        // 更新位置
        this.position.x += this.direction.x * this.speed * deltaTime;
        this.position.y += this.direction.y * this.speed * deltaTime;

        // 更新显示位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 随着生命时间减少透明度，产生消散效果
        const lifeRatio = 1 - this.lifeTime / this.maxLifeTime;
        this.container.alpha = lifeRatio;

        return true;
    }

    /**
     * 检查与敌人的碰撞
     * @param enemyPos 敌人像素位置
     * @param enemyRadius 敌人碰撞半径
     * @returns 是否碰撞
     */
    public checkCollision(enemyPos: Position, enemyRadius: number = 20): boolean {
        const dx = this.position.x - enemyPos.x;
        const dy = this.position.y - enemyPos.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        return distance < this.radius + enemyRadius;
    }

    /**
     * 标记为命中（销毁粒子）
     */
    public hit(): void {
        this.alive = false;
    }

    /**
     * 获取显示容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 获取当前位置
     */
    public getPosition(): Position {
        return { ...this.position };
    }

    /**
     * 获取伤害值
     */
    public getDamage(): number {
        return this.damage;
    }

    /**
     * 检查是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 销毁粒子
     */
    public destroy(): void {
        this.container.destroy({ children: true });
    }
}
