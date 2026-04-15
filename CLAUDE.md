# CLAUDE.md — AI Contributor Guide

Instructions for AI agents (Claude Code, Copilot, Cursor, etc.) working on this project.

## Project Overview

**SystemDataCleaner4Dev** is an interactive CLI tool that helps macOS/iOS developers reclaim disk space by cleaning up old Xcode simulator data — a major contributor to the "System Data" storage category.

- **Language:** Swift (script mode, `#!/usr/bin/env swift`)
- **Dependencies:** None (Foundation only)
- **Run:** `swift SystemDataCleaner4Dev.swift`
- **Compile:** `make build` (produces native binary via `swiftc -O`)

## Architecture

### Single-File Design

This is intentionally a single `.swift` file. Do NOT split it into multiple files or add Swift Package Manager (`Package.swift`). The value proposition is simplicity: download one file, run it. SPM would add friction for zero benefit.

### Code Organization (MARK Sections)

The file is organized top-to-bottom in dependency order:

1. **Errors** — `CleanerError` enum
2. **Models** — Value types: `SimctlOutput`, `SimDevice`, `RuntimeGroup`, `DeviceEntry`, `CleanupPlan`, `DeletionResult`, `CleanupResult`
3. **Protocols** — Abstractions: `CommandExecuting`, `UserInteracting`, `SimulatorLoading`, `SimulatorDeleting`
4. **Terminal Colors** — `Color` enum and `styled()` helper
5. **ShellExecutor** — `CommandExecuting` implementation (runs shell commands)
6. **ConsoleInput** — `UserInteracting` implementation (reads user input)
7. **RuntimeParser** — Parses simulator runtime keys into platform + version
8. **SimulatorLoader** — `SimulatorLoading` implementation (loads simulators via `xcrun simctl`)
9. **SimulatorCleaner** — `SimulatorDeleting` implementation (deletes simulators)
10. **Format Helpers** — `Format` enum for label/summary formatting
11. **Presenter** — All terminal output (print statements live here, nowhere else)
12. **CleanupPlanner** — Builds a `CleanupPlan` via interactive user selection
13. **CleanupExecutor** — Executes the plan (deletes simulators, collects results)
14. **App** — Orchestrates the full flow: load → plan → confirm → execute → report
15. **CLI Flags** — `--version` and `--help` handlers
16. **Composition Root** — Wires all dependencies and calls `App.run()`

### Composition Root Pattern

All concrete types are instantiated at the bottom of the file and injected into `App`. The `App` struct depends only on protocols, never on concrete implementations. This makes the code testable — you can inject mock implementations of any protocol.

## Code Style Rules

### Zero `if` — Strict Rule

This codebase contains **zero `if` statements**. This is a deliberate design choice, not a suggestion. Every conditional must use one of:

| Instead of `if` | Use |
|---|---|
| Early exit | `guard condition else { return }` |
| Branching on enum/value | `switch value { case ...: }` |
| Branching on boolean | `switch boolValue { case true: ... case false: ... }` |
| Inline conditional | Ternary `condition ? a : b` |
| Conditional execution | `guard condition else { return }` at start of function |
| Collection filtering | `.filter { }`, `.compactMap { }` |
| Optional handling | `.map { }`, `.flatMap { }`, `??`, `guard let` |

**Before submitting any change, verify:** `grep -n '^\s*if ' SystemDataCleaner4Dev.swift` must return zero results.

### Functional Style

- Prefer `map`, `filter`, `reduce`, `compactMap`, `flatMap` over `for` loops with mutation
- Use `forEach` only for side effects (printing, appending to external state)
- Use `reduce(into:)` when accumulating into a mutable container
- Chain functional transforms into pipelines where readable

### SOLID Principles

- **Single Responsibility:** Each type does one thing. `Presenter` prints. `CleanupPlanner` builds plans. `SimulatorLoader` loads data.
- **Open/Closed:** Add new platforms by extending `RuntimeParser.knownPlatforms`. Add new output by adding methods to `Presenter`.
- **Liskov Substitution:** All protocol conformances are fully substitutable.
- **Interface Segregation:** Four focused protocols instead of one large one.
- **Dependency Inversion:** `App` depends on `SimulatorLoading`, `UserInteracting`, `SimulatorDeleting` — never on concrete types.

### Immutability

- Use `let` everywhere possible
- Model types use stored `let` properties with computed properties for derived values
- Avoid `var` outside of `reduce(into:)` accumulators and `guard` bindings

### Naming

- Types: `PascalCase` (`RuntimeGroup`, `CleanupPlan`)
- Members: `camelCase` (`bootedCount`, `isBooted`)
- Protocols: verb+ing (`CommandExecuting`, `SimulatorLoading`) or adjective (`UserInteracting`)
- Enum cases: `camelCase` (`simctlFailed`, `decodingFailed`)

## What NOT to Do

- **No `if` statements** — zero tolerance, use the alternatives above
- **No force unwraps** (`!`) — use `guard let`, `??`, or `compactMap`
- **No mutable global state** — all state flows through function parameters
- **No SPM / Package.swift** — this is a single-file script by design
- **No external dependencies** — Foundation only
- **No splitting into multiple files** — keep everything in `SystemDataCleaner4Dev.swift`
- **No `print()` outside of `Presenter`** — all terminal output goes through the `Presenter` enum (exception: `ConsoleInput.prompt` which prints the prompt text)

## Common Tasks

### Adding a new CLI flag

Add a new `case` to the `switch CommandLine.arguments.dropFirst().first` block in the "CLI Flags" section.

### Adding new terminal output

Add a `static func` to the `Presenter` enum. Use `guard` for conditional display:
```swift
static func printMyNewThing(_ value: SomeType) {
    guard someCondition else { return }
    print(styled("...", .cyan))
}
```

### Supporting a new simulator platform

Add the platform name to `RuntimeParser.knownPlatforms`. The parser handles the rest automatically.

### Adding a new deletion strategy

1. Create a new struct conforming to `SimulatorDeleting`
2. Inject it via the composition root

### Testing

The protocol-based architecture supports mock injection:
```swift
struct MockExecutor: CommandExecuting {
    func execute(_ command: String) -> (output: String, exitCode: Int32) {
        // return test data
    }
}
```

No test framework is currently set up (would require SPM), but the code is structured for testability.

## Build & Run

```bash
# Run as script (no compilation)
swift SystemDataCleaner4Dev.swift

# Compile optimized binary
make build

# Install to /usr/local/bin
make install

# Check version
swift SystemDataCleaner4Dev.swift --version
```
