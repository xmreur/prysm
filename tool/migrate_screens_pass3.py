#!/usr/bin/env python3
"""Third-pass mechanical migrations for lib/screens/."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "lib" / "screens"

IMPORTS = {
    "PrysmTextButton": "package:prysm/ui/core/prysm_divider.dart",
    "PrysmLinkButton": "package:prysm/ui/core/prysm_divider.dart",
    "PrysmListRow": "package:prysm/ui/core/prysm_list_row.dart",
    "PrysmButton": "package:prysm/ui/core/prysm_button.dart",
    "PrysmIconButton": "package:prysm/ui/core/prysm_button.dart",
    "PrysmFab": "package:prysm/ui/core/prysm_tabs.dart",
    "PrysmTextField": "package:prysm/ui/core/prysm_text_field.dart",
    "PrysmRadioRow": "package:prysm/ui/core/prysm_radio.dart",
    "PrysmProgressIndicator": "package:prysm/ui/core/prysm_progress.dart",
    "PrysmPressable": "package:prysm/ui/core/prysm_pressable.dart",
    "showPrysmDialog": "package:prysm/ui/core/prysm_dialog.dart",
    "showPrysmConfirmDialog": "package:prysm/ui/core/prysm_dialog.dart",
    "showPrysmToast": "package:prysm/ui/core/prysm_toast.dart",
    "showPrysmSheet": "package:prysm/ui/core/prysm_list_row.dart",
    "PrysmPage": "package:prysm/ui/prysm_scaffold.dart",
    "PrysmScaffold": "package:prysm/ui/prysm_scaffold.dart",
    "PrysmPageRoute": "package:prysm/ui/core/prysm_app.dart",
    "context.prysmStyle": "package:prysm/theme/prysm_style_scope.dart",
    "context.prysmTokens": "package:prysm/theme/prysm_style_scope.dart",
}

REPLACEMENTS = [
    ("const CircularProgressIndicator()", "const PrysmProgressIndicator()"),
    ("CircularProgressIndicator(strokeWidth: 2)", "const PrysmProgressIndicator(size: 20)"),
    ("CircularProgressIndicator()", "const PrysmProgressIndicator()"),
    ("FloatingActionButton(", "PrysmFab(icon: PrysmIcons.callEnd, onPressed: null, /* was FAB */"),
    ("InkWell(", "PrysmPressable("),
    ("SelectableText(", "Text("),
    ("Theme.of(context)", "context.prysmStyle"),
    ("Theme.of(ctx)", "ctx.prysmStyle"),
    ("PrysmIcons.mic_outlined", "PrysmIcons.micOutlined"),
    ("PrysmPrysmIcons.", "PrysmIcons."),
    ("Prysmconst ", "const "),
    ("const Color(0xFF000000)87", "const Color(0x87000000)"),
    ("RadioGroup<", "Column(/* RadioGroup */"),
    ("RadioListTile<", "PrysmRadioRow<"),
]


def migrate_text_button(text: str) -> str:
    pattern = re.compile(
        r"TextButton\(\s*"
        r"(?:style:\s*TextButton\.styleFrom\([^)]*\),\s*)?"
        r"onPressed:\s*([^,]+),\s*"
        r"child:\s*(?:const\s+)?Text\((['\"])(.*?)\2\),\s*"
        r"\)",
        re.DOTALL,
    )
    return pattern.sub(r"PrysmTextButton(label: \2\3\2, onPressed: \1)", text)


def migrate_filled_button(text: str) -> str:
    for cls in ("FilledButton", "ElevatedButton", "OutlinedButton"):
        pattern = re.compile(
            rf"{cls}\(\s*"
            r"onPressed:\s*([^,]+),\s*"
            r"child:\s*(?:const\s+)?Text\((['\"])(.*?)\2\),\s*"
            r"\)",
            re.DOTALL,
        )
        text = pattern.sub(
            r"PrysmButton(label: \2\3\2, onPressed: \1)", text
        )
    return text


def migrate_list_tile_simple(text: str) -> str:
    """ListTile with string title/subtitle -> PrysmListRow."""
    pattern = re.compile(
        r"ListTile\(\s*"
        r"(leading:\s*[^,]+,\s*)?"
        r"title:\s*(?:const\s+)?Text\((['\"])(.*?)\3\),\s*"
        r"(?:subtitle:\s*(?:const\s+)?Text\((['\"])(.*?)\5\),\s*)?"
        r"(?:trailing:\s*([^,]+),\s*)?"
        r"onTap:\s*([^,]+),\s*"
        r"\)",
        re.DOTALL,
    )

    def repl(m: re.Match[str]) -> str:
        leading = m.group(1) or ""
        title = m.group(4)
        subtitle_part = ""
        if m.group(6):
            subtitle_part = f"subtitle: '{m.group(6)}', "
        trailing = f"trailing: {m.group(7)}, " if m.group(7) else ""
        on_tap = m.group(8)
        return (
            f"PrysmListRow({leading}{subtitle_part}title: '{title}', "
            f"{trailing}onTap: {on_tap})"
        )

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
    lines[insert_at:insert_at] = sorted(set(needed))
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def migrate_file(path: Path) -> bool:
    original = path.read_text()
    text = original
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    text = migrate_text_button(text)
    text = migrate_filled_button(text)
    text = migrate_list_tile_simple(text)
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
    print(f"Pass3 migrated {count} files")


if __name__ == "__main__":
    main()
