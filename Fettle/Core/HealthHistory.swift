import Foundation

/// Numeric activity readings kept on this Mac. No process names, file paths,
/// browser data or credentials are stored here.
@MainActor
final class HealthHistoryStore: ObservableObject {
    @Published private(set) var samples: [HealthHistorySample] = []
    private let fileURL: URL
    private let retention: TimeInterval = 7 * 24 * 60 * 60
    private let limit = 10_080

    init(fileURL: URL = AppPaths.healthHistoryFile) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HealthHistorySample].self, from: data) else {
            samples = []
            return
        }
        let cutoff = Date().addingTimeInterval(-retention)
        samples = decoded.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    func append(_ sample: HealthHistorySample) {
        if let last = samples.last, sample.date.timeIntervalSince(last.date) < 1 {
            return
        }
        samples.append(sample)
        prune()
        save()
    }

    func append(snapshot: HealthSnapshot) {
        let root = snapshot.rootVolume
        let battery = snapshot.battery
        append(HealthHistorySample(
            date: snapshot.readAt,
            cpuPercent: snapshot.cpu.usagePercent,
            memoryUsedBytes: snapshot.memory.usedBytes,
            memoryTotalBytes: snapshot.memory.totalBytes,
            memoryPressure: snapshot.memory.pressure,
            diskFreeBytes: root?.availableBytes ?? 0,
            diskTotalBytes: root?.totalBytes ?? 0,
            networkInBytesPerSecond: snapshot.network.receiveRate,
            networkOutBytesPerSecond: snapshot.network.sendRate,
            batteryPercent: battery.isPresent ? battery.percent : nil,
            thermalState: snapshot.thermalState
        ))
    }

    func samples(since date: Date) -> [HealthHistorySample] {
        samples.filter { $0.date >= date }
    }

    func latest(_ count: Int = 20) -> [HealthHistorySample] {
        Array(samples.suffix(max(0, count))).reversed()
    }

    func clear() {
        samples = []
        save()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retention)
        samples.removeAll { $0.date < cutoff }
        if samples.count > limit {
            samples = Array(samples.suffix(limit))
        }
    }

    private func save() {
        try? AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(samples) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
