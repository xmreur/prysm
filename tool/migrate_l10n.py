#!/usr/bin/env python3
"""Migrate hardcoded English strings to context.l10n / SettingsService().localizations."""
import json
import re
from pathlib import Path

with open('lib/l10n/app_en.arb', encoding='utf-8') as f:
    arb = json.load(f)

value_to_key = {}
for k, v in arb.items():
    if k.startswith('@') or k == '@@locale':
        continue
    if v not in value_to_key or len(k) < len(value_to_key[v]):
        value_to_key[v] = k

roots = [
    Path('lib/screens'),
    Path('lib/ui'),
    Path('lib/util'),
    Path('lib/services/tray_service.dart'),
    Path('lib/util/notification_service.dart'),
    Path('lib/util/schedule_time_format.dart'),
    Path('lib/util/file_download_helper.dart'),
    Path('lib/util/log_export_helper.dart'),
    Path('lib/util/biometrics.dart'),
    Path('lib/util/reply_preview_label.dart'),
    Path('lib/util/message_preview_label.dart'),
    Path('lib/util/notification_preview.dart'),
    Path('lib/util/image_download_helper.dart'),
    Path('lib/ui/core/prysm_text_selection.dart'),
    Path('lib/services/notification_mute_service.dart'),
]

SERVICE_FILES = {
    'lib/services/tray_service.dart',
    'lib/util/notification_service.dart',
    'lib/util/schedule_time_format.dart',
    'lib/services/notification_mute_service.dart',
    'lib/util/log_export_helper.dart',
    'lib/util/biometrics.dart',
    'lib/util/reply_preview_label.dart',
    'lib/util/message_preview_label.dart',
    'lib/util/notification_preview.dart',
    'lib/util/image_download_helper.dart',
    'lib/util/file_download_helper.dart',
}

L10N_IMPORT = "import 'package:prysm/l10n/l10n_extensions.dart';\n"
SETTINGS_IMPORT = "import 'package:prysm/services/settings_service.dart';\n"


def add_import(content: str, import_line: str) -> str:
    if import_line.strip() in content:
        return content
    lines = content.split('\n')
    last_import = 0
    for i, line in enumerate(lines):
        if line.startswith('import '):
            last_import = i
    lines.insert(last_import + 1, import_line.rstrip())
    return '\n'.join(lines)


def l10n_expr(key: str, is_service: bool) -> str:
    if is_service:
        return f'SettingsService().localizations.{key}'
    return f'context.l10n.{key}'


def replace_simple_strings(content: str, filepath: str) -> tuple[str, int]:
    is_service = filepath in SERVICE_FILES
    changes = 0

    for value, key in sorted(value_to_key.items(), key=lambda x: -len(x[0])):
        if '{' in value or '$' in value:
            continue
        if len(value) < 3:
            continue
        esc = re.escape(value)
        expr = l10n_expr(key, is_service)

        replacements = [
            (rf"title:\s*'{esc}'", f'title: {expr}'),
            (rf"label:\s*'{esc}'", f'label: {expr}'),
            (rf"subtitle:\s*'{esc}'", f'subtitle: {expr}'),
            (rf"tooltip:\s*'{esc}'", f'tooltip: {expr}'),
            (rf"labelText:\s*'{esc}'", f'labelText: {expr}'),
            (rf"hintText:\s*'{esc}'", f'hintText: {expr}'),
            (rf"barrierLabel:\s*'{esc}'", f'barrierLabel: {expr}'),
            (rf"return\s+'{esc}'", f'return {expr}'),
            (rf"error\s*=\s*'{esc}'", f'error = {expr}'),
            (rf"_error\s*=\s*'{esc}'", f'_error = {expr}'),
            (rf"_setupError\s*=\s*'{esc}'", f'_setupError = {expr}'),
            (rf"Text\(\s*'{esc}'\s*\)", f'Text({expr})'),
            (rf"_buildSectionHeader\('{esc}'\)", f'_buildSectionHeader({expr})'),
            (rf"_buildSearchSectionHeader\('{esc}'\)", f'_buildSearchSectionHeader({expr})'),
            (rf"showPrysmToast\(context,\s*'{esc}'\)", f'showPrysmToast(context, {expr})'),
            (rf"PrysmButton\(label:\s*'{esc}'", f'PrysmButton(label: {expr}'),
            (rf"PrysmTextButton\(label:\s*'{esc}'", f'PrysmTextButton(label: {expr}'),
            (rf"defaultActionName:\s*'{esc}'", f'defaultActionName: {expr}'),
            (rf"appName:\s*'{esc}'", f'appName: {expr}'),
            (rf"name:\s*'{esc}'", f'name: {expr}'),
            (rf"description:\s*'{esc}'", f'description: {expr}'),
            (rf"MenuItem\(\s*label:\s*'{esc}'", f'MenuItem(label: {expr}'),
            (rf"MenuItem\(label:\s*'{esc}'", f'MenuItem(label: {expr}'),
        ]

        for pat, repl in replacements:
            new_content, n = re.subn(pat, repl, content)
            if n:
                content = new_content
                changes += n

    if changes > 0:
        if not is_service and 'l10n_extensions.dart' not in content:
            content = add_import(content, L10N_IMPORT)
        if is_service and 'settings_service.dart' not in content:
            content = add_import(content, SETTINGS_IMPORT)

    return content, changes


total = 0
for root in roots:
    files = [root] if root.is_file() else list(root.rglob('*.dart'))
    for f in files:
        rel = str(f).replace('\\', '/')
        try:
            orig = f.read_text(encoding='utf-8')
        except OSError:
            continue
        new, n = replace_simple_strings(orig, rel)
        if n > 0:
            f.write_text(new, encoding='utf-8')
            total += n
            print(f'{rel}: {n}')

print(f'Total replacements: {total}')
