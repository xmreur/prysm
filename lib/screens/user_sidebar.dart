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
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.grey[100],
        border: Border(
          right: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
            width: 1
          ),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                ),
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context).primaryColor,
                  child: const Text(
                    'P',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded( 
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "My Profile",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Online',
                        style: TextStyle(
                          color: Colors.teal,
                          fontSize: 12,
                          fontWeight: FontWeight.w500
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF2D2D2D)
                    : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: const TextField(
                decoration: InputDecoration(
                  hintText: 'Search chats...',
                  hintStyle: TextStyle(fontSize: 14),
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Contacts list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: contacts.length,
              itemBuilder: (_, index) {
                final contact = contacts[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      radius: 22,
                      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).primaryColorLight : Theme.of(context).primaryColor,
                      child: Text(
                        contact.name.isNotEmpty
                            ? contact.name[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: Theme.of(context).primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      contact.name,
                      style: TextStyle(
                        fontWeight: selectedContact?.id == contact.id
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    subtitle: const Text(
                      'Last message...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: selectedContact?.id == contact.id,
                    selectedTileColor: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onTap: () => onContactSelected(contact),
                  ),
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
                  width: 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () {},
                  tooltip: 'Settings',
                ),
                IconButton(
                  icon: const Icon(Icons.person_outline),
                  onPressed: () {},
                  tooltip: 'Profile',
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: onAddUser,
                  tooltip: 'Add User',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
