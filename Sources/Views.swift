import Charts
import SwiftUI

// MARK: - Biçimlendirme

func watts(_ w: Double?) -> String {
    guard let w else { return "—" }
    return String(format: w < 10 ? "%.2f W" : "%.1f W", w)
}

func gb(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

func percent(_ x: Double?) -> String {
    guard let x else { return "—" }
    return "%\(Int((x * 100).rounded()))"
}

func duration(_ s: Double) -> String {
    let m = Int(s) / 60
    return m >= 60 ? "\(m / 60) sa \(m % 60) dk" : "\(m) dk"
}

// MARK: - Ortak parçalar

struct Card<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2.weight(.semibold))
                Text(title).font(.caption2.weight(.semibold)).textCase(.uppercase)
                Spacer(minLength: 4)
                accessory.font(.caption2)
            }
            .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct Bar: View {
    let value: Double   // 0...1
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct StackedBar: View {
    let segments: [(Double, Color)]   // her biri toplamın oranı

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle().fill(segments[i].1)
                        .frame(width: max(0, g.size.width * segments[i].0 - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
    }
}

func tempColor(_ t: Double?) -> Color {
    guard let t else { return .secondary }
    switch t {
    case ..<60: return .green
    case ..<80: return .yellow
    case ..<95: return .orange
    default: return .red
    }
}

// MARK: - Güç

struct PowerTile: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(watts(value)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct PowerCard: View {
    let power: PowerMonitor

    var body: some View {
        let r = power.current
        Card(title: "Güç", icon: "bolt.fill") {
            if r.externalConnected, let w = r.adapterWatts {
                Text(r.adapterVolts.map { String(format: "%d W adaptör · %.0f V", w, $0) } ?? "\(w) W adaptör")
            }
        } content: {
            HStack(spacing: 5) {
                PowerTile(title: "Giriş", value: r.inputW, color: .green)
                PowerTile(title: "Tüketim", value: r.loadW, color: .orange)
                PowerTile(title: r.batteryW >= 0 ? "Pile giden" : "Pilden", value: abs(r.batteryW), color: .blue)
            }

            Chart(power.chartPoints()) { s in
                LineMark(x: .value("Zaman", s.date), y: .value("W", s.inputW))
                    .foregroundStyle(by: .value("Seri", "Giriş"))
                LineMark(x: .value("Zaman", s.date), y: .value("W", s.loadW))
                    .foregroundStyle(by: .value("Seri", "Tüketim"))
            }
            .chartForegroundStyleScale(["Giriş": Color.green, "Tüketim": Color.orange])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) }
            .frame(height: 56)

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    Text("Ortalama tüketim").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                    Text("1 dk").foregroundStyle(.secondary)
                    Text("10 dk").foregroundStyle(.secondary)
                    Text(duration(power.sessionSeconds)).foregroundStyle(.secondary)
                }
                GridRow {
                    Text(String(format: "%.2f Wh harcandı", power.loadEnergyJ / 3600)).gridColumnAlignment(.leading)
                    Text(watts(power.average(\.loadW, last: 60)))
                    Text(watts(power.average(\.loadW, last: 600)))
                    Text(watts(power.sessionAvgLoad))
                }
            }
            .font(.caption2)
            .monospacedDigit()
        }
    }
}

// MARK: - Sıcaklık

struct TempGauge: View {
    let label: String
    let value: Double?

    var body: some View {
        VStack(spacing: 2) {
            Gauge(value: min(max(value ?? 20, 20), 110), in: 20...110) {
                EmptyView()
            } currentValueLabel: {
                Text(value.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
            .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
            .scaleEffect(0.82)
            .frame(width: 50, height: 50)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ThermalCard: View {
    let stats: SystemStats

    var thermalText: (String, Color) {
        switch stats.thermalState {
        case .nominal: return ("Normal", .green)
        case .fair: return ("Ilık", .yellow)
        case .serious: return ("Yavaşlatılıyor", .orange)
        case .critical: return ("Kritik", .red)
        @unknown default: return ("?", .secondary)
        }
    }

    var body: some View {
        let t = stats.temps
        Card(title: "Sıcaklık", icon: "thermometer.medium") {
            HStack(spacing: 4) {
                Circle().fill(thermalText.1).frame(width: 6, height: 6)
                Text(thermalText.0)
            }
        } content: {
            HStack(spacing: 0) {
                TempGauge(label: "CPU", value: t.cpu)
                TempGauge(label: stats.temps.gpu == nil ? "GPU (uykuda)" : "GPU", value: t.gpu)
                TempGauge(label: "SSD", value: t.ssd)
                TempGauge(label: "Pil", value: t.battery)
            }
            if let m = t.cpuMax {
                Text("En sıcak çekirdek: \(Int(m.rounded()))°C")
                    .font(.caption2).foregroundStyle(tempColor(m))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - İşlemci

struct CoreBars: View {
    let loads: [Double]
    let eCores: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(loads.indices, id: \.self) { i in
                let isE = i < eCores
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(isE ? Color.mint : Color.orange)
                            .frame(height: max(3, 34 * loads[i]))
                    }
                    .frame(width: 8, height: 34)
                    Text(isE ? "E" : "P").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
                if i == eCores - 1 { Spacer().frame(width: 4) }
            }
        }
    }
}

struct CPUCard: View {
    let stats: SystemStats

    var body: some View {
        Card(title: "İşlemci", icon: "cpu") {
            if !stats.cores.isEmpty {
                Text("\(stats.activeCores)/\(stats.cores.count) çekirdek aktif")
            }
        } content: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(percent(stats.cpuTotal))
                        .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    Group {
                        Text("Performans \(percent(stats.pLoad))").foregroundStyle(.orange)
                        Text("Verimlilik \(percent(stats.eLoad))").foregroundStyle(.mint)
                    }
                    .font(.caption2).monospacedDigit()
                }
                Spacer()
                if stats.cores.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    CoreBars(loads: stats.cores, eCores: stats.eCores)
                }
            }
        }
    }
}

// MARK: - GPU

struct GPUCard: View {
    let stats: SystemStats

    var body: some View {
        let g = stats.gpu
        Card(title: "GPU", icon: "square.stack.3d.up.fill") {
            if let c = g.coreCount { Text("\(c) çekirdek") }
        } content: {
            HStack(spacing: 10) {
                Text(percent(g.utilization))
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                Bar(value: g.utilization, color: .purple)
            }
        }
    }
}

// MARK: - Bellek

struct MemoryCard: View {
    let stats: SystemStats

    var pressure: (String, Color) {
        switch stats.memory.pressure {
        case 4: return ("Baskı: kritik", .red)
        case 2: return ("Baskı: yüksek", .yellow)
        default: return ("Baskı: normal", .green)
        }
    }

    var body: some View {
        let m = stats.memory
        let total = Double(max(m.total, 1))
        let gpuBytes = min(stats.gpu.inUseBytes, m.used)
        Card(title: "Bellek", icon: "memorychip") {
            HStack(spacing: 4) {
                Circle().fill(pressure.1).frame(width: 6, height: 6)
                Text(pressure.0)
            }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(gb(m.used)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                Text("/ \(gb(m.total)) kullanımda").font(.caption).foregroundStyle(.secondary)
            }
            StackedBar(segments: [
                (Double(m.app) / total, .blue),
                (Double(m.wired) / total, .orange),
                (Double(m.compressed) / total, .pink),
                (Double(m.cached) / total, Color.secondary.opacity(0.35)),
            ])
            Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    LegendItem(color: .blue, label: "Uygulamalar", value: gb(m.app))
                    LegendItem(color: .orange, label: "Sistem", value: gb(m.wired))
                }
                GridRow {
                    LegendItem(color: .pink, label: "Sıkıştırılmış", value: gb(m.compressed))
                    LegendItem(color: Color.secondary.opacity(0.35), label: "Önbellek", value: gb(m.cached))
                }
            }

            Divider().padding(.vertical, 1)

            // Birleşik bellek: GPU ayrı VRAM yerine aynı RAM'den pay alır
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CPU / GPU paylaşımı").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Swap \(gb(m.swapUsed))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                StackedBar(segments: [
                    (Double(m.used - gpuBytes) / total, .blue),
                    (Double(gpuBytes) / total, .purple),
                ])
                Grid(horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        LegendItem(color: .blue, label: "CPU tarafı", value: gb(m.used - gpuBytes))
                        LegendItem(color: .purple, label: "GPU (VRAM)", value: gb(gpuBytes))
                    }
                }
            }
        }
    }
}

// MARK: - Panel

/// Sistem kartları ayrı görünümde: `system.stats` sadece burada okunur,
/// böylece güç verisi değişince bu kartlar, sistem verisi değişince güç kartı yeniden çizilmez.
struct SystemCards: View {
    let system: SystemMonitor

    var body: some View {
        let stats = system.stats
        ThermalCard(stats: stats)
        CPUCard(stats: stats)
        GPUCard(stats: stats)
        MemoryCard(stats: stats)
    }
}

struct PanelView: View {
    let power: PowerMonitor
    let system: SystemMonitor

    var status: String {
        let r = power.current
        if !r.externalConnected { return "Pilde çalışıyor" }
        if r.batteryW < -0.3 { return "Prizde, ama adaptör yetmiyor: pil de devrede" }
        if r.fullyCharged { return "Tam dolu, adaptörden çalışıyor" }
        if r.isCharging { return "Şarj oluyor" }
        return "Prizde, şarj beklemede"
    }

    var batterySymbol: String {
        let p = power.current.batteryPercent
        if power.current.isCharging { return "battery.100percent.bolt" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PowerMeter").font(.headline)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol)
                    Text("%\(power.current.batteryPercent)").monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            PowerCard(power: power)
            SystemCards(system: system)
        }
        .padding(10)
        .frame(width: 320)
    }
}
