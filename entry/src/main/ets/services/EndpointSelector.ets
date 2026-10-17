import { AppSettings } from '../models/ApiModels';
import { OTransApi } from './OTransApi';

class EndpointCandidate {
  route: string;
  serverUrl: string;
  timeout: number;

  constructor(route: string, serverUrl: string, timeout: number) {
    this.route = route;
    this.serverUrl = serverUrl;
    this.timeout = timeout;
  }
}

export class ResolvedEndpoint {
  route: string;
  serverUrl: string;
  serverId: string;

  constructor(route: string, serverUrl: string, serverId: string) {
    this.route = route;
    this.serverUrl = serverUrl;
    this.serverId = serverId;
  }
}

export class EndpointSelector {
  static async resolve(settings: AppSettings, authenticated: boolean = true): Promise<ResolvedEndpoint> {
    const candidates: EndpointCandidate[] = [];
    const lanUrl = EndpointSelector.normalize(settings.lanServerUrl);
    const wanUrl = EndpointSelector.normalize(settings.wanServerUrl);
    if (lanUrl.length > 0) {
      candidates.push(new EndpointCandidate('lan', lanUrl, 1600));
    }
    if (wanUrl.length > 0 && wanUrl !== lanUrl) {
      candidates.push(new EndpointCandidate('wan', wanUrl, 5000));
    }
    if (candidates.length === 0) {
      throw new Error('请至少填写一个飞牛服务地址');
    }

    const failures: string[] = [];
    for (const candidate of candidates) {
      try {
        const api = new OTransApi(candidate.serverUrl, authenticated ? settings.deviceToken : '');
        const info = await api.getServerInfo(candidate.timeout);
        if (info.serverId.length === 0) {
          throw new Error('服务端未返回 serverId，请先升级飞牛端');
        }
        if (settings.serverId.length > 0 && settings.serverId !== info.serverId) {
          throw new Error('这不是已配对的飞牛服务器');
        }
        if (authenticated) {
          await api.getDevice();
        }
        return new ResolvedEndpoint(candidate.route, candidate.serverUrl, info.serverId);
      } catch (error) {
        const cause = error as Error;
        const routeName = candidate.route === 'lan' ? '内网' : '外网';
        failures.push(`${routeName}：${cause.message || '连接失败'}`);
      }
    }
    throw new Error(`内外网均无法连接（${failures.join('；')}）`);
  }

  private static normalize(value: string): string {
    return value.trim().replace(/\/+$/, '');
  }
}
