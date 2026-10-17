import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { TransferItem } from '../models/ApiModels';

export class FileDownloadService {
  static async chooseDestination(context: common.UIAbilityContext, item: TransferItem): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.save({
      newFileNames: [FileDownloadService.safeFileName(item.name || '未命名文件')]
    });
    return uris.length > 0 ? uris[0] : '';
  }

  static write(uri: string, content: ArrayBuffer): void {
    const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const written = fs.writeSync(file.fd, content);
      if (written !== content.byteLength) {
        throw new Error('保存文件时写入不完整');
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
  }

  private static safeFileName(name: string): string {
    let safe = name.trim().replace(/[\\\/:*?"<>|\u0000]/g, '_').replace(/[. ]+$/g, '');
    if (safe.length === 0) {
      safe = '未命名文件';
    }
    return safe.length > 200 ? safe.substring(0, 200) : safe;
  }
}
