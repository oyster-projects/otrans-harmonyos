import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  AppSettings,
  BlobDownloadResult,
  Device,
  LocalTransferFile,
  Transfer,
  TransferInputContent,
  TransferItem
} from '../models/ApiModels';
import { ClipboardService } from '../services/ClipboardService';
import { FileSelectionService } from '../services/FileSelectionService';
import { FileDownloadService } from '../services/FileDownloadService';
import { OTransApi } from '../services/OTransApi';
import { EndpointSelector } from '../services/EndpointSelector';
import { SettingsService } from '../services/SettingsService';
import { TransferInputService } from '../services/TransferInputService';

@Entry
@ComponentV2
struct Index {
  @Local clipboardText: string = '';
  @Local lanServerUrl: string = '';
  @Local wanServerUrl: string = '';
  @Local serverId: string = '';
  @Local activeServerUrl: string = '';
  @Local routeStatusText: string = '尚未选择连接线路';
  @Local deviceToken: string = '';
  @Local pairCode: string = '';
  @Local deviceName: string = 'HarmonyOS 手机';
  @Local isReading: boolean = false;
  @Local isUploading: boolean = false;
  @Local isSelectingFiles: boolean = false;
  @Local isDropActive: boolean = false;
  @Local isLoadingDrop: boolean = false;
  @Local isPairing: boolean = false;
  @Local isSettingsOpen: boolean = false;
  @Local statusText: string = '可读取剪贴板，或从系统中转站拖入内容';
  @Local fileStatusText: string = '文本、图片与文件可以组成一条中转记录';
  @Local selectedFiles: LocalTransferFile[] = [];
  @Local transfers: Transfer[] = [];
  @Local currentDeviceId: string = '';
  @Local isRefreshingTransfers: boolean = false;
  @Local activeDownloadId: string = '';
  @Local deletingTransferId: string = '';
  private isInitialized: boolean = false;
  private netConnection: connection.NetConnection = connection.createNetConnection();
  private networkAvailableCallback = (_handle: connection.NetHandle): void => {
    void this.handleNetworkChanged();
  };
  private networkLostCallback = (_handle: connection.NetHandle): void => {
    this.activeServerUrl = '';
    this.routeStatusText = '网络已变化，正在重新选择线路…';
  };
  private networkUnavailableCallback = (): void => {
    this.activeServerUrl = '';
    this.routeStatusText = '当前网络不可用';
  };

  aboutToAppear(): void {
    this.netConnection.on('netAvailable', this.networkAvailableCallback);
    this.netConnection.on('netLost', this.networkLostCallback);
    this.netConnection.on('netUnavailable', this.networkUnavailableCallback);
    this.netConnection.register((error: BusinessError): void => {
      if (error) {
        this.routeStatusText = error.message || '网络状态监听启动失败';
      }
    });
    void this.initialize();
  }

  aboutToDisappear(): void {
    this.netConnection.unregister((_error: BusinessError): void => {});
  }

  onPageShow(): void {
    if (this.isInitialized && this.deviceToken.length > 0) {
      this.activeServerUrl = '';
      void this.refreshTransfers(false);
    }
  }

  private getContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private currentSettings(): AppSettings {
    return {
      lanServerUrl: this.lanServerUrl,
      wanServerUrl: this.wanServerUrl,
      serverId: this.serverId,
      deviceToken: this.deviceToken
    };
  }

  private async persistSettings(): Promise<void> {
    await SettingsService.save(this.getContext(), this.currentSettings());
  }

  private async resolveApi(force: boolean = false): Promise<OTransApi> {
    if (!force && this.activeServerUrl.length > 0) {
      return new OTransApi(this.activeServerUrl, this.deviceToken);
    }
    const endpoint = await EndpointSelector.resolve(this.currentSettings(), true);
    this.activeServerUrl = endpoint.serverUrl;
    this.serverId = endpoint.serverId;
    this.routeStatusText = endpoint.route === 'lan' ? '当前使用内网连接' : '当前使用外网连接';
    await this.persistSettings();
    return new OTransApi(endpoint.serverUrl, this.deviceToken);
  }

  private async handleNetworkChanged(): Promise<void> {
    this.activeServerUrl = '';
    if (!this.isInitialized || this.deviceToken.length === 0) {
      return;
    }
    try {
      await this.resolveApi(true);
      await this.refreshTransfers(false);
    } catch (error) {
      const cause = error as Error;
      this.routeStatusText = cause.message || '网络线路选择失败';
    }
  }

  private async initialize(): Promise<void> {
    try {
      const settings = await SettingsService.load(this.getContext());
      this.lanServerUrl = settings.lanServerUrl;
      this.wanServerUrl = settings.wanServerUrl;
      this.serverId = settings.serverId;
      this.deviceToken = settings.deviceToken;
    } catch (error) {
      const cause = error as Error;
      this.statusText = cause.message || '读取连接信息失败';
    }
    await this.refreshClipboard();
    this.isInitialized = true;
    if ((this.lanServerUrl.length > 0 || this.wanServerUrl.length > 0) && this.deviceToken.length > 0) {
      await this.refreshTransfers(false);
    }
  }

  private async refreshClipboard(): Promise<void> {
    if (this.isReading) {
      return;
    }
    this.isReading = true;
    try {
      const content = await ClipboardService.readContent(this.getContext());
      const count = this.mergeInputContent(content, true);
      this.statusText = count > 0 ? `已从剪贴板加入 ${count} 项，请确认后发送` : '当前剪贴板没有支持的内容';
    } catch (error) {
      const cause = error as BusinessError;
      this.statusText = cause.message || '读取剪贴板失败';
    } finally {
      this.isReading = false;
    }
  }

  private async saveSettings(): Promise<void> {
    try {
      this.activeServerUrl = '';
      await this.persistSettings();
      this.showToast('连接信息已保存');
    } catch (error) {
      const cause = error as Error;
      this.showToast(cause.message || '保存失败');
    }
  }

  private draftItemCount(): number {
    return this.selectedFiles.length + (this.clipboardText.trim().length > 0 ? 1 : 0);
  }

  private mergeInputContent(content: TransferInputContent, replaceText: boolean = false): number {
    const available = FileSelectionService.maxSelectedItems() - this.selectedFiles.length;
    const knownUris = new Set<string>(this.selectedFiles.map((file: LocalTransferFile) => file.uri));
    const incomingFiles = content.files.filter((file: LocalTransferFile) => !knownUris.has(file.uri)).slice(0, available);
    this.selectedFiles = this.selectedFiles.concat(incomingFiles);
    const incomingText = content.texts.map((value: string) => value.trim())
      .filter((value: string) => value.length > 0).join('\n\n');
    if (incomingText.length > 0) {
      if (replaceText || this.clipboardText.trim().length === 0) {
        this.clipboardText = incomingText;
      } else if (this.clipboardText.trim() !== incomingText) {
        this.clipboardText = `${this.clipboardText.trim()}\n\n${incomingText}`;
      }
    } else if (replaceText) {
      this.clipboardText = '';
    }
    const added = incomingFiles.length + (incomingText.length > 0 ? 1 : 0);
    const skipped = content.unsupportedCount + Math.max(0, content.files.length - incomingFiles.length);
    this.fileStatusText = skipped > 0 ? `已加入 ${added} 项，另有 ${skipped} 项不支持或超过数量限制` :
      `待发送 ${this.draftItemCount()} 项`;
    return added;
  }

  private async uploadDraft(): Promise<void> {
    if (this.draftItemCount() === 0 || this.isUploading) {
      return;
    }
    this.isUploading = true;
    this.statusText = '正在发送待发送内容…';
    const clientTransferId = util.generateRandomUUID();
    try {
      await this.persistSettings();
      let api = await this.resolveApi();
      try {
        await api.createMixedTransfer(this.clipboardText, this.selectedFiles, (message: string) => {
          this.fileStatusText = message;
        }, clientTransferId);
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        await api.createMixedTransfer(this.clipboardText, this.selectedFiles, (message: string) => {
          this.fileStatusText = message;
        }, clientTransferId);
      }
      const count = this.draftItemCount();
      this.clipboardText = '';
      this.selectedFiles = [];
      this.statusText = `已发送 ${count} 项到中转站`;
      this.fileStatusText = '文本、图片与文件可以组成一条中转记录';
      this.showToast('待发送内容已上传');
      await this.refreshTransfers(false);
    } catch (error) {
      const cause = error as Error;
      this.statusText = cause.message || '上传失败';
      this.showToast(this.statusText);
    } finally {
      this.isUploading = false;
    }
  }

  private async selectPhotos(): Promise<void> {
    await this.selectTransferFiles(true);
  }

  private async selectDocuments(): Promise<void> {
    await this.selectTransferFiles(false);
  }

  private async selectTransferFiles(isImage: boolean): Promise<void> {
    if (this.isSelectingFiles || this.selectedFiles.length >= FileSelectionService.maxSelectedItems()) {
      return;
    }
    this.isSelectingFiles = true;
    try {
      const remaining = FileSelectionService.maxSelectedItems() - this.selectedFiles.length;
      const selected = isImage ?
        await FileSelectionService.selectPhotos(this.getContext(), remaining) :
        await FileSelectionService.selectFiles(this.getContext(), remaining);
      const knownUris = new Set<string>(this.selectedFiles.map((file: LocalTransferFile) => file.uri));
      const appended = selected.filter((file: LocalTransferFile) => !knownUris.has(file.uri));
      this.selectedFiles = this.selectedFiles.concat(appended).slice(0, FileSelectionService.maxSelectedItems());
      this.fileStatusText = this.draftItemCount() > 0 ? `待发送 ${this.draftItemCount()} 项` :
        '文本、图片与文件可以组成一条中转记录';
    } catch (error) {
      const cause = error as BusinessError;
      this.fileStatusText = cause.message || '选择文件失败';
      this.showToast(this.fileStatusText);
    } finally {
      this.isSelectingFiles = false;
    }
  }

  private removeSelectedFile(index: number): void {
    const next = this.selectedFiles.slice();
    next.splice(index, 1);
    this.selectedFiles = next;
    this.fileStatusText = this.draftItemCount() > 0 ? `待发送 ${this.draftItemCount()} 项` :
      '文本、图片与文件可以组成一条中转记录';
  }

  private handleDrop(event: DragEvent): void {
    this.isDropActive = false;
    this.isLoadingDrop = true;
    this.fileStatusText = '正在接收拖入内容…';
    try {
      const data = event.getData();
      event.setResult(DragResult.DRAG_SUCCESSFUL);
      void this.acceptDroppedData(data);
    } catch (error) {
      const cause = error as BusinessError;
      this.isLoadingDrop = false;
      this.fileStatusText = cause.message || '拖入内容读取失败';
      event.setResult(DragResult.DRAG_FAILED);
      this.showToast(this.fileStatusText);
    }
  }

  private async acceptDroppedData(data: unifiedDataChannel.UnifiedData): Promise<void> {
    try {
      // 拖拽源授予的 URI 访问权限可能只在本次拖拽期间有效，立即复制到应用缓存。
      const content = await TransferInputService.parse(this.getContext(), data, true);
      const count = this.mergeInputContent(content);
      this.showToast(count > 0 ? `已加入 ${count} 项拖入内容` : '拖入内容中没有支持的文本或文件');
    } catch (error) {
      const cause = error as Error;
      this.fileStatusText = cause.message || '拖入内容读取失败';
      this.showToast(this.fileStatusText);
    } finally {
      this.isLoadingDrop = false;
    }
  }

  private async refreshTransfers(showFeedback: boolean = true): Promise<void> {
    if (this.isRefreshingTransfers || (this.lanServerUrl.length === 0 && this.wanServerUrl.length === 0) ||
      this.deviceToken.length === 0) {
      return;
    }
    this.isRefreshingTransfers = true;
    try {
      let api = await this.resolveApi();
      let device: Device;
      let records: Transfer[];
      try {
        device = await api.getDevice();
        records = await api.listTransfers();
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        device = await api.getDevice();
        records = await api.listTransfers();
      }
      this.currentDeviceId = device.id;
      this.transfers = records.filter((record: Transfer) => record.deletedAt === undefined);
      if (showFeedback) {
        this.showToast(`已拉取 ${this.transfers.length} 条中转记录`);
      }
    } catch (error) {
      const cause = error as Error;
      if (showFeedback) {
        this.showToast(cause.message || '拉取中转记录失败');
      }
    } finally {
      this.isRefreshingTransfers = false;
    }
  }

  private async copyReceivedText(text: string): Promise<void> {
    try {
      await ClipboardService.writeText(text);
      this.showToast('文本已复制到剪贴板');
    } catch (error) {
      const cause = error as Error;
      this.showToast(cause.message || '复制失败');
    }
  }

  private async saveReceivedFile(item: TransferItem): Promise<void> {
    if (!item.id || this.activeDownloadId.length > 0) {
      return;
    }
    this.activeDownloadId = item.id;
    try {
      const destination = await FileDownloadService.chooseDestination(this.getContext(), item);
      if (destination.length === 0) {
        return;
      }
      let api = await this.resolveApi();
      let download: BlobDownloadResult;
      try {
        download = await api.downloadBlobPreferLan(item);
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        download = await api.downloadBlobPreferLan(item);
      }
      FileDownloadService.write(destination, download.content);
      if (download.route === 'lan') {
        this.showToast(`${item.name || '文件'} 已从 ${download.sourceName || '局域网设备'} 直传保存`);
      } else {
        this.showToast(`${item.name || '文件'} 已从飞牛保存`);
      }
    } catch (error) {
      const cause = error as BusinessError;
      if (cause.code !== 13900042) {
        this.showToast(cause.message || '保存文件失败');
      }
    } finally {
      this.activeDownloadId = '';
    }
  }

  private async deleteTransferRecord(transfer: Transfer): Promise<void> {
    if (this.deletingTransferId.length > 0) {
      return;
    }
    this.deletingTransferId = transfer.id;
    try {
      let api = await this.resolveApi();
      try {
        await api.deleteTransfer(transfer.id);
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        await api.deleteTransfer(transfer.id);
      }
      this.transfers = this.transfers.filter((record: Transfer) => record.id !== transfer.id);
      this.showToast('已全局删除，其他电脑下次同步时会一并删除');
    } catch (error) {
      const cause = error as Error;
      this.showToast(cause.message || '删除失败');
    } finally {
      this.deletingTransferId = '';
    }
  }

  private async confirmDelete(transfer: Transfer): Promise<void> {
    const result = await this.getUIContext().getPromptAction().showDialog({
      title: '全局删除',
      message: '删除后，飞牛中的记录和其他客户端管理的副本都会在同步时删除。确定继续吗？',
      buttons: [
        { text: '取消', color: '#68718A' },
        { text: '删除', color: '#E84040' }
      ]
    });
    if (result.index === 1) {
      await this.deleteTransferRecord(transfer);
    }
  }

  private sourceLabel(transfer: Transfer): string {
    return transfer.sourceDeviceId === this.currentDeviceId ? '来自本机' : '来自其他设备';
  }

  private transferTime(transfer: Transfer): string {
    const value = transfer.committedAt || transfer.createdAt;
    return value.replace('T', ' ').replace('Z', '').substring(0, 19);
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KiB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
  }

  private async pairDevice(): Promise<void> {
    if (this.isPairing) {
      return;
    }
    this.isPairing = true;
    try {
      const pairingSettings: AppSettings = {
        lanServerUrl: this.lanServerUrl,
        wanServerUrl: this.wanServerUrl,
        serverId: '',
        deviceToken: ''
      };
      const endpoint = await EndpointSelector.resolve(pairingSettings, false);
      const api = new OTransApi(endpoint.serverUrl, '');
      const paired = await api.pair(this.pairCode, this.deviceName);
      this.deviceToken = paired.token;
      this.serverId = endpoint.serverId;
      this.activeServerUrl = endpoint.serverUrl;
      this.routeStatusText = endpoint.route === 'lan' ? '当前使用内网连接' : '当前使用外网连接';
      await this.persistSettings();
      this.pairCode = '';
      this.statusText = `已配对：${paired.device.name}`;
      this.isSettingsOpen = false;
      this.showToast('配对成功');
      await this.refreshTransfers(false);
    } catch (error) {
      const cause = error as Error;
      this.showToast(cause.message || '配对失败');
    } finally {
      this.isPairing = false;
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (_) {
      // Toast 只是辅助反馈，不应该打断上传或保存流程。
    }
  }

  @Builder
  private settingsPage() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Button('返回')
          .type(ButtonType.Capsule)
          .onClick(() => { this.isSettingsOpen = false; })
        Column({ space: 2 }) {
          Text('设置')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('飞牛连接与设备配对')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 14 })
      .backgroundColor($r('app.color.card_background'))

      Scroll() {
        Column({ space: 12 }) {
          Text('连接地址')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(this.routeStatusText)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          TextInput({ text: this.lanServerUrl, placeholder: '内网地址：http://192.168.1.10:18990' })
            .width('100%')
            .onChange((value: string) => {
              this.lanServerUrl = value;
              this.activeServerUrl = '';
            })
          TextInput({ text: this.wanServerUrl, placeholder: '外网地址（可选）：https://你的域名' })
            .width('100%')
            .onChange((value: string) => {
              this.wanServerUrl = value;
              this.activeServerUrl = '';
            })
          TextInput({ text: this.deviceName, placeholder: '设备名称' })
            .width('100%')
            .onChange((value: string) => { this.deviceName = value; })

          Divider().margin({ top: 4, bottom: 4 })

          Text('设备配对')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          TextInput({ text: this.pairCode, placeholder: '10 分钟内有效的配对码' })
            .width('100%')
            .onChange((value: string) => { this.pairCode = value; })
          Button(this.isPairing ? '配对中…' : '使用配对码连接')
            .width('100%')
            .enabled(!this.isPairing && this.pairCode.trim().length > 0)
            .onClick(() => { void this.pairDevice(); })
          TextInput({ text: this.deviceToken, placeholder: '设备令牌' })
            .type(InputType.Password)
            .width('100%')
            .onChange((value: string) => { this.deviceToken = value; })
          Button('保存连接信息')
            .width('100%')
            .onClick(() => { void this.saveSettings(); })

          Text('令牌只保存在本机；内网可用时优先走内网，失败后自动切换外网。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('100%')
        .padding(18)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .zIndex(10)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 18 }) {
      Row() {
        Column({ space: 4 }) {
          Text('OTrans')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text('自己的 NAS，就是跨设备中转站')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Button('设置')
          .type(ButtonType.Capsule)
          .onClick(() => { this.isSettingsOpen = true; })
      }
      .width('100%')

        Column({ space: 12 }) {
          Row() {
            Column({ space: 3 }) {
              Text('待发送内容')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('从系统中转站拖到这里，支持文本、图片和多文件混合')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            if (this.isSelectingFiles || this.isLoadingDrop || this.isReading) {
              LoadingProgress().width(22).height(22).color($r('app.color.primary'))
            }
          }
          .width('100%')

          Column({ space: 7 }) {
            Text(this.isDropActive ? '松手即可加入待发送内容' : '拖入文本、照片、视频或文件')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isDropActive ? $r('app.color.primary') : $r('app.color.text_primary'))
            Text('拖入后不会立即上传，可以继续添加并确认')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(92)
          .borderRadius(14)
          .border({
            width: this.isDropActive ? 2 : 1,
            color: this.isDropActive ? $r('app.color.primary') : $r('app.color.text_secondary'),
            style: BorderStyle.Dashed
          })
          .backgroundColor($r('app.color.page_background'))
          .allowDrop([
            uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
            uniformTypeDescriptor.UniformDataType.HTML,
            uniformTypeDescriptor.UniformDataType.HYPERLINK,
            uniformTypeDescriptor.UniformDataType.FILE_URI,
            uniformTypeDescriptor.UniformDataType.FILE,
            uniformTypeDescriptor.UniformDataType.IMAGE,
            uniformTypeDescriptor.UniformDataType.VIDEO,
            uniformTypeDescriptor.UniformDataType.AUDIO,
            uniformTypeDescriptor.UniformDataType.OPENHARMONY_PIXEL_MAP
          ])
          .onDragEnter((event: DragEvent) => {
            this.isDropActive = true;
            this.fileStatusText = '已识别拖入内容，松手即可加入';
            event.setResult(DragResult.DROP_ENABLED);
          })
          .onDragMove((event: DragEvent) => {
            this.isDropActive = true;
            event.setResult(DragResult.DROP_ENABLED);
          })
          .onDragLeave((event: DragEvent) => {
            this.isDropActive = false;
            this.fileStatusText = this.draftItemCount() > 0 ? `待发送 ${this.draftItemCount()} 项` :
              '文本、图片与文件可以组成一条中转记录';
            event.setResult(DragResult.DROP_ENABLED);
          })
          .onDrop((event: DragEvent) => { this.handleDrop(event); })

          TextArea({ text: this.clipboardText, placeholder: '输入文本，或点击“读取剪贴板”' })
            .height(130)
            .width('100%')
            .fontSize(16)
            .backgroundColor($r('app.color.page_background'))
            .borderRadius(14)
            .padding(14)
            .onChange((value: string) => {
              this.clipboardText = value;
              this.fileStatusText = this.draftItemCount() > 0 ? `待发送 ${this.draftItemCount()} 项` :
                '文本、图片与文件可以组成一条中转记录';
            })

          Row({ space: 10 }) {
            Button('读取剪贴板')
              .layoutWeight(1)
              .enabled(!this.isReading)
              .onClick(() => { void this.refreshClipboard(); })
            Button('选择图片')
              .layoutWeight(1)
              .enabled(!this.isSelectingFiles && this.selectedFiles.length < FileSelectionService.maxSelectedItems())
              .onClick(() => { void this.selectPhotos(); })
          }
          .width('100%')

          Row({ space: 10 }) {
            Button('选择文件')
              .layoutWeight(1)
              .enabled(!this.isSelectingFiles && this.selectedFiles.length < FileSelectionService.maxSelectedItems())
              .onClick(() => { void this.selectDocuments(); })
            Button('清空')
              .layoutWeight(1)
              .enabled(this.draftItemCount() > 0 && !this.isUploading)
              .onClick(() => {
                this.clipboardText = '';
                this.selectedFiles = [];
                this.fileStatusText = '文本、图片与文件可以组成一条中转记录';
              })
          }
          .width('100%')

          if (this.selectedFiles.length > 0) {
            Column({ space: 8 }) {
              ForEach(this.selectedFiles, (file: LocalTransferFile, index: number) => {
                Row({ space: 10 }) {
                  Text(file.isImage ? '图片' : '文件')
                    .fontSize(12)
                    .fontColor($r('app.color.primary'))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(8)
                    .backgroundColor($r('app.color.page_background'))
                  Column({ space: 2 }) {
                    Text(file.name)
                      .fontSize(14)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.formatBytes(file.size))
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Button('移除')
                    .fontSize(12)
                    .height(32)
                    .onClick(() => { this.removeSelectedFile(index); })
                }
                .width('100%')
                .padding(10)
                .borderRadius(12)
                .backgroundColor($r('app.color.page_background'))
              }, (file: LocalTransferFile) => file.uri)
            }
            .width('100%')
          }

          Text(this.fileStatusText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Text(this.statusText)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Button(this.isUploading ? '发送中…' : `发送全部内容（${this.draftItemCount()} 项）`)
            .width('100%')
            .height(48)
            .fontSize(16)
            .enabled(!this.isUploading && this.draftItemCount() > 0)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => { void this.uploadDraft(); })
        }
        .width('100%')
        .padding(18)
        .borderRadius(22)
        .backgroundColor($r('app.color.card_background'))

        Column({ space: 12 }) {
          Row() {
            Column({ space: 3 }) {
              Text('中转站记录')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('进入应用时只拉取列表，文件由你点击后保存')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            Button(this.isRefreshingTransfers ? '拉取中…' : '刷新')
              .height(36)
              .enabled(!this.isRefreshingTransfers && this.deviceToken.length > 0)
              .onClick(() => { void this.refreshTransfers(); })
          }
          .width('100%')

          if (this.transfers.length === 0) {
            Text(this.deviceToken.length > 0 ? '暂时没有中转记录' : '配对后即可查看其他设备发送的内容')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 18, bottom: 18 })
          } else {
            Column({ space: 10 }) {
              ForEach(this.transfers, (transfer: Transfer) => {
                Column({ space: 9 }) {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(transfer.title || '未命名中转内容')
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(2)
                      Text(`${this.sourceLabel(transfer)} · ${this.transferTime(transfer)}`)
                        .fontSize(11)
                        .fontColor($r('app.color.text_secondary'))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Button(this.deletingTransferId === transfer.id ? '删除中…' : '删除')
                      .height(32)
                      .fontSize(12)
                      .enabled(this.deletingTransferId.length === 0)
                      .fontColor(Color.Red)
                      .onClick(() => { void this.confirmDelete(transfer); })
                  }
                  .width('100%')

                  ForEach(transfer.items, (item: TransferItem) => {
                    if (item.kind === 'text') {
                      Column({ space: 7 }) {
                        Text(item.text || '')
                          .fontSize(14)
                          .fontColor($r('app.color.text_primary'))
                          .maxLines(4)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                        Button('复制文本')
                          .height(34)
                          .width('100%')
                          .onClick(() => { void this.copyReceivedText(item.text || ''); })
                      }
                      .width('100%')
                      .padding(10)
                      .borderRadius(10)
                      .backgroundColor($r('app.color.page_background'))
                    } else if (item.kind === 'file') {
                      Row({ space: 8 }) {
                        Column({ space: 2 }) {
                          Text(item.name || '未命名文件')
                            .fontSize(14)
                            .fontColor($r('app.color.text_primary'))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          Text(this.formatBytes(item.size || 0))
                            .fontSize(11)
                            .fontColor($r('app.color.text_secondary'))
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                        Button(this.activeDownloadId === item.id ? '保存中…' : '保存')
                          .height(34)
                          .fontSize(12)
                          .enabled(this.activeDownloadId.length === 0)
                          .onClick(() => { void this.saveReceivedFile(item); })
                      }
                      .width('100%')
                      .padding(10)
                      .borderRadius(10)
                      .backgroundColor($r('app.color.page_background'))
                    }
                  }, (item: TransferItem) => item.id)
                }
                .width('100%')
                .padding(12)
                .borderRadius(14)
                .backgroundColor($r('app.color.page_background'))
              }, (transfer: Transfer) => transfer.id)
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(18)
        .borderRadius(22)
        .backgroundColor($r('app.color.card_background'))

          Blank().height(8)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 24, bottom: 18 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))

      if (this.isSettingsOpen) {
        this.settingsPage()
      }
    }
    .width('100%')
    .height('100%')
  }
}
