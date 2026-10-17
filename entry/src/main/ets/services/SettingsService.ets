import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppSettings } from '../models/ApiModels';

const STORE_NAME: string = 'otrans_settings';
const SERVER_URL_KEY: string = 'server_url';
const LAN_SERVER_URL_KEY: string = 'lan_server_url';
const WAN_SERVER_URL_KEY: string = 'wan_server_url';
const SERVER_ID_KEY: string = 'server_id';
const DEVICE_TOKEN_KEY: string = 'device_token';

export class SettingsService {
  static async load(context: common.UIAbilityContext): Promise<AppSettings> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    const legacyServerUrl = await store.get(SERVER_URL_KEY, '');
    const lanServerUrl = await store.get(LAN_SERVER_URL_KEY, legacyServerUrl);
    const wanServerUrl = await store.get(WAN_SERVER_URL_KEY, '');
    const serverId = await store.get(SERVER_ID_KEY, '');
    const deviceToken = await store.get(DEVICE_TOKEN_KEY, '');
    return {
      lanServerUrl: lanServerUrl as string,
      wanServerUrl: wanServerUrl as string,
      serverId: serverId as string,
      deviceToken: deviceToken as string
    };
  }

  static async save(context: common.UIAbilityContext, settings: AppSettings): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.put(LAN_SERVER_URL_KEY, settings.lanServerUrl.trim().replace(/\/+$/, ''));
    await store.put(WAN_SERVER_URL_KEY, settings.wanServerUrl.trim().replace(/\/+$/, ''));
    await store.put(SERVER_ID_KEY, settings.serverId.trim());
    await store.put(DEVICE_TOKEN_KEY, settings.deviceToken.trim());
    await store.flush();
  }
}
