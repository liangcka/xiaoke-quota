# Claude娘

贴在 Claude 桌面 App 窗口右下角、陪你看剩余额度的看板娘，灵感来自 GPT-Niang（Codex 版）。角色是「小克」。

## 组成

| 部分 | 位置 | 作用 |
| --- | --- | --- |
| 桌面挂件 | `app/` | 透明窗口，跟随 Claude 窗口贴在右下角：小克动画、按压压扁、思考泡泡、托盘图标 |
| 配套插件 xiaoke-quota | `plugin/xiaoke-quota/` | 装进 Claude（设置 → 插件），在每个 Code 会话里读取官方 5 小时 / 每周额度，写到 `%LOCALAPPDATA%\ClaudeNiang\bridge.json` 给挂件 |
| 本地插件市场 | `.claude-plugin/marketplace.json` | 让 Claude 能从这个文件夹安装上面的插件 |

额度只读、来自 Claude 自己的官方数据，不需要登录、Cookie 或任何 key。

## 安装

1. 下载到一个固定位置（不要放在压缩包或临时目录里）：

   ```bash
   git clone https://github.com/liangcka/xiaoke-quota.git ClaudeNiang
   ```

   或在仓库页面 Code → Download ZIP，解压后使用。
2. 双击 **安装Claude娘.cmd**：安装配套插件 → 选择是否开机自启（默认否）→ 启动挂件。
3. 在 Claude 里新开一个会话、发一条消息，小克就能拿到额度了。

只想单独安装配套插件（例如在另一台电脑上给已有的挂件供数），在 Claude Code 2.1.275 或更高版本的会话里输入：

```
/plugin install xiaoke-quota --marketplace liangcka/xiaoke-quota
```

需要：Windows 10/11、Windows PowerShell 5.1（系统自带）、Claude 桌面 App。动画使用系统自带的 WebP 解码器；没有时会自动改用静态立绘。

## 使用

- **点小克**：弹出泡泡，依次显示 5 小时剩余 → 本周剩余 → Claude Code 今日 token → 一句语录
- **点泡泡**：翻到下一页，最后一页再点就收起；每页停留 5 秒自动收起
- **按住小克**：压扁，松开回弹；按住拖动可以调整她相对 Claude 窗口的位置
- **Ctrl + 滚轮 / 右键 → 大小**：0.6–2.5 倍（默认 1.5 倍）；超过 384px 时自动换用 512px 高清动画
- **右键菜单**：显示模式（跟随 Claude 窗口 / 桌面自由摆放）、置顶、声音、自动说话、语录编辑、省内存模式、开机自启
- 剩余额度低于 20% 时，小克会换成哭哭表情
- 在 Claude 里输入 `/xiaoke` 可以打开插件自带的额度面板

## 停用与卸载

双击 **停用Claude娘.cmd**：退出挂件、移除开机自启、卸载配套插件，可选删除数据目录。之后即可移动或删除程序文件夹。

## 数据位置

`%LOCALAPPDATA%\ClaudeNiang\`：设置（config.json）、自定义语录（quotes.txt）、插件写入的额度（bridge.json）、日志。

## 署名与授权

- 代码：MIT。
- 角色「小克」立绘与动画（`app/assets/xiaoke/`、`plugin/xiaoke-quota/assets/` 及图标）来自 [aklnaaw/dsh-xiaoke-widget](https://github.com/aklnaaw/dsh-xiaoke-widget)，动画制作 AirsEDA，按 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 授权：**仅限非商业使用**，再分发需署名并沿用相同授权。详见 `app/assets/xiaoke/LICENSE-ARTWORK`。
- 泡泡几何与按压手感参考 dsh-xiaoke-widget；整体灵感来自 GPT-Niang。
