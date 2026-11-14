import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DiscoveryService, SdServer } from '../common/DiscoveryService';
import { loadSettings, saveSettings, SdSettings } from '../common/SdSettings';

/** 传递给显示页的参数 */
export class DisplayParams {
  ip: string = '';
  port: number = 0;
  name: string = '';
  width: number = 1280;
  height: number = 720;
  fps: number = 30;
}

class ResPair {
  width: number = 1280;
  height: number = 720;
}

const RES_BUTTON_LABELS: string[] = ['HD 720', 'FHD 1080', '跟随屏幕'];

@Entry
@Component
struct Index {
  @State servers: SdServer[] = [];
  @State scanning: boolean = false;
  @State status: string = '未扫描';
  @State manualIp: string = '';
  @State settings: SdSettings = new SdSettings();
  @State resolutionMode: number = 0;
  @State frameRate: number = 30;

  private discovery: DiscoveryService | undefined = undefined;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  /** 首启隐私提示只弹一次（本次会话内） */
  private privacyChecked: boolean = false;

  aboutToAppear(): void {
    this.initSettings();
  }

  /** 从设置页/显示页返回时刷新，避免陈旧对象覆盖已保存的设置 */
  onPageShow(): void {
    this.reloadSettings();
  }

  aboutToDisappear(): void {
    const discovery = this.discovery;
    if (discovery !== undefined) {
      discovery.stop();
    }
  }

  private async reloadSettings(): Promise<void> {
    try {
      this.settings = await loadSettings(this.context);
      this.resolutionMode = this.settings.resolutionMode;
      this.frameRate = this.settings.fps;
    } catch (error) {
      const err = error as BusinessError;
      console.error(`reload settings failed: ${err.message}`);
      return;
    }
    if (!this.privacyChecked) {
      this.privacyChecked = true;
      if (!this.settings.privacyAgreed) {
        this.showPrivacyDialog();
      }
    }
  }

  private async initSettings(): Promise<void> {
    await this.reloadSettings();
    // 隐私提示未同意前不做自动连接
    if (!this.settings.privacyAgreed) {
      return;
    }
    // 自动连接上次主机（仅在首次进入时判定）
    if (this.settings.autoConnect && this.settings.lastIp.length > 0) {
      this.status = `自动连接 ${this.settings.lastIp} …`;
      this.connectTo(this.settings.lastIp, this.settings.lastPort, this.settings.lastName);
    }
  }

  /** 首次启动隐私合规提示（同意后不再弹出） */
  private showPrivacyDialog(): void {
    AlertDialog.show({
      title: '隐私保护提示',
      message: '欢迎使用扩展屏助手。\n\n本应用不收集、不上传您的任何个人信息，所有设置仅保存在本机。\n应用仅通过局域网与您指定的电脑建立连接，用于传输屏幕画面与输入指令，不连接任何第三方服务器。\n\n点击「同意并继续」表示您已阅读并同意《隐私政策》（可在设置页查看）。如不同意，将无法使用本应用。',
      autoCancel: false,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '同意并继续',
        action: () => {
          this.settings.privacyAgreed = true;
          saveSettings(this.context, this.settings).catch((error: BusinessError) => {
            console.error(`save privacy agree failed: ${error.message}`);
          });
        }
      },
      secondaryButton: {
        value: '不同意并退出',
        action: () => {
          this.context.terminateSelf();
        }
      }
    });
  }

  private async toggleScan(): Promise<void> {
    if (this.scanning) {
      const discovery = this.discovery;
      if (discovery !== undefined) {
        discovery.stop();
      }
      this.scanning = false;
      this.status = this.servers.length > 0 ? `发现 ${this.servers.length} 台服务器` : '未扫描';
      return;
    }
    const discovery = new DiscoveryService((list: SdServer[]) => {
      this.servers = list;
      this.status = list.length > 0 ? `发现 ${list.length} 台服务器` : '正在搜索…（确保同一局域网）';
    });
    this.discovery = discovery;
    this.scanning = true;
    this.status = '正在搜索…';
    this.servers = [];
    try {
      await discovery.start();
    } catch (error) {
      this.scanning = false;
      const err = error as BusinessError;
      this.status = '搜索失败';
      promptAction.showToast({ message: err.message.length > 0 ? err.message : 'UDP 广播不可用' });
    }
  }

  /** 按设备比例算出一个不拉伸的分辨率 */
  private resolveResolution(mode: number): ResPair {
    const pair = new ResPair();
    let screenWidth = 1280;
    let screenHeight = 720;
    try {
      const info = display.getDefaultDisplaySync();
      screenWidth = info.width;
      screenHeight = info.height;
    } catch (error) {
      console.error(`get display size failed: ${error}`);
    }
    if (mode === 2) {
      pair.width = screenWidth;
      pair.height = screenHeight;
      return pair;
    }
    const landscape = screenWidth >= screenHeight;
    const shortEdge = mode === 0 ? 720 : 1080;
    const aspect = landscape ? screenWidth / screenHeight : screenHeight / screenWidth;
    if (landscape) {
      pair.height = shortEdge;
      pair.width = Math.round(shortEdge * aspect / 2) * 2;
    } else {
      pair.width = shortEdge;
      pair.height = Math.round(shortEdge * aspect / 2) * 2;
    }
    return pair;
  }

  private async connectTo(ip: string, port: number, name: string): Promise<void> {
    const trimmed = ip.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '请输入服务器 IP' });
      return;
    }
    // 连接前强制重读最新设置，保证设置页的修改一定生效；
    // 但保留主页上刚选的分辨率/帧率（页面即时选择优先）
    const localResMode = this.resolutionMode;
    const localFps = this.frameRate;
    await this.reloadSettings();
    this.resolutionMode = localResMode;
    this.frameRate = localFps;
    const pair = this.resolveResolution(this.resolutionMode);
    // 锁定方向时让虚拟显示器方向与之一致（显示页会按设置锁定窗口方向）
    if (this.settings.orientation === 1 && pair.width < pair.height) {
      const t = pair.width;
      pair.width = pair.height;
      pair.height = t;
    } else if (this.settings.orientation === 2 && pair.width > pair.height) {
      const t = pair.width;
      pair.width = pair.height;
      pair.height = t;
    }
    this.settings.resolutionMode = this.resolutionMode;
    this.settings.fps = this.frameRate;
    this.settings.width = pair.width;
    this.settings.height = pair.height;
    this.settings.lastIp = trimmed;
    this.settings.lastPort = port > 0 ? port : 28252;
    this.settings.lastName = name;
    try {
      await saveSettings(this.context, this.settings);
    } catch (error) {
      console.error(`save settings failed: ${error}`);
    }

    const params = new DisplayParams();
    params.ip = trimmed;
    params.port = port > 0 ? port : 28252;
    params.name = name;
    params.width = pair.width;
    params.height = pair.height;
    params.fps = this.frameRate;
    try {
      await router.pushUrl({ url: 'pages/Display', params: params });
    } catch (error) {
      const err = error as BusinessError;
      console.error(`push url failed: ${err.code} ${err.message}`);
    }
  }

  /** 分段标题（与设置页一致） */
  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.primary'))
      .fontWeight(FontWeight.Medium)
      .margin({ left: 4, top: 18, bottom: 8 })
  }

  /** 首页画质选择即时落盘（避免进设置页/切页后又被 reloadSettings 覆盖） */
  private async persistQuick(): Promise<void> {
    try {
      const s = await loadSettings(this.context);
      s.resolutionMode = this.resolutionMode;
      s.fps = this.frameRate;
      const pair = this.resolveResolution(this.resolutionMode);
      s.width = pair.width;
      s.height = pair.height;
      this.settings = s;
      await saveSettings(this.context, s);
    } catch (error) {
      const err = error as BusinessError;
      console.error(`persist quick settings failed: ${err.message}`);
    }
  }

  @Builder
  serverCard(server: SdServer) {
    Row() {
      Column() {
        Text(server.displayName())
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium)
        Text(`${server.ip}:${server.port}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('连接')
        .fontSize(14)
        .height(34)
        .backgroundColor($r('app.color.primary'))
        .fontColor('#FFFFFF')
        .onClick(() => {
          this.connectTo(server.ip, server.port, server.displayName());
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_background'))
    .margin({ bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('扩展屏助手')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('无线副屏客户端')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('设置')
          .fontSize(14)
          .height(36)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' }).catch((error: BusinessError) => {
              console.error(`open settings failed: ${error.code} ${error.message}`);
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          this.SectionTitle('搜索与连接')
          Column() {
            Row() {
              Button(this.scanning ? '停止搜索' : '搜索服务器')
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .backgroundColor($r('app.color.primary'))
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.toggleScan();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 4 })

            Text(this.status)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 14, right: 14, bottom: 10 })
              .maxLines(2)

            Divider().color($r('app.color.divider')).strokeWidth(0.5)

            Row() {
              TextInput({ placeholder: '服务器 IP，例如 192.168.1.20', text: this.manualIp })
                .fontSize(14)
                .layoutWeight(1)
                .backgroundColor($r('app.color.divider'))
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_hint'))
                .onChange((value: string) => {
                  this.manualIp = value;
                })
              Button('直连')
                .fontSize(15)
                .height(40)
                .margin({ left: 10 })
                .backgroundColor($r('app.color.primary'))
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.connectTo(this.manualIp, 28252, this.manualIp);
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 12 })
          }
          .borderRadius(16)
          .clip(true)
          .backgroundColor($r('app.color.card_background'))

          if (this.servers.length === 0) {
            this.SectionTitle('发现的服务器')
            Column() {
              Text('暂无服务器')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text('1. 在 Windows 上安装兼容的扩展屏服务端并启动\n2. 两个设备连到同一局域网/热点\n3. 也可以直接在上方手动输入 IP')
                .fontSize(12)
                .fontColor($r('app.color.text_hint'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
                .lineHeight(18)
            }
            .width('100%')
            .padding({ top: 20, bottom: 20 })
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
          } else {
            this.SectionTitle('发现的服务器')
            ForEach(this.servers, (server: SdServer) => {
              this.serverCard(server);
            }, (server: SdServer) => server.key)
          }

          this.SectionTitle('画质设置')
          Column() {
            Row() {
              Text('分辨率').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(`${this.resolveResolution(this.resolutionMode).width} × ${this.resolveResolution(this.resolutionMode).height}`)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 8 })

            Row() {
              Button(RES_BUTTON_LABELS[0])
                .fontSize(13)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.resolutionMode === 0
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.resolutionMode === 0 ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.resolutionMode = 0;
                  this.persistQuick();
                })
              Blank().width(8)
              Button(RES_BUTTON_LABELS[1])
                .fontSize(13)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.resolutionMode === 1
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.resolutionMode === 1 ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.resolutionMode = 1;
                  this.persistQuick();
                })
              Blank().width(8)
              Button(RES_BUTTON_LABELS[2])
                .fontSize(13)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.resolutionMode === 2
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.resolutionMode === 2 ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.resolutionMode = 2;
                  this.persistQuick();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, bottom: 8 })

            Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })

            Row() {
              Text('帧率').fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
              Text(`${this.frameRate} fps`)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 10, bottom: 8 })

            Row() {
              Button('15')
                .fontSize(13)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.frameRate === 15
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.frameRate === 15 ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.frameRate = 15;
                  this.persistQuick();
                })
              Blank().width(8)
              Button('30')
                .fontSize(13)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.frameRate === 30
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.frameRate === 30 ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.frameRate = 30;
                  this.persistQuick();
                })
              Blank().width(8)
              Button('60')
                .fontSize(13)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.frameRate === 60
                  ? $r('app.color.primary') : $r('app.color.primary_light'))
                .fontColor(this.frameRate === 60 ? '#FFFFFF' : $r('app.color.primary'))
                .onClick(() => {
                  this.frameRate = 60;
                  this.persistQuick();
                })
            }
            .width('100%')
            .padding({ left: 14, right: 14, bottom: 12 })
          }
          .borderRadius(16)
          .clip(true)
          .backgroundColor($r('app.color.card_background'))

          Text('连接密码在点击「连接」时按当前服务器 IP 输入并保存；密码错误会自动要求重新输入，换一台电脑需重新输入。压缩方式、色彩深度、屏幕方向等更多选项在右上角「设置」页。')
            .fontSize(12)
            .fontColor($r('app.color.text_hint'))
            .lineHeight(16)
            .margin({ top: 10, left: 4 })
            .width('100%')

          Text('本应用用于个人设备间的无线副屏扩展，需在电脑端配合投屏驱动使用。')
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .margin({ top: 24, bottom: 20 })
            .width('100%')
            .textAlign(TextAlign.Center)
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
}
