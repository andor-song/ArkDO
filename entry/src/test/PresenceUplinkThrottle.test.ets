import { describe, it, expect } from '@ohos/hypium';
import { PresenceUplinkThrottle } from '../main/ets/services/presence/PresenceUplinkThrottle';

export default function presenceUplinkThrottleTest() {
  describe('presenceUplinkThrottleTest', () => {
    it('allowsFirstSend', 0, () => {
      const throttle: PresenceUplinkThrottle = new PresenceUplinkThrottle(3000);
      expect(throttle.shouldSend(1000)).assertTrue();
    });

    it('blocksWithinInterval', 0, () => {
      const throttle: PresenceUplinkThrottle = new PresenceUplinkThrottle(3000);
      throttle.markSent(1000);
      expect(throttle.shouldSend(1000)).assertFalse();
      expect(throttle.shouldSend(3999)).assertFalse();
    });

    it('allowsAfterInterval', 0, () => {
      const throttle: PresenceUplinkThrottle = new PresenceUplinkThrottle(3000);
      throttle.markSent(1000);
      expect(throttle.shouldSend(4000)).assertTrue();
    });

    it('resetClearsWindow', 0, () => {
      const throttle: PresenceUplinkThrottle = new PresenceUplinkThrottle(3000);
      throttle.markSent(1000);
      throttle.reset();
      expect(throttle.shouldSend(1001)).assertTrue();
    });
  });
}
