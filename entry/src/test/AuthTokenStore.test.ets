import { describe, it, expect } from '@ohos/hypium';
import { AuthTokenStore, decideRestore, RestoreDecision } from '../main/ets/services/session/AuthTokenStore';
import { NO_COOKIE } from '../main/ets/services/web/CookieProbe';

// 只测这个服务里**不碰存储/系统 API** 的两个纯函数:死令牌名单的合并与匹配。
// 它们是整条「防死令牌重放」链路的正确性支点 —— 名单错了,要么死令牌照样被灌回去
// (互踢继续),要么有效备份被永久判定为死(再也恢复不了登录)。两种失效都静默无报错。
export default function authTokenStoreTest() {
  describe('authTokenStoreTest', () => {
    it('newestFingerprintGoesFirst', 0, () => {
      expect(AuthTokenStore.mergeDeadList('aaaa1111', 'bbbb2222'))
        .assertEqual('bbbb2222,aaaa1111');
    });

    // 同一枚重复被拒不能把名单越写越长:名单只是"最近几枚"的滑动窗口,重复项会挤掉更早的真记录。
    it('doesNotDuplicateAnExistingEntry', 0, () => {
      const once: string = AuthTokenStore.mergeDeadList('', 'aaaa1111');
      const twice: string = AuthTokenStore.mergeDeadList(once, 'aaaa1111');
      expect(twice).assertEqual('aaaa1111');
      expect(twice.split(',').length).assertEqual(1);
    });

    // 空值占位符**绝不能入名单**:否则"jar 里没 cookie"这个正常游客态会被判成命中,
    // 此后每次冷启动都以为备份是死的,把恢复链路自己焊死。
    it('neverAdmitsTheMissingValuePlaceholder', 0, () => {
      const before: string = AuthTokenStore.mergeDeadList('', 'aaaa1111');
      expect(AuthTokenStore.mergeDeadList(before, NO_COOKIE)).assertEqual(before);
      expect(AuthTokenStore.deadListContains(NO_COOKIE, NO_COOKIE)).assertFalse();
    });

    // 名单是"最近几枚"的滑动窗口:必须有上限(无界增长会淹掉真正的命中),且**淘汰最旧的**。
    // 顺序不能反:最新被拒的那枚最可能被磁盘快照带回来,它才是必须钉住的。
    it('capsAtMaxEntriesKeepingNewest', 0, () => {
      const token = (index: number): string => `f${index}0000000`.substring(0, 8);
      let list: string = '';
      for (let index: number = 0; index < 12; index++) {
        list = AuthTokenStore.mergeDeadList(list, token(index));
      }
      expect(list.split(',').length).assertEqual(AuthTokenStore.MAX_DEAD_TOKENS);
      expect(AuthTokenStore.deadListContains(list, token(11))).assertTrue();
      expect(AuthTokenStore.deadListContains(list, token(6))).assertTrue();
      expect(AuthTokenStore.deadListContains(list, token(0))).assertFalse();
    });

    it('containsMatchesExactTokensOnly', 0, () => {
      const list: string = 'aaaa1111,bbbb2222';
      expect(AuthTokenStore.deadListContains(list, 'aaaa1111')).assertTrue();
      expect(AuthTokenStore.deadListContains(list, 'cccc3333')).assertFalse();
      // 子串不算命中(指纹是比对整枚 token 的,不是前缀匹配)。
      expect(AuthTokenStore.deadListContains(list, 'aaaa')).assertFalse();
      expect(AuthTokenStore.deadListContains('', 'aaaa1111')).assertFalse();
    });

    // —— 冷启动恢复决策 ——
    // 这一组钉的是 2026-10-27 真机掉登录的根因:jar 里已有一枚更新的 `_t`,
    // 却被更旧的备份无条件覆盖,覆盖后服务端判它作废,用户从已登录掉成游客。
    // 备份是从 jar 抄出来的,只可能等于或落后于 jar —— 用旧的盖新的在 `_t` 上只有坏处。
    it('keepsNewerJarTokenInsteadOfOverwritingWithOlderBackup', 0, () => {
      expect(decideRestore('_t', 'jar-value-newer', 'backup-value-older', false, false))
        .assertEqual(RestoreDecision.KEEP_JAR);
    });

    // jar 读不到 `_t` 是常态(HttpOnly + fetchCookieSync 无 includeHttpOnly),
    // 此时必须走备份兜底 —— 否则恢复链路等于没有。
    it('fallsBackToBackupWhenJarTokenUnreadable', 0, () => {
      expect(decideRestore('_t', undefined, 'backup-value', false, false))
        .assertEqual(RestoreDecision.RESTORE_BACKUP);
    });

    // jar 里那枚已被判死:不能用它,退回备份(备份若也是死的,上一档会先拦掉)。
    it('ignoresDeadJarTokenAndRestoresBackup', 0, () => {
      expect(decideRestore('_t', 'jar-dead', 'backup-value', false, true))
        .assertEqual(RestoreDecision.RESTORE_BACKUP);
    });

    // 备份被判死:无论 jar 里有什么都不能恢复它,而且要让调用方按值删掉。
    it('neverRestoresDeadBackup', 0, () => {
      expect(decideRestore('_t', undefined, 'backup-dead', true, false))
        .assertEqual(RestoreDecision.SKIP_DEAD_BACKUP);
      expect(decideRestore('_t', 'jar-ok', 'backup-dead', true, false))
        .assertEqual(RestoreDecision.SKIP_DEAD_BACKUP);
      expect(decideRestore('_forum_session', 'jar-ok', 'backup-dead', true, false))
        .assertEqual(RestoreDecision.SKIP_DEAD_BACKUP);
    });

    // `_forum_session` **必须**覆盖:ArkWeb 会从磁盘恢复出登录前的匿名 session,
    // 而 Discourse 先认 session 再认 `_t`,旧的匿名 session 会把有效 `_t` 挡住(1.0.6 真机)。
    // 这条与上一条相反,是刻意的不对称 —— 谁把它"统一"成同一策略,这条会红。
    it('alwaysOverwritesForumSessionEvenWhenJarHasOne', 0, () => {
      expect(decideRestore('_forum_session', 'jar-session', 'backup-session', false, false))
        .assertEqual(RestoreDecision.RESTORE_BACKUP);
      expect(decideRestore('_forum_session', undefined, 'backup-session', false, false))
        .assertEqual(RestoreDecision.RESTORE_BACKUP);
    });

    // 没有备份:什么都不恢复(也不该误删)。
    it('doesNothingWhenThereIsNoBackup', 0, () => {
      expect(decideRestore('_t', 'jar-value', undefined, false, false))
        .assertEqual(RestoreDecision.SKIP_DEAD_BACKUP);
    });
  });
}
