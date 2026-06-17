/**
 * ============================================================
 * 游戏主类
 * ============================================================
 * 管理整个游戏的运行，包括：
 * - 游戏循环
 * - 实体管理（炮台、敌人、子弹）
 * - 地图渲染
 * - 战斗逻辑
 * - 波次系统
 */

import { Application, Container, Graphics, Text, TextStyle } from 'pixi.js';
import { GameMap } from './GameMap';
import { AssetManager } from './AssetManager';
import { Position, GameState, EnemyType, TowerType } from '../types';
import { PathFinding } from '../systems/PathFinding';
import { CombatSystem, DamageType } from '../systems/CombatSystem';
import { WaveSystem } from '../systems/WaveSystem';
import { Tower } from '../entities/stationary/Tower';
import { PrototypeTower } from '../entities/stationary/prototype_tower/PrototypeTower';
import { FlameThrower, FlameSpawnData } from '../entities/stationary/flame_thrower/FlameThrower';
import { LaserTower, LaserFireData } from '../entities/stationary/laser_tower/LaserTower';
import { LaserBeam } from '../entities/stationary/laser_tower/LaserBeam';
import { FlameParticle } from '../entities/stationary/flame_thrower/FlameParticle';
import { Enemy } from '../entities/movable/Enemy';
import { Zombie } from '../entities/movable/zombie/Zombie';
import { CapooSwordsman } from '../entities/movable/capoo_swordsman/CapooSwordsman';
import { CapooBubbleTea, BubblePearlData } from '../entities/movable/capoo_bubble_tea/CapooBubbleTea';
import { CapooAK47, AK47BulletData } from '../entities/movable/capoo_ak47/CapooAK47';
import { BubblePearl } from '../entities/movable/capoo_bubble_tea/BubblePearl';
import { AK47Bullet } from '../entities/movable/capoo_ak47/AK47Bullet';
import { Projectile } from '../entities/stationary/Projectile';
import { DamagePopup } from '../ui/DamagePopup';
import { DeploymentBar } from '../ui/DeploymentBar';
import { RangeOverlay } from '../ui/RangeOverlay';
import { TowerInfoPanel } from '../ui/TowerInfoPanel';
import { DeathEffect } from '../effects/DeathEffect';
import { AntiaircraftTower, AntiaircraftFireData } from '../entities/stationary/antiaircraft_tower/AntiaircraftTower';
import { ExplosionEffect } from '../entities/effects/ExplosionEffect';
import { GatlingTower } from '../entities/stationary/gatling_tower/GatlingTower';
import { GatlingBullet } from '../entities/stationary/gatling_tower/GatlingBullet';
import { GuardTower } from '../entities/stationary/guard_tower/GuardTower';
import { AuraGlowEffect } from '../entities/effects/AuraGlowEffect';

/**
 * 游戏主类
 */
export class Game {
    /** PixiJS 应用实例 */
    private app: Application;

    /** 游戏地图 */
    private gameMap: GameMap;

    /** 寻路系统 */
    private pathFinding: PathFinding;

    /** 战斗系统 */
    private combatSystem: CombatSystem;

    /** 波次系统 */
    private waveSystem: WaveSystem;

    /** 地图层容器 */
    private mapLayer: Container;

    /** 实体层容器（炮台、敌人） */
    private entityLayer: Container;

    /** 子弹层容器 */
    private projectileLayer: Container;

    /** 血条层（确保所有血条在最上方） */
    private healthBarLayer: Container;

    /** 飘字伤害层 */
    private popupLayer: Container;

    /** UI层容器 */
    private uiLayer: Container;

    /** 炮台列表 */
    private towers: Tower[] = [];

    /** 敌人列表 */
    private enemies: Enemy[] = [];

    /** 子弹列表 */
    private projectiles: Projectile[] = [];

    /** 火焰粒子列表（喷火器攻击） */
    private flameParticles: FlameParticle[] = [];

    /** 伤害飘字列表 */
    private popups: DamagePopup[] = [];

    /** 死亡特效列表 */
    private deathEffects: DeathEffect[] = [];

    /** 激光射线列表 */
    private laserBeams: LaserBeam[] = [];

    /** 珍珠投射物列表（珍珠奶茶Capoo攻击） */
    private bubblePearls: BubblePearl[] = [];

    /** AK47 子弹列表（AK47 Capoo攻击） */
    private ak47Bullets: import('../entities/movable/capoo_ak47/AK47Bullet').AK47Bullet[] = [];

    /** 爆炸效果列表（防空塔攻击） */
    private explosionEffects: ExplosionEffect[] = [];

    /** 加特林子弹列表（加特林塔攻击） */
    private gatlingBullets: GatlingBullet[] = [];

    /** 游戏状态 */
    private gameState: GameState = GameState.IDLE;

    /** 核心生命值 */
    private coreHealth: number = 10;

    /** 核心最大生命值 */
    private maxCoreHealth: number = 10;

    /** 金币 */
    private gold: number = 10000;

    /** 实体ID计数器 */
    private entityIdCounter: number = 0;

    /** 游戏是否初始化完成 */
    private initialized: boolean = false;

    /** 上一帧时间 */
    private lastTime: number = 0;

    /** 核心生命值文本 */
    private coreHealthText: Text | null = null;

    /** 金币文本 */
    private goldText: Text | null = null;

    /** 波次文本 */
    private waveText: Text | null = null;

    /** 部署栏 */
    private deploymentBar: DeploymentBar | null = null;

    /** 攻击范围覆盖层 */
    private rangeOverlay: RangeOverlay | null = null;

    /** 炮台信息面板 */
    private towerInfoPanel: TowerInfoPanel | null = null;

    /** 当前拖拽中的炮台类型 */
    private draggingTowerType: TowerType | null = null;

    /** 当前拖拽中的炮台费用 */
    private draggingTowerCost: number = 0;

    /** 游戏结束回调 */
    private onGameEnd: ((victory: boolean) => void) | null = null;

    /**
     * 构造函数
     * @param app PixiJS 应用实例
     */
    constructor(app: Application) {
        this.app = app;

        // 创建图层容器
        this.mapLayer = new Container();
        this.entityLayer = new Container();
        this.projectileLayer = new Container();
        this.healthBarLayer = new Container();
        this.popupLayer = new Container();
        this.uiLayer = new Container();

        // 添加到舞台
        this.app.stage.addChild(this.mapLayer);
        this.app.stage.addChild(this.entityLayer);
        this.app.stage.addChild(this.projectileLayer);
        this.app.stage.addChild(this.healthBarLayer); // 高于实体和子弹
        this.app.stage.addChild(this.popupLayer);     // 高于血条
        this.app.stage.addChild(this.uiLayer);        // 最顶层UI

        // 创建攻击范围层（位于地图上，实体下）
        this.rangeOverlay = new RangeOverlay();
        this.app.stage.addChildAt(this.rangeOverlay.getContainer(), this.app.stage.getChildIndex(this.entityLayer));

        // 初始化地图
        this.gameMap = new GameMap(this.mapLayer);

        // 初始化系统
        this.pathFinding = new PathFinding(this.gameMap);
        this.combatSystem = new CombatSystem();
        this.waveSystem = new WaveSystem();

        // 设置波次回调
        this.setupWaveCallbacks();

        console.log('[游戏] 游戏核心初始化完成');
    }

    /**
     * 初始化游戏
     */
    public async init(): Promise<void> {
        if (this.initialized) {
            console.log('[游戏] 已初始化，跳过');
            return;
        }

        console.log('[游戏] 开始初始化...');

        // 加载资源
        const assetManager = AssetManager.getInstance();
        await assetManager.loadAssets();

        // 资源加载完成后渲染地图（使用贴图）
        this.gameMap.render();

        // 创建UI
        this.createUI();

        // 初始化信息面板
        this.towerInfoPanel = new TowerInfoPanel();
        this.towerInfoPanel.setOnRemoveTower((tower) => {
            this.removeTower(tower);
        });
        this.uiLayer.addChild(this.towerInfoPanel.getContainer());

        // 设置交互事件
        this.setupInteraction();

        // 居中地图
        this.centerMap();

        this.initialized = true;
        console.log('[游戏] 初始化完成');
    }

    /**
     * 居中地图
     */
    private centerMap(): void {
        const mapWidth = this.gameMap.getPixelWidth();
        const mapHeight = this.gameMap.getPixelHeight();
        const screenWidth = this.app.screen.width;
        const screenHeight = this.app.screen.height;

        // 如果地图比屏幕大，优先靠左靠上居中
        const offsetX = Math.max(0, (screenWidth - mapWidth) / 2);
        const offsetY = Math.max(0, (screenHeight - mapHeight) / 2 + 30);

        this.mapLayer.x = offsetX;
        this.mapLayer.y = offsetY;
        this.entityLayer.x = offsetX;
        this.entityLayer.y = offsetY;
        this.projectileLayer.x = offsetX;
        this.projectileLayer.y = offsetY;
        this.healthBarLayer.x = offsetX;
        this.healthBarLayer.y = offsetY;
        this.popupLayer.x = offsetX;
        this.popupLayer.y = offsetY;

        if (this.rangeOverlay) {
            this.rangeOverlay.getContainer().x = offsetX;
            this.rangeOverlay.getContainer().y = offsetY;
        }
    }

    /**
     * 创建UI
     */
    private createUI(): void {
        const textStyle = new TextStyle({
            fontFamily: 'Microsoft YaHei, Arial',
            fontSize: 20,
            fill: '#ffffff',
            fontWeight: 'bold',
        });

        // 核心生命值
        this.coreHealthText = new Text({
            text: `核心生命: ${this.coreHealth}/${this.maxCoreHealth}`,
            style: textStyle,
        });
        this.coreHealthText.x = 20;
        this.coreHealthText.y = 10;
        this.uiLayer.addChild(this.coreHealthText);

        // 金币
        this.goldText = new Text({
            text: `金币: ${this.gold}`,
            style: textStyle,
        });
        this.goldText.x = 250;
        this.goldText.y = 10;
        this.uiLayer.addChild(this.goldText);

        // 波次
        this.waveText = new Text({
            text: `波次: 0/${this.waveSystem.getTotalWaves()}`,
            style: textStyle,
        });
        this.waveText.x = 400;
        this.waveText.y = 10;
        this.uiLayer.addChild(this.waveText);

        // 开始按钮
        const startButton = this.createButton('开始游戏', 550, 5, () => {
            this.startGame();
        });
        this.uiLayer.addChild(startButton);

        // 炮台放置提示
        const tipsStyle = new TextStyle({
            fontFamily: 'Microsoft YaHei, Arial',
            fontSize: 14,
            fill: '#888888',
        });
        const tips = new Text({
            text: '从底部拖拽单位到蓝色高台部署',
            style: tipsStyle,
        });
        tips.x = 20;
        tips.y = 40;
        this.uiLayer.addChild(tips);

        // 创建部署栏
        this.createDeploymentBar();
    }

    /**
     * 创建部署栏
     */
    private createDeploymentBar(): void {
        this.deploymentBar = new DeploymentBar();
        this.deploymentBar.centerAtBottom(this.app.screen.width, this.app.screen.height);
        this.deploymentBar.updateGold(this.gold);

        // 设置部署栏回调
        this.deploymentBar.setCallbacks({
            onDragStart: (unitType: TowerType, cost: number) => {
                this.draggingTowerType = unitType;
                this.draggingTowerCost = cost;
            },
            onDragMove: (_x: number, _y: number) => {
                // 可以在这里添加高亮可部署格子的逻辑
            },
            onDragEnd: (x: number, y: number) => {
                return this.handleDragDeploy(x, y);
            },
            onDragCancel: () => {
                this.draggingTowerType = null;
                this.draggingTowerCost = 0;
            },
        });

        // 添加到UI层
        this.uiLayer.addChild(this.deploymentBar.getContainer());
    }

    /**
     * 创建按钮
     */
    private createButton(text: string, x: number, y: number, onClick: () => void): Container {
        const button = new Container();
        button.x = x;
        button.y = y;

        // 按钮背景
        const bg = new Graphics();
        bg.roundRect(0, 0, 100, 30, 5);
        bg.fill({ color: 0xe94560 });
        button.addChild(bg);

        // 按钮文字
        const label = new Text({
            text,
            style: new TextStyle({
                fontFamily: 'Microsoft YaHei, Arial',
                fontSize: 14,
                fill: '#ffffff',
                fontWeight: 'bold',
            }),
        });
        label.x = 50 - label.width / 2;
        label.y = 15 - label.height / 2;
        button.addChild(label);

        // 交互
        button.eventMode = 'static';
        button.cursor = 'pointer';
        button.on('pointerdown', () => {
            // 播放点击音效
            AssetManager.getInstance().playClickSound();
            onClick();
        });

        return button;
    }

    /**
     * 设置交互事件
     * 监听画布的鼠标事件用于拖拽部署
     */
    private setupInteraction(): void {
        // 设置舞台交互
        this.app.stage.eventMode = 'static';
        this.app.stage.hitArea = this.app.screen;

        // 鼠标移动事件（用于拖拽预览）
        this.app.stage.on('pointermove', (event) => {
            if (this.deploymentBar?.getIsDragging()) {
                this.deploymentBar.updateDragPosition(event.global.x, event.global.y);
            }
        });

        // 鼠标释放事件（用于结束拖拽）
        this.app.stage.on('pointerup', (event) => {
            if (this.deploymentBar?.getIsDragging()) {
                this.deploymentBar.endDrag(event.global.x, event.global.y);
            }
        });

        // 鼠标离开画布事件（取消拖拽）
        this.app.stage.on('pointerleave', () => {
            if (this.deploymentBar?.getIsDragging()) {
                this.deploymentBar.cancelDrag();
            }
        });

        // 全局点击事件（用于取消选中）
        this.app.stage.on('pointertap', () => {
            // 如果点击的是背景（非图标或炮台），取消选中
            this.selectTower(null);
        });
    }

    /**
     * 处理拖拽部署
     * @param x 鼠标X坐标（屏幕坐标）
     * @param y 鼠标Y坐标（屏幕坐标）
     * @returns 是否成功部署
     */
    private handleDragDeploy(x: number, y: number): boolean {
        if (this.gameState !== GameState.PLAYING && this.gameState !== GameState.IDLE) {
            return false;
        }

        if (!this.draggingTowerType) {
            return false;
        }

        // 转换屏幕坐标到地图坐标
        const mapX = x - this.mapLayer.x;
        const mapY = y - this.mapLayer.y;

        // 转换为格子坐标
        const tileX = Math.floor(mapX / 64);
        const tileY = Math.floor(mapY / 64);

        // 检查是否可以放置（近卫塔可以放在地面）
        const canPlace = this.draggingTowerType === TowerType.GUARD
            ? this.gameMap.canPlaceGuardTower(tileX, tileY)
            : this.gameMap.canPlaceTower(tileX, tileY);

        if (!canPlace) {
            console.log('[游戏] 无法在此位置部署');
            this.draggingTowerType = null;
            this.draggingTowerCost = 0;
            return false;
        }

        // 检查金币
        if (this.gold < this.draggingTowerCost) {
            console.log('[游戏] 金币不足');
            this.draggingTowerType = null;
            this.draggingTowerCost = 0;
            return false;
        }

        // 扣除金币
        this.gold -= this.draggingTowerCost;
        this.updateUI();

        // 放置炮台
        this.placeTower(tileX, tileY, this.draggingTowerType);

        // 重置拖拽状态
        this.draggingTowerType = null;
        this.draggingTowerCost = 0;

        return true;
    }

    /**
     * 放置炮台
     * @param x 格子X坐标
     * @param y 格子Y坐标
     * @param towerType 炮台类型
     */
    private placeTower(x: number, y: number, towerType: TowerType = TowerType.PROTOTYPE): void {
        const id = `tower_${this.entityIdCounter++}`;
        let tower: Tower;

        // 根据类型创建不同的炮台
        switch (towerType) {
            case TowerType.FLAMETHROWER:
                tower = new FlameThrower(id, { x, y });
                break;
            case TowerType.LASER:
                tower = new LaserTower(id, { x, y });
                break;
            case TowerType.ANTIAIRCRAFT:
                tower = new AntiaircraftTower(id, { x, y });
                break;
            case TowerType.GATLING:
                tower = new GatlingTower(id, { x, y });
                break;
            case TowerType.GUARD:
                tower = new GuardTower(id, { x, y });
                break;
            case TowerType.PROTOTYPE:
            default:
                tower = new PrototypeTower(id, { x, y });
                break;
        }

        this.towers.push(tower);

        // 设置炮台交互
        const container = tower.getContainer();
        container.eventMode = 'static';
        container.cursor = 'pointer';
        container.on('pointertap', (event) => {
            event.stopPropagation(); // 阻止事件冒泡到舞台
            this.selectTower(tower);
        });

        this.entityLayer.addChild(container);
        // 近卫塔可放置在地面，不阻挡敌人
        const isGroundTower = towerType === TowerType.GUARD;
        this.gameMap.setTowerOnTile(x, y, true, isGroundTower);

        // 将炮台血条添加到独立的血条层
        this.healthBarLayer.addChild(tower.getHealthBarContainer());

        // ============= 光环效果处理 =============

        // 1. 检查当前地块是否已有光环效果（由其他近卫塔产生）
        if (this.gameMap.tileHasGuardAura(x, y) && !tower.hasAuraEffect()) {
            console.log(`[游戏] 炮塔放置于已有的光环区 (${x}, ${y})，添加护盾效果`);
            const pixelPos = this.gameMap.tileToPixel(x, y);
            const effect = new AuraGlowEffect(pixelPos);
            tower.setAuraEffect(effect);
            this.entityLayer.addChild(effect.getContainer());
        }

        // 2. 如果是近卫塔，处理其对周围的影响并添加技力条
        if (tower.type === TowerType.GUARD && tower instanceof GuardTower) {
            console.log(`[游戏] 检测到近卫塔放置，开始扩散光环...`);
            this.healthBarLayer.addChild(tower.getSpBarContainer());
            this.onGuardTowerPlaced(tower);
        }

        // 播放放置成功音效
        AssetManager.getInstance().playPlantingSound();

        console.log(`[游戏] 放置${towerType === TowerType.FLAMETHROWER ? '喷火器' : '炮台'}于 (${x}, ${y})`);
    }

    /**
     * 选中炮台并显示范围及信息
     * @param tower 被选中的炮台，null 表示取消选中
     */
    private selectTower(tower: Tower | null): void {
        if (tower) {
            // 显示攻击范围覆盖
            this.rangeOverlay?.show(tower.getRangeTiles());
            // 计算炮台在屏幕上的实际位置（地图坐标 + 地图偏移）
            const towerPos = tower.getPosition();
            const screenPos = {
                x: towerPos.x + this.mapLayer.x,
                y: towerPos.y + this.mapLayer.y,
            };

            // 获取光环防御加成
            const tilePos = tower.getTilePosition();
            const defenseBonus = this.gameMap.tileHasGuardAura(tilePos.x, tilePos.y) ? 10 : 0;

            // 显示面板信息（传递屏幕坐标以便显示在右侧）
            this.towerInfoPanel?.show(tower, screenPos, defenseBonus);
            console.log(`[游戏] 选中炮台: ${tower.getName()}, 防御加成: ${defenseBonus}`);
        } else {
            // 隐藏覆盖和面板
            this.rangeOverlay?.hide();
            this.towerInfoPanel?.hide();
        }
    }

    /**
     * 移除炮台（撤销部署）
     * 不返还任何费用
     * @param tower 要移除的炮台
     */
    private removeTower(tower: Tower): void {
        const index = this.towers.indexOf(tower);
        if (index === -1) {
            console.warn('[游戏] 尝试移除不存在的炮台');
            return;
        }

        // 从地图上标记为空
        const tilePos = tower.getTilePosition();
        this.gameMap.setTowerOnTile(tilePos.x, tilePos.y, false);

        // 从血条层移除血条
        const healthBar = tower.getHealthBarContainer();
        if (healthBar.parent) {
            healthBar.parent.removeChild(healthBar);
        }

        // 如果是近卫塔，移除光环
        if (tower.type === TowerType.GUARD && tower instanceof GuardTower) {
            this.onGuardTowerRemoved(tower);
        }

        // 销毁炮台
        tower.destroy();
        this.towers.splice(index, 1);

        // 隐藏面板和范围覆盖
        this.selectTower(null);

        console.log(`[游戏] 撤销部署：${tower.getName()}，位置 (${tilePos.x}, ${tilePos.y})`);
    }

    /**
     * 设置波次回调
     */
    private setupWaveCallbacks(): void {
        // 敌人生成回调
        this.waveSystem.setOnSpawnEnemy((type: EnemyType, _gateIndex: number) => {
            this.spawnEnemy(type);
        });

        // 波次开始回调
        this.waveSystem.setOnWaveStart((waveNumber: number) => {
            console.log(`[游戏] 第 ${waveNumber} 波开始！`);
            this.updateUI();
        });

        // 波次结束回调
        this.waveSystem.setOnWaveEnd((waveNumber: number) => {
            console.log(`[游戏] 第 ${waveNumber} 波结束！`);

            // 检查是否还有下一波
            if (!this.waveSystem.isAllWavesComplete()) {
                // 等待3秒后自动开始下一波
                setTimeout(() => {
                    this.waveSystem.startNextWave();
                }, 3000); // 敌人击溺后等待3秒
            }
        });

        // 所有波次完成回调
        this.waveSystem.setOnAllWavesComplete(() => {
            console.log('[游戏] 所有波次完成，胜利！');
            this.endGame(true);
        });
    }

    /**
     * 生成敌人
     */
    private spawnEnemy(type: EnemyType): void {
        const redGates = this.gameMap.getRedGates();
        if (redGates.length === 0) {
            console.error('[游戏] 没有红门，无法生成敌人');
            return;
        }

        // 从第一个红门生成
        const gate = redGates[0];
        const startPos = this.gameMap.tileToPixel(gate.x, gate.y);

        // 创建敌人
        const id = `enemy_${this.entityIdCounter++}`;
        let enemy: Enemy;

        switch (type) {
            case EnemyType.ZOMBIE:
                enemy = new Zombie(id, startPos);
                break;
            case EnemyType.CAPOO_SWORDSMAN:
                enemy = new CapooSwordsman(id, startPos);
                break;
            case EnemyType.CAPOO_BUBBLETEA:
                enemy = new CapooBubbleTea(id, startPos);
                break;
            case EnemyType.CAPOO_AK47:
                enemy = new CapooAK47(id, startPos);
                break;
            default:
                enemy = new Zombie(id, startPos);
        }

        // 计算路径
        const path = this.pathFinding.findPathToNearestBlueGate(gate);
        if (path.length === 0) {
            console.error('[游戏] 无法找到到蓝门的路径');
            enemy.destroy();
            return;
        }

        enemy.setPath(path);
        this.enemies.push(enemy);
        this.entityLayer.addChild(enemy.getContainer());
        this.healthBarLayer.addChild(enemy.getHealthBarContainer()); // 将血条添加到血条层

        console.log(`[游戏] 生成敌人 ${type}，路径长度: ${path.length}`);
    }

    /**
     * 开始游戏
     */
    public startGame(): void {
        if (this.gameState === GameState.PLAYING) {
            console.log('[游戏] 游戏已在进行中');
            return;
        }

        console.log('[游戏] 开始游戏');
        this.gameState = GameState.PLAYING;
        this.lastTime = performance.now();

        // 开始第一波
        this.waveSystem.startNextWave();

        // 启动游戏循环
        this.app.ticker.add(this.gameLoop, this);
    }

    /**
     * 游戏循环
     */
    private gameLoop = (): void => {
        if (this.gameState !== GameState.PLAYING) {
            return;
        }

        // 计算时间增量
        const currentTime = performance.now();
        const deltaTime = (currentTime - this.lastTime) / 1000; // 转换为秒
        this.lastTime = currentTime;

        // 限制最大时间增量，防止暂停后恢复时出现异常
        const clampedDelta = Math.min(deltaTime, 0.1);

        // 更新波次系统
        this.waveSystem.update();

        // 更新炮台
        this.updateTowers(clampedDelta);

        // 更新敌人
        this.updateEnemies(clampedDelta);

        // 更新子弹
        this.updateProjectiles(clampedDelta);

        // 更新火焰粒子（喷火器攻击）
        this.updateFlameParticles(clampedDelta);

        // 更新伤害飘字
        this.updateDamagePopups(clampedDelta);

        // 更新激光射线
        this.updateLaserBeams(clampedDelta);

        // 更新珍珠投射物（珍珠奶茶Capoo攻击）
        this.updateBubblePearls(clampedDelta);

        // 更新 AK47 子弹（AK47 Capoo攻击）
        this.updateAK47Bullets(clampedDelta);

        // 更新加特林子弹（加特林塔攻击）
        this.updateGatlingBullets(clampedDelta);

        // 清理死亡实体
        this.cleanupDeadEntities();

        // 更新爆炸效果（防空塔攻击）
        this.updateExplosionEffects(clampedDelta);

        // 更新死亡特效
        this.updateDeathEffects(clampedDelta);

        // 检查波次完成
        this.checkWaveComplete();

        // 检查游戏结束
        if (this.coreHealth <= 0) {
            this.endGame(false);
        }
    };

    /**
     * 更新炮台
     */
    private updateTowers(deltaTime: number): void {
        // 收集存活敌人信息
        const enemyInfos = this.enemies
            .filter((e) => e.isAlive())
            .map((e) => ({
                id: e.id,
                position: e.getPosition(),
                isAlive: e.isAlive(),
            }));

        for (const tower of this.towers) {
            if (!tower.isAlive()) continue;

            // 对于喷火器，需要设置火焰发射回调
            if (tower.type === TowerType.FLAMETHROWER && tower instanceof FlameThrower) {
                // 如果还没有设置回调，则设置
                if (!tower['_flameCallbackSet']) {
                    tower.setOnFireFlames((particles: FlameSpawnData[]) => {
                        this.spawnFlameParticles(particles, tower.id);
                    });
                    tower['_flameCallbackSet'] = true;
                }
            }

            // 对于激光塔，需要设置激光发射回调
            if (tower.type === TowerType.LASER && tower instanceof LaserTower) {
                if (!tower._laserCallbackSet) {
                    tower.setOnFireLaser((data: LaserFireData) => {
                        this.fireLaser(data);
                    });
                    tower._laserCallbackSet = true;
                }
            }

            // 对于防空塔，需要设置开火回调
            if (tower.type === TowerType.ANTIAIRCRAFT && tower instanceof AntiaircraftTower) {
                if (!tower._antiaircraftCallbackSet) {
                    tower.setOnFire((data: AntiaircraftFireData) => {
                        this.handleExplosion(data);
                    });
                    tower._antiaircraftCallbackSet = true;
                }
            }

            const result = tower.update(deltaTime, enemyInfos);

            // 更新护盾动画等显示效果
            tower.updateEffect(deltaTime);

            if (result.shouldFire && result.targetId) {
                // 对于普通炮台，发射子弹（喷火器、激光塔和防空塔已通过回调处理）
                if (tower.type !== TowerType.FLAMETHROWER && tower.type !== TowerType.LASER && tower.type !== TowerType.ANTIAIRCRAFT) {
                    if (tower.type === TowerType.GATLING) {
                        this.fireGatlingBullet(tower, result.targetId);
                    } else {
                        this.fireProjectile(tower, result.targetId);
                    }
                }
            }
        }
    }

    /**
     * 生成火焰粒子（喷火器攻击）
     * @param particles 粒子生成数据数组
     * @param ownerId 发射者ID
     */
    private spawnFlameParticles(particles: FlameSpawnData[], ownerId: string): void {
        for (const data of particles) {
            const id = `flame_${this.entityIdCounter++}`;
            const particle = new FlameParticle(
                id,
                data.startPos,
                data.direction,
                data.damage,
                data.speed,
                ownerId
            );
            this.flameParticles.push(particle);
            this.projectileLayer.addChild(particle.getContainer());
        }

        // 播放喷火器开火音效（每次喷射只播放一次）
        if (particles.length > 0) {
            AssetManager.getInstance().playFlameThrowerFireSound();
        }
    }

    /**
     * 发射子弹
     */
    private fireProjectile(tower: Tower, targetId: string): void {
        const id = `projectile_${this.entityIdCounter++}`;
        const startPos = tower.getPosition();
        const damage = tower.getAttack();
        const speed = 300; // 像素/秒

        const projectile = new Projectile(id, startPos, damage, speed, targetId, tower.id);
        this.projectiles.push(projectile);
        this.projectileLayer.addChild(projectile.getContainer());

        // 播放原型炮台开火音效
        AssetManager.getInstance().playPrototypeTowerFireSound();
    }

    /**
     * 发射加特林子弹（加特林塔攻击）
     * @param tower 发射者炮塔
     * @param targetId 目标ID
     */
    private fireGatlingBullet(tower: Tower, targetId: string): void {
        const id = `gatling_${this.entityIdCounter++}`;
        // 从炮塔左上角（炮口位置）发射
        const towerPos = tower.getPosition();

        const startPos = {
            x: towerPos.x + 23,
            y: towerPos.y - 13,
        };
        const damage = tower.getAttack();
        const speed = 600; // 更快的速度

        const bullet = new GatlingBullet(id, startPos, damage, speed, targetId, tower.id);
        this.gatlingBullets.push(bullet);
        this.projectileLayer.addChild(bullet.getContainer());

        // 播放开火音效（使用原型炮台音效）
        AssetManager.getInstance().playGatlingTowerFireSound();
    }

    /**
     * 发射激光（激光塔攻击）
     * @param data 激光发射数据
     */
    private fireLaser(data: LaserFireData): void {
        // 查找目标敌人
        const target = this.enemies.find(e => e.id === data.targetId && e.isAlive());
        if (!target) return;

        const targetPos = target.getPosition();

        // 创建激光射线视觉效果
        const beam = new LaserBeam(data.startPos, targetPos);
        this.laserBeams.push(beam);
        this.projectileLayer.addChild(beam.getContainer());

        // 播放激光塔开火音效
        AssetManager.getInstance().playLaserTowerFireSound();

        // 直接造成伤害（激光是即时命中）
        const finalDamage = this.combatSystem.calculateDamage(
            data.damage,
            DamageType.MAGICAL, // 激光为法术伤害
            target.getDefense(),
            target.getMagicResist()
        );
        target.takeDamage(finalDamage);

        // 添加伤害飘字
        this.addDamagePopup(finalDamage, DamageType.MAGICAL, targetPos);

        // 击杀奖励
        if (!target.isAlive()) {
            this.gold += 10;
            this.updateUI();
        }

        console.log(`[激光塔] 对 ${data.targetId} 造成 ${finalDamage} 点法术伤害`);
    }

    /**
     * 处理爆炸（防空塔攻击）
     * @param data 爆炸数据
     */
    private handleExplosion(data: AntiaircraftFireData): void {
        // 创建爆炸视觉效果（半径 96 像素）
        const explosion = new ExplosionEffect(data.position, 96);
        this.explosionEffects.push(explosion);
        this.projectileLayer.addChild(explosion.getContainer());

        // 播放防空塔开火音效
        AssetManager.getInstance().playAntiaircraftTowerFireSound();

        // 计算 AOE 伤害
        let hitCount = 0;
        for (const enemy of this.enemies) {
            if (!enemy.isAlive()) continue;

            const enemyPos = enemy.getPosition();
            const dx = enemyPos.x - data.position.x;
            const dy = enemyPos.y - data.position.y;
            const distance = Math.sqrt(dx * dx + dy * dy);

            // 检查敌人在哪个伤害层
            let damagePercent = 0;
            for (const layer of data.layers) {
                if (distance <= layer.radius) {
                    damagePercent = layer.damagePercent;
                    break; // 取最内层的伤害
                }
            }

            if (damagePercent > 0) {
                const rawDamage = data.baseDamage * damagePercent;
                const finalDamage = this.combatSystem.calculateDamage(
                    rawDamage,
                    DamageType.PHYSICAL,
                    enemy.getDefense(),
                    enemy.getMagicResist()
                );
                enemy.takeDamage(finalDamage);
                hitCount++;

                // 添加伤害飘字
                this.addDamagePopup(finalDamage, DamageType.PHYSICAL, enemyPos);

                // 击杀奖励
                if (!enemy.isAlive()) {
                    this.gold += 10;
                    this.updateUI();
                }
            }
        }

        if (hitCount > 0) {
            console.log(`[防空塔] 爆炸命中 ${hitCount} 个敌人`);
        }
    }

    /**
     * 更新激光射线
     */
    private updateLaserBeams(deltaTime: number): void {
        for (let i = this.laserBeams.length - 1; i >= 0; i--) {
            const beam = this.laserBeams[i];
            beam.update(deltaTime);
            if (!beam.isAlive()) {
                beam.destroy();
                this.laserBeams.splice(i, 1);
            }
        }
    }

    /**
     * 更新加特林子弹（加特林塔攻击）
     */
    private updateGatlingBullets(deltaTime: number): void {
        for (let i = this.gatlingBullets.length - 1; i >= 0; i--) {
            const bullet = this.gatlingBullets[i];

            // 更新目标位置（追踪敌人）
            const target = this.enemies.find(e => e.id === bullet.getTargetId() && e.isAlive());
            if (target) {
                bullet.updateTargetPosition(target.getPosition());
            } else {
                // 目标已死亡或不存在，销毁子弹
                bullet.destroy();
                this.gatlingBullets.splice(i, 1);
                continue;
            }

            // 更新子弹
            const hit = bullet.update(deltaTime);

            if (hit && target) {
                // 命中，造成伤害
                const finalDamage = this.combatSystem.calculateDamage(
                    bullet.getDamage(),
                    DamageType.PHYSICAL,
                    target.getDefense(),
                    target.getMagicResist()
                );
                target.takeDamage(finalDamage);

                // 添加伤害飘字
                this.addDamagePopup(finalDamage, DamageType.PHYSICAL, target.getPosition());

                // 击杀奖励
                if (!target.isAlive()) {
                    this.gold += 10;
                    this.updateUI();
                }

                // 销毁子弹
                bullet.destroy();
                this.gatlingBullets.splice(i, 1);
            } else if (!bullet.isAlive()) {
                // 子弹失效（目标丢失等）
                bullet.destroy();
                this.gatlingBullets.splice(i, 1);
            }
        }
    }

    /**
     * 更新爆炸效果（防空塔攻击）
     */
    private updateExplosionEffects(deltaTime: number): void {
        for (let i = this.explosionEffects.length - 1; i >= 0; i--) {
            const explosion = this.explosionEffects[i];
            explosion.update(deltaTime);
            if (!explosion.isAlive()) {
                explosion.destroy();
                this.explosionEffects.splice(i, 1);
            }
        }
    }

    /**
     * 发射珍珠（珍珠奶茶 Capoo 攻击）
     * @param data 珍珠发射数据
     */
    private fireBubblePearls(data: BubblePearlData): void {
        // 查找目标炮台
        const target = this.towers.find(t => t.id === data.targetId && t.isAlive());
        if (!target) return;

        // 发射多颗珍珠（带有小幅随机偏移）
        for (let i = 0; i < data.count; i++) {
            // 起始位置添加随机偏移
            const offsetX = (Math.random() - 0.5) * 10;
            const offsetY = (Math.random() - 0.5) * 10;
            const startPos = {
                x: data.startPos.x + offsetX,
                y: data.startPos.y + offsetY,
            };

            // 目标位置也添加小幅偏移
            const targetOffsetX = (Math.random() - 0.5) * 20;
            const targetOffsetY = (Math.random() - 0.5) * 20;
            const targetPos = {
                x: data.targetPos.x + targetOffsetX,
                y: data.targetPos.y + targetOffsetY,
            };

            const pearl = new BubblePearl(
                startPos,
                targetPos,
                data.damage,
                data.targetId,
                'enemy' // 发射者类型标识
            );
            this.bubblePearls.push(pearl);
            this.projectileLayer.addChild(pearl.getContainer());
        }

        console.log(`[珍珠奶茶Capoo] 发射 ${data.count} 颗珍珠攻击 ${data.targetId}`);
    }

    /**
     * 更新珍珠投射物
     */
    private updateBubblePearls(deltaTime: number): void {
        for (let i = this.bubblePearls.length - 1; i >= 0; i--) {
            const pearl = this.bubblePearls[i];
            const hit = pearl.update(deltaTime);

            if (hit) {
                // 命中目标炮台，造成伤害
                const target = this.towers.find(t => t.id === pearl.targetId && t.isAlive());
                if (target) {
                    const tilePos = target.getTilePosition();
                    const defenseBonus = this.gameMap.tileHasGuardAura(tilePos.x, tilePos.y) ? target.getGuardAuraBonus() : 0;

                    const damage = this.combatSystem.calculateDamage(
                        pearl.damage,
                        DamageType.PHYSICAL,
                        target.getDefenseWithBonus(defenseBonus),
                        target.getMagicResist()
                    );
                    target.takeDamage(damage);

                    // 添加伤害飘字
                    this.addDamagePopup(damage, DamageType.PHYSICAL, target.getPosition());
                }
            }

            if (!pearl.isAlive()) {
                pearl.destroy();
                this.bubblePearls.splice(i, 1);
            }
        }
    }

    /**
     * 发射 AK47 子弹（AK47 Capoo 攻击）
     */
    private fireAK47Bullets(data: AK47BulletData): void {
        for (let i = 0; i < data.count; i++) {
            // 起始位置添加小幅随机偏移（模拟散射）
            const offsetX = (Math.random() - 0.5) * 5;
            const offsetY = (Math.random() - 0.5) * 5;
            const startPos = {
                x: data.startPos.x + offsetX,
                y: data.startPos.y + offsetY,
            };

            // 目标位置也添加小幅偏移
            const targetOffsetX = (Math.random() - 0.5) * 15;
            const targetOffsetY = (Math.random() - 0.5) * 15;
            const targetPos = {
                x: data.targetPos.x + targetOffsetX,
                y: data.targetPos.y + targetOffsetY,
            };

            const bullet = new AK47Bullet(
                startPos,
                targetPos,
                data.damage,
                data.targetId,
                'enemy' // 发射者类型标识
            );
            this.ak47Bullets.push(bullet);
            this.projectileLayer.addChild(bullet.getContainer());
        }
    }

    /**
     * 更新 AK47 子弹
     */
    private updateAK47Bullets(deltaTime: number): void {
        for (let i = this.ak47Bullets.length - 1; i >= 0; i--) {
            const bullet = this.ak47Bullets[i];
            const hit = bullet.update(deltaTime);

            if (hit) {
                // 命中目标炮台，造成伤害
                const target = this.towers.find(t => t.id === bullet.targetId && t.isAlive());
                if (target) {
                    const tilePos = target.getTilePosition();
                    const defenseBonus = this.gameMap.tileHasGuardAura(tilePos.x, tilePos.y) ? target.getGuardAuraBonus() : 0;

                    const damage = this.combatSystem.calculateDamage(
                        bullet.damage,
                        DamageType.PHYSICAL,
                        target.getDefenseWithBonus(defenseBonus),
                        target.getMagicResist()
                    );
                    target.takeDamage(damage);
                    this.addDamagePopup(damage, DamageType.PHYSICAL, target.getPosition());
                }
            }

            // 清理失效子弹
            if (!bullet.isAlive()) {
                bullet.destroy();
                this.ak47Bullets.splice(i, 1);
            }
        }
    }

    /**
     * 更新敌人
     */
    private updateEnemies(deltaTime: number): void {
        // 收集炮台信息用于珍珠奶茶 Capoo 攻击检测
        const towerInfos = this.towers
            .filter(t => t.isAlive())
            .map(t => ({
                id: t.id,
                tilePos: t.getTilePosition(),
                pixelPos: t.getPosition(),
                isAlive: t.isAlive(),
            }));

        for (const enemy of this.enemies) {
            if (!enemy.isAlive()) continue;

            // 珍珠奶茶 Capoo 特殊处理
            if (enemy.type === EnemyType.CAPOO_BUBBLETEA && enemy instanceof CapooBubbleTea) {
                // 设置珍珠发射回调（如果尚未设置）
                if (!enemy._pearlCallbackSet) {
                    enemy.setOnFirePearls((data: BubblePearlData) => {
                        this.fireBubblePearls(data);
                    });
                    enemy._pearlCallbackSet = true;
                }

                // 尝试攻击范围内的炮台
                enemy.tryAttack(towerInfos);
            }

            // AK47 Capoo 特殊处理
            if (enemy.type === EnemyType.CAPOO_AK47 && enemy instanceof CapooAK47) {
                // 设置子弹发射回调（如果尚未设置）
                if (!enemy._bulletCallbackSet) {
                    enemy.setOnFireBullets((data: AK47BulletData) => {
                        this.fireAK47Bullets(data);
                    });
                    enemy._bulletCallbackSet = true;
                }

                // 尝试攻击范围内的炮台
                enemy.tryAttack(towerInfos);
            }

            const reachedEnd = enemy.update(deltaTime);

            if (reachedEnd) {
                // 敌人到达蓝门，扣除核心生命值
                this.coreHealth--;
                this.updateUI();
                enemy.kill();
                console.log(`[游戏] 敌人进入蓝门，核心生命值: ${this.coreHealth}`);
            }
        }
    }

    /**
     * 更新子弹
     */
    private updateProjectiles(deltaTime: number): void {
        for (const projectile of this.projectiles) {
            if (!projectile.isAlive()) continue;

            // 找到目标敌人
            const target = this.enemies.find((e) => e.id === projectile.getTargetId());

            if (!target || !target.isAlive()) {
                // 目标已不存在，销毁子弹
                projectile.hit();
                continue;
            }

            // 更新目标位置
            projectile.updateTargetPosition(target.getPosition());

            // 更新子弹位置
            const hit = projectile.update(deltaTime);

            if (hit) {
                // 命中目标，造成伤害
                const damage = this.combatSystem.calculateDamage(
                    projectile.getDamage(),
                    DamageType.PHYSICAL,
                    target.getDefense(),
                    target.getMagicResist()
                );

                target.takeDamage(damage);
                projectile.hit();

                // 添加伤害飘字
                this.addDamagePopup(damage, DamageType.PHYSICAL, target.getPosition());

                console.log(`[游戏] 子弹命中敌人，造成 ${damage} 伤害`);

                // 击杀奖励
                if (!target.isAlive()) {
                    this.gold += 10;
                    this.updateUI();
                }
            }
        }
    }

    /**
     * 更新火焰粒子（喷火器攻击）
     * 处理火焰粒子的移动和与敌人的碰撞检测
     */
    private updateFlameParticles(deltaTime: number): void {
        for (const particle of this.flameParticles) {
            if (!particle.isAlive()) continue;

            // 更新粒子位置
            particle.update(deltaTime);

            // 检查与敌人的碰撞
            for (const enemy of this.enemies) {
                if (!enemy.isAlive()) continue;

                // 碰撞检测
                if (particle.checkCollision(enemy.getPosition(), 20)) {
                    // 造成伤害
                    const damage = this.combatSystem.calculateDamage(
                        particle.getDamage(),
                        DamageType.MAGICAL, // 假设火焰是魔法伤害
                        enemy.getDefense(),
                        enemy.getMagicResist()
                    );

                    enemy.takeDamage(damage);
                    particle.hit();

                    // 添加伤害飘字
                    this.addDamagePopup(damage, DamageType.MAGICAL, enemy.getPosition());

                    // 击杀奖励
                    if (!enemy.isAlive()) {
                        this.gold += 10;
                        this.updateUI();
                    }

                    break; // 每个粒子只能命中一个敌人
                }
            }
        }
    }

    /**
     * 清理死亡实体
     */
    private cleanupDeadEntities(): void {
        // 清理死亡的敌人
        for (let i = this.enemies.length - 1; i >= 0; i--) {
            if (!this.enemies[i].isAlive()) {
                const enemy = this.enemies[i];
                // 创建死亡特效
                this.spawnDeathEffect(enemy.getPosition(), 30, 0x2ecc71);
                // 先从血条层移除该敌人的血条
                const healthBar = enemy.getHealthBarContainer();
                if (healthBar.parent) {
                    healthBar.parent.removeChild(healthBar);
                }
                enemy.destroy();
                this.enemies.splice(i, 1);
            }
        }

        // 清理死亡的炮台
        for (let i = this.towers.length - 1; i >= 0; i--) {
            if (!this.towers[i].isAlive()) {
                const tower = this.towers[i];
                const tilePos = tower.getTilePosition();
                this.gameMap.setTowerOnTile(tilePos.x, tilePos.y, false);
                // 创建死亡特效
                this.spawnDeathEffect(tower.getPosition(), 40, 0x3498db);
                // 先从血条层移除该炮台的血条
                const healthBar = tower.getHealthBarContainer();
                if (healthBar.parent) {
                    healthBar.parent.removeChild(healthBar);
                }

                // 如果是近卫塔且正在被清理，移除其光环
                if (tower.type === TowerType.GUARD && tower instanceof GuardTower) {
                    this.onGuardTowerRemoved(tower);
                }

                tower.destroy();
                this.towers.splice(i, 1);
            }
        }

        // 清理命中的子弹
        for (let i = this.projectiles.length - 1; i >= 0; i--) {
            if (!this.projectiles[i].isAlive()) {
                this.projectiles[i].destroy();
                this.projectiles.splice(i, 1);
            }
        }

        // 清理消失的火焰粒子
        for (let i = this.flameParticles.length - 1; i >= 0; i--) {
            if (!this.flameParticles[i].isAlive()) {
                this.flameParticles[i].destroy();
                this.flameParticles.splice(i, 1);
            }
        }

        // 清理消失的伤害飘字
        for (let i = this.popups.length - 1; i >= 0; i--) {
            if (!this.popups[i].isAlive()) {
                this.popups[i].destroy();
                this.popups.splice(i, 1);
            }
        }
    }

    /**
     * 检查波次完成
     * 当所有敌人已生成并全部被击溺时，标记波次完成
     */
    private checkWaveComplete(): void {
        if (!this.waveSystem.isWaveInProgress()) {
            return;
        }

        // 检查：1) 所有敌人已生成 2) 所有敌人已被消灭
        if (this.waveSystem.isAllEnemiesSpawned()) {
            const aliveEnemies = this.enemies.filter((e) => e.isAlive());
            if (aliveEnemies.length === 0) {
                // 所有敌人已被击溺，标记波次完成
                console.log('[游戏] 当前波次所有敌人已被击溺');
                this.waveSystem.markWaveComplete();
            }
        }
    }

    /**
     * 更新UI显示
     */
    private updateUI(): void {
        if (this.coreHealthText) {
            this.coreHealthText.text = `核心生命: ${this.coreHealth}/${this.maxCoreHealth}`;
        }
        if (this.goldText) {
            this.goldText.text = `金币: ${this.gold}`;
        }
        if (this.waveText) {
            this.waveText.text = `波次: ${this.waveSystem.getCurrentWaveNumber()}/${this.waveSystem.getTotalWaves()}`;
        }

        // 更新部署栏金币（用于禁用/启用单位按钮）
        if (this.deploymentBar) {
            this.deploymentBar.updateGold(this.gold);
        }
    }

    /**
     * 添加伤害飘字
     * @param damage 伤害数值
     * @param type 伤害类型
     * @param position 弹出位置（像素坐标）
     */
    private addDamagePopup(damage: number, type: DamageType, position: Position): void {
        const popup = new DamagePopup(damage, type, position);
        this.popups.push(popup);
        this.popupLayer.addChild(popup.getContainer());
    }

    /**
     * 更新所有伤害飘字
     * @param deltaTime 时间增量
     */
    private updateDamagePopups(deltaTime: number): void {
        for (const popup of this.popups) {
            popup.update(deltaTime);
        }
    }

    /**
     * 生成死亡特效
     * @param position 死亡位置
     * @param size 实体大小
     * @param color 实体颜色
     */
    private spawnDeathEffect(position: Position, size: number, color: number): void {
        const effect = new DeathEffect(position, size, color);
        this.deathEffects.push(effect);
        this.entityLayer.addChild(effect.getContainer());
    }

    /**
     * 更新所有死亡特效
     * @param deltaTime 时间增量
     */
    private updateDeathEffects(deltaTime: number): void {
        for (let i = this.deathEffects.length - 1; i >= 0; i--) {
            const effect = this.deathEffects[i];
            effect.update(deltaTime);
            if (!effect.isAlive()) {
                effect.destroy();
                this.deathEffects.splice(i, 1);
            }
        }
    }

    /**
     * 结束游戏
     */
    private endGame(victory: boolean): void {
        this.gameState = victory ? GameState.VICTORY : GameState.DEFEAT;
        this.app.ticker.remove(this.gameLoop, this);

        console.log(`[游戏] 游戏结束，${victory ? '胜利' : '失败'}！`);

        // 显示结果
        const resultText = new Text({
            text: victory ? '胜利！' : '失败...',
            style: new TextStyle({
                fontFamily: 'Microsoft YaHei, Arial',
                fontSize: 48,
                fill: victory ? '#27ae60' : '#e74c3c',
                fontWeight: 'bold',
                stroke: { color: '#000000', width: 4 },
            }),
        });
        resultText.x = this.app.screen.width / 2 - resultText.width / 2;
        resultText.y = this.app.screen.height / 2 - resultText.height / 2;
        this.uiLayer.addChild(resultText);

        // 回调
        this.onGameEnd?.(victory);
    }

    /**
     * 设置游戏结束回调
     */
    public setOnGameEnd(callback: (victory: boolean) => void): void {
        this.onGameEnd = callback;
    }

    /**
     * 重置游戏
     */
    public reset(): void {
        // 停止游戏循环
        this.app.ticker.remove(this.gameLoop, this);

        // 清理所有实体
        for (const tower of this.towers) {
            tower.destroy();
        }
        for (const enemy of this.enemies) {
            enemy.destroy();
        }
        for (const projectile of this.projectiles) {
            projectile.destroy();
        }
        for (const particle of this.flameParticles) {
            particle.destroy();
        }

        this.towers = [];
        this.enemies = [];
        this.projectiles = [];
        this.flameParticles = [];

        // 重置状态
        this.gameState = GameState.IDLE;
        this.coreHealth = this.maxCoreHealth;
        this.gold = 100;
        this.waveSystem.reset();

        // 更新UI
        this.updateUI();

        console.log('[游戏] 游戏已重置');
    }

    /**
     * 处理窗口缩放
     * 重新居中地图和 UI
     */
    public onResize(): void {
        this.centerMap();
        // 重新设置部署栏位置
        if (this.deploymentBar) {
            this.deploymentBar.centerAtBottom(this.app.screen.width, this.app.screen.height);
        }
        console.log('[游戏] 窗口缩放，重新居中');
    }

    // ============================================================
    // 光环系统 - 护盾效果由炮塔自己管理，destroy 时自动清理
    // ============================================================

    /**
     * 当近卫塔放置时，为周围已有的炮塔添加护盾效果
     */
    private onGuardTowerPlaced(guardTower: GuardTower): void {
        const affectedTiles = guardTower.getAuraAffectedTiles();

        for (const tile of affectedTiles) {
            this.gameMap.addGuardAuraToTile(tile.x, tile.y);
            console.log(`[光环系统] 处理地块 (${tile.x}, ${tile.y})`);

            // 检查该地块是否有其他炮塔
            const towerOnTile = this.towers.find(t => {
                const pos = t.getTilePosition();
                const match = pos.x === tile.x && pos.y === tile.y && t.id !== guardTower.id && t.isAlive();
                if (pos.x === tile.x && pos.y === tile.y) {
                    console.log(`[光环系统] 地块 (${tile.x}, ${tile.y}) 匹配到炮塔: ${t.getName()}, ID: ${t.id}, 当前存活: ${t.isAlive()}`);
                }
                return match;
            });

            // 如果有炮塔且没有护盾效果，创建护盾
            if (towerOnTile && !towerOnTile.hasAuraEffect()) {
                console.log(`[光环系统] 为位于 (${tile.x}, ${tile.y}) 的 ${towerOnTile.getName()} 添加护盾效果`);
                const pixelPos = this.gameMap.tileToPixel(tile.x, tile.y);
                const effect = new AuraGlowEffect(pixelPos);
                towerOnTile.setAuraEffect(effect);
                this.entityLayer.addChild(effect.getContainer());
            }
        }
        console.log(`[光环系统] 近卫塔放置于 (${guardTower.getTilePosition().x}, ${guardTower.getTilePosition().y})，受影响地块:`, affectedTiles);
    }

    /**
     * 当近卫塔移除时，移除周围地块的光环效果
     */
    private onGuardTowerRemoved(guardTower: GuardTower): void {
        const affectedTiles = guardTower.getAuraAffectedTiles();

        for (const tile of affectedTiles) {
            this.gameMap.removeGuardAuraFromTile(tile.x, tile.y);

            // 如果该地块光环计数降为0，清除该地块炮塔的护盾
            if (this.gameMap.getTileGuardAuraCount(tile.x, tile.y) === 0) {
                const towerOnTile = this.towers.find(t => {
                    const pos = t.getTilePosition();
                    return pos.x === tile.x && pos.y === tile.y && t !== guardTower;
                });
                if (towerOnTile) {
                    towerOnTile.clearAuraEffect();
                }
            }
        }
        console.log(`[光环系统] 近卫塔移除，影响 ${affectedTiles.length} 个地块`);
    }

    /**
     * 销毁游戏
     */
    public destroy(): void {
        this.reset();
        this.app.ticker.remove(this.gameLoop, this);
        this.mapLayer.destroy({ children: true });
        this.entityLayer.destroy({ children: true });
        this.projectileLayer.destroy({ children: true });
        this.uiLayer.destroy({ children: true });
    }
}
