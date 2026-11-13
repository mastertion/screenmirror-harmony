# 扩展屏助手（HarmonyOS NEXT）

把 HarmonyOS 手机变成 Windows 电脑的第二块屏幕：局域网无线投屏、屏幕镜像与扩展显示、触控回传。本工程为独立实现的原生 HarmonyOS 应用，通过局域网协议与主流 Windows 投屏服务端驱动互操作，不包含任何第三方应用代码、资源或图标。

## 功能特性

- 全中文界面（连接 / 设置 / 关于 / 使用说明 / 投屏页）
- 局域网主机自动发现（UDP 广播）+ 手动添加 IP + 最近连接记录
- TCP 会话建立、心跳保活、断连处理、显示状态同步
- MJPEG 画面解码上屏，触控坐标归一化回传、软键盘事件
- H.264 硬解码：已内置 `OH_AVCodec` native 解码器（`entry/src/main/cpp/`）
- 设置持久化

## 编译运行

### 环境

- DevEco Studio 5.0 及以上
- HarmonyOS SDK API 12（`5.0.0(12)`）
- 一台 HarmonyOS NEXT 真机（UDP 广播与投屏必须真机验证，模拟器网络受限）

### 步骤

1. `File → Open` 选择本仓库根目录
2. `File → Project Structure → Signing Configs` 登录并自动生成签名
3. 连接手机，点 `Run 'entry'`
4. 命令行构建（需 DevEco 附带的 hvigor）：`hvigorw assembleHap`

### 使用

1. 在 Windows 电脑上安装并启动兼容的投屏服务端驱动
2. 手机与电脑接入同一 Wi-Fi，关闭路由器「AP 隔离」
3. Windows 防火墙放行 **UDP 28252 / TCP 28252**
4. 打开应用 →「连接」页等待主机出现，或点「手动添加」输入电脑 IP
5. 点击主机进入全屏投屏页；右上角悬浮按钮展开工具栏

## 工程结构

```
AppScope/                     应用级配置、图标、应用名
entry/src/main/module.json5   模块配置、页面、权限声明
entry/src/main/ets/
  entryability/EntryAbility.ets
  common/Protocol.ets         协议核心：常量、枚举、包头偏移、发现应答、身份包、组帧
  common/Res.ets              资源字符串同步读取
  model/ServerInfo.ets        主机列表项
  model/SettingsModel.ets     设置持久化
  service/DiscoveryService.ets    UDP 发现
  service/ConnectionService.ets   TCP 会话 / 帧解码 / 输入回传
  pages/Index.ets             首页（Tabs）
  pages/DisplayPage.ets       全屏投屏页
  pages/Panels.ets            可复用的设置 / 关于 / 说明面板
  pages/{Settings,About,Manual}Page.ets
entry/src/main/cpp/           OH_AVCodec H.264 硬解码 native 模块
entry/src/main/resources/
  base/element/string.json    170+ 条中文文案
  base/element/color.json · float.json
  base/profile/main_pages.json
```

## 协议要点（`common/Protocol.ets`）

| 项 | 值 |
| --- | --- |
| 发现 / 会话端口 | `28252` |
| 发现探测载荷 | `SPACEDESK-NET-CLIENT\0`（UTF-8，连发 5 次） |
| 发现应答长度 | `308` 字节 |
| 包头长度 | `128` 字节，**小端序** |
| 身份包载荷 | `334` 字节，UTF-16LE |
| 报文类型 | 0 身份 / 1 心跳 / 2 画面帧 / 8 断开 / 10 鼠标 / 11 键盘 / 12 触摸 / 13 手写笔 |
| 编码方式 | 0 不压缩 / 1 YUV / 3 MJPEG / 4 H.264 / 5 自动 |

## 注意事项

- **混淆与兼容**：身份包中 `osType` 声明沿用服务端已知的枚举值，保证互操作。
- **加密会话**：服务端启用 TLS-PSK 时，当前版本会给出明确提示而不尝试连接，避免静默失败。
- **授权合规**：本工程为独立实现，不含任何授权绕过逻辑，使用请遵守相关软件的许可条款。
- **签名**：`build-profile.json5` 的 `signingConfigs` 留空，真机运行前必须配置自动签名。

## 联系方式

- 邮箱：dev@asahilee.top
