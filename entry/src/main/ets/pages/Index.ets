import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppSettings, Device, LocalTransferFile, Transfer, TransferItem } from '../models/ApiModels';
import { ClipboardService } from '../services/ClipboardService';
import { FileSelectionService } from '../services/FileSelectionService';
import { FileDownloadService } from '../services/FileDownloadService';
import { OTransApi } from '../services/OTransApi';
import { EndpointSelector } from '../services/EndpointSelector';
import { SettingsService } from '../services/SettingsService';

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
  @Local isUploadingFiles: boolean = false;
  @Local isPairing: boolean = false;
  @Local statusText: string = '打开应用后会读取一次当前剪贴板';
  @Local fileStatusText: string = '可一次选择最多 9 张图片或文件';
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
      const text = await ClipboardService.readText(this.getContext());
      this.clipboardText = text;
      this.statusText = text.length > 0 ? '已读取当前剪贴板，请确认后上传' : '当前剪贴板没有可用文本';
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

  private async uploadText(): Promise<void> {
    if (this.clipboardText.trim().length === 0 || this.isUploading) {
      return;
    }
    this.isUploading = true;
    this.statusText = '正在上传…';
    const clientTransferId = util.generateRandomUUID();
    try {
      await this.persistSettings();
      let api = await this.resolveApi();
      try {
        await api.createTextTransfer(this.clipboardText, clientTransferId);
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        await api.createTextTransfer(this.clipboardText, clientTransferId);
      }
      this.statusText = '已上传到中转站';
      this.showToast('上传成功');
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
      this.fileStatusText = this.selectedFiles.length > 0 ?
        `已选择 ${this.selectedFiles.length} 项，确认后上传` : '尚未选择图片或文件';
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
    this.fileStatusText = next.length > 0 ? `已选择 ${next.length} 项，确认后上传` : '尚未选择图片或文件';
  }

  private async uploadFiles(): Promise<void> {
    if (this.selectedFiles.length === 0 || this.isUploadingFiles) {
      return;
    }
    this.isUploadingFiles = true;
    const clientTransferId = util.generateRandomUUID();
    try {
      await this.persistSettings();
      let api = await this.resolveApi();
      try {
        await api.createFileTransfer(this.selectedFiles, (message: string) => {
          this.fileStatusText = message;
        }, clientTransferId);
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        await api.createFileTransfer(this.selectedFiles, (message: string) => {
          this.fileStatusText = message;
        }, clientTransferId);
      }
      const count = this.selectedFiles.length;
      this.selectedFiles = [];
      this.fileStatusText = `已上传 ${count} 项到中转站`;
      this.showToast('图片和文件上传成功');
      await this.refreshTransfers(false);
    } catch (error) {
      const cause = error as Error;
      this.fileStatusText = cause.message || '文件上传失败';
      this.showToast(this.fileStatusText);
    } finally {
      this.isUploadingFiles = false;
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
      let content: ArrayBuffer;
      try {
        content = await api.downloadBlob(item);
      } catch (_) {
        this.activeServerUrl = '';
        api = await this.resolveApi(true);
        content = await api.downloadBlob(item);
      }
      FileDownloadService.write(destination, content);
      this.showToast(`${item.name || '文件'} 已保存`);
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

  build() {
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
        Button('重新读取')
          .type(ButtonType.Capsule)
          .enabled(!this.isReading)
          .onClick(() => { void this.refreshClipboard(); })
      }
      .width('100%')

      Column({ space: 12 }) {
        Row() {
          Text('当前剪贴板')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          if (this.isReading) {
            LoadingProgress().width(22).height(22).color($r('app.color.primary'))
          }
        }
        .width('100%')

        TextArea({ text: this.clipboardText, placeholder: '复制一段文字后返回 OTrans' })
          .height(170)
          .width('100%')
          .fontSize(16)
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(14)
          .padding(14)
          .onChange((value: string) => { this.clipboardText = value; })

        Text(this.statusText)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        Button(this.isUploading ? '上传中…' : '上传到中转站')
          .width('100%')
          .height(48)
          .fontSize(16)
          .enabled(!this.isUploading && this.clipboardText.trim().length > 0)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => { void this.uploadText(); })
      }
      .width('100%')
      .padding(18)
      .borderRadius(22)
      .backgroundColor($r('app.color.card_background'))

        Column({ space: 12 }) {
          Row() {
            Column({ space: 3 }) {
              Text('图片与文件')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('单文件最大 128 MiB')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            Blank()
            if (this.isSelectingFiles) {
              LoadingProgress().width(22).height(22).color($r('app.color.primary'))
            }
          }
          .width('100%')

          Row({ space: 10 }) {
            Button('选择图片')
              .layoutWeight(1)
              .enabled(!this.isSelectingFiles && this.selectedFiles.length < FileSelectionService.maxSelectedItems())
              .onClick(() => { void this.selectPhotos(); })
            Button('选择文件')
              .layoutWeight(1)
              .enabled(!this.isSelectingFiles && this.selectedFiles.length < FileSelectionService.maxSelectedItems())
              .onClick(() => { void this.selectDocuments(); })
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

          Button(this.isUploadingFiles ? '上传中…' : '上传所选内容')
            .width('100%')
            .height(48)
            .fontSize(16)
            .enabled(!this.isUploadingFiles && this.selectedFiles.length > 0)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => { void this.uploadFiles(); })
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

        Column({ space: 12 }) {
        Text('飞牛连接')
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
  }
}
