#!/usr/bin/env python3
"""Finds display text that never passes through a localized lookup.

Every earlier sweep of this codebase searched for `Localization.` *call sites*. That cannot see a
string with no call site at all — a bare `Button("Delete Layer")`, or one branch of a ternary whose
other branch was wrapped — which is how `Merge Down`, `Delete Layer` and 32 more survived four passes.

So this walks the other way round: it looks for literals in positions that *render*, and reports the
ones no lookup wraps. A title is a first argument to `Button`, `Text`, `Menu`, `Label`, `.help`,
`.alert` and the like, so only that argument is examined — a message body or a symbol name is not a
title.

    python3 scripts/l10n/check-display-literals.py

Known exceptions live in ALLOWED, each with the reason it is not a title.
"""

import pathlib
import re
import sys

# APIs whose first argument is display text.
TITLE_API = re.compile(
    r"\b(Button|Menu|Toggle|Text|Label|Picker|TextField|CommandMenu|CommandGroup"
    r"|navigationTitle|accessibilityLabel|alert|help)\s*[(:]"
)
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

ALLOWED_SUBSTRINGS = (
    "systemSymbolName", "systemName", "verbatim", "monospacedDigit",
)
ALLOWED_LITERALS = {"%", "#", "·", "×", "—", "OK", "px", "RGBA", "sRGB", "8BPS", "8BIM"}


def balanced(text: str, start: int) -> str | None:
    """Text between the brackets opening at `start`, or None if they never close."""
    pairs = {"(": ")", "[": "]"}
    if start >= len(text) or text[start] not in pairs:
        return None
    close = pairs[text[start]]
    depth, i, in_string, escaped = 1, start + 1, False, False
    while i < len(text):
        ch = text[i]
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == '"':
            in_string = not in_string
        elif not in_string:
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
                if depth == 0:
                    return text[start + 1:i]
        i += 1
    return None


def first_argument(args: str) -> str:
    """The text of the first argument, stopping at the first top-level comma."""
    depth, out, in_string, escaped = 0, "", False, False
    for ch in args:
        if escaped:
            out += ch
            escaped = False
        elif ch == "\\":
            out += ch
            escaped = True
        elif ch == '"':
            in_string = not in_string
            out += ch
        elif not in_string:
            if ch in "([":
                depth += 1
                out += ch
            elif ch in ")]":
                depth -= 1
                out += ch
            elif ch == "," and depth == 0:
                break
            else:
                out += ch
        else:
            out += ch
    return out.strip()


# Localized on purpose, so they are not titles to translate:
#   · notation rather than prose — a unit or a symbol, like "°" or "px".
#   · symbol names, verbatim quotes and monospaced readouts.
def looks_like_prose(literal: str) -> bool:
    """A title reads as words. A symbol name, a key, a readout or a token does not."""
    if literal in ALLOWED_LITERALS or len(literal) < 2:
        return False
    # Interpolation is code, not words: a readout built by \(Int(x)) is not a title to translate.
    if "\\(" in literal:
        return False
    # Two or more letters in a row: "Delete Layer" does, and a unit like "px" does not.
    if not re.search(r"[A-Za-z]{2}", literal):
        return False
    # A single lowercase token is an identifier or a symbol name, not a title.
    if re.fullmatch(r"[a-z][A-Za-z0-9.]*", literal):
        return False
    # A lone word with no space is a unit or a format name.
    if re.fullmatch(r"[A-Za-z0-9_.%\- ]+", literal) and " " not in literal and literal[0].islower():
        return False
    return True


def check_file(path: pathlib.Path) -> list[tuple[int, str, str]]:
    text = path.read_text(encoding="utf-8")
    # Comment lines are documentation, and several of them quote the very mistake this looks for.
    lines = text.split("\n")
    code_lines = ["" if line.lstrip().startswith(("//", "///", "*")) else line for line in lines]
    code = "\n".join(code_lines)
    problems = []
    for match in TITLE_API.finditer(code):
        args = balanced(code, match.end() - 1)
        if args is None:
            continue
        title = first_argument(args)
        if not title or "Localization." in title:
            continue
        if any(skip in title for skip in ALLOWED_SUBSTRINGS):
            continue
        for literal in LITERAL.findall(title):
            if literal.startswith("%"):
                continue  # a format string is looked up through a key, not rendered itself
            if looks_like_prose(literal):
                line = code[:match.start()].count("\n") + 1
                problems.append((line, match.group(1), title[:90]))
                break
    return problems


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2] / "Compositor"
    total = 0
    for path in sorted(root.rglob("*.swift")):
        if path.name == "Localization.swift":
            continue  # its doc comments quote the pattern on purpose
        problems = check_file(path)
        if problems:
            print(f"{path.relative_to(root.parent)}")
            for line, api, title in problems:
                print(f"  {line}: {api}  {title}")
            total += len(problems)
    if total:
        print(f"\n{total} title(s) with no localized lookup.")
        return 1
    print("display titles: all localized")
    return 0


if __name__ == "__main__":
    sys.exit(main())
