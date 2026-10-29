import { describe, it, expect } from '@ohos/hypium';
import { DraftPublishRaceGuard } from '../main/ets/services/draft/DraftPublishRaceGuard';

// 这条逻辑对应的 bug 是「回复已发出,草稿箱里却留着当时的回复内容」。
// 它只在时序上出现(草稿保存在途 ∩ 用户点了发送),真机手测极难稳定复现,
// 所以把判定抽成纯函数在这里锁死:任何一次把 beginPublish 挪到请求之后、
// 或把「迟到保存」当成正常保存记账的改动,都会在这里红掉。
export default function draftPublishRaceGuardTest() {
  describe('draftPublishRaceGuardTest', () => {
    it('freshSaveIsNotLate', 0, () => {
      const guard: DraftPublishRaceGuard = new DraftPublishRaceGuard();
      const start: number = guard.getGeneration();
      expect(guard.isLateSave(start)).assertFalse();
    });

    it('saveStartedBeforePublishIsLate', 0, () => {
      const guard: DraftPublishRaceGuard = new DraftPublishRaceGuard();
      const start: number = guard.getGeneration();
      // 保存在途 → 用户点发送 → 发布发起。保存回包时必须认出自己跨过了发布。
      guard.beginPublish();
      expect(guard.isLateSave(start)).assertTrue();
    });

    it('publishSuppressesNewSavesUntilRealEdit', 0, () => {
      const guard: DraftPublishRaceGuard = new DraftPublishRaceGuard();
      expect(guard.isSuppressed()).assertFalse();
      guard.beginPublish();
      expect(guard.isSuppressed()).assertTrue();
      // 用户又敲了新内容:那是尚未发表的另一个草稿,保存能力必须恢复。
      guard.noteUserEdit();
      expect(guard.isSuppressed()).assertFalse();
    });

    it('beginPublishBumpsGenerationEachTime', 0, () => {
      const guard: DraftPublishRaceGuard = new DraftPublishRaceGuard();
      const first: number = guard.getGeneration();
      guard.beginPublish();
      const second: number = guard.getGeneration();
      expect(second - first).assertEqual(1);
      guard.beginPublish();
      expect(guard.getGeneration() - second).assertEqual(1);
    });

    // 这里原来有一条 needsDelete(sequence) 的判据(序号 0 就别删),已删:那个 0 是**新 key
    // 首次保存的正常返回值**,这样的草稿照样删得掉。「有没有行」只有服务端说得准,
    // 对应行为锁在 DraftService.test.ets 的 firstSaveWithSequenceZeroIsStillDeleted 里。

    it('lateSavePurgeKeepsSuppression', 0, () => {
      const guard: DraftPublishRaceGuard = new DraftPublishRaceGuard();
      const start: number = guard.getGeneration();
      guard.beginPublish();
      // 迟到的保存要「自己删掉自己」,但删除不解除抑制:否则删除前的一次重排
      // 又能把同一段内容存回去。
      expect(guard.isLateSave(start)).assertTrue();
      expect(guard.isSuppressed()).assertTrue();
    });
  });
}
