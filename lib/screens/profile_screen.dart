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
    );
    widget.onUpdate(updatedUser);
    widget.onClose();
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
        child: Column(
          children: [
            CircleAvatar(
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
            ),
            // Additional fields like avatar upload can be added here
          ],
        ),
      ),
    );
  }
}
