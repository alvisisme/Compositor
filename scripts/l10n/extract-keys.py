#!/usr/bin/env python3
"""Lists every key the sources look up, so translation coverage can be checked.

Finds `Localization.v("…")`, `Localization.text("…")`, `Localization.string("…")` and the
`displayName` switch bodies those feed, then reports which keys have no translation.
"""
import pathlib, re, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from translations import TRANSLATIONS  # noqa: E402

LOOKUP = re.compile(r'Localization\.(?:v|text|string)\("((?:[^"\\]|\\.)*)"')

def keys_in(path: pathlib.Path) -> set:
    found = set()
    for m in LOOKUP.finditer(path.read_text(encoding="utf-8")):
        key = m.group(1).replace('\\"', '"').replace("\\\\", "\\")
        found.add(key)
    return found

def main() -> None:
    used, per_file = set(), {}
    for path in sorted((ROOT / "Compositor").rglob("*.swift")):
        if path.name == "Localization.swift":
            continue
        found = keys_in(path)
        if found:
            per_file[str(path.relative_to(ROOT))] = len(found)
            used |= found
    missing = sorted(k for k in used if k not in TRANSLATIONS and re.search(r"[A-Za-z]{2}", k))
    print(f"keys looked up in sources: {len(used)}")
    print(f"translated:                {len(used) - len(missing)}")
    print(f"missing a translation:     {len(missing)}")
    if missing and "--list" in sys.argv:
        print()
        for k in missing:
            print(f'    {k!r}: "",')
    if "--files" in sys.argv:
        print()
        for f, n in sorted(per_file.items(), key=lambda kv: -kv[1])[:15]:
            print(f"{n:5}  {f}")

if __name__ == "__main__":
    main()
