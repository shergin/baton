#!/usr/bin/env python3
"""Summarizes a Time Profiler export of the bench suite.

    scripts/profile-summary.py <export.xml> <binary> <load address> [--scope <symbol>] [--top <n>] [--all-threads]

The export is xctrace's `time-profile` table. Frames of the executable come
unsymbolicated, as addresses; they are symbolicated through atos against
the binary at the load address the suite's --profile mode printed. The
summary counts the main thread's samples, those whose stack holds the
scope symbol when one is given, and prints the heaviest symbols by self
time (the innermost frame) and by inclusive time (every frame of the
stack, once per sample).
"""
import argparse
import collections
import platform
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def resolve(element, by_id):
    """The element itself, or the one its `ref` names."""
    ref = element.get("ref")
    return by_id[ref] if ref is not None else element


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("export")
    parser.add_argument("binary")
    parser.add_argument("load")
    parser.add_argument("--scope", help="keep the samples whose stack holds a symbol containing this text")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--all-threads", action="store_true", help="count every thread, not the main thread alone")
    arguments = parser.parse_args()

    tree = ET.parse(arguments.export)
    root = tree.getroot()
    by_id = {element.get("id"): element for element in root.iter() if element.get("id") is not None}

    stacks = []
    for row in root.iter("row"):
        thread = row.find("thread")
        if thread is None:
            continue
        thread = resolve(thread, by_id)
        if not arguments.all_threads and "Main Thread" not in (thread.get("fmt") or ""):
            continue
        tagged = row.find("tagged-backtrace")
        if tagged is None:
            continue
        tagged = resolve(tagged, by_id)
        backtrace = tagged.find("backtrace")
        if backtrace is None:
            continue
        backtrace = resolve(backtrace, by_id)
        frames = []
        for frame in backtrace.findall("frame"):
            frame = resolve(frame, by_id)
            frames.append(frame.get("name") or frame.get("addr") or "?")
        if frames:
            stacks.append(frames)

    # The executable's frames: addresses atos names.
    hexadecimal = re.compile(r"^0x[0-9a-f]+$")
    addresses = sorted({name for stack in stacks for name in stack if hexadecimal.match(name)})
    names = {}
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    for start in range(0, len(addresses), 400):
        batch = addresses[start:start + 400]
        output = subprocess.run(
            ["atos", "-o", arguments.binary, "-arch", arch, "-l", arguments.load] + batch,
            capture_output=True, text=True, check=False,
        ).stdout.splitlines()
        for address, line in zip(batch, output):
            symbol = re.sub(r" \(in [^)]*\)", "", line).strip()
            symbol = re.sub(r" \([^()]*:\d+\)$", "", symbol)
            names[address] = symbol or address

    def named(stack):
        return [names.get(frame, frame) for frame in stack]

    stacks = [named(stack) for stack in stacks]
    total = len(stacks)
    if arguments.scope:
        stacks = [stack for stack in stacks if any(arguments.scope in frame for frame in stack)]
    counted = len(stacks)
    if counted == 0:
        print(f"{total} samples on the thread, none in scope")
        return
    self_time = collections.Counter(stack[0] for stack in stacks)
    inclusive = collections.Counter()
    for stack in stacks:
        for symbol in set(stack):
            inclusive[symbol] += 1

    scope = f" holding {arguments.scope!r}" if arguments.scope else ""
    print(f"{total} samples on the {'threads' if arguments.all_threads else 'main thread'}, {counted} counted{scope}")
    print(f"\nTop {arguments.top} by self time:")
    for symbol, n in self_time.most_common(arguments.top):
        print(f"  {100 * n / counted:5.1f}%  {symbol}")
    print(f"\nTop {arguments.top} by inclusive time:")
    for symbol, n in inclusive.most_common(arguments.top):
        print(f"  {100 * n / counted:5.1f}%  {symbol}")


if __name__ == "__main__":
    sys.exit(main())
