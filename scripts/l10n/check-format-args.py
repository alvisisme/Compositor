#!/usr/bin/env python3
"""Checks that every Localization format call passes arguments its specifiers can accept.

The crash this exists to prevent: `%@` in `String(format:)` means "send this object a message". Hand it
a Swift `Int` and Foundation dereferences the *number* as a pointer:

    String(format: "%@", 1920)      // SIGSEGV, not a formatting error

That shipped once, in the status bar's canvas size, and killed the app the moment a canvas existed.
It is not a mistake the type checker can see, because `Int` conforms to `CVarArg` just as `String`
does — the two only differ at the format string, which lives in a `.strings` file where no compiler
looks.

Run it after touching a localized call site's arguments:

    python3 scripts/l10n/check-format-args.py

An argument it cannot classify is reported as a note rather than a failure, so the exit status means
"something is definitely wrong" and nothing else.
"""

import pathlib
import re
import sys

CALL = re.compile(r"Localization\.(?:v|string)\(")

# Properties and locals that hold a String in this codebase.
STRING_PROPERTY = re.compile(
    r"\.(?:localizedName|displayName|name|title|label|editName|lastPathComponent|rawValue)\b"
    r"|^(?:undoName|redoName|percent|version|sourceName|mode|title|other|name|editableText)$"
)
# Functions in this codebase that return a String.
STRING_FUNCTION = re.compile(r"^(?:bytes|String|Localization\.[a-z]+)\s*\(")
NUMERIC_PROPERTY = re.compile(
    r"\.(?:count|width|height|maximum|minimum|lowerBound|upperBound|megapixels)\b"
    r"|^(?:width|height|count|maximum|version)$"
)
NUMERIC_CONVERSION = re.compile(r"^(?:Int|CGFloat|Double|Float)\s*\(")


def split_arguments(text):
    """Splits an argument list at top-level commas, ignoring commas inside strings and brackets."""
    parts, depth, current, in_string, escaped = [], 0, "", False, False
    for ch in text:
        if escaped:
            current += ch
            escaped = False
        elif ch == "\\":
            current += ch
            escaped = True
        elif ch == '"':
            in_string = not in_string
            current += ch
        elif not in_string and ch in "([":
            depth += 1
            current += ch
        elif not in_string and ch in ")]":
            if depth == 0:
                break
            depth -= 1
            current += ch
        elif not in_string and ch == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current.strip())
    return parts


def split_branches(text):
    """Splits a ternary into its branches at top-level `?` and `:`."""
    parts, depth, in_string, escaped, current = [], 0, False, False, ""
    for ch in text:
        if escaped:
            current += ch
            escaped = False
        elif ch == "\\":
            current += ch
            escaped = True
        elif ch == '"':
            in_string = not in_string
            current += ch
        elif not in_string and ch in "([":
            depth += 1
            current += ch
        elif not in_string and ch in ")]":
            depth -= 1
            current += ch
        elif not in_string and depth == 0 and ch in "?:":
            parts.append(current.strip())
            current = ""
        else:
            current += ch
    if not parts:
        return [text]
    parts.append(current.strip())
    return [part for part in parts if part]


def classify(expression, numeric_names):
    """Returns 'string', 'numeric' or 'unknown'."""
    text = expression.strip()
    if not text:
        return "unknown"
    if text.startswith('"'):
        return "string"
    # A ternary yields whichever branch runs, so it is a String only if every branch is.
    branches = split_branches(text)
    if len(branches) > 1:
        kinds = {classify(branch, numeric_names) for branch in branches}
        if kinds == {"string"}:
            return "string"
        if "numeric" in kinds:
            return "numeric"
        return "unknown"
    # An explicit conversion or a String-returning property wins over what it is built from:
    # `String(document.width)` is a String even though `.width` alone is not.
    if STRING_FUNCTION.match(text) or ".formatted(" in text or STRING_PROPERTY.search(text):
        return "string"
    if text in numeric_names or NUMERIC_CONVERSION.match(text) or NUMERIC_PROPERTY.search(text):
        return "numeric"
    if re.fullmatch(r"[A-Za-z_]\w*", text):
        return "numeric" if text in numeric_names else "unknown"
    return "unknown"


def call_body(text, start):
    """The text between the parentheses of the call whose `(` falls just before `start`."""
    i, depth = start, 1
    while i < len(text) and depth:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    return text[start:i - 1]


def check_file(path):
    """Returns (errors, notes)."""
    text = path.read_text(encoding="utf-8")
    numeric_names = {
        m.group(1)
        for m in re.finditer(r"\b(?:let|var)\s+(\w+)\s*:\s*(?:Int|CGFloat|Double|Float)\b", text)
    }
    errors, notes = [], []
    for match in CALL.finditer(text):
        pieces = split_arguments(call_body(text, match.end()))
        if len(pieces) < 2:
            continue  # no arguments, so no specifier can mismatch
        format_string, rest = pieces[0], ",".join(pieces[1:])
        # Only a literal can be counted. When the key is a variable the specifiers it carries are
        # decided at runtime, and a miscount here would be this script's mistake rather than the code's.
        if not format_string.lstrip().startswith('"'):
            continue
        # A format string may be a ternary over two format strings; both branches hold the same
        # specifiers, so count the first branch alone.
        branches = split_branches(format_string)
        counted = branches[-1] if len(branches) > 1 else format_string
        specs = [s for s in re.findall(r"%(?:\d+\$)?(@|lld|ld|d|f|%)", counted) if s != "%"]
        args = split_arguments(rest)
        if len(specs) != len(args):
            errors.append(f"  {format_string[:60]}: {len(specs)} specifier(s), {len(args)} argument(s)")
            continue
        for spec, argument in zip(specs, args):
            if spec != "@":
                continue
            kind = classify(argument, numeric_names)
            if kind == "numeric":
                errors.append(f"  %@ receives {argument!r}, which is numeric - use String(...) or %lld")
            elif kind == "unknown":
                notes.append(f"  %@ receives {argument!r}; confirm it is an object, not a scalar")
    return errors, notes


def main():
    root = pathlib.Path(__file__).resolve().parents[2] / "Compositor"
    files = sorted(root.rglob("*.swift"))
    error_count, note_count = 0, 0
    for path in files:
        errors, notes = check_file(path)
        if errors or notes:
            print(f"{path.relative_to(root.parent)}")
            for line in errors:
                print(line)
            for line in notes:
                print(line)
            error_count += len(errors)
            note_count += len(notes)
    if note_count:
        print(f"\n{note_count} argument(s) to confirm by eye (listed above).")
    if error_count:
        print(f"{error_count} error(s). A %@ given a number is a segfault, not a formatting error.")
        return 1
    print(f"format arguments: no errors ({len(files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
