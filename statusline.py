#!/usr/bin/env python3
"""
Enhanced Claude Code status line.
Layout: prompt (left-aligned) | metadata (right-aligned)
"""

import json
import os
import re
import sys
import time
from pathlib import Path

# Constants
AUTOCOMPACT_BUFFER = 33_000  # Reserved for compaction, adjust if needed
# No reliable way to detect terminal width: the statusline runs as a forked
# subprocess with no controlling TTY, $COLUMNS isn't consistently exported (and
# is stale across resizes when it is), and the Claude Code stdin JSON doesn't
# carry width. Best-guess fixed.
TERM_WIDTH = 140

# ANSI colors
C_RESET = "\033[0m"
C_RED = "\033[31m"
C_GREEN = "\033[32m"
C_YELLOW = "\033[33m"
C_BLUE = "\033[34m"
C_MAGENTA = "\033[35m"
C_CYAN = "\033[36m"
C_DIM = "\033[2m"


def strip_ansi(text):
    """Remove ANSI escape codes to get visible length."""
    return re.sub(r"\033\[[0-9;]*m", "", text)


def visible_len(text):
    """Get visible length of text (excluding ANSI codes)."""
    return len(strip_ansi(text))


def fmt_k(n):
    """Format number as Xk or X.Xk"""
    if n >= 1000:
        return f"{n / 1000:.0f}k" if n >= 10000 else f"{n / 1000:.1f}k"
    return str(n)


def fmt_duration(ms):
    """Format milliseconds as human-readable duration."""
    secs = ms / 1000
    if secs < 60:
        return f"{secs:.0f}s"
    mins = int(secs // 60)
    secs = int(secs % 60)
    if mins < 60:
        return f"{mins}m{secs:02d}s"
    hours = int(mins // 60)
    mins = int(mins % 60)
    return f"{hours}h{mins:02d}m"


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("[?] error")
        return

    # Debug: save last input for checking formatting offline or in testing
    if False:
        try:
            with (
                Path("~/.claude/statusline-lastinput.json").expanduser().open("w") as f
            ):
                json.dump(data, f, indent=2)
        except Exception:
            pass

    # === Extract data ===

    # Model
    model = data.get("model", {}).get("display_name", "?")

    # Cumulative session tokens
    ctx = data.get("context_window", {})
    total_in = ctx.get("total_input_tokens", 0)
    total_out = ctx.get("total_output_tokens", 0)
    ctx_size = ctx.get("context_window_size", 200_000)

    # Usable context (excluding autocompact buffer)
    usable_ctx = ctx_size - AUTOCOMPACT_BUFFER

    # Primary source: Claude Code passes the latest usage directly in stdin JSON.
    # Avoid the transcript: huge messages (seen up to ~300KB) can fully cover any
    # tail window, causing scans to find no parseable line and fall back to a
    # session-cumulative total — the spurious "7742k"-style flashes.
    approx = ""
    cu = ctx.get("current_usage") or {}
    current_ctx = (
        cu.get("input_tokens", 0)
        + cu.get("cache_creation_input_tokens", 0)
        + cu.get("cache_read_input_tokens", 0)
    )

    transcript_path = data.get("transcript_path")
    transcript_file = Path(transcript_path) if transcript_path else None
    if current_ctx == 0 and transcript_file and transcript_file.exists():
        # Fallback for older Claude Code versions without current_usage.
        # Read up to 1MB so post-compact summary messages fit.
        try:
            with transcript_file.open("rb") as f:
                f.seek(0, 2)
                size = f.tell()
                read_size = min(size, 1_048_576)
                f.seek(max(0, size - read_size))
                tail = f.read().decode("utf-8", errors="ignore")

            for line in reversed(tail.splitlines()):
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("isSidechain"):
                    continue
                inner = msg.get("message") or {}
                usage = inner.get("usage")
                if not usage:
                    continue
                current_ctx = (
                    usage.get("input_tokens", 0)
                    + usage.get("cache_creation_input_tokens", 0)
                    + usage.get("cache_read_input_tokens", 0)
                )
                if current_ctx > 0:
                    break
        except Exception:
            pass

    # Last resort: cumulative session total (clearly marked).
    if current_ctx == 0:
        current_ctx = total_in + total_out
        approx = "~"

    # Context percentage of usable space
    pct = int((current_ctx / usable_ctx) * 100) if usable_ctx > 0 else 0

    # Color for context percentage
    if pct < 50:
        pct_color = C_GREEN
    elif pct < 80:
        pct_color = C_YELLOW
    else:
        pct_color = C_RED

    # Cost and stats
    cost_data = data.get("cost", {})
    cost = cost_data.get("total_cost_usd", 0)
    lines_added = cost_data.get("total_lines_added", 0)
    lines_removed = cost_data.get("total_lines_removed", 0)
    api_duration_ms = cost_data.get("total_api_duration_ms", 0)

    # Rate limits (Claude.ai subscribers only — absent otherwise).
    def _rl_color(p):
        if p < 50:
            return C_GREEN
        if p < 80:
            return C_YELLOW
        return C_RED

    def _fmt_until(epoch):
        if not isinstance(epoch, (int, float)):
            return ""
        secs = int(epoch - time.time())
        if secs <= 0:
            return "now"
        mins = secs // 60
        if mins < 60:
            return f"{mins}m"
        hours, mins = divmod(mins, 60)
        if hours < 24:
            return f"{hours}h{mins:02d}m"
        days, hours = divmod(hours, 24)
        return f"{days}d{hours:02d}h"

    rl = data.get("rate_limits") or {}
    rl_bits = []
    for label, key in (("5h", "five_hour"), ("7D", "seven_day")):
        win = rl.get(key) or {}
        p = win.get("used_percentage")
        if p is None:
            continue
        pi = int(p)
        bit = f"{C_DIM}{label}:{C_RESET}{_rl_color(pi)}{pi}%{C_RESET}"
        until = _fmt_until(win.get("resets_at"))
        if until:
            bit += f" {C_DIM}({until}){C_RESET}"
        rl_bits.append(bit)
    rl_str = (
        f"{C_DIM}[{C_RESET}{f' {C_DIM}|{C_RESET} '.join(rl_bits)}{C_DIM}]{C_RESET}"
        if rl_bits
        else ""
    )

    # Prompt: user@host:path
    user = os.environ.get("USER", "?")
    host = os.uname().nodename.split(".")[0]
    cwd = str(
        data.get("workspace", {}).get("current_dir") or data.get("cwd") or Path.cwd()
    )
    home = str(Path("~").expanduser())
    if cwd.startswith(home):
        cwd = "~" + cwd[len(home) :]

    # Effort / thinking (only present on supporting models)
    effort_level = (data.get("effort") or {}).get("level")
    thinking_on = bool((data.get("thinking") or {}).get("enabled"))
    effort_bits = []
    if effort_level:
        effort_bits.append(f"{C_DIM}e:{C_RESET}{C_CYAN}{effort_level}{C_RESET}")
    if thinking_on:
        effort_bits.append(f"{C_CYAN}+T{C_RESET}")
    effort_str = " ".join(effort_bits)

    # === Build output ===
    # Two lines, both right-aligned via padding math:
    #   line 1: user@host:cwd .................. model [effort]
    #   line 2: ............................... in/out | ctx | lines | dur $cost

    line1_left = (
        f"{C_RED}{user}{C_RESET}@{C_MAGENTA}{host}{C_RESET}:{C_BLUE}{cwd}{C_RESET}"
    )
    line1_right_parts = [f"{C_CYAN}{model}{C_RESET}"]
    if effort_str:
        line1_right_parts.append(effort_str)
    line1_right = "  ".join(line1_right_parts)

    lines_str = f"{C_GREEN}+{lines_added:,}{C_RESET};{C_RED}-{lines_removed:,}{C_RESET}"
    stats_block = " | ".join(
        [
            f"in:{C_YELLOW}{fmt_k(total_in)}{C_RESET} out:{C_YELLOW}{fmt_k(total_out)}{C_RESET}",
            f"ctx:{pct_color}{approx}{pct}%{C_RESET} {C_DIM}({fmt_k(current_ctx)}/{fmt_k(usable_ctx)}){C_RESET}",
            lines_str,
            f"{C_DIM}{fmt_duration(api_duration_ms)}{C_RESET} {C_MAGENTA}${cost:,.2f}{C_RESET}",
        ]
    )

    # Line 2: stats float left, rate_limits float right (under model+effort).
    # When rate_limits is absent (non-subscribers), keep stats right-aligned so
    # the line doesn't feel orphaned on the left.
    if rl_str:
        line2_left, line2_right = stats_block, rl_str
    else:
        line2_left, line2_right = "", stats_block

    def _render(left, right):
        pad = TERM_WIDTH - visible_len(left) - visible_len(right)
        if pad < 2:
            pad = 2
        return f"{left}{' ' * pad}{right}"

    print(_render(line1_left, line1_right))
    print(_render(line2_left, line2_right), end="")


if __name__ == "__main__":
    main()
