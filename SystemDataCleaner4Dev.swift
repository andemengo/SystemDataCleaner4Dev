#!/usr/bin/env swift

// ============================================
// SystemDataCleaner4Dev
// Interactive Simulator Cleanup CLI for macOS
//
// Created by Andrea Mengoli
// Usage: swift SystemDataCleaner4Dev.swift
// ============================================

import Foundation

// MARK: - Errors

enum CleanerError: Error, CustomStringConvertible {
    case simctlFailed
    case decodingFailed(String)

    var description: String {
        switch self {
        case .simctlFailed:
            return "Failed to run 'xcrun simctl'. Is Xcode installed?"
        case .decodingFailed(let detail):
            return "Failed to parse simulator data: \(detail)"
        }
    }
}

// MARK: - Models

struct SimctlOutput: Decodable {
    let devices: [String: [SimDevice]]
}

struct SimDevice: Decodable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool
    let deviceTypeIdentifier: String?
    let lastBootedAt: String?

    var isBooted: Bool { state.lowercased() == "booted" }
}

struct RuntimeGroup {
    let runtimeKey: String
    let displayName: String
    let platform: String
    let version: String
    let devices: [SimDevice]

    var bootedCount: Int { devices.filter(\.isBooted).count }
    var hasBooted: Bool { bootedCount > 0 }
}

struct DeviceEntry {
    let device: SimDevice
    let runtime: String
}

struct CleanupPlan {
    let devicesToKeep: Set<String>
    let devicesToRemove: [DeviceEntry]
    let hasRemovedRuntimes: Bool

    var bootedToDelete: [DeviceEntry] { devicesToRemove.filter(\.device.isBooted) }
    var isEmpty: Bool { devicesToRemove.isEmpty }

    var groupedByRuntime: [(runtime: String, entries: [DeviceEntry])] {
        Dictionary(grouping: devicesToRemove, by: \.runtime)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.device.name < $1.device.name }) }
    }
}

struct DeletionResult {
    let entry: DeviceEntry
    let success: Bool
}

struct CleanupResult {
    let deletions: [DeletionResult]
    var deleted: Int { deletions.filter(\.success).count }
    var failed: Int { deletions.filter { !$0.success }.count }
}

// MARK: - Protocols

protocol CommandExecuting {
    func execute(_ command: String) -> (output: String, exitCode: Int32)
}

protocol UserInteracting {
    func prompt(_ text: String) -> String
    func multiSelect(items: [String], prompt: String) -> Set<Int>
    func confirm(_ prompt: String) -> Bool
}

protocol SimulatorLoading {
    func load() -> Result<[RuntimeGroup], CleanerError>
}

protocol SimulatorDeleting {
    func delete(device: SimDevice) -> Bool
}

// MARK: - Terminal Colors

enum Color: String {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"
}

func styled(_ text: String, _ colors: Color...) -> String {
    colors.map(\.rawValue).joined() + text + Color.reset.rawValue
}

// MARK: - Shell Executor

struct ShellExecutor: CommandExecuting {
    func execute(_ command: String) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}

// MARK: - Console Input

struct ConsoleInput: UserInteracting {
    func prompt(_ text: String) -> String {
        print(text, terminator: "")
        fflush(stdout)
        return Swift.readLine(strippingNewline: true) ?? ""
    }

    func multiSelect(items: [String], prompt promptText: String) -> Set<Int> {
        print()
        print(styled(promptText, .bold, .cyan))
        print(styled("  Enter numbers separated by commas (e.g. 1,3,5)", .dim))
        print(styled("  'a' = select all, 'n' = select none", .dim))
        print()

        items.enumerated().forEach { i, item in
            print("  \(styled("[\(i + 1)]", .bold)) \(item)")
        }
        print()

        let input = prompt(styled("  → Your choice: ", .yellow))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        switch input {
        case "a":
            return Set(0..<items.count)
        case "n", "":
            return []
        default:
            return Set(
                input.split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0 >= 1 && $0 <= items.count }
                    .map { $0 - 1 }
            )
        }
    }

    func confirm(_ promptText: String) -> Bool {
        ["y", "yes"].contains(
            prompt(styled(promptText + " [y/N]: ", .yellow)).lowercased()
        )
    }
}

// MARK: - Runtime Parser

enum RuntimeParser {
    private static let knownPlatforms = ["iOS", "xrOS", "visionOS", "tvOS", "watchOS"]
    private static let prefix = "com.apple.CoreSimulator.SimRuntime."

    static func parse(_ key: String) -> (platform: String, version: String) {
        let stripped = key.replacingOccurrences(of: prefix, with: "")

        return knownPlatforms
            .first { stripped.hasPrefix($0 + "-") }
            .map { platform in
                let version = String(stripped.dropFirst(platform.count + 1))
                    .replacingOccurrences(of: "-", with: ".")
                return (platform, version)
            }
            ?? fallback(stripped)
    }

    private static func fallback(_ value: String) -> (platform: String, version: String) {
        value.range(of: "-")
            .map { range in
                (
                    String(value[value.startIndex..<range.lowerBound]),
                    String(value[range.upperBound...]).replacingOccurrences(of: "-", with: ".")
                )
            }
            ?? ("Unknown", value)
    }
}

// MARK: - Simulator Loader

struct SimulatorLoader: SimulatorLoading {
    let executor: CommandExecuting

    func load() -> Result<[RuntimeGroup], CleanerError> {
        let result = executor.execute("xcrun simctl list devices -j")

        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8)
        else { return .failure(.simctlFailed) }

        return Result { try JSONDecoder().decode(SimctlOutput.self, from: data) }
            .mapError { .decodingFailed($0.localizedDescription) }
            .map(Self.buildGroups)
    }

    private static func buildGroups(from output: SimctlOutput) -> [RuntimeGroup] {
        output.devices
            .compactMap { key, devices -> RuntimeGroup? in
                let available = devices.filter(\.isAvailable)
                guard !available.isEmpty else { return nil }
                let parsed = RuntimeParser.parse(key)
                return RuntimeGroup(
                    runtimeKey: key,
                    displayName: "\(parsed.platform) \(parsed.version)",
                    platform: parsed.platform,
                    version: parsed.version,
                    devices: available
                )
            }
            .sorted { a, b in
                a.platform == b.platform
                    ? a.version.compare(b.version, options: .numeric) == .orderedAscending
                    : a.platform < b.platform
            }
    }
}

// MARK: - Simulator Deleter

struct SimulatorCleaner: SimulatorDeleting {
    let executor: CommandExecuting

    func delete(device: SimDevice) -> Bool {
        let result = executor.execute("xcrun simctl delete '\(device.udid)' 2>&1")

        switch result.exitCode {
        case 0:
            return true
        default:
            let path = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/\(device.udid)"
            return executor.execute("rm -rf '\(path)' 2>&1").exitCode == 0
        }
    }
}

// MARK: - Format Helpers

enum Format {
    static func runtimeLabel(_ group: RuntimeGroup) -> String {
        let suffix = group.hasBooted ? " \(styled("← active", .green))" : ""
        return "\(group.displayName) (\(group.devices.count) sims)\(suffix)"
    }

    static func deviceLabel(_ device: SimDevice) -> String {
        let icon = device.isBooted ? styled("●", .green) : styled("○", .dim)
        return "\(icon) \(device.name)"
    }

    static func runtimeSummary(_ group: RuntimeGroup) -> String {
        let booted = group.hasBooted ? styled(" (\(group.bootedCount) booted)", .green) : ""
        return "  \(styled(group.displayName, .bold))  — \(group.devices.count) simulators\(booted)"
    }
}

// MARK: - Presenter (Single Responsibility — all terminal output)

enum Presenter {
    static func printHeader() {
        print()
        print(styled("  ╭──────────────────────────────────────────────╮", .cyan))
        print("  " + styled("│", .cyan) + styled("  SystemDataCleaner4Dev", .bold) + "                       " + styled("│", .cyan))
        print("  " + styled("│", .cyan) + styled("  Interactive simulator cleanup for macOS", .dim) + "     " + styled("│", .cyan))
        print(styled("  ╰──────────────────────────────────────────────╯", .cyan))
        print()
    }

    static func printLoading() {
        print(styled("  Loading simulators...", .dim))
    }

    static func printError(_ error: CleanerError) {
        print(styled("  ✗ \(error.description)", .red))
    }

    static func printGroupsSummary(_ groups: [RuntimeGroup]) {
        let total = groups.reduce(0) { $0 + $1.devices.count }
        print(styled("  Found \(total) simulators across \(groups.count) runtimes\n", .green))
        groups.map(Format.runtimeSummary).forEach { print($0) }
    }

    static func printAllKeptWarning(kept: Int, total: Int) {
        guard kept == total else { return }
        print()
        print(styled("  You selected all runtimes — nothing to remove at this level.", .yellow))
        print(styled("  You can still remove individual simulators from each runtime.\n", .dim))
    }

    static func printRemovedRuntimes(_ runtimes: [RuntimeGroup]) {
        guard !runtimes.isEmpty else { return }
        let count = runtimes.reduce(0) { $0 + $1.devices.count }
        print()
        print(styled("  Runtimes to remove entirely (\(count) simulators):", .red))
        runtimes.forEach { rt in
            print("    \(styled("✗", .red)) \(rt.displayName) — \(rt.devices.count) simulators")
        }
    }

    static func printCleanupSummary(_ plan: CleanupPlan) {
        print()
        print(styled("  ── Cleanup Summary ─────────────────────────────", .cyan))
        print()
        print("  \(styled("Keep:", .green))   \(plan.devicesToKeep.count) simulators")
        print("  \(styled("Remove:", .red)) \(plan.devicesToRemove.count) simulators")
        print()
        printBootedWarning(plan.bootedToDelete)
        plan.groupedByRuntime.forEach { runtime, entries in
            print("  \(styled(runtime, .bold, .red))")
            entries.forEach { print("    \(styled("✗", .red)) \($0.device.name)") }
        }
        print()
    }

    static func printBootedWarning(_ booted: [DeviceEntry]) {
        guard !booted.isEmpty else { return }
        print(styled("  ⚠️  Warning: \(booted.count) simulator(s) to delete are currently booted:", .yellow))
        booted.forEach { entry in
            print("    \(styled("●", .yellow)) \(entry.device.name) (\(entry.runtime))")
        }
        print()
    }

    static func printDeletion(_ result: DeletionResult) {
        switch result.success {
        case true:
            print("  \(styled("✓", .green)) \(result.entry.runtime) — \(result.entry.device.name)")
        case false:
            print("  \(styled("✗", .red)) \(result.entry.runtime) — \(result.entry.device.name)")
        }
    }

    static func printResults(_ result: CleanupResult, hasRemovedRuntimes: Bool) {
        print()
        print(styled("  ── Results ─────────────────────────────────────", .cyan))
        print("  \(styled("✓ Deleted:", .green)) \(result.deleted) simulators")
        printFailed(result.failed)
        printRuntimeTip(hasRemovedRuntimes)
        print()
        print(styled("  Done! Check storage: System Settings → General → Storage", .green))
        print()
    }

    static func printFailed(_ count: Int) {
        guard count > 0 else { return }
        print("  \(styled("✗ Failed:", .red))  \(count) simulators")
    }

    static func printRuntimeTip(_ show: Bool) {
        guard show else { return }
        print()
        print(styled("  💡 Tip:", .yellow) + " You removed all simulators from some runtimes.")
        print("  You can also delete the runtime images to save more space:")
        print()
        print(styled("    xcrun simctl runtime list", .dim))
        print(styled("    xcrun simctl runtime delete <identifier>", .dim))
    }

    static func printNothingToRemove() {
        print(styled("  Nothing to remove. All clean!", .green))
        print()
    }

    static func printCancelled() {
        print(styled("\n  Cancelled. No changes made.\n", .yellow))
    }
}

// MARK: - Cleanup Planner (builds the plan via user interaction)

struct CleanupPlanner {
    let input: UserInteracting

    func buildPlan(groups: [RuntimeGroup]) -> CleanupPlan {
        let keepIndices = input.multiSelect(
            items: groups.map(Format.runtimeLabel),
            prompt: "Which runtimes do you want to KEEP?"
        )

        Presenter.printAllKeptWarning(kept: keepIndices.count, total: groups.count)

        let kept = keepIndices.sorted().map { groups[$0] }
        let removed = groups.enumerated()
            .filter { !keepIndices.contains($0.offset) }
            .map(\.element)

        Presenter.printRemovedRuntimes(removed)

        let removedDevices = removed.flatMap { rt in
            rt.devices.map { DeviceEntry(device: $0, runtime: rt.displayName) }
        }

        let pruned = pruneKeptRuntimes(kept)

        return CleanupPlan(
            devicesToKeep: pruned.kept,
            devicesToRemove: removedDevices + pruned.removed,
            hasRemovedRuntimes: !removed.isEmpty
        )
    }

    private func pruneKeptRuntimes(
        _ runtimes: [RuntimeGroup]
    ) -> (kept: Set<String>, removed: [DeviceEntry]) {
        guard !runtimes.isEmpty else { return ([], []) }

        print()
        guard input.confirm("  Do you also want to prune individual simulators from kept runtimes?") else {
            return (Set(runtimes.flatMap { $0.devices.map(\.udid) }), [])
        }

        return runtimes.reduce(into: (kept: Set<String>(), removed: [DeviceEntry]())) { result, rt in
            let keepDevices = input.multiSelect(
                items: rt.devices.map(Format.deviceLabel),
                prompt: "\(rt.displayName) — which simulators do you want to KEEP?"
            )

            rt.devices.enumerated().forEach { i, device in
                switch keepDevices.contains(i) {
                case true: result.kept.insert(device.udid)
                case false: result.removed.append(DeviceEntry(device: device, runtime: rt.displayName))
                }
            }
        }
    }
}

// MARK: - Cleanup Executor (performs deletions)

struct CleanupExecutor {
    let deleter: SimulatorDeleting

    func execute(plan: CleanupPlan) -> CleanupResult {
        print()
        print(styled("  Cleaning up...\n", .bold))

        let deletions = plan.devicesToRemove.map { entry -> DeletionResult in
            let result = DeletionResult(
                entry: entry,
                success: deleter.delete(device: entry.device)
            )
            Presenter.printDeletion(result)
            return result
        }

        return CleanupResult(deletions: deletions)
    }
}

// MARK: - App (Composition & Orchestration)

struct App {
    let loader: SimulatorLoading
    let planner: CleanupPlanner
    let executor: CleanupExecutor
    let input: UserInteracting

    func run() {
        Presenter.printHeader()
        Presenter.printLoading()

        switch loader.load() {
        case .failure(let error):
            Presenter.printError(error)
            exit(1)

        case .success(let groups):
            Presenter.printGroupsSummary(groups)

            let plan = planner.buildPlan(groups: groups)

            guard !plan.isEmpty else {
                Presenter.printNothingToRemove()
                return
            }

            Presenter.printCleanupSummary(plan)

            guard input.confirm("  Proceed with deletion?") else {
                Presenter.printCancelled()
                return
            }

            let result = executor.execute(plan: plan)
            Presenter.printResults(result, hasRemovedRuntimes: plan.hasRemovedRuntimes)
        }
    }
}

// MARK: - CLI Flags

let appVersion = "1.0.0"

switch CommandLine.arguments.dropFirst().first {
case "--version", "-v":
    print("SystemDataCleaner4Dev \(appVersion)")
    exit(0)
case "--help", "-h":
    print("""
    SystemDataCleaner4Dev v\(appVersion)
    Reclaim macOS "System Data" by cleaning up old Xcode simulators.

    Usage:
      swift SystemDataCleaner4Dev.swift            Run interactive cleanup
      swift SystemDataCleaner4Dev.swift --version   Show version
      swift SystemDataCleaner4Dev.swift --help      Show this help

    The tool scans all installed simulators, lets you choose which
    runtimes and devices to keep, and deletes the rest.

    Requires: macOS, Xcode (or Command Line Tools)
    """)
    exit(0)
default:
    break
}

// MARK: - Composition Root

let shell = ShellExecutor()
let console = ConsoleInput()

App(
    loader: SimulatorLoader(executor: shell),
    planner: CleanupPlanner(input: console),
    executor: CleanupExecutor(deleter: SimulatorCleaner(executor: shell)),
    input: console
).run()
