# 扩展屏助手 · HarmonyOS 客户端

把鸿蒙手机或平板变成 Windows 电脑的第二块无线扩展屏。在同一局域网内发现并连接电脑端的扩展屏服务端，实时显示电脑桌面画面，并把触摸、键盘操作回传给电脑。

- 平台：HarmonyOS NEXT（SDK / API 26，arm64-v8a）
- 语言：ArkTS + ArkUI，Native C++（TLS 通道、图像解码）
- 应用名：扩展屏助手
- 包名：`top.asahilee.app.screenmirror`
- 版本：1.1.0（versionCode 1000001）

兼容性：与 Windows 端 spacedesk 系列扩展屏服务端的局域网协议互通，本工程是该协议的**独立实现**，不包含任何第三方应用的代码、资源或私有库。

## 功能

| 能力 | 说明 |
| --- | --- |
| 局域网发现 | UDP 广播探测，解析服务端应答中的名称、IP、端口与系统信息 |
| 手动直连 | 支持直接输入 IP / 端口连接，无需依赖发现广播 |
| 加密连接 | 服务端开启访问密码时走 TLS-PSK 通道；密码按服务器 IP 分别保存 |
| 密码状态机 | 首次连接询问密码，连接成功后才保存；密码错误自动清除并重新询问，不同 IP 独立记忆 |
| 画面显示 | MJPEG 增量条带解码，按整帧尺寸缩放后局部更新到画布，不做全屏重绘 |
| 设置 | 分辨率（720P / 1080P / 跟随屏幕）、帧率（15 / 30 / 60）、画质、方向、鼠标模式等本地持久化 |
| 输入回传 | 单指触摸（按下 / 移动 / 抬起）、键盘文本与功能键 |
| 会话管理 | 帧级流控 ACK、Ping 应答、断线重连、正常断开通知 |
| 隐私合规 | 首次启动隐私提示，应用内可打开隐私政策托管页面 |

## 目录结构

```
AppScope/                     应用级配置、名称与图标
entry/src/main/ets/
├── common/
│   ├── SdProtocol.ets        协议常量、报文头读写、各类报文构造
│   ├── DiscoveryService.ets  UDP 发现与应答解析
│   ├── SdClient.ets          TCP 会话、拆包、流控、输入上报
│   ├── SdSettings.ets        设置、按 IP 密码本、首启同意状态
│   ├── KeyMapping.ets        鸿蒙 KeyCode 到服务端按键码的映射
│   ├── AudioClient.ets       音频通道（当前版本未启用）
│   └── H264Decoder.ets       原生解码接口（当前版本默认关闭）
├── pages/
│   ├── Index.ets             服务器发现、手动 IP、画质快捷设置
│   ├── Display.ets           画面渲染、密码弹窗、触摸/键盘回传
│   └── SettingsPage.ets      设置、隐私政策入口、关于
└── entryability/EntryAbility.ets
entry/src/main/cpp/           TLS 通道与图像解码的 Native 实现
store/                        应用市场素材与合规作业单
```

## 构建

需要 DevEco Studio 26.x（HarmonyOS 26.0.0 SDK）。工程路径不能含中文字符，否则命令行构建会报 `00306003 Specification Limit Violation`。

```bash
# 1. 从模板创建本机构建配置（含签名信息，不入库）
cp build-profile.example.json5 build-profile.json5

# 2. 在 DevEco Studio 中配置签名（File > Project Structure > Signing Configs）
#    或在 build-profile.json5 的 signingConfigs 中填写本机证书路径

# 3. 编译调试 HAP
bash build_v2.sh

# 4. 编译发布 APP
bash build_release.sh
```

产物位置：`entry/build/default/outputs/default/`。`*.hap` 用于本机调试直装，应用市场提交必须使用**发布证书签名的 `*.app`**。

> 根目录 `build-profile.json5` 含本机签名配置，已被 `.gitignore` 排除。请勿把证书、Profile 或口令提交到版本库。

## 上架材料

- `PRIVACY.md`：隐私政策（与当前版本实际权限、数据行为一致）
- `TERMS.md`：用户协议
- `store/listing.md`：应用市场文案、隐私标签与后台填写清单
- `store/上架合规检查.md`：逐项合规检查结论与阻断项
- `store/icon-216.png` / `icon-1024.png`：方角应用图标
- `store/screenshots/`：1080×1920 介绍截图

应用市场提交需要在华为 AppGallery Connect 控制台由开发者本人完成实名、软著、发布证书申请与最终提审，详见 `store/上架合规检查.md`。

## 已知限制

- 当前版本固定使用 MJPEG；H.264 解码链路在高帧率高分辨率下表现不稳定，暂不开放切换。
- 音频通道、多指手势、USB 直连尚未开放。
- 部分设备上远端桌面方向适配仍在优化中。

## 许可

本工程为独立实现，仅供本人设备互联使用；与所兼容的服务端产品无隶属、授权或关联关系。
