/**
 * ============================================================
 * 珍珠投射物（BubblePearl）
 * ============================================================
 * 珍珠奶茶 Capoo 发射的棕色小球投射物
 * 高速飞向目标炮台，命中时造成物理伤害
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../../types';

/**
 * 珍珠投射物类
 */
export class BubblePearl {
    /** 显示容器 */
    private container: Container;

    /** 珍珠图形 */
    private graphics: Graphics;

    /** 当前位置 */
    private position: Position;

    /** 目标位置 */
    private targetPos: Position;

    /** 移动速度（像素/秒） */
    private speed: number = 400;

    /** 伤害值 */
    public readonly damage: number;

    /** 目标炮台 ID */
    public readonly targetId: string;

    /** 发射者 ID */
    public readonly ownerId: string;

    /** 是否存活 */
    private alive: boolean = true;

    /** 珍珠大小 */
    private readonly size: number = 6;

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

        // 绘制珍珠（棕色小球）
        this.draw();

        // 设置初始位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;
    }

    /**
     * 绘制珍珠
     */
    private draw(): void {
        this.graphics.clear();

        // 棕色珍珠主体
        this.graphics.circle(0, 0, this.size);
        this.graphics.fill({ color: 0x8B4513 }); // 棕色

        // 高光
        this.graphics.circle(-this.size / 3, -this.size / 3, this.size / 3);
        this.graphics.fill({ color: 0xA0522D, alpha: 0.8 });
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

        // 命中检测（距离小于 10 像素）
        if (distance < 10) {
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
