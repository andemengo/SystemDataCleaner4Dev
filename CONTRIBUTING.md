# Contributing to SystemDataCleaner4Dev

Thanks for your interest in contributing!

## Getting Started

```bash
git clone https://github.com/andemengo/SystemDataCleaner4Dev.git
cd SystemDataCleaner4Dev
swift SystemDataCleaner4Dev.swift
```

## Code Style

This project follows strict coding conventions documented in [`CLAUDE.md`](CLAUDE.md). The key rules:

- **Zero `if` statements** — use `guard`, `switch`, pattern matching, ternary, and functional transforms
- **Functional style** — prefer `map`, `filter`, `reduce` over imperative loops
- **SOLID principles** — protocols for abstraction, single responsibility per type
- **Single-file design** — do not split into multiple files or add SPM

Please read `CLAUDE.md` before submitting code.

## Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-change`)
3. Make your changes following the code style in `CLAUDE.md`
4. Test by running `swift SystemDataCleaner4Dev.swift` and verifying the interactive flow works
5. Verify it compiles: `make build`
6. Commit with a clear message
7. Open a Pull Request

## Reporting Issues

Open an issue on GitHub with:
- Your macOS version
- Your Xcode version
- What happened vs. what you expected
- Any error output from the terminal

## Questions?

Open a discussion or issue — happy to help.
