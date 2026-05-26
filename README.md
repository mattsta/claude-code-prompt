# Claude Code Prompt

Custom Claude Code status line infrastructure with:

- `statusline.py`: Python reference implementation.
- `statusline-zig/`: Zig implementation with unit tests and Python parity tests.

The status line reads Claude Code's JSON status-line payload from stdin and writes a two-line ANSI-colored prompt to stdout. It shows the current workspace, model, effort/thinking state, token totals, context usage, changed lines, API duration, cost, and optional rate-limit windows.

## Requirements

- Python 3 for `statusline.py`.
- Zig 0.16.0 for `statusline-zig/`.

## Repository Layout

```text
.
├── scripts
│   └── setup.py
├── statusline.py
└── statusline-zig
    ├── build.zig
    ├── src
    └── tests
```

## Automated Claude Setup

Install the managed Claude Code status line into `~/.claude/claude-code-prompt`,
build the Zig implementation there, and inject the matching `statusLine`
setting into `~/.claude/settings.json`:

```bash
python3 scripts/setup.py
```

The setup script uses Python's standard `json` module to update settings. It
copies the Python reference, Zig source, tests, README, and license, then runs
`zig build -Doptimize=ReleaseFast` inside the installed copy. The script locates
project sources relative to its own path, so it does not need to be run from the
repository root. Existing settings are preserved, except `statusLine` is
replaced with:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/you/.claude/claude-code-prompt/statusline-zig/zig-out/bin/statusline",
    "padding": 0
  }
}
```

The setup script writes the expanded absolute command path for the current
machine.

If `~/.claude/settings.json` already exists and changes are needed, the setup
script writes a timestamped backup next to it. For test installs, override the
target:

```bash
python3 scripts/setup.py --claude-dir /tmp/claude-test
```

## Python Version

Run directly with Python 3:

```bash
chmod +x statusline.py
./statusline.py < statusline-zig/tests/fixtures/01_basic.json
```

Add one of these commands to `~/.claude/settings.json`.

Python settings example:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude-code-prompt/statusline.py",
    "padding": 0
  }
}
```

The Python implementation uses `context_window.current_usage` when Claude Code provides it. For older inputs, it can fall back to scanning the transcript tail, then finally to cumulative session totals marked with `~`.

## Zig Version

Build the optimized binary:

```bash
cd statusline-zig
zig build -Doptimize=ReleaseFast
./zig-out/bin/statusline < tests/fixtures/01_basic.json
```

Zig settings example:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude-code-prompt/statusline-zig/zig-out/bin/statusline",
    "padding": 0
  }
}
```

The Zig implementation is intended for daily use once built. It avoids Python startup cost and ignores unknown JSON fields so newer Claude Code payloads do not break parsing.

## Tests

Run Zig unit tests:

```bash
cd statusline-zig
zig build test
```

Compare Zig output against the Python reference across fixtures:

```bash
cd statusline-zig
zig build parity
```

Run both gates:

```bash
cd statusline-zig
zig build check
```

`zig build parity` expects the Python reference at `../statusline.py`. You can also invoke the script manually with explicit paths:

```bash
statusline-zig/tests/parity.sh statusline-zig/zig-out/bin/statusline statusline.py
```

## Notes

- The output assumes ANSI color support.
- The render width is fixed at 140 columns because Claude Code status-line commands do not reliably receive the live terminal width.
- The displayed context percentage uses a 33k-token autocompact buffer.
