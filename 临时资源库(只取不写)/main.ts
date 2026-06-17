/**
 * ============================================================
 * 应用主入口
 * ============================================================
 * 初始化 PixiJS 应用，管理页面路由和游戏生命周期
 */

import { Application } from 'pixi.js';
import { SocketManager } from './network/SocketManager';
import { LoginPage } from './ui/LoginPage';
import { HomePage } from './ui/HomePage';
import { LobbyPage } from './ui/LobbyPage';
import { GameUI } from './ui/GameUI';
import { Game } from './core/Game';

/**
 * 页面状态枚举
 */
enum PageState {
    LOGIN = 'login',
    HOME = 'home',
    LOBBY = 'lobby',
    GAME = 'game',
}

/**
 * 主应用类
 */
class App {
    /** 应用容器 */
    private appContainer: HTMLElement;

    /** PixiJS 应用实例 */
    private pixiApp: Application | null = null;

    /** 网络管理器 */
    private socketManager: SocketManager;

    /** 当前页面状态 */
    private currentPage: PageState = PageState.LOGIN;

    /** 页面实例 */
    private loginPage: LoginPage;
    private homePage: HomePage;
    private lobbyPage: LobbyPage;
    private gameUI: GameUI;

    /** 游戏实例 */
    private game: Game | null = null;

    /**
     * 构造函数
     */
    constructor() {
        this.appContainer = document.getElementById('app')!;
        this.socketManager = SocketManager.getInstance();

        // 创建页面实例
        this.loginPage = new LoginPage();
        this.homePage = new HomePage();
        this.lobbyPage = new LobbyPage();
        this.gameUI = new GameUI();

        // 设置页面回调
        this.setupCallbacks();
    }

    /**
     * 设置页面回调
     */
    private setupCallbacks(): void {
        // 登录页回调
        this.loginPage.setOnLoginSuccess(() => {
            this.navigateTo(PageState.HOME);
        });

        // 主页回调
        this.homePage.setOnEnterLobby(() => {
            this.navigateTo(PageState.LOBBY);
        });
        this.homePage.setOnLogout(() => {
            this.navigateTo(PageState.LOGIN);
        });

        // 大厅回调
        this.lobbyPage.setOnBack(() => {
            this.navigateTo(PageState.HOME);
        });
        this.lobbyPage.setOnStartSinglePlayer(() => {
            this.navigateTo(PageState.GAME);
        });

        // 游戏UI回调
        this.gameUI.setOnBackToLobby(() => {
            this.exitGame();
            this.navigateTo(PageState.LOBBY);
        });
    }

    /**
     * 初始化应用
     */
    public async init(): Promise<void> {
        console.log('[应用] 初始化中...');

        // 连接服务器
        try {
            await this.socketManager.connect();
            console.log('[应用] 服务器连接成功');
        } catch (error) {
            console.warn('[应用] 服务器连接失败，将以离线模式运行');
        }

        // 检查是否已登录
        const user = await this.socketManager.fetchCurrentUser();

        if (user) {
            console.log('[应用] 检测到已登录用户:', user.username);
            this.navigateTo(PageState.HOME);
        } else {
            this.navigateTo(PageState.LOGIN);
        }

        console.log('[应用] 初始化完成');
    }

    /**
     * 页面导航
     */
    private navigateTo(page: PageState): void {
        console.log(`[应用] 导航到: ${page}`);
        this.currentPage = page;

        switch (page) {
            case PageState.LOGIN:
                this.loginPage.show(this.appContainer);
                break;

            case PageState.HOME:
                this.homePage.show(this.appContainer);
                break;

            case PageState.LOBBY:
                this.lobbyPage.show(this.appContainer);
                break;

            case PageState.GAME:
                this.startGame();
                break;
        }
    }

    /**
     * 启动游戏
     */
    private async startGame(): Promise<void> {
        console.log('[应用] 启动游戏...');

        // 清空容器
        this.appContainer.innerHTML = '';

        // 创建游戏画布容器
        const gameContainer = document.createElement('div');
        gameContainer.id = 'game-container';
        gameContainer.style.cssText = `
      width: 100%;
      height: 100vh;
      position: relative;
    `;
        this.appContainer.appendChild(gameContainer);

        // 创建 PixiJS 应用
        this.pixiApp = new Application();
        await this.pixiApp.init({
            width: window.innerWidth,
            height: window.innerHeight,
            backgroundColor: 0x1a1a2e,
            resolution: window.devicePixelRatio || 1,
            autoDensity: true,
        });

        // 添加画布到容器
        gameContainer.appendChild(this.pixiApp.canvas);

        // 创建游戏实例
        this.game = new Game(this.pixiApp);
        await this.game.init();

        // 显示游戏UI
        this.gameUI.show(gameContainer);

        // 设置游戏结束回调
        this.game.setOnGameEnd((victory) => {
            console.log(`[应用] 游戏结束，${victory ? '胜利' : '失败'}`);
        });

        // 监听窗口大小变化
        window.addEventListener('resize', this.handleResize);

        // 禁用画布内的右键菜单
        this.pixiApp.canvas.addEventListener('contextmenu', (e) => {
            e.preventDefault();
        });

        console.log('[应用] 游戏启动完成');
    }

    /**
     * 退出游戏
     */
    private exitGame(): void {
        console.log('[应用] 退出游戏...');

        // 移除窗口大小监听
        window.removeEventListener('resize', this.handleResize);

        // 销毁游戏
        if (this.game) {
            this.game.destroy();
            this.game = null;
        }

        // 销毁 PixiJS 应用
        if (this.pixiApp) {
            this.pixiApp.destroy(true, { children: true, texture: true });
            this.pixiApp = null;
        }

        // 隐藏游戏UI
        this.gameUI.hide();
    }

    /**
     * 处理窗口大小变化
     * 调整渲染器大小并重新居中地图
     */
    private handleResize = (): void => {
        if (this.pixiApp) {
            this.pixiApp.renderer.resize(window.innerWidth, window.innerHeight);
            // 缩放后重新居中地图
            if (this.game) {
                this.game.onResize();
            }
        }
    };
}

// ============================================================
// 应用启动
// ============================================================

/**
 * 启动应用
 */
async function main(): Promise<void> {
    console.log('='.repeat(50));
    console.log('星跃塔防 - StarJump Tower Defense');
    console.log('='.repeat(50));

    const app = new App();
    await app.init();
}

// 启动
main().catch(console.error);
