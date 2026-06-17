/**
 * ============================================================
 * AK47 子弹（AK47Bullet）
 * ============================================================
 * AK47 Capoo 发射的高速小型子弹
 * 比珍珠更小、速度更快
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../../types';

/**
 * AK47 子弹类
 */
export class AK47Bullet {
    /** 显示容器 */
    private container: Container;

    /** 子弹图形 */
    private graphics: Graphics;

    /** 当前位置 */
    private position: Position;

    /** 目标位置 */
    private targetPos: Position;

    /** 移动速度（像素/秒）- 比珍珠快很多 */
    private speed: number = 800;

    /** 伤害值 */
    public readonly damage: number;

    /** 目标炮台 ID */
    public readonly targetId: string;

    /** 发射者 ID */
    public readonly ownerId: string;

    /** 是否存活 */
    private alive: boolean = true;

    /** 子弹大小 - 比珍珠小 */
    private readonly size: number = 3;

    /**
     * 构造函数
     * @param startPos 起始位置
     * @param targetPos 目标位置
     * @param damage 伤害值
     * @param targetId 目标炮台 ID
     * @param ownerId 发射者 ID
     */
    constructor(
        startPos: Position,
        targetPos: Position,
        damage: number,
        targetId: string,
        ownerId: string
    ) {
        this.position = { ...startPos };
        this.targetPos = { ...targetPos };
        this.damage = damage;
        this.targetId = targetId;
        this.ownerId = ownerId;

        this.container = new Container();
        this.graphics = new Graphics();
        this.container.addChild(this.graphics);

        // 绘制子弹
        this.draw();

        // 设置初始位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;
    }

    /**
     * 绘制子弹（金黄色小子弹）
     */
    private draw(): void {
        this.graphics.clear();

        // 金黄色子弹主体（椭圆形更像子弹）
        this.graphics.ellipse(0, 0, this.size * 1.5, this.size);
        this.graphics.fill({ color: 0xFFD700 }); // 金黄色

        // 子弹尾部拖影
        this.graphics.ellipse(-this.size, 0, this.size * 0.8, this.size * 0.6);
        this.graphics.fill({ color: 0xFFA500, alpha: 0.5 }); // 橙色半透明
    }

    /**
     * 更新
     * @param deltaTime 时间增量（秒）
     * @returns 是否命中目标
     */
    public update(deltaTime: number): boolean {
        if (!this.alive) return false;

        // 计算方向
        const dx = this.targetPos.x - this.position.x;
        const dy = this.targetPos.y - this.position.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        // 命中检测（距离小于 8 像素）
        if (distance < 8) {
            this.alive = false;
            return true; // 命中
        }

        // 移动
        const moveDistance = this.speed * deltaTime;
        if (moveDistance >= distance) {
            // 直接到达目标
            this.position.x = this.targetPos.x;
            this.position.y = this.targetPos.y;
            this.alive = false;
            return true; // 命中
        }

        // 正常移动
        const dirX = dx / distance;
        const dirY = dy / distance;
        this.position.x += dirX * moveDistance;
        this.position.y += dirY * moveDistance;

        // 更新显示位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 让子弹朝向目标方向旋转
        this.container.rotation = Math.atan2(dy, dx);

        return false; // 未命中
    }

    /**
     * 是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 获取容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 销毁
     */
    public destroy(): void {
        this.container.destroy({ children: true });
    }
}
