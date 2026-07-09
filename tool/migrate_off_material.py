#!/usr/bin/env python3
"""Batch-migrate lib/ Dart files off Material UI."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "lib"

ICON_MAP = {
    "Icons.add_circle_outline": "PrysmIcons.addCircle",
    "Icons.archive_outlined": "PrysmIcons.archive",
    "Icons.arrow_back": "PrysmIcons.arrowBack",
    "Icons.arrow_forward_ios": "PrysmIcons.arrowForwardIos",
    "Icons.auto_awesome_outlined": "PrysmIcons.autoAwesome",
    "Icons.auto_fix_high_outlined": "PrysmIcons.autoAwesome",
    "Icons.block": "PrysmIcons.block",
    "Icons.block_outlined": "PrysmIcons.blockOutlined",
    "Icons.call": "PrysmIcons.call",
    "Icons.call_end": "PrysmIcons.callEnd",
    "Icons.chevron_left": "PrysmIcons.chevronLeft",
    "Icons.chevron_right": "PrysmIcons.chevronRight",
    "Icons.close": "PrysmIcons.close",
    "Icons.code": "PrysmIcons.code",
    "Icons.copy": "PrysmIcons.copy",
    "Icons.copy_rounded": "PrysmIcons.copyRounded",
    "Icons.dark_mode_outlined": "PrysmIcons.darkMode",
    "Icons.delete": "PrysmIcons.delete",
    "Icons.delete_outline": "PrysmIcons.deleteOutline",
    "Icons.delete_outlined": "PrysmIcons.deleteOutlined",
    "Icons.design_services": "PrysmIcons.designServices",
    "Icons.download_outlined": "PrysmIcons.downloadOutlined",
    "Icons.edit_outlined": "PrysmIcons.editOutlined",
    "Icons.exit_to_app": "PrysmIcons.exitToApp",
    "Icons.fiber_manual_record": "PrysmIcons.offlineBolt",
    "Icons.fingerprint_outlined": "PrysmIcons.fingerprintOutlined",
    "Icons.group_add_outlined": "PrysmIcons.groupAddOutlined",
    "Icons.groups_rounded": "PrysmIcons.groupsRounded",
    "Icons.image_outlined": "PrysmIcons.imageOutlined",
    "Icons.info_outline": "PrysmIcons.infoOutline",
    "Icons.insert_drive_file": "PrysmIcons.insertDriveFile",
    "Icons.key_outlined": "PrysmIcons.keyOutlined",
    "Icons.light_mode_outlined": "PrysmIcons.lightMode",
    "Icons.link": "PrysmIcons.link",
    "Icons.lock_outline": "PrysmIcons.lock",
    "Icons.menu": "PrysmIcons.menu",
    "Icons.mic": "PrysmIcons.mic",
    "Icons.mic_off": "PrysmIcons.micOff",
    "Icons.more_vert": "PrysmIcons.moreVert",
    "Icons.offline_bolt": "PrysmIcons.offlineBolt",
    "Icons.pause": "PrysmIcons.pause",
    "Icons.person_add_alt_1_rounded": "PrysmIcons.personAddAlt1Rounded",
    "Icons.person_add_outlined": "PrysmIcons.personAddOutlined",
    "Icons.person_outline": "PrysmIcons.personOutline",
    "Icons.person_remove_outlined": "PrysmIcons.personRemoveOutlined",
    "Icons.phone": "PrysmIcons.phone",
    "Icons.photo_library_outlined": "PrysmIcons.photoLibraryOutlined",
    "Icons.pin_outlined": "PrysmIcons.pin",
    "Icons.play_arrow": "PrysmIcons.playArrow",
    "Icons.privacy_tip_outlined": "PrysmIcons.privacyTip",
    "Icons.push_pin": "PrysmIcons.pushPin",
    "Icons.qr_code": "PrysmIcons.qrCode",
    "Icons.qr_code_scanner": "PrysmIcons.qrCodeScanner",
    "Icons.refresh": "PrysmIcons.refresh",
    "Icons.reply": "PrysmIcons.reply",
    "Icons.save_outlined": "PrysmIcons.saveOutlined",
    "Icons.search": "PrysmIcons.search",
    "Icons.security": "PrysmIcons.security",
    "Icons.select_all": "PrysmIcons.selectAll",
    "Icons.settings_outlined": "PrysmIcons.settingsOutlined",
    "Icons.shield_outlined": "PrysmIcons.shieldOutlined",
    "Icons.storage_outlined": "PrysmIcons.storageOutlined",
    "Icons.swap_horiz": "PrysmIcons.swapHoriz",
    "Icons.timer": "PrysmIcons.timer",
    "Icons.timer_off": "PrysmIcons.timerOff",
    "Icons.troubleshoot_rounded": "PrysmIcons.troubleshootRounded",
    "Icons.visibility": "PrysmIcons.visibility",
    "Icons.volume_off": "PrysmIcons.volumeOff",
    "Icons.volume_up": "PrysmIcons.volumeUp",
    "Icons.water_drop_outlined": "PrysmIcons.waterDrop",
    "Icons.whatshot_outlined": "PrysmIcons.whatshot",
    "Icons.wifi_off": "PrysmIcons.wifiOff",
    "Icons.whatshot": "PrysmIcons.whatshot",
}

SKIP = {
    ROOT / "ui" / "core",  # already material-free
}

def needs_migration(text: str) -> bool:
    return "package:flutter/material.dart" in text

def migrate_file(path: Path) -> bool:
    text = path.read_text()
    if not needs_migration(text):
        return False

    # Preserve show/material-only imports as show clauses if any
    uses_services = "package:flutter/services.dart" in text or "Clipboard" in text or "LogicalKeyboardKey" in text
    uses_foundation = "package:flutter/foundation.dart" in text or "kIsWeb" in text or "debugPrint" in text

    text = re.sub(
        r"import 'package:flutter/material.dart';\n?",
        "",
        text,
    )

    imports = ["import 'package:flutter/widgets.dart';"]
    if uses_services and "package:flutter/services.dart" not in text:
        imports.append("import 'package:flutter/services.dart';")
    if uses_foundation and "package:flutter/foundation.dart" not in text:
        imports.append("import 'package:flutter/foundation.dart';")

    needs_icons = "Icons." in text or "Icon(Icons" in text
    for old, new in ICON_MAP.items():
        text = text.replace(old, new)
    if "PrysmIcons." in text and "prysm_icons.dart" not in text:
        imports.append("import 'package:prysm/ui/core/prysm_icons.dart';")

    text = text.replace("const CircularProgressIndicator()", "const PrysmProgressIndicator()")
    text = text.replace("CircularProgressIndicator()", "PrysmProgressIndicator()")
    if "PrysmProgressIndicator" in text and "prysm_progress.dart" not in text:
        imports.append("import 'package:prysm/ui/core/prysm_progress.dart';")

    text = re.sub(
        r"MaterialPageRoute\s*\(\s*builder:\s*\(([^)]*)\)\s*=>\s*",
        r"PrysmPageRoute(page: ",
        text,
    )
    text = re.sub(
        r"MaterialPageRoute\s*\(\s*builder:\s*\(_\)\s*=>\s*",
        r"PrysmPageRoute(page: ",
        text,
    )
    text = text.replace("MaterialPageRoute(", "PrysmPageRoute(page: ")
    if "PrysmPageRoute" in text and "prysm_app.dart" not in text:
        imports.append("import 'package:prysm/ui/core/prysm_app.dart';")

    # Simple snackbar -> toast
    text = re.sub(
        r"ScaffoldMessenger\.of\(([^)]+)\)\.showSnackBar\(\s*SnackBar\(\s*content:\s*Text\(([^)]+)\)[^)]*\)[^)]*\);",
        r"showPrysmToast(\1, \2);",
        text,
        flags=re.DOTALL,
    )
    text = re.sub(
        r"ScaffoldMessenger\.of\(([^)]+)\)\.showSnackBar\(\s*const SnackBar\(\s*content:\s*Text\(([^)]+)\)[^)]*\)[^)]*\);",
        r"showPrysmToast(\1, \2);",
        text,
        flags=re.DOTALL,
    )
    if "showPrysmToast" in text and "prysm_toast.dart" not in text:
        imports.append("import 'package:prysm/ui/core/prysm_toast.dart';")

    text = text.replace("Theme.of(context).colorScheme.primary", "context.prysmStyle.tokens.accent")
    text = text.replace("Theme.of(context).colorScheme.onPrimary", "context.prysmStyle.tokens.onAccent")
    text = text.replace("Theme.of(context).colorScheme.secondary", "context.prysmStyle.tokens.accentMuted")
    text = text.replace("Theme.of(context).colorScheme.onSecondary", "context.prysmStyle.tokens.textPrimary")
    text = text.replace("Theme.of(context).colorScheme.onSurface", "context.prysmStyle.tokens.textPrimary")
    text = text.replace("Theme.of(context).colorScheme.tertiary", "context.prysmStyle.tokens.accentMuted")
    text = text.replace("Theme.of(context).colorScheme.surfaceContainerHighest", "context.prysmStyle.tokens.surfaceElevated")
    text = text.replace("Theme.of(context).primaryColor", "context.prysmStyle.tokens.accent")
    text = text.replace("Theme.of(context).hintColor", "context.prysmStyle.tokens.textMuted")
    text = text.replace("Theme.of(context).scaffoldBackgroundColor", "context.prysmStyle.tokens.background")
    text = text.replace("Theme.of(context).dividerColor", "context.prysmStyle.tokens.divider")
    if "context.prysmStyle" in text and "prysm_style_scope.dart" not in text:
        imports.append("import 'package:prysm/theme/prysm_style_scope.dart';")

    text = text.replace("IconButton(", "PrysmIconButton(icon: PrysmIcons.more, onPressed: null, ").replace("PrysmIconButton(icon: PrysmIcons.more, onPressed: null, ", "IconButton(")  # undo bad replace

    # Insert imports after first line (shebang/license) or at top
    header = "\n".join(imports) + "\n"
    if text.startswith("//") or text.startswith("///"):
        first_blank = text.find("\n\n")
        if first_blank != -1:
            text = text[: first_blank + 2] + header + text[first_blank + 2 :]
        else:
            text = header + text
    else:
        text = header + text

    path.write_text(text)
    return True

def main():
    count = 0
    for path in sorted(ROOT.rglob("*.dart")):
        if any(str(path).startswith(str(s)) for s in SKIP):
            continue
        if migrate_file(path):
            count += 1
            print(path.relative_to(ROOT.parent))
    print(f"Migrated {count} files")

if __name__ == "__main__":
    main()
