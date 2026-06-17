/**
 * ============================================================
 * 敌人基类
 * ============================================================
 * 定义敌人的基本属性和行为
 * 敌人从红门生成，沿地面行走到蓝门
 */

import { Container, Graphics } from 'pixi.js';
import { Position, EnemyStats, EnemyType } from '../../types';

/**
 * 敌人基类
 */
export abstract class Enemy {
    /** 敌人唯一ID */
    public readonly id: string;

    /** 敌人类型 */
    public readonly type: EnemyType;

    /** 敌人属性 */
    protected stats: EnemyStats;

    /** 当前像素位置 */
    protected position: Position;

    /** 是否存活 */
    protected alive: boolean = true;

    /** 当前移动路径（格子坐标） */
    protected path: Position[] = [];

    /** 当前路径索引 */
    protected pathIndex: number = 0;

    /** PixiJS 显示容器 */
    protected container: Container;

    /** 敌人图形 */
    protected graphics: Graphics;

    /** 生命条图形 */
    protected healthBar: Graphics;

    /** 格子大小 */
    protected readonly tileSize: number = 64;

    /** 
     * 攻击范围模板（二维数组，1表示可攻击，0表示不可攻击）
     * 中心点为数组中心，与 Tower 的 rangePattern 一致
     * 默认为自身所在格 [[1]]
     */
    protected rangePattern: number[][] = [[1]];

    /**
     * 构造函数
     * @param id 唯一ID
     * @param type 敌人类型
     * @param startPos 起始像素位置
     * @param stats 敌人属性
     */
    constructor(id: string, type: EnemyType, startPos: Position, stats: EnemyStats) {
        this.id = id;
        this.type = type;
        this.position = { ...startPos };
        this.stats = stats;

        // 创建显示容器
        this.container = new Container();
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 创建图形
        this.graphics = this.createGraphics();
        this.container.addChild(this.graphics);

        // 创建生命条（注意：不再直接添加到 container，由 Game 类管理图层）
        this.healthBar = this.createHealthBar();

        console.log(`[敌人] 创建 ${type}，起始位置: (${startPos.x}, ${startPos.y})`);
    }

    /**
     * 创建敌人图形（由子类实现）
     */
    protected abstract createGraphics(): Graphics;

    /**
     * 创建生命条
     */
    protected createHealthBar(): Graphics {
        const bar = new Graphics();
        this.updateHealthBar(bar);
        // 设置血条初始位置（全局坐标，因为血条会被添加到独立图层）
        bar.x = this.position.x;
        bar.y = this.position.y;
        return bar;
    }

    /**
     * 更新生命条显示
     */
    protected updateHealthBar(bar?: Graphics): void {
        const healthBar = bar || this.healthBar;
        healthBar.clear();

        const barWidth = 40;
        const barHeight = 5;
        const healthPercent = this.stats.health / this.stats.maxHealth;

        // 背景（黑色）
        healthBar.rect(-barWidth / 2, -30, barWidth, barHeight);
        healthBar.fill({ color: 0x000000 });

        // 生命值颜色：满血鲜红，血越少越深红
        // 鲜红 0xff3333 → 深红 0x8b0000
        const clampedPercent = Math.max(0, Math.min(1, healthPercent));
        const r = Math.floor(139 + clampedPercent * 116); // 139 → 255
        const g = Math.floor(clampedPercent * 51);        // 0 → 51
        const b = Math.floor(clampedPercent * 51);        // 0 → 51
        const healthColor = (r << 16) | (g << 8) | b;
        healthBar.rect(-barWidth / 2, -30, barWidth * healthPercent, barHeight);
        healthBar.fill({ color: healthColor });

        // 边框
        healthBar.rect(-barWidth / 2, -30, barWidth, barHeight);
        healthBar.stroke({ color: 0xffffff, width: 1 });
    }

    /**
     * 设置行走路径
     * @param path 路径数组（格子坐标）
     */
    public setPath(path: Position[]): void {
        this.path = path;
        this.pathIndex = 0;
        console.log(`[敌人] ${this.id} 设置路径，长度: ${path.length}`);
    }

    /**
     * 更新敌人
     * @param deltaTime 时间增量（秒）
     * @returns 是否到达终点
     */
    public update(deltaTime: number): boolean {
        if (!this.alive || this.path.length === 0) {
            return false;
        }

        // 检查是否已到达终点
        if (this.pathIndex >= this.path.length) {
            return true; // 到达蓝门
        }

        // 获取当前目标格子
        const targetTile = this.path[this.pathIndex];
        const targetPos = {
            x: targetTile.x * this.tileSize + this.tileSize / 2,
            y: targetTile.y * this.tileSize + this.tileSize / 2,
        };

        // 计算移动方向
        const dx = targetPos.x - this.position.x;
        const dy = targetPos.y - this.position.y;
        const distance = Math.sqrt(dx * dx + dy * dy);

        // 计算本帧移动距离（像素）
        const moveDistance = this.stats.moveSpeed * this.tileSize * deltaTime;

        if (distance <= moveDistance) {
            // 到达目标格子
            this.position.x = targetPos.x;
            this.position.y = targetPos.y;
            this.pathIndex++;

            // 检查是否到达终点
            if (this.pathIndex >= this.path.length) {
                return true;
            }
        } else {
            // 向目标移动
            const ratio = moveDistance / distance;
            this.position.x += dx * ratio;
            this.position.y += dy * ratio;
        }

        // 更新显示位置
        this.container.x = this.position.x;
        this.container.y = this.position.y;

        // 同步血条位置（因为血条已移至全局血条层，不再随本体容器移动）
        this.healthBar.x = this.position.x;
        this.healthBar.y = this.position.y;

        return false;
    }

    /**
     * 受到伤害
     * @param damage 伤害值
     */
    public takeDamage(damage: number): void {
        this.stats.health -= damage;
        this.updateHealthBar();

        if (this.stats.health <= 0) {
            this.stats.health = 0;
            this.alive = false;
            console.log(`[敌人] ${this.type} 被击杀`);
        }
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
     * 获取防御力
     */
    public getDefense(): number {
        return this.stats.defense;
    }

    /**
     * 获取法术抗性
     */
    public getMagicResist(): number {
        return this.stats.magicResist;
    }

    /**
     * 检查是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 获取血条容器
     * 用于在全局血条层显示，确保血条始终在最上方
     */
    public getHealthBarContainer(): Graphics {
        return this.healthBar;
    }

    /**
     * 获取当前格子位置
     */
    public getCurrentTilePosition(): Position {
        return {
            x: Math.floor(this.position.x / this.tileSize),
            y: Math.floor(this.position.y / this.tileSize),
        };
    }

    /**
     * 检查目标格子是否在攻击范围内
     * @param targetTileX 目标格子X
     * @param targetTileY 目标格子Y
     */
    public isInRange(targetTileX: number, targetTileY: number): boolean {
        const currentTile = this.getCurrentTilePosition();
        const patternRows = this.rangePattern.length;
        const patternCols = this.rangePattern[0].length;
        const centerRow = Math.floor(patternRows / 2);
        const centerCol = Math.floor(patternCols / 2);

        // 计算目标相对于自身的偏移
        const offsetX = targetTileX - currentTile.x;
        const offsetY = targetTileY - currentTile.y;

        // 转换为模板数组索引
        const patternRow = centerRow + offsetY;
        const patternCol = centerCol + offsetX;

        // 检查是否在模板范围内且可攻击
        if (patternRow >= 0 && patternRow < patternRows &&
            patternCol >= 0 && patternCol < patternCols) {
            return this.rangePattern[patternRow][patternCol] === 1;
        }

        return false;
    }

    /**
     * 标记为死亡
     */
    public kill(): void {
        this.alive = false;
    }

    /**
     * 销毁敌人
     */
    public destroy(): void {
        this.container.destroy({ children: true });
    }
}
