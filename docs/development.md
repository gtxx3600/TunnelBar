# 开发与构建

[返回项目首页](../README.md) · [使用指南](user-guide.md)

以下命令均在项目根目录运行。

## 构建与运行

```bash
./build.sh
open build/TunnelBar.app
```

要求：Xcode Command Line Tools（swiftc），macOS 13+。

构建会为完整 `.app` 进行本机 ad-hoc 签名并验证，以支持系统登录项。
如有签名证书，可通过 `TUNNELBAR_SIGN_IDENTITY` 指定。

应用图标采用黑绿莫比乌斯 B 版，位于 `Resources/AppIcon.png`。
`gpt-image-2.5-sunburst` 生成的平滑原版与选定稿保留在 `Resources/IconCandidates/`；
B 版使用 6/16 px 块大小、0.85 px 预过滤及 42% 混合，保留平滑轮廓。
制作参数记录在 `Resources/AppIcon.recipe.json`，正式图标去掉外侧白底以适配 macOS 透明圆角。
构建时通过 `Tools/build-icon.sh` 生成 16–1024 像素的标准与 Retina 资源，打包为 `AppIcon.icns`。

如需从原版重做图标：

```bash
mkdir -p build
swiftc -O Tools/icon-filter-study.swift -o build/icon-filter-study-renderer
build/icon-filter-study-renderer Resources/IconCandidates/MobiusGreen.png build/icon-filter-study
swift Tools/prepare-app-icon.swift build/icon-filter-study/MobiusGreen-filter-B.png Resources/AppIcon.png
./build.sh
```

运行回归测试：`./test.sh`。测试使用临时配置和不联网的模拟 SSH 程序，
覆盖配置损坏、迁移备份、启停竞态、重连，以及应用退出后接管 L/R/D 隧道，不操作现有连接。
分组测试覆盖旧配置兼容、组内启停与重试取消，以及移动、重命名、删除分组时保留原 PID。
也覆盖连接确认、错误分类、端口预检、模板与复制；端口占用测试仅绑定临时回环端口，不发起连接。
配置文件测试覆盖导入导出往返、旧版只读迁移、冲突引用重映射、重复导入、原配置备份及失败保护；
登录项测试使用独立服务替身，覆盖系统状态刷新、等待允许、注册与关闭失败，不改动真实登录偏好。

可选真实 SSH 验证：`python3 Tests/local-ssh-test.py`。脚本生成临时密钥和配置，
启动只监听 `127.0.0.1` 的临时 sshd，验证 L/R/D 建立、快速重启与接管，结束后清理。
此测试需要 Python 3，不读取用户的 SSH 配置或连接外部服务器。

离屏预览：`./preview.sh` 在 `build/panel-preview/` 输出真实 SwiftUI 面板的深浅外观、
多隧道、分组展开/折叠、空分组、错误和滚动状态图片。预览只使用展示数据，不读取在线配置或启动 SSH。
预览也会检查弹窗给出额外高度时的布局，确保内容按理想高度收紧。

配置窗口预览：`./config-preview.sh` 在 `build/config-preview/` 输出节点、L/R/D 转发、
分组管理、模板归属、校验错误、保存影响与最小窗口尺寸的深浅外观图片，只使用独立展示数据。

## 更新 README 图片

```bash
bash Tools/update-readme-images.sh
```

脚本重新渲染真实 SwiftUI 界面，将首页使用的截图和封面写入 `docs/images/`。
封面通过 `Tools/ReadmeArtwork.swift` 为菜单栏截图添加背景、标题和应用图标，不改变界面内容。
生成过程使用通用演示数据，不读取用户配置或启动 SSH；修改界面后可运行此命令同步展示素材。
