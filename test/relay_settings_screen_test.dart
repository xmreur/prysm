import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/l10n/app_localizations.dart';
import 'package:prysm/screens/relay_settings_screen.dart';
import 'package:prysm/services/relay_service.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/util/qr_platform.dart';
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
// Another real v3 onion: a hand edit target, never a link.
const _otherOnion =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion';
const _deposit =
    'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
const _token =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
// Valid hex64 that never equals the fixed-keys manifest fingerprint below.
const _otherFingerprint =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

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

  testWidgets('pairing link in the address field fills the form and fetches', (
    tester,
  ) async {
    final manifest = _manifest();
    final link = RelayPairingLink(
      onion: _onion,
      fingerprint: manifest.relayFingerprint,
      token: _token,
    ).encode();
    final fetched = <String>[];
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async {
          fetched.add(relayOnion);
          return RelayPairingPreview(
            manifest: manifest,
            relayOnion: relayOnion,
            signatureValid: true,
          );
        },
      ),
    );

    await tester.enterText(find.byType(EditableText).at(0), link);
    await tester.pump();

    // Toast for the applied link, read before it times out.
    expect(find.text(l10n.relayLinkPasted), findsOneWidget);
    final fields = tester
        .widgetList<PrysmTextField>(find.byType(PrysmTextField))
        .toList();
    expect(fields[0].controller.text, _onion);
    expect(fields[1].controller.text, _token);

    await tester.pumpAndSettle();
    expect(fetched, [_onion]);
    expect(find.text(l10n.relayLinkFingerprintMatch), findsOneWidget);
    // Lets the applied-link toast dismiss: its timer would otherwise outlive
    // the test and fail the binding's no-pending-timers check.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('manifest fingerprint differing from the link blocks pairing', (
    tester,
  ) async {
    final manifest = _manifest();
    final link = RelayPairingLink(
      onion: _onion,
      fingerprint: _otherFingerprint,
      token: _token,
    ).encode();
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async => RelayPairingPreview(
          manifest: manifest,
          relayOnion: relayOnion,
          signatureValid: true,
        ),
      ),
    );

    await tester.enterText(find.byType(EditableText).at(0), link);
    await tester.pumpAndSettle();

    expect(find.text(l10n.relayLinkFingerprintMismatch), findsOneWidget);
    final accept = tester.widget<PrysmButton>(
      find.byKey(const ValueKey('relayAcceptButton')),
    );
    expect(accept.onPressed, isNull);
    // Lets the applied-link toast dismiss (see above).
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('manifest fingerprint matching the link enables pairing', (
    tester,
  ) async {
    final manifest = _manifest();
    final link = RelayPairingLink(
      onion: _onion,
      fingerprint: manifest.relayFingerprint,
      token: _token,
    ).encode();
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async => RelayPairingPreview(
          manifest: manifest,
          relayOnion: relayOnion,
          signatureValid: true,
        ),
      ),
    );

    await tester.enterText(find.byType(EditableText).at(0), link);
    await tester.pumpAndSettle();

    expect(find.text(l10n.relayLinkFingerprintMatch), findsOneWidget);
    final accept = tester.widget<PrysmButton>(
      find.byKey(const ValueKey('relayAcceptButton')),
    );
    expect(accept.onPressed, isNotNull);
    // Lets the applied-link toast dismiss (see above).
    await tester.pump(const Duration(seconds: 4));
  });
  testWidgets('malformed pairing link shows the invalid-link banner', (
    tester,
  ) async {
    var fetches = 0;
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async {
          fetches++;
          return RelayPairingPreview(
            manifest: _manifest(),
            relayOnion: relayOnion,
            signatureValid: true,
          );
        },
      ),
    );

    await tester.enterText(
      find.byType(EditableText).at(0),
      'prysm-relay://pair?onion=not-an-onion',
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.relayLinkInvalid), findsOneWidget);
    expect(fetches, 0);
  });

  testWidgets('cold-start timeout retries once and then renders the preview', (
    tester,
  ) async {
    final manifest = _manifest();
    final link = RelayPairingLink(
      onion: _onion,
      fingerprint: manifest.relayFingerprint,
      token: _token,
    ).encode();
    final secondAttempt = Completer<RelayPairingPreview>();
    var calls = 0;
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async {
          calls++;
          if (calls == 1) throw TimeoutException('cold start');
          return secondAttempt.future;
        },
      ),
    );

    await tester.enterText(find.byType(EditableText).at(0), link);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, 2);
    expect(find.text(l10n.relayFetchRetrying), findsOneWidget);

    secondAttempt.complete(
      RelayPairingPreview(
        manifest: manifest,
        relayOnion: _onion,
        signatureValid: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.relayLinkFingerprintMatch), findsOneWidget);
    // Lets the applied-link toast dismiss (see above).
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('paste button applies a valid pairing link', (tester) async {
    final manifest = _manifest();
    final link = RelayPairingLink(
      onion: _onion,
      fingerprint: manifest.relayFingerprint,
      token: _token,
    ).encode();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': link};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final fetched = <String>[];
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async {
          fetched.add(relayOnion);
          return RelayPairingPreview(
            manifest: manifest,
            relayOnion: relayOnion,
            signatureValid: true,
          );
        },
      ),
    );

    final paste = find.text(l10n.relayPasteLink);
    await tester.ensureVisible(paste);
    await tester.pumpAndSettle();
    await tester.tap(paste);
    await tester.pumpAndSettle();

    final fields = tester
        .widgetList<PrysmTextField>(find.byType(PrysmTextField))
        .toList();
    expect(fields[0].controller.text, _onion);
    expect(fields[1].controller.text, _token);
    expect(fetched, [_onion]);
    // Lets the applied-link toast dismiss (see above).
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('hand edit of the address clears the link fingerprint', (
    tester,
  ) async {
    final manifest = _manifest();
    final link = RelayPairingLink(
      onion: _onion,
      fingerprint: manifest.relayFingerprint,
      token: _token,
    ).encode();
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(
        onClose: () {},
        stateOverride: _unpaired(),
        fetchManifestFn: (relayOnion) async => RelayPairingPreview(
          manifest: manifest,
          relayOnion: relayOnion,
          signatureValid: true,
        ),
      ),
    );

    await tester.enterText(find.byType(EditableText).at(0), link);
    await tester.pumpAndSettle();
    expect(find.text(l10n.relayLinkFingerprintMatch), findsOneWidget);

    await tester.enterText(find.byType(EditableText).at(0), _otherOnion);
    await tester.pumpAndSettle();
    expect(find.text(l10n.relayLinkFingerprintMatch), findsNothing);
    expect(find.text(l10n.relayLinkFingerprintMismatch), findsNothing);
    // Lets the applied-link toast dismiss (see above).
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('scan button only shows where camera scanning is supported', (
    tester,
  ) async {
    await pumpWithPrysmL10n(
      tester,
      RelaySettingsScreen(onClose: () {}, stateOverride: _unpaired()),
    );

    expect(find.text(l10n.relayPasteLink), findsOneWidget);
    expect(
      find.text(l10n.relayScanLink),
      QrPlatform.isScanSupported ? findsOneWidget : findsNothing,
    );
  });
}
