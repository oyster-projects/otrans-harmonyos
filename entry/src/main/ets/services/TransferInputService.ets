import { common } from '@kit.AbilityKit';
import { unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { LocalTransferFile, TransferInputContent } from '../models/ApiModels';
import { FileSelectionService } from './FileSelectionService';

interface InputFileUri {
  uri: string;
  imageHint: boolean;
}

export class TransferInputService {
  static async parse(context: common.UIAbilityContext, data: unifiedDataChannel.UnifiedData,
    copyFiles: boolean): Promise<TransferInputContent> {
    const texts: string[] = [];
    const inputFiles: InputFileUri[] = [];
    let unsupportedCount: number = 0;
    const records = data.getRecords();
    for (const record of records) {
      const types = record.getTypes();
      const text = TransferInputService.readText(record, types);
      if (text.length > 0) {
        texts.push(text);
        continue;
      }
      const inputFile = TransferInputService.readFileUri(record, types);
      if (inputFile !== undefined) {
        inputFiles.push(inputFile);
        continue;
      }
      const pixelMapFile = await TransferInputService.savePixelMap(context, record, types);
      if (pixelMapFile !== undefined) {
        inputFiles.push(pixelMapFile);
        continue;
      }
      unsupportedCount++;
    }

    const files: LocalTransferFile[] = [];
    for (const input of inputFiles) {
      const uri = copyFiles ? TransferInputService.copyToInputCache(context, input.uri) : input.uri;
      files.push(...FileSelectionService.describeUris([uri], input.imageHint));
    }
    return { texts: texts, files: files, unsupportedCount: unsupportedCount };
  }

  private static readText(record: unifiedDataChannel.UnifiedRecord, types: string[]): string {
    if (types.includes(uniformTypeDescriptor.UniformDataType.PLAIN_TEXT)) {
      try {
        const value = record.getEntry(uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) as uniformDataStruct.PlainText;
        if (value.textContent) {
          return value.textContent;
        }
      } catch (_) {
        const plainText = record as unifiedDataChannel.PlainText;
        return plainText.textContent || '';
      }
    }
    if (types.includes(uniformTypeDescriptor.UniformDataType.HYPERLINK)) {
      try {
        const value = record.getEntry(uniformTypeDescriptor.UniformDataType.HYPERLINK) as uniformDataStruct.Hyperlink;
        return value.url || '';
      } catch (_) {
        return (record as unifiedDataChannel.Hyperlink).url || '';
      }
    }
    if (types.includes(uniformTypeDescriptor.UniformDataType.HTML)) {
      try {
        const value = record.getEntry(uniformTypeDescriptor.UniformDataType.HTML) as uniformDataStruct.HTML;
        return value.plainContent || value.htmlContent || '';
      } catch (_) {
        const html = record as unifiedDataChannel.HTML;
        return html.plainContent || html.htmlContent || '';
      }
    }
    return '';
  }

  private static readFileUri(record: unifiedDataChannel.UnifiedRecord, types: string[]): InputFileUri | undefined {
    if (types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) {
      const entry = record.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
      if (TransferInputService.isFolderType(entry.fileType)) {
        return undefined;
      }
      return {
        uri: entry.oriUri,
        imageHint: TransferInputService.belongsTo(entry.fileType, uniformTypeDescriptor.UniformDataType.IMAGE)
      };
    }
    for (const type of types) {
      if (TransferInputService.belongsTo(type, uniformTypeDescriptor.UniformDataType.FOLDER)) {
        return undefined;
      }
      if (TransferInputService.belongsTo(type, uniformTypeDescriptor.UniformDataType.FILE)) {
        const file = record as unifiedDataChannel.File;
        let uri = file.uri;
        if (file instanceof unifiedDataChannel.Image) {
          uri = file.imageUri;
        } else if (file instanceof unifiedDataChannel.Video) {
          uri = file.videoUri;
        }
        if (uri.length > 0) {
          return {
            uri: uri,
            imageHint: TransferInputService.belongsTo(type, uniformTypeDescriptor.UniformDataType.IMAGE)
          };
        }
      }
    }
    return undefined;
  }

  private static async savePixelMap(context: common.UIAbilityContext, record: unifiedDataChannel.UnifiedRecord,
    types: string[]): Promise<InputFileUri | undefined> {
    if (!types.includes(uniformTypeDescriptor.UniformDataType.OPENHARMONY_PIXEL_MAP)) {
      return undefined;
    }
    const value = record.getEntry(uniformTypeDescriptor.UniformDataType.OPENHARMONY_PIXEL_MAP) as uniformDataStruct.PixelMap;
    const packer = image.createImagePacker();
    try {
      const content = await packer.packing(value.pixelMap, { format: 'image/png', quality: 100 });
      const directory = TransferInputService.ensureInputDirectory(context);
      const path = `${directory}/拖入图片-${util.generateRandomUUID()}.png`;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      return { uri: fileUri.getUriFromPath(path), imageHint: true };
    } finally {
      packer.release();
    }
  }

  private static copyToInputCache(context: common.UIAbilityContext, sourceUri: string): string {
    const source = fs.openSync(sourceUri, fs.OpenMode.READ_ONLY);
    try {
      const name = FileSelectionService.safeFileName(source.name);
      const directory = TransferInputService.ensureInputDirectory(context);
      const destination = `${directory}/${util.generateRandomUUID()}-${name}`;
      const output = fs.openSync(destination,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        // FileUri 不是文件系统路径。源文件保持打开，并通过 FD 复制，才能读取中转站授予的临时 URI。
        fs.copyFileSync(source.fd, output.fd);
      } finally {
        fs.closeSync(output);
      }
      return fileUri.getUriFromPath(destination);
    } finally {
      fs.closeSync(source);
    }
  }

  private static ensureInputDirectory(context: common.UIAbilityContext): string {
    const directory = `${context.cacheDir}/otrans-input`;
    try {
      fs.mkdirSync(directory, true);
    } catch (_) {
      // 目录已存在时可直接复用。
    }
    return directory;
  }

  private static isFolderType(type: string): boolean {
    return TransferInputService.belongsTo(type, uniformTypeDescriptor.UniformDataType.FOLDER);
  }

  private static belongsTo(type: string, parent: string): boolean {
    try {
      return uniformTypeDescriptor.getTypeDescriptor(type).belongsTo(parent);
    } catch (_) {
      return false;
    }
  }
}
