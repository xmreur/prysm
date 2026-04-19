import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

class ContactAvatar extends StatelessWidget {
  final String name;
  final double radius;
  final String? avatarBase64;

  const ContactAvatar({
    required this.name,
    this.radius = 22,
    this.avatarBase64,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (avatarBase64 != null && avatarBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(avatarBase64!);
        return CircleAvatar(
          radius: radius,
          backgroundImage: MemoryImage(Uint8List.fromList(bytes)),
          backgroundColor: Colors.transparent,
        );
      } catch (_) {
        // Fall through to letter avatar
      }
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: isDark
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.primary,
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: isDark
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.8,
        ),
      ),
    );
  }
}
