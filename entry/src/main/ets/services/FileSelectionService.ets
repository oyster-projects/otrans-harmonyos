import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { LocalTransferFile } from '../models/ApiModels';

const MAX_SELECTED_ITEMS: number = 9;
const MAX_FILE_BYTES: number = 128 * 1024 * 1024;

export class FileSelectionService {
  static async selectPhotos(context: common.UIAbilityContext, remaining: number): Promise<LocalTransferFile[]> {
    const photoPicker = new photoAccessHelper.PhotoViewPicker();
    const result = await photoPicker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: Math.max(1, Math.min(MAX_SELECTED_ITEMS, remaining)),
      isOriginalSupported: true,
      isSelectionNumberVisible: true
    });
    return FileSelectionService.describeUris(result.photoUris, true);
  }

  static async selectFiles(context: common.UIAbilityContext, remaining: number): Promise<LocalTransferFile[]> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.select({
      maxSelectNumber: Math.max(1, Math.min(MAX_SELECTED_ITEMS, remaining)),
      fileSuffixFilters: ['全部文件 (*.*)|.*']
    });
    return FileSelectionService.describeUris(uris, false);
  }

  static maxSelectedItems(): number {
    return MAX_SELECTED_ITEMS;
  }

  static maxFileBytes(): number {
    return MAX_FILE_BYTES;
  }

  private static describeUris(uris: string[], isImage: boolean): LocalTransferFile[] {
    const files: LocalTransferFile[] = [];
    for (const uri of uris) {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size > MAX_FILE_BYTES) {
          throw new Error(`${file.name} 超过手机端单文件 128 MiB 限制`);
        }
        files.push({
          uri: uri,
          name: FileSelectionService.safeFileName(file.name),
          mimeType: FileSelectionService.mimeTypeFor(file.name, isImage),
          size: stat.size,
          isImage: isImage
        });
      } finally {
        fs.closeSync(file);
      }
    }
    return files;
  }

  private static safeFileName(name: string): string {
    let safe = name.trim().replace(/[\\\/:*?"<>|\u0000]/g, '_').replace(/[. ]+$/g, '');
    if (safe.length === 0) {
      safe = '未命名文件';
    }
    return safe.length > 200 ? safe.substring(0, 200) : safe;
  }

  private static mimeTypeFor(name: string, isImage: boolean): string {
    const dot = name.lastIndexOf('.');
    const extension = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
      case 'heif':
        return 'image/heif';
      case 'bmp':
        return 'image/bmp';
      case 'svg':
        return 'image/svg+xml';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      default:
        return isImage ? 'image/*' : 'application/octet-stream';
    }
  }
}
