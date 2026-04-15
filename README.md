# SystemDataCleaner4Dev

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)]()

> Reclaim tens of gigabytes of "System Data" on your Mac by cleaning up old Xcode simulator data.

---

## The Problem

If you're an iOS developer, you've probably noticed your Mac's **System Data** growing silently — 50 GB, 80 GB, sometimes over 100 GB. A major culprit is **Xcode simulator data**: every runtime version and device image takes up several gigabytes, and they pile up over months of development.

Old simulators from iOS 16, iOS 17, tvOS, watchOS — they're all still sitting in `~/Library/Developer/CoreSimulator/Devices/`, eating your disk space. Apple provides no easy way to bulk-clean them.

**SystemDataCleaner4Dev fixes that in one command.**

## Demo

```
  ╭──────────────────────────────────────────────╮
  │  SystemDataCleaner4Dev                       │
  │  Interactive simulator cleanup for macOS     │
  ╰──────────────────────────────────────────────╯

  Found 47 simulators across 8 runtimes

  iOS 16.4  — 6 simulators
  iOS 17.0  — 6 simulators
  iOS 17.5  — 6 simulators
  iOS 18.0  — 7 simulators (2 booted)
  tvOS 17.0 — 4 simulators
  watchOS 10.0 — 5 simulators
  visionOS 2.0 — 6 simulators
  iOS 18.4  — 7 simulators (1 booted)

  Which runtimes do you want to KEEP?
  Enter numbers separated by commas (e.g. 1,3,5)
  'a' = select all, 'n' = select none

  [1] iOS 16.4 (6 sims)
  [2] iOS 17.0 (6 sims)
  [3] iOS 17.5 (6 sims)
  [4] iOS 18.0 (7 sims) ← active
  [5] tvOS 17.0 (4 sims)
  [6] watchOS 10.0 (5 sims)
  [7] visionOS 2.0 (6 sims)
  [8] iOS 18.4 (7 sims) ← active

  → Your choice: 4,8

  ── Cleanup Summary ─────────────────────────────

  Keep:   14 simulators
  Remove: 33 simulators

  Proceed with deletion? [y/N]: y

  ✓ iOS 16.4 — iPhone 14
  ✓ iOS 16.4 — iPhone 14 Pro
  ...

  ── Results ─────────────────────────────────────
  ✓ Deleted: 33 simulators

  Done! Check storage: System Settings → General → Storage
```

## Installation

### Quick Run (no install needed)

Download and run directly — no cloning, no building:

```bash
curl -fsSL https://raw.githubusercontent.com/andemengo/SystemDataCleaner4Dev/main/SystemDataCleaner4Dev.swift -o /tmp/sdc.swift && swift /tmp/sdc.swift
```

### Clone and Run

```bash
git clone https://github.com/andemengo/SystemDataCleaner4Dev.git
cd SystemDataCleaner4Dev
swift SystemDataCleaner4Dev.swift
```

### Install as a Command

Compile to a native binary and install system-wide:

```bash
git clone https://github.com/andemengo/SystemDataCleaner4Dev.git
cd SystemDataCleaner4Dev
sudo make install
```

Then run from anywhere:

```bash
systemdatacleaner
```

To uninstall:

```bash
sudo make uninstall
```

## Usage

The tool is fully interactive. Just run it and follow the prompts:

1. **Scan** — The tool loads all installed simulators via `xcrun simctl`
2. **Select runtimes** — Choose which runtimes (iOS versions) to **keep** (safer than choosing what to delete)
3. **Prune devices** — Optionally remove individual simulators from kept runtimes
4. **Review** — See a full summary of what will be deleted, with warnings for booted simulators
5. **Confirm** — Nothing is deleted until you explicitly confirm

## How It Works

- Reads simulator data from `xcrun simctl list devices -j` (JSON output)
- Groups simulators by runtime (platform + version)
- Deletes via `xcrun simctl delete <UDID>`
- Falls back to direct removal of `~/Library/Developer/CoreSimulator/Devices/<UDID>` if simctl fails
- Suggests cleaning up unused runtime images after deletion

## What Gets Deleted

- **Simulator device data** — the per-device storage in `~/Library/Developer/CoreSimulator/Devices/`
- Xcode can recreate any simulator at any time via **Window > Devices and Simulators > +**

**What is NOT deleted:**

- Runtime images (the tool provides a tip on how to remove these manually)
- Xcode itself
- Any non-simulator files

## Requirements

- **macOS** (any recent version)
- **Xcode** or **Xcode Command Line Tools** (`xcode-select --install`)
- **Swift** (included with Xcode)

## Code Design

This project follows a strict coding discipline:

- **Single file** — download, audit, and run with zero friction
- **Zero `if` statements** — all control flow uses `guard`, `switch`, pattern matching, and functional transforms
- **SOLID principles** — protocol-oriented with dependency injection
- **Functional style** — `map`, `filter`, `reduce` over imperative loops

See [`CLAUDE.md`](CLAUDE.md) for full coding guidelines.

## Contributing

Contributions are welcome! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`CLAUDE.md`](CLAUDE.md) before submitting.

## License

[MIT](LICENSE) — Andrea Mengoli
