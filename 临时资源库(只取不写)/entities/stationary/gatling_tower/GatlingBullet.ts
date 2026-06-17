/**
 * ============================================================
 * 加特林子弹类
 * ============================================================
 * 加特林塔发射的小型高速子弹
 * 比普通子弹更小、更快
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../../types';

/**
 * 加特林子弹类
 */
export class GatlingBullet {
    /** 子弹唯一ID */
    public readonly id: string;

    /** 当前像素位置 */
    private position: Position;

    /** 伤害值 */
    private damage: number;

    /** 移动速度（像素/秒） */
    private speed: number;

    /** 目标敌人ID */
    private targetId: string;

    /** 发射者ID（炮台） */
    private ownerId: string;

    /** 是否存活（未命中前为true） */
    private alive: boolean = true;

    /** PixiJS 显示容器 */
    private container: Container;

    /** 子弹图形 */
    private graphics: Graphics;

    /** 目标位置（用于追踪） */
    private targetPosition: Position | null = null;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param startPos 起始位置
     * @param damage 伤害值
     * @param speed 移动速度（像素/秒）
     * @param targetId 目标敌人ID
     * @param ownerId 发射者ID
     */
    constructor(
        id: string,
        startPos: Position,
        damage: number,
        speed: number,
        targetId: string,
        ownerId: string
    ) {
        this.id = id;
        this.position = { ...startPos };
        this.damage = damage;
        this.speed = speed;
        this.targetId = targetId;
        this.ownerId = ownerId;

        // 创建显示容器
        this.container = new Container();
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 创建图形
        this.graphics = this.createGraphics();
        this.container.addChild(this.graphics);
    }

    /**
     * 创建小型子弹图形
     */
    private createGraphics(): Graphics {
        const graphics = new Graphics();

        // 小型子弹主体（亮黄色小圆形）
        graphics.circle(0, 0, 3);
        graphics.fill({ color: 0xffdd00 });

        // 轻微发光效果
        graphics.circle(0, 0, 4);
        graphics.stroke({ color: 0xffaa00, width: 1, alpha: 0.6 });

        return graphics;
    }

    /**
     * 更新目标位置
     * @param targetPos 目标当前位置
     */
    public updateTargetPosition(targetPos: Position): void {
        this.targetPosition = { ...targetPos };
    }

    /**
     * 更新子弹状态
     * @param deltaTime 时间增量（秒）
     * @returns 是否命中目标（需要处理伤害）
     */
    public update(deltaTime: number): boolean {
        if (!this.alive || !this.targetPosition) return false;

        // 计算朝向目标的方向
        const dx = this.targetPosition.x - this.position.x;
        const dy = this.targetPosition.y - this.position.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        // 检测命中（距离小于阈值）
        if (distance < 15) {
            this.alive = false;
            return true; // 命中
        }

        // 移动子弹
        const moveDistance = this.speed * deltaTime;
        if (moveDistance >= distance) {
            // 本帧可到达目标
            this.position = { ...this.targetPosition };
            this.alive = false;
            return true;
        } else {
            // 正常移动
            const ratio = moveDistance / distance;
            this.position.x += dx * ratio;
            this.position.y += dy * ratio;
        }

        // 更新显示位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        return false;
    }

    /**
     * 获取伤害值
     */
    public getDamage(): number {
        return this.damage;
    }

    /**
     * 获取目标ID
     */
    public getTargetId(): string {
        return this.targetId;
    }

    /**
     * 获取发射者ID
     */
    public getOwnerId(): string {
        return this.ownerId;
    }

    /**
     * 获取当前位置
     */
    public getPosition(): Position {
        return { ...this.position };
    }

    /**
     * 是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 获取显示容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 销毁
     */
    public destroy(): void {
        this.alive = false;
        this.container.destroy({ children: true });
    }
}
