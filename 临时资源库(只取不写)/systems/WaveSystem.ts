/**
 * ============================================================
 * 波次系统
 * ============================================================
 * 管理敌人波次的生成和调度
 */

import { EnemyType, Position } from '../types';

/**
 * 单个敌人生成配置
 */
export interface EnemySpawnConfig {
    /** 敌人类型 */
    type: EnemyType;
    /** 生成延迟（毫秒，相对于波次开始） */
    delay: number;
    /** 生成位置（红门索引，-1表示随机） */
    gateIndex: number;
}

/**
 * 波次配置
 */
export interface WaveConfig {
    /** 波次编号 */
    waveNumber: number;
    /** 敌人生成配置列表 */
    enemies: EnemySpawnConfig[];
    /** 波次开始前的准备时间（毫秒） */
    prepareTime: number;
}

/**
 * 波次系统类
 */
export class WaveSystem {
    /** 所有波次配置 */
    private waves: WaveConfig[];

    /** 当前波次索引 */
    private currentWaveIndex: number = -1;

    /** 当前波次已生成的敌人数 */
    private spawnedCount: number = 0;

    /** 波次开始时间 */
    private waveStartTime: number = 0;

    /** 波次是否进行中 */
    private waveInProgress: boolean = false;

    /** 当前波次所有敌人是否已生成完毕 */
    private allEnemiesSpawned: boolean = false;

    /** 敌人生成回调 */
    private onSpawnEnemy: ((type: EnemyType, gateIndex: number) => void) | null = null;

    /** 波次开始回调 */
    private onWaveStart: ((waveNumber: number) => void) | null = null;

    /** 波次结束回调 */
    private onWaveEnd: ((waveNumber: number) => void) | null = null;

    /** 所有波次完成回调 */
    private onAllWavesComplete: (() => void) | null = null;

    /**
     * 构造函数
     */
    constructor() {
        // 初始化默认波次配置
        this.waves = this.createDefaultWaves();
    }
    //临时函数。测试用
    private test1(n: number) {
        let su = [];
        for (let i = 0; i < n; i++) {
            su.push(
                { type: EnemyType.CAPOO_AK47, delay: i * 400, gateIndex: 0 }
            );
        }
        return su;
    }
    /**
     * 创建默认波次配置
     * 当前配置为单人模式 5 波挑战
     */
    private createDefaultWaves(): WaveConfig[] {
        return [
            // ============================================================
            // 第 1 波：入门（5 僵尸 + 2 Capoo）
            // 总数：7 | 目标：熟悉基础操作
            // ============================================================
            {
                waveNumber: 1,
                prepareTime: 3000,
                enemies: this.test1(50),
                // enemies: [
                //     { type: EnemyType.CAPOO_AK47, delay: 0, gateIndex: 0 },
                //     { type: EnemyType.CAPOO_AK47, delay: 2000, gateIndex: 0 },
                //     { type: EnemyType.CAPOO_AK47, delay: 2000, gateIndex: 0 },
                //     
                // ],
            },
            // ============================================================
            // 第 2 波：压制（8 僵尸 + 3 Capoo）
            // 总数：11 | 目标：考验火力密度
            // ============================================================
            {
                waveNumber: 2,
                prepareTime: 5000,
                enemies: [
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 0, gateIndex: 0 },
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 1500, gateIndex: 0 },
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 3000, gateIndex: 0 },
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 1000, gateIndex: 0 },
                    { type: EnemyType.ZOMBIE, delay: 2000, gateIndex: 0 },
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 4000, gateIndex: 0 },
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 6000, gateIndex: 0 },
                    { type: EnemyType.CAPOO_BUBBLETEA, delay: 8000, gateIndex: 0 },
                    { type: EnemyType.CAPOO_SWORDSMAN, delay: 4500, gateIndex: 0 },
                    { type: EnemyType.ZOMBIE, delay: 6000, gateIndex: 0 },
                    { type: EnemyType.ZOMBIE, delay: 7500, gateIndex: 0 },
                    { type: EnemyType.CAPOO_SWORDSMAN, delay: 9000, gateIndex: 0 },
                    { type: EnemyType.ZOMBIE, delay: 10500, gateIndex: 0 },
                    { type: EnemyType.ZOMBIE, delay: 12000, gateIndex: 0 },
                    { type: EnemyType.ZOMBIE, delay: 13500, gateIndex: 0 },
                    { type: EnemyType.CAPOO_SWORDSMAN, delay: 15000, gateIndex: 0 },
                ],
            },
            // ============================================================
            // 第 3 波：急袭（10 僵尸 + 6 Capoo）
            // 总数：16 | 目标：应对快速单位冲阵
            // ============================================================
            {
                waveNumber: 3,
                prepareTime: 5000,
                enemies: [
                    // 先来一拨僵尸铺路
                    ...Array(5).fill(0).map((_, i) => ({ type: EnemyType.ZOMBIE, delay: i * 1000, gateIndex: 0 })),
                    // 突然加速：Capoo 小队冲锋
                    ...Array(6).fill(0).map((_, i) => ({ type: EnemyType.CAPOO_SWORDSMAN, delay: 5000 + i * 800, gateIndex: 0 })),
                    // 后续僵尸补足
                    ...Array(5).fill(0).map((_, i) => ({ type: EnemyType.ZOMBIE, delay: 10000 + i * 1000, gateIndex: 0 })),
                ],
            },
            // ============================================================
            // 第 4 波：混合爆发（15 僵尸 + 8 Capoo）
            // 总数：23 | 目标：综合防御考验
            // ============================================================
            {
                waveNumber: 4,
                prepareTime: 5000,
                enemies: [
                    // 僵尸与 Capoo 混合生成，制造持续压力
                    ...Array(15).fill(0).map((_, i) => ({ type: EnemyType.ZOMBIE, delay: i * 800, gateIndex: 0 })),
                    ...Array(8).fill(0).map((_, i) => ({ type: EnemyType.CAPOO_SWORDSMAN, delay: i * 1500, gateIndex: 0 })),
                ].sort((a, b) => a.delay - b.delay), // 按延迟排序确保逻辑正确
            },
            // ============================================================
            // 第 5 波：最终波次（20 僵尸 + 12 Capoo）
            // 总数：32 | 目标：终极防线测试
            // ============================================================
            {
                waveNumber: 5,
                prepareTime: 8000,
                enemies: [
                    // 高频率生成敌军
                    ...Array(20).fill(0).map((_, i) => ({ type: EnemyType.ZOMBIE, delay: i * 600, gateIndex: 0 })),
                    ...Array(12).fill(0).map((_, i) => ({ type: EnemyType.CAPOO_SWORDSMAN, delay: 2000 + i * 1000, gateIndex: 0 })),
                ].sort((a, b) => a.delay - b.delay),
            },
        ];
    }

    /**
     * 设置敌人生成回调
     */
    public setOnSpawnEnemy(callback: (type: EnemyType, gateIndex: number) => void): void {
        this.onSpawnEnemy = callback;
    }

    /**
     * 设置波次开始回调
     */
    public setOnWaveStart(callback: (waveNumber: number) => void): void {
        this.onWaveStart = callback;
    }

    /**
     * 设置波次结束回调
     */
    public setOnWaveEnd(callback: (waveNumber: number) => void): void {
        this.onWaveEnd = callback;
    }

    /**
     * 设置所有波次完成回调
     */
    public setOnAllWavesComplete(callback: () => void): void {
        this.onAllWavesComplete = callback;
    }

    /**
     * 开始下一波
     */
    public startNextWave(): boolean {
        if (this.waveInProgress) {
            console.warn('[波次系统] 当前波次尚未结束');
            return false;
        }

        this.currentWaveIndex++;

        if (this.currentWaveIndex >= this.waves.length) {
            console.log('[波次系统] 所有波次已完成！');
            this.onAllWavesComplete?.();
            return false;
        }

        const wave = this.waves[this.currentWaveIndex];
        console.log(`[波次系统] 开始第 ${wave.waveNumber} 波，敌人数量: ${wave.enemies.length}`);

        this.waveInProgress = true;
        this.spawnedCount = 0;
        this.waveStartTime = Date.now();
        this.allEnemiesSpawned = false; // 重置敌人生成完毕标志

        this.onWaveStart?.(wave.waveNumber);

        return true;
    }

    /**
     * 更新波次系统
     * 在游戏循环中调用
     */
    public update(): void {
        if (!this.waveInProgress) return;

        const wave = this.waves[this.currentWaveIndex];
        if (!wave) return;

        const elapsed = Date.now() - this.waveStartTime;

        // 检查是否有敌人需要生成
        for (let i = this.spawnedCount; i < wave.enemies.length; i++) {
            const enemyConfig = wave.enemies[i];

            if (elapsed >= wave.prepareTime + enemyConfig.delay) {
                // 生成敌人
                this.onSpawnEnemy?.(enemyConfig.type, enemyConfig.gateIndex);
                this.spawnedCount++;
                console.log(`[波次系统] 生成敌人 ${enemyConfig.type}，已生成: ${this.spawnedCount}/${wave.enemies.length}`);
            } else {
                // 后面的敌人还没到时间，跳出循环
                break;
            }
        }

        // 检查波次是否完成（所有敌人都已生成）
        if (this.spawnedCount >= wave.enemies.length && !this.allEnemiesSpawned) {
            // 标记敌人生成完毕
            this.allEnemiesSpawned = true;
            console.log(`[波次系统] 第 ${wave.waveNumber} 波敌人生成完毕，等待击溃所有敌人...`);
        }
    }

    /**
     * 检查当前波次所有敌人是否已生成完毕
     * @returns 是否所有敌人已生成
     */
    public isAllEnemiesSpawned(): boolean {
        return this.allEnemiesSpawned;
    }

    /**
     * 标记波次结束
     * 当所有敌人被消灭时调用
     */
    public markWaveComplete(): void {
        if (!this.waveInProgress) return;

        const wave = this.waves[this.currentWaveIndex];
        console.log(`[波次系统] 第 ${wave.waveNumber} 波结束`);

        this.waveInProgress = false;
        this.onWaveEnd?.(wave.waveNumber);
    }

    /**
     * 获取当前波次编号
     */
    public getCurrentWaveNumber(): number {
        if (this.currentWaveIndex < 0) return 0;
        return this.waves[this.currentWaveIndex]?.waveNumber || 0;
    }

    /**
     * 获取总波次数
     */
    public getTotalWaves(): number {
        return this.waves.length;
    }

    /**
     * 获取当前波次敌人数量
     */
    public getCurrentWaveEnemyCount(): number {
        if (this.currentWaveIndex < 0) return 0;
        return this.waves[this.currentWaveIndex]?.enemies.length || 0;
    }

    /**
     * 检查波次是否进行中
     */
    public isWaveInProgress(): boolean {
        return this.waveInProgress;
    }

    /**
     * 检查是否所有波次都已完成
     */
    public isAllWavesComplete(): boolean {
        return this.currentWaveIndex >= this.waves.length - 1 && !this.waveInProgress;
    }

    /**
     * 重置波次系统
     */
    public reset(): void {
        this.currentWaveIndex = -1;
        this.spawnedCount = 0;
        this.waveStartTime = 0;
        this.waveInProgress = false;
        this.allEnemiesSpawned = false;
    }
}
