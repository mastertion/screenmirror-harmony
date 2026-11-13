/** 可复用的中文设置 / 关于 / 使用说明面板（供首页 Tab 与独立页面共用） */
import { promptAction } from '@kit.ArkUI';
import { settings } from '../model/SettingsModel';
import { s } from '../common/Res';

// 下标与 Compression 枚举 ordinal 严格对齐（0..5）
const ENCODING_LABELS: string[] = ['不压缩', 'YUV 原始', '保留', 'MJPEG（兼容性最好）', 'H.264（流畅、低带宽）', '自动选择'];
const FPS_LABELS: string[] = ['15 帧/秒', '30 帧/秒', '60 帧/秒'];
const FPS_VALUES: number[] = [15, 30, 60];
const DEPTH_LABELS: string[] = ['16 位', '24 位', '32 位'];
const CONNECT_LABELS: string[] = ['不自动连接', '上次连接的主机', '指定 IP 地址', '指定主机名'];
const TOUCH_LABELS: string[] = ['鼠标模式', '触摸模式'];

function toOptions(labels: string[]): SelectOption[] {
  const out: SelectOption[] = [];
  for (const l of labels) {
    out.push({ value: l });
  }
  return out;
}

@Component
export struct SettingsPanel {
  @State quality: number = 60;
  @State encodingIndex: number = 5;
  @State fpsIndex: number = 1;
  @State depthIndex: number = 2;
  @State connectIndex: number = 0;
  @State touchIndex: number = 0;
  @State autoRotation: boolean = false;
  @State showFps: boolean = false;
  @State audio: boolean = true;
  @State displayMenu: boolean = true;
  @State touchEnable: boolean = true;
  @State stylusEnable: boolean = true;
  @State autoConnectIp: string = '';
  @State autoConnectHost: string = '';
  @State connectTimeout: string = '20000';
  @State showResolution: boolean = false;
  @State resWidth: string = '1920';
  @State resHeight: string = '1080';
  @State autoReconnect: boolean = true;
  @State landscape: boolean = true;
  @State showStats: boolean = true;
  @State audioVolume: number = 100;
  @State pointerIndex: number = 0;
  @State deviceName: string = 'HarmonyOS Phone';
  @State pingPeriod: string = '5000';

  aboutToAppear(): void {
    this.quality = settings.getQuality();
    this.fpsIndex = this.indexOfValue(FPS_VALUES, settings.getFps(), 1);
    this.encodingIndex = settings.getCompression();
    this.depthIndex = settings.getColorDepth() >= 4 ? 2 : settings.getColorDepth() >= 2 ? 1 : 0;
    this.autoConnectIp = settings.getAutoConnectIp();
    this.connectTimeout = String(settings.getConnectTimeout());
    this.resWidth = String(settings.getNumber('harmony_resolution_width', 1920));
    this.resHeight = String(settings.getNumber('harmony_resolution_height', 1080));
    this.autoRotation = settings.getBool('key_autorotation', false);
    this.showFps = settings.getBool('fps_view_enable', false);
    this.audio = settings.getBool('key_audio', true);
    this.displayMenu = settings.getBool('key_display_menu', true);
    this.touchEnable = settings.getBool('key_ktm_mouse', true);
    this.stylusEnable = settings.getBool('key_ktm_stylus', true);
    this.touchIndex = settings.getNumber('key_ktm_touch_type', 0);
    this.connectIndex = settings.getNumber('key_auto_connect_type', 0);
    this.autoConnectHost = settings.getString('key_auto_connect_hostname', '');
    this.autoReconnect = settings.getBool('harmony_auto_reconnect', true);
    this.landscape = settings.getBool('harmony_landscape', true);
    this.showStats = settings.getBool('harmony_show_stats', true);
    this.audioVolume = settings.getNumber('harmony_audio_volume', 100);
    this.pointerIndex = settings.getNumber('harmony_pointer_mode', 0);
    this.deviceName = settings.getString('harmony_device_name', 'HarmonyOS Phone');
    this.pingPeriod = String(settings.getNumber('harmony_ping_period', 5000));
  }

  private indexOfValue(values: number[], target: number, def: number): number {
    for (let i: number = 0; i < values.length; i++) {
      if (values[i] === target) {
        return i;
      }
    }
    return def;
  }

  @Builder
  SectionTitle(title: ResourceStr) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.primary'))
      .fontWeight(FontWeight.Medium)
      .margin({ left: 4, top: 18, bottom: 8 })
  }

  @Builder
  SwitchRow(title: ResourceStr, summary: ResourceStr, value: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title).fontSize(15).fontColor($r('app.color.text_primary'))
        Text(summary).fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 3 })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor($r('app.color.primary'))
        .onChange((v: boolean) => onChange(v))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.card_background'))
  }

  @Builder
  SelectRow(title: string, labels: string[], index: number, onChange: (i: number) => void) {
    Row() {
      Text(title).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
      Select(toOptions(labels))
        .selected(index)
        .value(labels[index])
        .font({ size: 14 })
        .fontColor($r('app.color.text_secondary'))
        .onSelect((i: number) => onChange(i))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.card_background'))
  }

  @Builder
  InputRow(title: ResourceStr, value: string, onChange: (v: string) => void) {
    Row() {
      Text(title).fontSize(15).fontColor($r('app.color.text_primary')).width(110)
      TextInput({ text: value })
        .fontSize(14)
        .layoutWeight(1)
        .backgroundColor('#FFF5F7FA')
        .onChange((v: string) => onChange(v))
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.card_background'))
  }

  build() {
    Scroll() {
      Column() {
        this.SectionTitle($r('app.string.sec_resolution'))
        Column() {
          Row() {
            Column() {
              Text($r('app.string.pref_custom_resolution'))
                .fontSize(15).fontColor($r('app.color.text_primary'))
              Text(`${this.resWidth} × ${this.resHeight}`)
                .fontSize(12).fontColor($r('app.color.text_secondary')).margin({ top: 3 })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button($r('app.string.btn_apply'))
              .fontSize(13).height(32)
              .backgroundColor($r('app.color.primary_light'))
              .fontColor($r('app.color.primary'))
              .onClick(() => this.showResolution = true)
          }
          .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor($r('app.color.card_background'))
        }.borderRadius(16).clip(true)

        this.SectionTitle($r('app.string.sec_rotation'))
        Column() {
          this.SwitchRow($r('app.string.pref_auto_rotation'),
            $r('app.string.pref_auto_rotation_sum'), this.autoRotation, (v: boolean) => {
              this.autoRotation = v;
              settings.putBool('key_autorotation', v);
            })
        }.borderRadius(16).clip(true)

        this.SectionTitle($r('app.string.sec_quality'))
        Column() {
          Row() {
            Text($r('app.string.pref_image_quality')).fontSize(15).width(90)
            Slider({ value: this.quality, min: 10, max: 100, step: 1 })
              .layoutWeight(1).selectedColor($r('app.color.primary'))
              .onChange((v: number) => {
                this.quality = v;
                settings.putNumber('key_compression_quality', Math.round(v));
              })
            Text(`${Math.round(this.quality)}`).fontSize(13).width(34).textAlign(TextAlign.End)
          }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor($r('app.color.card_background'))

          this.SelectRow(s($r('app.string.pref_encoding_type')), ENCODING_LABELS,
            this.encodingIndex, (i: number) => {
              this.encodingIndex = i;
              settings.putNumber('key_compression_type_string', i);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SelectRow(s($r('app.string.pref_fps')), FPS_LABELS,
            this.fpsIndex, (i: number) => {
              this.fpsIndex = i;
              settings.putNumber('key_fps', FPS_VALUES[i]);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SelectRow(s($r('app.string.pref_color_depth')), DEPTH_LABELS,
            this.depthIndex, (i: number) => {
              this.depthIndex = i;
              settings.putNumber('key_bmp_cnf', i);
              settings.putNumber('key_color_depth', i === 0 ? 2 : i === 1 ? 4 : 6);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SwitchRow($r('app.string.pref_show_fps'),
            $r('app.string.pref_show_fps_sum'), this.showFps, (v: boolean) => {
              this.showFps = v;
              settings.putBool('fps_view_enable', v);
            })
        }.borderRadius(16).clip(true)

        this.SectionTitle($r('app.string.sec_connection'))
        Column() {
          this.SelectRow(s($r('app.string.pref_auto_connect')), CONNECT_LABELS,
            this.connectIndex, (i: number) => {
              this.connectIndex = i;
              settings.putNumber('key_auto_connect_type', i);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.InputRow($r('app.string.pref_auto_connect_ip'), this.autoConnectIp, (v: string) => {
            this.autoConnectIp = v;
            settings.putString('key_auto_connect_ip', v);
          })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.InputRow($r('app.string.pref_auto_connect_host'), this.autoConnectHost, (v: string) => {
            this.autoConnectHost = v;
            settings.putString('key_auto_connect_hostname', v);
          })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.InputRow($r('app.string.pref_timeout_connection'), this.connectTimeout, (v: string) => {
            this.connectTimeout = v;
            const n: number = Number.parseInt(v, 10);
            if (!Number.isNaN(n) && n > 0) {
              settings.putNumber('key_con_watcher_timeout_delta', n);
            }
          })
        }.borderRadius(16).clip(true)

        this.SectionTitle($r('app.string.sec_audio'))
        Column() {
          this.SwitchRow($r('app.string.pref_audio'),
            $r('app.string.pref_audio_sum'), this.audio, (v: boolean) => {
              this.audio = v;
              settings.putBool('key_audio', v);
            })
        }.borderRadius(16).clip(true)

        this.SectionTitle($r('app.string.sec_menu'))
        Column() {
          this.SwitchRow($r('app.string.pref_display_menu'),
            $r('app.string.pref_display_menu_sum'), this.displayMenu, (v: boolean) => {
              this.displayMenu = v;
              settings.putBool('key_display_menu', v);
            })
        }.borderRadius(16).clip(true)

        this.SectionTitle($r('app.string.sec_input'))
        Column() {
          this.SwitchRow($r('app.string.pref_touch_enable'),
            $r('app.string.pref_touch_enable_sum'), this.touchEnable, (v: boolean) => {
              this.touchEnable = v;
              settings.putBool('key_ktm_mouse', v);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SelectRow(s($r('app.string.pref_touch_type')), TOUCH_LABELS,
            this.touchIndex, (i: number) => {
              this.touchIndex = i;
              settings.putNumber('key_ktm_touch_type', i);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SwitchRow($r('app.string.pref_stylus_enable'),
            $r('app.string.pref_stylus_enable_sum'), this.stylusEnable, (v: boolean) => {
              this.stylusEnable = v;
              settings.putBool('key_ktm_stylus', v);
            })
        }.borderRadius(16).clip(true)

        this.SectionTitle('连接稳定性与体验')
        Column() {
          this.SwitchRow('断线自动重连', '最多自动尝试 3 次，间隔递增', this.autoReconnect, (v: boolean) => {
            this.autoReconnect = v;
            settings.putBool('harmony_auto_reconnect', v);
          })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SwitchRow('投屏时强制横屏', '进入投屏页自动切换为横屏', this.landscape, (v: boolean) => {
            this.landscape = v;
            settings.putBool('harmony_landscape', v);
          })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SwitchRow('显示帧率与码率', '顶部叠加实时统计', this.showStats, (v: boolean) => {
            this.showStats = v;
            settings.putBool('harmony_show_stats', v);
          })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.InputRow('心跳间隔（毫秒）', this.pingPeriod, (v: string) => {
            this.pingPeriod = v;
            const n: number = Number.parseInt(v, 10);
            if (!Number.isNaN(n) && n >= 1000) {
              settings.putNumber('harmony_ping_period', n);
            }
          })
        }.borderRadius(16).clip(true)

        this.SectionTitle('音频与输入')
        Column() {
          Row() {
            Text('音频音量').fontSize(15).width(90)
            Slider({ value: this.audioVolume, min: 0, max: 100, step: 1 })
              .layoutWeight(1).selectedColor($r('app.color.primary'))
              .onChange((v: number) => {
                this.audioVolume = v;
                settings.putNumber('harmony_audio_volume', Math.round(v));
              })
            Text(`${Math.round(this.audioVolume)}`).fontSize(13).width(34).textAlign(TextAlign.End)
          }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor($r('app.color.card_background'))
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.SelectRow('默认指针模式', ['鼠标模式', '触摸模式'],
            this.pointerIndex, (i: number) => {
              this.pointerIndex = i;
              settings.putNumber('harmony_pointer_mode', i);
            })
          Divider().color($r('app.color.divider')).strokeWidth(0.5).margin({ left: 14 })
          this.InputRow('本机显示名称', this.deviceName, (v: string) => {
            this.deviceName = v;
            settings.putString('harmony_device_name', v);
          })
        }.borderRadius(16).clip(true)

        this.SectionTitle('投屏页手势')
        Column() {
          Text('单指点击 / 拖动：鼠标或触摸事件回传主机')
            .fontSize(13).fontColor($r('app.color.text_primary')).lineHeight(22).width('100%')
          Text('双指捏合：放大或缩小远程画面（1×–5×）')
            .fontSize(13).fontColor($r('app.color.text_primary')).lineHeight(22).width('100%').margin({ top: 6 })
          Text('双指拖动：平移画面；悬浮菜单里可一键复位')
            .fontSize(13).fontColor($r('app.color.text_primary')).lineHeight(22).width('100%').margin({ top: 6 })
          Text('悬浮菜单：左右键、滚轮、全键软键盘、旋转、分辨率、冻结画面')
            .fontSize(13).fontColor($r('app.color.text_primary')).lineHeight(22).width('100%').margin({ top: 6 })
        }
        .width('100%').padding(14)
        .backgroundColor($r('app.color.card_background')).borderRadius(16)
        .alignItems(HorizontalAlign.Start)

        Text('设置项与原 APK 的 key_* 保持一致，便于对照迁移')
          .fontSize(12).fontColor($r('app.color.text_hint'))
          .margin({ top: 20, bottom: 24 })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    .height('100%')
    .bindSheet(this.showResolution, this.ResolutionSheet(), {
      height: 300,
      dragBar: true,
      title: { title: $r('app.string.pref_custom_resolution') }
    })
  }

  @Builder
  ResolutionSheet() {
    Column() {
      Row() {
        TextInput({ text: this.resWidth })
          .layoutWeight(1).type(InputType.Number)
          .onChange((v: string) => this.resWidth = v)
        Text('×').fontSize(18).margin({ left: 10, right: 10 })
        TextInput({ text: this.resHeight })
          .layoutWeight(1).type(InputType.Number)
          .onChange((v: string) => this.resHeight = v)
      }.width('100%').padding(16)

      Button($r('app.string.btn_apply'))
        .width('90%')
        .backgroundColor($r('app.color.primary'))
        .onClick(() => {
          const w: number = Number.parseInt(this.resWidth, 10);
          const h: number = Number.parseInt(this.resHeight, 10);
          if (Number.isNaN(w) || Number.isNaN(h)) {
            promptAction.showToast({ message: s($r('app.string.err_non_numeric')) });
            return;
          }
          if (w % 2 !== 0 || h % 2 !== 0) {
            promptAction.showToast({ message: s($r('app.string.err_multiple_of_2')) });
            return;
          }
          settings.putNumber('harmony_resolution_width', w);
          settings.putNumber('harmony_resolution_height', h);
          this.showResolution = false;
          promptAction.showToast({ message: `${w} × ${h}` });
        })
    }.padding({ top: 8, bottom: 24 })
  }
}

@Component
export struct AboutPanel {
  build() {
    Scroll() {
      Column() {
        Image($r('app.media.icon')).width(88).height(88).margin({ top: 28 })
        Text($r('app.string.app_name'))
          .fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).margin({ top: 16 })
        Text(s($r('app.string.about_version')).replace('%s', '1.0.0'))
          .fontSize(13).fontColor($r('app.color.text_secondary')).margin({ top: 6 })
        Text($r('app.string.about_based_on'))
          .fontSize(12).fontColor($r('app.color.text_hint')).margin({ top: 4 })

        Column() {
          Text($r('app.string.about_intro'))
            .fontSize(14).fontColor($r('app.color.text_primary')).lineHeight(22)
          Text($r('app.string.about_protocol'))
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .lineHeight(21).margin({ top: 12 })
        }
        .width('100%').padding(16).margin({ top: 24 })
        .backgroundColor($r('app.color.card_background')).borderRadius(16)
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text($r('app.string.about_disclaimer_title'))
            .fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.warning'))
          Text($r('app.string.about_disclaimer'))
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .lineHeight(21).margin({ top: 8 })
        }
        .width('100%').padding(16).margin({ top: 16 })
        .backgroundColor($r('app.color.card_background')).borderRadius(16)
        .alignItems(HorizontalAlign.Start)

        Text($r('app.string.err_free_only'))
          .fontSize(12).fontColor($r('app.color.text_hint'))
          .margin({ top: 24, bottom: 28 })
      }.width('100%').padding({ left: 16, right: 16 })
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
}

@Component
export struct ManualPanel {
  build() {
    Scroll() {
      Column() {
        ForEach([
          s($r('app.string.manual_step1')),
          s($r('app.string.manual_step2')),
          s($r('app.string.manual_step3')),
          s($r('app.string.manual_step4')),
          s($r('app.string.manual_step5'))
        ], (step: string) => {
          Text(step)
            .fontSize(15).fontColor($r('app.color.text_primary')).lineHeight(24)
            .width('100%').padding(14).margin({ top: 10 })
            .backgroundColor($r('app.color.card_background')).borderRadius(12)
        }, (step: string) => step)
      }.width('100%').padding(16)
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
}
