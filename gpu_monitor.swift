// ===========================================================================
// MARK: - GPU & Thermals pane
// ===========================================================================
//
//   A pane that surfaces the metrics Activity Monitor is sparse on:
//     • GPU utilization (Device/Renderer/Activity %, per-accelerator)
//     • GPU memory in-use vs. free VRAM (per-accelerator)
//     • Thermal pressure (Process Info)
//     • Fan RPM where SMC exposes it (graceful no-op on Apple Silicon)
//     • Current AC power draw + battery state (pmset -g batt)
//     • 60-second rolling sparkline per metric
//
//   Audience: gamers, ML devs, video editors. Pin-to-front, CSV export,
//   keyboard-driven, optional menubar alert when thermal state ≥ .serious.
//
//   No `@main`, no `App`, no new `Pane` case in this file. Public entry
//   point is `GPUMonitorView`. Wire it up from main.swift when ready.
//
// ===========================================================================

import SwiftUI
import AppKit
import Foundation
import IOKit
import Metal

// ===========================================================================
// MARK: - Data model
// ===========================================================================

/// One per IOAccelerator service. We key by registry ID so we can match
/// MTLDevice → IOService and merge static info (vendor/name/VRAM) with
/// dynamic performance stats (utilization/in-use memory).
struct GPUAccelerator: Identifiable, Hashable {
    let id: UInt64                  // registry entry id
    var name: String                // e.g. "Apple M3 Max" or "AMD Radeon Pro 5500M"
    var vendor: String              // "Apple", "AMD", "Intel", "NVIDIA", "—"
    var totalVRAM: Int64            // bytes, from Metal recommendedMaxWorkingSetSize
    var isHeadless: Bool            // Metal isHeadless
    var isLowPower: Bool            // Metal isLowPower
    // dynamic — refreshed every tick:
    var deviceUtilization: Double?  // 0…100
    var rendererUtilization: Double?
    var gpuActivity: Double?        // 0…100, generic "% busy"
    var inUseSystemMemory: Int64?   // bytes
    var freeVRAM: Int64?            // bytes (computed: total - inUse) when one side missing
    var rawStats: [String: Any]     // for the JSON snapshot — non-Hashable

    // red-team: manual Hashable conformance keyed on `id` only. Automatic
    // synthesis fails because `[String: Any]` isn't Hashable; we don't need
    // to compare/hash the raw stats anyway — id is the stable identifier.
    static func == (a: GPUAccelerator, b: GPUAccelerator) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct GPUSample {
    let t: Date
    let perGPU: [UInt64: (activity: Double, mem: Int64)]
    let thermal: ProcessInfo.ThermalState
    // red-team: distinguish "couldn't read SMC" (nil) from "fans measured at 0
    // RPM" (empty / zero values). Previously a failed read produced [] which
    // looked identical to a silent-fan reading on a passive iPad-class Mac.
    let fanRPMs: [Int]?             // nil = SMC unreadable, [] = 0 fans reported, [v…] = real RPMs
    let acWatts: Double?            // nil when on battery / pmset silent
    let batteryPercent: Int?        // nil when no battery
    let onAC: Bool
}

extension ProcessInfo.ThermalState {
    var gpuLabel: String {
        switch self {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    var gpuTint: Color {
        switch self {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
    /// True if we want to flash the optional menubar alert.
    var gpuAlerting: Bool {
        switch self { case .serious, .critical: return true; default: return false }
    }
    /// Ordinal mapping used by the qualitative-pressure sparkline. 0…3.
    var gpuOrdinal: Double {
        switch self {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

// ===========================================================================
// MARK: - HID sensor types (experimental, private API)
// ===========================================================================

/// Coarse role bucket inferred from the sensor's `Product` string.
enum GPUSensorRole: String, CaseIterable {
    case cpu      = "CPU"
    case gpu      = "GPU"
    case battery  = "Battery"
    case pmu      = "SoC / PMU"
    case other    = "Other"

    var tint: Color {
        switch self {
        case .cpu:     return .orange
        case .gpu:     return .pink
        case .battery: return .green
        case .pmu:     return .purple
        case .other:   return .secondary
        }
    }

    /// Heuristic — case-insensitive substring match on the sensor name.
    static func infer(from name: String) -> GPUSensorRole {
        let l = name.lowercased()
        // red-team: order matters. "pcpu/ecpu" before plain "cpu" is irrelevant
        // here (substring "cpu" matches both), but check the cores first for
        // future-proofing in case Apple renames them.
        if l.contains("pcpu") || l.contains("ecpu") || l.contains("cpu") {
            return .cpu
        }
        if l.contains("gpu") { return .gpu }
        if l.contains("battery") || l.contains("gas gauge") { return .battery }
        if l.contains("pmu") || l.contains("pmp") { return .pmu }
        return .other
    }
}

/// One temperature reading from a single HID sensor at a given tick.
struct GPUSensorReading: Identifiable, Hashable {
    let id: String          // the sensor's Product string (stable per boot)
    let name: String        // == id, kept separate for future renaming
    let role: GPUSensorRole
    let celsius: Double
    let t: Date
}

/// A bucketed series for the temperature chart — one row per role.
struct GPUTempChartRow: Identifiable {
    let id: GPUSensorRole
    let role: GPUSensorRole
    let series: [(t: Date, c: Double)]   // 60s rolling, averaged across sensors in this role
    let currentC: Double?
    /// Underlying sensor `Product` strings that contributed to this row's
    /// latest sample. Drives the per-row tooltip so power users can confirm
    /// which sensors Apple grouped under, e.g., "GPU".
    let sensorNames: [String]
}

// ===========================================================================
// MARK: - IOHIDEventSystemClient bridge (private API)
// ===========================================================================
//
//   These symbols are exported by /System/Library/Frameworks/IOKit.framework
//   (and the HID family inside it) but are *not* declared in the public
//   IOKit headers. We import via `@_silgen_name` so the linker resolves
//   against the live dylib at runtime — no extra link flags needed because
//   the GPU pane already imports `IOKit`.
//
//   This is the same approach Stats, iStat Menus, and Hot use. Apple
//   doesn't bless it; macOS updates can and have moved sensor keys. We
//   degrade gracefully when the matching set is empty (headless servers,
//   VMs, or a future macOS that locks this down further).
//
// ===========================================================================

@_silgen_name("IOHIDEventSystemClientCreate")
private func _IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func _IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func _IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func _IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int64, _ timestamp: UInt64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func _IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
private func _IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// Apple's private HID page for thermal sensors.
///   - PrimaryUsagePage 0xff00 = "AppleVendor"
///   - PrimaryUsage      0x0005 = "Temperature"
/// `IOHIDEventTypeTemperature` is enum value 15. The float field for the
/// reading is `IOHIDEventFieldBase(15) | 1` == `(15 << 16) | 1` == 983041.
private let kGPUHIDPrimaryUsagePageKey   = "PrimaryUsagePage" as CFString
private let kGPUHIDPrimaryUsageKey       = "PrimaryUsage"     as CFString
private let kGPUHIDProductKey            = "Product"          as CFString
private let kGPUHIDEventTypeTemperature: Int64 = 15
private let kGPUHIDTemperatureFloatField: Int32 = (15 << 16) | 1   // 983041

/// Background sampler for HID temperature sensors. Lazy: nothing runs until
/// `start()` is called, and stopping fully releases the system client.
/// All public methods are main-thread-safe; the inner reads happen on a
/// dedicated background queue.
final class GPUHIDSensors {
    private let queue = DispatchQueue(label: "trove.gpu.hid", qos: .utility)
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var serviceNames: [ObjectIdentifier: String] = [:]   // memo so we don't re-read Product per tick

    /// Set on first successful `services` enumeration. False = empty matching
    /// (headless / VM / locked-down macOS). Drives the empty-state copy.
    private(set) var hasServices: Bool = false

    /// One sample of all available sensors at a given tick.
    var lastReadings: [GPUSensorReading] = []

    /// Lazy open. Returns true if the client was created. Doesn't itself
    /// guarantee non-empty services — that's `hasServices`.
    @discardableResult
    func openIfNeeded() -> Bool {
        if client != nil { return true }
        guard let unmanaged = _IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return false
        }
        let c = unmanaged.takeRetainedValue()
        let matching: [String: Any] = [
            (kGPUHIDPrimaryUsagePageKey as String): 0xff00,
            (kGPUHIDPrimaryUsageKey     as String): 0x0005,
        ]
        _ = _IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
        self.client = c
        refreshServices()
        return true
    }

    /// Re-enumerate services. Cheap; called once on open and could be
    /// re-called if the user hot-plugs an eGPU mid-session.
    func refreshServices() {
        guard let c = client else { return }
        // red-team #1: CopyServices returns a +1 CFArray. Use takeRetainedValue.
        guard let unmanaged = _IOHIDEventSystemClientCopyServices(c) else {
            services = []
            hasServices = false
            return
        }
        let arr = unmanaged.takeRetainedValue() as Array
        var out: [AnyObject] = []
        var names: [ObjectIdentifier: String] = [:]
        for entry in arr {
            // Cast the CFTypeRef array element to AnyObject so we can pass
            // it to the C bridge functions.
            let svc = entry as AnyObject
            // Memoize the Product string per service. red-team #4: this read
            // happens once per service-lifetime, not once per tick.
            if let propUM = _IOHIDServiceClientCopyProperty(svc, kGPUHIDProductKey) {
                let cf = propUM.takeRetainedValue()
                if let s = cf as? String, !s.isEmpty {
                    names[ObjectIdentifier(svc)] = s
                }
            }
            out.append(svc)
        }
        self.services = out
        self.serviceNames = names
        self.hasServices = !out.isEmpty
    }

    /// Synchronous: read every matched service once. Skips services whose
    /// `CopyEvent` returns nil (event hasn't fired yet on this tick — red-team
    /// #2: don't poison the chart with zeros).
    func sample() -> [GPUSensorReading] {
        guard !services.isEmpty else { return [] }
        let now = Date()
        var out: [GPUSensorReading] = []
        out.reserveCapacity(services.count)
        for svc in services {
            guard let evUM = _IOHIDServiceClientCopyEvent(svc, kGPUHIDEventTypeTemperature, 0, 0) else {
                continue
            }
            let event = evUM.takeRetainedValue()
            let value = _IOHIDEventGetFloatValue(event, kGPUHIDTemperatureFloatField)
            // Sanity: thermistors land 0…125 °C. Anything else is garbage.
            guard value.isFinite, value > -40, value < 200 else { continue }
            let name = serviceNames[ObjectIdentifier(svc)] ?? "Sensor"
            out.append(GPUSensorReading(
                id: name,
                name: name,
                role: GPUSensorRole.infer(from: name),
                celsius: value,
                t: now
            ))
        }
        return out
    }

    /// Async sample → main-queue callback. red-team #7: keep HID off the UI thread.
    func sampleAsync(_ done: @escaping ([GPUSensorReading]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let r = self.sample()
            DispatchQueue.main.async {
                self.lastReadings = r
                done(r)
            }
        }
    }

    /// Release the client + services. We don't get an explicit teardown call
    /// on macOS for IOHIDEventSystemClient — dropping the last retain releases
    /// it. Clearing the array does that.
    func close() {
        services.removeAll()
        serviceNames.removeAll()
        client = nil
        hasServices = false
        lastReadings = []
    }
}

// ===========================================================================
// MARK: - IOKit / IOAccelerator probe
// ===========================================================================

/// Walks the IORegistry for `IOAccelerator` services and pulls the
/// `PerformanceStatistics` dict (present on Apple Silicon, AMD, and
/// usually NVIDIA Web Drivers). Returns merged static+dynamic state.
///
/// Red-team: on Hackintoshes / headless servers `IOServiceMatching` can
/// yield zero results. Caller handles the empty case (renders "No
/// accelerator visible"); we don't fatalError.
enum GPUProbe {

    static func snapshot() -> [GPUAccelerator] {
        var out: [GPUAccelerator] = []

        // Build a map of registry-id → MTLDevice so we can attach the
        // Metal name / VRAM ceiling to the matching IOService entry.
        var metalByID: [UInt64: MTLDevice] = [:]
        var devices: [MTLDevice]
        #if os(macOS)
        devices = MTLCopyAllDevices()
        // red-team: on early boot / display-arbiter-not-ready /
        // remote-SSH-no-graphics-session, MTLCopyAllDevices() can return [].
        // Fall back to the system default so we at least surface the iGPU.
        // IOAccelerator iteration below still works either way; this only
        // affects the human-readable name and VRAM ceiling.
        if devices.isEmpty, let def = MTLCreateSystemDefaultDevice() {
            devices = [def]
        }
        #else
        devices = MTLCreateSystemDefaultDevice().map { [$0] } ?? []
        #endif
        for d in devices { metalByID[d.registryID] = d }

        guard let matching = IOServiceMatching("IOAccelerator") else { return [] }
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var entry: io_registry_entry_t = IOIteratorNext(iter)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iter)
            }

            var regID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &regID)

            var unmanaged: Unmanaged<CFMutableDictionary>?
            let pr = IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
            guard pr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let perf = (dict["PerformanceStatistics"] as? [String: Any]) ?? [:]

            // Vendor / name. Try IOService class first, then Metal device.
            var name = "GPU"
            var vendor = "—"
            if let m = metalByID[regID] {
                name = m.name
            } else if let n = dict["IOName"] as? String {
                name = n
            } else if let n = dict["model"] as? Data, let s = String(data: n, encoding: .utf8) {
                name = s.trimmingCharacters(in: .controlCharacters)
            }
            let lower = name.lowercased()
            if      lower.contains("apple")  { vendor = "Apple" }
            else if lower.contains("amd") || lower.contains("radeon") { vendor = "AMD" }
            else if lower.contains("intel")  { vendor = "Intel" }
            else if lower.contains("nvidia") || lower.contains("geforce") { vendor = "NVIDIA" }

            var total: Int64 = 0
            if let m = metalByID[regID] {
                total = Int64(m.recommendedMaxWorkingSetSize)
            } else if let v = perf["vramFreeBytes"] as? Int64, let u = perf["vramUsedBytes"] as? Int64 {
                total = v + u
            }

            // Pull the well-known dynamic keys; missing ones stay nil.
            func dnum(_ k: String) -> Double? { (perf[k] as? NSNumber)?.doubleValue }
            func inum(_ k: String) -> Int64?  { (perf[k] as? NSNumber).map { Int64(truncating: $0) } }

            let deviceUtil   = dnum("Device Utilization %")
            let rendererUtil = dnum("Renderer Utilization %")
            let activity     = dnum("GPU Activity(%)") ?? dnum("GPU Core Utilization") ?? deviceUtil ?? rendererUtil
            let inUseMem     = inum("In use system memory") ?? inum("vramUsedBytes") ?? inum("Alloc system memory")
            let freeVRAM     = inum("Free VRAM") ?? inum("vramFreeBytes") ?? (total > 0 && inUseMem != nil ? max(total - inUseMem!, 0) : nil)

            out.append(GPUAccelerator(
                id: regID,
                name: name,
                vendor: vendor,
                totalVRAM: total,
                isHeadless: metalByID[regID]?.isHeadless ?? false,
                isLowPower: metalByID[regID]?.isLowPower ?? false,
                deviceUtilization: deviceUtil,
                rendererUtilization: rendererUtil,
                gpuActivity: activity,
                inUseSystemMemory: inUseMem,
                freeVRAM: freeVRAM,
                rawStats: perf
            ))
        }

        // Stable order: discrete > integrated > headless, then by name.
        out.sort { a, b in
            let ra = (a.isLowPower ? 1 : 0) + (a.isHeadless ? 2 : 0)
            let rb = (b.isLowPower ? 1 : 0) + (b.isHeadless ? 2 : 0)
            if ra != rb { return ra < rb }
            return a.name < b.name
        }
        return out
    }
}

// ===========================================================================
// MARK: - SMC fan probe (best-effort, no sudo)
// ===========================================================================
//
//   The SMC interface is private. On Apple Silicon many keys require root
//   and the modern thermal driver hides fan RPM entirely. We make a single
//   best-effort attempt; failure → empty array → UI shows "—".
//
//   We deliberately keep this short and defensive. Red-team #3: every read
//   is wrapped, every failure is non-fatal.
//
// ===========================================================================

private struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0)
    var pLimitData: (UInt16, UInt16, UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0, 0, 0)
    var keyInfo = SMCKeyData_keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum GPUSMC {
    private static var conn: io_connect_t = 0
    private static var opened = false

    static func open() -> Bool {
        if opened { return conn != 0 }
        opened = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        return r == KERN_SUCCESS
    }

    static func close() {
        if conn != 0 { IOServiceClose(conn) }
        conn = 0
        opened = false
    }

    /// Best-effort: returns an array of fan RPMs, or `nil` if the SMC read
    /// itself failed (so the UI can render "—" instead of plotting a fake 0).
    /// red-team: caller previously couldn't tell apart "silent fans" from
    /// "SMC unreadable" — both surfaced as `[]`.
    static func fanRPMs() -> [Int]? {
        guard open(), conn != 0 else { return nil }

        // FNum → number of fans (uint8). nil here means we couldn't even
        // ask the SMC; surface as nil, not empty.
        guard let count = readUInt8(key: "FNum") else { return nil }
        // count == 0 is a legitimate "this Mac has no fans" answer.
        guard count < 16 else { return nil }   // garbage value → treat as unreadable
        if count == 0 { return [] }

        var rpms: [Int] = []
        var anyReadFailed = false
        for i in 0..<Int(count) {
            // F<i>Ac → actual RPM, fp79 (16-bit fixed point, top 7 bits = whole)
            let key = "F\(i)Ac"
            if let raw = readFP79(key: key) {
                rpms.append(raw)
            } else {
                anyReadFailed = true
            }
        }
        // red-team: if every per-fan read failed but we did know fan-count,
        // that's "unreadable" not "all fans at 0".
        if rpms.isEmpty && anyReadFailed { return nil }
        return rpms
    }

    // ---- low-level helpers --------------------------------------------------

    private static func fourCharCode(_ s: String) -> UInt32 {
        var out: UInt32 = 0
        for ch in s.utf8.prefix(4) { out = (out << 8) | UInt32(ch) }
        return out
    }

    private static func call(_ input: SMCKeyData_t) -> SMCKeyData_t? {
        var input = input
        var output = SMCKeyData_t()
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        let r = IOConnectCallStructMethod(conn, 2 /* kSMCHandleYPCEvent */,
                                          &input, inputSize,
                                          &output, &outputSize)
        guard r == KERN_SUCCESS else { return nil }
        return output
    }

    private static func info(key: String) -> SMCKeyData_t? {
        var input = SMCKeyData_t()
        input.key = fourCharCode(key)
        input.data8 = 9 /* kSMCGetKeyInfo */
        return call(input)
    }

    private static func readUInt8(key: String) -> UInt8? {
        guard let i = info(key: key) else { return nil }
        var input = SMCKeyData_t()
        input.key = i.key
        input.keyInfo = i.keyInfo
        input.data8 = 5 /* kSMCReadKey */
        guard let out = call(input), out.result == 0 else { return nil }
        return out.bytes.0
    }

    /// fp79 = 9 fractional bits, 7 integer bits, big-endian
    private static func readFP79(key: String) -> Int? {
        guard let i = info(key: key) else { return nil }
        var input = SMCKeyData_t()
        input.key = i.key
        input.keyInfo = i.keyInfo
        input.data8 = 5
        guard let out = call(input), out.result == 0 else { return nil }
        let hi = UInt16(out.bytes.0)
        let lo = UInt16(out.bytes.1)
        let raw = (hi << 8) | lo
        let val = Double(raw) / Double(1 << 2)   // fpe2 = >>2, common for FxAc; both forms appear in the wild
        // Some firmwares store the value in fp79 (>>9). If we got something
        // wildly out of range, fall back to that interpretation.
        if val > 12000 || val < 0 {
            return Int(Double(raw) / Double(1 << 9))
        }
        return Int(val)
    }
}

// ===========================================================================
// MARK: - Power (IOPSCopyPowerSourcesInfo)
// ===========================================================================
//
//   Fix 16: replaced fork+exec of /usr/bin/pmset with IOPSCopyPowerSourcesInfo
//   (pure IPC, no fork). Pattern mirrors KeepAwakePowerWatcher in keep_awake.swift.
//   This removes a 5s throttle that was needed to amortise Process() cost.
//
// ===========================================================================
import IOKit.ps

enum GPUPower {
    struct Reading {
        var onAC: Bool
        var batteryPercent: Int?
        var acWatts: Double?   // nil if not exposed / not available via IOPS
        var raw: String        // kept for UI display; now shows source description
    }

    static func read() -> Reading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return Reading(onAC: true, batteryPercent: nil, acWatts: nil, raw: "IOPSCopyPowerSourcesInfo failed")
        }
        var onAC = true
        var pct: Int? = nil
        var rawParts: [String] = []
        for s in sources {
            guard let dict = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if let state = dict[kIOPSPowerSourceStateKey] as? String {
                onAC = (state != kIOPSBatteryPowerValue)
                rawParts.append(state)
            }
            if let cur = dict[kIOPSCurrentCapacityKey] as? Int,
               let max = dict[kIOPSMaxCapacityKey] as? Int, max > 0 {
                pct = Int((Double(cur) / Double(max)) * 100.0)
            }
        }
        return Reading(onAC: onAC, batteryPercent: pct, acWatts: nil, raw: rawParts.joined(separator: ", "))
    }
}

// ===========================================================================
// MARK: - Model / refresh loop
// ===========================================================================

@MainActor
final class GPUMonitorModel: ObservableObject {
    @Published var gpus: [GPUAccelerator] = []
    @Published var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    // red-team: nil = SMC couldn't be read (show "—"), [] = OK but no fans / 0
    // values reported, [v…] = real RPMs. Was previously [Int] which conflated
    // "unreadable" with "all fans silent at 0 RPM".
    @Published var fanRPMs: [Int]? = nil
    @Published var power: GPUPower.Reading = GPUPower.Reading(onAC: false, batteryPercent: nil, acWatts: nil, raw: "")
    @Published var samples: [GPUSample] = []          // rolling 60s
    @Published var paused: Bool = false
    @Published var interval: TimeInterval = 1.0
    @Published var floating: Bool = false
    @Published var compact: Bool = false
    @Published var alertsEnabled: Bool = false
    @Published var lastError: String? = nil

    // ---- experimental HID temperature sensors -------------------------------
    /// Toggle is persisted across launches. Default OFF so the private-API
    /// path is fully opt-in.
    @Published var experimentalSensors: Bool {
        didSet {
            UserDefaults.standard.set(experimentalSensors, forKey: Self.kExperimentalKey)
            if experimentalSensors { startHID() } else { stopHID() }
        }
    }
    /// Display unit for temperature readings. Stored °C internally; this
    /// only affects rendering. Persisted across launches.
    @Published var temperatureFahrenheit: Bool {
        didSet { UserDefaults.standard.set(temperatureFahrenheit, forKey: Self.kFahrenheitKey) }
    }
    private static let kExperimentalKey = "gpu.experimentalSensors"
    private static let kFahrenheitKey   = "gpu.tempFahrenheit"

    /// Format a stored-°C value in the user's chosen unit. One decimal place.
    func formatTemp(_ celsius: Double) -> String {
        if temperatureFahrenheit {
            return String(format: "%.1f °F", celsius * 9.0 / 5.0 + 32.0)
        }
        return String(format: "%.1f °C", celsius)
    }

    /// Convert a stored-°C value into whichever unit the sparkline should
    /// plot in. Sparkline uses raw doubles (no unit awareness), so callers
    /// hand it pre-converted points.
    func plotValue(_ celsius: Double) -> Double {
        temperatureFahrenheit ? (celsius * 9.0 / 5.0 + 32.0) : celsius
    }

    /// Fixed sparkline ceiling in the user's unit. 110 °C ≈ 230 °F covers
    /// any modern Mac's throttle territory without clipping in practice.
    var plotCeiling: Double { temperatureFahrenheit ? 230.0 : 110.0 }

    /// Rolling 60s of per-sensor readings. Newest at the end. Capped to
    /// `bufferCap` ticks regardless of how many sensors are present.
    @Published var sensorHistory: [[GPUSensorReading]] = []
    /// Most recent set of readings, for the "current value" badges.
    @Published var sensorLatest: [GPUSensorReading] = []
    /// True after at least one successful enumeration of HID services.
    /// False means headless / VM / locked-down → empty state.
    @Published var sensorsAvailable: Bool = false
    private let hid = GPUHIDSensors()

    private let bufferCap = 60
    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private let powerQueue = DispatchQueue(label: "trove.gpu.power")
    // Fix 16: pmsetTick removed — IOPSCopyPowerSourcesInfo is cheap enough to call every tick.

    init() {
        // red-team: read the persisted toggle BEFORE the property is observed,
        // otherwise the `didSet` would fire during init and try to start HID
        // before the rest of the model is ready. Direct UD read sidesteps that.
        self.experimentalSensors = UserDefaults.standard.bool(forKey: Self.kExperimentalKey)
        // Same pattern for the unit toggle — its didSet only writes back to UD,
        // which is idempotent, but the spurious write at init is still noise.
        self.temperatureFahrenheit = UserDefaults.standard.bool(forKey: Self.kFahrenheitKey)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.thermal = ProcessInfo.processInfo.thermalState
                self.refreshAlertIcon()
        }
        // NOTE: `start()` used to fire here, which triggered an immediate
        // synchronous `tick()` — and `tick()` does IOKit / IORegistry
        // traversal + `MTLCopyAllDevices()`, all of which is OK off-main but
        // accumulates main-thread time during @StateObject init. The view
        // now triggers `start()` from `.onAppear` so init returns instantly.
    }

    deinit {
        timer?.invalidate()
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
        // red-team: drop the .floating window level so a torn-down model
        // doesn't leave the user's window stuck above all others.
        if let w = pinnedWindow { w.level = .normal }
        GPUSMC.close()
        hid.close()
    }

    func start() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()    // immediate first sample
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Begin the experimental HID-sensor sampler. Idempotent — safe to call
    /// repeatedly. Piggybacks on the regular tick: each tick calls
    /// `hid.sampleAsync` which hops back to main with the latest readings.
    func startHID() {
        let opened = hid.openIfNeeded()
        if !opened {
            sensorsAvailable = false
            lastError = "Could not open IOHIDEventSystemClient — sensors unavailable on this host."
            return
        }
        sensorsAvailable = hid.hasServices
        if !sensorsAvailable {
            lastError = "No matching HID temperature services (headless / VM / locked-down macOS)."
        } else {
            lastError = nil
        }
        // Take one immediate sample so the UI shows something right away.
        hid.sampleAsync { [weak self] readings in
            guard let self = self else { return }
            self.sensorLatest = readings
            self.appendHistoryTick(readings)
        }
    }

    /// Stop the HID sampler. Releases the client + service array. Charts
    /// freeze on the last sample; new ticks won't add HID rows.
    func stopHID() {
        hid.close()
        // Clear the most-recent badges but keep the history so toggling
        // back ON doesn't lose the chart visually mid-session.
        sensorLatest = []
        sensorsAvailable = false
    }

    /// Append one HID tick to the rolling sensor history buffer. Capped at
    /// `bufferCap` ticks regardless of how many sensors are present.
    private func appendHistoryTick(_ readings: [GPUSensorReading]) {
        if readings.isEmpty { return }
        sensorHistory.append(readings)
        while sensorHistory.count > bufferCap {
            sensorHistory.removeFirst()
        }
    }

    /// Bucket the rolling HID history by role. Each role emits one row with
    /// a per-tick average across its sensors plus the latest value (computed
    /// from `sensorLatest` so the badge reflects "right now" rather than the
    /// last appended tick). Roles with no readings at all are dropped so a
    /// Mac with only CPU+PMU sensors doesn't render an empty "Battery" row.
    var tempChartRows: [GPUTempChartRow] {
        guard experimentalSensors, sensorsAvailable else { return [] }
        var byRole: [GPUSensorRole: [(t: Date, c: Double)]] = [:]
        for tick in sensorHistory {
            // red-team: a single tick may contain multiple sensors with the
            // same role (e.g. pcpu0/pcpu1/ecpu0). Average them so one role =
            // one point per tick — otherwise the series has N points per
            // tick and the sparkline x-axis is meaningless.
            var sums: [GPUSensorRole: (sum: Double, n: Int, t: Date)] = [:]
            for r in tick {
                var acc = sums[r.role] ?? (0, 0, r.t)
                acc.sum += r.celsius
                acc.n += 1
                sums[r.role] = acc
            }
            for (role, acc) in sums where acc.n > 0 {
                byRole[role, default: []].append((t: acc.t, c: acc.sum / Double(acc.n)))
            }
        }
        // Average same-role sensors in the latest snapshot to match what the
        // sparkline would plot at "now". Also collect underlying sensor
        // names so the row tooltip can show them — sorted+deduped so the
        // order is stable across ticks (sensor enumeration order is not).
        var latestSum: [GPUSensorRole: Double] = [:]
        var latestN: [GPUSensorRole: Int] = [:]
        var latestNames: [GPUSensorRole: Set<String>] = [:]
        for r in sensorLatest {
            latestSum[r.role, default: 0] += r.celsius
            latestN[r.role, default: 0] += 1
            latestNames[r.role, default: []].insert(r.name)
        }
        return GPUSensorRole.allCases.compactMap { role in
            let series = byRole[role] ?? []
            let cur: Double? = {
                guard let s = latestSum[role], let n = latestN[role], n > 0 else { return nil }
                return s / Double(n)
            }()
            if series.isEmpty && cur == nil { return nil }
            let names = (latestNames[role] ?? []).sorted()
            return GPUTempChartRow(id: role, role: role, series: series,
                                   currentC: cur, sensorNames: names)
        }
    }

    func togglePause() {
        paused.toggle()
        if paused { stop() } else { start() }
    }

    func setInterval(_ s: TimeInterval) {
        interval = s
        if !paused { start() }
    }

    func tick() {
        // GPU probe + thermal are cheap. Fix 16: IOPSCopyPowerSourcesInfo is
        // pure IPC (no fork), so power can be read every tick without throttling.
        let probed = GPUProbe.snapshot()
        let rpms: [Int]? = GPUSMC.fanRPMs()
        // Power read is cheap now — call directly on background queue.
        powerQueue.async { [weak self] in
            let r = GPUPower.read()
            Task { @MainActor [weak self] in self?.power = r }
        }

        self.gpus = probed
        self.fanRPMs = rpms
        self.thermal = ProcessInfo.processInfo.thermalState

        // Experimental HID sensors — fire-and-forget; result lands on main.
        if experimentalSensors {
            hid.sampleAsync { [weak self] readings in
                guard let self = self else { return }
                self.sensorLatest = readings
                self.appendHistoryTick(readings)
            }
        }

        var perGPU: [UInt64: (activity: Double, mem: Int64)] = [:]
        for g in probed {
            perGPU[g.id] = (g.gpuActivity ?? 0, g.inUseSystemMemory ?? 0)
        }
        let sample = GPUSample(
            t: Date(),
            perGPU: perGPU,
            thermal: thermal,
            fanRPMs: rpms,
            acWatts: power.acWatts,
            batteryPercent: power.batteryPercent,
            onAC: power.onAC
        )
        samples.append(sample)
        if samples.count > bufferCap { samples.removeFirst(samples.count - bufferCap) }
    }

    // ---- pin window ---------------------------------------------------------

    /// red-team: remember which specific NSWindow we toggled, keyed by ID, so
    /// closing the GPU window or opening a second Trove window doesn't
    /// leave a stray "floating" level on the wrong window. We also restore
    /// the level when floating is turned off only on the windows we touched
    /// — never globally rewrite levels on windows we don't own.
    private weak var pinnedWindow: NSWindow?

    func applyFloating(to window: NSWindow?) {
        guard let w = window else { return }
        if floating {
            // If a different window was previously pinned (user dragged the
            // GPU pane to a new window), un-pin the old one first.
            if let prev = pinnedWindow, prev !== w {
                prev.level = .normal
            }
            w.level = .floating
            pinnedWindow = w
        } else {
            // Only un-pin a window if it's the one *we* pinned. Don't smash
            // .normal onto a sibling Trove window the user pinned via some
            // other code path.
            if pinnedWindow === w || pinnedWindow == nil {
                w.level = .normal
            }
            pinnedWindow = nil
        }
    }

    // ---- menubar alert ------------------------------------------------------

    func setAlertsEnabled(_ on: Bool) {
        alertsEnabled = on
        if on {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "GPU thermal")
                statusItem = item
            }
            refreshAlertIcon()
        } else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
            statusItem = nil
        }
    }

    private func refreshAlertIcon() {
        guard alertsEnabled, let item = statusItem, let btn = item.button else { return }
        if thermal.gpuAlerting {
            btn.image = NSImage(systemSymbolName: "thermometer.high", accessibilityDescription: "Thermal pressure")
            btn.contentTintColor = .systemRed
            btn.toolTip = "Thermal pressure: \(thermal.gpuLabel)"
        } else {
            btn.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "GPU thermal")
            btn.contentTintColor = nil
            btn.toolTip = "Thermal pressure: \(thermal.gpuLabel)"
        }
    }

    // ---- export -------------------------------------------------------------

    func jsonSnapshot() -> String {
        struct GPUJson: Encodable {
            let name: String; let vendor: String; let totalVRAMBytes: Int64
            let deviceUtilPct: Double?; let rendererUtilPct: Double?; let activityPct: Double?
            let inUseSystemMemoryBytes: Int64?; let freeVRAMBytes: Int64?
        }
        struct SensorJson: Encodable {
            let name: String; let role: String; let celsius: Double
        }
        struct Snap: Encodable {
            let timestamp: String
            let thermal: String
            // red-team: nil → SMC unreadable (encodes as JSON null, distinct
            // from [] which is "no fans"). Don't lie to downstream tooling.
            let fanRPMs: [Int]?
            let acWatts: Double?
            let onAC: Bool
            let batteryPercent: Int?
            let gpus: [GPUJson]
            // Same distinction for sensors: nil = experimental path disabled
            // or unavailable on this host; [] = enabled but no readings yet.
            let sensors: [SensorJson]?
        }
        let iso = ISO8601DateFormatter()
        let sensorsOut: [SensorJson]? = {
            guard experimentalSensors, sensorsAvailable else { return nil }
            return sensorLatest.map {
                SensorJson(name: $0.name, role: $0.role.rawValue, celsius: $0.celsius)
            }
        }()
        let snap = Snap(
            timestamp: iso.string(from: Date()),
            thermal: thermal.gpuLabel,
            fanRPMs: fanRPMs,
            acWatts: power.acWatts,
            onAC: power.onAC,
            batteryPercent: power.batteryPercent,
            gpus: gpus.map {
                GPUJson(name: $0.name, vendor: $0.vendor, totalVRAMBytes: $0.totalVRAM,
                        deviceUtilPct: $0.deviceUtilization,
                        rendererUtilPct: $0.rendererUtilization,
                        activityPct: $0.gpuActivity,
                        inUseSystemMemoryBytes: $0.inUseSystemMemory,
                        freeVRAMBytes: $0.freeVRAM)
            },
            sensors: sensorsOut
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(snap), encoding: .utf8)) ?? "{}"
    }

    func copySnapshotJSON() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(jsonSnapshot(), forType: .string)
    }

    /// CSV of the rolling 60s buffer. One row per sample, columns include
    /// per-GPU activity + memory by name (sanitized).
    func csvOfBuffer() -> String {
        let gpuList = gpus
        var header = ["timestamp", "thermal", "fanRPMs", "onAC", "acWatts", "batteryPct"]
        for g in gpuList {
            let n = g.name.replacingOccurrences(of: ",", with: " ")
            header.append("\(n) activity%")
            header.append("\(n) inUseBytes")
        }
        var rows: [String] = [header.joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        for s in samples {
            var cols: [String] = []
            cols.append(iso.string(from: s.t))
            cols.append(s.thermal.gpuLabel)
            // red-team: encode "unreadable" as empty CSV cell, not "0".
            cols.append(s.fanRPMs.map { $0.map(String.init).joined(separator: "|") } ?? "")
            cols.append(s.onAC ? "1" : "0")
            cols.append(s.acWatts.map { String(format: "%.0f", $0) } ?? "")
            cols.append(s.batteryPercent.map(String.init) ?? "")
            for g in gpuList {
                if let entry = s.perGPU[g.id] {
                    cols.append(String(format: "%.2f", entry.activity))
                    cols.append(String(entry.mem))
                } else {
                    cols.append(""); cols.append("")
                }
            }
            rows.append(cols.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Save CSV next to the user's Desktop. Red-team #6: collision-safe
    /// suffix `(2)`, `(3)`… so back-to-back exports don't clobber each
    /// other when somebody's mid-benchmark.
    @discardableResult
    func exportCSV() -> URL? {
        let fm = FileManager.default
        let dir = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
        let stamp = DateFormatter()
        // red-team: avoid ":" in the date format — on HFS+ that's the path
        // separator and on APFS it round-trips to "/" in Finder. Use plain
        // digits, no punctuation that could land as a path delimiter.
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        // red-team-sec: sanitize the entire computed basename — guard against
        // unexpected formatter locales injecting "/" / ":" / control chars.
        // We *generate* the name, but defense-in-depth keeps a future caller
        // (e.g. user-pasted save-as) from sneaking ".." or path separators.
        let rawBase = "Trove GPU \(stamp.string(from: Date()))"
        let base = Self.sanitizeFilename(rawBase)
        var candidate = dir.appendingPathComponent("\(base).csv")
        // red-team-sec: defense-in-depth — ensure the resolved path is still
        // inside `dir`. URL.appendingPathComponent doesn't itself resolve "..",
        // but symlinks and the sanitize step above could in theory still let
        // an attacker-influenced base land outside; refuse if so.
        let resolvedDir = dir.standardizedFileURL.path
        if !candidate.standardizedFileURL.path.hasPrefix(resolvedDir) {
            lastError = "CSV export refused: unsafe path"
            return nil
        }
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n)).csv")
            n += 1
            if n > 99 { break }
        }
        do {
            // atomically:true uses write-to-temp + rename, which on macOS is
            // an atomic rename(2) within the same volume → safe against
            // half-written files if the app is SIGKILL'd mid-export.
            try csvOfBuffer().write(to: candidate, atomically: true, encoding: .utf8)
            return candidate
        } catch {
            lastError = "CSV export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// red-team-sec: strip path separators, NUL, and other control chars from
    /// a proposed filename. Also rejects leading "." (no hidden files) and
    /// any ".." component.
    private static func sanitizeFilename(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s.unicodeScalars {
            // No path separators, no colon (HFS legacy), no NUL, no controls.
            if ch == "/" || ch == ":" || ch == "\\" || ch.value < 0x20 {
                out.unicodeScalars.append("_")
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        // Collapse ".." -> "__" to neutralise traversal.
        out = out.replacingOccurrences(of: "..", with: "__")
        // Strip leading dots so we don't accidentally create a hidden file.
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { out = "Trove-Export" }
        // Cap to a sane length (HFS+ allows 255 UTF-16 units; be conservative).
        if out.count > 120 { out = String(out.prefix(120)) }
        return out
    }
}

// ===========================================================================
// MARK: - Sparkline (Reduce-Motion aware)
// ===========================================================================

struct GPUSparkline: View {
    let values: [Double]
    let tint: Color
    /// If nil, auto-scale to local max. Pass 100 for percentage metrics so
    /// "GPU running cool" doesn't get rescaled to look like a stress test.
    let maxValue: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let pts = values
            let n = max(pts.count, 2)
            let localMax = max(maxValue ?? (pts.max() ?? 1), 0.0001)
            if reduceMotion {
                // Discrete bars: no anti-aliased moving line, just static bins.
                let w = g.size.width
                let h = g.size.height
                let bw = max(w / CGFloat(n) - 1, 1)
                Path { p in
                    for (i, v) in pts.enumerated() {
                        let x = CGFloat(i) * (w / CGFloat(n))
                        let bh = CGFloat(min(v / localMax, 1.0)) * h
                        p.addRect(CGRect(x: x, y: h - bh, width: bw, height: bh))
                    }
                }
                .fill(tint.opacity(0.85))
            } else {
                Path { path in
                    guard !pts.isEmpty else { return }
                    let w = g.size.width
                    let h = g.size.height
                    let dx = w / CGFloat(n - 1)
                    for (i, v) in pts.enumerated() {
                        let x = CGFloat(i) * dx
                        let y = h - CGFloat(min(v / localMax, 1.0)) * h
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else      { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }
        }
        .frame(height: 28)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
        // Fix 17: accessibility for VoiceOver rotor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sparkline")
        .accessibilityValue(values.last.map { String(format: "%.0f%%", $0) } ?? "no data")
    }
}

// ===========================================================================
// MARK: - Per-GPU card
// ===========================================================================

struct GPUDeviceCard: View {
    let gpu: GPUAccelerator
    let history: [GPUSample]
    let compact: Bool

    var activitySeries: [Double] {
        history.compactMap { $0.perGPU[gpu.id]?.activity }
    }
    var memSeries: [Double] {
        history.compactMap { $0.perGPU[gpu.id].map { Double($0.mem) } }
    }
    var memPct: Double? {
        guard let used = gpu.inUseSystemMemory, gpu.totalVRAM > 0 else { return nil }
        return Double(used) / Double(gpu.totalVRAM) * 100.0
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gpu.name).headerText()
                        Text("\(gpu.vendor) • \(gpu.totalVRAM > 0 ? Int64(gpu.totalVRAM).human : "Unknown VRAM")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if gpu.isLowPower { GPUTag(text: "iGPU") }
                    if gpu.isHeadless { GPUTag(text: "Headless") }
                }

                if compact {
                    HStack(spacing: 14) {
                        GPUBigNumber(label: "Activity",
                                     value: gpu.gpuActivity.map { String(format: "%.0f%%", $0) } ?? "—",
                                     tint: .accentColor)
                        GPUBigNumber(label: "VRAM",
                                     value: gpu.inUseSystemMemory.map { Int64($0).human } ?? "—",
                                     tint: .blue)
                    }
                } else {
                    GPUMetricRow(label: "Device Utilization",
                                 value: gpu.deviceUtilization.map { String(format: "%.1f%%", $0) } ?? "—",
                                 series: history.compactMap { $0.perGPU[gpu.id]?.activity },
                                 tint: .accentColor, maxValue: 100)
                    GPUMetricRow(label: "Renderer Utilization",
                                 value: gpu.rendererUtilization.map { String(format: "%.1f%%", $0) } ?? "—",
                                 series: activitySeries,
                                 tint: .purple, maxValue: 100)
                    GPUMetricRow(label: "GPU Activity",
                                 value: gpu.gpuActivity.map { String(format: "%.1f%%", $0) } ?? "—",
                                 series: activitySeries,
                                 tint: .pink, maxValue: 100)
                    Divider()
                    GPUMetricRow(label: "VRAM In Use",
                                 value: vramText(),
                                 series: memSeries,
                                 tint: .blue,
                                 maxValue: gpu.totalVRAM > 0 ? Double(gpu.totalVRAM) : nil)
                    if let free = gpu.freeVRAM {
                        Text("Free VRAM: \(Int64(free).human)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func vramText() -> String {
        guard let used = gpu.inUseSystemMemory else { return "—" }
        if gpu.totalVRAM > 0, let pct = memPct {
            return "\(Int64(used).human) / \(Int64(gpu.totalVRAM).human)  (\(String(format: "%.0f%%", pct)))"
        }
        return Int64(used).human
    }
}

struct GPUMetricRow: View {
    let label: String
    let value: String
    let series: [Double]
    let tint: Color
    let maxValue: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .frame(width: 170, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .frame(width: 180, alignment: .leading)
            GPUSparkline(values: series, tint: tint, maxValue: maxValue)
                .frame(maxWidth: .infinity)
        }
    }
}

struct GPUBigNumber: View {
    let label: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).foregroundStyle(tint)
        }
    }
}

struct GPUTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

// ===========================================================================
// MARK: - System summary card (thermal, fans, power)
// ===========================================================================

struct GPUSystemCard: View {
    @ObservedObject var model: GPUMonitorModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(model.thermal.gpuTint)
                    Text("Thermal Pressure").headerText()
                    Spacer()
                    Text(model.thermal.gpuLabel)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(model.thermal.gpuTint)
                }
                if model.thermal.gpuAlerting {
                    Text("System is throttling. Heavy workloads will run at reduced clocks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fan RPM").font(.caption).foregroundStyle(.secondary)
                        // red-team: nil → unreadable ("—"); [] → known zero-fan
                        // hardware ("None"); non-empty → actual values. Never
                        // print "0 / 0" when SMC simply refused us.
                        Text(fanText(model.fanRPMs))
                            .font(.system(.body, design: .monospaced))
                            .help(fanTooltip(model.fanRPMs))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Power").font(.caption).foregroundStyle(.secondary)
                        Text(powerText())
                            .font(.system(.body, design: .monospaced))
                            .help("From `pmset -g batt`. CPU/GPU package power requires `powermetrics` + sudo; intentionally not used.")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery").font(.caption).foregroundStyle(.secondary)
                        Text(model.power.batteryPercent.map { "\($0)%" } ?? "—")
                            .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                }
            }
        }
    }

    private func powerText() -> String {
        if let w = model.power.acWatts { return "\(Int(w)) W (AC)" }
        if model.power.onAC { return "AC" }
        return "Battery"
    }

    // red-team: tri-state renderer for the fan-RPM cell so a failed SMC read
    // doesn't render as a misleading "0".
    private func fanText(_ rpms: [Int]?) -> String {
        guard let rpms = rpms else { return "—" }
        if rpms.isEmpty { return "None" }
        return rpms.map { "\($0)" }.joined(separator: "  /  ")
    }
    private func fanTooltip(_ rpms: [Int]?) -> String {
        guard let rpms = rpms else {
            return "Fan RPM not exposed by SMC (common on Apple Silicon without root)."
        }
        if rpms.isEmpty { return "This Mac reports zero fans (passive cooling)." }
        return "Per-fan RPM from SMC."
    }
}

// ===========================================================================
// MARK: - Temperature card (experimental HID sensors)
// ===========================================================================

/// Renders one row per role (CPU / GPU / Battery / SoC / Other) — never one
/// row per raw sensor. That's deliberate: a per-sensor wall is what iStat
/// Menus and Stats already do, and 30+ rows of "pcpu0_te / pcpu1_te / …"
/// names is overwhelming and useless without the schematic. Five buckets
/// answers the actual question ("is the GPU hot?") in one glance.
struct GPUTempCard: View {
    @ObservedObject var model: GPUMonitorModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(.pink)
                    Text("Temperatures").headerText()
                    Text("β")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Apple HID sensors")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !model.sensorsAvailable {
                    Text("No HID temperature services matched. Common on Hackintoshes, VMs, headless servers, or a macOS build that locked the private interface.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.tempChartRows.isEmpty {
                    // Briefly visible during the first tick after toggling on.
                    Text("Waiting for first sensor tick…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.tempChartRows) { row in
                        GPUTempRow(row: row, model: model)
                    }
                }
            }
        }
    }
}

struct GPUTempRow: View {
    let row: GPUTempChartRow
    @ObservedObject var model: GPUMonitorModel

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(row.role.tint).frame(width: 8, height: 8)
            Text(row.role.rawValue)
                .font(.subheadline)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(currentText)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .frame(width: 92, alignment: .leading)
                .foregroundStyle(tint(for: row.currentC))
            // Sparkline plots in the user's chosen unit so the y-axis ceiling
            // (110 °C / 230 °F) lines up with the numeric badge above. Tint
            // thresholds still live in °C since they're a physical property.
            GPUSparkline(values: row.series.map { model.plotValue($0.c) },
                         tint: row.role.tint,
                         maxValue: model.plotCeiling)
                .frame(maxWidth: .infinity)
        }
        .help(tooltip)
        // Fix 17: VoiceOver label for GPUTempRow so rotor reads "GPU temperature: 65°C".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.role.rawValue) temperature")
        .accessibilityValue(currentText)
    }

    private var currentText: String {
        guard let c = row.currentC else { return "—" }
        return model.formatTemp(c)
    }

    /// Mirror the thermal-pressure color ramp so a "GPU 92 °C" badge reads
    /// red without needing to look at the thermal-pressure card. Thresholds
    /// are in °C — temperature is a physical quantity, the toggle is just
    /// presentation.
    private func tint(for c: Double?) -> Color {
        guard let c = c else { return .secondary }
        switch c {
        case ..<60:  return .primary
        case ..<80:  return .yellow
        case ..<95:  return .orange
        default:     return .red
        }
    }

    private var tooltip: String {
        if row.sensorNames.isEmpty {
            return "\(row.role.rawValue): no sensors reporting this tick."
        }
        return "\(row.role.rawValue) sensors: " + row.sensorNames.joined(separator: ", ")
    }
}

// ===========================================================================
// MARK: - Toolbar / keyboard
// ===========================================================================

struct GPUMonitorToolbar: View {
    @ObservedObject var model: GPUMonitorModel
    let onExport: () -> Void
    let onCopyJSON: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.togglePause()
            } label: {
                Label(model.paused ? "Resume" : "Pause",
                      systemImage: model.paused ? "play.fill" : "pause.fill")
            }
            .help("r — Toggle live refresh")

            Picker("", selection: Binding(
                get: { model.interval },
                set: { model.setInterval($0) }
            )) {
                Text("1s").tag(TimeInterval(1))
                Text("2s").tag(TimeInterval(2))
                Text("5s").tag(TimeInterval(5))
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("1 / 2 / 5 — Sample interval")

            Toggle(isOn: $model.compact) {
                Label("Compact", systemImage: "rectangle.compress.vertical")
            }
            .toggleStyle(.button)
            .help("Hide sparklines, shrink to corner-widget size.")

            Toggle(isOn: Binding(
                get: { model.floating },
                set: { model.floating = $0 }
            )) {
                Label("Pin", systemImage: "pin.fill")
            }
            .toggleStyle(.button)
            .help("Keep this window above all others.")

            Toggle(isOn: Binding(
                get: { model.alertsEnabled },
                set: { model.setAlertsEnabled($0) }
            )) {
                Label("Alerts", systemImage: "bell.badge")
            }
            .toggleStyle(.button)
            .help("Flash a red menubar icon when thermal state ≥ Serious.")

            Toggle(isOn: $model.experimentalSensors) {
                Label("Sensors β", systemImage: "thermometer.medium")
            }
            .toggleStyle(.button)
            .help("Read °C from HID temperature sensors (private API). Off by default. Empty on Hackintoshes, VMs, and locked-down macOS.")

            // °C/°F picker is only meaningful while sensors are surfacing
            // temperatures — hide it when the feature is off so the toolbar
            // doesn't carry dead controls.
            if model.experimentalSensors {
                Picker("", selection: $model.temperatureFahrenheit) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 86)
                .help("Display unit for HID temperature readings.")
            }

            Spacer()

            Button { onCopyJSON() } label: {
                Label("Copy JSON", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("c", modifiers: [.command])
            .help("⌘C — Copy current snapshot as JSON")

            Button { onExport() } label: {
                Label("Export CSV", systemImage: "square.and.arrow.down")
            }
            .help("Save last 60 seconds as CSV (collision-safe).")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// ===========================================================================
// MARK: - Window-level chrome (pin)
// ===========================================================================

/// Standalone window pinner: doesn't depend on `SharedStore.stage`. The
/// pane spec called out "use NSWindow.level directly". We poll-once after
/// view install + react to the model's floating toggle.
struct GPUWindowPin: NSViewRepresentable {
    @ObservedObject var model: GPUMonitorModel
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.isMovableByWindowBackground = true
            model.applyFloating(to: v.window)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            model.applyFloating(to: v.window)
        }
    }
}

// ===========================================================================
// MARK: - Public View
// ===========================================================================

/// Drop this into the root nav anywhere; it owns its own model + timer.
public struct GPUMonitorView: View {
    @StateObject private var model = GPUMonitorModel()
    @State private var toast: String? = nil
    // Fix 15: gate flash animations on reduceMotion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            GPUMonitorToolbar(model: model,
                              onExport: exportCSV,
                              onCopyJSON: copyJSON)
            Divider()
            content
        }
        .background(GPUWindowPin(model: model))
        .background(keyboardCatcher)
        .overlay(alignment: .bottom) { toastView }
        .navigationTitle("GPU & Thermals")
        .onAppear { model.start(); if model.experimentalSensors { model.startHID() } }
        .onDisappear { model.stop(); if model.experimentalSensors { model.stopHID() } }
    }

    @ViewBuilder
    private var content: some View {
        if model.gpus.isEmpty {
            GPUEmptyState()
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    GPUSystemCard(model: model)
                    if model.experimentalSensors {
                        GPUTempCard(model: model)
                    }
                    ForEach(model.gpus) { g in
                        GPUDeviceCard(gpu: g, history: model.samples, compact: model.compact)
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                .padding(.bottom, 14)
                .transition(.opacity)
        }
    }

    /// Hidden view that owns keyboard shortcuts the toolbar buttons don't
    /// already cover (r / 1 / 2 / 5). Uses SwiftUI's command-key API so we
    /// don't have to plumb an NSEvent monitor.
    private var keyboardCatcher: some View {
        Group {
            Button("Pause") { model.togglePause() }
                .keyboardShortcut("r", modifiers: [])
            Button("1s") { model.setInterval(1) }.keyboardShortcut("1", modifiers: [])
            Button("2s") { model.setInterval(2) }.keyboardShortcut("2", modifiers: [])
            Button("5s") { model.setInterval(5) }.keyboardShortcut("5", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func copyJSON() {
        model.copySnapshotJSON()
        flash("Snapshot copied as JSON")
    }

    private func exportCSV() {
        if let url = model.exportCSV() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            flash("Saved \(url.lastPathComponent)")
        } else if let err = model.lastError {
            flash(err)
        }
    }

    private func flash(_ s: String) {
        // Fix 15: gate animation on reduceMotion preference.
        let anim: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
        let animOut: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.4)
        withAnimation(anim) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(animOut) { toast = nil }
        }
    }
}

struct GPUEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No accelerator visible")
                .headerText()
            Text("IOKit returned no `IOAccelerator` services on this host. This is normal on Hackintoshes, headless servers, or in heavily sandboxed environments. Thermal pressure and battery state are still polled.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
