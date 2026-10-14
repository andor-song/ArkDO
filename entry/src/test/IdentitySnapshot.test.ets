import { describe, it, expect } from '@ohos/hypium';
import { IdentitySnapshotData, identitySnapshotKey, parseIdentity, serializeIdentity } from '../main/ets/services/session/IdentitySnapshot';

export default function identitySnapshotTest() {
  describe('identitySnapshotTest', () => {
    it('roundTripsAllFields', 0, () => {
      const data: IdentitySnapshotData = {
        id: 42,
        username: 'kavin',
        displayName: 'Kavin',
        avatarTemplate: '/user_avatar/linux.do/kavin/{size}/1_2.png'
      };
      const parsed: IdentitySnapshotData | undefined = parseIdentity(serializeIdentity(data));
      expect(parsed?.id).assertEqual(42);
      expect(parsed?.username).assertEqual('kavin');
      expect(parsed?.displayName).assertEqual('Kavin');
      expect(parsed?.avatarTemplate).assertEqual('/user_avatar/linux.do/kavin/{size}/1_2.png');
    });

    it('treatsMissingAvatarAsAbsent', 0, () => {
      const parsed: IdentitySnapshotData | undefined =
        parseIdentity(serializeIdentity({ id: 1, username: 'a', displayName: 'A' }));
      expect(parsed?.avatarTemplate).assertUndefined();
    });

    it('returnsUndefinedForEmptyOrMalformedInput', 0, () => {
      expect(parseIdentity('')).assertUndefined();
      expect(parseIdentity('{bad')).assertUndefined();
      expect(parseIdentity('[]')).assertUndefined();
      expect(parseIdentity('null')).assertUndefined();
    });

    it('rejectsSnapshotWithoutUsernameOrNumericId', 0, () => {
      expect(parseIdentity('{"id":1,"displayName":"A"}')).assertUndefined();
      expect(parseIdentity('{"username":"a","displayName":"A"}')).assertUndefined();
      expect(parseIdentity('{"id":"1","username":"a","displayName":"A"}')).assertUndefined();
    });

    it('toleratesUnknownExtraFields', 0, () => {
      const parsed: IdentitySnapshotData | undefined =
        parseIdentity('{"id":9,"username":"x","displayName":"X","futureField":true}');
      expect(parsed?.username).assertEqual('x');
    });

    it('scopesKeyPerHost', 0, () => {
      expect(identitySnapshotKey('linux.do')).assertEqual('identity_snapshot_linux.do');
      expect(identitySnapshotKey('example.com')).assertEqual('identity_snapshot_example.com');
    });
  });
}
