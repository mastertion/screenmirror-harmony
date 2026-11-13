import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { settings } from '../model/SettingsModel';
import { discoveryService } from '../service/DiscoveryService';
import { connectionService } from '../service/ConnectionService';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 设置仓库是异步初始化，页面首次读取时有默认值兜底
    settings.init(this.context).catch((e: BusinessError): void => {
      console.error(`设置初始化失败: ${e.message}`);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError): void => {
      if (err.code) {
        console.error(`加载首页失败: ${JSON.stringify(err)}`);
      }
    });
  }

  onWindowStageDestroy(): void {
    discoveryService.stop();
    connectionService.disconnect();
  }

  onForeground(): void {
    // 回到前台时由页面自行决定是否恢复发现
  }

  onBackground(): void {
    discoveryService.stop();
  }
}
