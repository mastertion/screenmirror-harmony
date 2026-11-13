import { router } from '@kit.ArkUI';
import { SettingsPanel } from './Panels';

@Entry
@Component
struct SettingsPage {
  build() {
    Column() {
      Row() {
        Button('‹').fontSize(26).width(44).height(44)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => router.back())
        Text($r('app.string.menu_settings'))
          .fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }.width('100%').padding({ left: 8, right: 16, top: 8, bottom: 8 })

      SettingsPanel()
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
