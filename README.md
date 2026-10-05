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

图形化配置：面板底部 **⚙** 打开配置窗口，左侧列表右侧表单，「隧道 / 节点」两页切换；
保存时统一校验（名称/主机/端口/转发格式），改动到运行中隧道的生效参数会自动重启该隧道，
新加的 autoStart 隧道保存后立即拉起。删除被引用的节点会被拦截。

数据模型分两层，配置文件 `~/.config/tunnel-bar/config.json`（首次启动自动生成，老版
sshTarget 单串格式会自动迁移，迁移前原文件备份为 `config.json.v1.bak`）：

- **节点** = SSH 端点：名称、主机（域名/IP/`~/.ssh/config` 别名）、端口、用户、密钥路径。
  主机填别名时，端口/用户/密钥留空即完全沿用别名里的定义
- **隧道** = 绑定一个节点 + 若干条转发（`-L` 值）+ 附加参数 + 自动启动

```json
{
  "nodes": [
    { "id": "node-example", "name": "example", "host": "example", "port": "", "user": "", "identityFile": "" }
  ],
  "tunnels": [
    {
      "id": "database-forward", "name": "数据库访问", "nodeId": "node-example",
      "forwards": [
        {"type": "L", "bind": "127.0.0.1", "port": "15432", "host": "127.0.0.1", "rport": "5432"},
        {"type": "D", "port": "1080"}
      ],
      "extraArgs": [], "autoStart": true
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `node.host` | 域名 / IP / ssh 别名；`port`/`user`/`identityFile` 留空 = 不附加对应参数 |
| `forward.type` | `L` 本地转发(-L) / `R` 远程转发(-R) / `D` 动态SOCKS(-D)，一条隧道可混搭多条 |
| `forward.*` | L/R 填 地址+端口+目标地址+目标端口（地址可留空）；D 只填端口。老版纯字符串格式自动按 L 迁移 |
| `tunnel.extraArgs` | 附加 ssh 参数（空格分隔，不支持含空格的值） |
| `tunnel.autoStart` | 应用启动时是否自动拉起 |

内置固定参数（每条隧道都会带上）：
`-N -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ExitOnForwardFailure=yes -o ConnectTimeout=10`

## 菜单说明

- `●` 运行中 / `↻` 断线重连中（显示第几次、几秒后重试、最后一条 ssh 报错）/ `○` 已停止
- 点击隧道名即切换启停；「启动全部 / 停止全部」批量操作
- **退出 app 不杀隧道**，重启后按 pid 文件自动接管恢复状态；要停隧道用面板开关

## 开机自启

系统设置 → 通用 → 登录项与扩展 → 登录项 → `+` 添加 `build/TunnelBar.app`。
（建议把 .app 挪到 `~/Applications` 等稳定位置再加入，build 目录容易被清理）

## 卸载

先在面板里「全部停止」（或手动 `pkill -f "ssh -N -L"`）→ 删掉项目目录 → `rm -rf ~/.config/tunnel-bar`
