#!/usr/bin/env python3
"""Adds one release to appcast.xml — the file installed copies read to find out
a new version exists.

Written by hand rather than with Sparkle's `generate_appcast`, which applies a
single download-URL prefix to every archive in a folder. GitHub puts each
release's .dmg behind its own per-tag URL, so one prefix cannot address them —
and the alternative, keeping every .dmg ever shipped in a local folder, means
the ability to publish an update depends on a directory on one Mac.
"""

import argparse
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{ns}">
  <channel>
    <title>Notch Voice</title>
    <description>On-device voice dictation for macOS.</description>
    <language>en</language>
  </channel>
</rss>
""".format(ns=SPARKLE_NS)


def parse_signature(line: str) -> tuple[str, str]:
    """Pulls the two attributes out of sign_update's output.

    It prints a ready-made XML fragment rather than a pair of values, e.g.
    `sparkle:edSignature="…" length="123"`. Parsed rather than pasted through,
    so a change in what it emits fails here instead of producing an appcast
    that is well-formed and unverifiable.
    """
    signature = re.search(r'sparkle:edSignature="([^"]+)"', line)
    length = re.search(r'length="(\d+)"', line)
    if not signature or not length:
        raise SystemExit(f"could not read sign_update output: {line!r}")
    return signature.group(1), length.group(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--minimum-system-version", default="26.0")
    args = parser.parse_args()

    signature, length = parse_signature(args.signature)

    path = Path(args.appcast)
    tree = ET.ElementTree(ET.fromstring(path.read_text() if path.exists() else EMPTY))
    channel = tree.getroot().find("channel")

    # Refuses rather than appends a duplicate. Two items with one version is a
    # feed where which update gets offered depends on parse order.
    for existing in channel.findall("item"):
        node = existing.find(f"{{{SPARKLE_NS}}}shortVersionString")
        if node is not None and node.text == args.version:
            raise SystemExit(f"appcast already has {args.version}")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {args.version}"
    ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(
        item, f"{{{SPARKLE_NS}}}minimumSystemVersion"
    ).text = args.minimum_system_version
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}edSignature": signature,
            "length": length,
        },
    )

    # Newest first. Sparkle does not require it, but a human opening this file
    # to check what shipped should not have to scroll to the bottom.
    channel.insert(len(list(channel.findall("*"))) - len(channel.findall("item")), item)

    ET.indent(tree, space="  ")
    path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        + ET.tostring(tree.getroot(), encoding="unicode")
        + "\n"
    )
    print(f"appcast.xml now offers {args.version}")


if __name__ == "__main__":
    main()
