/**
 * ============================================================
 * 个人主页
 * ============================================================
 * 显示用户账户信息和功能导航
 */

import { SocketManager } from '../network/SocketManager';
import { AssetManager } from '../core/AssetManager';
import { User } from '../types';

/**
 * 主页类
 */
export class HomePage {
  /** 页面容器元素 */
  private container: HTMLDivElement;

  /** 网络管理器 */
  private socketManager: SocketManager;

  /** 当前用户 */
  private user: User | null = null;

  /** 进入大厅回调 */
  private onEnterLobby: (() => void) | null = null;

  /** 进入升级中心回调 */
  private onEnterUpgrade: (() => void) | null = null;

  /** 登出回调 */
  private onLogout: (() => void) | null = null;

  /**
   * 构造函数
   */
  constructor() {
    this.socketManager = SocketManager.getInstance();
    this.container = this.createContainer();
  }

  /**
   * 创建页面容器
   */
  private createContainer(): HTMLDivElement {
    const container = document.createElement('div');
    container.id = 'home-page';
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

    // 标题
    const title = document.createElement('h1');
    title.textContent = '星跃塔防';
    title.style.cssText = `
      font-size: 32px;
      color: #e94560;
    `;
    navbar.appendChild(title);

    // 登出按钮
    const logoutBtn = document.createElement('button');
    logoutBtn.textContent = '登出';
    logoutBtn.className = 'btn btn-secondary';
    logoutBtn.onclick = () => this.handleLogout();
    navbar.appendChild(logoutBtn);

    container.appendChild(navbar);

    // 主要内容区域
    const content = document.createElement('div');
    content.style.cssText = `
      width: 100%;
      max-width: 1200px;
      display: grid;
      grid-template-columns: 300px 1fr;
      gap: 24px;
    `;

    // 用户信息卡片
    const userCard = document.createElement('div');
    userCard.className = 'card';
    userCard.id = 'user-card';
    userCard.style.cssText = `
      height: fit-content;
    `;
    content.appendChild(userCard);

    // 功能区域
    const features = document.createElement('div');
    features.style.cssText = `
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 24px;
    `;

    // 对战大厅按钮
    const lobbyCard = this.createFeatureCard(
      '⚔️ 对战大厅',
      '进入战斗，保卫基地！',
      () => this.onEnterLobby?.()
    );
    features.appendChild(lobbyCard);

    // 升级中心按钮
    const upgradeCard = this.createFeatureCard(
      '📈 升级中心',
      '强化你的防御单位',
      () => this.onEnterUpgrade?.(),
      true
    );
    features.appendChild(upgradeCard);

    content.appendChild(features);
    container.appendChild(content);

    return container;
  }

  /**
   * 创建功能卡片
   */
  private createFeatureCard(
    title: string,
    description: string,
    onClick: () => void,
    disabled: boolean = false
  ): HTMLDivElement {
    const card = document.createElement('div');
    card.className = 'card';
    card.style.cssText = `
      cursor: ${disabled ? 'not-allowed' : 'pointer'};
      transition: transform 0.3s ease, box-shadow 0.3s ease;
      opacity: ${disabled ? '0.6' : '1'};
      text-align: center;
      padding: 40px;
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

    const titleEl = document.createElement('h2');
    titleEl.textContent = title;
    titleEl.style.cssText = `
      font-size: 28px;
      margin-bottom: 12px;
    `;
    card.appendChild(titleEl);

    const descEl = document.createElement('p');
    descEl.textContent = disabled ? '敬请期待' : description;
    descEl.style.cssText = `
      color: #888;
      font-size: 16px;
    `;
    card.appendChild(descEl);

    return card;
  }

  /**
   * 更新用户信息显示
   */
  private updateUserInfo(): void {
    const userCard = document.getElementById('user-card');
    if (!userCard) return;

    userCard.innerHTML = '';

    // 头像占位
    const avatar = document.createElement('div');
    avatar.style.cssText = `
      width: 80px;
      height: 80px;
      border-radius: 50%;
      background: linear-gradient(135deg, #e94560 0%, #ff6b6b 100%);
      margin: 0 auto 16px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 36px;
    `;
    avatar.textContent = this.user?.username.charAt(0).toUpperCase() || '?';
    userCard.appendChild(avatar);

    // 用户名
    const username = document.createElement('h3');
    username.textContent = this.user?.username || '未知用户';
    username.style.cssText = `
      font-size: 24px;
      text-align: center;
      margin-bottom: 8px;
    `;
    userCard.appendChild(username);

    // 账号信息
    const info = document.createElement('p');
    info.style.cssText = `
      color: #888;
      font-size: 14px;
      text-align: center;
    `;
    if (this.user?.createdAt) {
      const date = new Date(this.user.createdAt);
      info.textContent = `注册时间: ${date.toLocaleDateString()}`;
    }
    userCard.appendChild(info);

    // 分隔线
    const divider = document.createElement('hr');
    divider.style.cssText = `
      border: none;
      border-top: 1px solid rgba(255, 255, 255, 0.1);
      margin: 24px 0;
    `;
    userCard.appendChild(divider);

    // 统计信息
    const stats = document.createElement('div');
    stats.innerHTML = `
      <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
        <span style="color: #888;">战斗胜利</span>
        <span>0</span>
      </div>
      <div style="display: flex; justify-content: space-between; margin-bottom: 8px;">
        <span style="color: #888;">战斗失败</span>
        <span>0</span>
      </div>
      <div style="display: flex; justify-content: space-between;">
        <span style="color: #888;">击杀敌人</span>
        <span>0</span>
      </div>
    `;
    userCard.appendChild(stats);
  }

  /**
   * 处理登出
   */
  private handleLogout(): void {
    AssetManager.getInstance().playClickSound();
    this.socketManager.logout();
    this.onLogout?.();
  }

  /**
   * 设置进入大厅回调
   */
  public setOnEnterLobby(callback: () => void): void {
    this.onEnterLobby = callback;
  }

  /**
   * 设置进入升级中心回调
   */
  public setOnEnterUpgrade(callback: () => void): void {
    this.onEnterUpgrade = callback;
  }

  /**
   * 设置登出回调
   */
  public setOnLogout(callback: () => void): void {
    this.onLogout = callback;
  }

  /**
   * 显示页面
   */
  public show(parent: HTMLElement): void {
    this.user = this.socketManager.getCurrentUser();
    parent.innerHTML = '';
    parent.appendChild(this.container);
    this.updateUserInfo();
  }

  /**
   * 隐藏页面
   */
  public hide(): void {
    this.container.remove();
  }
}
