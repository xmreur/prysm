import 'dart:convert';
import 'dart:typed_data';

import 'package:bs58/bs58.dart';
import 'package:flutter/material.dart';
import '../models/contact.dart'; // adjust the relative path


typedef ValueChanged<T> = void Function(T value);

class ProfileScreen extends StatefulWidget {
  final Contact user;
  final VoidCallback onClose;
  
  final ValueChanged<Contact> onUpdate;

  const ProfileScreen({
    required this.user,
    required this.onClose,
    required this.onUpdate,
    Key? key,
  }) : super(key: key);

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _saveProfile() {
    final updatedUser = Contact(
      id: widget.user.id,
      name: _nameController.text,
      avatarUrl: widget.user.avatarUrl,
      publicKeyPem: widget.user.publicKeyPem,
    );
    widget.onUpdate(updatedUser);
    widget.onClose();
  }

  
  String encodeOnionToBase58(String onion) {
    // Remove trailing '.onion' if present
    final cleanOnion = onion.endsWith('.onion') ? onion.substring(0, onion.length - 6) : onion;

    // Convert string to UTF8 bytes
    final bytes = utf8.encode(cleanOnion);

    // Encode bytes into Base58 string
    return base58.encode(Uint8List.fromList(bytes));
  } 
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
        actions: [IconButton(icon: const Icon(Icons.save), onPressed: _saveProfile)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            children: [
              /*CircleAvatar(
                radius: 60,
                child: Text(
                  widget.user.name.isNotEmpty ? widget.user.name[0] : '?',
                  style: const TextStyle(fontSize: 40),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ), */
              Padding(padding: EdgeInsetsGeometry.all(30)),
              Text("Your ID:", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              SelectableText(encodeOnionToBase58(widget.user.id), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              // Additional fields like avatar upload can be added here
            ],
          ),
        ) 
      ),
    );
  }
}
