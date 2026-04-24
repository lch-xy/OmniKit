//
//  BatteryChargeController.swift
//  OmniKit
//

import Foundation

nonisolated enum BatteryHardwarePlatform: String {
    case intel = "Intel"
    case appleSilicon = "Apple Silicon"

    static var current: BatteryHardwarePlatform {
        #if arch(arm64)
        .appleSilicon
        #else
        .intel
        #endif
    }
}

nonisolated enum BatteryChargeBackend {
    case unavailable(reason: String)
    /// `batt` 后端。`daemonReachableWithoutRoot` 表示当前 App 账号能不能直接和 daemon 通信；
    /// 为 false 时写入需要管理员权限（会弹密码框）。
    case batt(path: String, platform: BatteryHardwarePlatform, daemonReachableWithoutRoot: Bool)
    case bclm(path: String, platform: BatteryHardwarePlatform)

    var title: String {
        switch self {
        case .unavailable:
            return "不可用"
        case let .batt(_, platform, reachable):
            return "batt · \(platform.rawValue)" + (reachable ? "" : "（需管理员）")
        case let .bclm(_, platform):
            return "BCLM · \(platform.rawValue)"
        }
    }

    var detail: String {
        switch self {
        case let .unavailable(reason):
            return reason
        case let .batt(path, platform, reachable):
            let base = "检测到 `batt`：\(path)。\(platform.rawValue) 机型会通过 batt 守护进程控制最大充电上限；如果当前电量已经高于目标值，系统会停止继续充电，但不会自动放电回目标值。"
            if reachable {
                return base + " 当前 daemon 已允许非 root 访问，可直接写入。"
            }
            return base + " 当前 daemon 未允许非 root 访问（socket 连接被拒绝），写入会弹管理员密码框。"
        case let .bclm(path, platform):
            if platform == .appleSilicon {
                return "检测到 `bclm`：\(path)。Apple Silicon 机型通过该后端通常只支持 80 或 100。"
            }
            return "检测到 `bclm`：\(path)。该后端需要管理员权限写入电池上限。"
        }
    }

    var canRead: Bool {
        switch self {
        case .unavailable:
            return false
        case .batt, .bclm:
            return true
        }
    }

    var canWrite: Bool {
        switch self {
        case .unavailable:
            return false
        case .batt, .bclm:
            return true
        }
    }

    /// 写入是否需要弹管理员密码框。
    var writeRequiresAdminPrompt: Bool {
        switch self {
        case .unavailable:
            return false
        case let .batt(_, _, reachable):
            return !reachable
        case .bclm:
            return true
        }
    }
}

nonisolated enum BatteryChargeControlResult {
    case success(String)
    case failure(String)
}

nonisolated struct BatteryChargeController {
    private static let commonBattPaths = [
        "/opt/homebrew/bin/batt",
        "/usr/local/bin/batt",
        "/usr/bin/batt",
        "/opt/local/bin/batt",
    ]
    private static let commonBattConfigPaths = [
        "/etc/batt.json",
        "/opt/homebrew/etc/batt.json",
        "/usr/local/etc/batt.json",
    ]
    private static let commonBCLMPaths = [
        "/opt/homebrew/bin/bclm",
        "/usr/local/bin/bclm",
        "/usr/bin/bclm",
    ]

    static func detectBackend() -> BatteryChargeBackend {
        let platform = BatteryHardwarePlatform.current
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion

        if platform == .appleSilicon,
           let battPath = firstExecutable(in: commonBattPaths) {
            let reachable = battDaemonReachableWithoutRoot(path: battPath)
            return .batt(path: battPath, platform: platform, daemonReachableWithoutRoot: reachable)
        }

        if platform == .appleSilicon {
            return .unavailable(reason: "当前系统是 macOS \(osVersion.majorVersion).\(osVersion.minorVersion)，这台 Apple Silicon 机器需要 `batt` 这类守护进程后端才可以真正应用充电上限；本机当前还没有检测到 `batt`。")
        }

        if osVersion.majorVersion >= 15 {
            return .unavailable(reason: "当前系统是 macOS \(osVersion.majorVersion).\(osVersion.minorVersion)，Intel 机型常见的 `bclm` 在 macOS 15 及以上会被新的内核 entitlement 限制拦住，普通 App 无法直接用这条路径控充。")
        }

        if let path = firstExecutable(in: commonBCLMPaths) {
            return .bclm(path: path, platform: platform)
        }

        return .unavailable(reason: "当前未检测到 `bclm`。如果要走 AlDente/BCLM 这条技术路径，至少需要先安装对应底层工具或后续接入特权 helper。")
    }

    static func readCurrentLimit(using backend: BatteryChargeBackend) -> BatteryChargeControlResult {
        switch backend {
        case let .batt(path, _, reachable):
            if reachable {
                let result = runProcess(executablePath: path, arguments: ["status"])
                if result.exitCode == 0,
                   let limit = extractLimit(from: result.combinedOutput) {
                    return .success("\(limit)")
                }
            }

            if let fallbackLimit = readBattConfiguredLimit() {
                return .success("\(fallbackLimit)")
            }

            if !reachable {
                let fallbackResult = runShellCommand(
                    shellCommand: "\(shellQuoted(path)) status",
                    requiresAdministratorPrivileges: true
                )
                if fallbackResult.exitCode == 0,
                   let limit = extractLimit(from: fallbackResult.combinedOutput) {
                    return .success("\(limit)")
                }
                return .failure("读取失败：\(preferredErrorMessage(primary: fallbackResult))")
            }

            return .failure("读取失败：未能从 batt 输出中解析出当前上限。")
        case let .bclm(path, _):
            let result = runProcess(executablePath: path, arguments: ["read"])
            guard result.exitCode == 0 else {
                return .failure("读取失败：\(preferredErrorMessage(primary: result))")
            }

            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure("读取失败：未返回有效的 BCLM 数值。")
            }
            return .success(trimmed)
        case .unavailable:
            return .failure("当前后端不支持读取已应用的充电上限。")
        }
    }

    static func apply(limit: Int, using backend: BatteryChargeBackend) -> BatteryChargeControlResult {
        switch backend {
        case let .batt(path, _, reachable):
            let resolvedValue = max(10, min(100, limit))
            let arguments: [String]
            if resolvedValue >= 100 {
                arguments = ["disable"]
            } else {
                arguments = ["limit", "\(resolvedValue)"]
            }

            if reachable {
                let result = runProcess(executablePath: path, arguments: arguments)
                if result.exitCode == 0 {
                    return .success(successMessage(forBatt: resolvedValue))
                }

                if !looksLikeSocketPermissionDenied(result.combinedOutput) {
                    return .failure("写入失败：\(preferredErrorMessage(primary: result))")
                }
                // socket 被拒绝，回退到管理员路径
            }

            let shellCommand = "\(shellQuoted(path)) " + arguments.map(shellQuoted).joined(separator: " ")
            let fallbackResult = runShellCommand(shellCommand: shellCommand, requiresAdministratorPrivileges: true)
            guard fallbackResult.exitCode == 0 else {
                return .failure("写入失败：\(preferredErrorMessage(primary: fallbackResult))")
            }
            return .success(successMessage(forBatt: resolvedValue))
        case let .bclm(path, platform):
            let resolvedValue: Int
            switch platform {
            case .intel:
                resolvedValue = max(20, min(100, limit))
            case .appleSilicon:
                guard limit == 80 || limit == 100 else {
                    return .failure("Apple Silicon 通过 BCLM 通常只接受 80 或 100，当前设置的 \(limit)% 无法直接写入。")
                }
                resolvedValue = limit
            }

            let command = "\(shellQuoted(path)) write \(resolvedValue)"
            let result = runAdministratorCommand(shellCommand: command)
            guard result.exitCode == 0 else {
                return .failure("写入失败：\(preferredErrorMessage(primary: result))")
            }

            return .success("已尝试将充电上限写入为 \(resolvedValue)% 。")
        case .unavailable:
            return .failure("当前环境不支持直接写入充电上限。")
        }
    }

    static func disable(using backend: BatteryChargeBackend) -> BatteryChargeControlResult {
        switch backend {
        case let .batt(path, _, reachable):
            let arguments = ["disable"]
            if reachable {
                let result = runProcess(executablePath: path, arguments: arguments)
                if result.exitCode == 0 {
                    return .success("已关闭 batt 充电上限，系统将恢复默认充电行为。")
                }

                if !looksLikeSocketPermissionDenied(result.combinedOutput) {
                    return .failure("关闭失败：\(preferredErrorMessage(primary: result))")
                }
            }

            let shellCommand = "\(shellQuoted(path)) disable"
            let fallbackResult = runShellCommand(shellCommand: shellCommand, requiresAdministratorPrivileges: true)
            guard fallbackResult.exitCode == 0 else {
                return .failure("关闭失败：\(preferredErrorMessage(primary: fallbackResult))")
            }
            return .success("已关闭 batt 充电上限，系统将恢复默认充电行为。")
        case let .bclm(path, _):
            let command = "\(shellQuoted(path)) write 100"
            let result = runAdministratorCommand(shellCommand: command)
            guard result.exitCode == 0 else {
                return .failure("关闭失败：\(preferredErrorMessage(primary: result))")
            }
            return .success("已将 BCLM 上限恢复到 100%。")
        case .unavailable:
            return .failure("当前环境不支持关闭充电上限。")
        }
    }

    static func suggestedCommand(for limit: Int, using backend: BatteryChargeBackend) -> String? {
        switch backend {
        case let .batt(path, _, reachable):
            let resolvedValue = max(10, min(100, limit))
            let prefix = reachable ? "" : "sudo "
            if resolvedValue >= 100 {
                return "\(prefix)\(path) disable"
            }
            return "\(prefix)\(path) limit \(resolvedValue)"
        case let .bclm(path, platform):
            switch platform {
            case .intel:
                let resolvedValue = max(20, min(100, limit))
                return "sudo \(path) write \(resolvedValue)"
            case .appleSilicon:
                guard limit == 80 || limit == 100 else { return nil }
                return "sudo \(path) write \(limit)"
            }
        case .unavailable:
            if BatteryHardwarePlatform.current == .appleSilicon {
                if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
                    return """
                    /opt/homebrew/bin/brew install batt
                    sudo /opt/homebrew/bin/brew services start batt
                    """
                }
                return "安装 batt 后再试，例如：brew install batt"
            }
            return nil
        }
    }

    // MARK: - Helpers

    private static func successMessage(forBatt limit: Int) -> String {
        "已通过 batt 应用 \(limit)% 充电上限。如果当前电量已经高于目标值，系统会停止继续充电，但不会自动放电回 \(limit)% 。"
    }

    private static func firstExecutable(in paths: [String]) -> String? {
        paths.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func battDaemonReachableWithoutRoot(path: String) -> Bool {
        // 用 `batt status` 做探针：只要 exit code 为 0 就说明 daemon 可连通。
        // 注意 batt 的 status/limit 输出都走 stderr，我们必须合并输出才能正确判断。
        let result = runProcess(executablePath: path, arguments: ["status"])
        if result.exitCode == 0 {
            return true
        }
        return false
    }

    private static func looksLikeSocketPermissionDenied(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("operation not permitted")
            || lowered.contains("permission denied")
            || lowered.contains("connect: permission")
            || (lowered.contains("unix socket") && lowered.contains("permission"))
    }

    private static func readBattConfiguredLimit() -> Int? {
        for path in commonBattConfigPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            if let limit = extractLimit(from: jsonObject) {
                return limit
            }
        }
        return nil
    }

    private static func extractLimit(from jsonObject: Any) -> Int? {
        if let dictionary = jsonObject as? [String: Any] {
            let exactKeys = [
                "upperLimit",
                "upper_limit",
                "chargeLimit",
                "charge_limit",
                "limit",
            ]
            for key in exactKeys {
                if let value = dictionary[key] as? NSNumber {
                    return value.intValue
                }
                if let value = dictionary[key] as? Int {
                    return value
                }
            }
            for value in dictionary.values {
                if let limit = extractLimit(from: value) {
                    return limit
                }
            }
        } else if let array = jsonObject as? [Any] {
            for item in array {
                if let limit = extractLimit(from: item) {
                    return limit
                }
            }
        }
        return nil
    }

    private static func extractLimit(from statusOutput: String) -> Int? {
        let patterns = [
            #"(?i)upper\s*limit[^0-9]{0,20}([0-9]{2,3})"#,
            #"(?i)(?:charge\s*limit|limit)[^0-9]{0,20}([0-9]{2,3})"#,
            #"([0-9]{2,3})\s*%"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(statusOutput.startIndex..<statusOutput.endIndex, in: statusOutput)
            guard let match = regex.firstMatch(in: statusOutput, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: statusOutput),
                  let value = Int(statusOutput[valueRange]) else {
                continue
            }
            if (10...100).contains(value) {
                return value
            }
        }

        return nil
    }

    private static func runShellCommand(shellCommand: String, requiresAdministratorPrivileges: Bool = false) -> ProcessResult {
        let wrappedCommand: String
        if requiresAdministratorPrivileges {
            // 管理员路径通过 AppleScript 弹密码框，用 2>&1 把 stderr 带回来以便解析。
            wrappedCommand = "/bin/bash -c " + appleScriptQuoted(shellCommand + " 2>&1")
        } else {
            wrappedCommand = shellCommand
        }

        let script: String
        if requiresAdministratorPrivileges {
            script = "do shell script " + appleScriptQuoted(wrappedCommand) + " with administrator privileges"
        } else {
            script = "do shell script " + appleScriptQuoted(wrappedCommand)
        }

        return runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script]
        )
    }

    private static func runAdministratorCommand(shellCommand: String) -> ProcessResult {
        runShellCommand(shellCommand: shellCommand, requiresAdministratorPrivileges: true)
    }

    private static func runProcess(executablePath: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, output: "", errorOutput: error.localizedDescription)
        }

        // 先排空再 wait，避免子进程因为管道写满被挂起。
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func preferredErrorMessage(primary: ProcessResult, fallback: ProcessResult? = nil) -> String {
        let candidates = [primary, fallback]
            .compactMap { $0 }
            .flatMap { [$0.errorOutput, $0.output] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return candidates.first ?? "未知错误"
    }
}

private nonisolated struct ProcessResult {
    let exitCode: Int32
    let output: String
    let errorOutput: String

    var combinedOutput: String {
        var pieces: [String] = []
        if !output.isEmpty { pieces.append(output) }
        if !errorOutput.isEmpty { pieces.append(errorOutput) }
        return pieces.joined(separator: "\n")
    }
}
