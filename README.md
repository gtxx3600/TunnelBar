# TunnelBar

macOS 菜单栏 SSH 隧道管理器。常驻顶部状态栏，预置多条隧道配置，面板里开关即启停；
隧道进程断开后自动指数退避重连（1.5s → 30s 封顶，autossh 风格），稳定运行 60s 后计数清零。

**隧道生命周期独立于 app**：退出/重启 TunnelBar 不会打断隧道——ssh 子进程脱离终端，
app 退出后由 launchd 接管继续跑；重启后 TunnelBar 读取 `~/.config/tunnel-bar/run/*.pid`
校验并接管已在跑的进程（核对 `ps` 命令行防 pid 复用），状态、运行时长（按进程 etime 换算）
直接恢复。要停隧道请用面板开关或「全部停止」。

> ⚠️ 别在终端手动跑 TunnelBar 管理的同一条 `-L` 隧道，端口会互相冲突（ExitOnForwardFailure
> 会让后来者起不来）。每条隧道的 ssh stderr 记在 `run/<id>.log`，面板红叹号点开即见。

## 构建 & 运行

```bash
./build.sh
open build/TunnelBar.app
```

要求：Xcode Command Line Tools（swiftc），macOS 13+。

## 配置

配置文件：`~/.config/tunnel-bar/config.json`（首次启动自动生成，已预置 数据库访问）。
菜单里「编辑配置…」直接打开，改完点「重新载入配置」生效——运行中的隧道配置有变化会自动重启。

```json
{
  "tunnels": [
    {
      "id": "database-forward",
      "name": "数据库访问",
      "sshTarget": "example",
      "forwards": ["127.0.0.1:15432:127.0.0.1:5432"],
      "extraArgs": [],
      "autoStart": true
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `id` | 唯一标识，改配置时按它对应已运行的隧道 |
| `name` | 菜单里显示的名字 |
| `sshTarget` | `~/.ssh/config` 里的别名，或 `user@host`（端口写在别名里最省事） |
| `forwards` | `-L` 参数值数组，一条隧道可以挂多个转发 |
| `extraArgs` | 附加 ssh 参数，如 `["-v"]` |
| `autoStart` | 应用启动时是否自动拉起 |

内置固定参数（每条隧道都会带上）：
`-N -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ExitOnForwardFailure=yes -o ConnectTimeout=10`

## 菜单说明

- `●` 运行中 / `↻` 断线重连中（显示第几次、几秒后重试、最后一条 ssh 报错）/ `○` 已停止
- 点击隧道名即切换启停；「启动全部 / 停止全部」批量操作
- 退出应用会终止所有它拉起的 ssh 进程，不留孤儿

## 开机自启

系统设置 → 通用 → 登录项与扩展 → 登录项 → `+` 添加 `build/TunnelBar.app`。
（建议把 .app 挪到 `~/Applications` 等稳定位置再加入，build 目录容易被清理）

## 卸载

先在面板里「全部停止」（或手动 `pkill -f "ssh -N -L"`）→ 删掉项目目录 → `rm -rf ~/.config/tunnel-bar`
