import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/pin_entry.dart';
import 'package:prysm/screens/settings_screen.dart';
import 'package:prysm/server/PrysmServer.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/updater_downloader.dart';
import 'package:prysm/screens/chat.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/util/tor_service.dart'; // Updated Tor service
import 'package:prysm/util/tor_downloader.dart';
import 'package:prysm/screens/profile_screen.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/util/theme_manager.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:window_manager/window_manager.dart';

bool _isProcessRunning(int pid) {
  try {
    if (Platform.isWindows) {
      final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid']);
      return (result.stdout as String).contains('$pid');
    } else {
      // Linux/macOS: send signal 0 to check if process exists
      final result = Process.runSync('kill', ['-0', '$pid']);
      return result.exitCode == 0;
    }
  } catch (_) {
    return false;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Prevent multiple instances on desktop
  if (!Platform.isAndroid && !Platform.isIOS) {
    final docDir = await getApplicationDocumentsDirectory();
    final lockFile = File(p.join(docDir.path, 'prysm', '.lock'));
    await Directory(p.join(docDir.path, 'prysm')).create(recursive: true);

    if (await lockFile.exists()) {
      final pidStr = (await lockFile.readAsString()).trim();
      final pid = int.tryParse(pidStr);
      if (pid != null && _isProcessRunning(pid)) {
        // Another instance is running — activate it and exit
        print('Another instance of Prysm is already running (PID $pid).');
        exit(0);
      }
    }
    // Write our PID
    await lockFile.writeAsString('${pid}');

    // Clean up lock file on exit
    ProcessSignal.sigterm.watch().listen((_) async {
      try { await lockFile.delete(); } catch (_) {}
      exit(0);
    });
    ProcessSignal.sigint.watch().listen((_) async {
      try { await lockFile.delete(); } catch (_) {}
      exit(0);
    });
  }

  await NotificationService().init();
  await SettingsService().init();

  final keyManager = KeyManager();

  // Start background service on Android BEFORE runApp so the persistent
  // notification ("Prysm Chat is running") is always present.
  if (Platform.isAndroid) {
    final settings = SettingsService();
    final androidConfig = FlutterBackgroundAndroidConfig(
      notificationTitle: "${settings.name} Chat is running",
      notificationText: "${settings.name} chat is actively waiting for new messages",
      notificationImportance: AndroidNotificationImportance.normal,
      notificationIcon: AndroidResource(name: "icon", defType: "drawable"),
    );
    await FlutterBackground.initialize(androidConfig: androidConfig);
    await FlutterBackground.enableBackgroundExecution();
    await NotificationService().requestPermission();
  }

  // Start the message server early so incoming messages are received
  // even while Tor is still bootstrapping or the user is on the PIN screen.
  final messageServer = PrysmServer(port: 12345, keyManager: keyManager);
  messageServer.start();

  runApp(MyApp(keyManager: keyManager));
}

/// Initializes Tor and the message server in the background.
/// Returns the onion address when ready.
Future<TorInitResult> initializeTor() async {
  var torPath = ""; 
  if (!Platform.isAndroid) {
    await UpdaterDownloader().getOrDownloadUpdater();
    checkForUpdatesAndLaunchUpdater();

    final torDownloader = TorDownloader();
    torPath = await torDownloader.getOrDownloadTor();
  }

  final documentsDir = await getApplicationDocumentsDirectory();
  final dataDirPath = p.join(documentsDir.path, 'prysm', 'tor_executable', 'tor_data');

  final dataDir = Directory(dataDirPath);
  if (!dataDir.existsSync()) {
    dataDir.createSync(recursive: true);
  }

  final torManager = TorManager(
    torPath: torPath,
    dataDir: dataDirPath,
    controlPassword: 'your_strong_password_here',
  );

  await torManager.startTor();

  late String onionAddress;
  try {
    onionAddress = (await torManager.getOnionAddress())!;
  } catch (e) {
    print('Failed to create hidden service: $e');
    onionAddress = 'me';
  }

  return TorInitResult(torManager: torManager, onionAddress: onionAddress);
}

class TorInitResult {
  final TorManager torManager;
  final String onionAddress;
  const TorInitResult({required this.torManager, required this.onionAddress});
}

Future<bool> isNewerVersion(String current, String latest) async {
  // Simple version comparison (assumes vX.Y.Z format)
  List<int> toNums(String v) =>
      v.replaceFirst('v', '').split('.').map(int.parse).toList();

  final currNums = toNums(current);
  final latestNums = toNums(latest);
  for (int i = 0; i < currNums.length && i < latestNums.length; i++) {
    if (latestNums[i] > currNums[i]) return true;
    if (latestNums[i] < currNums[i]) return false;
  }
  return latestNums.length > currNums.length;
}


const String currentVersion = SettingsService.appVersion;

Future<void> checkForUpdatesAndLaunchUpdater() async {
  final url = Uri.parse('https://api.github.com/repos/xmreur/prysm/releases/latest');

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final jsonData = jsonDecode(response.body);

      final latestVersion = jsonData['tag_name'] as String;

      if (await isNewerVersion(currentVersion, latestVersion)) {

        
        final updaterPath = await UpdaterDownloader().getOrDownloadUpdater();


        print('Launching updater process...');
        await Process.start(
          updaterPath,
          [],
          mode: ProcessStartMode.detached,
        );

        // Exit app to allow updater to proceed
        exit(0);
      } else {
        print('Already at latest version $currentVersion');
      }
    } else {
      print('Failed to fetch latest release info. Status: ${response.statusCode}');
    }
  } catch (e) {
    print('Error checking updates: $e');
  }
}

class MyWindowListener extends WindowListener {
  final TorManager torManager;
  MyWindowListener(this.torManager);

  @override
  void onWindowClose() async {
    await torManager.stopTor();
    // Clean up lock file
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final lockFile = File(p.join(docDir.path, 'prysm', '.lock'));
      if (await lockFile.exists()) await lockFile.delete();
    } catch (_) {}
    windowManager.destroy();
  }
}

class MyApp extends StatefulWidget {

  final KeyManager keyManager;

  const MyApp({
    required this.keyManager,
    super.key,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {

    static final settings = SettingsService();
    
  bool unlocked = false;
  int _currentTheme = 0;

  // Tor init state
  TorManager? _torManager;
  String? _onionAddress;
  String _torStatus = 'Initializing...';
  bool _torReady = false;

  Future<bool> onVerifyPin(String pin) async {
    KeyManager keyManager = widget.keyManager;
    bool ok = await keyManager.unlockWithPin(pin);
    if (!ok) return false;

    setState(() => unlocked = true);

    return true;
  }

  @override
  void initState() {
    super.initState();
    _loadSavedTheme();
    _initTorInBackground();
  }

  Future<void> _initTorInBackground() async {
    try {
      setState(() => _torStatus = 'Starting Tor...');
      final result = await initializeTor();

      if (!Platform.isAndroid) {
        windowManager.addListener(MyWindowListener(result.torManager));
      }

      if (mounted) {
        setState(() {
          _torManager = result.torManager;
          _onionAddress = result.onionAddress;
          _torReady = true;
          _torStatus = 'Connected';
        });
      }
    } catch (e) {
      print('Tor initialization failed: $e');
      if (mounted) {
        setState(() => _torStatus = 'Failed to connect: $e');
      }
    }
  }

  Future<void> _loadSavedTheme() async {
    final themeIndex = settings.themeMode;
    setState(() {
      _currentTheme = themeIndex;
    });
  }

  void updateTheme(int themeIndex) async {
    setState(() {
      _currentTheme = themeIndex;
    });
    await settings.setThemeMode(themeIndex);
  }

  @override
  Widget build(BuildContext context) {
    if (!unlocked) {
      return MaterialApp(
        title: "Unlock ${settings.name} Chat",
        theme: ThemeManager.getTheme(_currentTheme),
        home: PinScreen(onVerifyPin: onVerifyPin, isSetupMode: widget.keyManager.isPinSet(),)
      );
    }
    if (!_torReady) {
      return MaterialApp(
        title: '${settings.name} Chat',
        theme: ThemeManager.getTheme(_currentTheme),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  _torStatus,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  'Setting up secure connection...',
                  style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return MaterialApp(
      title: '${settings.name} Chat',
      theme: ThemeManager.getTheme(_currentTheme),
      home: HomeScreen(torManager: _torManager!, onionAddress: _onionAddress!, keyManager: widget.keyManager, onThemeChanged: updateTheme, currentTheme: _currentTheme),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final TorManager torManager;
  final String onionAddress;
  final KeyManager keyManager;
  final Function(int)? onThemeChanged;
  final int currentTheme;

  const HomeScreen({
    required this.torManager, 
    required this.onionAddress, 
    required this.keyManager, 
    this.onThemeChanged,
    this.currentTheme = 0,
    super.key
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {

    static final settings = SettingsService();

  List<Contact> contacts = [];
  late Contact appUser;
  Contact? selectedContact;
  bool showProfile = false;
  bool showSettings = false;
  bool isLoading = true;
  int currentTheme = 0; // 0: Light, 1: Dark, 2: Pink, 3: Cyan, 4: Purple, 5 Orange
  String _searchQuery = '';

  Timer? _refreshTimer;

  List<Contact> get _filteredContacts {
    if (_searchQuery.isEmpty) return contacts;
    return contacts.where((c) => c.displayName.toLowerCase().contains(_searchQuery)).toList();
  }

  @override
  void initState() {
    super.initState();
    currentTheme = widget.currentTheme;
    appUser = Contact(id: widget.onionAddress, name: 'My Profile', avatarUrl: '', publicKeyPem: 'NONE');
    loadUsers();
    _startAutoRefresh();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentTheme != widget.currentTheme) {
      setState(() {
        currentTheme = widget.currentTheme;
      });
    }
  }


  void _startAutoRefresh() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      await loadUsers();
    });
  }


  Future<void> loadUsers() async {
    final userMaps = await DBHelper.getUsers();
    final timestamps = await MessagesDb.getLastMessageTimestampsForAllUsers();
    List<Contact> newContacts = [];
    
    for (var map in userMaps) {
      String id = map['id'];
      String name = map['name'];
      String avatarUrl = '';
      String? avatarBase64 = map['avatarBase64'] as String?;
      String? customName = map['customName'] as String?;
      String? publicKeyPem = map['publicKeyPem'];
      int? lastMessageTimestamp = timestamps[id];

      newContacts.add(Contact(id: id, name: name, avatarUrl: avatarUrl, avatarBase64: avatarBase64, customName: customName, publicKeyPem: publicKeyPem ?? '', lastMessageTimestamp: lastMessageTimestamp));
    }

    // Replace the user with current Tor onion address if it exists
    Contact? newAppUser;
    try {
      newAppUser = newContacts.firstWhere((c) => c.id == widget.onionAddress);
    } catch (_) {
      // Save appUser if not in DB yet
      saveAppUser(appUser);
    }

    // Sync profile to SettingsService if not yet set (migration)
    if (newAppUser != null) {
      final s = SettingsService();
      if (s.username == null && newAppUser.name.isNotEmpty) {
        s.setUsername(newAppUser.name);
      }
      if (s.avatar == null && newAppUser.avatarBase64 != null) {
        s.setAvatar(newAppUser.avatarBase64);
      }
    }

    // Check if contacts have changed (simple length or content check)
    bool contactsChanged = newContacts.length != contacts.length ||
        !newContacts.every((c) => contacts.any((old) => old.id == c.id && old.name == c.name && old.avatarBase64 == c.avatarBase64 && old.customName == c.customName && formatLastMessageTime(old.lastMessageTimestamp) == formatLastMessageTime(c.lastMessageTimestamp)));

    if (contactsChanged) {
      setState(() {

        newContacts.sort((a, b) {
          final aTs = a.lastMessageTimestamp ?? 0;
          final bTs = b.lastMessageTimestamp ?? 0;
          return bTs.compareTo(aTs);
        });
        contacts = newContacts;
        if (newAppUser != null) {
          appUser = newAppUser;
        }
        isLoading = false;
      });
    } else if (isLoading) {
      setState(() {
        isLoading = false;
      });
    }
  }


  void saveAppUser(Contact user) async {
    await DBHelper.insertOrUpdateUser({
      'id': user.id,
      'name': user.name,
      'avatarUrl': user.avatarUrl,
      'avatarBase64': user.avatarBase64,
      'publicKeyPem': user.publicKeyPem
    });
  }

  void onUpdateProfile(Contact updatedUser) {
    setState(() {
      appUser = updatedUser;
    });
    saveAppUser(updatedUser);
    // Persist avatar and username to SettingsService so /profile serves fresh data
    final settings = SettingsService();
    settings.setAvatar(updatedUser.avatarBase64);
    settings.setUsername(updatedUser.name);
    loadUsers();
  }

  void onSelectContact(Contact contact) {
    setState(() {
      selectedContact = contact;
      showProfile = false;
    });
  }

  void onShowProfile() {
    setState(() {
      showSettings = false;
      showProfile = true;
    });
  }

  void onShowSettings() {
    setState(() {
      showSettings = true;
      showProfile = false;
    });
  }

  void onThemeChanged(int themeIndex) {
    setState(() {
      currentTheme = themeIndex;
    });
    widget.onThemeChanged?.call(themeIndex);
  }

  Future<void> _showAddUserDialog() async {
    final idController = TextEditingController();
    final nameController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add New User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(
                labelText: 'User ID (Base58 Onion URL)',
                hintText: 'eg. 51EsbujFRDJLHJ',
              ),
            ),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                hintText: 'eg. Alice',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.of(context).pop(),
          ),
          ElevatedButton(
            child: const Text('Add'),
            onPressed: () {
              String newId;
              try {
                newId = decodeBase58ToOnion(idController.text.trim());
              } catch (e) {
                return;
              }
              final newName = nameController.text.trim();
              
              if (newId.isEmpty || newId == ".onion" || newName.isEmpty) {
                return;
              }
              _addNewUser(newId, newName);
              loadUsers();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _addNewUser(String id, String name) async {
    String? publicKeyPem;
    String? avatarBase64;
    String fetchedName = name;
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final peerOnion = id;
      // Try /profile first for full info
      try {
        final profileUri = Uri.parse("http://$peerOnion:80/profile");
        final profileResponse = await torClient.get(profileUri, {});
        final profileBody = await profileResponse.transform(utf8.decoder).join();
        final profileData = jsonDecode(profileBody) as Map<String, dynamic>;
        publicKeyPem = profileData['publicKeyPem'] as String?;
        if (profileData['username'] != null && (profileData['username'] as String).isNotEmpty) {
          fetchedName = profileData['username'] as String;
        }
        if (profileData['avatar'] != null && (profileData['avatar'] as String).isNotEmpty) {
          avatarBase64 = profileData['avatar'] as String;
        }
        print("Fetched profile from $peerOnion");
      } catch (e) {
        // Fallback to /public
        print("Profile fetch failed, trying /public: $e");
        final uri = Uri.parse("http://$peerOnion:80/public");
        final response = await torClient.get(uri, {});
        publicKeyPem = await response.transform(utf8.decoder).join();
        print("Fetched public key from $peerOnion");
      }
    } catch (e) {
      print("Failed to fetch public key from $id: $e");
      publicKeyPem = "";
    } finally {
      torClient.close();
    }

    final newUser = Contact(id: id, name: fetchedName, avatarUrl: '', avatarBase64: avatarBase64, publicKeyPem: publicKeyPem ?? '');
    await DBHelper.insertOrUpdateUser({
      'id': newUser.id,
      'name': newUser.name,
      'avatarUrl': newUser.avatarUrl,
      'avatarBase64': avatarBase64,
      'publicKeyPem': newUser.publicKeyPem
    });
    await loadUsers();
  }

  String formatLastMessageTime(int? timestamp) {
    if (timestamp == null) return "No message";
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toUtc().toLocal();
    final now = DateTime.now().toUtc();

    bool isSameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;

    if (isSameDay) {
      // Format as "HH:mm"
      return DateFormat('HH:mm').format(dt);
    } else {
      // Format as "dd/MM/yy - HH:mm"
      return DateFormat('dd/MM/yy - HH:mm').format(dt);
    }
  }


  Widget buildSidebar() { 
    
    final isMobile = MediaQuery.of(context).size.width < 600; // You can tune this breakpoint

    return Container(
      margin: EdgeInsetsGeometry.only(top: isMobile ? 50 : 0, bottom: isMobile ? 20 : 0),
      width: 280,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            width: 1
          )
        )
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                  width: 1
                )
              )
            ),
            child: Row(
              children: [
                ContactAvatar(name: appUser.name, radius: 20, avatarBase64: appUser.avatarBase64),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appUser.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        )
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.green,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Online',
                            style: TextStyle(
                              color: Colors.green,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4
                  )
                ]
              ),
              child: TextField(
                onChanged: (value) {
                  setState(() => _searchQuery = value.trim().toLowerCase());
                },
                decoration: const InputDecoration(
                  hintText: 'Search chats...',
                  hintStyle: TextStyle(fontSize: 14),
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Contact List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _filteredContacts.length,
              itemBuilder: (_, index) {
                final contact = _filteredContacts[index];
                if (contact.id == appUser.id) return const SizedBox.shrink();
                return Padding(
                  key: ValueKey('${contact.id}_${contact.lastMessageTimestamp ?? 0}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2
                  ),
                  child: ListTile(
                    key: ValueKey('${contact.id}_${contact.lastMessageTimestamp ?? 0}'),
                    leading: ContactAvatar(name: contact.displayName, avatarBase64: contact.avatarBase64),
                    title: Text(
                      contact.displayName,
                      style: TextStyle(
                        fontWeight: selectedContact?.id == contact.id ? FontWeight.bold : FontWeight.normal,
                      )
                    ),
                    subtitle: Text(
                      formatLastMessageTime(contact.lastMessageTimestamp),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: selectedContact?.id == contact.id,
                    selectedTileColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () => onSelectContact(contact)
                  )  
                );
              },
            ),
          ),
          // Bottom buttons
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                  width: 1
                ),
              )
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: onShowSettings,
                  tooltip: "Settings",
                ),
                IconButton(
                  icon: const Icon(Icons.person_outline),
                  onPressed: onShowProfile,
                  tooltip: "Profile",
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _showAddUserDialog,
                  tooltip: "Add Contact",
                )
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _shutdownTor();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached || state == AppLifecycleState.inactive) {
      _shutdownTor();
    }
  }


  bool _torStopped = false;

  Future<void> _shutdownTor() async {
    if (!_torStopped) {
      _torStopped = true;
      await widget.torManager.stopTor();
      print('Tor process stopped gracefully.');
    }
  }

  String encodeOnionToBase58(String onion) {
    // Remove trailing '.onion' if present
    final cleanOnion = onion.endsWith('.onion') ? onion.substring(0, onion.length - 6) : onion;

    // Convert string to UTF8 bytes
    final bytes = utf8.encode(cleanOnion);

    // Encode bytes into Base58 string
    return base58.encode(Uint8List.fromList(bytes));
  } 

  String decodeBase58ToOnion(String base58String) {
    final bytes = base58.decode(base58String);
    final onion = utf8.decode(bytes);
    return '$onion.onion';
  }

  void clearChat() {
    setState(() {
      loadUsers();
      selectedContact = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600; // You can tune this breakpoint

    if (isLoading) {
      return const Material(child: Center(child: CircularProgressIndicator()));
    }

    
    if (isMobile) {
       return Scaffold(
        appBar: AppBar(
          toolbarHeight: 70,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.asset(
                  'assets/logo.png',
                  height: 40.0,
                  width: 40.0,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${settings.name} Chat',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            )
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () {},
            ),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () => setState(() => showSettings = true)),
          ],
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.1),
        ),
        drawer: Drawer(
          child: buildSidebar(),
        ),
        body: Row(
          children: [
            Expanded(
              child: showProfile
                  ? ProfileScreen(
                      user: appUser,
                      onClose: () => setState(() => showProfile = false),
                      onUpdate: onUpdateProfile,
                      reloadUsers: () => loadUsers(),
                    )
                  : showSettings
                  ? SettingsScreen(
                      onClose: () => setState(() => showSettings = false),
                      onThemeChanged: onThemeChanged,
                      torManager: widget.torManager,
                    )
                  : selectedContact != null
                  ? ChatScreen(
                      userId: appUser.id,
                      userName: appUser.name,
                      peerId: selectedContact!.id,
                      peerName: selectedContact!.displayName,
                      peerAvatarBase64: selectedContact!.avatarBase64,
                      torManager: widget.torManager,
                      keyManager: widget.keyManager,
                      currentTheme: currentTheme,
                      clearChat: () => clearChat(),
                      reloadUsers: () => loadUsers(),
                      onCloseChat: () => clearChat(),
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              Icons.chat_bubble_outline,
                              size: 60,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Select a chat to start messaging',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton.icon(
                            onPressed: _showAddUserDialog,
                            icon: const Icon(Icons.add),
                            label: const Text('Add User'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Image.asset(
                'assets/logo.png',
                height: 40.0,
                width: 40.0,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${settings.name} Chat',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () {},
          ),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () => setState(() => showSettings = true)),
        ],
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: Row(
        children: [
          buildSidebar(),
          Expanded(
            child: showProfile
                ? ProfileScreen(
                    user: appUser,
                    onClose: () => setState(() => showProfile = false),
                    onUpdate: onUpdateProfile,
                    reloadUsers: () => loadUsers(),
                  )
                : showSettings
                ? SettingsScreen(
                    onClose: () => setState(() => showSettings = false),
                    onThemeChanged: onThemeChanged,
                    torManager: widget.torManager,
                  )
                : selectedContact != null
                ? ChatScreen(
                    userId: appUser.id,
                    userName: appUser.name,
                    peerId: selectedContact!.id,
                    peerName: selectedContact!.displayName,
                    peerAvatarBase64: selectedContact!.avatarBase64,
                    torManager: widget.torManager,
                    keyManager: widget.keyManager,
                    currentTheme: currentTheme,
                    clearChat: () => clearChat(),
                    reloadUsers: () => loadUsers(),
                    onCloseChat: () => clearChat(),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            Icons.chat_bubble_outline,
                            size: 60,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Select a chat to start messaging',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Your ${settings.name} ID: ${encodeOnionToBase58(appUser.id)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _showAddUserDialog,
                          icon: const Icon(Icons.add),
                          label: const Text('Add User'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
