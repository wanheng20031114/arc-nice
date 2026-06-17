/**
 * ============================================================
 * 资源管理器
 * ============================================================
 * 负责加载和管理游戏中的所有资源（图片、音频等）
 * 使用 PixiJS 的资源加载系统
 */

import { Assets, Texture } from 'pixi.js';

// @ts-ignore
import clickSoundUrl from '../sound/Click.m4a';
// @ts-ignore
import flameThrowerFireUrl from '../sound/FlameThrower_fire.m4a';
// @ts-ignore
import prototypeTowerFireUrl from '../sound/PrototypeTower_fire.m4a';
// @ts-ignore
import plantingSoundUrl from '../sound/planting.m4a';
// @ts-ignore
import laserTowerFireUrl from '../sound/LaserTower_fire.m4a';
// @ts-ignore
import capooBubbleTeaFireUrl from '../sound/capoo_BubbleTea_fire.m4a';
// @ts-ignore
import capooAK47FireUrl from '../sound/capoo_ak47_fire.m4a';
// @ts-ignore
import antiaircraftTowerFireUrl from '../sound/AntiaircraftTower_fire.m4a';

// 导入高清图片素材
// @ts-ignore
import prototypeTowerImg from '../assets/towers/PrototypeTower/PrototypeTower.png';
// @ts-ignore
import flameThrowerImg from '../assets/towers/FlameThrower/FlameThrower.png';
// @ts-ignore
import capooSwordsmanImg from '../assets/capoos/capoo_swordsman/capoo_swordsman.png';

// 激光塔图标
// @ts-ignore
import laserTowerIconImg from '../assets/towers/LaserTower/LaserTower.png';
// 激光塔动画精灵表（8帧水平排列）
// @ts-ignore
import laserTowerSpriteImg from '../assets/towers/LaserTower/LaserTower_sprite.png';

// 珍珠奶茶 Capoo 资源
// @ts-ignore
import capooBubbleTeaImg from '../assets/capoos/capoo_BubbleTea/capoo_BubbleTea.png';
// @ts-ignore
import capooBubbleTeaSpriteImg from '../assets/capoos/capoo_BubbleTea/capoo_BubbleTea_sprite.png';

// AK47 Capoo 资源
// @ts-ignore
import capooAK47Img from '../assets/capoos/capoo_ak47/capoo_ak47.png';
// @ts-ignore
import capooAK47SpriteImg from '../assets/capoos/capoo_ak47/capoo_ak47_sprite.png';

// 防空塔资源
// @ts-ignore
import antiaircraftTowerImg from '../assets/towers/AntiaircraftTower/AntiaircraftTower.png';
// @ts-ignore
import antiaircraftTowerSpriteImg from '../assets/towers/AntiaircraftTower/AntiaircraftTower_sprite.png';

// 加特林塔资源
// @ts-ignore
import gatlingTowerImg from '../assets/towers/GatlingTower/GatlingTower.png';
// @ts-ignore
import gatlingTowerSpriteImg from '../assets/towers/GatlingTower/GatlingTower_sprite.png';

// 近卫塔资源
// @ts-ignore
import guardTowerImg from '../assets/towers/GuardTower/GuardTower.png';
// @ts-ignore
import guardTowerSpriteImg from '../assets/towers/GuardTower/GuardTower_sprite.png';

// 环境/地形贴图
// @ts-ignore
import grassImg from '../assets/env/Grass1.png';
// @ts-ignore
import flowerImg from '../assets/env/Flower1.png';
// @ts-ignore
import highPlatformImg from '../assets/env/HighPlatform1.png';

/**
 * 资源管理器类
 * 单例模式，全局统一管理游戏资源
 */
export class AssetManager {
    /** 单例实例 */
    private static instance: AssetManager;

    /** 是否已加载完成 */
    private loaded: boolean = false;

    /** 纹理缓存 */
    private textures: Map<string, Texture> = new Map();

    /** 喷火器音效上次播放时间（用于冷却控制） */
    private lastFlameThrowerSoundTime: number = 0;

    /**
     * 私有构造函数（单例模式）
     */
    private constructor() { }

    /**
     * 获取单例实例
     */
    public static getInstance(): AssetManager {
        if (!AssetManager.instance) {
            AssetManager.instance = new AssetManager();
        }
        return AssetManager.instance;
    }

    /**
     * 加载所有游戏资源
     * @returns Promise<void>
     */
    public async loadAssets(): Promise<void> {
        if (this.loaded) {
            console.log('[资源管理器] 资源已加载，跳过重复加载');
            return;
        }

        console.log('[资源管理器] 开始加载游戏资源...');

        try {
            // 1. 注册并加载高清图片资源
            Assets.add({ alias: 'tower_prototype', src: prototypeTowerImg });
            Assets.add({ alias: 'tower_flamethrower', src: flameThrowerImg });
            Assets.add({ alias: 'enemy_capoo', src: capooSwordsmanImg });

            // 激光塔资源
            Assets.add({ alias: 'tower_laser', src: laserTowerIconImg });
            Assets.add({ alias: 'laser_sprite', src: laserTowerSpriteImg });

            // 珍珠奶茶 Capoo 资源
            Assets.add({ alias: 'capoo_bubbletea', src: capooBubbleTeaImg });
            Assets.add({ alias: 'capoo_bubbletea_attack_sprite', src: capooBubbleTeaSpriteImg });

            // AK47 Capoo 资源
            Assets.add({ alias: 'capoo_ak47', src: capooAK47Img });
            Assets.add({ alias: 'capoo_ak47_attack_sprite', src: capooAK47SpriteImg });

            // 防空塔资源
            Assets.add({ alias: 'tower_antiaircraft', src: antiaircraftTowerImg });
            Assets.add({ alias: 'antiaircraft_sprite', src: antiaircraftTowerSpriteImg });

            // 加特林塔资源
            Assets.add({ alias: 'tower_gatling', src: gatlingTowerImg });
            Assets.add({ alias: 'gatling_sprite', src: gatlingTowerSpriteImg });

            // 近卫塔资源
            Assets.add({ alias: 'tower_guard', src: guardTowerImg });
            Assets.add({ alias: 'guard_sprite', src: guardTowerSpriteImg });

            // 地形贴图
            Assets.add({ alias: 'env_grass', src: grassImg });
            Assets.add({ alias: 'env_flower', src: flowerImg });
            Assets.add({ alias: 'env_platform', src: highPlatformImg });

            const textures = await Assets.load([
                'tower_prototype', 'tower_flamethrower', 'enemy_capoo',
                'tower_laser', 'laser_sprite',
                'capoo_bubbletea', 'capoo_bubbletea_attack_sprite',
                'capoo_ak47', 'capoo_ak47_attack_sprite',
                'tower_antiaircraft', 'antiaircraft_sprite',
                'tower_gatling', 'gatling_sprite',
                'tower_guard', 'guard_sprite',
                'env_grass', 'env_flower', 'env_platform',
            ]);

            // 2. 存入本地纹理缓存
            this.textures.set('tower_prototype', textures.tower_prototype);
            this.textures.set('tower_flamethrower', textures.tower_flamethrower);
            this.textures.set('enemy_capoo', textures.enemy_capoo);

            // 激光塔纹理
            this.textures.set('tower_laser', textures.tower_laser);
            this.textures.set('laser_sprite', textures.laser_sprite);

            // 珍珠奶茶 Capoo 纹理
            this.textures.set('capoo_bubbletea', textures.capoo_bubbletea);
            this.textures.set('capoo_bubbletea_attack_sprite', textures.capoo_bubbletea_attack_sprite);

            // AK47 Capoo 纹理
            this.textures.set('capoo_ak47', textures.capoo_ak47);
            this.textures.set('capoo_ak47_attack_sprite', textures.capoo_ak47_attack_sprite);

            // 防空塔纹理
            this.textures.set('tower_antiaircraft', textures.tower_antiaircraft);
            this.textures.set('antiaircraft_sprite', textures.antiaircraft_sprite);

            // 加特林塔纹理
            this.textures.set('tower_gatling', textures.tower_gatling);
            this.textures.set('gatling_sprite', textures.gatling_sprite);

            // 近卫塔纹理
            this.textures.set('tower_guard', textures.tower_guard);
            this.textures.set('guard_sprite', textures.guard_sprite);

            // 地形纹理
            this.textures.set('env_grass', textures.env_grass);
            this.textures.set('env_flower', textures.env_flower);
            this.textures.set('env_platform', textures.env_platform);

            // 3. 创建其他占位符纹理
            this.createPlaceholderTextures();

            this.loaded = true;
            console.log('[资源管理器] 资源加载完成！（包含珍珠奶茶Capoo精灵表）');
        } catch (error) {
            console.error('[资源管理器] 资源加载失败:', error);
            throw error;
        }
    }

    /**
     * 创建占位符纹理
     * 在没有实际图片资源时使用
     */
    private createPlaceholderTextures(): void {
        // 这些纹理会在运行时通过 Graphics 绘制
        // 此处仅作为示例，实际纹理在 Game.ts 中创建
        console.log('[资源管理器] 使用占位符纹理');
    }

    /**
     * 获取纹理
     * @param name 纹理名称
     * @returns Texture 对象
     */
    public getTexture(name: string): Texture | undefined {
        return this.textures.get(name);
    }

    /**
     * 设置纹理
     * @param name 纹理名称
     * @param texture 纹理对象
     */
    public setTexture(name: string, texture: Texture): void {
        this.textures.set(name, texture);
    }

    /**
     * 检查资源是否已加载
     */
    public isLoaded(): boolean {
        return this.loaded;
    }

    /**
     * 播放点击音效
     * 使用原生 Audio API，确保非阻塞播放
     */
    public playClickSound(): void {
        this.playSound(clickSoundUrl, 0.8);
    }

    /**
     * 播放喷火器开火音效
     * 每 3 秒至多播放一次，避免频繁播放导致噪音
     */
    public playFlameThrowerFireSound(): void {
        const now = Date.now();
        const cooldown = 3000; // 3 秒冷却时间
        if (now - this.lastFlameThrowerSoundTime >= cooldown) {
            this.lastFlameThrowerSoundTime = now;
            this.playSound(flameThrowerFireUrl, 0.2);
        }
    }

    /**
     * 播放原型炮台开火音效
     */
    public playPrototypeTowerFireSound(): void {
        this.playSound(prototypeTowerFireUrl, 0.1);
    }
    /**
      * 播放原型炮台（给加特林使用）开火音效
      */
    public playGatlingTowerFireSound(): void {
        this.playSound(prototypeTowerFireUrl, 0.02);
    }

    /**
     * 播放炮台放置成功音效
     */
    public playPlantingSound(): void {
        this.playSound(plantingSoundUrl, 0.6);
    }

    /**
     * 播放激光塔开火音效
     */
    public playLaserTowerFireSound(): void {
        this.playSound(laserTowerFireUrl, 0.2);
    }

    /**
     * 播放珍珠奶茶 Capoo 开火音效
     */
    public playCapooBubbleTeaFireSound(): void {
        this.playSound(capooBubbleTeaFireUrl, 0.2);
    }

    /**
     * 播放 AK47 Capoo 开火音效
     */
    public playCapooAK47FireSound(): void {
        this.playSound(capooAK47FireUrl, 0.26);
    }

    /**
     * 播放防空塔开火音效
     */
    public playAntiaircraftTowerFireSound(): void {
        this.playSound(antiaircraftTowerFireUrl, 0.20);
    }

    /**
     * 通用音效播放方法
     * @param url 音效文件 URL
     * @param volume 音量 (0-1)
     */
    private playSound(url: string, volume: number = 0.5): void {
        try {
            const audio = new Audio(url);
            audio.volume = volume;
            audio.play().catch(error => {
                console.warn('[资源管理器] 音效播放受限:', error);
            });
        } catch (error) {
            console.error('[资源管理器] 播放音效失败:', error);
        }
    }
}
