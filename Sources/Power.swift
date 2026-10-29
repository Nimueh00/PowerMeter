import AppKit
import IOKit
import IOKit.ps
import Observation

// MARK: - Sensör okuma (IOKit / AppleSmartBattery, sudo gerekmez)

struct PowerReading {
    var date = Date()
    var externalConnected = false
    var isCharging = false
    var fullyCharged = false
    var batteryPercent = 0
    var adapterWatts: Int?
    var adapterVolts: Double?
    var adapterAmps: Double?
    var inputW = 0.0    // adaptörden sisteme giren güç
    var loadW = 0.0     // tüm sistemin anlık tüketimi
    var batteryW = 0.0  // + pile giden (şarj), − pilden çekilen
}

enum SmartBattery {
    // Servisi bir kez bul, her okumada yeniden aramaya gerek yok
    private static let service =
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    /// Bir okuma ~0.08 ms sürer; sadece gereken anahtarlar tek tek okunur.
    static func read() -> PowerReading? {
        guard service != IO_OBJECT_NULL else { return nil }

        func value(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // ioreg negatif değerleri 64-bit işaretsiz olarak saklayabiliyor
        func int(_ any: Any?) -> Int? {
            (any as? NSNumber).map { Int(Int64(bitPattern: $0.uint64Value)) }
        }

        var r = PowerReading()
        r.externalConnected = (value("ExternalConnected") as? Bool) ?? false
        r.isCharging = (value("IsCharging") as? Bool) ?? false
        r.fullyCharged = (value("FullyCharged") as? Bool) ?? false
        r.batteryPercent = int(value("CurrentCapacity")) ?? 0

        if r.externalConnected, let a = value("AdapterDetails") as? [String: Any] {
            r.adapterWatts = int(a["Watts"])
            r.adapterVolts = int(a["AdapterVoltage"]).map { Double($0) / 1000 }
            r.adapterAmps = int(a["Current"]).map { Double($0) / 1000 }
        }

        let mV = Double(int(value("Voltage")) ?? 0)
        let mA = Double(int(value("InstantAmperage")) ?? int(value("Amperage")) ?? 0)
        r.batteryW = mV * mA / 1_000_000

        if let t = value("PowerTelemetryData") as? [String: Any] {
            r.inputW = Double(int(t["SystemPowerIn"]) ?? 0) / 1000
            r.loadW = Double(int(t["SystemLoad"]) ?? 0) / 1000
        }
        if !r.externalConnected { r.inputW = 0 }
        // Telemetri yoksa ya da geçersizse: tüketim = giriş − pile giden
        if r.loadW <= 0 { r.loadW = max(0, r.inputW - r.batteryW) }
        return r
    }
}

// MARK: - Ölçüm ve ortalamalar

struct Sample: Identifiable {
    let date: Date
    let dt: Double      // bu örneğin temsil ettiği süre (zaman ağırlıklı ortalama için)
    let inputW: Double
    let loadW: Double
    var id: Date { date }
}

@MainActor @Observable
final class PowerMonitor {
    private(set) var current = PowerReading()
    private(set) var samples: [Sample] = []
    private(set) var loadEnergyJ = 0.0
    private(set) var inputEnergyJ = 0.0
    private(set) var sessionSeconds = 0.0
    @ObservationIgnored private var lastDate: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored var onUpdate: ((PowerReading) -> Void)?
    let historySeconds: TimeInterval = 600

    /// Panel açıkken saniyede bir, kapalıyken 3 sn'de bir, ekran uykudayken 15 sn'de bir okunur.
    /// Pil çipi değerleri zaten birkaç saniyede bir yeniliyor; daha sık okumak boşa uyanmak olur.
    /// Adaptör takılıp çıkarılması ayrıca bildirimle anında yakalanır.
    @ObservationIgnored var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            if panelOpen { tick() }
            schedule()
        }
    }
    @ObservationIgnored private var screensAsleep = false {
        didSet { if screensAsleep != oldValue { schedule() } }
    }
    private var interval: TimeInterval { panelOpen ? 1 : (screensAsleep ? 15 : 3) }

    func start() {
        // Güç kaynağı değişince (adaptör tak/çıkar vb.) beklemeden oku
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.tick() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        }
        // Sistem uykusu ortalamaya katılmasın
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastDate = nil }
        }
        tick()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Tolerans, macOS'un uyanmaları diğer işlerle birleştirmesine izin verir (enerji tasarrufu)
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let r = SmartBattery.read() else { return }
        var dt = 0.0
        if let last = lastDate {
            // App Nap vb. gecikmeler sayılır, ama uzun boşluklar (uyku) sayılmaz
            dt = min(r.date.timeIntervalSince(last), 60)
            loadEnergyJ += r.loadW * dt
            inputEnergyJ += r.inputW * dt
            sessionSeconds += dt
        }
        lastDate = r.date
        current = r
        samples.append(Sample(date: r.date, dt: dt, inputW: r.inputW, loadW: r.loadW))
        let cutoff = r.date.addingTimeInterval(-historySeconds)
        if let first = samples.first, first.date < cutoff,
           let i = samples.firstIndex(where: { $0.date >= cutoff }) {
            samples.removeFirst(i)
        }
        onUpdate?(r)
    }

    /// Zaman ağırlıklı ortalama (okuma aralığı değişse de doğru kalır).
    func average(_ key: KeyPath<Sample, Double>, last seconds: TimeInterval) -> Double? {
        let cutoff = Date().addingTimeInterval(-seconds)
        var sum = 0.0, total = 0.0
        for s in samples.reversed() {
            if s.date < cutoff { break }
            sum += s[keyPath: key] * s.dt
            total += s.dt
        }
        return total > 0 ? sum / total : nil
    }

    /// Grafik için 5 sn'lik dilimlere indirgenmiş veri (en fazla 120 nokta).
    func chartPoints() -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(120)
        var bucket = -1, n = 0.0, inSum = 0.0, loadSum = 0.0, date = Date()
        func flush() {
            if n > 0 { out.append(Sample(date: date, dt: 0, inputW: inSum / n, loadW: loadSum / n)) }
        }
        for s in samples {
            let b = Int(s.date.timeIntervalSinceReferenceDate / 5)
            if b != bucket { flush(); bucket = b; n = 0; inSum = 0; loadSum = 0; date = s.date }
            n += 1; inSum += s.inputW; loadSum += s.loadW
        }
        flush()
        return out
    }

    var sessionAvgLoad: Double? { sessionSeconds > 0 ? loadEnergyJ / sessionSeconds : nil }
    var sessionAvgInput: Double? { sessionSeconds > 0 ? inputEnergyJ / sessionSeconds : nil }

    func reset() {
        loadEnergyJ = 0
        inputEnergyJ = 0
        sessionSeconds = 0
        samples.removeAll()
        lastDate = nil
        tick()
    }
}

