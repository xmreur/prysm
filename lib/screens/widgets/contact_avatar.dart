import 'package:flutter/material.dart';
import 'package:prysm/util/avatar_image_cache.dart';

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
    final cachedImage = AvatarImageCache.imageForBase64(avatarBase64);

    if (cachedImage != null) {
      return RepaintBoundary(
        child: CircleAvatar(
          radius: radius,
          backgroundImage: cachedImage,
          backgroundColor: Colors.transparent,
        ),
      );
    }

    return RepaintBoundary(
      child: CircleAvatar(
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
      ),
    );
  }
}
