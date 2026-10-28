import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Log } from '../logging/Log';
import { AvatarImageCache } from '../network/AvatarImageCache';
import { ContentImageCache } from '../network/ContentImageCache';

const LOG_TAG: string = '[ArkDO][Storage]';
// 附件下载目录:host webview 的下载委托把它写在 filesDir/download(见 RootTabPage 注入沙箱上下文处)。
const DOWNLOAD_DIR_NAME: string = 'download';

export interface DownloadFile {
  name: string;
  path: string;
  size: number;
}

export interface StorageUsage {
  imageEntries: number;
  imageBytes: number;
  imageMaxBytes: number;
  downloadFiles: DownloadFile[];
  downloadBytes: number;
}

/**
 * 存储清理:图片缓存(内存里的已解码 PixelMap)与附件下载目录(沙箱文件)。
 *
 * 刻意只清这两样:
 *  · 图片缓存随时可重建,清了只是下次重新走一遍 host webview 取字节;
 *  · 下载目录是用户点过「下载附件」留下的副本,清了不会丢服务器上的原件。
 * 登录态、草稿、设置这些「清了就回不来」的东西一概不碰。
 */
export class StorageCleanupService {
  private static downloadDir(context: common.Context): string {
    return `${context.filesDir}/${DOWNLOAD_DIR_NAME}`;
  }

  static usage(context: common.Context): StorageUsage {
    const avatar = AvatarImageCache.statsOf();
    const content = ContentImageCache.statsOf();
    const files: DownloadFile[] = StorageCleanupService.listDownloads(context);
    let downloadBytes: number = 0;
    for (let index: number = 0; index < files.length; index++) {
      downloadBytes += files[index].size;
    }
    return {
      imageEntries: avatar.entries + content.entries,
      imageBytes: avatar.bytes + content.bytes,
      imageMaxBytes: avatar.maxBytes + content.maxBytes,
      downloadFiles: files,
      downloadBytes: downloadBytes
    };
  }

  // 目录不存在(从没下载过)按空列表处理,不报错。
  static listDownloads(context: common.Context): DownloadFile[] {
    const dir: string = StorageCleanupService.downloadDir(context);
    const files: DownloadFile[] = [];
    try {
      const names: string[] = fs.listFileSync(dir);
      for (let index: number = 0; index < names.length; index++) {
        const path: string = `${dir}/${names[index]}`;
        let size: number = 0;
        try {
          size = fs.statSync(path).size;
        } catch (statError) {
          // 刚被系统回收/正在写:列出来但大小未知,别因此让整页失败。
          size = 0;
        }
        files.push({ name: names[index], path: path, size: size });
      }
    } catch (error) {
      // 目录不存在是正常状态(从没下载过)。
      Log.i(`${LOG_TAG} list downloads skipped: ${JSON.stringify(error)}`);
      return [];
    }
    // 大的排前面:用户想清理时先看到占地方的。
    files.sort((a: DownloadFile, b: DownloadFile): number => b.size - a.size);
    return files;
  }

  // 清空两类图片缓存,返回释放的字节数(仅已解码缓存,不含 GC 尚未回收的部分)。
  static clearImageCaches(): number {
    return AvatarImageCache.clearAll() + ContentImageCache.clearAll();
  }

  static deleteDownload(file: DownloadFile): boolean {
    try {
      fs.unlinkSync(file.path);
      return true;
    } catch (error) {
      Log.i(`${LOG_TAG} delete download failed name=${file.name} error=${JSON.stringify(error)}`);
      return false;
    }
  }

  // 删除下载目录里的全部文件,返回释放字节数。目录本身保留(下载委托要用)。
  static clearDownloads(context: common.Context): number {
    const files: DownloadFile[] = StorageCleanupService.listDownloads(context);
    let freed: number = 0;
    for (let index: number = 0; index < files.length; index++) {
      if (StorageCleanupService.deleteDownload(files[index])) {
        freed += files[index].size;
      }
    }
    return freed;
  }

  // 人类可读的字节数。界面统一走它,免得各页各写一套 toFixed(1) MB。
  static formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
}
