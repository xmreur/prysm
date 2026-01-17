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
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_db_helper.dart';
import 'package:prysm/util/updater_downloader.dart';
import 'screens/chat_screen.dart';
import 'util/db_helper.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'util/tor_service.dart'; // Updated Tor service
import 'util/tor_downloader.dart';
import 'screens/profile_screen.dart';
import 'models/contact.dart';
import 'util/theme_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'util/notification_service.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();
  
  if (Platform.isAndroid) {
    final androidConfig = FlutterBackgroundAndroidConfig(
      notificationTitle: "Prysm Chat is running",
      notificationText: "Prysm chat is actively waiting for new messages",
      notificationImportance: AndroidNotificationImportance.normal,
      notificationIcon: AndroidResource(name: "icon", defType: "drawable"),
    );
    await FlutterBackground.initialize(androidConfig: androidConfig);

    await FlutterBackground.enableBackgroundExecution();
  }

  var torPath = ""; 
  if (!Platform.isAndroid) {
    await UpdaterDownloader().getOrDownloadUpdater();
    checkForUpdatesAndLaunchUpdater();

    // Download or get local Tor executable path
    final torDownloader = TorDownloader();
    torPath = await torDownloader.getOrDownloadTor();
  } else {
    torPath = "";
  }

  final documentsDir = await getApplicationDocumentsDirectory();
  final dataDirPath = p.join(documentsDir.path, 'prysm', 'tor_executable', 'tor_data');

  final dataDir = Directory(dataDirPath);
  if (!dataDir.existsSync()) {
    dataDir.createSync(recursive: true);
  }
  // Initialize Tor manager
  final torManager = TorManager(
    torPath: torPath,
    dataDir: dataDirPath,
    controlPassword: 'your_strong_password_here',
  );

  await torManager.startTor();


  // Start the HTTP server for incoming message listener on hidden service port
  
  final keyManager = KeyManager();


  final messageServer = PrysmServer(port: 12345, keyManager: keyManager);
  messageServer.start();

  // Try to create/get hidden service onion address as user ID
  late String onionAddress;
  try {
    onionAddress = (await torManager.getOnionAddress())!;
  } catch (e) {
    print('Failed to create hidden service: $e');
    onionAddress = 'me'; // fallback user id
  }

  windowManager.addListener(MyWindowListener(torManager));

  runApp(MyApp(torManager: torManager, onionAddress: onionAddress, keyManager: keyManager));

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


const String currentVersion = "v0.0.7";

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
    // Your cleanup code here — will be called on window close
    await torManager.stopTor();
    windowManager.destroy();
  }
}

class MyApp extends StatefulWidget {

  final TorManager torManager;
  final String onionAddress;
  final KeyManager keyManager;

  const MyApp({
    required this.torManager,
    required this.onionAddress,
    required this.keyManager,
    super.key,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {

  bool unlocked = false;
  int _currentTheme = 0;

  Future<bool> onVerifyPin(String pin) async {
    // 1. Unlock and decrypt private key with pin
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
  }

  Future<void> _loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeIndex = prefs.getInt("custom_theme") ?? 0;
    setState(() {
      _currentTheme = themeIndex;
    });
  }

  void updateTheme(int themeIndex) {
    setState(() {
      _currentTheme = themeIndex;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!unlocked) {
      return MaterialApp(
        title: "Unlock Prysm Chat App",
        home: PinScreen(onVerifyPin: onVerifyPin, isSetupMode: widget.keyManager.isPinSet(),)
      );
    }
    return MaterialApp(
      title: 'Prysm Chat App',
      theme: ThemeManager.getTheme(_currentTheme),
      home: HomeScreen(torManager: widget.torManager, onionAddress: widget.onionAddress, keyManager: widget.keyManager, onThemeChanged: updateTheme, currentTheme: _currentTheme),
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
  List<Contact> contacts = [];
  late Contact appUser;
  Contact? selectedContact;
  bool showProfile = false;
  bool showSettings = false;
  bool isLoading = true;
  int currentTheme = 0; // 0: Light, 1: Dark, 2: Pink, 3: Cyan, 4: Purple, 5 Orange
  

  Timer? _refreshTimer;

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
    List<Contact> newContacts = [];
    
    for (var map in userMaps) {
      String id = map['id'];
      String name = map['name'];
      String avatarUrl = '';
      String? publicKeyPem = map['publicKeyPem'];
      int? lastMessageTimestamp = await MessagesDb.getLastMessageTimestampForUser(id);
      
      // If publicKeyPem is null or empty, try to fetch it using TorHttpClient
      if (publicKeyPem == null || publicKeyPem.isEmpty) {
        try {
          final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
          final uri = Uri.parse("http://$id:80/public");
          final response = await torClient.get(uri, {});
          publicKeyPem = await response.transform(utf8.decoder).join();
          torClient.close();

          // Update DB with fetched publicKeyPem
          await DBHelper.insertOrUpdateUser({
            'id': id,
            'name': name,
            'avatarUrl': avatarUrl,
            'publicKeyPem': publicKeyPem,
          });
        } catch (e) {
          print("Failed to fetch public key for $id: $e");
          publicKeyPem = ""; // fallback empty string to avoid null
        }
      }

      newContacts.add(Contact(id: id, name: name, avatarUrl: avatarUrl, publicKeyPem: publicKeyPem, lastMessageTimestamp: lastMessageTimestamp));
    }

    // Replace the user with current Tor onion address if it exists
    Contact? newAppUser;
    try {
      newAppUser = newContacts.firstWhere((c) => c.id == widget.onionAddress);
    } catch (_) {
      // Save appUser if not in DB yet
      saveAppUser(appUser);
    }

    // Check if contacts have changed (simple length or content check)
    bool contactsChanged = newContacts.length != contacts.length ||
        !newContacts.every((c) => contacts.any((old) => old.id == c.id && old.name == c.name && formatLastMessageTime(old.lastMessageTimestamp) == formatLastMessageTime(c.lastMessageTimestamp)));

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
      'publicKeyPem': user.publicKeyPem
    });
  }

  void onUpdateProfile(Contact updatedUser) {
    setState(() {
      appUser = updatedUser;
    });
    saveAppUser(updatedUser);
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
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
    try {
      final peerOnion = id; // full onion address
      final uri = Uri.parse("http://$peerOnion:80/public");

      final response = await torClient.get(uri, {});
      publicKeyPem = await response.transform(utf8.decoder).join();

      print("Fetched public key from $peerOnion");
    } catch (e) {
      print("Failed to fetch public key from $id: $e");
      publicKeyPem = ""; // fallback empty, so we can retry later
    } finally {
      torClient.close();
    }

    final newUser = Contact(id: id, name: name, avatarUrl: '', publicKeyPem: publicKeyPem);
    await DBHelper.insertOrUpdateUser({
      'id': newUser.id,
      'name': newUser.name,
      'avatarUrl': newUser.avatarUrl,
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
        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.grey[100],
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
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).primaryColorLight : Theme.of(context).primaryColor,
                  child: Text(
                    appUser.name.isNotEmpty ? appUser.name[0].toLowerCase() : 'P',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
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
                      const SizedBox(height: 2,),
                      Text(
                        'GHOST',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      )
                    ],
                  ),
                )
              ],
            ),
          ),
          const SizedBox(height: 8,),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF2D2D2D) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4
                  )
                ]
              ),
              child: const TextField(
                decoration: InputDecoration(
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
          const SizedBox(height: 8,),
          // Contact Lsit
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: contacts.length,
              itemBuilder: (_, index) {
                final contact = contacts[index];
                if (contact.id == appUser.id) return const SizedBox.shrink();
                return Padding(
                  key: ValueKey('${contact.id}_${contact.lastMessageTimestamp ?? 0}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2
                  ),
                  child: ListTile(
                    key: ValueKey('${contact.id}_${contact.lastMessageTimestamp ?? 0}'),
                    leading: CircleAvatar(
                      radius: 22,
                      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).primaryColorLight : Theme.of(context).primaryColor,
                      child: Text(
                        contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?',
                        style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).hintColor : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      contact.name,
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
              const Text(
                'Prysm Chat',
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
                    )
                  : selectedContact != null
                  ? ChatScreen(
                      userId: appUser.id,
                      userName: appUser.name,
                      peerId: selectedContact!.id,
                      peerName: selectedContact!.name,
                      torManager: widget.torManager,
                      keyManager: widget.keyManager,
                      currentTheme: currentTheme,
                      clearChat: () => clearChat(),
                      reloadUsers: () => loadUsers(),
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
            const Text(
              'Prysm Chat',
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
                  )
                : selectedContact != null
                ? ChatScreen(
                    userId: appUser.id,
                    userName: appUser.name,
                    peerId: selectedContact!.id,
                    peerName: selectedContact!.name,
                    torManager: widget.torManager,
                    keyManager: widget.keyManager,
                    currentTheme: currentTheme,
                    clearChat: () => clearChat(),
                    reloadUsers: () => loadUsers(),
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
                          'Your Prysm ID: ${encodeOnionToBase58(appUser.id)}',
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
