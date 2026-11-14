import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { loadSettings, saveSettings, SdSettings, listPasswordIps, clearIpPassword } from '../common/SdSettings';

const RES_LABELS: string[] = ['1280 × 720（流畅）', '1920 × 1080（高清）', '跟随屏幕比例'];
const FPS_LABELS: string[] = ['15 帧/秒', '30 帧/秒', '60 帧/秒'];
const FPS_VALUES: number[] = [15, 30, 60];
const ENC_LABELS: string[] = ['MJPEG（兼容性最好）', 'H.264（低带宽，失败自动回退）'];
const COLOR_LABELS: string[] = ['最佳画质 4:4:4（文字最清晰）', '均衡 4:2:2', '流畅 4:2:0（最省带宽）'];
const ORI_LABELS: string[] = ['跟随系统（自动旋转）', '锁定横屏', '锁定竖屏'];
/** 隐私政策托管页面（AGC 协议服务生成） */
const PRIVACY_URL: string = 'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2082897497809754880';
/** 版本号展示（与 AppScope/app.json5 保持一致） */
const APP_VERSION: string = '1.1.0';

function toOptions(labels: string[]): SelectOption[] {
  const out: SelectOption[] = [];
  for (const l of labels) {
    out.push({ value: l });
  }
  return out;
}

/**
 * 设置页。刻意不使用 @Builder 抽象行控件：
 * @Builder 按值传参不会随状态刷新，导致异步加载完成后控件显示与真实值脱节。
 * 所有控件内联绑定 this.settings（@State 对象一级属性可观察），改动即存。
 */
@Entry
@Component
struct SettingsPage {
  @State settings: SdSettings = new SdSettings();
  @State loaded: boolean = false;
  @State deviceName: string = '';
  @State savedPwdIps: string[] = [];
  @State presetApplied: string = '';
  @State savedTip: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    try {
      const s = await loadSettings(this.context);
      // 整体替换后逐项赋值，确保每个绑定都拿到最新值
      this.settings = s;
      this.deviceName = s.deviceName;
      this.savedPwdIps = listPasswordIps(s.passwordBook);
      this.loaded = true;
      console.info(`[Settings] loaded: res=${s.resolutionMode} fps=${s.fps} enc=${s.encoding} ` +
        `color=${s.colorDepth} ori=${s.orientation} stats=${s.showStats} mouse=${s.mouseMode} ` +
        `audio=${s.audioEnabled} autoConn=${s.autoConnect} autoRec=${s.autoReconnect}`);
    } catch (error) {
      const err = error as BusinessError;
      promptAction.showToast({ message: `读取设置失败: ${err.message}` });
    }
  }

  /** 改动即保存 */
  private async persist(): Promise<void> {
    if (!this.loaded) {
      return;
    }
    const s = this.settings;
    try {
      await saveSettings(this.context, s);
      this.savedTip = '已保存';
      console.info(`[Settings] saved: res=${s.resolutionMode} fps=${s.fps} enc=${s.encoding} ` +
        `color=${s.colorDepth} ori=${s.orientation} stats=${s.showStats} mouse=${s.mouseMode} ` +
        `audio=${s.audioEnabled} autoConn=${s.autoConnect} autoRec=${s.autoReconnect}`);
    } catch (error) {
      const err = error as BusinessError;
      this.savedTip = '';
      promptAction.showToast({ message: `保存设置失败: ${err.message}` });
    }
  }

  /** 清除某台主机保存的密码，下次连接该 IP 会重新询问 */
  private async forgetPassword(ip: string): Promise<void> {
    this.settings.passwordBook = clearIpPassword(this.settings.passwordBook, ip);
    this.savedPwdIps = listPasswordIps(this.settings.passwordBook);
    await this.persist();
    promptAction.showToast({ message: `已清除 ${ip} 的密码，下次连接会重新输入` });
  }

  private fpsIndex(): number {
    for (let i = 0; i < FPS_VALUES.length; i++) {
      if (FPS_VALUES[i] === this.settings.fps) {
        return i;
      }
    }
    return 1;
  }

  /** 用系统浏览器打开隐私政策 */
  private openPrivacy(): void {
    this.context.openLink(PRIVACY_URL).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开隐私政策失败，请检查网络' });
    });
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.primary'))
      .fontWeight(FontWeight.Medium)
      .margin({ left: 4, top: 18, bottom: 8 })
  }

  build() {
    Column() {
      Row() {
        Button('← 返回')
          .fontSize(14)
          .height(36)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.text_primary'))
          .onClick(async () => {
            await this.saveInputs();
            router.back();
          })
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })
        Blank()
        Text(this.savedTip)
          .fontSize(12)
          .fontColor($r('app.color.success'))
          .margin({ right: 8 })
        Button('保存')
          .fontSize(14)
          .height(36)
          .backgroundColor($r('app.color.primary'))
          .onClick(async () => {
            await this.saveInputs();
            promptAction.showToast({ message: '设置已保存' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          this.SectionTitle('画质与性能')
          Column() {
            // 画质预设
            Row() {
              Text('画质预设').fontSize(15).fontColor($r('app.color.text_primary')).width(90)
              Button('流畅 720p@15')
                .fontSize(12).height(32).layoutWeight(1)
                .backgroundColor(this.settings.resolutionMode === 0 && this.settings.fps === 15
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.settings.resolutionMode === 0 && this.settings.fps === 15
                  ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.settings.resolutionMode = 0;
                  this.settings.fps = 15;
                  this.presetApplied = '流畅 720p@15';
                  this.persist();
                })
              Button('均衡 720p@30')
                .fontSize(12).height(32).layoutWeight(1).margin({ left: 6 })
                .backgroundColor(this.settings.resolutionMode === 0 && this.settings.fps === 30
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.settings.resolutionMode === 0 && this.settings.fps === 30
                  ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.settings.resolutionMode = 0;
                  this.settings.fps = 30;
                  this.presetApplied = '均衡 720p@30';
                  this.persist();
                })
              Button('高清 1080p@30')
                .fontSize(12).height(32).layoutWeight(1).margin({ left: 6 })
                .backgroundColor(this.settings.resolutionMode === 1 && this.settings.fps === 30
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.settings.resolutionMode === 1 && this.settings.fps === 30
                  ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.settings.resolutionMode = 1;
                  this.settings.fps = 30;
                  this.presetApplied = '高清 1080p@30';
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor($r('app.color.card_background'))

            if (this.presetApplied.length > 0) {
              Text(`已选：${this.presetApplied}（下次连接生效）`)
                .fontSize(12).fontColor($r('app.color.success'))
                .width('100%').padding({ left: 14, bottom: 8 })
                .backgroundColor($r('app.color.card_background'))
            }

            // 分辨率
            Row() {
              Text('分辨率').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Select(toOptions(RES_LABELS))
                .selected(this.settings.resolutionMode)
                .value(RES_LABELS[this.settings.resolutionMode])
                .font({ size: 14 })
                .fontColor($r('app.color.text_secondary'))
                .onSelect((i: number) => {
                  this.settings.resolutionMode = i;
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            // 帧率
            Row() {
              Text('帧率').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Select(toOptions(FPS_LABELS))
                .selected(this.fpsIndex())
                .value(FPS_LABELS[this.fpsIndex()])
                .font({ size: 14 })
                .fontColor($r('app.color.text_secondary'))
                .onSelect((i: number) => {
                  this.settings.fps = FPS_VALUES[i];
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            // 编码：当前版本固定 MJPEG。H.264 原生解码链路在高分辨率 60fps 下会
            // 丢 P 帧 / 截断 AU / 逐像素转换，导致画面割裂、残影、卡顿，暂不开放切换。
            Row() {
              Text('编码').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text('MJPEG').fontSize(14).fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
            Text('为保证画面稳定，本版本固定使用 MJPEG；H.264 硬件解码优化完成后再开放切换。')
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .padding({ left: 14, right: 14, bottom: 10 })
              .backgroundColor($r('app.color.card_background'))
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            // 色彩深度
            Row() {
              Text('编码色彩深度').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Select(toOptions(COLOR_LABELS))
                .selected(this.settings.colorDepth)
                .value(COLOR_LABELS[this.settings.colorDepth])
                .font({ size: 14 })
                .fontColor($r('app.color.text_secondary'))
                .onSelect((i: number) => {
                  this.settings.colorDepth = i;
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            // JPEG 画质
            Row() {
              Text('JPEG 画质').fontSize(15).fontColor($r('app.color.text_primary')).width(110)
              Slider({ value: this.settings.quality, min: 10, max: 100, step: 1 })
                .layoutWeight(1)
                .selectedColor($r('app.color.primary'))
                .onChange((v: number, mode: SliderChangeMode) => {
                  this.settings.quality = Math.round(v);
                  // 拖动结束/点按时才落盘，避免拖动过程高频写偏好存储
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.persist();
                  }
                })
              Text(`${Math.round(this.settings.quality)}`)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width(34)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor($r('app.color.card_background'))
          }
          .borderRadius(16)
          .clip(true)

          this.SectionTitle('设备')
          Column() {
            Row() {
              Text('设备名称').fontSize(15).fontColor($r('app.color.text_primary')).width(110)
              TextInput({ text: this.deviceName })
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor('#FFF5F7FA')
                .onChange((v: string) => {
                  this.deviceName = v;
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
          }
          .borderRadius(16)
          .clip(true)
          Text('设备名称显示在 Windows 端扩展屏服务端的控制面板中')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 8, left: 4 })
            .width('100%')

          this.SectionTitle('连接密码（按服务器 IP 保存）')
          Column() {
            Text('连接时会自动弹出密码输入框，输入电脑端 Driver Console 显示的十六进制密钥。密码只按当前服务器 IP 保存在本机，连接成功后才记住；密码错误或换一台电脑会自动重新询问。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(18)
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 10 })
            if (this.savedPwdIps.length === 0) {
              Text('暂无已保存的连接密码')
                .fontSize(13)
                .fontColor($r('app.color.text_hint'))
                .width('100%')
                .padding({ left: 14, right: 14, bottom: 12 })
            } else {
              ForEach(this.savedPwdIps, (ip: string) => {
                Row() {
                  Text(ip)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                  Button('清除')
                    .fontSize(12)
                    .height(30)
                    .backgroundColor($r('app.color.primary_light'))
                    .fontColor($r('app.color.primary'))
                    .onClick(() => {
                      this.forgetPassword(ip);
                    })
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              }, (ip: string) => ip)
            }
          }
          .borderRadius(16)
          .clip(true)
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start)

          this.SectionTitle('连接行为')
          Column() {
            // 屏幕方向
            Row() {
              Text('屏幕方向').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Select(toOptions(ORI_LABELS))
                .selected(this.settings.orientation)
                .value(ORI_LABELS[this.settings.orientation])
                .font({ size: 14 })
                .fontColor($r('app.color.text_secondary'))
                .onSelect((i: number) => {
                  this.settings.orientation = i;
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            ToggleRow({
              title: '显示统计信息（帧率/延迟/丢帧）',
              isOn: this.settings.showStats,
              onChange: (v: boolean) => {
                this.settings.showStats = v;
                this.persist();
              }
            })
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
            ToggleRow({
              title: '鼠标模式（点按=左键，双指滑动=滚轮）',
              isOn: this.settings.mouseMode,
              onChange: (v: boolean) => {
                this.settings.mouseMode = v;
                this.persist();
              }
            })
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
            ToggleRow({
              title: '接收电脑声音（下次连接生效）',
              isOn: this.settings.audioEnabled,
              onChange: (v: boolean) => {
                this.settings.audioEnabled = v;
                this.persist();
              }
            })
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
            ToggleRow({
              title: '断线/无画面时自动重连',
              isOn: this.settings.autoReconnect,
              onChange: (v: boolean) => {
                this.settings.autoReconnect = v;
                this.persist();
              }
            })
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
            ToggleRow({
              title: '启动时自动连接上次主机',
              isOn: this.settings.autoConnect,
              onChange: (v: boolean) => {
                this.settings.autoConnect = v;
                this.persist();
              }
            })
          }
          .borderRadius(16)
          .clip(true)

          this.SectionTitle('显示模式（复制 / 扩展）')
          Column() {
            Text('本机作为副屏接入后，Windows 会新增一台虚拟显示器。使用「扩展」还是「复制」模式由电脑端决定：\n\n· 扩展屏幕（默认）：桌面延伸，手机显示独立内容\n· 复制屏幕：在电脑上按 Win + P 选择「复制」，或在 显示设置 中选中虚拟显示器后选「复制这些显示器」\n\n提示：若连接后电脑端显示已断开/黑屏，请在电脑端扩展屏服务控制台点击「Clear Windows Display Settings」后重连。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(14)
          }
          .borderRadius(16)
          .clip(true)
          .alignItems(HorizontalAlign.Start)

          this.SectionTitle('关于')
          Column() {
            Row() {
              Text('隐私政策').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text('›').fontSize(16).fontColor($r('app.color.text_hint'))
            }
            .width('100%')
            .height(48)
            .padding({ left: 14, right: 14 })
            .onClick(() => {
              this.openPrivacy();
            })
            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            Row() {
              Text('版本').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(APP_VERSION).fontSize(14).fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .height(48)
            .padding({ left: 14, right: 14 })
          }
          .borderRadius(16)
          .clip(true)

          Text('本应用不收集、不上传任何个人信息，所有设置仅保存在本机；仅通过局域网与您指定的电脑建立连接。')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 8, left: 4 })
            .width('100%')

          Blank().height(30)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  /** 提交文本输入框的值后保存 */
  private async saveInputs(): Promise<void> {
    if (!this.loaded) {
      return;
    }
    this.settings.deviceName = this.deviceName.trim().length > 0
      ? this.deviceName.trim() : this.settings.deviceName;
    await this.persist();
  }

  /** 系统返回键与「返回」按钮一致：先保存再退出 */
  onBackPress(): boolean {
    this.saveInputs();
    return false;
  }
}

/** 独立开关行组件（替代按值传参的 @Builder，保证状态同步） */
@Component
struct ToggleRow {
  title: string = '';
  @Prop isOn: boolean = false;
  onChange: (v: boolean) => void = (_v: boolean) => {
  };

  build() {
    Row() {
      Text(this.title).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor($r('app.color.primary'))
        .onChange((v: boolean) => {
          this.onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.card_background'))
  }
}
