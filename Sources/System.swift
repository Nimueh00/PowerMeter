import Darwin
import Foundation
import IOKit
import Observation

// Bu dosyadaki okuyucular sadece panel açıkken çalışır; kapalıyken hiçbiri çağrılmaz.

// MARK: - SMC (sıcaklıklar, sudo gerekmez)

private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
// C'deki yapıyla birebir aynı boyut (80 bayt) için dolgu alanı gerekli
private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfoData] = [:]
    private static let fltType = code("flt ")

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func name(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(v >> $0 & 0xff) }, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    /// Anahtar bilgisi önbelleğe alınır. Olmayan anahtarlar da boş bilgiyle kaydedilir,
    /// böylece her okumada boşuna yeniden sorulmaz.
    private func info(_ k: UInt32) -> SMCKeyInfoData {
        if let cached = infoCache[k] { return cached }
        var q = SMCKeyData()
        q.key = k
        q.data8 = 9
        let info = call(&q)?.keyInfo ?? SMCKeyInfoData()
        infoCache[k] = info
        return info
    }

    /// Anahtar var ve sıcaklık biçiminde mi? (Değeri o an 0 olabilir: örn. boştaki GPU kapalıdır.)
    func hasTemperature(_ key: String) -> Bool {
        let i = info(SMC.code(key))
        return i.dataSize == 4 && i.dataType == SMC.fltType
    }

    /// Bir sıcaklık anahtarını °C olarak okur. Anahtar bilgisi önbellekte olduğundan tek çağrıdır.
    func temperature(_ key: String) -> Double? {
        let k = SMC.code(key)
        let info = info(k)
        guard info.dataSize == 4, info.dataType == SMC.fltType else { return nil }
        var q = SMCKeyData()
        q.key = k
        q.keyInfo.dataSize = 4
        q.data8 = 5
        guard let r = call(&q) else { return nil }
        var bytes = r.bytes
        let v = withUnsafeBytes(of: &bytes) { $0.load(as: Float.self) }
        return v > 1 && v < 150 ? Double(v) : nil
    }

    /// Tüm anahtarları tarar (~50 ms). Sadece bilinen anahtarlar bulunamazsa, bir kez kullanılır.
    func keys(withPrefix prefix: String) -> [String] {
        var q = SMCKeyData()
        q.key = SMC.code("#KEY")
        q.keyInfo.dataSize = 4
        q.data8 = 5
        guard let r = call(&q) else { return [] }
        let count = Int(UInt32(r.bytes.0) << 24 | UInt32(r.bytes.1) << 16 | UInt32(r.bytes.2) << 8 | UInt32(r.bytes.3))
        var out: [String] = []
        for i in 0..<count {
            var e = SMCKeyData()
            e.data8 = 8
            e.data32 = UInt32(i)
            if let r = call(&e) {
                let n = SMC.name(r.key)
                if n.hasPrefix(prefix) { out.append(n) }
            }
        }
        return out
    }
}

struct Temperatures {
    var cpu: Double?
    var cpuMax: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
}

final class ThermalSensors {
    private let smc: SMC?
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    init() {
        let smc = SMC()
        // M4 için bilinen çekirdek sensörleri; bulunamazsa önek taramasına düşülür.
        // Bulunan anahtarlar saklanır, tarama (~50 ms) sonraki açılışlarda tekrarlanmaz.
        func pick(_ known: [String], prefixes: [String], cacheKey: String) -> [String] {
            guard let smc else { return [] }
            let defaults = UserDefaults.standard
            for candidates in [defaults.stringArray(forKey: cacheKey) ?? [], known] {
                let found = candidates.filter { smc.hasTemperature($0) }
                if !found.isEmpty { return found }
            }
            let scanned = prefixes.flatMap { smc.keys(withPrefix: $0) }.filter { smc.hasTemperature($0) }
            if !scanned.isEmpty { defaults.set(scanned, forKey: cacheKey) }
            return scanned
        }
        cpuKeys = pick(["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                       prefixes: ["Tp", "Te"], cacheKey: "smcCPUKeys")
        gpuKeys = pick(["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
                       prefixes: ["Tg"], cacheKey: "smcGPUKeys")
        self.smc = smc
    }

    func read() -> Temperatures {
        guard let smc else { return Temperatures() }
        let cpu = cpuKeys.compactMap { smc.temperature($0) }
        let gpu = gpuKeys.compactMap { smc.temperature($0) }
        func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        return Temperatures(cpu: avg(cpu), cpuMax: cpu.max(), gpu: avg(gpu),
                            ssd: smc.temperature("TH0x"), battery: smc.temperature("TB0T"))
    }
}

// MARK: - CPU çekirdek kullanımı

final class CPULoadReader {
    private let host = mach_host_self()
    private var previous: [UInt32]?

    func reset() { previous = nil }

    /// Çekirdek başına 0...1 kullanım. İlk çağrıda karşılaştıracak örnek olmadığından nil döner.
    func read() -> [Double]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previous = ticks }
        guard let prev = previous, prev.count == ticks.count else { return nil }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { c in
            func d(_ state: Int32) -> Double { Double(ticks[c * stride + Int(state)] &- prev[c * stride + Int(state)]) }
            let busy = d(CPU_STATE_USER) + d(CPU_STATE_SYSTEM) + d(CPU_STATE_NICE)
            let total = busy + d(CPU_STATE_IDLE)
            return total > 0 ? busy / total : 0
        }
    }
}

// MARK: - GPU

struct GPUStats {
    var utilization = 0.0     // 0...1
    var inUseBytes: UInt64 = 0
    var allocatedBytes: UInt64 = 0
    var coreCount: Int?
}

enum GPUReader {
    private static let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
    private static let coreCount: Int? = {
        (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.intValue
    }()

    static func read() -> GPUStats? {
        guard service != IO_OBJECT_NULL,
              let ps = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return nil }
        func u64(_ k: String) -> UInt64 { (ps[k] as? NSNumber)?.uint64Value ?? 0 }
        return GPUStats(utilization: Double(u64("Device Utilization %")) / 100,
                        inUseBytes: u64("In use system memory"),
                        allocatedBytes: u64("Alloc system memory"),
                        coreCount: coreCount)
    }
}

// MARK: - Bellek (Etkinlik Monitörü ile aynı hesap)

struct MemoryStats {
    var total: UInt64 = 0
    var app: UInt64 = 0         // uygulamaların belleği
    var wired: UInt64 = 0       // sistemin sabitlediği bellek
    var compressed: UInt64 = 0
    var cached: UInt64 = 0      // dosya önbelleği (gerektiğinde boşaltılır)
    var swapUsed: UInt64 = 0
    var pressure = 1            // 1 normal, 2 uyarı, 4 kritik
    var used: UInt64 { app + wired + compressed }
}

enum MemoryReader {
    private static let host = mach_host_self()
    private static let total: UInt64 = {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &size, nil, 0)
        return v
    }()

    static func read() -> MemoryStats? {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        var m = MemoryStats()
        m.total = total
        // İşaretsiz çıkarma: purgeable internal'ı aşarsa taşmasın, 0'da kalsın
        let internalPages = UInt64(s.internal_page_count), purgeable = UInt64(s.purgeable_count)
        m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        m.wired = UInt64(s.wire_count) * page
        m.compressed = UInt64(s.compressor_page_count) * page
        m.cached = (UInt64(s.external_page_count) + UInt64(s.purgeable_count)) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = swap.xsu_used }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressure = Int(level) }
        return m
    }
}

// MARK: - Toplu sistem durumu

struct SystemStats {
    var temps = Temperatures()
    var cores: [Double] = []          // önce verimlilik (E), sonra performans (P) çekirdekleri
    var eCores = 0
    var pCores = 0
    var gpu = GPUStats()
    var memory = MemoryStats()
    var thermalState = ProcessInfo.ThermalState.nominal

    var cpuTotal: Double? { cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count) }
    var activeCores: Int { cores.filter { $0 > 0.15 }.count }
    var eLoad: Double? { eCores > 0 && cores.count >= eCores ? cores.prefix(eCores).reduce(0, +) / Double(eCores) : nil }
    var pLoad: Double? { pCores > 0 && cores.count >= eCores + pCores ? cores.suffix(pCores).reduce(0, +) / Double(pCores) : nil }
}

@MainActor @Observable
final class SystemMonitor {
    private(set) var stats = SystemStats()
    @ObservationIgnored private lazy var thermal = ThermalSensors()   // SMC ilk açılışta bağlanır
    @ObservationIgnored private let cpu = CPULoadReader()

    init() {
        func perf(_ level: Int) -> Int {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.perflevel\(level).physicalcpu", &v, &size, nil, 0) == 0 ? Int(v) : 0
        }
        stats.pCores = perf(0)
        stats.eCores = perf(1)
    }

    /// Panel açılınca çağrılır: CPU sayaçlarını sıfırlar ve hemen bir okuma yapar.
    func begin() {
        cpu.reset()
        sample()
    }

    func sample() {
        var s = stats
        s.temps = thermal.read()
        if let loads = cpu.read() { s.cores = loads }
        if let g = GPUReader.read() { s.gpu = g }
        if let m = MemoryReader.read() { s.memory = m }
        s.thermalState = ProcessInfo.processInfo.thermalState
        stats = s
    }
}
