import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Log } from '../logging/Log';

const LOG_TAG: string = '[ArkDO][AuthSecret]';
// 上游定义的错误码（@ohos.security.asset 的 @throws 文档）：
//   24000002 = The asset is not found / 24000003 = The asset already exists。
// 已存在 → 改走 update；找不到 → 静默（"没有备份"是正常状态）。
const ERROR_NOT_FOUND: number = 24000002;
const ERROR_ALREADY_EXISTS: number = 24000003;

/**
 * 认证 cookie 备份的安全存储（Asset Store Kit）。
 *
 * 为什么不用 preferences：`_t` / `_forum_session` 是**可以直接冒用身份的凭据**，
 * 明文落在应用沙箱里时，任何拿到开发者模式 + hdc 的人都能读走（`strings app_settings` 即可见）。
 * Asset Store 由系统密钥库托管（按应用隔离、可选"首次解锁后可访问"），读取仍需本应用身份。
 *
 * 语义刻意做得"读不到就当没有"：所有失败都只记日志并返回 undefined，
 * 让调用方回落到"这次冷启动可能判匿名"的正常路径，而不是把异常抛进会话链路。
 */
export class AuthSecretStore {
  private static aliasBytes(alias: string): Uint8Array {
    return new util.TextEncoder().encodeInto(alias);
  }

  private static queryFor(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, AuthSecretStore.aliasBytes(alias));
    return query;
  }

  /** 写入或覆盖。值与别名一律不进日志。 */
  static async save(alias: string, value: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, AuthSecretStore.aliasBytes(alias));
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(value));
    // 首次解锁后即可访问：冷启动(开机后首次打开 App)也能读回来,否则恢复不了会话。
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attributes);
      return;
    } catch (addError) {
      const code: number = (addError as BusinessError).code;
      if (code !== ERROR_ALREADY_EXISTS) {
        Log.i(`${LOG_TAG} add failed code=${code}`);
      }
    }
    const update: asset.AssetMap = new Map();
    update.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(value));
    try {
      await asset.update(AuthSecretStore.queryFor(alias), update);
    } catch (updateError) {
      Log.i(`${LOG_TAG} update failed code=${(updateError as BusinessError).code}`);
    }
  }

  static async load(alias: string): Promise<string | undefined> {
    const query: asset.AssetMap = AuthSecretStore.queryFor(alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return undefined;
      }
      const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
      if (secret === undefined || typeof secret === 'number') {
        return undefined;
      }
      const bytes: Uint8Array = secret as Uint8Array;
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (queryError) {
      const code: number = (queryError as BusinessError).code;
      if (code !== ERROR_NOT_FOUND) {
        Log.i(`${LOG_TAG} query failed code=${code}`);
      }
      return undefined;
    }
  }

  static async remove(alias: string): Promise<void> {
    try {
      await asset.remove(AuthSecretStore.queryFor(alias));
    } catch (removeError) {
      const code: number = (removeError as BusinessError).code;
      if (code !== ERROR_NOT_FOUND) {
        Log.i(`${LOG_TAG} remove failed code=${code}`);
      }
    }
  }
}
