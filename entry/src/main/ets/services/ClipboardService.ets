import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { TransferInputContent } from '../models/ApiModels';
import { TransferInputService } from './TransferInputService';

type ClipboardPermission = 'ohos.permission.READ_PASTEBOARD';

interface PermissionResult {
  authResults: abilityAccessCtrl.GrantStatus[];
}

const READ_PASTEBOARD: ClipboardPermission = 'ohos.permission.READ_PASTEBOARD';

export class ClipboardService {
  static async writeText(text: string): Promise<void> {
    const board = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await board.setData(data);
  }

  static async readText(context: common.UIAbilityContext): Promise<string> {
    const granted = await ClipboardService.ensurePermission(context);
    if (!granted) {
      throw new Error('未获得剪贴板读取权限');
    }
    const board = pasteboard.getSystemPasteboard();
    const data = await board.getData();
    if (!data.hasType(pasteboard.MIMETYPE_TEXT_PLAIN) &&
      !data.hasType(pasteboard.MIMETYPE_TEXT_HTML) &&
      !data.hasType(pasteboard.MIMETYPE_TEXT_URI)) {
      return '';
    }
    return data.getPrimaryText();
  }

  static async readContent(context: common.UIAbilityContext): Promise<TransferInputContent> {
    const granted = await ClipboardService.ensurePermission(context);
    if (!granted) {
      throw new Error('未获得剪贴板读取权限');
    }
    const data = await pasteboard.getSystemPasteboard().getUnifiedData();
    return TransferInputService.parse(context, data, true);
  }

  private static async ensurePermission(context: common.UIAbilityContext): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
    );
    const status = manager.checkAccessTokenSync(bundleInfo.appInfo.accessTokenId, READ_PASTEBOARD);
    if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return true;
    }
    const result = await (manager.requestPermissionsFromUser(context, [READ_PASTEBOARD]) as Promise<PermissionResult>);
    return result.authResults.length > 0 &&
      result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }
}
