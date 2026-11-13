import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { settings } from '../model/SettingsModel';
import { ServerItem, createServerItem } from '../model/ServerInfo';
import { discoveryService } from '../service/DiscoveryService';
import { connectionService } from '../service/ConnectionService';
import { isIpV4, NET_PORT } from '../common/Protocol';
import { s } from '../common/Res';
import { SettingsPanel, AboutPanel } from './Panels';

// 半模态弹层状态机：同一节点只允许绑定一个 bindSheet，多个会互相冲突（后绑吞先绑）
const SHEET_NONE: number = 0;
const SHEET_ADD_IP: number = 1;
const SHEET_PASSWORD: number = 2;
const SHEET_FIRST_RUN: number = 3;

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State servers: ServerItem[] = [];
  @State status: string = '';
  @State discovering: boolean = false;
  @State activeSheet: number = SHEET_NONE;
  @State ipInput: string = '';
  private pendingFirstRun: boolean = false;
  passwordInput: string = '';
  pendingServer: ServerItem | undefined = undefined;

  aboutToAppear(): void {
    this.loadRecent();
    this.startDiscovery();
    if (!settings.getBool('harmony_first_run_shown', false)) {
      this.pendingFirstRun = true;
      settings.putBool('harmony_first_run_shown', true);
    }
  }

  aboutToDisappear(): void {
    discoveryService.stop();
  }

  /** 页面真正挂载完成后再拉起首启引导，避免宿主未挂载时 sheet 不出现 */
  onPageShow(): void {
    if (this.pendingFirstRun) {
      this.pendingFirstRun = false;
      this.activeSheet = SHEET_FIRST_RUN;
    }
  }

  private loadRecent(): void {
    const raw: string = settings.getString('harmony_recent_ips', '');
    if (raw.length === 0) {
      return;
    }
    const parts: string[] = raw.split(',');
    const loaded: ServerItem[] = [];
    for (const ip of parts) {
      if (isIpV4(ip)) {
        loaded.push(createServerItem(ip, ip, NET_PORT, 'Windows', false, false, true));
      }
    }
    this.servers = loaded;
  }

  private saveRecent(): void {
    const ips: string[] = [];
    for (const item of this.servers) {
      if (item.manual && !ips.includes(item.ip)) {
        ips.push(item.ip);
      }
    }
    settings.putString('harmony_recent_ips', ips.join(','));
  }

  private startDiscovery(): void {
    const knownIps: string[] = [];
    for (const item of this.servers) {
      if (item.manual) {
        knownIps.push(item.ip);
      }
    }
    this.discovering = true;
    this.status = s($r('app.string.status_discovering'));
    discoveryService.start(
      (found: ServerItem): void => {
        this.upsert(found);
      },
      (msg: string): void => {
        this.status = msg;
      },
      knownIps
    ).then((): void => {
      this.status = s($r('app.string.status_found')).replace('%d', String(this.servers.length));
    });
  }

  private upsert(found: ServerItem): void {
    let hit: boolean = false;
    const next: ServerItem[] = [];
    for (const item of this.servers) {
      if (item.ip === found.ip) {
        next.push(found);
        hit = true;
      } else {
        next.push(item);
      }
    }
    if (!hit) {
      next.push(found);
    }
    this.servers = next;
    this.status = s($r('app.string.status_found')).replace('%d', String(this.servers.length));
  }

  private addManual(): void {
    const ip: string = this.ipInput.trim();
    if (!isIpV4(ip)) {
      promptAction.showToast({ message: s($r('app.string.err_invalid_ip')) });
      return;
    }
    this.upsert(createServerItem(ip, ip, NET_PORT, 'Windows', false, false, true));
    this.saveRecent();
    this.activeSheet = SHEET_NONE;
    this.ipInput = '';
    // 对刚添加的地址做单播探测
    discoveryService.start(
      (found: ServerItem): void => this.upsert(found),
      (msg: string): void => { this.status = msg; },
      [ip]
    );
  }

  private openDisplay(server: ServerItem): void {
    if (server.passwordRequired) {
      this.pendingServer = server;
      this.activeSheet = SHEET_PASSWORD;
      return;
    }
    this.doOpenDisplay(server, '');
  }

  private doOpenDisplay(server: ServerItem, password: string): void {
    discoveryService.stop();
    router.pushUrl({
      url: 'pages/DisplayPage',
      params: {
        host: server.ip,
        port: server.port,
        name: server.name,
        encrypted: server.encrypted,
        password: password
      }
    }).catch((e: BusinessError): void => {
      promptAction.showToast({ message: e.message });
    });
  }

  private disconnectIfAny(): void {
    connectionService.disconnect();
  }

  @Builder
  TabItem(index: number, label: ResourceStr, icon: string) {
    Column() {
      Text(icon).fontSize(20).fontColor(this.currentTab === index ? $r('app.color.primary') : $r('app.color.text_hint'))
      Text(label).fontSize(11)
        .fontColor(this.currentTab === index ? $r('app.color.primary') : $r('app.color.text_hint'))
        .margin({ top: 2 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  ServerCard(item: ServerItem) {
    Row() {
      Column() {
        Text('🖥').fontSize(26)
      }.width(46).height(46).borderRadius(12)
        .backgroundColor($r('app.color.primary_light'))
        .justifyContent(FlexAlign.Center)

      Column() {
        Text(item.name).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${item.ip}:${item.port}  ·  ${item.osLabel}`)
          .fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 4 })
        Row() {
          if (item.encrypted) {
            Text('🔒 加密').fontSize(11).fontColor($r('app.color.primary'))
          }
          Text(item.manual ? '手动添加' : '局域网发现')
            .fontSize(11).fontColor($r('app.color.text_hint'))
        }.margin({ top: 4 })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 12 })

      Button($r('app.string.btn_connect'))
        .fontSize(13).height(34)
        .backgroundColor($r('app.color.primary'))
        .onClick(() => this.openDisplay(item))
    }
    .width('100%').padding(14).margin({ top: 10 })
    .backgroundColor($r('app.color.card_background')).borderRadius(16)
  }

  @Builder
  ConnectView() {
    Column() {
      // 状态条
      Row() {
        if (this.discovering) {
          LoadingProgress().width(18).height(18).color($r('app.color.primary'))
        }
        Text(this.status.length > 0 ? this.status : s($r('app.string.status_idle')))
          .fontSize(13).fontColor($r('app.color.text_secondary')).margin({ left: this.discovering ? 8 : 0 })
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      if (this.servers.length === 0) {
        Column() {
          Text('📡').fontSize(52).margin({ bottom: 12 })
          Text($r('app.string.hint_no_server'))
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text($r('app.string.hint_manual_ip'))
            .fontSize(13).fontColor($r('app.color.text_secondary')).margin({ top: 8 })
          Text($r('app.string.hint_tap_to_connect'))
            .fontSize(12).fontColor($r('app.color.text_hint')).margin({ top: 20 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.servers, (item: ServerItem) => {
            ListItem() {
              this.ServerCard(item)
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.DeleteButton(item)
                }
              }
            })
          }, (item: ServerItem) => item.ip)
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off)
        .padding({ left: 16, right: 16 })
      }

      Row() {
        Button($r('app.string.btn_add_ip'))
          .layoutWeight(1).height(44).fontSize(15)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.activeSheet = SHEET_ADD_IP)
        Button($r('app.string.btn_refresh'))
          .layoutWeight(1).height(44).fontSize(15)
          .backgroundColor($r('app.color.primary_light'))
          .fontColor($r('app.color.primary'))
          .margin({ left: 12 })
          .onClick(() => this.startDiscovery())
      }.width('100%').padding(16)
    }.width('100%').height('100%')
  }

  @Builder
  DeleteButton(item: ServerItem) {
    Button($r('app.string.btn_delete'))
      .fontSize(13).height(48)
      .backgroundColor($r('app.color.danger'))
      .onClick(() => {
        this.servers = this.servers.filter((s: ServerItem): boolean => s.ip !== item.ip);
        this.saveRecent();
      })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.app_name'))
            .fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text($r('app.string.connect_subtitle'))
            .fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 3 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Button() {
          Text('⋯').fontSize(22).fontColor($r('app.color.text_primary'))
        }
        .width(40).height(40).backgroundColor(Color.Transparent)
        .bindMenu([
          { value: s($r('app.string.menu_user_manual')), action: (): void => { router.pushUrl({ url: 'pages/ManualPage' }); } },
          { value: s($r('app.string.menu_settings')), action: (): void => { router.pushUrl({ url: 'pages/SettingsPage' }); } },
          { value: s($r('app.string.menu_about')), action: (): void => { router.pushUrl({ url: 'pages/AboutPage' }); } },
          { value: s($r('app.string.btn_disconnect')), action: (): void => { this.disconnectIfAny(); } }
        ])
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() { this.ConnectView() }
          .tabBar(this.TabItem(0, $r('app.string.tab_connect'), '🔌'))
        TabContent() { SettingsPanel() }
          .tabBar(this.TabItem(1, $r('app.string.tab_settings'), '⚙️'))
        TabContent() { AboutPanel() }
          .tabBar(this.TabItem(2, $r('app.string.tab_about'), 'ℹ️'))
      }
      .width('100%').layoutWeight(1)
      .scrollable(false)
      .barHeight(62)
      .onChange((index: number): void => { this.currentTab = index; })
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet(this.activeSheet !== SHEET_NONE, this.ActiveSheet(), {
      height: this.sheetHeight(),
      dragBar: true,
      title: { title: this.sheetTitle() },
      onDisappear: (): void => { this.activeSheet = SHEET_NONE; }
    })
  }

  private sheetTitle(): ResourceStr {
    if (this.activeSheet === SHEET_PASSWORD) {
      return $r('app.string.dlg_password_title');
    }
    if (this.activeSheet === SHEET_FIRST_RUN) {
      return $r('app.string.dlg_info_title');
    }
    return $r('app.string.dlg_add_ip_title');
  }

  private sheetHeight(): number {
    if (this.activeSheet === SHEET_PASSWORD) {
      return 260;
    }
    if (this.activeSheet === SHEET_FIRST_RUN) {
      return 300;
    }
    return 280;
  }

  @Builder
  ActiveSheet() {
    if (this.activeSheet === SHEET_ADD_IP) {
      this.AddSheet()
    } else if (this.activeSheet === SHEET_PASSWORD) {
      this.PasswordSheet()
    } else if (this.activeSheet === SHEET_FIRST_RUN) {
      this.FirstRunSheet()
    }
  }

  @Builder
  AddSheet() {
    Column() {
      Text($r('app.string.dlg_add_ip_text'))
        .fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ placeholder: '192.168.1.10', text: this.ipInput })
        .maxLength(15)
        // InputType.Number 会拦截小数点，改用普通键盘 + 白名单过滤（仅数字与点）
        .inputFilter('[0-9.]')
        .fontSize(16).height(46).margin({ top: 12 })
        .onChange((v: string): void => { this.ipInput = v; })
      Button($r('app.string.btn_add'))
        .width('100%').height(44).margin({ top: 18 })
        .backgroundColor($r('app.color.primary'))
        .onClick(() => this.addManual())
    }.padding(20)
  }

  @Builder
  PasswordSheet() {
    Column() {
      Text(s($r('app.string.dlg_password_text')).replace('%s', this.pendingServer?.name ?? ''))
        .fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ placeholder: s($r('app.string.label_password')) })
        .type(InputType.Password).fontSize(16).height(46).margin({ top: 12 })
        .onChange((v: string): void => { this.passwordInput = v; })
      Button($r('app.string.btn_connect'))
        .width('100%').height(44).margin({ top: 18 })
        .backgroundColor($r('app.color.primary'))
        .onClick(() => {
          if (this.pendingServer !== undefined) {
            this.doOpenDisplay(this.pendingServer, this.passwordInput);
          }
          this.activeSheet = SHEET_NONE;
        })
    }.padding(20)
  }

  @Builder
  FirstRunSheet() {
    Column() {
      Text($r('app.string.hint_first_run'))
        .fontSize(15).lineHeight(24).fontColor($r('app.color.text_primary'))
      Button($r('app.string.dlg_info_btn'))
        .width('100%').height(44).margin({ top: 20 })
        .backgroundColor($r('app.color.primary'))
        .onClick(() => this.activeSheet = SHEET_NONE)
    }.padding(20)
  }
}
