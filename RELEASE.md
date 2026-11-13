# 发布到华为应用市场（AppGallery）指引

> 本文件说明把"扩展屏助手"提交到华为应用市场所需的**账号侧**与**工程侧**步骤。
> 注意：**应用市场上架必须通过华为 AppGallery Connect 控制台人工提交**，本工程不提供自动发布接口。

## 一、前置条件（需开发者本人操作）

1. 注册并实名认证 [华为开发者联盟](https://developer.huawei.com/consumer/cn/) 账号
   - 个人开发者或企业开发者均可；企业应用需企业资质。
2. 在 AppGallery Connect 创建应用，获取：
   - **Package name**：必须与 `AppScope/app.json5` 的 `bundleName` 一致（当前 `top.asahilee.app.screenmirror`）。
   - **发布证书（.cer）** + **签名密钥库（.p12）** + **Profile（.p7b）**。
     ⚠️ 不要用本工程 `_sign/` 下的调试证书——那是本地调试用的，市场发布必须用控制台签发的正式证书。

## 二、工程侧发布构建

1. 在 DevEco Studio：`File → Project Structure → Signing Configs`，
   勾选"Automatically generate signature"并登录**发布**证书（或手动导入 .p12/.cer/.p7b）。
2. `Build → Build HAP(s)/APP(s) → Build APP` 生成正式签名包。
3. 本地调试用的 `entry-default-signed.hap` 仅为调试证书，**不可**直接提交市场。

## 三、提交材料清单（控制台填写）

- [ ] 应用名称：扩展屏助手（已与显示名一致）
- [ ] 一句话简介 + 详细简介（建议强调"局域网投屏 / 手机变扩展屏"）
- [ ] 应用图标（已有 `entry/.../media/icon.png`，建议另备 512×512 / 1024×1024）
- [ ] 截图 4–6 张（连接页、投屏页、设置页、关于页）
- [ ] **隐私政策链接**：将本仓库 `PRIVACY.md` 托管为可公网访问的网页（如 GitHub Pages / 自有站点），填入控制台
- [ ] 权限声明说明（见 PRIVACY.md 第三节）
- [ ] 内容分级与适用年龄
- [ ] 是否含付费 / 广告：本应用免费、无广告、无内购

## 四、已完成的合规整改（见 git 提交）

- 移除未使用的 `MICROPHONE` 敏感权限（原声明但未调用，属典型拒审点）。
- 为 `KEEP_BACKGROUND_RUNNING` 补全 `backgroundModes: ["dataTransfer"]` 声明。
- "关于"页去除"逆向分析 / 第三方许可条款"等易触发审核的表述，改为独立互操作实现的中性描述。
- 补充隐私政策模板 `PRIVACY.md`。

## 五、仍需注意的残留风险

- **包名 / 代码去品牌化（已完成）**：包名已改为 `top.asahilee.app.screenmirror`；原生模块 `libscreenmirror.so`、工程名 `screenmirror-harmony`、存储键 `screenmirror_settings` 等均已去除 spacedesk 字样；应用自身不再以 spacedesk 品牌自居（关于页与界面文案均为"独立互操作实现"）。
- **商店曝光策略（用户决策）**：为让搜索 "spacedesk" 的用户能找到本应用，应用市场「应用名称 / 搜索关键词」中保留 spacedesk 字样（见下方上架文案草稿）。该做法存在被华为判定为"克隆 / 冒用第三方品牌"而驳回的风险，已由用户确认承担。
- **上架文案草稿（AppGallery 控制台填写）**：
  - 应用名称：`扩展屏助手（Spacedesk 兼容）` 或 `spacedesk 扩展屏助手 · ScreenMirror`
  - 一句话简介：把鸿蒙手机变成 Windows 电脑的第二块扩展屏，兼容 spacedesk 投屏服务端的局域网协议。
  - 搜索关键词：`spacedesk, 扩展屏, 双屏, 投屏, 无线显示器, screen mirroring`
  - 隐私政策链接：将本仓库 `PRIVACY.md` 托管为 GitHub Pages 后填入控制台。
- **协议常量保留说明**：`Protocol.ets` 中的 `DISCOVERY_MAGIC = 'SPACEDESK-NET-CLIENT\0'` 是服务端要求的握手探测载荷，属于公开协议常量，不可更改，否则无法连接；该字符串仅出现在私有代码与私有仓库文档中，不进入应用商店展示。
- **后台保活**：`dataTransfer` 后台模式需确保确有持续数据传输场景，否则审核可能要求说明。
- 截图、隐私政策托管链接、正式签名证书均需开发者本人在控制台完成。
