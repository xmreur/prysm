
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/screens/relay_settings_screen.dart';
import 'package:prysm/services/relay_service.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pump_prysm_l10n.dart';

const _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
// A real v3 onion: 56 base32 chars, or `RelayFields.onion` refuses it and a
// stored Contract never parses back.
const _onion =
    'abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion';
const _deposit =
    'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

RelayManifest _manifest() {
  final identity = RelayIdentity.fromKeys(
    signPublic: List<int>.filled(32, 1),
    agreePublic: List<int>.filled(32, 2),
  );
  return RelayManifest(
    relayIdentityJson: identity.toJsonString(),
    relayFingerprint: identity.fingerprint,
    relayOnion: _onion,
    tenancy: RelayTenancy.private,
    admission: RelayAdmission.invite,
    limits: const RelayLimits(
      maxItemBytes: 2 * 1024 * 1024,
      maxMailboxItems: 256,
      maxTenantBytes: 64 * 1024 * 1024,
      itemTtlSeconds: 20 * 86400,
      maxMailboxes: 512,
    ),
    software: 'prysm-relay/test',
    issuedAt: 1700000000000,
    terms: 'Test terms.',
  );
}

RelayState _unpaired() => const RelayState(enabled: false);

RelayState _paired() => RelayState(
  enabled: true,
  contract: RelayContract(
    version: 1,
    relayFingerprint: _fingerprint,
    relayOnion: _onion,
    ownerFingerprint: _fingerprint,
    ownerOnion: _onion,
    tenancy: RelayTenancy.private,
    limits: const RelayLimits(
      maxItemBytes: 2 * 1024 * 1024,
      maxMailboxItems: 256,
      maxTenantBytes: 64 * 1024 * 1024,
      itemTtlSeconds: 20 * 86400,
      maxMailboxes: 512,
    ),
    issuedAt: 1700000000000,
  ),
  usage: const RelayUsage(
    items: 3,
    bytes: 3072,
    mailboxes: 2,
    oldestExpiresAt: null,
  ),
  mailboxes: const [
    RelayMailboxInfo(
      deposit: _deposit,
      label: 'Alice',
      items: 2,
      bytes: 2048,
      enabled: true,
    ),
    RelayMailboxInfo(
      deposit:
          '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
      items: 0,
      bytes: 0,
      enabled: true,
    ),
  ],
  lastPickupAt: null,
  lastPickupDelivered: 0,
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('invalid manifest signature disables the accept action', (
    tester,
  ) async {
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        previewOverride: RelayPairingPreview(
          manifest: _manifest(),
          relayOnion: _onion,
          signatureValid: false,
        ),
      ),
    );

    expect(find.text(l10n.relayBadSignature), findsOneWidget);
    final accept = tester.widget<PrysmButton>(
      find.byKey(const ValueKey('relayAcceptButton')),
    );
    expect(accept.onPressed, isNull);
  });

  testWidgets('valid manifest signature enables the accept action', (
    tester,
  ) async {
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        previewOverride: RelayPairingPreview(
          manifest: _manifest(),
          relayOnion: _onion,
          signatureValid: true,
        ),
      ),
    );

    expect(find.text(l10n.relayBadSignature), findsNothing);
    final accept = tester.widget<PrysmButton>(
      find.byKey(const ValueKey('relayAcceptButton')),
    );
    expect(accept.onPressed, isNotNull);
  });

  testWidgets('paired state renders limits and mailbox rows', (tester) async {
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(onClose: () {}, stateOverride: _paired()),
    );

    // Contract limits in human units.
    expect(find.text('2.0 MB'), findsWidgets);
    expect(find.text(l10n.relayRetentionDays(20)), findsWidgets);
    // Mailbox rows: labelled contact plus truncated raw deposit.
    expect(find.text('Alice'), findsOneWidget);
    expect(find.textContaining('…'), findsWidgets);
    expect(find.textContaining(l10n.relayMailboxItems(2)), findsOneWidget);
  });

  testWidgets('revoke asks for confirmation before calling through', (
    tester,
  ) async {
    final revoked = <String>[];
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _paired(),
        revokeMailboxFn: (deposit) async {
          revoked.add(deposit);
        },
      ),
    );

    final revokeButton = find.byKey(ValueKey('relayRevoke-$_deposit'));
    await tester.ensureVisible(revokeButton);
    await tester.pumpAndSettle();
    await tester.tap(revokeButton);
    await tester.pumpAndSettle();

    expect(find.text(l10n.relayRevokeTitle), findsOneWidget);
    expect(revoked, isEmpty);

    await tester.tap(find.text(l10n.relayRevoke));
    await tester.pumpAndSettle();

    expect(revoked, [_deposit]);
  });

  testWidgets('opening the screen while paired refreshes the relay status', (
    tester,
  ) async {
    // No `stateOverride`: this is the live path, the one the app takes. It
    // used to throw a zone error out of `initState` and never refresh, so the
    // mailbox list stayed empty even when the relay held addresses.
    SharedPreferences.setMockInitialValues({});
    await SettingsService().init();
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();
    final identity = await IdentityKeyPair.generate();
    await CryptoKeyStore.write(
      CryptoKeyStore.publicIdentityKey,
      jsonEncode(await identity.toPublicJson()),
    );
    RelayService.instance.configure(keyManager: KeyManager.fromIdentity(identity));
    await SettingsService().setRelayContract(
      jsonEncode(_paired().contract!.toJson()),
    );
    await SettingsService().setRelayEnabled(true);
    await RelayService.instance.load();
    addTearDown(() async {
      await SettingsService().setRelayContract(null);
      await SettingsService().setRelayEnabled(false);
      await RelayService.instance.load();
    });

    var refreshes = 0;
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        refreshStatusFn: () async => refreshes++,
        mailboxLabelsFn: () async => const {},
      ),
    );
    await tester.pumpAndSettle();

    expect(refreshes, 1);
  });
}
