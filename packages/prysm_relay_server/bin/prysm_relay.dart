/// `prysm_relay`: init / serve / token / status / fingerprint.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:prysm_relay_server/prysm_relay_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> args) async {
  final runner = CommandRunner<void>(
    'prysm_relay',
    'Standalone store-and-forward Relay for Prysm (prysm-relay/1).',
  )
    ..addCommand(_InitCommand())
    ..addCommand(_ServeCommand())
    ..addCommand(_TokenCommand())
    ..addCommand(_StatusCommand())
    ..addCommand(_FingerprintCommand());
  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(e.usage);
    exit(64);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  } on RelayError catch (e) {
    stderr.writeln('error: ${e.code}: ${e.message}');
    exit(1);
  } catch (e) {
    stderr.writeln('error: $e');
    exit(1);
  }
}

class _ConfigLoader {
  static RelayConfig load(String? path) {
    if (path == null || path.isEmpty) {
      throw const FormatException('missing --config <path>');
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('config not found: $path');
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('config must be a JSON object');
    }
    return RelayConfig.fromJson(Map<String, dynamic>.from(decoded));
  }
}

class _InitCommand extends Command<void> {
  @override
  String get name => 'init';

  @override
  String get description =>
      'Create a data dir, relay identity, default config and first setup token.';

  _InitCommand() {
    argParser
      ..addOption('data-dir', mandatory: true, help: 'Relay data directory.')
      ..addOption('tenancy',
          defaultsTo: 'private', allowed: ['private', 'public'])
      ..addOption('onion', help: 'v3 .onion address (set before serve).')
      ..addOption('bind', defaultsTo: '127.0.0.1')
      ..addOption('port', defaultsTo: '8443');
  }

  @override
  Future<void> run() async {
    final r = argResults!;
    final dataDir = r['data-dir'] as String;
    // Rejected here, not at the first `serve`: a config `serve` will refuse to
    // load is not a config worth writing.
    RelayConfig.requireLoopbackBind(r['bind'] as String);
    await Directory(dataDir).create(recursive: true);
    final config = RelayConfig.defaults(
      dataDir: Directory(dataDir).absolute.path,
      tenancy: RelayTenancy.parse(r['tenancy']),
      onion: (r['onion'] as String?) ?? '',
      bind: r['bind'] as String,
      port: int.parse(r['port'] as String),
    );
    final configPath = '${config.dataDir}/config.json';
    // Every conflict is checked before anything is written: generating the
    // identity first left a brand-new fingerprint (and a half-initialised data
    // dir) behind whenever the config turned out to exist already.
    if (File(configPath).existsSync()) {
      throw StateError('config already exists at $configPath');
    }
    final keys = await RelayKeyPair.generateAndSave(config.dataDir);
    File(configPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config.toJson()));
    final store = await RelayStore.open(config.dataDir);
    final token = await store.mintToken(
      ttlHours: 168,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    // ignore: avoid_print
    print('relay initialised');
    // ignore: avoid_print
    print('  dataDir:     ${config.dataDir}');
    // ignore: avoid_print
    print('  config:      $configPath');
    // ignore: avoid_print
    print('  fingerprint: ${keys.fingerprint}');
    // ignore: avoid_print
    print('  setup token: ${token.token} (expires in 168h)');
    if (config.onion.isEmpty) {
      // ignore: avoid_print
      print('  next: put your .onion address in "onion" inside $configPath,');
      // ignore: avoid_print
      print('  then configure Tor (see README) and run `serve`.');
    }
  }
}

class _ServeCommand extends Command<void> {
  @override
  String get name => 'serve';

  @override
  String get description => 'Serve the relay HTTP API (behind Tor).';

  _ServeCommand() {
    argParser.addOption('config', mandatory: true, help: 'Config JSON path.');
  }

  @override
  Future<void> run() async {
    final config = _ConfigLoader.load(argResults!['config'] as String?);
    if (config.onion.isEmpty) {
      throw FormatException(
        'config "onion" is empty: set your .onion address before serving',
      );
    }
    RelayFields.onion(config.onion, field: 'onion');
    final keys = await RelayKeyPair.load(config.dataDir);
    final store = await RelayStore.open(config.dataDir);
    final log = RelayLog(debug: config.isDebug);
    if (config.isDebug) {
      log.warn('logLevel=debug: redaction is relaxed. Never use in production.');
    }
    final server = RelayServer(
      config: config,
      keys: keys,
      store: store,
      log: log,
    );
    final http = await shelf_io.serve(
      server.handler,
      config.bind,
      config.port,
    );
    log.event(
      'prysm-relay $relaySoftware listening on ${config.bind}:${http.port} '
      'fingerprint=${keys.fingerprint}',
    );
    server.startSweeper();
    await Future.any([
      ProcessSignal.sigint.watch().first,
      ProcessSignal.sigterm.watch().first,
    ]);
    server.stopSweeper();
    await http.close(force: true);
  }
}

class _TokenCommand extends Command<void> {
  @override
  String get name => 'token';

  @override
  String get description => 'Manage setup/invite tokens.';

  _TokenCommand() {
    addSubcommand(_TokenNewCommand());
    addSubcommand(_TokenListCommand());
  }
}

class _TokenNewCommand extends Command<void> {
  @override
  String get name => 'new';

  @override
  String get description => 'Mint a single-use setup/invite token.';

  _TokenNewCommand() {
    argParser
      ..addOption('config', mandatory: true)
      ..addOption('ttl', defaultsTo: '168', help: 'Time to live, in hours.');
  }

  @override
  Future<void> run() async {
    final config = _ConfigLoader.load(argResults!['config'] as String?);
    final ttl = int.tryParse(argResults!['ttl'] as String);
    if (ttl == null || ttl <= 0) {
      throw const FormatException('--ttl must be a positive number of hours');
    }
    final store = await RelayStore.open(config.dataDir);
    // Under the store's lock: a relay is usually serving from this same file.
    final entry = await store.mintToken(
      ttlHours: ttl,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    // ignore: avoid_print
    print(entry.token);
  }
}

class _TokenListCommand extends Command<void> {
  @override
  String get name => 'list';

  @override
  String get description => 'List pending (unused, unexpired) tokens.';

  _TokenListCommand() {
    argParser.addOption('config', mandatory: true);
  }

  @override
  Future<void> run() async {
    final config = _ConfigLoader.load(argResults!['config'] as String?);
    final store = await RelayStore.open(config.dataDir);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var shown = 0;
    for (final t in store.tokens) {
      if (t.used || t.expiredAt(nowMs)) continue;
      // ignore: avoid_print
      print(
        '${t.token}  expires=${DateTime.fromMillisecondsSinceEpoch(t.expiresAt).toIso8601String()}',
      );
      shown++;
    }
    if (shown == 0) {
      // ignore: avoid_print
      print('no pending tokens');
    }
  }
}

class _StatusCommand extends Command<void> {
  @override
  String get name => 'status';

  @override
  String get description => 'Operator summary of tenants, mailboxes and items.';

  _StatusCommand() {
    argParser.addOption('config', mandatory: true);
  }

  @override
  Future<void> run() async {
    final config = _ConfigLoader.load(argResults!['config'] as String?);
    final store = await RelayStore.open(config.dataDir);
    var items = 0;
    var bytes = 0;
    var mailboxes = 0;
    for (final owner in store.tenants.keys) {
      final usage = store.usageOf(owner);
      items += usage.items;
      bytes += usage.bytes;
      mailboxes += usage.mailboxes;
      // ignore: avoid_print
      print(
        'tenant ${RelayLog.shortId(owner, 8)}… '
        'items=${usage.items} bytes=${usage.bytes} '
        'mailboxes=${usage.mailboxes}',
      );
    }
    // ignore: avoid_print
    print(
      'tenants=${store.tenants.length} mailboxes=$mailboxes '
      'items=$items bytes=$bytes',
    );
  }
}

class _FingerprintCommand extends Command<void> {
  @override
  String get name => 'fingerprint';

  @override
  String get description => 'Print the relay fingerprint.';

  _FingerprintCommand() {
    argParser.addOption('config', mandatory: true);
  }

  @override
  Future<void> run() async {
    final config = _ConfigLoader.load(argResults!['config'] as String?);
    final keys = await RelayKeyPair.load(config.dataDir);
    // ignore: avoid_print
    print(keys.fingerprint);
  }
}
