import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
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
  final messageServer = MessageHttpServer(port: 12345);
  messageServer.start();

  // Try to create/get hidden service onion address as user ID
  late String onionAddress;
  try {
    onionAddress = await torManager.createHiddenService(12345, 12345);
  } catch (e) {
    print('Failed to create hidden service: $e');
    onionAddress = 'me'; // fallback user id
  }

  runApp(MyApp(torManager: torManager, onionAddress: onionAddress));
}

class MyApp extends StatelessWidget {
  final TorManager torManager;
  final String onionAddress;

  const MyApp({
    required this.torManager,
    required this.onionAddress,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tor Chat App',
      home: HomeScreen(torManager: torManager, onionAddress: onionAddress),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final TorManager torManager;
  final String onionAddress;

  const HomeScreen({required this.torManager, required this.onionAddress, Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<Contact> contacts = [];
  late Contact appUser;
  Contact? selectedContact;
  bool showProfile = false;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    appUser = Contact(id: widget.onionAddress, name: 'My Profile', avatarUrl: '');
    loadUsers();
  }

  Future<void> loadUsers() async {
    final userMaps = await DBHelper.getUsers();

    setState(() {
      contacts = userMaps
          .map((map) =>
              Contact(id: map['id'], name: map['name'], avatarUrl: map['avatarUrl']))
          .toList();

      // Replace the user with current Tor onion address if it exists
      try {
        final me = contacts.firstWhere((c) => c.id == widget.onionAddress);
        appUser = me;
      } catch (_) {
        // Save appUser if not in DB yet
        saveAppUser(appUser);
      }

      isLoading = false;
    });
  }

  void saveAppUser(Contact user) async {
    await DBHelper.insertOrUpdateUser({
      'id': user.id,
      'name': user.name,
      'avatarUrl': user.avatarUrl,
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
              final newId = idController.text.trim();
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
    final newUser = Contact(id: id, name: name, avatarUrl: '');
    await DBHelper.insertOrUpdateUser({
      'id': newUser.id,
      'name': newUser.name,
      'avatarUrl': newUser.avatarUrl,
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

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Material(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
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
                      )
                    : Center(
                        child: Text(
                          'Welcome, your Tor ID is:\n${appUser.id}',
                          textAlign: TextAlign.center,
                        ),
                      ),
          )
        ],
      ),
    );
  }
}
