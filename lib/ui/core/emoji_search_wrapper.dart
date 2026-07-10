import 'package:flutter/widgets.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show
    DefaultMaterialLocalizations,
    Theme,
    ThemeData,
    Material,
    MaterialType,
    Colors,
    Icons,
    GridView,
    SliverGridDelegateWithFixedCrossAxisCount,
    ColorScheme,
    Brightness,
    TextField,
    InputDecoration,
    OutlineInputBorder,
    IconButton,
    CircularProgressIndicator;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart'
    show getDefaultEmojiLocale;
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_style_resolver.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

/// Telegram-style emoji picker with always-visible search bar and Prysm theming.
class EmojiSearchWrapper extends StatefulWidget {
  final ValueChanged<String> onEmojiSelected;

  const EmojiSearchWrapper({required this.onEmojiSelected, super.key});

  @override
  State<EmojiSearchWrapper> createState() => _EmojiSearchWrapperState();
}

class _EmojiSearchWrapperState extends State<EmojiSearchWrapper> {
  final _searchController = TextEditingController();
  List<Emoji> _allEmojis = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadEmojis();
  }

  Future<void> _loadEmojis() async {
    final data = getDefaultEmojiLocale(const Locale('en'));
    final all = <Emoji>[];
    for (final cat in data) {
      all.addAll(cat.emoji);
    }
    if (mounted) {
      setState(() {
        _allEmojis = all;
        _loaded = true;
      });
    }
  }

  List<Emoji> _filteredEmojis(String query) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    return _allEmojis.where((e) {
      if (e.emoji.contains(q)) return true;
      for (final kw in e.keywords) {
        if (kw.toLowerCase().contains(q)) return true;
      }
      return e.name.toLowerCase().contains(q);
    }).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmTokens;
    final style = context.prysmStyle;
    final query = _searchController.text;
    final isSearching = query.isNotEmpty;

    return SizedBox(
      height: 280,
      child: Localizations(
        locale: const Locale('en', 'US'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: Theme(
          data: ThemeData(
            useMaterial3: true,
            canvasColor: Colors.transparent,
            scaffoldBackgroundColor: tokens.surface,
            colorScheme: ColorScheme(
              brightness: Brightness.light,
              primary: tokens.accent,
              onPrimary: tokens.onAccent,
              secondary: tokens.accent,
              onSecondary: tokens.onAccent,
              surface: tokens.surface,
              onSurface: tokens.textPrimary,
              error: tokens.danger,
              onError: tokens.onAccent,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Telegram-style search bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search emoji',
                      hintStyle: style.captionStyle
                          .copyWith(color: tokens.textMuted),
                      prefixIcon: Icon(
                        PrysmIcons.search,
                        size: 18,
                        color: tokens.textSecondary,
                      ),
                      suffixIcon: isSearching
                          ? IconButton(
                              icon: Icon(PrysmIcons.close,
                                  size: 16, color: tokens.textSecondary),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      filled: true,
                      fillColor: tokens.surfaceElevated,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: style.bodyStyle.copyWith(fontSize: 14),
                  ),
                ),
                // Emoji content
                Expanded(
                  child: !_loaded
                      ? Center(child: CircularProgressIndicator())
                      : isSearching
                          ? _buildSearchResults(tokens, query)
                          : _buildEmojiGrid(tokens, style),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiGrid(PrysmTokens tokens, PrysmResolvedStyle style) {
    return EmojiPicker(
      onEmojiSelected: (category, emoji) {
        widget.onEmojiSelected(emoji.emoji);
      },
      config: Config(
        height: null,
        checkPlatformCompatibility: false,
        emojiTextStyle: TextStyle(
          fontFamily: 'NotoEmoji',
          fontSize: 26,
        ),
        emojiViewConfig: EmojiViewConfig(
          backgroundColor: tokens.surface,
          verticalSpacing: 4,
          horizontalSpacing: 4,
          gridPadding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        categoryViewConfig: CategoryViewConfig(
          backgroundColor: tokens.surface,
          iconColor: tokens.textMuted,
          iconColorSelected: tokens.accent,
          indicatorColor: tokens.accent,
          backspaceColor: tokens.textSecondary,
          dividerColor: tokens.divider.withValues(alpha: 0.3),
          tabBarHeight: 42,
          // Icone semanticamente pertinenti per ogni categoria: Cupertino-first
          // (coerente con il resto della UI Prysm), con un fallback dal set
          // Material solo per il cibo (Cupertino non ha una glifo dedicato).
          // Le icone Cupertino sono distribuite dal package cupertino_icons,
          // mentre Icons.restaurant funziona perché emoji_picker_flutter
          // carica transitivamente il font Material.
          categoryIcons: const CategoryIcons(
            recentIcon: CupertinoIcons.time,
            smileyIcon: CupertinoIcons.smiley,
            animalIcon: CupertinoIcons.paw,
            foodIcon: Icons.restaurant,
            activityIcon: CupertinoIcons.gamecontroller,
            travelIcon: CupertinoIcons.airplane,
            objectIcon: CupertinoIcons.lightbulb,
            symbolIcon: CupertinoIcons.bolt,
            flagIcon: CupertinoIcons.flag,
          ),
        ),
        bottomActionBarConfig: const BottomActionBarConfig(
          enabled: false,
        ),
      ),
    );
  }

  Widget _buildSearchResults(PrysmTokens tokens, String query) {
    final results = _filteredEmojis(query);
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No emoji found',
          style: TextStyle(color: tokens.textMuted, fontSize: 14),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        return GestureDetector(
          onTap: () => widget.onEmojiSelected(results[index].emoji),
          child: Text(
            results[index].emoji,
            style: const TextStyle(fontSize: 26, fontFamily: 'NotoEmoji'),
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }
}
