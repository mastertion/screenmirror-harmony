# 扩展屏助手（HarmonyOS NEXT 原生版）

把鸿蒙手机变成 Windows 电脑的第二块屏幕。全中文界面，基于对 `spacedesk` Android v2.1.38 的**协议层逆向分析**独立实现，不包含原 APK 的任何代码、资源或图标。

> 完整逆向过程、协议字段与证据见上级目录 `analysis/逆向分析报告.md`。
> 全部界面文案的英中对照见 `analysis/汉化对照表.md`。

---

## 一、能做什么 / 不能做什么

| 能力 | 状态 |
| --- | --- |
| 全中文 UI（连接 / 设置 / 关于 / 使用说明 / 投屏页） | ✅ 已完成 |
| 设置持久化（沿用原 APK 的 `key_*` 键名） | ✅ 已完成 |
| 局域网主机发现（UDP 28252 广播 + 308 字节应答解析） | ✅ 已实现 |
| 手动添加 IP、最近连接记录、密码输入 | ✅ 已实现 |
| TCP 28252 会话 + 128 字节包头身份握手 + 流式组帧 | ✅ 已实现 |
| 心跳 / 断连 / 显示状态 / 会话状态机 | ✅ 已实现 |
| MJPEG 画面解码上屏（`image.createImageSource` → `PixelMap`） | ✅ 已实现 |
| 触摸坐标归一化回传、软键盘事件 | ⚠️ 骨架已实现，载荷字段需按抓包结果最终对齐 |
| H.264 硬解码 | ⚠️ 预留 `onH264Data` 回调，需接入 native `OH_AVCodec` + `XComponent` |
| TLS-PSK 加密会话 | ❌ 未实现（会给出明确提示，不会静默失败） |
| 音频播放 / USB 有线 / Wi-Fi Direct / SonarPen / 内购授权 | ❌ 未实现 |

**换句话说：工程可编译、可运行、能发现主机并建立会话；要 100% 对齐官方客户端的画面与操控，还需要用 Wireshark 抓包把输入事件载荷和 H.264 帧封装补齐。** 所有不确定的位置在 `Protocol.ets` 里都有 `TODO / 待抓包确认` 注释。

---

## 二、编译运行

### 环境

- DevEco Studio 5.0 及以上
- HarmonyOS SDK API 12（`5.0.0(12)`）
- 一台 HarmonyOS NEXT 真机（UDP 广播与投屏必须真机验证，模拟器网络受限）

### 步骤

1. `File → Open` 选择本目录 `SpaceDeskHarmony/`
2. `File → Project Structure → Signing Configs` 登录并自动生成签名
3. 连接手机，点 `Run 'entry'`
4. 命令行构建（需 DevEco 附带的 hvigor）：`hvigorw assembleHap`

### 使用

1. 在 Windows 电脑上安装并启动 spacedesk 服务端驱动
2. 手机与电脑接入同一 Wi-Fi，关闭路由器「AP 隔离」
3. Windows 防火墙放行 **UDP 28252 / TCP 28252**
4. 打开应用 →「连接」页等主机出现，或点「手动添加」输入电脑 IP
5. 点击主机进入全屏投屏页；右上角悬浮按钮展开工具栏

---

## 三、工程结构

```
AppScope/                     应用级配置、图标、应用名
entry/src/main/module.json5   模块配置、5 个页面、权限声明
entry/src/main/ets/
  entryability/EntryAbility.ets
  common/Protocol.ets         ★ 协议核心：常量、枚举、包头偏移、发现应答、身份包、组帧
  common/Res.ets              资源字符串同步读取
  model/ServerInfo.ets        主机列表项
  model/SettingsModel.ets     设置持久化
  service/DiscoveryService.ets    UDP 发现
  service/ConnectionService.ets   TCP 会话 / 帧解码 / 输入回传
  pages/Index.ets             首页（Tabs）
  pages/DisplayPage.ets       全屏投屏页
  pages/Panels.ets            可复用的设置 / 关于 / 说明面板
  pages/{Settings,About,Manual}Page.ets
entry/src/main/resources/
  base/element/string.json    ★ 170+ 条中文文案
  base/element/color.json · float.json
  base/profile/main_pages.json
```

### 关键协议常量（`common/Protocol.ets`）

| 项 | 值 |
| --- | --- |
| 发现 / 会话端口 | `28252` |
| 发现探测载荷 | `SPACEDESK-NET-CLIENT\0`（UTF-8，连发 5 次） |
| 发现应答长度 | `308` 字节 |
| 包头长度 | `128` 字节，**小端序** |
| 身份包载荷 | `334` 字节，UTF-16LE |
| 报文类型 | 0 身份 / 1 心跳 / 2 画面帧 / 8 断开 / 10 鼠标 / 11 键盘 / 12 触摸 / 13 手写笔 |
| 编码方式 | 0 不压缩 / 1 YUV / 3 MJPEG / 4 H.264 / 5 自动 |

---

## 四、接入 H.264 原生解码（后续工作）

`ConnectionService.renderFrame()` 在检测到非 JPEG 帧时调用 `onH264Data(ArrayBuffer)`。
要补齐 H.264：

1. 在 `entry/src/main/cpp/` 增加 `OH_AVCodec` 视频解码器（`video/avc`），
   从服务端下发的 `csd-0/csd-1`（SPS/PPS）初始化，输出 Surface
2. 用 `XComponent` 的 `surfaceId` 绑定解码输出，替换 `DisplayPage` 里的 `Image(this.frame)`
3. 在 `module.json5` 中无需额外权限，但需在 `build-profile.json5` 打开 native 构建
4. 用 Wireshark 抓一次官方客户端会话，确认 H.264 帧载荷里 NAL 的分片与长度字段

输入事件同理：`Protocol.buildInputEvent()` 目前用「包头类型 + 归一化坐标 × 1000」的占位布局，
抓包确认 `SAMotionEvent` 的真实字段后只需替换这一个函数。

---

## 五、注意事项

- **混淆与兼容**：原 APK 用了 R8 强混淆，鸿蒙端身份包里 `osType` 仍声明 `ANDROID=3`，因为服务端只认识已知枚举值。
- **加密会话**：服务端可启用 TLS-PSK，鸿蒙端当前会提示「加密连接需要商业授权」而不尝试连接，避免静默失败。
- **授权合规**：spacedesk 为 datronicsoft 专有软件，免费版限非商业用途。本工程不含任何授权绕过逻辑，商用请自行取得许可。
- **签名**：`build-profile.json5` 的 `signingConfigs` 留空，真机运行前必须配置自动签名。
