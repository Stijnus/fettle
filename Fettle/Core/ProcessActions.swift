import Foundation
import AppKit
import Darwin
import ApplicationServices

enum ProcessActions {
    /// Re-checks that the process is still the same user-owned process that was
    /// shown in the list. A recycled PID is refused.
    static func stillMatches(_ reading: ProcessReading) -> Bool {
        guard reading.pid > 1, reading.pid != getpid(), reading.canManage else { return false }
        var bsd = proc_bsdinfo()
        let result = proc_pidinfo(reading.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard result > 0, bsd.pbi_uid == getuid() else { return false }
        if let startedAt = reading.startedAt {
            let started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
            if abs(started.timeIntervalSince(startedAt)) > 1.0 { return false }
        }
        if reading.isApplication, let bundleID = reading.bundleID {
            guard let app = NSRunningApplication(processIdentifier: reading.pid),
                  app.bundleIdentifier == bundleID else { return false }
            return true
        }
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let nameLength = proc_name(reading.pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            let current = String(cString: nameBuffer)
            if !reading.name.isEmpty, current != reading.name, !reading.name.hasPrefix("pid ") { return false }
        }
        return true
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        var bsd = proc_bsdinfo()
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        return result > 0 && bsd.pbi_status != 5
    }

    /// Quits one process. Returns (success, message). The caller has already
    /// confirmed the action; this method revalidates the process first.
    static func quit(_ reading: ProcessReading, force: Bool) -> (Bool, String) {
        guard stillMatches(reading) else {
            return (false, L("The process changed or is no longer available, so nothing was done."))
        }
        let app = NSRunningApplication(processIdentifier: reading.pid)
        if let app, !app.isTerminated {
            if force {
                let sent = app.forceTerminate()
                if !sent { return (false, L("macOS refused to force quit %@.", reading.displayName)) }
                if waitForExit(reading.pid, app: app, timeout: 1.5) {
                    return (true, L("%@ was force quit.", reading.displayName))
                }
                return (false, L("%@ is still running.", reading.displayName))
            }
            let sent = app.terminate()
            if !sent { return (false, L("macOS refused to quit %@.", reading.displayName)) }
            if waitForExit(reading.pid, app: app, timeout: 3.0) {
                return (true, L("%@ quit.", reading.displayName))
            }
            return (false, L("%@ did not quit. You can try Force Quit.", reading.displayName))
        }

        let signal = force ? SIGKILL : SIGTERM
        if kill(reading.pid, signal) != 0 {
            return (false, L("Permission denied. Fettle could not quit %@.", reading.displayName))
        }
        if waitForExit(reading.pid, app: nil, timeout: force ? 1.5 : 3.0) {
            return (true, force ? L("%@ was force quit.", reading.displayName) : L("%@ quit.", reading.displayName))
        }
        return (false, L("%@ did not quit. You can try Force Quit.", reading.displayName))
    }

    private static func waitForExit(_ pid: pid_t, app: NSRunningApplication?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app, app.isTerminated { return true }
            if !isRunning(pid) { return true }
            usleep(80_000)
        }
        if let app { return app.isTerminated }
        return !isRunning(pid)
    }

    // MARK: - Responsiveness

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Uses the Accessibility API with a short messaging timeout. A process that
    /// cannot answer within that window is reported as not responding. Without
    /// Accessibility permission this returns nil (unknown), never a guess.
    static func responsiveness(of pid: pid_t) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.45)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if result == .success { return true }
        if result == .cannotComplete { return false }
        // Missing Accessibility support, a terminated element or revoked
        // permission are unknown, not proof that the app is hung.
        return nil
    }

    static func openAccessibilitySettings() {
        _ = SystemActions.open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    }
}
