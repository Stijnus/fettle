import Foundation

/// Fixed product rules: reminder schedules, alert thresholds and the limits
/// the maintenance and uninstaller scanners work within.
///
/// Keeping them in one place means Settings, the scanners, notifications and
/// the self-test all agree on the same values.
enum Rules {

    // MARK: - Reminders

    /// Cleanup reminder intervals offered in Settings: every 3 days, weekly
    /// (the default), every two weeks or monthly.
    enum Reminder {
        static let optionDays: [Int] = [3, 7, 14, 30]
        static let optionSeconds: [Double] = [
            259_200,    // 3 days
            604_800,    // 7 days
            1_209_600,  // 14 days
            2_592_000,  // 30 days
        ]
        static let defaultDays: Int = 7

        /// Notification category for the periodic cleanup reminder.
        static let notificationCategory = "FettleCleanupReminder"
        /// The reminder repeats at the chosen interval until it is turned off.
        static let notificationRepeats = true

        /// Interval for a stored option. Falls back to a plain day conversion
        /// if a value outside the option table is ever supplied (for example
        /// from a future migration).
        static func intervalSeconds(forDays days: Int) -> Double {
            if let index = optionDays.firstIndex(of: days) {
                return optionSeconds[index]
            }
            return Double(max(1, days)) * 86_400
        }
    }

    // MARK: - Trash size alert

    /// Trash size alert thresholds, 500 MB … 100 GB in decimal bytes.
    static let trashAlertThresholdBytes: [Int64] = [
        500_000_000,          // 500 MB
        1_000_000_000,        // 1 GB
        2_000_000_000,        // 2 GB
        3_000_000_000,        // 3 GB
        5_000_000_000,        // 5 GB
        10_000_000_000,       // 10 GB
        15_000_000_000,       // 15 GB
        20_000_000_000,       // 20 GB
        30_000_000_000,       // 30 GB
        50_000_000_000,       // 50 GB
        100_000_000_000,      // 100 GB
    ]

    /// The default is the third option, 2 GB.
    static let defaultTrashAlertThresholdIndex = 2

    static var defaultTrashAlertThresholdBytes: Int64 {
        trashAlertThresholdBytes[defaultTrashAlertThresholdIndex]
    }

    static var defaultTrashThresholdMB: Int {
        Int(defaultTrashAlertThresholdBytes / 1_000_000)
    }

    // MARK: - Low disk space alert

    /// Low disk space alert thresholds, 2 GB … 100 GB in decimal bytes.
    static let diskSpaceAlertThresholdBytes: [Int64] = [
        2_000_000_000,
        5_000_000_000,
        10_000_000_000,
        20_000_000_000,
        30_000_000_000,
        50_000_000_000,
        100_000_000_000,
    ]

    /// Free space assumed when the volume cannot report it (1 TB), which makes
    /// the automatic threshold 100 GB.
    static let diskSpaceUnknownBytes: Int64 = 1_000_000_000_000

    /// The option nearest to 10% of `value`. The tenth is computed with integer
    /// division, so it is floored, and an exact tie keeps the earlier, smaller
    /// option.
    static func nearestThreshold(to value: Int64, options: [Int64]) -> Int64 {
        guard !options.isEmpty else { return 0 }
        let target = max(0, value) / 10
        let targetValue = Double(target)
        var best = options[0]
        var bestDistance = abs(Double(best) - targetValue)
        for option in options.dropFirst() {
            let distance = abs(Double(option) - targetValue)
            if distance < bestDistance {
                best = option
                bestDistance = distance
            }
        }
        return best
    }

    /// Automatic alert threshold for the current free space. Only an absent
    /// value uses the 1 TB fallback; a readable zero is a real value and
    /// resolves to the smallest option (2 GB).
    static func defaultDiskSpaceThreshold(freeSpace: Int64?) -> Int64 {
        if let freeSpace {
            return nearestThreshold(to: freeSpace, options: diskSpaceAlertThresholdBytes)
        }
        return nearestThreshold(to: diskSpaceUnknownBytes, options: diskSpaceAlertThresholdBytes)
    }

    static func diskSpaceThresholdGB(forOption bytes: Int64) -> Int {
        Int(bytes / 1_000_000_000)
    }

    // MARK: - Maintenance rules

    /// A personal LaunchAgent is broken when its program cannot be found. A
    /// relative `Program` is resolved against `WorkingDirectory`, `~` is
    /// expanded, and a missing path is only reported when no installed app
    /// owns it. The executable bit is never used as a signal.
    enum LaunchAgent {
        /// A path inside an `.app` bundle is treated as owned by that app —
        /// the ownership boundary a non-privileged app can check.
        static let appOwnedMarker = ".app/Contents/"
    }

    /// A preference file is broken when it cannot be read as a valid property
    /// list.
    enum Preferences {
        static let maxFilesPerScan = 2_000
    }

    // MARK: - Uninstaller leftovers

    /// Extra user-writable roots, beyond the standard Library folders, where
    /// apps leave per-bundle-identifier data. System-wide roots under
    /// `/Library` need administrator rights, so Fettle does not remove them.
    enum Leftovers {
        static let userRoots: [(relativeToLibrary: String, appendsBundleID: Bool)] = [
            ("Preferences/SDMHelpData/Other", true),
            ("Application Support/Adobe/AIR/ELS", true),
        ]
    }
}
