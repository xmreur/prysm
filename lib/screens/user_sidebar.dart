import 'package:flutter/material.dart';
import '../models/contact.dart'; // adjust the relative path

typedef ContactSelectedCallback = void Function(Contact);

class UserSidebar extends StatelessWidget {
  final List<Contact> contacts;
  final Contact? selectedContact;
  final ContactSelectedCallback onContactSelected;
  final VoidCallback onAddUser;

  const UserSidebar({
    required this.contacts,
    required this.selectedContact,
    required this.onContactSelected,
    required this.onAddUser,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.grey[200]!,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: contacts.length,
              itemBuilder: (_, i) {
                final contact = contacts[i];
                return ListTile(
                  leading: CircleAvatar(child: Text(contact.name.isNotEmpty ? contact.name[0] : '?')),
                  title: Text(contact.name),
                  selected: selectedContact?.id == contact.id,
                  onTap: () => onContactSelected(contact),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add User'),
              onPressed: onAddUser,
            ),
          )
        ],
      ),
    );
  }
}
