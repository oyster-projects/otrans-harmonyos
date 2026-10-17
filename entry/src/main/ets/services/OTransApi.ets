import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  BlobDownloadResult,
  CreateTransferResponse,
  Device,
  ErrorResponse,
  LocalTransferFile,
  PairResponse,
  PeerSourcesResponse,
  PreparedTransferFile,
  ServerInfo,
  Transfer,
  TransferItem,
  TransferListResponse
} from '../models/ApiModels';

interface TransferItemRequest {
  kind: string;
  text?: string;
  name?: string;
  mimeType: string;
  size?: number;
  sha256?: string;
}

interface CreateTransferRequest {
  clientTransferId: string;
  title: string;
  items: TransferItemRequest[];
}

interface PairRequest {
  code: string;
  name: string;
  platform: string;
}

export class OTransApi {
  private serverUrl: string;
  private token: string;

  constructor(serverUrl: string, token: string) {
    this.serverUrl = serverUrl.trim().replace(/\/+$/, '');
    this.token = token.trim();
  }

  async pair(code: string, deviceName: string): Promise<PairResponse> {
    this.ensureServerUrl();
    const body: PairRequest = {
      code: code.trim(),
      name: deviceName.trim(),
      platform: 'harmonyos'
    };
    if (body.code.length === 0 || body.name.length === 0) {
      throw new Error('请填写配对码和设备名称');
    }
    return this.request<PairResponse>('/api/v1/pair', http.RequestMethod.POST, JSON.stringify(body), false);
  }

  async getServerInfo(connectTimeout: number = 3000): Promise<ServerInfo> {
    this.ensureServerUrl();
    return this.request<ServerInfo>('/api/v1/server-info', http.RequestMethod.GET, undefined, false, connectTimeout);
  }

  async createTextTransfer(text: string, clientTransferId: string = util.generateRandomUUID()): Promise<Transfer> {
    return this.createMixedTransfer(text, [], (_message: string): void => {}, clientTransferId);
  }

  async getDevice(): Promise<Device> {
    return this.request<Device>('/api/v1/devices/me', http.RequestMethod.GET);
  }

  async listTransfers(): Promise<Transfer[]> {
    const response = await this.request<TransferListResponse>('/api/v1/transfers?limit=100', http.RequestMethod.GET);
    return response.transfers;
  }

  async deleteTransfer(transferId: string): Promise<void> {
    await this.requestNoContent(`/api/v1/transfers/${transferId}`, http.RequestMethod.DELETE);
  }

  async downloadBlob(item: TransferItem): Promise<ArrayBuffer> {
    if (!item.sha256 || !item.name || item.size === undefined) {
      throw new Error('文件记录不完整');
    }
    const request = http.createHttp();
    try {
      const response = await request.request(
        this.serverUrl + `/api/v1/blobs/${item.sha256}?name=${encodeURIComponent(item.name)}`,
        {
          method: http.RequestMethod.GET,
          header: { 'Authorization': `Bearer ${this.token}` },
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 10000,
          readTimeout: 180000
        }
      );
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`下载失败，服务返回 ${response.responseCode}`);
      }
      const content = response.result as ArrayBuffer;
      await this.validateBlob(content, item);
      return content;
    } finally {
      request.destroy();
    }
  }

  async downloadBlobPreferLan(item: TransferItem): Promise<BlobDownloadResult> {
    if (!item.sha256 || !item.name || item.size === undefined) {
      throw new Error('文件记录不完整');
    }
    try {
      const peers = await this.request<PeerSourcesResponse>(
        `/api/v1/lan/sources/${encodeURIComponent(item.sha256)}`, http.RequestMethod.GET
      );
      for (const source of peers.sources) {
        for (const address of source.addresses) {
          try {
            const url = address.replace(/\/+$/, '') +
              `/v1/blobs/${encodeURIComponent(item.sha256)}?ticket=${encodeURIComponent(source.ticket)}`;
            const content = await this.downloadPeerBlob(url, item);
            return { content: content, route: 'lan', sourceName: source.deviceName };
          } catch (_) {
            // 地址可能因休眠、换网或防火墙失效，继续尝试并最终回退飞牛。
          }
        }
      }
    } catch (_) {
      // 兼容尚未提供局域网发现接口的旧服务端。
    }
    return { content: await this.downloadBlob(item), route: 'nas' };
  }

  private async downloadPeerBlob(url: string, item: TransferItem): Promise<ArrayBuffer> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 1800,
        readTimeout: 180000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`局域网设备返回 ${response.responseCode}`);
      }
      const content = response.result as ArrayBuffer;
      await this.validateBlob(content, item);
      return content;
    } finally {
      request.destroy();
    }
  }

  private async validateBlob(content: ArrayBuffer, item: TransferItem): Promise<void> {
    if (!item.sha256 || !item.name || item.size === undefined) {
      throw new Error('文件记录不完整');
    }
    if (content.byteLength !== item.size) {
      throw new Error(`${item.name} 文件大小校验失败`);
    }
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new Uint8Array(content) });
    const digest = this.toHex((await md.digest()).data);
    if (digest !== item.sha256.toLowerCase()) {
      throw new Error(`${item.name} 完整性校验失败`);
    }
  }

  async createFileTransfer(files: LocalTransferFile[], onProgress: (message: string) => void,
    clientTransferId: string = util.generateRandomUUID()): Promise<Transfer> {
    return this.createMixedTransfer('', files, onProgress, clientTransferId);
  }

  async createMixedTransfer(text: string, files: LocalTransferFile[], onProgress: (message: string) => void,
    clientTransferId: string = util.generateRandomUUID()): Promise<Transfer> {
    this.ensureServerUrl();
    if (this.token.length === 0) {
      throw new Error('请先填写设备令牌');
    }
    const normalizedText = text.trim();
    if (files.length === 0 && normalizedText.length === 0) {
      throw new Error('请先添加文本、图片或文件');
    }
    if (files.length + (normalizedText.length > 0 ? 1 : 0) > 64) {
      throw new Error('一条中转记录最多包含 64 项');
    }

    const prepared: PreparedTransferFile[] = [];
    for (let index = 0; index < files.length; index++) {
      const source = files[index];
      onProgress(`正在校验 ${index + 1}/${files.length}：${source.name}`);
      prepared.push({
        uri: source.uri,
        name: source.name,
        mimeType: source.mimeType,
        size: source.size,
        isImage: source.isImage,
        sha256: await this.sha256File(source.uri, source.size)
      });
    }

    const items: TransferItemRequest[] = [];
    if (normalizedText.length > 0) {
      items.push({ kind: 'text', text: normalizedText, mimeType: 'text/plain' });
    }
    for (const file of prepared) {
      const item: TransferItemRequest = {
        kind: 'file',
        name: file.name,
        mimeType: file.mimeType,
        size: file.size,
        sha256: file.sha256
      };
      items.push(item);
    }
    let title: string;
    if (prepared.length === 0) {
      title = '来自 HarmonyOS 的文本';
    } else if (normalizedText.length > 0) {
      title = `来自 HarmonyOS：文本和 ${prepared.length} 个文件`;
    } else {
      title = prepared.length === 1 ? `来自 HarmonyOS：${prepared[0].name}` :
        `来自 HarmonyOS 的 ${prepared.length} 个文件`;
    }
    const createBody: CreateTransferRequest = {
      clientTransferId: clientTransferId,
      title: title,
      items: items
    };

    let created: CreateTransferResponse;
    try {
      created = await this.request<CreateTransferResponse>(
        '/api/v1/transfers', http.RequestMethod.POST, JSON.stringify(createBody)
      );
    } catch (error) {
      const cause = error as Error;
      throw new Error(`创建中转记录失败：${cause.message}`);
    }

    try {
      const uploadedDigests = new Set<string>();
      for (let index = 0; index < prepared.length; index++) {
        const file = prepared[index];
        if (created.missingBlobs.indexOf(file.sha256) < 0 || uploadedDigests.has(file.sha256)) {
          continue;
        }
        onProgress(`正在上传 ${index + 1}/${prepared.length}：${file.name}`);
        await this.uploadBlob(file);
        uploadedDigests.add(file.sha256);
      }
      onProgress('正在提交中转记录…');
      return await this.request<Transfer>(
        `/api/v1/transfers/${created.transfer.id}/commit`, http.RequestMethod.POST
      );
    } catch (error) {
      const cause = error as Error;
      throw new Error(`提交中转内容失败：${cause.message}`);
    }
  }

  private async sha256File(uri: string, size: number): Promise<string> {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const md = cryptoFramework.createMd('SHA256');
    const chunkSize: number = 1024 * 1024;
    let offset: number = 0;
    try {
      while (offset < size) {
        const length = Math.min(chunkSize, size - offset);
        const buffer = new ArrayBuffer(length);
        const read = fs.readSync(file.fd, buffer, { offset: offset, length: length });
        if (read <= 0) {
          throw new Error('读取文件时意外结束');
        }
        await md.update({ data: new Uint8Array(buffer, 0, read) });
        offset += read;
      }
      const result = await md.digest();
      return this.toHex(result.data);
    } finally {
      fs.closeSync(file);
    }
  }

  private async uploadBlob(fileInfo: PreparedTransferFile): Promise<void> {
    const content = this.readWholeFile(fileInfo.uri, fileInfo.size);
    const request = http.createHttp();
    try {
      const response = await request.request(this.serverUrl + `/api/v1/blobs/${fileInfo.sha256}`, {
        method: http.RequestMethod.PUT,
        header: {
          'Authorization': `Bearer ${this.token}`,
          'Content-Type': fileInfo.mimeType
        },
        extraData: content,
        connectTimeout: 10000,
        readTimeout: 180000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const raw = response.result as string;
        const failure = JSON.parse(raw) as ErrorResponse;
        throw new Error(failure.error || `服务返回 ${response.responseCode}`);
      }
    } finally {
      request.destroy();
    }
  }

  private readWholeFile(uri: string, size: number): ArrayBuffer {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const buffer = new ArrayBuffer(size);
    const target = new Uint8Array(buffer);
    const chunkSize: number = 1024 * 1024;
    let offset: number = 0;
    try {
      while (offset < size) {
        const length = Math.min(chunkSize, size - offset);
        const chunk = new ArrayBuffer(length);
        const read = fs.readSync(file.fd, chunk, { offset: offset, length: length });
        if (read <= 0) {
          throw new Error('读取文件时意外结束');
        }
        target.set(new Uint8Array(chunk, 0, read), offset);
        offset += read;
      }
      return buffer;
    } finally {
      fs.closeSync(file);
    }
  }

  private toHex(bytes: Uint8Array): string {
    let result: string = '';
    for (let index = 0; index < bytes.length; index++) {
      result += bytes[index].toString(16).padStart(2, '0');
    }
    return result;
  }

  private ensureServerUrl(): void {
    if (!this.serverUrl.startsWith('http://') && !this.serverUrl.startsWith('https://')) {
      throw new Error('服务地址必须以 http:// 或 https:// 开头');
    }
  }

  private async request<T>(path: string, method: http.RequestMethod, body?: string,
    authenticated: boolean = true, connectTimeout: number = 10000): Promise<T> {
    const request = http.createHttp();
    try {
      const authorization = authenticated ? `Bearer ${this.token}` : '';
      const response = body === undefined ?
        await request.request(this.serverUrl + path, {
          method: method,
          header: {
            'Authorization': authorization
          },
          connectTimeout: connectTimeout,
          readTimeout: 30000
        }) :
        await request.request(this.serverUrl + path, {
          method: method,
          header: {
            'Authorization': authorization,
            'Content-Type': 'application/json'
          },
          extraData: body,
          connectTimeout: connectTimeout,
          readTimeout: 30000
        });
      const raw = response.result as string;
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const failure = JSON.parse(raw) as ErrorResponse;
        throw new Error(failure.error || `服务返回 ${response.responseCode}`);
      }
      return JSON.parse(raw) as T;
    } finally {
      request.destroy();
    }
  }

  private async requestNoContent(path: string, method: http.RequestMethod): Promise<void> {
    const request = http.createHttp();
    try {
      const response = await request.request(this.serverUrl + path, {
        method: method,
        header: { 'Authorization': `Bearer ${this.token}` },
        connectTimeout: 10000,
        readTimeout: 30000
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const raw = response.result as string;
        const failure = JSON.parse(raw) as ErrorResponse;
        throw new Error(failure.error || `服务返回 ${response.responseCode}`);
      }
    } finally {
      request.destroy();
    }
  }
}
