import 'package:flutter/widgets.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
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
    final tokens = context.prysmStyle.tokens;
    final isDark = tokens.brightness == Brightness.dark;
    final cachedImage = AvatarImageCache.imageForBase64(avatarBase64);
    final size = radius * 2;

    if (cachedImage != null) {
      return RepaintBoundary(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            image: DecorationImage(image: cachedImage, fit: BoxFit.cover),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark ? tokens.accentMuted : tokens.accent,
        ),
        alignment: Alignment.center,
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: tokens.onAccent,
            fontWeight: FontWeight.bold,
            fontSize: radius * 0.8,
          ),
        ),
      ),
    );
  }
}
