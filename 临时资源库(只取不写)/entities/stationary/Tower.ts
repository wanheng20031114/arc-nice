/**
 * ============================================================
 * 炮台基类
 * ============================================================
 * 定义炮台的基本属性和行为
 * 炮台只能放置在高台格子上
 */

import { Container, Graphics } from 'pixi.js';
import { Position, TowerStats, TowerType } from '../../types';
import { AuraGlowEffect } from '../effects/AuraGlowEffect';

/**
 * 炮台基类
 */
export abstract class Tower {
    /** 炮台唯一ID */
    public readonly id: string;

    /** 炮台类型 */
    public readonly type: TowerType;

    /** 炮台属性 */
    protected stats: TowerStats;

    /** 格子位置 */
    protected tilePosition: Position;

    /** 像素位置 */
    protected pixelPosition: Position;

    /** 是否存活 */
    protected alive: boolean = true;

    /** 攻击冷却计时器（秒） */
    protected attackCooldown: number = 0;

    /** PixiJS 显示容器 */
    protected container: Container;

    /** 炮台图形 */
    protected graphics: Graphics;

    /** 生命条图形 */
    protected healthBar: Graphics;

    /** 格子大小 */
    protected readonly tileSize: number = 64;

    /** 近卫塔光环防御加成值（常量） */
    protected readonly GUARD_AURA_BONUS: number = 10;

    /** 护盾效果引用（受光环影响时显示） */
    protected auraGlowEffect: AuraGlowEffect | null = null;

    /**
     * 构造函数
     * @param id 唯一ID
     * @param type 炮台类型
     * @param tilePos 格子位置
     * @param stats 炮台属性
     */
    constructor(id: string, type: TowerType, tilePos: Position, stats: TowerStats) {
        this.id = id;
        this.type = type;
        this.tilePosition = tilePos;
        this.stats = stats;

        // 计算像素位置（格子中心）
        this.pixelPosition = {
            x: tilePos.x * this.tileSize + this.tileSize / 2,
            y: tilePos.y * this.tileSize + this.tileSize / 2,
        };

        // 创建显示容器
        this.container = new Container();
        this.container.x = this.pixelPosition.x;
        this.container.y = this.pixelPosition.y;

        // 创建图形
        this.graphics = this.createGraphics();
        this.container.addChild(this.graphics);

        // 创建生命条（注意：不再直接添加到 container，由 Game 类管理图层）
        this.healthBar = this.createHealthBar();

        console.log(`[炮台] 创建 ${type} 炮台，位置: (${tilePos.x}, ${tilePos.y})`);
    }

    /**
     * 创建炮台图形（由子类实现）
     */
    protected abstract createGraphics(): Graphics;

    /**
     * 创建生命条
     */
    protected createHealthBar(): Graphics {
        const bar = new Graphics();
        this.updateHealthBar(bar);
        // 设置血条初始位置（全局坐标，因为血条会被添加到独立图层）
        bar.x = this.pixelPosition.x;
        bar.y = this.pixelPosition.y;
        return bar;
    }

    /**
     * 更新生命条显示
     */
    protected updateHealthBar(bar?: Graphics): void {
        const healthBar = bar || this.healthBar;
        healthBar.clear();

        const barWidth = 50;
        const barHeight = 4;  // 更紧凑的血条高度
        const healthPercent = this.stats.health / this.stats.maxHealth;

        // 血条 Y 偏移：在格子内顶部 (-tileSize/2 + 1)
        const barY = -this.tileSize / 2 + 1;

        // 背景（黑色）
        healthBar.rect(-barWidth / 2, barY, barWidth, barHeight);
        healthBar.fill({ color: 0x000000 });

        // 生命值（绿色渐变到红色）
        const healthColor = healthPercent > 0.5 ? 0x27ae60 : healthPercent > 0.25 ? 0xf39c12 : 0xe74c3c;
        healthBar.rect(-barWidth / 2, barY, barWidth * healthPercent, barHeight);
        healthBar.fill({ color: healthColor });

        // 边框
        healthBar.rect(-barWidth / 2, barY, barWidth, barHeight);
        healthBar.stroke({ color: 0xffffff, width: 1 });
    }

    /**
     * 更新炮台
     * @param deltaTime 时间增量（秒）
     * @param enemies 敌人列表（用于寻找目标）
     * @returns 是否发射了子弹
     */
    public update(deltaTime: number, enemies: { id: string; position: Position; isAlive: boolean }[]): {
        shouldFire: boolean;
        targetId: string | null;
    } {
        if (!this.alive) {
            return { shouldFire: false, targetId: null };
        }

        // 更新攻击冷却
        if (this.attackCooldown > 0) {
            this.attackCooldown -= deltaTime;
        }

        // 检查是否可以攻击
        if (this.attackCooldown <= 0) {
            // 寻找范围内最近的敌人
            const target = this.findTarget(enemies);

            if (target) {
                // 重置冷却时间
                this.attackCooldown = 1 / this.stats.attackSpeed;

                // 返回发射信号
                return { shouldFire: true, targetId: target.id };
            }
        }

        return { shouldFire: false, targetId: null };
    }

    /**
     * 寻找攻击目标
     * @param enemies 敌人列表
     */
    protected findTarget(
        enemies: { id: string; position: Position; isAlive: boolean }[]
    ): { id: string; position: Position } | null {
        let nearest: { id: string; position: Position } | null = null;
        let nearestDistance = Infinity;

        for (const enemy of enemies) {
            if (!enemy.isAlive) continue;

            const dx = enemy.position.x - this.pixelPosition.x;
            const dy = enemy.position.y - this.pixelPosition.y;
            const distance = Math.sqrt(dx * dx + dy * dy);

            // 检查是否在范围内
            if (this.isInRange(enemy.position.x, enemy.position.y)) {
                if (distance < nearestDistance) {
                    nearestDistance = distance;
                    nearest = enemy;
                }
            }
        }

        return nearest;
    }

    /**
     * 检查目标像素位置是否在攻击范围内
     * @param targetX 目标像素 X
     * @param targetY 目标像素 Y
     */
    public isInRange(targetX: number, targetY: number): boolean {
        // 如果有攻击模板，使用模板检测（基于格子）
        if (this.stats.rangePattern) {
            const pattern = this.stats.rangePattern;
            const patternHeight = pattern.length;
            const patternWidth = pattern[0].length;

            // 计算中心点（模板数组的中心）
            const centerX = Math.floor(patternWidth / 2);
            const centerY = Math.floor(patternHeight / 2);

            // 计算目标相对于炮台的格子偏移
            const targetTileX = Math.floor(targetX / this.tileSize);
            const targetTileY = Math.floor(targetY / this.tileSize);
            const offsetX = targetTileX - this.tilePosition.x;
            const offsetY = targetTileY - this.tilePosition.y;

            // 转换偏移到模板索引
            const patternX = centerX + offsetX;
            const patternY = centerY + offsetY;

            // 检查是否在模板范围内且该位置为 1
            if (patternY >= 0 && patternY < patternHeight && patternX >= 0 && patternX < patternWidth) {
                return pattern[patternY][patternX] === 1;
            }
            return false;
        }

        // 如果没有模板，默认只能攻击当前所在的格子
        const targetTileX = Math.floor(targetX / this.tileSize);
        const targetTileY = Math.floor(targetY / this.tileSize);
        return targetTileX === this.tilePosition.x && targetTileY === this.tilePosition.y;
    }

    /**
     * 获取攻击范围内的所有格子坐标
     */
    public getRangeTiles(): Position[] {
        const tiles: Position[] = [];

        if (this.stats.rangePattern) {
            const pattern = this.stats.rangePattern;
            const patternHeight = pattern.length;
            const patternWidth = pattern[0].length;
            const centerX = Math.floor(patternWidth / 2);
            const centerY = Math.floor(patternHeight / 2);

            for (let r = 0; r < patternHeight; r++) {
                for (let c = 0; c < patternWidth; c++) {
                    if (pattern[r][c] === 1) {
                        tiles.push({
                            x: this.tilePosition.x + (c - centerX),
                            y: this.tilePosition.y + (r - centerY)
                        });
                    }
                }
            }
        } else {
            // 默认仅返回当前格子
            tiles.push({ x: this.tilePosition.x, y: this.tilePosition.y });
        }

        return tiles;
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
            console.log(`[炮台] ${this.type} 炮台被摧毁`);
        }
    }

    /**
     * 获取显示容器
     */
    public getContainer(): Container {
        return this.container;
    }

    /**
     * 获取血条容器
     * 用于在全局血条层显示，确保血条始终在最上方
     */
    public getHealthBarContainer(): Graphics {
        return this.healthBar;
    }

    /**
     * 获取像素位置
     */
    public getPosition(): Position {
        return { ...this.pixelPosition };
    }

    /**
     * 获取格子位置
     */
    public getTilePosition(): Position {
        return { ...this.tilePosition };
    }

    /**
     * 获取攻击力
     */
    public getAttack(): number {
        return this.stats.attack;
    }

    /**
     * 获取防御力（基础值）
     */
    public getDefense(): number {
        return this.stats.defense;
    }

    /**
     * 获取实际防御力（包含外部加成）
     * @param bonus 外部防御加成（如近卫塔光环）
     */
    public getDefenseWithBonus(bonus: number = 0): number {
        return this.stats.defense + bonus;
    }

    /**
     * 获取光环防御加成值（常量）
     */
    public getGuardAuraBonus(): number {
        return this.GUARD_AURA_BONUS;
    }

    /**
     * 获取法术抗性
     */
    public getMagicResist(): number {
        return this.stats.magicResist;
    }

    /**
     * 获取攻击范围（像素）
     * 基于 rangePattern 模板自动计算最大包围半径
     */
    public getRange(): number {
        const stats = this.stats;

        // 如果有模板，动态计算最远格子的中心点到炮台中心的像素距离作为半径
        if (stats.rangePattern) {
            const pattern = stats.rangePattern;
            const rows = pattern.length;
            const cols = pattern[0].length;
            const centerX = Math.floor(cols / 2);
            const centerY = Math.floor(rows / 2);

            let maxDistSq = 0;

            for (let y = 0; y < rows; y++) {
                for (let x = 0; x < cols; x++) {
                    if (pattern[y][x] === 1) {
                        const dx = x - centerX;
                        const dy = y - centerY;
                        const distSq = dx * dx + dy * dy;
                        if (distSq > maxDistSq) {
                            maxDistSq = distSq;
                        }
                    }
                }
            }

            // 返回最大格数半径乘以格子大小（这里取大致值用于外部逻辑参考）
            return Math.sqrt(maxDistSq) * this.tileSize;
        }

        // 默认返回半格宽度
        return this.tileSize / 2;
    }

    /**
     * 检查是否存活
     */
    public isAlive(): boolean {
        return this.alive;
    }

    /**
     * 获取属性数据
     */
    public getStats(): TowerStats {
        return { ...this.stats };
    }

    /**
     * 获取显示名称（由子类覆盖）
     */
    public abstract getName(): string;

    /**
     * 销毁炮台
     */
    public destroy(): void {
        // 自动清理护盾效果
        this.clearAuraEffect();
        this.container.destroy({ children: true });
    }

    // ============================================================
    // 光环护盾效果管理
    // ============================================================

    /**
     * 设置护盾效果（受光环影响时调用）
     * @param effect 护盾效果实例
     */
    public setAuraEffect(effect: AuraGlowEffect): void {
        // 如果已经有效果，先清理
        if (this.auraGlowEffect) {
            this.auraGlowEffect.destroy();
        }
        this.auraGlowEffect = effect;
    }

    /**
     * 清除护盾效果（光环消失时调用）
     */
    public clearAuraEffect(): void {
        if (this.auraGlowEffect) {
            this.auraGlowEffect.destroy();
            this.auraGlowEffect = null;
        }
    }

    /**
     * 更新显示效果（如光环护盾动画）
     * @param deltaTime 时间增量（秒）
     */
    public updateEffect(deltaTime: number): void {
        if (this.auraGlowEffect) {
            this.auraGlowEffect.update(deltaTime);
        }
    }

    /**
     * 检查是否有护盾效果
     */
    public hasAuraEffect(): boolean {
        return this.auraGlowEffect !== null;
    }
}
