import Foundation
import Darwin
import IOKit.ps

/// Collects read-only readings from Apple-supported interfaces and fixed system
/// tools. Nothing here changes a setting, kills a process or writes a file.
actor HealthSampler {
    private var previousCPUTicks: [UInt32]?
    private var previousCPUTime: Date?
    private var previousProcessCPU: [pid_t: UInt64] = [:]
    private var previousProcessTime: Date?
    private var previousNetwork: [String: (received: UInt64, sent: UInt64)] = [:]
    private var previousNetworkTime: Date?
    private var previousDiskBytes: (read: UInt64, write: UInt64)?
    private var previousDiskTime: Date?

    private var cachedVolumes: [VolumeHealth] = []
    private var cachedDrives: [DriveHealth] = []
    private var lastDiskRefresh = Date.distantPast
    private var diskNotes: [String] = []
    private var cachedBattery = BatteryReading()
    private var lastBatteryRefresh = Date.distantPast
    private var hardwarePorts: [String: String]?
    private var lastHardwarePortRefresh = Date.distantPast
    private var primaryInterface: String?
    private var lastPrimaryRefresh = Date.distantPast

    private let diskCacheInterval: TimeInterval = 60
    private let batteryCacheInterval: TimeInterval = 300

    func invalidateDiskCache() {
        lastDiskRefresh = .distantPast
    }

    func sample() -> HealthSnapshot {
        let now = Date()
        var snapshot = HealthSnapshot()
        snapshot.readAt = now
        snapshot.notes = []

        snapshot.memory = readMemory()
        snapshot.cpu = readCPU(now: now)
        snapshot.processes = readProcesses(now: now)
        snapshot.processCount = snapshot.processes.count
        snapshot.thermalState = Self.thermalStateText(ProcessInfo.processInfo.thermalState)

        let disk = readDisks(now: now)
        snapshot.volumes = disk.volumes
        snapshot.drives = disk.drives
        snapshot.notes.append(contentsOf: disk.notes)

        snapshot.diskIO = readDiskIO(now: now)
        snapshot.network = readNetwork(now: now)
        snapshot.battery = readBattery(now: now)
        if disk.volumes.isEmpty {
            snapshot.notes.append(L("No mounted volumes were reported."))
        }
        return snapshot
    }

    // MARK: - Memory

    nonisolated static func memoryPressureLevel(raw: Int) -> MemoryPressureLevel {
        switch raw {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private func readMemory() -> MemoryReading {
        var reading = MemoryReading()
        reading.totalBytes = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        if result == KERN_SUCCESS {
            let active = UInt64(stats.active_count) * page
            let inactive = UInt64(stats.inactive_count) * page
            let wired = UInt64(stats.wire_count) * page
            let compressed = UInt64(stats.compressor_page_count) * page
            let free = UInt64(stats.free_count) * page
            let purgeable = UInt64(stats.purgeable_count) * page
            reading.activeBytes = active
            reading.wiredBytes = wired
            reading.compressedBytes = compressed
            reading.freeBytes = free
            reading.cachedBytes = inactive
            reading.usedBytes = min(reading.totalBytes, active + wired + compressed)
            reading.availableBytes = min(reading.totalBytes, free + inactive + purgeable)
            reading.pressureFraction = reading.totalBytes > 0 ? Double(reading.usedBytes) / Double(reading.totalBytes) : 0
        }

        let rawPressure = Int(Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 0)
        reading.pressureRaw = rawPressure
        reading.pressure = Self.memoryPressureLevel(raw: rawPressure)
        if reading.pressure == .unknown {
            if reading.pressureFraction >= 0.9 { reading.pressure = .critical }
            else if reading.pressureFraction >= 0.75 { reading.pressure = .warning }
            else if reading.totalBytes > 0 { reading.pressure = .normal }
        }

        if let swap = Self.sysctlString("vm.swapusage") {
            let values = Self.parseSwap(swap)
            reading.swapTotalBytes = values.total
            reading.swapUsedBytes = values.used
        }
        return reading
    }

    nonisolated static func parseSwap(_ text: String) -> (total: UInt64, used: UInt64, free: UInt64) {
        func value(after marker: String) -> UInt64 {
            guard let range = text.range(of: marker) else { return 0 }
            let tail = text[range.upperBound...]
            let parts = tail.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first else { return 0 }
            return parseByteValue(String(first))
        }
        return (value(after: "total = "), value(after: "used = "), value(after: "free = "))
    }

    nonisolated static func parseByteValue(_ raw: String) -> UInt64 {
        let upper = raw.uppercased()
        let multiplier: Double
        if upper.hasSuffix("G") { multiplier = 1_000_000_000 }
        else if upper.hasSuffix("M") { multiplier = 1_000_000 }
        else if upper.hasSuffix("K") { multiplier = 1_000 }
        else { multiplier = 1 }
        let number = upper.dropLast(upper.hasSuffix("G") || upper.hasSuffix("M") || upper.hasSuffix("K") ? 1 : 0)
            .replacingOccurrences(of: ",", with: ".")
        return UInt64((Double(number) ?? 0) * multiplier)
    }

    // MARK: - CPU

    private func readCPU(now: Date) -> CPUReading {
        var reading = CPUReading()
        reading.coreCount = ProcessInfo.processInfo.activeProcessorCount
        reading.uptime = ProcessInfo.processInfo.systemUptime

        var load = [Double](repeating: 0, count: 3)
        _ = load.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
        reading.load1 = load[0]
        reading.load5 = load[1]
        reading.load15 = load[2]

        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return reading }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [UInt32] = []
        ticks.reserveCapacity(Int(cpuCount) * stride)
        for index in 0..<Int(cpuCount) * stride {
            ticks.append(UInt32(bitPattern: info[index]))
        }
        let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)

        if let previous = previousCPUTicks, previous.count == ticks.count, let lastTime = previousCPUTime {
            let elapsed = max(0.2, now.timeIntervalSince(lastTime))
            var totalUser: UInt64 = 0
            var totalSystem: UInt64 = 0
            var totalIdle: UInt64 = 0
            var totalNice: UInt64 = 0
            var perCore: [Double] = []
            for core in 0..<Int(cpuCount) {
                let base = core * stride
                let user = UInt64(ticks[base + Int(CPU_STATE_USER)] &- previous[base + Int(CPU_STATE_USER)])
                let system = UInt64(ticks[base + Int(CPU_STATE_SYSTEM)] &- previous[base + Int(CPU_STATE_SYSTEM)])
                let idle = UInt64(ticks[base + Int(CPU_STATE_IDLE)] &- previous[base + Int(CPU_STATE_IDLE)])
                let nice = UInt64(ticks[base + Int(CPU_STATE_NICE)] &- previous[base + Int(CPU_STATE_NICE)])
                let total = user + system + idle + nice
                perCore.append(total > 0 ? Double(user + system + nice) / Double(total) : 0)
                totalUser += user
                totalSystem += system
                totalIdle += idle
                totalNice += nice
            }
            let total = totalUser + totalSystem + totalIdle + totalNice
            if total > 0 {
                reading.usageFraction = Double(totalUser + totalSystem + totalNice) / Double(total)
                reading.userFraction = Double(totalUser) / Double(total)
                reading.systemFraction = Double(totalSystem) / Double(total)
                reading.idleFraction = Double(totalIdle) / Double(total)
                reading.perCore = perCore
                reading.warmedUp = elapsed > 0
            }
        }
        previousCPUTicks = ticks
        previousCPUTime = now
        return reading
    }

    // MARK: - Processes

    private func readProcesses(now: Date) -> [ProcessReading] {
        let maxPIDs = 8192
        var pids = [pid_t](repeating: 0, count: maxPIDs)
        let byteCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        let pidCount = max(0, Int(byteCount) / MemoryLayout<pid_t>.stride)
        let myPID = getpid()
        let myUID = getuid()
        let elapsed = previousProcessTime.map { max(0.2, now.timeIntervalSince($0)) } ?? 0
        var nextCPU: [pid_t: UInt64] = [:]
        var readings: [ProcessReading] = []
        readings.reserveCapacity(pidCount)

        for index in 0..<pidCount {
            let pid = pids[index]
            if pid <= 0 { continue }
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize)
            guard bsdResult > 0, bsd.pbi_uid == myUID else { continue }
            if pid == 1 || pid == myPID { continue }

            var nameBuffer = [CChar](repeating: 0, count: 1024)
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            var name = nameLength > 0 ? String(cString: nameBuffer) : ""

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : nil
            if name.isEmpty, let path { name = (path as NSString).lastPathComponent }
            if name.isEmpty { name = "pid \(pid)" }

            var totalCPU: UInt64 = 0
            var memory: UInt64 = 0
            var usage = rusage_info_v2()
            let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
                }
            }
            if usageResult == 0 {
                totalCPU = usage.ri_user_time &+ usage.ri_system_time
                memory = usage.ri_phys_footprint
            }
            if memory == 0 {
                var taskInfo = proc_taskinfo()
                let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
                if taskResult > 0 { memory = taskInfo.pti_resident_size }
            }
            nextCPU[pid] = totalCPU

            var cpuPercent: Double = 0
            if elapsed > 0, let previous = previousProcessCPU[pid] {
                let delta = totalCPU >= previous ? totalCPU - previous : 0
                cpuPercent = (Double(delta) / 1_000_000_000.0) / elapsed * 100
            }

            let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
            readings.append(ProcessReading(
                pid: pid,
                name: name,
                path: path,
                isApplication: false,
                cpuPercent: min(cpuPercent, Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) * 100),
                memoryBytes: memory,
                status: Self.processStatus(bsd.pbi_status),
                user: NSUserName(),
                startedAt: start,
                canManage: Self.canManageProcess(name: name, path: path, pid: pid, uid: bsd.pbi_uid),
                isOwnProcess: false,
                parentPID: pid_t(bsd.pbi_ppid)
            ))
        }
        previousProcessCPU = nextCPU
        previousProcessTime = now
        return readings
    }

    nonisolated static func processStatus(_ raw: UInt32) -> String {
        switch raw {
        case 1: return L("Idle")
        case 2: return L("Running")
        case 3: return L("Sleeping")
        case 4: return L("Stopped")
        case 5: return L("Zombie")
        default: return L("Unknown")
        }
    }

    nonisolated static func canManageProcess(name: String, path: String?, pid: pid_t, uid: uid_t) -> Bool {
        guard pid > 1, uid == getuid(), pid != getpid() else { return false }
        let protectedNames: Set<String> = [
            "launchd", "kernel_task", "WindowServer", "loginwindow", "Dock", "Finder",
            "SystemUIServer", "ControlCenter", "NotificationCenter", "WindowManager",
            "tccd", "securityd", "coreaudiod", "logd", "configd", "opendirectoryd"
        ]
        if protectedNames.contains(name) { return false }
        if let path, path.hasPrefix("/System/Library/CoreServices/") && name == "Finder" { return false }
        return true
    }

    // MARK: - Disks

    private func readDisks(now: Date) -> (volumes: [VolumeHealth], drives: [DriveHealth], notes: [String]) {
        if now.timeIntervalSince(lastDiskRefresh) < diskCacheInterval, !cachedVolumes.isEmpty {
            return (cachedVolumes, cachedDrives, [])
        }
        if now.timeIntervalSince(lastDiskRefresh) < diskCacheInterval, cachedVolumes.isEmpty {
            return ([], [], diskNotes)
        }
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey,
            .volumeUUIDStringKey, .volumeIsBrowsableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [VolumeHealth] = []
        var drivesByID: [String: DriveHealth] = [:]
        var notes: [String] = []
        var diskInfoCache: [String: [String: Any]] = [:]

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0))
            let mountPath = url.path
            let device = Self.mountDevice(mountPath) ?? ""
            let wholeDisk = Self.wholeDisk(for: device, cache: &diskInfoCache, notes: &notes)
            let driveInfo = wholeDisk.flatMap { Self.diskInfo("/dev/\($0)", cache: &diskInfoCache, notes: &notes) }
            let smart = driveInfo?["SMARTStatus"] as? String
            let isInternal = values.volumeIsInternal ?? (driveInfo?["Internal"] as? Bool ?? true)
            let isRemovable = values.volumeIsRemovable ?? false
            let isEjectable = values.volumeIsEjectable ?? false
            let isReadOnly = values.volumeIsReadOnly ?? false
            let name = values.volumeName ?? url.lastPathComponent
            let filesystem = values.volumeLocalizedFormatDescription ?? ""

            let volume = VolumeHealth(
                id: values.volumeUUIDString ?? mountPath,
                name: name,
                mountPath: mountPath,
                device: device,
                totalBytes: total,
                availableBytes: available,
                isInternal: isInternal,
                isRemovable: isRemovable,
                isEjectable: isEjectable,
                isReadOnly: isReadOnly,
                filesystem: filesystem,
                driveID: wholeDisk,
                smartStatus: smart,
                isSystemVolume: mountPath == "/" || mountPath.hasPrefix("/System/Volumes")
            )
            volumes.append(volume)

            if let wholeDisk, let driveInfo {
                if var drive = drivesByID[wholeDisk] {
                    if !drive.volumeIDs.contains(volume.id) { drive.volumeIDs.append(volume.id) }
                    drivesByID[wholeDisk] = drive
                } else {
                    drivesByID[wholeDisk] = Self.drive(from: wholeDisk, info: driveInfo, volumeID: volume.id)
                }
            }
        }

        let drives = drivesByID.values.sorted { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.id < rhs.id
        }
        volumes.sort { lhs, rhs in
            if lhs.mountPath == "/" { return true }
            if rhs.mountPath == "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        cachedVolumes = volumes
        cachedDrives = drives
        lastDiskRefresh = now
        diskNotes = notes
        return (volumes, drives, notes)
    }

    nonisolated static func mountDevice(_ path: String) -> String? {
        var stats = statfs()
        let result = path.withCString { statfs($0, &stats) }
        guard result == 0 else { return nil }
        return withUnsafePointer(to: &stats.f_mntfromname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { chars in
                String(cString: chars)
            }
        }
    }

    private nonisolated static func wholeDisk(for device: String, cache: inout [String: [String: Any]], notes: inout [String]) -> String? {
        guard !device.isEmpty else { return nil }
        let info = diskInfo(device, cache: &cache, notes: &notes)
        if let stores = info?["APFSPhysicalStores"] as? [[String: Any]],
           let first = stores.first?["APFSPhysicalStore"] as? String {
            return baseDisk(first)
        }
        if let parent = info?["ParentWholeDisk"] as? String {
            return baseDisk(parent)
        }
        return baseDisk(device)
    }

    private nonisolated static func baseDisk(_ identifier: String) -> String {
        if let range = identifier.range(of: #"disk\d+"#, options: .regularExpression) {
            return String(identifier[range])
        }
        return identifier
    }

    private nonisolated static func diskInfo(_ device: String, cache: inout [String: [String: Any]], notes: inout [String]) -> [String: Any]? {
        if let cached = cache[device] { return cached }
        let result = Shell.run("/usr/sbin/diskutil", ["info", "-plist", device], timeout: 5)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            if notes.count < 3 { notes.append(L("Drive information could not be read for %@.", device)) }
            return nil
        }
        cache[device] = dictionary
        return dictionary
    }

    private nonisolated static func drive(from id: String, info: [String: Any], volumeID: String) -> DriveHealth {
        let details = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        let smart = info["SMARTStatus"] as? String ?? ""
        let model = info["MediaName"] as? String
            ?? info["IORegistryEntryName"] as? String
            ?? info["DeviceIdentifier"] as? String
            ?? id
        let size = (info["IOKitSize"] as? Int64) ?? Int64((info["Size"] as? Int) ?? 0)
        let solid = info["SolidState"] as? Bool ?? false
        let temperature = (details["TEMPERATURE"] as? Int).map { Double($0) / 10.0 }
        return DriveHealth(
            id: id,
            model: model,
            sizeBytes: size,
            isInternal: info["Internal"] as? Bool ?? false,
            isSolidState: solid,
            smartStatus: smart,
            busProtocol: info["BusProtocol"] as? String ?? "",
            percentageUsed: intValue(details["PERCENTAGE_USED"]),
            powerOnHours: intValue(details["POWER_ON_HOURS_0"] ?? details["POWER_ON_HOURS"]),
            unsafeShutdowns: intValue(details["UNSAFE_SHUTDOWNS_0"] ?? details["UNSAFE_SHUTDOWNS"]),
            mediaErrors: intValue(details["MEDIA_ERRORS_0"] ?? details["MEDIA_ERRORS"]),
            powerCycles: intValue(details["POWER_CYCLES_0"] ?? details["POWER_CYCLES"]),
            temperatureCelsius: temperature,
            volumeIDs: [volumeID]
        )
    }

    nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func readDiskIO(now: Date) -> DiskIOReading {
        var reading = DiskIOReading()
        let result = Shell.run("/usr/sbin/ioreg", ["-r", "-c", "IOBlockStorageDriver", "-k", "Statistics"], timeout: 4)
        guard result.succeeded else { return reading }
        let read = Self.sumStatistic(in: result.stdout, key: "Bytes (Read)")
        let write = Self.sumStatistic(in: result.stdout, key: "Bytes (Write)")
        reading.totalReadBytes = read
        reading.totalWriteBytes = write
        if let previous = previousDiskBytes, let last = previousDiskTime {
            let elapsed = max(0.2, now.timeIntervalSince(last))
            if read >= previous.read { reading.readBytesPerSecond = Double(read - previous.read) / elapsed }
            if write >= previous.write { reading.writeBytesPerSecond = Double(write - previous.write) / elapsed }
            reading.warmedUp = true
        }
        previousDiskBytes = (read, write)
        previousDiskTime = now
        return reading
    }

    nonisolated static func sumStatistic(in text: String, key: String) -> UInt64 {
        let marker = "\"\(key)\"="
        var total: UInt64 = 0
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            var index = range.upperBound
            var digits = ""
            while index < text.endIndex, text[index].isNumber {
                digits.append(text[index])
                index = text.index(after: index)
            }
            if let value = UInt64(digits) { total &+= value }
            searchStart = index
        }
        return total
    }

    // MARK: - Network

    private func readNetwork(now: Date) -> NetworkReading {
        var reading = NetworkReading()
        let counters = Self.networkCounters()
        let addresses = Self.networkAddresses()
        if now.timeIntervalSince(lastHardwarePortRefresh) > 300 {
            hardwarePorts = Self.hardwarePortNames()
            lastHardwarePortRefresh = now
        }
        let hardware = hardwarePorts ?? [:]
        if now.timeIntervalSince(lastPrimaryRefresh) > 60 {
            primaryInterface = Self.routePrimaryInterface()
            lastPrimaryRefresh = now
        }
        reading.primaryInterface = primaryInterface

        let elapsed = previousNetworkTime.map { now.timeIntervalSince($0) } ?? 0
        var next: [String: (received: UInt64, sent: UInt64)] = [:]
        var interfaces: [NetworkInterfaceReading] = []
        for (name, bytes) in counters {
            if name == "lo0" { continue }
            if bytes.received == 0 && bytes.sent == 0 && name != primaryInterface { continue }
            let (receiveRate, sendRate) = Self.networkRates(current: bytes, previous: previousNetwork[name], elapsed: elapsed)
            next[name] = bytes
            reading.totalReceived &+= bytes.received
            reading.totalSent &+= bytes.sent
            reading.receiveRate += receiveRate
            reading.sendRate += sendRate
            interfaces.append(NetworkInterfaceReading(
                name: name,
                displayName: hardware[name] ?? Self.friendlyInterfaceName(name),
                address: addresses[name],
                receivedBytes: bytes.received,
                sentBytes: bytes.sent,
                receiveRate: receiveRate,
                sendRate: sendRate,
                isUp: true
            ))
        }
        if interfaces.isEmpty {
            for (name, address) in addresses where name != "lo0" {
                interfaces.append(NetworkInterfaceReading(name: name, displayName: hardware[name] ?? Self.friendlyInterfaceName(name), address: address, receivedBytes: 0, sentBytes: 0, receiveRate: 0, sendRate: 0, isUp: true))
            }
        }
        interfaces.sort { lhs, rhs in
            if lhs.name == reading.primaryInterface { return true }
            if rhs.name == reading.primaryInterface { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        reading.interfaces = interfaces
        previousNetwork = next
        previousNetworkTime = now
        return reading
    }

    nonisolated static func friendlyInterfaceName(_ name: String) -> String {
        if name.hasPrefix("utun") { return L("VPN tunnel") }
        if name.hasPrefix("awdl") { return "AirDrop" }
        if name.hasPrefix("llw") { return "Low Latency WLAN" }
        if name.hasPrefix("bridge") { return L("Bridge") }
        if name == "en0" { return "Wi-Fi" }
        if name.hasPrefix("en") { return L("Ethernet") }
        return name
    }

    nonisolated static func networkRates(current: (received: UInt64, sent: UInt64),
                                         previous: (received: UInt64, sent: UInt64)?,
                                         elapsed: TimeInterval) -> (Double, Double) {
        // A missed minute, a new interface or a reset starts a new baseline.
        guard let previous, elapsed > 0, elapsed < 60,
              current.received >= previous.received, current.sent >= previous.sent else { return (0, 0) }
        return (Double(current.received - previous.received) / elapsed, Double(current.sent - previous.sent) / elapsed)
    }

    private nonisolated static func networkCounters() -> [String: (received: UInt64, sent: UInt64)] {
        let result = Shell.run("/usr/sbin/netstat", ["-ib"], timeout: 4)
        guard result.succeeded else { return [:] }
        var counters: [String: (received: UInt64, sent: UInt64)] = [:]
        for line in result.stdout.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 10, parts[2].hasPrefix("<Link") else { continue }
            let hasAddress = UInt64(parts[3]) == nil
            let incomingIndex = hasAddress ? 6 : 5
            let outgoingIndex = hasAddress ? 9 : 8
            guard parts.count > outgoingIndex else { continue }
            let name = parts[0].replacingOccurrences(of: "*", with: "")
            let received = UInt64(parts[incomingIndex]) ?? 0
            let sent = UInt64(parts[outgoingIndex]) ?? 0
            if let existing = counters[name] {
                counters[name] = (max(existing.received, received), max(existing.sent, sent))
            } else {
                counters[name] = (received, sent)
            }
        }
        return counters
    }

    private nonisolated static func networkAddresses() -> [String: String] {
        var addresses: [String: String] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return addresses }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    let value = String(cString: host)
                    if !value.hasPrefix("127.") { addresses[name] = value }
                }
            }
            cursor = interface.ifa_next
        }
        return addresses
    }

    private nonisolated static func routePrimaryInterface() -> String? {
        let result = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
        guard result.succeeded else { return nil }
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private nonisolated static func hardwarePortNames() -> [String: String] {
        let result = Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 4)
        guard result.succeeded else { return [:] }
        var mapping: [String: String] = [:]
        var currentPort: String?
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentPort = trimmed.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:"), let port = currentPort {
                let device = trimmed.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                mapping[device] = port
            }
        }
        return mapping
    }

    // MARK: - Battery

    private func readBattery(now: Date) -> BatteryReading {
        // Live values (charge, charging state, adapter, time, voltage) are read on every
        // sample. Only the slow system_profiler fields (condition, maximum capacity,
        // cycle count) are cached, so the gauge never lags behind the real charge.
        var reading = BatteryReading()
        reading.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
                guard let type = description[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType else { continue }
                reading.isPresent = true
                reading.percent = description[kIOPSCurrentCapacityKey] as? Int
                reading.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
                let state = description[kIOPSPowerSourceStateKey] as? String
                reading.isPluggedIn = state == kIOPSACPowerValue
                if reading.isCharging, let full = description[kIOPSTimeToFullChargeKey] as? Int, full > 0 {
                    reading.timeRemainingMinutes = full
                } else if !reading.isPluggedIn, let empty = description[kIOPSTimeToEmptyKey] as? Int, empty > 0 {
                    reading.timeRemainingMinutes = empty
                }
                break
            }
        }

        let ioreg = Shell.run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: 4)
        if ioreg.succeeded {
            let text = ioreg.stdout
            reading.isPresent = reading.isPresent || text.contains("\"AppleSmartBattery\"")
            reading.cycleCount = Self.intFromIOReg(text, key: "CycleCount")
            reading.voltageMillivolts = Self.intFromIOReg(text, key: "Voltage")
            if let temperature = Self.intFromIOReg(text, key: "Temperature") ?? Self.intFromIOReg(text, key: "VirtualTemperature"),
               temperature > 0 {
                // AppleSmartBattery reports hundredths of a degree Celsius (3021 = 30.21 °C).
                reading.temperatureCelsius = Double(temperature) / 100.0
            }
            if let design = Self.intFromIOReg(text, key: "DesignCapacity") {
                reading.designCapacity = design
            }
            if let maxCapacity = Self.intFromIOReg(text, key: "AppleRawMaxCapacity") ?? Self.intFromIOReg(text, key: "NominalChargeCapacity") {
                reading.maxCapacity = maxCapacity
            }
            if let design = reading.designCapacity, let max = reading.maxCapacity, design > 0 {
                reading.healthPercent = min(100, Int((Double(max) / Double(design) * 100).rounded()))
            }
            // AdapterDetails is a nested dictionary printed without spaces: "Watts"=68
            if let watts = Self.intFromIOReg(text, key: "Watts"), watts > 0 {
                reading.adapterWatts = watts
            }
            if reading.timeRemainingMinutes == nil {
                let key = reading.isCharging ? "AvgTimeToFull" : (reading.isPluggedIn ? nil : "AvgTimeToEmpty")
                if let key, let minutes = Self.intFromIOReg(text, key: key), minutes > 0, minutes < 65535 {
                    reading.timeRemainingMinutes = minutes
                }
            }
        }
        if reading.isPluggedIn, reading.adapterWatts == nil {
            reading.adapterWatts = Self.adapterWattsFromIOPS()
        }

        if now.timeIntervalSince(lastBatteryRefresh) >= batteryCacheInterval {
            var slow = BatteryReading()
            let profiler = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 8)
            if profiler.succeeded {
                let text = profiler.stdout
                slow.condition = Self.stringAfter(text, label: "Condition:")
                slow.cycleCount = Self.intAfter(text, label: "Cycle Count:")
                slow.healthPercent = Self.intAfter(text, label: "Maximum Capacity:")
            }
            cachedBattery = slow
            lastBatteryRefresh = now
        }
        if let condition = cachedBattery.condition { reading.condition = condition }
        if let cycles = cachedBattery.cycleCount { reading.cycleCount = cycles }
        if let health = cachedBattery.healthPercent { reading.healthPercent = health }

        if !reading.isPresent {
            reading.notes.append(L("This Mac reports no internal battery. Battery readings are unavailable, and the Power page still shows the power settings."))
        } else {
            if reading.condition == nil { reading.notes.append(L("Battery condition is not reported by this Mac.")) }
            if !reading.isPluggedIn { reading.adapterWatts = nil }
        }
        return reading
    }

    private static func adapterWattsFromIOPS() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else { return nil }
        if let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 { return watts }
        if let volts = details["AdapterVoltage"] as? Int, let current = details[kIOPSPowerAdapterCurrentKey] as? Int, volts > 0, current > 0 {
            return Int((Double(volts) * Double(current) / 1_000_000).rounded())
        }
        return nil
    }

    nonisolated static func intFromIOReg(_ text: String, key: String) -> Int? {
        // Top-level properties print as `"Key" = 1`; nested dictionaries as `"Key"=1`.
        guard let range = text.range(of: "\"\(key)\" = ") ?? text.range(of: "\"\(key)\"=") else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    nonisolated static func intAfter(_ text: String, label: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits)
    }

    nonisolated static func stringAfter(_ text: String, label: String) -> String? {
        guard let range = text.range(of: label) else { return nil }
        let tail = text[range.upperBound...]
        let value = tail.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    nonisolated static func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return L("Nominal")
        case .fair: return L("Fair")
        case .serious: return L("Serious")
        case .critical: return L("Critical")
        @unknown default: return L("Unknown")
        }
    }

    // MARK: - sysctl helpers

    nonisolated static func sysctlInt32(_ name: String) -> Int32? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value: Int32 = 0
        var actual = size
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            sysctlbyname(name, pointer, &actual, nil, 0)
        }
        return result == 0 ? value : nil
    }

    nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        var actual = size
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname(name, pointer.baseAddress, &actual, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
}
