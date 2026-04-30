#!/usr/bin/env python3
"""Session archaeology: query pi + Claude Code session transcripts.

Subcommands:
  find       List sessions matching cwd / time range / content grep.
  prompts    Enumerate user prompts from a session with timestamps.
  tools      Sample assistant tool calls (+ results) from a session.
  subagents  List subagent transcripts under a Claude Code parent session.
  shuttle    Flag user messages over a length threshold (likely cross-harness pastes).

All output is JSONL on stdout (one record per line), unless --text is passed
where supported. Stdlib only, no external deps.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional

CC_ROOT = Path.home() / ".claude" / "projects"
PI_ROOT = Path.home() / ".pi" / "agent" / "sessions"


# ---------- cwd encoding ----------

def encode_cwd_cc(cwd: str) -> str:
    """/Users/foo.bar/code → -Users-foo-bar-code (slashes AND dots → dash)."""
    p = os.path.realpath(cwd)
    return p.replace("/", "-").replace(".", "-")


def encode_cwd_pi(cwd: str) -> str:
    """/Users/foo.bar/code → --Users-foo.bar-code-- (slashes → dash, dots kept, --bookends--)."""
    p = os.path.realpath(cwd)
    inner = p.replace("/", "-")
    return f"-{inner}--"


def decode_cwd_cc(dirname: str) -> str:
    """Best-effort inverse: dashes-to-slashes, but dots are ambiguous (lossy)."""
    return dirname.replace("-", "/")


def decode_cwd_pi(dirname: str) -> str:
    inner = dirname.strip("-")
    return inner.replace("-", "/")


# ---------- session discovery ----------

@dataclass
class Session:
    harness: str          # "cc" or "pi"
    path: Path
    cwd: Optional[str]
    started: Optional[str]   # ISO8601
    ended: Optional[str]
    line_count: int
    parent_session: Optional[str] = None  # for CC subagents

    def to_dict(self) -> dict:
        return {
            "harness": self.harness,
            "path": str(self.path),
            "cwd": self.cwd,
            "started": self.started,
            "ended": self.ended,
            "line_count": self.line_count,
            "parent_session": self.parent_session,
        }


def _scan_jsonl(path: Path) -> tuple[Optional[str], Optional[str], Optional[str], int]:
    """Return (cwd, first_ts, last_ts, line_count). Tolerant of corrupt lines."""
    cwd = None
    first_ts = None
    last_ts = None
    n = 0
    try:
        with path.open() as fp:
            for line in fp:
                n += 1
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if cwd is None:
                    cwd = d.get("cwd")
                ts = d.get("timestamp")
                if ts:
                    if first_ts is None:
                        first_ts = ts
                    last_ts = ts
    except OSError:
        pass
    return cwd, first_ts, last_ts, n


def _iter_cc_sessions(cwd_filter: Optional[str]) -> Iterator[Session]:
    if not CC_ROOT.exists():
        return
    if cwd_filter:
        # Prefix-match the encoded form to handle worktree-suffixed dirs.
        prefix = encode_cwd_cc(cwd_filter)
        candidates = [d for d in CC_ROOT.iterdir() if d.is_dir() and d.name.startswith(prefix)]
    else:
        candidates = [d for d in CC_ROOT.iterdir() if d.is_dir()]
    for proj in candidates:
        for f in proj.glob("*.jsonl"):
            cwd, first, last, n = _scan_jsonl(f)
            yield Session(
                harness="cc",
                path=f,
                cwd=cwd or decode_cwd_cc(proj.name),
                started=first,
                ended=last,
                line_count=n,
            )
        sub = proj / "subagents"
        if sub.is_dir():
            for f in sub.glob("*.jsonl"):
                cwd, first, last, n = _scan_jsonl(f)
                yield Session(
                    harness="cc",
                    path=f,
                    cwd=cwd or decode_cwd_cc(proj.name),
                    started=first,
                    ended=last,
                    line_count=n,
                    parent_session=proj.name,
                )


def _iter_pi_sessions(cwd_filter: Optional[str]) -> Iterator[Session]:
    if not PI_ROOT.exists():
        return
    if cwd_filter:
        prefix = encode_cwd_pi(cwd_filter).rstrip("-")
        # PI dirs look like --Users-...-- ; match by stripping bookends.
        candidates = []
        for d in PI_ROOT.iterdir():
            if not d.is_dir():
                continue
            stripped = d.name.strip("-")
            if stripped.startswith(prefix.strip("-")):
                candidates.append(d)
    else:
        candidates = [d for d in PI_ROOT.iterdir() if d.is_dir()]
    for proj in candidates:
        for f in proj.glob("*.jsonl"):
            cwd, first, last, n = _scan_jsonl(f)
            yield Session(
                harness="pi",
                path=f,
                cwd=cwd or decode_cwd_pi(proj.name),
                started=first,
                ended=last,
                line_count=n,
            )


def discover_sessions(cwd_filter: Optional[str] = None) -> Iterator[Session]:
    yield from _iter_cc_sessions(cwd_filter)
    yield from _iter_pi_sessions(cwd_filter)


# ---------- line iteration with format adapters ----------

@dataclass
class Event:
    """Normalized conversational event from either harness."""
    harness: str
    timestamp: Optional[str]
    role: str  # "user", "assistant", "tool_result", "system", "other"
    text: str
    tool_name: Optional[str] = None
    tool_input: Optional[dict] = None
    raw_type: Optional[str] = None  # original type/role for debugging


def _cc_blocks_to_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t == "text":
                out.append(b.get("text", ""))
            elif t == "tool_result":
                inner = b.get("content")
                if isinstance(inner, str):
                    out.append(inner)
                elif isinstance(inner, list):
                    out.append(_cc_blocks_to_text(inner))
        return "\n".join(out)
    return ""


def iter_events(path: Path) -> Iterator[Event]:
    """Yield normalized events from a session JSONL."""
    harness = "cc" if "/.claude/" in str(path) else "pi"
    try:
        fp = path.open()
    except OSError:
        return
    with fp:
        for line in fp:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = d.get("timestamp")
            if harness == "cc":
                t = d.get("type")
                if t == "user":
                    msg = d.get("message", {}) or {}
                    c = msg.get("content", "")
                    if isinstance(c, list):
                        # User messages can contain tool_result blocks.
                        for b in c:
                            if isinstance(b, dict) and b.get("type") == "tool_result":
                                inner = b.get("content", "")
                                txt = inner if isinstance(inner, str) else _cc_blocks_to_text(inner)
                                yield Event(harness, ts, "tool_result", txt, raw_type="tool_result")
                            elif isinstance(b, dict) and b.get("type") == "text":
                                yield Event(harness, ts, "user", b.get("text", ""), raw_type="user")
                    else:
                        yield Event(harness, ts, "user", str(c), raw_type="user")
                elif t == "assistant":
                    msg = d.get("message", {}) or {}
                    c = msg.get("content", [])
                    if isinstance(c, list):
                        text_parts = []
                        for b in c:
                            if not isinstance(b, dict):
                                continue
                            bt = b.get("type")
                            if bt == "text":
                                text_parts.append(b.get("text", ""))
                            elif bt == "tool_use":
                                yield Event(
                                    harness, ts, "assistant",
                                    "\n".join(text_parts),
                                    tool_name=b.get("name"),
                                    tool_input=b.get("input"),
                                    raw_type="tool_use",
                                )
                                text_parts = []
                        if text_parts:
                            yield Event(harness, ts, "assistant", "\n".join(text_parts), raw_type="assistant")
            else:  # pi
                t = d.get("type")
                if t != "message":
                    continue
                msg = d.get("message", {}) or {}
                role = msg.get("role")
                c = msg.get("content", [])
                if not isinstance(c, list):
                    continue
                if role == "user":
                    text_parts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
                    if text_parts:
                        yield Event(harness, ts, "user", "\n".join(text_parts), raw_type="user")
                elif role == "assistant":
                    text_parts = []
                    for b in c:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "text":
                            text_parts.append(b.get("text", ""))
                        elif bt == "toolCall":
                            yield Event(
                                harness, ts, "assistant",
                                "\n".join(text_parts),
                                tool_name=b.get("name"),
                                tool_input=b.get("arguments"),
                                raw_type="toolCall",
                            )
                            text_parts = []
                    if text_parts:
                        yield Event(harness, ts, "assistant", "\n".join(text_parts), raw_type="assistant")
                elif role == "toolResult":
                    text_parts = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
                    if text_parts:
                        yield Event(harness, ts, "tool_result", "\n".join(text_parts), raw_type="toolResult")


# ---------- subcommands ----------

def _ts_in_range(ts: Optional[str], since: Optional[str], until: Optional[str]) -> bool:
    if not (since or until):
        return True
    if not ts:
        return False
    try:
        t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return False
    if since:
        try:
            s = datetime.fromisoformat(since.replace("Z", "+00:00"))
            if s.tzinfo is None:
                s = s.replace(tzinfo=timezone.utc)
            if t < s:
                return False
        except ValueError:
            pass
    if until:
        try:
            u = datetime.fromisoformat(until.replace("Z", "+00:00"))
            if u.tzinfo is None:
                u = u.replace(tzinfo=timezone.utc)
            if t > u:
                return False
        except ValueError:
            pass
    return True


def _grep_session(path: Path, pattern: str) -> bool:
    """Plain substring grep over the raw JSONL bytes."""
    try:
        with path.open("rb") as fp:
            needle = pattern.encode()
            for line in fp:
                if needle in line:
                    return True
    except OSError:
        return False
    return False


def cmd_find(args) -> int:
    cwd = args.cwd
    for s in discover_sessions(cwd_filter=cwd):
        # time-range filter: a session matches if its [started, ended] overlaps
        # the requested window.
        if args.since and s.ended and s.ended < args.since:
            continue
        if args.until and s.started and s.started > args.until:
            continue
        if args.grep and not _grep_session(s.path, args.grep):
            continue
        rec = s.to_dict()
        if args.text:
            print(f"{rec['harness']}\t{rec['started'] or '-'}\t{rec['line_count']:>5}  {rec['path']}")
        else:
            print(json.dumps(rec))
    return 0


def cmd_prompts(args) -> int:
    p = Path(args.session)
    if not p.exists():
        print(f"error: {p} does not exist", file=sys.stderr)
        return 2
    skip_synth = re.compile(r"^<(command|local|bash|task|system)-?")
    for ev in iter_events(p):
        if ev.role != "user":
            continue
        if not ev.text or not ev.text.strip():
            continue
        if skip_synth.match(ev.text.strip()):
            continue
        if not _ts_in_range(ev.timestamp, args.since, args.until):
            continue
        if args.text:
            preview = ev.text.replace("\n", " ")
            if len(preview) > args.preview:
                preview = preview[: args.preview] + "…"
            print(f"{ev.timestamp or '-'}  {preview}")
        else:
            print(json.dumps({
                "timestamp": ev.timestamp,
                "harness": ev.harness,
                "text": ev.text,
            }))
    return 0


def cmd_tools(args) -> int:
    p = Path(args.session)
    if not p.exists():
        print(f"error: {p} does not exist", file=sys.stderr)
        return 2
    name_filter = set(args.name) if args.name else None
    file_filter = args.file
    for ev in iter_events(p):
        if ev.tool_name is None:
            continue
        if name_filter and ev.tool_name not in name_filter:
            continue
        if not _ts_in_range(ev.timestamp, args.since, args.until):
            continue
        # File filter: substring match on stringified input.
        if file_filter:
            if file_filter not in json.dumps(ev.tool_input or {}, default=str):
                continue
        if args.text:
            inp = json.dumps(ev.tool_input or {}, default=str)
            if len(inp) > args.preview:
                inp = inp[: args.preview] + "…"
            print(f"{ev.timestamp or '-'}  {ev.tool_name}  {inp}")
        else:
            print(json.dumps({
                "timestamp": ev.timestamp,
                "harness": ev.harness,
                "tool": ev.tool_name,
                "input": ev.tool_input,
            }, default=str))
    return 0


def cmd_subagents(args) -> int:
    """List subagent transcripts under a Claude Code parent session.

    Argument can be either the parent session JSONL path or its directory name
    (e.g. '7ac2ac42-3cd7-...'). pi has no equivalent.
    """
    arg = args.parent
    p = Path(arg)
    if p.suffix == ".jsonl":
        # parent session jsonl → look for sibling <stem>/subagents/
        subdir = p.parent / p.stem / "subagents"
    elif p.is_dir():
        subdir = p / "subagents"
    else:
        # treat as a session UUID; search under CC_ROOT.
        found = None
        for proj in CC_ROOT.iterdir():
            cand = proj / arg / "subagents"
            if cand.is_dir():
                found = cand
                break
        if found is None:
            print(f"error: could not locate subagents dir for {arg}", file=sys.stderr)
            return 2
        subdir = found
    if not subdir.is_dir():
        print(f"(no subagents directory at {subdir})", file=sys.stderr)
        return 0
    for f in sorted(subdir.glob("*.jsonl")):
        cwd, first, last, n = _scan_jsonl(f)
        # Surface the first non-synthetic user prompt as a one-line label.
        label = ""
        for ev in iter_events(f):
            if ev.role == "user" and ev.text.strip() and not ev.text.startswith("<"):
                label = ev.text.replace("\n", " ")[:160]
                break
        rec = {
            "path": str(f),
            "started": first,
            "line_count": n,
            "first_prompt": label,
        }
        if args.text:
            print(f"{first or '-'}  {n:>4}  {f.name}  {label}")
        else:
            print(json.dumps(rec))
    return 0


def cmd_shuttle(args) -> int:
    """Flag user messages whose length suggests they're pasted from another agent.

    Heuristic only: messages above --threshold characters that aren't synthetic
    wrappers. The calling agent decides whether each match is actually a shuttle.
    """
    p = Path(args.session)
    if not p.exists():
        print(f"error: {p} does not exist", file=sys.stderr)
        return 2
    skip_synth = re.compile(r"^<(command|local|bash|task|system)-?")
    for ev in iter_events(p):
        if ev.role != "user":
            continue
        text = (ev.text or "").strip()
        if not text or skip_synth.match(text):
            continue
        if len(text) < args.threshold:
            continue
        if args.text:
            preview = text.replace("\n", " ")[: args.preview]
            print(f"{ev.timestamp or '-'}  [{len(text)} chars]  {preview}…")
        else:
            print(json.dumps({
                "timestamp": ev.timestamp,
                "harness": ev.harness,
                "length": len(text),
                "preview": text[:400],
            }))
    return 0


# ---------- arg parsing ----------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="archaeology", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    pf = sub.add_parser("find", help="list sessions matching cwd / time / grep")
    pf.add_argument("--cwd", help="prefix-match (realpath) on session cwd")
    pf.add_argument("--since", help="ISO8601 lower bound on session timestamps")
    pf.add_argument("--until", help="ISO8601 upper bound on session timestamps")
    pf.add_argument("--grep", help="substring pattern; matches if any raw JSONL line contains it")
    pf.add_argument("--text", action="store_true", help="human-readable output")
    pf.set_defaults(func=cmd_find)

    pp = sub.add_parser("prompts", help="enumerate user prompts from a session")
    pp.add_argument("session", help="path to a session JSONL file")
    pp.add_argument("--since", help="ISO8601 lower bound")
    pp.add_argument("--until", help="ISO8601 upper bound")
    pp.add_argument("--text", action="store_true", help="human-readable output")
    pp.add_argument("--preview", type=int, default=300, help="max chars in --text preview")
    pp.set_defaults(func=cmd_prompts)

    pt = sub.add_parser("tools", help="sample assistant tool calls (+ inputs) from a session")
    pt.add_argument("session", help="path to a session JSONL file")
    pt.add_argument("--name", action="append", help="filter by tool name (repeatable)")
    pt.add_argument("--file", help="substring filter on tool input JSON (e.g. a file path)")
    pt.add_argument("--since", help="ISO8601 lower bound")
    pt.add_argument("--until", help="ISO8601 upper bound")
    pt.add_argument("--text", action="store_true", help="human-readable output")
    pt.add_argument("--preview", type=int, default=200, help="max chars in --text preview")
    pt.set_defaults(func=cmd_tools)

    ps = sub.add_parser("subagents", help="list subagent transcripts under a CC parent session")
    ps.add_argument("parent", help="parent session JSONL path, parent session dir, or parent session UUID")
    ps.add_argument("--text", action="store_true", help="human-readable output")
    ps.set_defaults(func=cmd_subagents)

    psh = sub.add_parser("shuttle", help="flag long user messages (likely cross-harness pastes)")
    psh.add_argument("session", help="path to a session JSONL file")
    psh.add_argument("--threshold", type=int, default=1500, help="min chars to flag (default 1500)")
    psh.add_argument("--text", action="store_true", help="human-readable output")
    psh.add_argument("--preview", type=int, default=200, help="max chars in --text preview")
    psh.set_defaults(func=cmd_shuttle)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
