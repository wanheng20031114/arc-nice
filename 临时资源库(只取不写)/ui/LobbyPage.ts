/**
 * ============================================================
 * 对战大厅页面
 * ============================================================
 * 选择游戏模式（单人/多人）
 */

import { AssetManager } from '../core/AssetManager';

/**
 * 大厅页面类
 */
export class LobbyPage {
    /** 页面容器元素 */
    private container: HTMLDivElement;

    /** 返回主页回调 */
    private onBack: (() => void) | null = null;

    /** 开始单人游戏回调 */
    private onStartSinglePlayer: (() => void) | null = null;

    /**
     * 构造函数
     */
    constructor() {
        this.container = this.createContainer();
    }

    /**
     * 创建页面容器
     */
    private createContainer(): HTMLDivElement {
        const container = document.createElement('div');
        container.id = 'lobby-page';
        container.style.cssText = `
      display: flex;
      flex-direction: column;
      align-items: center;
      min-height: 100vh;
      padding: 40px 20px;
    `;

        // 顶部导航栏
        const navbar = document.createElement('div');
        navbar.style.cssText = `
      width: 100%;
      max-width: 1200px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 40px;
    `;

        // 返回按钮
        const backBtn = document.createElement('button');
        backBtn.textContent = '← 返回主页';
        backBtn.className = 'btn btn-secondary';
        backBtn.onclick = () => {
            AssetManager.getInstance().playClickSound();
            this.onBack?.();
        };
        navbar.appendChild(backBtn);

        // 标题
        const title = document.createElement('h1');
        title.textContent = '对战大厅';
        title.style.cssText = `
      font-size: 32px;
      color: #e94560;
    `;
        navbar.appendChild(title);

        // 占位元素
        const spacer = document.createElement('div');
        spacer.style.width = '100px';
        navbar.appendChild(spacer);

        container.appendChild(navbar);

        // 模式选择区域
        const modes = document.createElement('div');
        modes.style.cssText = `
      width: 100%;
      max-width: 800px;
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 32px;
    `;

        // 单人模式
        const singlePlayer = this.createModeCard(
            '🎮 单人模式',
            '独自挑战，保卫基地',
            '• 3波敌人来袭\n• 放置炮台防御\n• 守护核心生命值',
            false,
            () => this.onStartSinglePlayer?.()
        );
        modes.appendChild(singlePlayer);

        // 四人模式
        const multiPlayer = this.createModeCard(
            '👥 四人模式',
            '与好友组队作战',
            '• 四人协作\n• 共同防守\n• 即将推出...',
            true,
            () => { }
        );
        modes.appendChild(multiPlayer);

        container.appendChild(modes);

        return container;
    }

    /**
     * 创建模式卡片
     */
    private createModeCard(
        title: string,
        subtitle: string,
        features: string,
        disabled: boolean,
        onClick: () => void
    ): HTMLDivElement {
        const card = document.createElement('div');
        card.className = 'card';
        card.style.cssText = `
      cursor: ${disabled ? 'not-allowed' : 'pointer'};
      transition: transform 0.3s ease, box-shadow 0.3s ease;
      opacity: ${disabled ? '0.5' : '1'};
      padding: 32px;
    `;

        if (!disabled) {
            card.onmouseenter = () => {
                card.style.transform = 'translateY(-5px)';
                card.style.boxShadow = '0 10px 40px rgba(233, 69, 96, 0.3)';
            };
            card.onmouseleave = () => {
                card.style.transform = 'translateY(0)';
                card.style.boxShadow = 'none';
            };
            card.onclick = () => {
                AssetManager.getInstance().playClickSound();
                onClick();
            };
        }

        // 标题
        const titleEl = document.createElement('h2');
        titleEl.textContent = title;
        titleEl.style.cssText = `
      font-size: 32px;
      margin-bottom: 8px;
      text-align: center;
    `;
        card.appendChild(titleEl);

        // 副标题
        const subtitleEl = document.createElement('p');
        subtitleEl.textContent = disabled ? '敬请期待' : subtitle;
        subtitleEl.style.cssText = `
      color: #888;
      font-size: 18px;
      margin-bottom: 24px;
      text-align: center;
    `;
        card.appendChild(subtitleEl);

        // 分隔线
        const divider = document.createElement('hr');
        divider.style.cssText = `
      border: none;
      border-top: 1px solid rgba(255, 255, 255, 0.1);
      margin-bottom: 24px;
    `;
        card.appendChild(divider);

        // 特性列表
        const featuresEl = document.createElement('pre');
        featuresEl.textContent = features;
        featuresEl.style.cssText = `
      color: #aaa;
      font-size: 14px;
      font-family: inherit;
      white-space: pre-line;
      line-height: 1.8;
    `;
        card.appendChild(featuresEl);

        // 开始按钮
        if (!disabled) {
            const startBtn = document.createElement('button');
            startBtn.textContent = '开始游戏';
            startBtn.className = 'btn btn-primary';
            startBtn.style.cssText = `
        width: 100%;
        margin-top: 24px;
      `;
            startBtn.onclick = (e) => {
                e.stopPropagation();
                AssetManager.getInstance().playClickSound();
                onClick();
            };
            card.appendChild(startBtn);
        }

        return card;
    }

    /**
     * 设置返回回调
     */
    public setOnBack(callback: () => void): void {
        this.onBack = callback;
    }

    /**
     * 设置开始单人游戏回调
     */
    public setOnStartSinglePlayer(callback: () => void): void {
        this.onStartSinglePlayer = callback;
    }

    /**
     * 显示页面
     */
    public show(parent: HTMLElement): void {
        parent.innerHTML = '';
        parent.appendChild(this.container);
    }

    /**
     * 隐藏页面
     */
    public hide(): void {
        this.container.remove();
    }
}
