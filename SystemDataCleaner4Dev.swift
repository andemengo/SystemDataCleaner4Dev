#!/usr/bin/env swift

// ============================================
// SystemDataCleaner4Dev
// Interactive Xcode storage cleanup CLI for macOS
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

struct SimRuntimeImage: Decodable {
    let identifier: String
    let runtimeIdentifier: String?
    let version: String?
    let build: String?
    let sizeBytes: Int64?
    let deletable: Bool?
}

struct RuntimeGroup {
    let runtimeKey: String
    let displayName: String
    let platform: String
    let version: String
    let devices: [SimDevice]
    let sizes: [String: Int64]

    var bootedCount: Int { devices.filter(\.isBooted).count }
    var hasBooted: Bool { bootedCount > 0 }
    var sizeBytes: Int64 { devices.reduce(0) { $0 + size(of: $1) } }

    func size(of device: SimDevice) -> Int64 { sizes[device.udid] ?? 0 }
}

struct DeviceEntry {
    let device: SimDevice
    let runtime: String
    let sizeBytes: Int64
}

struct CleanupPlan {
    let devicesToKeep: Set<String>
    let devicesToRemove: [DeviceEntry]

    var bootedToDelete: [DeviceEntry] { devicesToRemove.filter(\.device.isBooted) }
    var isEmpty: Bool { devicesToRemove.isEmpty }
    var bytesToRemove: Int64 { devicesToRemove.reduce(0) { $0 + $1.sizeBytes } }

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
    var freedBytes: Int64 { deletions.filter(\.success).reduce(0) { $0 + $1.entry.sizeBytes } }
}

enum TargetCategory: Int {
    case orphanedSimulators
    case deviceSupport
    case runtimeImages

    var title: String {
        switch self {
        case .orphanedSimulators: return "Orphaned simulators"
        case .deviceSupport: return "Device support files"
        case .runtimeImages: return "Simulator runtimes"
        }
    }
}

enum TargetAction {
    case deleteSimulators([SimDevice])
    case deleteRuntime(identifier: String)
    case removeDirectory(String)
}

struct CleanupTarget {
    let category: TargetCategory
    let name: String
    let note: String
    let sizeBytes: Int64
    let action: TargetAction

    static func displayOrder(_ a: CleanupTarget, _ b: CleanupTarget) -> Bool {
        a.category == b.category
            ? a.sizeBytes > b.sizeBytes
            : a.category.rawValue < b.category.rawValue
    }
}

struct ScanReport {
    let targets: [CleanupTarget]
    let notes: [String]

    static let empty = ScanReport(targets: [], notes: [])

    func merged(with other: ScanReport) -> ScanReport {
        ScanReport(targets: targets + other.targets, notes: notes + other.notes)
    }
}

struct TargetRemoval {
    let target: CleanupTarget
    let success: Bool
}

struct ExtraCleanupResult {
    let removals: [TargetRemoval]
    var removed: [TargetRemoval] { removals.filter(\.success) }
    var failed: [TargetRemoval] { removals.filter { !$0.success } }
    var freedBytes: Int64 { removed.reduce(0) { $0 + $1.target.sizeBytes } }
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

protocol SizeMeasuring {
    func sizes(of paths: [String]) -> [String: Int64]
}

protocol DiskSpaceReading {
    func availableBytes() -> Int64?
}

protocol TargetScanning {
    func scan() -> ScanReport
}

protocol TargetRemoving {
    func remove(_ target: CleanupTarget) -> Bool
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

// MARK: - Paths

enum Paths {
    static let developer = NSHomeDirectory() + "/Library/Developer"
    static let xcode = developer + "/Xcode"
    static let deviceFS = developer + "/CoreDevice/DeviceFS"

    static func simulatorDevice(_ udid: String) -> String {
        developer + "/CoreSimulator/Devices/\(udid)"
    }
}

extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
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
        guard (try? process.run()) != nil else { return ("", -1) }
        // Drain the pipe before waiting: large outputs would otherwise fill
        // the pipe buffer and deadlock the child process.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}

// MARK: - Disk Usage

struct DiskUsageMeasurer: SizeMeasuring {
    let executor: CommandExecuting

    /// Measures real allocated size on disk (`du -sk`), keyed by path.
    func sizes(of paths: [String]) -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        let args = paths.map(\.shellQuoted).joined(separator: " ")
        return executor.execute("du -sk \(args) 2>/dev/null").output
            .split(separator: "\n")
            .reduce(into: [String: Int64]()) { result, line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let kilobytes = Int64(parts[0]) else { return }
                result[String(parts[1])] = kilobytes * 1024
            }
    }
}

struct VolumeSpaceReader: DiskSpaceReading {
    func availableBytes() -> Int64? {
        (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]))
            .flatMap(\.volumeAvailableCapacity)
            .map(Int64.init)
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

    static func displayName(_ key: String) -> String {
        let parsed = parse(key)
        return "\(parsed.platform) \(parsed.version)"
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

// MARK: - Simctl

enum Simctl {
    static func devices(_ executor: CommandExecuting) -> Result<SimctlOutput, CleanerError> {
        let result = executor.execute("xcrun simctl list devices -j 2>/dev/null")

        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8)
        else { return .failure(.simctlFailed) }

        return Result { try JSONDecoder().decode(SimctlOutput.self, from: data) }
            .mapError { .decodingFailed($0.localizedDescription) }
    }

    static func runtimeImages(_ executor: CommandExecuting) -> [SimRuntimeImage] {
        let result = executor.execute("xcrun simctl runtime list -j 2>/dev/null")

        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let images = try? JSONDecoder().decode([String: SimRuntimeImage].self, from: data)
        else { return [] }

        return Array(images.values)
    }
}

// MARK: - Simulator Loader

struct SimulatorLoader: SimulatorLoading {
    let executor: CommandExecuting
    let measurer: SizeMeasuring

    func load() -> Result<[RuntimeGroup], CleanerError> {
        Simctl.devices(executor).map { output in
            let available = output.devices
                .mapValues { $0.filter(\.isAvailable) }
                .filter { !$0.value.isEmpty }
            let sizes = measurer.sizes(
                of: available.values.flatMap { $0.map { Paths.simulatorDevice($0.udid) } }
            )
            return Self.buildGroups(from: available, sizes: sizes)
        }
    }

    private static func buildGroups(
        from devices: [String: [SimDevice]],
        sizes: [String: Int64]
    ) -> [RuntimeGroup] {
        devices
            .map { key, devices in
                let parsed = RuntimeParser.parse(key)
                return RuntimeGroup(
                    runtimeKey: key,
                    displayName: "\(parsed.platform) \(parsed.version)",
                    platform: parsed.platform,
                    version: parsed.version,
                    devices: devices,
                    sizes: Dictionary(uniqueKeysWithValues: devices.map {
                        ($0.udid, sizes[Paths.simulatorDevice($0.udid)] ?? 0)
                    })
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
            let path = Paths.simulatorDevice(device.udid)
            return executor.execute("rm -rf '\(path)' 2>&1").exitCode == 0
        }
    }
}

// MARK: - Extra Cleanup Scanners

/// Simulators whose runtime is no longer installed (typically left behind by
/// older Xcode versions). `simctl` marks them unavailable; they can't boot.
struct OrphanedSimulatorScanner: TargetScanning {
    let executor: CommandExecuting
    let measurer: SizeMeasuring

    func scan() -> ScanReport {
        guard let output = try? Simctl.devices(executor).get() else { return .empty }

        let orphans = output.devices
            .mapValues { $0.filter { !$0.isAvailable } }
            .filter { !$0.value.isEmpty }
        let sizes = measurer.sizes(
            of: orphans.values.flatMap { $0.map { Paths.simulatorDevice($0.udid) } }
        )

        let targets = orphans.map { key, devices in
            CleanupTarget(
                category: .orphanedSimulators,
                name: "\(RuntimeParser.displayName(key)) — \(devices.count) sims",
                note: "runtime no longer installed, can't boot",
                sizeBytes: devices.reduce(0) { $0 + (sizes[Paths.simulatorDevice($1.udid)] ?? 0) },
                action: .deleteSimulators(devices)
            )
        }
        return ScanReport(targets: targets, notes: [])
    }
}

/// Debug symbols Xcode copies from every physical device/OS version you connect
/// (`~/Library/Developer/Xcode/<Platform> DeviceSupport/<version>`).
struct DeviceSupportScanner: TargetScanning {
    let measurer: SizeMeasuring
    private let suffix = " DeviceSupport"

    init(measurer: SizeMeasuring) {
        self.measurer = measurer
    }

    func scan() -> ScanReport {
        let entries = Self.contents(of: Paths.xcode)
            .filter { $0.hasSuffix(suffix) }
            .flatMap { dir in
                Self.contents(of: Paths.xcode + "/" + dir).map { name in
                    (
                        platform: dir.replacingOccurrences(of: suffix, with: ""),
                        name: name,
                        path: Paths.xcode + "/" + dir + "/" + name
                    )
                }
            }
        let sizes = measurer.sizes(of: entries.map(\.path))

        let newest = Set(
            Dictionary(grouping: entries, by: \.platform)
                .compactMap { _, group in
                    group.max { a, b in
                        Self.version(of: a.name).compare(Self.version(of: b.name), options: .numeric) == .orderedAscending
                    }?.path
                }
        )

        let targets = entries.map { entry in
            CleanupTarget(
                category: .deviceSupport,
                name: "\(entry.platform) \(entry.name)",
                note: newest.contains(entry.path)
                    ? "newest for \(entry.platform), needed to debug that device"
                    : "old, Xcode re-creates it when needed",
                sizeBytes: sizes[entry.path] ?? 0,
                action: .removeDirectory(entry.path)
            )
        }
        return ScanReport(targets: targets, notes: [])
    }

    private static func contents(of path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    /// Extracts the OS version from names like "iPhone18,1 26.5.2 (23F84)" or "16.0 (20A362) arm64e".
    static func version(of name: String) -> String {
        name.range(of: #"\d+(\.\d+)+"#, options: .regularExpression)
            .map { String(name[$0]) }
            ?? "0"
    }
}

/// Downloadable simulator runtime images (system-wide, shared by all users).
struct RuntimeImageScanner: TargetScanning {
    let executor: CommandExecuting

    private static let simulatorSDKs = [
        "iOS": "iphonesimulator",
        "tvOS": "appletvsimulator",
        "watchOS": "watchsimulator",
        "xrOS": "xrsimulator",
        "visionOS": "xrsimulator",
    ]

    func scan() -> ScanReport {
        let usage = (try? Simctl.devices(executor).get())?.devices
            .mapValues { $0.filter(\.isAvailable).count } ?? [:]

        let targets = Simctl.runtimeImages(executor)
            .filter { $0.deletable ?? false }
            .map { image in
                let inUse = image.runtimeIdentifier.flatMap { usage[$0] } ?? 0
                let name = image.runtimeIdentifier.map(RuntimeParser.displayName)
                    ?? "Runtime \(image.version ?? image.identifier)"
                let usageNote = inUse > 0
                    ? "\(inUse) simulators would become unusable"
                    : "no simulators use it"
                let sdkNote = matchesInstalledSDK(image) ? "matches your Xcode SDK, " : ""
                return CleanupTarget(
                    category: .runtimeImages,
                    name: "\(name) (\(image.build ?? "?"))",
                    note: "system-wide, \(sdkNote)\(usageNote)",
                    sizeBytes: image.sizeBytes ?? 0,
                    action: .deleteRuntime(identifier: image.identifier)
                )
            }
        return ScanReport(targets: targets, notes: [])
    }

    private func matchesInstalledSDK(_ image: SimRuntimeImage) -> Bool {
        guard let runtime = image.runtimeIdentifier,
              let sdk = Self.simulatorSDKs[RuntimeParser.parse(runtime).platform]
        else { return false }
        let sdkVersion = executor.execute("xcrun --sdk \(sdk) --show-sdk-version 2>/dev/null")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !sdkVersion.isEmpty && sdkVersion == RuntimeParser.parse(runtime).version
    }
}

/// `CoreDevice/DeviceFS` looks huge in Finder but is a virtual (FSKit) mount of a
/// connected device's files: its size lives on the device, not on this Mac.
struct DeviceMountScanner: TargetScanning {
    let executor: CommandExecuting

    func scan() -> ScanReport {
        let mounted = executor.execute("mount | grep -F -- \(Paths.deviceFS.shellQuoted)").exitCode == 0
        guard mounted else { return .empty }
        return ScanReport(targets: [], notes: [
            "~/Library/Developer/CoreDevice/DeviceFS is a virtual view of your connected device.",
            "Its data lives on the device, not on this Mac, so there's nothing to reclaim there.",
        ])
    }
}

struct CompositeScanner: TargetScanning {
    let scanners: [TargetScanning]

    func scan() -> ScanReport {
        scanners.map { $0.scan() }.reduce(.empty) { $0.merged(with: $1) }
    }
}

// MARK: - Target Remover

struct TargetRemover: TargetRemoving {
    let executor: CommandExecuting
    let simulatorDeleter: SimulatorDeleting

    func remove(_ target: CleanupTarget) -> Bool {
        switch target.action {
        case .deleteSimulators(let devices):
            return devices.map(simulatorDeleter.delete).allSatisfy { $0 }
        case .deleteRuntime(let identifier):
            return executor.execute("xcrun simctl runtime delete \(identifier.shellQuoted) 2>&1").exitCode == 0
        case .removeDirectory(let path):
            // Safety net: never remove anything outside ~/Library/Developer.
            guard path.hasPrefix(Paths.developer + "/") else { return false }
            return executor.execute("rm -rf \(path.shellQuoted) 2>&1").exitCode == 0
        }
    }
}

// MARK: - Format Helpers

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func paddedBytes(_ value: Int64) -> String {
        let text = bytes(value)
        return String(repeating: " ", count: max(0, 9 - text.count)) + text
    }

    static func runtimeLabel(_ group: RuntimeGroup) -> String {
        let suffix = group.hasBooted ? " \(styled("← active", .green))" : ""
        return "\(group.displayName) (\(group.devices.count) sims, \(bytes(group.sizeBytes)))\(suffix)"
    }

    static func deviceLabel(_ device: SimDevice, size: Int64) -> String {
        let icon = device.isBooted ? styled("●", .green) : styled("○", .dim)
        return "\(icon) \(device.name) \(styled(bytes(size), .dim))"
    }

    static func runtimeSummary(_ group: RuntimeGroup) -> String {
        let booted = group.hasBooted ? styled(" (\(group.bootedCount) booted)", .green) : ""
        return "  \(styled(paddedBytes(group.sizeBytes), .bold))  \(styled(group.displayName, .bold))  — \(group.devices.count) simulators\(booted)"
    }

    static func targetLabel(_ target: CleanupTarget) -> String {
        "\(styled(paddedBytes(target.sizeBytes), .bold))  \(target.name)  \(styled(target.note, .dim))"
    }
}

// MARK: - Presenter (Single Responsibility — all terminal output)

enum Presenter {
    static func printHeader() {
        print()
        print(styled("  ╭──────────────────────────────────────────────╮", .cyan))
        print("  " + styled("│", .cyan) + styled("  SystemDataCleaner4Dev", .bold) + "                       " + styled("│", .cyan))
        print("  " + styled("│", .cyan) + styled("  Interactive Xcode storage cleanup", .dim) + "           " + styled("│", .cyan))
        print(styled("  ╰──────────────────────────────────────────────╯", .cyan))
        print()
    }

    static func printSpacer() {
        print()
    }

    static func printSection(_ title: String) {
        print()
        print(styled("  ── \(title) " + String(repeating: "─", count: max(0, 44 - title.count)), .cyan))
        print()
    }

    static func printLoading() {
        print(styled("  Loading simulators and measuring disk usage...", .dim))
    }

    static func printError(_ error: CleanerError) {
        print(styled("  ✗ \(error.description)", .red))
    }

    static func printGroupsSummary(_ groups: [RuntimeGroup]) {
        let total = groups.reduce(0) { $0 + $1.devices.count }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print(styled("  Found \(total) simulators across \(groups.count) runtimes — \(Format.bytes(bytes)) on disk\n", .green))
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
            print("    \(styled("✗", .red)) \(rt.displayName) — \(rt.devices.count) simulators, \(Format.bytes(rt.sizeBytes))")
        }
    }

    static func printCleanupSummary(_ plan: CleanupPlan) {
        printSection("Cleanup Summary")
        print("  \(styled("Keep:", .green))   \(plan.devicesToKeep.count) simulators")
        print("  \(styled("Remove:", .red)) \(plan.devicesToRemove.count) simulators (\(Format.bytes(plan.bytesToRemove)))")
        print()
        printBootedWarning(plan.bootedToDelete)
        plan.groupedByRuntime.forEach { runtime, entries in
            print("  \(styled(runtime, .bold, .red))")
            entries.forEach { print("    \(styled("✗", .red)) \($0.device.name) \(styled(Format.bytes($0.sizeBytes), .dim))") }
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

    static func printCleaningUp() {
        print()
        print(styled("  Cleaning up...\n", .bold))
    }

    static func printDeletion(_ result: DeletionResult) {
        let mark = result.success ? styled("✓", .green) : styled("✗", .red)
        print("  \(mark) \(result.entry.runtime) — \(result.entry.device.name)")
    }

    static func printResults(_ result: CleanupResult) {
        printSection("Simulator Results")
        print("  \(styled("✓ Deleted:", .green)) \(result.deleted) simulators (\(Format.bytes(result.freedBytes)))")
        printFailed(result.failed)
    }

    static func printFailed(_ count: Int) {
        guard count > 0 else { return }
        print("  \(styled("✗ Failed:", .red))  \(count) simulators")
    }

    static func printNothingToRemove() {
        print(styled("  No simulators to remove.", .green))
    }

    static func printSkipped() {
        print(styled("\n  Skipped. Nothing deleted in this step.", .yellow))
    }

    // Extra cleanup

    static func printExtrasIntro() {
        printSection("Extra Cleanup")
        print(styled("  Scanning orphaned simulators, device support files and runtimes...", .dim))
    }

    static func printNotes(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        print()
        print(styled("  ℹ️  ", .blue) + notes.joined(separator: "\n     "))
    }

    static func printExtrasOverview(_ targets: [CleanupTarget]) {
        print()
        Dictionary(grouping: targets, by: \.category)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .forEach { category, items in
                let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
                print("  \(styled(Format.paddedBytes(total), .bold))  \(category.title) (\(items.count))")
            }
    }

    static func printNoExtras() {
        print()
        print(styled("  Nothing else to clean. All tidy!", .green))
    }

    static func printExtrasSummary(_ targets: [CleanupTarget]) {
        let total = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        printSection("Extra Cleanup Summary")
        print("  \(styled("Remove:", .red)) \(targets.count) items (\(Format.bytes(total)))")
        print()
        targets.forEach { target in
            print("    \(styled("✗", .red)) \(target.category.title): \(target.name) \(styled(Format.bytes(target.sizeBytes), .dim))")
        }
        printRuntimeWarning(targets)
        print()
    }

    static func printRuntimeWarning(_ targets: [CleanupTarget]) {
        let runtimes = targets.filter { $0.category == .runtimeImages }
        guard !runtimes.isEmpty else { return }
        print()
        print(styled("  ⚠️  Runtimes are shared by all users on this Mac. Re-download them from", .yellow))
        print(styled("     Xcode → Settings → Components if you need them again.", .yellow))
    }

    static func printRemoval(_ removal: TargetRemoval) {
        let mark = removal.success ? styled("✓", .green) : styled("✗", .red)
        print("  \(mark) \(removal.target.category.title): \(removal.target.name)")
    }

    static func printExtrasResults(_ result: ExtraCleanupResult) {
        printSection("Extra Cleanup Results")
        print("  \(styled("✓ Removed:", .green)) \(result.removed.count) items (\(Format.bytes(result.freedBytes)))")
        guard !result.failed.isEmpty else { return }
        print("  \(styled("✗ Failed:", .red))  \(result.failed.count) items")
        printRuntimeFailureHint(result.failed)
    }

    static func printRuntimeFailureHint(_ failed: [TargetRemoval]) {
        let ids = failed.compactMap { removal -> String? in
            switch removal.target.action {
            case .deleteRuntime(let identifier): return identifier
            default: return nil
            }
        }
        guard !ids.isEmpty else { return }
        print(styled("  Runtime deletion may need admin rights. Try:", .dim))
        ids.forEach { print(styled("    sudo xcrun simctl runtime delete \($0)", .dim)) }
    }

    // Final report

    static func printFinalReport(estimated: Int64, freeBefore: Int64?, freeAfter: Int64?) {
        printSection("Disk Space")
        print("  Measured size of deleted items:  \(styled(Format.bytes(estimated), .bold))")
        printFreeSpace(before: freeBefore, after: freeAfter)
        guard estimated > 0 else { return printDone() }
        print()
        print(styled("  Note: macOS may take a few minutes to release space from deleted", .dim))
        print(styled("  simulators, and APFS clones can make the real gain smaller than measured.", .dim))
        printDone()
    }

    static func printFreeSpace(before: Int64?, after: Int64?) {
        guard let before = before, let after = after else { return }
        let delta = after - before
        let sign = delta >= 0 ? "+" : "−"
        print("  Free space before:               \(Format.bytes(before))")
        print("  Free space now:                  \(Format.bytes(after)) \(styled("(\(sign)\(Format.bytes(abs(delta))))", delta > 0 ? .green : .dim))")
    }

    static func printDone() {
        print()
        print(styled("  Done! Check storage: System Settings → General → Storage", .green))
        print()
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
            rt.devices.map { DeviceEntry(device: $0, runtime: rt.displayName, sizeBytes: rt.size(of: $0)) }
        }

        let pruned = pruneKeptRuntimes(kept)

        return CleanupPlan(
            devicesToKeep: pruned.kept,
            devicesToRemove: removedDevices + pruned.removed
        )
    }

    private func pruneKeptRuntimes(
        _ runtimes: [RuntimeGroup]
    ) -> (kept: Set<String>, removed: [DeviceEntry]) {
        guard !runtimes.isEmpty else { return ([], []) }

        Presenter.printSpacer()
        guard input.confirm("  Do you also want to prune individual simulators from kept runtimes?") else {
            return (Set(runtimes.flatMap { $0.devices.map(\.udid) }), [])
        }

        return runtimes.reduce(into: (kept: Set<String>(), removed: [DeviceEntry]())) { result, rt in
            let keepDevices = input.multiSelect(
                items: rt.devices.map { Format.deviceLabel($0, size: rt.size(of: $0)) },
                prompt: "\(rt.displayName) — which simulators do you want to KEEP?"
            )

            rt.devices.enumerated().forEach { i, device in
                switch keepDevices.contains(i) {
                case true: result.kept.insert(device.udid)
                case false: result.removed.append(
                    DeviceEntry(device: device, runtime: rt.displayName, sizeBytes: rt.size(of: device))
                )
                }
            }
        }
    }
}

// MARK: - Cleanup Executor (performs deletions)

struct CleanupExecutor {
    let deleter: SimulatorDeleting

    func execute(plan: CleanupPlan) -> CleanupResult {
        Presenter.printCleaningUp()

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

// MARK: - Extra Cleanup Planner & Executor

struct ExtraCleanupPlanner {
    let input: UserInteracting

    /// Unlike simulators (choose what to KEEP), extras are opt-in: choose what to DELETE.
    func select(from targets: [CleanupTarget]) -> [CleanupTarget] {
        input.multiSelect(
            items: targets.map(Format.targetLabel),
            prompt: "Which items do you want to DELETE?"
        )
        .sorted()
        .map { targets[$0] }
    }
}

struct ExtraCleanupExecutor {
    let remover: TargetRemoving

    func execute(_ targets: [CleanupTarget]) -> ExtraCleanupResult {
        Presenter.printCleaningUp()

        let removals = targets.map { target -> TargetRemoval in
            let removal = TargetRemoval(target: target, success: remover.remove(target))
            Presenter.printRemoval(removal)
            return removal
        }

        return ExtraCleanupResult(removals: removals)
    }
}

// MARK: - App (Composition & Orchestration)

struct App {
    let loader: SimulatorLoading
    let planner: CleanupPlanner
    let executor: CleanupExecutor
    let scanner: TargetScanning
    let extraPlanner: ExtraCleanupPlanner
    let extraExecutor: ExtraCleanupExecutor
    let disk: DiskSpaceReading
    let input: UserInteracting

    func run() {
        Presenter.printHeader()
        let freeBefore = disk.availableBytes()

        let simulatorBytes = runSimulatorCleanup()
        let extraBytes = runExtraCleanup()

        Presenter.printFinalReport(
            estimated: simulatorBytes + extraBytes,
            freeBefore: freeBefore,
            freeAfter: disk.availableBytes()
        )
    }

    /// Returns the measured size of the deleted simulators.
    private func runSimulatorCleanup() -> Int64 {
        Presenter.printLoading()

        switch loader.load() {
        case .failure(let error):
            Presenter.printError(error)
            return 0

        case .success(let groups):
            guard !groups.isEmpty else {
                Presenter.printNothingToRemove()
                return 0
            }

            Presenter.printGroupsSummary(groups)

            let plan = planner.buildPlan(groups: groups)

            guard !plan.isEmpty else {
                Presenter.printNothingToRemove()
                return 0
            }

            Presenter.printCleanupSummary(plan)

            guard input.confirm("  Proceed with deletion?") else {
                Presenter.printSkipped()
                return 0
            }

            let result = executor.execute(plan: plan)
            Presenter.printResults(result)
            return result.freedBytes
        }
    }

    /// Returns the measured size of the removed extra items.
    private func runExtraCleanup() -> Int64 {
        Presenter.printExtrasIntro()

        let report = scanner.scan()
        Presenter.printNotes(report.notes)

        guard !report.targets.isEmpty else {
            Presenter.printNoExtras()
            return 0
        }

        let targets = report.targets.sorted(by: CleanupTarget.displayOrder)
        Presenter.printExtrasOverview(targets)

        let selected = extraPlanner.select(from: targets)

        guard !selected.isEmpty else {
            Presenter.printSkipped()
            return 0
        }

        Presenter.printExtrasSummary(selected)

        guard input.confirm("  Proceed with deletion?") else {
            Presenter.printSkipped()
            return 0
        }

        let result = extraExecutor.execute(selected)
        Presenter.printExtrasResults(result)
        return result.freedBytes
    }
}

// MARK: - CLI Flags

let appVersion = "1.1.0"

switch CommandLine.arguments.dropFirst().first {
case "--version", "-v":
    print("SystemDataCleaner4Dev \(appVersion)")
    exit(0)
case "--help", "-h":
    print("""
    SystemDataCleaner4Dev v\(appVersion)
    Reclaim macOS "System Data" by cleaning up old Xcode data.

    Usage:
      swift SystemDataCleaner4Dev.swift            Run interactive cleanup
      swift SystemDataCleaner4Dev.swift --version   Show version
      swift SystemDataCleaner4Dev.swift --help      Show this help

    Step 1 — Simulators: choose which runtimes and devices to keep,
             the rest is deleted.
    Step 2 — Extras: choose what to delete among orphaned simulators
             (left by older Xcode versions), old device support files
             and simulator runtime images.

    Every item shows its real size on disk, and the final report shows
    free space before and after.

    Requires: macOS, Xcode (or Command Line Tools)
    """)
    exit(0)
default:
    break
}

// MARK: - Composition Root

let shell = ShellExecutor()
let console = ConsoleInput()
let measurer = DiskUsageMeasurer(executor: shell)
let simulatorCleaner = SimulatorCleaner(executor: shell)

App(
    loader: SimulatorLoader(executor: shell, measurer: measurer),
    planner: CleanupPlanner(input: console),
    executor: CleanupExecutor(deleter: simulatorCleaner),
    scanner: CompositeScanner(scanners: [
        OrphanedSimulatorScanner(executor: shell, measurer: measurer),
        DeviceSupportScanner(measurer: measurer),
        RuntimeImageScanner(executor: shell),
        DeviceMountScanner(executor: shell),
    ]),
    extraPlanner: ExtraCleanupPlanner(input: console),
    extraExecutor: ExtraCleanupExecutor(remover: TargetRemover(executor: shell, simulatorDeleter: simulatorCleaner)),
    disk: VolumeSpaceReader(),
    input: console
).run()
