#!/usr/bin/env python3
"""Extract sections from a markdown spec file by section references.

Usage:
    python extract_sections.py spec.md "4.1-4.5, Module B, E1-E3, 6.4"

Section reference formats supported:
    4.1         — single numbered section (### 4.1 ...)
    4.1-4.5     — range of numbered sections
    E1-E3       — range of lettered sub-sections (### E1, ### E2, ### E3)
    E2          — single lettered sub-section
    Module B    — full module (## Module B ...)
    FR-2        — functional requirement (matched inside ## 3.1)
    NFR-1       — non-functional requirement (matched inside ## 3.2)
    1           — top-level section (# 1) ...)
    3.1         — second-level section (## 3.1 ...)

Output: extracted sections concatenated to stdout, each separated by ---.
Always includes section 1 (Architecture Overview) as context preamble.
"""

from __future__ import annotations

import re
import sys


def parse_spec(lines: list[str]) -> list[dict]:
    """Parse markdown into a list of sections with heading info and line ranges."""
    sections: list[dict] = []
    open_sections: list[int] = []
    for i, line in enumerate(lines):
        m = re.match(r"^(#{1,4})\s+(.*)", line)
        if m:
            level = len(m.group(1))
            title = m.group(2).strip()
            sections.append(
                {
                    "level": level,
                    "title": title,
                    "start": i,
                    "end": len(lines),  # will be narrowed
                    "line": line,
                }
            )
            while open_sections and sections[open_sections[-1]]["level"] >= level:
                sections[open_sections.pop()]["end"] = i
            open_sections.append(len(sections) - 1)
    return sections


def section_id(title: str) -> str | None:
    """Extract a section identifier from a heading title.

    Examples:
        "4.1 Top-level schema (YAML)" -> "4.1"
        "Module B — Compute Planning" -> "Module B"
        "E1: QC Agent inputs" -> "E1"
        "1) Architecture Overview" -> "1"
        "3.1 Functional Requirements (FR)" -> "3.1"
    """
    # "Module X" pattern
    m = re.match(r"(Module\s+[A-Z])", title)
    if m:
        return m.group(1)
    # "4.1", "6.8", "3.2" pattern
    m = re.match(r"(\d+\.\d+)", title)
    if m:
        return m.group(1)
    # "E1:", "E2:", "B1:", "C4:" pattern
    m = re.match(r"([A-Z]\d+)", title)
    if m:
        return m.group(1)
    # "1)" top-level pattern
    m = re.match(r"(\d+)\)", title)
    if m:
        return m.group(1)
    return None


def expand_range(ref: str) -> list[str]:
    """Expand a section reference into individual IDs.

    Examples:
        "4.1-4.5" -> ["4.1", "4.2", "4.3", "4.4", "4.5"]
        "E1-E3"   -> ["E1", "E2", "E3"]
        "Module B" -> ["Module B"]
        "6.4"     -> ["6.4"]
    """
    ref = ref.strip()

    # Range: 4.1-4.5 or 4.1–4.5 (en-dash)
    m = re.match(r"(\d+)\.(\d+)\s*[-–]\s*(\d+)\.(\d+)", ref)
    if m:
        prefix = m.group(1)
        start = int(m.group(2))
        end = int(m.group(4))
        return [f"{prefix}.{i}" for i in range(start, end + 1)]

    # Range: E1-E3 or B1-B2
    m = re.match(r"([A-Z])(\d+)\s*[-–]\s*[A-Z](\d+)", ref)
    if m:
        letter = m.group(1)
        start = int(m.group(2))
        end = int(m.group(3))
        return [f"{letter}{i}" for i in range(start, end + 1)]

    # Single ref (Module B, 4.1, E2, FR-2, etc.)
    return [ref]


def match_section(sec: dict, target_id: str) -> bool:
    """Check if a section matches a target ID."""
    sid = section_id(sec["title"])
    if sid and sid == target_id:
        return True

    # FR-N / NFR-N: match inside the section text
    if target_id.startswith("FR-") or target_id.startswith("NFR-"):
        return target_id in sec["title"]

    return False


def requirement_ids(title: str) -> list[str]:
    """Return FR/NFR IDs mentioned in a heading title."""
    return re.findall(r"\b(?:FR|NFR)-\d+\b", title)


def build_section_index(sections: list[dict]) -> dict[str, dict]:
    """Build first-match section index by supported section IDs."""
    index: dict[str, dict] = {}
    for sec in sections:
        sid = section_id(sec["title"])
        if sid:
            index.setdefault(sid, sec)
        for req_id in requirement_ids(sec["title"]):
            index.setdefault(req_id, sec)
    return index


def find_section(sections: list[dict], index: dict[str, dict], target_id: str) -> dict | None:
    """Find the first matching section for a target ID."""
    indexed = index.get(target_id)
    if indexed is not None:
        return indexed

    # Preserve legacy substring matching for uncommon FR/NFR heading variants.
    if target_id.startswith("FR-") or target_id.startswith("NFR-"):
        for sec in sections:
            if target_id in sec["title"]:
                return sec

    return None


def extract(spec_path: str, refs_str: str) -> str:
    """Extract sections matching the given references."""
    with open(spec_path) as f:
        lines = f.readlines()

    sections = parse_spec(lines)

    # Parse references
    raw_refs = re.split(r"[,;]", refs_str)
    # Also split on spaces around "Module" to handle "Module B (B1-B2)" -> "Module B", "B1-B2"
    expanded_refs: list[str] = []
    for ref in raw_refs:
        ref = ref.strip()
        if not ref:
            continue
        # Handle "Module B (B1-B2)" -> "Module B" + "B1-B2"
        m = re.match(r"(Module\s+[A-Z])\s*\(([^)]+)\)", ref)
        if m:
            expanded_refs.append(m.group(1))
            for sub in re.split(r"[,;]", m.group(2)):
                expanded_refs.extend(expand_range(sub.strip()))
        else:
            expanded_refs.extend(expand_range(ref))

    # Always include section 1 (Architecture Overview) for context
    if "1" not in expanded_refs:
        expanded_refs.insert(0, "1")

    # Find matching sections
    section_index = build_section_index(sections)
    matched_ranges: list[tuple[int, int]] = []
    for target in expanded_refs:
        sec = find_section(sections, section_index, target)
        if sec is not None:
            matched_ranges.append((sec["start"], sec["end"]))

    # Merge overlapping ranges and sort
    if not matched_ranges:
        return "# No matching sections found\n"

    matched_ranges.sort()
    merged: list[tuple[int, int]] = [matched_ranges[0]]
    for start, end in matched_ranges[1:]:
        if start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))

    # Build output
    parts: list[str] = []
    parts.append(f"<!-- Extracted sections: {', '.join(expanded_refs)} -->\n\n")
    for start, end in merged:
        chunk = "".join(lines[start:end]).rstrip()
        parts.append(chunk)
        parts.append("\n\n---\n\n")

    return "".join(parts).rstrip() + "\n"


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <spec.md> <section_refs>", file=sys.stderr)
        print(
            f'Example: {sys.argv[0]} spec.md "4.1-4.5, Module B, E1-E3"',
            file=sys.stderr,
        )
        sys.exit(1)

    result = extract(sys.argv[1], sys.argv[2])
    sys.stdout.write(result)
