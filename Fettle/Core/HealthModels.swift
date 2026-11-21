import Foundation
import Darwin

// MARK: - Pages

enum HealthPage: String, CaseIterable, Identifiable, Sendable {
    case overview, cpu, memory, disk, battery, network, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L("Overview")
        case .cpu: return L("CPU")
        case .memory: return L("Memory")
        case .disk: return L("Disk")
        case .battery: return L("Battery")
        case .network: return L("Network")
        case .activity: return L("Activity")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .battery: return "battery.75"
        case .network: return "network"
        case .activity: return "chart.xyaxis.line"
        }
    }

    var explanation: String {
        switch self {
        case .overview: return L("A live picture of the whole Mac.")
        case .cpu: return L("Processor load, cores and processes.")
        case .memory: return L("Memory pressure, swap and memory-heavy apps.")
        case .disk: return L("Volumes, drive health and disk activity.")
        case .battery: return L("Charge, battery health and power source.")
        case .network: return L("Counters and current traffic for every interface.")
        case .activity: return L("Readings kept on this Mac over time.")
        }
    }
}

enum HealthSeverity: Int, CaseIterable, Comparable, Sendable {
    case good = 0
    case info = 1
    case warning = 2
    case critical = 3

    static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .good: return L("Good")
        case .info: return L("Information")
        case .warning: return L("Attention")
        case .critical: return L("Critical")
        }
    }
}

enum MemoryPressureLevel: String, Codable, CaseIterable, Sendable {
    case normal, warning, critical, unknown

    var title: String {
        switch self {
        case .normal: return L("Normal")
        case .warning: return L("Elevated")
        case .critical: return L("Critical")
        case .unknown: return L("Unknown")
        }
    }

    var severity: HealthSeverity {
        switch self {
        case .normal: return .good
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return .info
        }
    }
}

// MARK: - Readings

struct ProcessReading: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var path: String?
    var bundleID: String?
    var isApplication: Bool = false
    var isFrontmost: Bool = false
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var status: String = ""
    var user: String = ""
    var startedAt: Date?
    var canManage: Bool = false
    var isOwnProcess: Bool = false
    var responding: Bool?
    var parentPID: pid_t = 0

    var displayName: String {
        if isApplication, let bundleID, !bundleID.isEmpty { return name }
        return name.isEmpty ? L("Process %d", pid) : name
    }

    var memoryText: String { Fmt.bytes(Int64(memoryBytes)) }

    var cpuText: String {
        if cpuPercent <= 0 { return "0%" }
        if cpuPercent >= 100 { return String(format: "%.0f%%", cpuPercent) }
        return String(format: "%.1f%%", cpuPercent)
    }
}

struct VolumeHealth: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var mountPath: String
    var device: String
    var totalBytes: Int64
    var availableBytes: Int64
    var isInternal: Bool
    var isRemovable: Bool
    var isEjectable: Bool
    var isReadOnly: Bool
    var filesystem: String
    var driveID: String?
    var smartStatus: String?
    var isSystemVolume: Bool

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var canEject: Bool { !isInternal && (isEjectable || isRemovable) && mountPath != "/" }
}

struct DriveHealth: Identifiable, Hashable, Sendable {
    var id: String
    var model: String
    var sizeBytes: Int64
    var isInternal: Bool
    var isSolidState: Bool
    var smartStatus: String
    var busProtocol: String
    var percentageUsed: Int?
    var powerOnHours: Int?
    var unsafeShutdowns: Int?
    var mediaErrors: Int?
    var powerCycles: Int?
    var temperatureCelsius: Double?
    var volumeIDs: [String]

    var severity: HealthSeverity {
        let value = smartStatus.lowercased()
        if value.contains("fail") || value.contains("not verified") || value.contains("warning") { return .critical }
        if value.contains("verified") { return .good }
        if value.contains("not supported") || value.contains("unavailable") { return .info }
        return .info
    }

    var smartLabel: String {
        if smartStatus.isEmpty { return L("Not reported") }
        if smartStatus.lowercased() == "verified" { return L("Verified") }
        if smartStatus.lowercased() == "not supported" { return L("Not supported") }
        return smartStatus
    }
}

struct NetworkInterfaceReading: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var displayName: String
    var address: String?
    var receivedBytes: UInt64
    var sentBytes: UInt64
    var receiveRate: Double
    var sendRate: Double
    var isUp: Bool
}

struct NetworkReading: Sendable, Equatable {
    var interfaces: [NetworkInterfaceReading] = []
    var totalReceived: UInt64 = 0
    var totalSent: UInt64 = 0
    var receiveRate: Double = 0
    var sendRate: Double = 0
    var primaryInterface: String?
}

struct BatteryReading: Sendable, Equatable {
    var isPresent: Bool = false
    var percent: Int?
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeRemainingMinutes: Int?
    var cycleCount: Int?
    var condition: String?
    var designCapacity: Int?
    var maxCapacity: Int?
    var healthPercent: Int?
    var temperatureCelsius: Double?
    var voltageMillivolts: Int?
    var adapterWatts: Int?
    var lowPowerMode: Bool = false
    var notes: [String] = []

    /// The condition macOS reports, in the interface language.
    var conditionText: String? {
        condition.map { L($0) }
    }

    var severity: HealthSeverity {
        if !isPresent { return .info }
        if let percent, percent <= 10 && !isCharging { return .critical }
        if let percent, percent <= 20 && !isCharging { return .warning }
        if let healthPercent, healthPercent < 80 { return .warning }
        return .good
    }

    var timeRemainingText: String {
        guard let minutes = timeRemainingMinutes, minutes > 0 else { return L("Calculating…") }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 { return L("%dh %dm", hours, mins) }
        return L("%d min", mins)
    }
}

struct MemoryReading: Sendable, Equatable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var activeBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var pressure: MemoryPressureLevel = .unknown
    var pressureRaw: Int = 0
    var pressureFraction: Double = 0

    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var freeFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
    var swapUsedFraction: Double { swapTotalBytes > 0 ? Double(swapUsedBytes) / Double(swapTotalBytes) : 0 }
    var severity: HealthSeverity { pressure.severity }
}

struct CPUReading: Sendable, Equatable {
    var usageFraction: Double = 0
    var userFraction: Double = 0
    var systemFraction: Double = 0
    var idleFraction: Double = 1
    var perCore: [Double] = []
    var coreCount: Int = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var uptime: TimeInterval = 0
    var warmedUp: Bool = false

    var usagePercent: Double { min(100, max(0, usageFraction * 100)) }
    var severity: HealthSeverity {
        if usagePercent >= 90 { return .critical }
        if usagePercent >= 70 { return .warning }
        return .good
    }
}

struct DiskIOReading: Sendable, Equatable {
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var totalReadBytes: UInt64 = 0
    var totalWriteBytes: UInt64 = 0
    var warmedUp: Bool = false
}

struct HealthSnapshot: Sendable {
    var readAt: Date = .now
    var cpu: CPUReading = CPUReading()
    var memory: MemoryReading = MemoryReading()
    var battery: BatteryReading = BatteryReading()
    var volumes: [VolumeHealth] = []
    var drives: [DriveHealth] = []
    var diskIO: DiskIOReading = DiskIOReading()
    var network: NetworkReading = NetworkReading()
    var processes: [ProcessReading] = []
    var topCPU: [ProcessReading] = []
    var topMemory: [ProcessReading] = []
    var applications: [ProcessReading] = []
    var thermalState: String = L("Nominal")
    var processCount: Int = 0
    var notes: [String] = []
    var sampleInterval: TimeInterval = 0

    var externalVolumes: [VolumeHealth] {
        volumes.filter { !$0.isInternal && $0.mountPath != "/" }
    }

    var ejectableVolumes: [VolumeHealth] {
        volumes.filter(\.canEject)
    }

    var worstDrive: DriveHealth? {
        drives.max { $0.severity < $1.severity }
    }

    var rootVolume: VolumeHealth? {
        volumes.first { $0.mountPath == "/" } ?? volumes.first
    }
}

struct TrendPoint: Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var value: Double
}

struct HealthHistorySample: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var cpuPercent: Double
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64
    var memoryPressure: MemoryPressureLevel
    var diskFreeBytes: Int64
    var diskTotalBytes: Int64
    var networkInBytesPerSecond: Double
    var networkOutBytesPerSecond: Double
    var batteryPercent: Int?
    var thermalState: String

    var memoryUsedText: String { Fmt.bytes(Int64(memoryUsedBytes)) }
    var diskFreeText: String { Fmt.bytes(diskFreeBytes) }
}

// MARK: - Alerts

enum HealthAlertKind: String, Codable, CaseIterable, Sendable {
    case memoryPressure
    case highCPU
    case lowDisk
    case largeTrash
    case externalDrive
    case driveHealth

    var title: String {
        switch self {
        case .memoryPressure: return L("Memory pressure")
        case .highCPU: return L("High CPU use")
        case .lowDisk: return L("Low disk space")
        case .largeTrash: return L("Large Trash")
        case .externalDrive: return L("External drive connected")
        case .driveHealth: return L("Drive health")
        }
    }

    var page: HealthPage {
        switch self {
        case .memoryPressure: return .memory
        case .highCPU: return .cpu
        case .lowDisk, .largeTrash: return .disk
        case .externalDrive, .driveHealth: return .disk
        }
    }

    var symbol: String {
        switch self {
        case .memoryPressure: return "memorychip.fill"
        case .highCPU: return "cpu.fill"
        case .lowDisk: return "internaldrive.fill"
        case .largeTrash: return "trash.fill"
        case .externalDrive: return "externaldrive.fill"
        case .driveHealth: return "heart.text.square.fill"
        }
    }
}

struct HealthAlert: Identifiable, Hashable, Sendable {
    var id: String { kind.rawValue }
    var kind: HealthAlertKind
    var severity: HealthSeverity
    var title: String
    var detail: String
    var date: Date
}

struct ProcessConfirmation: Identifiable {
    var id = UUID()
    var process: ProcessReading
    var force: Bool
}

struct AccessibilityPrompt: Identifiable {
    var id = UUID()
}

struct EjectResult: Identifiable, Sendable {
    var id = UUID()
    var volume: String
    var success: Bool
    var message: String
}

// MARK: - Formatting

enum HealthFormat {
    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", min(1, max(0, fraction)) * 100)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 KB/s" }
        return Fmt.bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return L("%dd %dh", days, hours) }
        if hours > 0 { return L("%dh %dm", hours, minutes) }
        return L("%d min", minutes)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        let number = L10n.languageCode == "nl" ? String(format: "%.1f", celsius).replacingOccurrences(of: ".", with: ",") : String(format: "%.1f", celsius)
        return "\(number) °C"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.languageCode == "nl" ? "nl_NL" : "en_US")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.languageCode == "nl" ? "nl_NL" : "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func bytes(_ value: UInt64) -> String { Fmt.bytes(Int64(value)) }
}
