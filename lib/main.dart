import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/util/base58_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'screens/chat_screen.dart';
import 'util/db_helper.dart';
import 'util/message_db_helper.dart';
import 'util/message_http_server.dart';
import 'util/message_http_client.dart';
import 'util/tor_service.dart'; // Updated Tor service
import 'util/tor_downloader.dart';
import 'screens/profile_screen.dart';
import 'models/contact.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Download or get local Tor executable path
  final torDownloader = TorDownloader();
  final torPath = await torDownloader.getOrDownloadTor();

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
  await keyManager.initKeys();

  final messageServer = MessageHttpServer(port: 12345, keyManager: keyManager);
  messageServer.start();

  // Try to create/get hidden service onion address as user ID
  late String onionAddress;
  try {
    onionAddress = await torManager.getOnionAddress();
  } catch (e) {
    //print('Failed to create hidden service: $e');
    onionAddress = 'me'; // fallback user id
  }

  runApp(MyApp(torManager: torManager, onionAddress: onionAddress, keyManager: keyManager));
}

class MyApp extends StatelessWidget {
  final TorManager torManager;
  final String onionAddress;
  final KeyManager keyManager;

  const MyApp({
    required this.torManager,
    required this.onionAddress,
    required this.keyManager,
    Key? key,
  }) : super(key: key);


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Prysm Chat App',
      home: HomeScreen(torManager: torManager, onionAddress: onionAddress, keyManager: keyManager),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final TorManager torManager;
  final String onionAddress;
  final KeyManager keyManager;

  const HomeScreen({required this.torManager, required this.onionAddress, required this.keyManager, super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Contact> contacts = [];
  late Contact appUser;
  Contact? selectedContact;
  bool showProfile = false;
  bool isLoading = true;
  

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    appUser = Contact(id: widget.onionAddress, name: 'My Profile', avatarUrl: '', publicKeyPem: 'NONE');
    loadUsers();
    _startAutoRefresh();
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

      // If publicKeyPem is null or empty, try to fetch it using TorHttpClient
      if (publicKeyPem == null || publicKeyPem.isEmpty) {
        try {
          final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
          final uri = Uri.parse("http://$id:12345/public");
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
          // print("Failed to fetch public key for $id: $e");
          publicKeyPem = ""; // fallback empty string to avoid null
        }
      }

      newContacts.add(Contact(id: id, name: name, avatarUrl: avatarUrl, publicKeyPem: publicKeyPem ?? ""));
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
        !newContacts.every((c) => contacts.any((old) => old.id == c.id && old.name == c.name));

    if (contactsChanged) {
      setState(() {
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
  }

  void onSelectContact(Contact contact) {
    setState(() {
      selectedContact = contact;
      showProfile = false;
    });
  }

  void onShowProfile() {
    setState(() {
      showProfile = true;
    });
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
              final newId = decodeBase58ToOnion(idController.text.trim());
              final newName = nameController.text.trim();
              if (newId.isEmpty || newName.isEmpty) {
                return;
              }
              _addNewUser(newId, newName);
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
      final uri = Uri.parse("http://$peerOnion:12345/public");

      final response = await torClient.get(uri, {});
      publicKeyPem = await response.transform(utf8.decoder).join();

      //print("Fetched public key from $peerOnion");
    } catch (e) {
      //print("Failed to fetch public key from $id: $e");
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

  Widget buildSidebar() {
    return Container(
      width: 300,
      color: Colors.grey[200],
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: contacts.length,
              itemBuilder: (_, index) {
                final contact = contacts[index];
                if (contact.id == appUser.id) return const SizedBox.shrink();
                return ListTile(
                  leading: CircleAvatar(
                      child:
                          Text(contact.name.isNotEmpty ? contact.name[0] : '?')),
                  title: Text(contact.name),
                  selected: selectedContact?.id == contact.id,
                  onTap: () => onSelectContact(contact),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add User'),
              onPressed: _showAddUserDialog,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
              ),
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
      // print('Tor process stopped gracefully.');
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

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Material(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.file(File('assets/logo.png'), height: 48.0, width: 48.0,),
            const Text('Chats'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: onShowProfile,
          ),
        ],
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
                  )
                : selectedContact != null
                    ? ChatScreen(
                        userId: appUser.id,
                        userName: appUser.name,
                        peerId: selectedContact!.id,
                        peerName: selectedContact!.name,
                        torManager: widget.torManager,
                        keyManager: widget.keyManager,
                      )
                    : Center(
                        child: SelectableText(
                          'Welcome, your Tor ID is:\n${encodeOnionToBase58(appUser.id)}',
                          textAlign: TextAlign.center,
                        ),
                      ),
          )
        ],
      ),
    );
  }
}
