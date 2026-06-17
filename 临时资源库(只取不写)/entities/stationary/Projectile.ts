/**
 * ============================================================
 * 子弹/弹药类
 * ============================================================
 * 炮台发射的跟踪子弹
 * 追踪最近的敌人，命中后造成伤害
 */

import { Container, Graphics } from 'pixi.js';
import { Position } from '../../types';

/**
 * 子弹类
 */
export class Projectile {
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
     * 创建子弹图形
     */
    private createGraphics(): Graphics {
        const graphics = new Graphics();

        // 子弹主体（黄色发光圆形）
        graphics.circle(0, 0, 6);
        graphics.fill({ color: 0xf1c40f });

        // 外发光效果
        graphics.circle(0, 0, 8);
        graphics.stroke({ color: 0xf39c12, width: 2, alpha: 0.5 });

        return graphics;
    }

    /**
     * 更新目标位置
     * @param targetPos 目标当前位置
     */
    public updateTargetPosition(targetPos: Position | null): void {
        this.targetPosition = targetPos;
    }

    /**
     * 更新子弹
     * @param deltaTime 时间增量（秒）
     * @returns 是否命中目标
     */
    public update(deltaTime: number): boolean {
        if (!this.alive || !this.targetPosition) {
            return false;
        }

        // 计算到目标的方向
        const dx = this.targetPosition.x - this.position.x;
        const dy = this.targetPosition.y - this.position.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        // 计算本帧移动距离
        const moveDistance = this.speed * deltaTime;

        // 检查是否命中
        if (distance <= moveDistance || distance < 10) {
            this.position.x = this.targetPosition.x;
            this.position.y = this.targetPosition.y;
            return true; // 命中
        }

        // 向目标移动
        const ratio = moveDistance / distance;
        this.position.x += dx * ratio;
        this.position.y += dy * ratio;

        // 更新显示位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 旋转子弹朝向目标
        this.container.rotation = Math.atan2(dy, dx);

        return false;
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
     * 检查是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 标记为命中（销毁）
     */
    public hit(): void {
        this.alive = false;
    }

    /**
     * 销毁子弹
     */
    public destroy(): void {
        this.container.destroy({ children: true });
    }
}
