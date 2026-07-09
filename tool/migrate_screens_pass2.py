#!/usr/bin/env python3
"""Second-pass mechanical migrations for lib/screens/."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent / "lib" / "screens"

REPLACEMENTS = [
    ("const Divider(height: 1)", "const PrysmDivider()"),
    ("Divider(height: 1)", "const PrysmDivider()"),
    ("const Divider()", "const PrysmDivider()"),
    ("Divider()", "const PrysmDivider()"),
    ("VisualDensity.compact", "null /* compact */"),
    ("MaterialTapTargetSize.shrinkWrap", "null /* shrinkWrap */"),
]

IMPORTS = {
    "PrysmDivider": "package:prysm/ui/core/prysm_divider.dart",
    "PrysmTextButton": "package:prysm/ui/core/prysm_divider.dart",
    "PrysmLinkButton": "package:prysm/ui/core/prysm_divider.dart",
}


def add_import(text: str, imp: str) -> str:
    if imp in text:
        return text
    lines = text.splitlines()
    insert = 0
    for i, line in enumerate(lines):
        if line.startswith("import "):
            insert = i + 1
    lines.insert(insert, f"import '{imp}';")
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def migrate_snackbar(text: str) -> str:
    pattern = re.compile(
        r"ScaffoldMessenger\.of\(([^)]+)\)\.showSnackBar\(\s*"
        r"(?:const\s+)?SnackBar\(\s*content:\s*Text\(([^)]+)\)[^)]*\)\s*,?\s*\);",
        re.DOTALL,
    )
    return pattern.sub(r"showPrysmToast(\1, \2);", text)


def migrate_file(path: Path) -> bool:
    original = path.read_text()
    text = original
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    text = migrate_snackbar(text)
    if "PrysmDivider" in text:
        text = add_import(text, IMPORTS["PrysmDivider"])
    if "showPrysmToast" in text and "prysm_toast.dart" not in text:
        text = add_import(text, "package:prysm/ui/core/prysm_toast.dart")
    if text != original:
        path.write_text(text)
        return True
    return False


def main() -> None:
    count = 0
    for path in sorted(ROOT.rglob("*.dart")):
        if migrate_file(path):
            count += 1
    print(f"Pass2 migrated {count} files")


if __name__ == "__main__":
    main()
