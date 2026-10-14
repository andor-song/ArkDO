// 「上次已知身份」快照:纯序列化层(不含任何设备 API,可单测)。
//
// 为什么需要:currentUser 只在内存(RootTabPage 的 @State),冷启动/进程回收后必然为空,
// 于是 UI 先渲染匿名态(「立即登录」),直到 /session/current.json 成功——新网络 + CF 挑战
// 会把这段窗口拉长到几十秒,用户看到的就是「掉登录」。这里按站点存一份最小身份,
// 冷启动先渲染它,**只喂渲染**:不参与写操作闸门(LoginGate),也不写信任等级
// (等级按站不同,用错会让附件上传误判,见 LoginGate.setUserPrivileges 的注释)。
//
// 键含站点域名:切到另一个已登录论坛时各读各的,不会把 A 站的头像显示成 B 站的。
// 清理时机(见 RootTabPage):用户登出、两振确认匿名、切站时不读旧站的那份。

export interface IdentitySnapshotData {
  id: number;
  username: string;
  displayName: string;
  avatarTemplate?: string;
}

// 磁盘形态刻意宽松:多出来的字段(未来版本写的)忽略即可,坏数据一律当没有。
interface RawIdentitySnapshot {
  id?: number;
  username?: string;
  displayName?: string;
  avatarTemplate?: string;
}

const SNAPSHOT_KEY_PREFIX: string = 'identity_snapshot_';

export function identitySnapshotKey(host: string): string {
  return `${SNAPSHOT_KEY_PREFIX}${host}`;
}

export function serializeIdentity(data: IdentitySnapshotData): string {
  const raw: RawIdentitySnapshot = {
    id: data.id,
    username: data.username,
    displayName: data.displayName,
    avatarTemplate: data.avatarTemplate !== undefined ? data.avatarTemplate : ''
  };
  return JSON.stringify(raw);
}

export function parseIdentity(raw: string | undefined): IdentitySnapshotData | undefined {
  if (raw === undefined || raw.length === 0) {
    return undefined;
  }
  try {
    const parsed: RawIdentitySnapshot | null = JSON.parse(raw) as RawIdentitySnapshot | null;
    if (parsed === null || parsed === undefined) {
      return undefined;
    }
    if (typeof parsed.id !== 'number' || !Number.isFinite(parsed.id)) {
      return undefined;
    }
    if (typeof parsed.username !== 'string' || parsed.username.length === 0) {
      return undefined;
    }
    const displayName: string = typeof parsed.displayName === 'string' && parsed.displayName.length > 0
      ? parsed.displayName
      : parsed.username;
    const avatarTemplate: string | undefined = typeof parsed.avatarTemplate === 'string' && parsed.avatarTemplate.length > 0
      ? parsed.avatarTemplate
      : undefined;
    return {
      id: Math.floor(parsed.id),
      username: parsed.username,
      displayName: displayName,
      avatarTemplate: avatarTemplate
    };
  } catch (error) {
    return undefined;
  }
}
