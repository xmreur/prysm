import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:open_file/open_file.dart';
import 'package:prysm/services/storage_usage_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/ui/prysm_section.dart';
import 'package:prysm/util/format_file_size.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class DownloadsFilesScreen extends StatefulWidget {
  final VoidCallback onClose;

  const DownloadsFilesScreen({required this.onClose, super.key});

  @override
  State<DownloadsFilesScreen> createState() => _DownloadsFilesScreenState();
}

class _DownloadsFilesScreenState extends State<DownloadsFilesScreen> {
  List<DownloadedFileEntry> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final files = await StorageUsageService.listDownloadedFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showPrysmToast(context, 'Could not load downloads: $e');
    }
  }

  IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return PrysmIcons.pictureAsPdf;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return PrysmIcons.imageOutlined;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
      return PrysmIcons.videocamOutlined;
    }
    return PrysmIcons.insertDriveFileOutlined;
  }

  Future<void> _openFile(DownloadedFileEntry entry) async {
    final result = await OpenFile.open(entry.path);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      showPrysmToast(context, result.message);
    }
  }

  Future<void> _deleteFile(DownloadedFileEntry entry) async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: context.l10n.deleteFile,
      content: Text(context.l10n.deleteFileFromDownloads(entry.name)),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.delete,
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;

    try {
      await File(entry.path).delete();
      if (!mounted) return;
      setState(() => _files.removeWhere((f) => f.path == entry.path));
      showPrysmToast(context, context.l10n.fileDeleted);
    } catch (e) {
      if (!mounted) return;
      showPrysmToast(context, 'Could not delete file: $e');
    }
  }

  String _formatDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    final style = context.prysmStyle;

    return PrysmPage(
      title: context.l10n.downloads,
      headerHeight: 70,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : _files.isEmpty
              ? Center(
                  child: Text(
                    'No downloaded files',
                    style: TextStyle(color: style.tokens.textMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(PrysmTokens.spacing16),
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final entry = _files[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: PrysmSection(
                        children: [
                          PrysmListRow(
                            leading: Icon(_iconFor(entry.name)),
                            title: entry.name,
                            subtitle:
                                '${formatFileSize(entry.bytes)} · ${_formatDate(entry.modifiedAt)}',
                            onTap: () => _openFile(entry),
                            trailing: PrysmIconButton(
                              icon: PrysmIcons.deleteOutline,
                              onPressed: () => _deleteFile(entry),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
