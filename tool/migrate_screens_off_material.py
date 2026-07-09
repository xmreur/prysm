#!/usr/bin/env python3
"""Migrate lib/screens/ Dart files off Material UI widgets."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "lib" / "screens"

ICON_SUFFIX_MAP = {
    "_outlined": "Outlined",
    "_rounded": "Rounded",
    "_outline": "Outline",
}

# Material icon snake_case -> PrysmIcons camelCase member
MATERIAL_ICON_MAP = {
    "add_circle_outline": "addCircle",
    "archive_outlined": "archive",
    "arrow_back": "arrowBack",
    "arrow_forward_ios": "arrowForwardIos",
    "attach_file": "attachFile",
    "auto_awesome_outlined": "autoAwesome",
    "auto_fix_high_outlined": "autoAwesome",
    "backspace_outlined": "backspaceOutlined",
    "backup_outlined": "backupOutlined",
    "battery_saver_outlined": "batterySaverOutlined",
    "block_outlined": "blockOutlined",
    "broken_image_outlined": "brokenImageOutlined",
    "camera_alt": "cameraAlt",
    "camera_alt_outlined": "cameraAltOutlined",
    "chat_bubble_outline": "chatBubbleOutline",
    "check_circle_outline": "checkCircleOutline",
    "check_circle_outline_outlined": "checkCircleOutlineOutlined",
    "chevron_left": "chevronLeft",
    "chevron_right": "chevronRight",
    "cloud_outlined": "cloudOutlined",
    "code_outlined": "codeOutlined",
    "copy_rounded": "copyRounded",
    "dark_mode_outlined": "darkMode",
    "delete_outline": "deleteOutline",
    "delete_outlined": "deleteOutlined",
    "delete_sweep_outlined": "deleteSweepOutlined",
    "description_outlined": "descriptionOutlined",
    "design_services": "designServices",
    "dns_outlined": "dnsOutlined",
    "download_outlined": "downloadOutlined",
    "edit_outlined": "editOutlined",
    "emoji_emotions_outlined": "emojiEmotionsOutlined",
    "emergency_outlined": "emergencyOutlined",
    "exit_to_app": "exitToApp",
    "fiber_manual_record": "offlineBolt",
    "fingerprint_outlined": "fingerprintOutlined",
    "flash_off": "flashOff",
    "flash_on": "flashOn",
    "flip_camera_android": "flipCameraAndroid",
    "folder_open_outlined": "folderOpenOutlined",
    "group_add_outlined": "groupAddOutlined",
    "groups_rounded": "groupsRounded",
    "help_outline": "helpOutline",
    "image_outlined": "imageOutlined",
    "info_outline": "infoOutline",
    "insert_drive_file": "insertDriveFile",
    "insert_drive_file_outlined": "insertDriveFileOutlined",
    "keyboard_arrow_down": "keyboardArrowDown",
    "keyboard_arrow_down_outlined": "keyboardArrowDownOutlined",
    "key_outlined": "keyOutlined",
    "light_mode_outlined": "lightMode",
    "local_shipping_outlined": "localShippingOutlined",
    "lock_outline": "lock",
    "mic_outlined": "micOutlined",
    "minimize_outlined": "minimizeOutlined",
    "more_vert": "moreVert",
    "notifications_active_outlined": "notificationsActiveOutlined",
    "notifications_off_outlined": "notificationsOffOutlined",
    "notifications_outlined": "notificationsOutlined",
    "offline_bolt": "offlineBolt",
    "open_in_new": "openInNew",
    "password_outlined": "passwordOutlined",
    "pause_circle": "pauseCircle",
    "pause_rounded": "pauseRounded",
    "person_add_alt_1_outlined": "personAddAlt1Outlined",
    "person_add_alt_1_rounded": "personAddAlt1Rounded",
    "person_add_outlined": "personAddOutlined",
    "person_outline": "personOutline",
    "person_remove_outlined": "personRemoveOutlined",
    "photo_library_outlined": "photoLibraryOutlined",
    "picture_as_pdf": "pictureAsPdf",
    "picture_as_pdf_outlined": "pictureAsPdfOutlined",
    "pin_outlined": "pin",
    "play_arrow": "playArrow",
    "play_arrow_rounded": "playArrowRounded",
    "play_circle": "playCircle",
    "play_circle_fill": "playCircleFill",
    "preview_outlined": "previewOutlined",
    "privacy_tip_outlined": "privacyTip",
    "push_pin": "pushPin",
    "push_pin_outlined": "pushPinOutlined",
    "qr_code": "qrCode",
    "qr_code_scanner": "qrCodeScanner",
    "refresh_outlined": "refreshOutlined",
    "remove_red_eye": "removeRedEye",
    "restore_outlined": "restoreOutlined",
    "save_outlined": "saveOutlined",
    "schedule_outlined": "scheduleOutlined",
    "settings_outlined": "settingsOutlined",
    "settings_input_component_outlined": "settingsInputComponentOutlined",
    "shield_outlined": "shieldOutlined",
    "storage_outlined": "storageOutlined",
    "subtitles_outlined": "subtitlesOutlined",
    "swap_horiz": "swapHoriz",
    "table_chart_outlined": "tableChartOutlined",
    "timer_off": "timerOff",
    "tour_outlined": "tourOutlined",
    "troubleshoot_rounded": "troubleshootRounded",
    "upload_file": "uploadFile",
    "videocam_outlined": "videocamOutlined",
    "visibility_off": "visibilityOff",
    "visibility_outlined": "visibilityOutlined",
    "volume_off": "volumeOff",
    "volume_up": "volumeUp",
    "warning_amber_rounded": "warningAmberRounded",
    "water_drop_outlined": "waterDrop",
    "whatshot_outlined": "whatshot",
    "wifi_off": "wifiOff",
    "access_time_outlined": "accessTimeOutlined",
    "account_circle_outlined": "accountCircleOutlined",
    "add_moderator_outlined": "addModeratorOutlined",
    "article_outlined": "articleOutlined",
    "audiotrack_outlined": "audiotrackOutlined",
    "send_rounded": "sendRounded",
}

THEME_REPLACEMENTS = [
    ("Theme.of(context).cardColor", "context.prysmStyle.tokens.surface"),
    ("Theme.of(context).scaffoldBackgroundColor", "context.prysmStyle.tokens.background"),
    ("Theme.of(context).primaryColor", "context.prysmStyle.tokens.accent"),
    ("Theme.of(context).dividerColor", "context.prysmStyle.tokens.divider"),
    ("Theme.of(context).hintColor", "context.prysmStyle.tokens.textMuted"),
    ("Theme.of(context).colorScheme.error", "context.prysmStyle.tokens.danger"),
    ("Theme.of(context).colorScheme.primary", "context.prysmStyle.tokens.accent"),
    ("Theme.of(context).colorScheme.onPrimary", "context.prysmStyle.tokens.onAccent"),
    ("Theme.of(context).colorScheme.onSurface", "context.prysmStyle.tokens.textPrimary"),
    ("Theme.of(context).colorScheme.outline", "context.prysmStyle.tokens.outline"),
    ("Theme.of(context).colorScheme.secondary", "context.prysmStyle.tokens.accentMuted"),
    ("Theme.of(context).colorScheme.onSecondary", "context.prysmStyle.tokens.textPrimary"),
    ("Theme.of(context).colorScheme.tertiary", "context.prysmStyle.tokens.accentMuted"),
    ("Theme.of(context).colorScheme.surfaceContainerHigh", "context.prysmStyle.tokens.surfaceElevated"),
    ("Theme.of(context).colorScheme.surfaceContainerHighest", "context.prysmStyle.tokens.surfaceElevated"),
    ("Theme.of(context).textTheme.headlineSmall", "context.prysmStyle.headlineStyle"),
    ("Theme.of(context).textTheme.headlineMedium", "context.prysmStyle.headlineStyle"),
    ("Theme.of(context).textTheme.headlineLarge", "context.prysmStyle.headlineStyle"),
    ("Theme.of(context).textTheme.titleLarge", "context.prysmStyle.headlineStyle"),
    ("Theme.of(context).textTheme.titleMedium", "context.prysmStyle.titleStyle"),
    ("Theme.of(context).textTheme.titleSmall", "context.prysmStyle.titleStyle"),
    ("Theme.of(context).textTheme.bodyMedium", "context.prysmStyle.bodyStyle"),
    ("Theme.of(context).textTheme.bodySmall", "context.prysmStyle.captionStyle"),
    ("Theme.of(context).iconTheme.color", "context.prysmStyle.tokens.textSecondary"),
    ("Theme.of(context).brightness == Brightness.dark", "context.prysmStyle.tokens.brightness == Brightness.dark"),
]

WIDGET_REPLACEMENTS = [
    ("const CircularProgressIndicator()", "const PrysmProgressIndicator()"),
    ("CircularProgressIndicator(strokeWidth: 2)", "const PrysmProgressIndicator(size: 20)"),
    ("CircularProgressIndicator()", "const PrysmProgressIndicator()"),
    ("LinearProgressIndicator(", "PrysmLinearProgressIndicator("),
    ("MaterialPageRoute<bool>(", "PrysmPageRoute<bool>(page: "),
    ("MaterialPageRoute<void>(", "PrysmPageRoute<void>(page: "),
    ("MaterialPageRoute(", "PrysmPageRoute(page: "),
    ("SwitchListTile(", "PrysmSwitchRow("),
    ("CheckboxListTile(", "PrysmCheckboxRow("),
    ("ChoiceChip(", "PrysmChip("),
    ("showModalBottomSheet<void>(", "showPrysmSheet<void>("),
    ("showModalBottomSheet<", "showPrysmSheet<"),
    ("showModalBottomSheet(", "showPrysmSheet("),
    ("Switch(", "PrysmSwitch("),
    ("Slider(", "PrysmSlider("),
    ("TabController(", "PrysmTabController("),
    ("TabBarView(", "PrysmTabBarView("),
    ("TabBar(", "PrysmTabBar("),
]

IMPORTS = {
    "PrysmIcons.": "package:prysm/ui/core/prysm_icons.dart",
    "PrysmProgressIndicator": "package:prysm/ui/core/prysm_progress.dart",
    "PrysmLinearProgressIndicator": "package:prysm/ui/core/prysm_linear_progress.dart",
    "PrysmPageRoute": "package:prysm/ui/core/prysm_app.dart",
    "PrysmButton": "package:prysm/ui/core/prysm_button.dart",
    "PrysmIconButton": "package:prysm/ui/core/prysm_button.dart",
    "PrysmSwitch": "package:prysm/ui/core/prysm_switch.dart",
    "PrysmSwitchRow": "package:prysm/ui/core/prysm_switch.dart",
    "PrysmSlider": "package:prysm/ui/core/prysm_slider.dart",
    "PrysmChip": "package:prysm/ui/core/prysm_chip.dart",
    "PrysmCheckboxRow": "package:prysm/ui/core/prysm_checkbox.dart",
    "PrysmRadioRow": "package:prysm/ui/core/prysm_radio.dart",
    "PrysmFab": "package:prysm/ui/core/prysm_tabs.dart",
    "PrysmTabController": "package:prysm/ui/core/prysm_tabs.dart",
    "PrysmTabBar": "package:prysm/ui/core/prysm_tabs.dart",
    "PrysmTabBarView": "package:prysm/ui/core/prysm_tabs.dart",
    "PrysmPressable": "package:prysm/ui/core/prysm_pressable.dart",
    "PrysmListRow": "package:prysm/ui/core/prysm_list_row.dart",
    "PrysmTextField": "package:prysm/ui/core/prysm_text_field.dart",
    "showPrysmToast": "package:prysm/ui/core/prysm_toast.dart",
    "showPrysmDialog": "package:prysm/ui/core/prysm_dialog.dart",
    "showPrysmConfirmDialog": "package:prysm/ui/core/prysm_dialog.dart",
    "showPrysmSheet": "package:prysm/ui/core/prysm_list_row.dart",
    "PrysmPage": "package:prysm/ui/prysm_scaffold.dart",
    "PrysmScaffold": "package:prysm/ui/prysm_scaffold.dart",
    "PrysmSection": "package:prysm/ui/prysm_section.dart",
    "context.prysmStyle": "package:prysm/theme/prysm_style_scope.dart",
}


def snake_to_camel(name: str) -> str:
    if name in MATERIAL_ICON_MAP:
        return MATERIAL_ICON_MAP[name]
    parts = name.split("_")
    return parts[0] + "".join(p.title() for p in parts[1:])


def migrate_icons(text: str) -> str:
    def repl_icons(match: re.Match[str]) -> str:
        raw = match.group(1)
        camel = snake_to_camel(raw)
        return f"PrysmIcons.{camel}"

    text = re.sub(r"Icons\.([a-zA-Z0-9_]+)", repl_icons, text)
    # Fix double Prysm prefix if any
    text = text.replace("PrysmPrysmIcons.", "PrysmIcons.")
    return text


def migrate_colors(text: str) -> str:
    replacements = [
        ("Colors.grey[500]", "context.prysmStyle.tokens.textMuted"),
        ("Colors.grey", "context.prysmStyle.tokens.textMuted"),
        ("Colors.red[400]", "context.prysmStyle.tokens.danger"),
        ("Colors.red", "context.prysmStyle.tokens.danger"),
        ("Colors.white70", "const Color(0xB3FFFFFF)"),
        ("Colors.white", "const Color(0xFFFFFFFF)"),
        ("Colors.black", "const Color(0xFF000000)"),
        ("Colors.transparent", "const Color(0x00000000)"),
        ("Colors.blue", "const Color(0xFF2196F3)"),
        ("Colors.green", "const Color(0xFF4CAF50)"),
        ("Colors.purple", "const Color(0xFF9C27B0)"),
        ("Colors.orange", "const Color(0xFFFF9800)"),
    ]
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def migrate_icon_button(text: str) -> str:
    pattern = re.compile(
        r"IconButton\(\s*"
        r"(?:tooltip:\s*('(?:\\'|[^'])*'|\"(?:\\\"|[^\"])*\"),\s*)?"
        r"icon:\s*(?:const\s+)?Icon\(([^,)]+)(?:,\s*[^)]+)?\),\s*"
        r"onPressed:\s*([^,]+),\s*"
        r"\)",
        re.DOTALL,
    )

    def repl(m: re.Match[str]) -> str:
        tooltip = m.group(1) or ""
        icon = m.group(2).strip()
        on_pressed = m.group(3).strip()
        return f"PrysmIconButton({tooltip}icon: {icon}, onPressed: {on_pressed})"

    return pattern.sub(repl, text)


def add_imports(text: str) -> str:
    needed = []
    for token, imp in IMPORTS.items():
        if token in text and imp not in text:
            needed.append(f"import '{imp}';")
    if not needed:
        return text
    lines = text.splitlines()
    insert_at = 0
    for i, line in enumerate(lines):
        if line.startswith("import "):
            insert_at = i + 1
    lines[insert_at:insert_at] = needed
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def migrate_file(path: Path) -> bool:
    original = path.read_text()
    text = original
    text = migrate_icons(text)
    for old, new in THEME_REPLACEMENTS:
        text = text.replace(old, new)
    text = migrate_colors(text)
    for old, new in WIDGET_REPLACEMENTS:
        text = text.replace(old, new)
    text = migrate_icon_button(text)
    text = text.replace("PrysmPrysmIcons.", "PrysmIcons.")
    text = add_imports(text)
    if text != original:
        path.write_text(text)
        return True
    return False


def main() -> None:
    count = 0
    for path in sorted(ROOT.rglob("*.dart")):
        if migrate_file(path):
            count += 1
            print(path.relative_to(ROOT.parent.parent))
    print(f"Migrated {count} files")


if __name__ == "__main__":
    main()
