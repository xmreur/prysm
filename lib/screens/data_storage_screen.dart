import 'package:flutter/widgets.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/downloads_files_screen.dart';
import 'package:prysm/screens/storage_media_browser_screen.dart';
import 'package:prysm/services/storage_usage_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/prysm_section.dart';
import 'package:prysm/util/format_file_size.dart';
import 'package:prysm/util/key_manager.dart';

class DataStorageScreen extends StatefulWidget {
  final VoidCallback onClose;
  final String? userId;
  final KeyManager? keyManager;

  const DataStorageScreen({
    required this.onClose,
    this.userId,
    this.keyManager,
    super.key,
  });

  @override
  State<DataStorageScreen> createState() => _DataStorageScreenState();
}

class _DataStorageScreenState extends State<DataStorageScreen> {
  StorageUsageBreakdown? _breakdown;
  int? _mediaItemCount;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final breakdown = await StorageUsageService.compute();
      final mediaCount = await MessagesDb.countAllMediaMessages();
      if (!mounted) return;
      setState(() {
        _breakdown = breakdown;
        _mediaItemCount = mediaCount;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showPrysmToast(context, 'Could not load storage usage: $e');
    }
  }

  Future<void> _clearCaches() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Clear caches',
      content: const Text(
        'Delete temporary image and voice caches? '
        'Media will be re-decrypted when opened again.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Clear',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;

    await StorageUsageService.clearEphemeralCaches();
    if (!mounted) return;
    showPrysmToast(context, 'Caches cleared');
    await _refresh();
  }

  Future<void> _openChatMedia() async {
    final userId = widget.userId;
    final keyManager = widget.keyManager;
    if (userId == null || keyManager == null) {
      showPrysmToast(context, 'Storage manager unavailable');
      return;
    }

    await Navigator.push(
      context,
      PrysmPageRoute(
        page: StorageMediaBrowserScreen(
          userId: userId,
          keyManager: keyManager,
          mediaItemCount: _mediaItemCount,
          onClose: () async {
            Navigator.of(context).pop();
            await _refresh();
          },
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openDownloads() async {
    await Navigator.push(
      context,
      PrysmPageRoute(
        page: DownloadsFilesScreen(
          onClose: () async {
            Navigator.of(context).pop();
            await _refresh();
          },
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;
    final breakdown = _breakdown;

    return PrysmPage(
      title: 'Storage Manager',
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: _loading && breakdown == null
          ? const Center(child: PrysmProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(PrysmTokens.spacing16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Storage Usage', style: style.headlineStyle),
                    const SizedBox(height: 20),
                    PrysmSection(
                      children: [
                        PrysmListRow(
                          leading: const Icon(PrysmIcons.storageOutlined),
                          title: 'Total',
                          subtitle: breakdown != null
                              ? formatFileSize(breakdown.totalBytes)
                              : 'Calculating…',
                        ),
                        if (breakdown != null) ...[
                          PrysmListRow(
                            leading: const Icon(PrysmIcons.chatBubbleOutline),
                            title: 'Chat media',
                            subtitle: formatFileSize(breakdown.chatMediaBytes),
                            trailing: const Icon(
                              PrysmIcons.arrowForwardIos,
                              size: 16,
                            ),
                            onTap: _openChatMedia,
                          ),
                          PrysmListRow(
                            leading: const Icon(PrysmIcons.downloadOutlined),
                            title: 'Downloads',
                            subtitle: formatFileSize(breakdown.downloadsBytes),
                            trailing: const Icon(
                              PrysmIcons.arrowForwardIos,
                              size: 16,
                            ),
                            onTap: _openDownloads,
                          ),
                          PrysmListRow(
                            leading: const Icon(PrysmIcons.refreshOutlined),
                            title: 'Caches',
                            subtitle: formatFileSize(breakdown.cacheBytes),
                            trailing: PrysmButton(
                              label: 'Clear',
                              variant: PrysmButtonVariant.danger,
                              onPressed: _clearCaches,
                            ),
                          ),
                          PrysmListRow(
                            leading: const Icon(PrysmIcons.folderOpenOutlined),
                            title: 'Other app data',
                            subtitle:
                                formatFileSize(breakdown.otherAppDataBytes),
                          ),
                        ],
                      ],
                    ),
                    if (_loading) ...[
                      const SizedBox(height: 16),
                      const Center(child: PrysmProgressIndicator(size: 20)),
                    ],
                    const SizedBox(height: 30),
                    Container(
                      padding: const EdgeInsets.all(PrysmTokens.spacing16),
                      decoration: BoxDecoration(
                        color: style.tokens.surface,
                        borderRadius:
                            BorderRadius.circular(PrysmTokens.radiusCard),
                      ),
                      child: Text(
                        'Chat media is stored encrypted on this device. '
                        'Deleting media here removes it locally only — '
                        'it may still exist for other participants.',
                        style: style.bodyStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
