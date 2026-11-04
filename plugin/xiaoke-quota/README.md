# Claude娘（xiaoke-quota）

Claude娘 桌面挂件的配套插件：在每个 Claude Code / Claude 桌面 App（Code）会话里读取官方剩余额度，写到 `%LOCALAPPDATA%\ClaudeNiang\bridge.json` 给贴在 Claude 窗口右下角的小克显示；也自带一个 `/xiaoke` 额度面板。

安装（Claude Code 2.1.275 或更高版本的会话里）：

```
/plugin install xiaoke-quota --marketplace liangcka/xiaoke-quota
```

完整的桌面挂件见仓库根目录的 README。

- **额度数据**：直接读取会话自己的官方数据（与状态栏同源的 5 小时 / 每周额度窗口），不需要登录、Cookie 或任何 key。额度每变动 1 个百分点、或每轮回复结束时自动刷新；新会话会先显示上次记下的数值。
- **小克**：呼吸、头发摇摆、眨眼的动画；按住她会「压一下」（压扁后回弹）；剩余额度低于 20% 时换成哭哭表情。
- **思考泡泡**：小圆点 → 中圆点 → 大泡依次弹出；点泡泡翻到下一页（5 小时剩余 → 本周剩余 → 一句语录），最后一页再点会收起；点小克重新弹出。
- **命令**：`/xiaoke` 重新打开面板。

## 署名与授权

- 代码：MIT（见 LICENSE）。
- 角色「小克」立绘与动画（`assets/` 下的图片、`.claude-plugin/icon.png`）来自 [aklnaaw/dsh-xiaoke-widget](https://github.com/aklnaaw/dsh-xiaoke-widget)，动画制作 AirsEDA，按 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 授权：**仅限非商业使用**，再分发需署名并沿用相同授权。详见 `assets/LICENSE-ARTWORK` 与 `assets/PROVENANCE-upstream.md`。
- 泡泡几何与按压手感参考 dsh-xiaoke-widget，整体灵感来自 GPT-Niang。
