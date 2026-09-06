#!/usr/bin/env python3
"""Fail CI when tracked repository text looks like real Pryvance-sensitive data.

This complements gitleaks. It intentionally favors high-confidence, structurally
checkable identifiers over guesses about names, merchants, dates, or monetary values.
Committed examples and fixtures must be synthetic from inception, never lightly
redacted exports of real Household data.
"""

from __future__ import annotations

import ipaddress
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
KNOWN_SAFE_BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".svgz",
    ".woff", ".woff2", ".ttf", ".eot", ".wasm",
}

EMAIL_RE = re.compile(r"(?<![\w.+-])([A-Z0-9._%+-]+)@([A-Z0-9.-]+\.[A-Z]{2,})(?![\w.-])", re.I)
SSN_RE = re.compile(r"(?<!\d)(\d{3})[- ](\d{2})[- ](\d{4})(?!\d)")
PAN_RE = re.compile(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)")
IBAN_RE = re.compile(r"(?<![A-Z0-9])([A-Z]{2}\d{2}[A-Z0-9]{11,30})(?![A-Z0-9])", re.I)
ROUTING_RE = re.compile(r"(?<!\d)(\d{9})(?!\d)")
IPV4_RE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
LOCAL_FQDN_RE = re.compile(r"(?<![A-Z0-9.-])([A-Z0-9-]+(?:\.[A-Z0-9-]+)+\.(?:local|lan|home|internal|corp))(?![A-Z0-9.-])", re.I)

ALLOWED_EMAIL_DOMAINS = {"example.com", "example.net", "example.org", "example.invalid"}
# Protocol/tooling identities that are constants rather than people or Household data.
# Keep this exact-value list deliberately tiny; do not turn it into a domain exemption.
ALLOWED_EMAIL_ADDRESSES = {"git@github.com"}
DOC_IPV4 = tuple(ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"))
ROUTING_CONTEXT_RE = re.compile(r"\b(?:aba|routing|routing number|routing_number)\b", re.I)


def _luhn(value: str) -> bool:
    digits = [int(c) for c in value if c.isdigit()]
    if not 13 <= len(digits) <= 19:
        return False
    total = 0
    parity = len(digits) % 2
    for i, digit in enumerate(digits):
        if i % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        total += digit
    return total % 10 == 0


def _valid_ssn(parts: tuple[str, str, str]) -> bool:
    area, group, serial = (int(p) for p in parts)
    return area not in {0, 666} and area < 900 and group != 0 and serial != 0


def _valid_iban(value: str) -> bool:
    compact = re.sub(r"\s+", "", value).upper()
    if not 15 <= len(compact) <= 34:
        return False
    rearranged = compact[4:] + compact[:4]
    expanded = "".join(str(ord(c) - 55) if c.isalpha() else c for c in rearranged)
    try:
        return int(expanded) % 97 == 1
    except ValueError:
        return False


def _valid_routing(value: str) -> bool:
    if len(value) != 9 or not value.isdigit():
        return False
    d = [int(c) for c in value]
    return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])) % 10 == 0


def scan_text(path: str, text: str) -> list[str]:
    findings: list[str] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in EMAIL_RE.finditer(line):
            address = match.group(0).lower()
            domain = match.group(2).lower()
            if address not in ALLOWED_EMAIL_ADDRESSES and domain not in ALLOWED_EMAIL_DOMAINS:
                findings.append(f"{path}:{lineno}: non-example email address: {match.group(0)}")

        for match in SSN_RE.finditer(line):
            if _valid_ssn(match.groups()):
                findings.append(f"{path}:{lineno}: SSN/TIN-shaped value")

        for match in PAN_RE.finditer(line):
            compact = re.sub(r"\D", "", match.group(0))
            if len(set(compact)) > 1 and _luhn(compact):
                findings.append(f"{path}:{lineno}: payment-card-shaped value passing Luhn")

        for match in IBAN_RE.finditer(line):
            if _valid_iban(match.group(1)):
                findings.append(f"{path}:{lineno}: IBAN-shaped value passing checksum")

        if ROUTING_CONTEXT_RE.search(line):
            for match in ROUTING_RE.finditer(line):
                if _valid_routing(match.group(1)):
                    findings.append(f"{path}:{lineno}: ABA routing-number-shaped value passing checksum")

        for match in IPV4_RE.finditer(line):
            try:
                address = ipaddress.ip_address(match.group(0))
            except ValueError:
                continue
            if address.is_loopback or address.is_unspecified or any(address in network for network in DOC_IPV4):
                continue
            findings.append(f"{path}:{lineno}: non-documentation IPv4 address: {address}")

        for match in LOCAL_FQDN_RE.finditer(line):
            fqdn = match.group(1).lower()
            if fqdn.startswith("example.") or ".example." in fqdn:
                continue
            findings.append(f"{path}:{lineno}: local/internal FQDN: {fqdn}")

    return findings


def _tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=REPO_ROOT, check=True, capture_output=True
    )
    return [REPO_ROOT / p.decode() for p in result.stdout.split(b"\0") if p]


def main() -> int:
    findings: list[str] = []
    unreadable: list[str] = []

    for path in _tracked_files():
        rel = path.relative_to(REPO_ROOT).as_posix()
        if path.suffix.lower() in KNOWN_SAFE_BINARY_EXTENSIONS:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            unreadable.append(rel)
            continue
        findings.extend(scan_text(rel, text))

    if unreadable:
        print("Sanitization scan refused to silently skip uninspectable tracked files:")
        for rel in unreadable:
            print(f"  {rel}")
        print("Add only genuinely inert binary formats to KNOWN_SAFE_BINARY_EXTENSIONS, with review.")
        return 1

    if findings:
        print("Pryvance repository sanitization findings:")
        for finding in findings:
            print(f"  {finding}")
        return 1

    print("Pryvance repository sanitization scan passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
