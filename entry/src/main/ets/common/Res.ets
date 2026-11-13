/** 把 $r() 资源对象同步解析成字符串，供需要真实字符串值的 API 使用 */
import { common } from '@kit.AbilityKit';

export function s(res: Resource): string {
  try {
    const ctx: common.UIAbilityContext = getContext() as common.UIAbilityContext;
    return ctx.resourceManager.getStringSync(res.id);
  } catch (e) {
    return '';
  }
}
