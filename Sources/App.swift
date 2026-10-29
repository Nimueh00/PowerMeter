import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Açılır panel (ekranın içinde kalacak şekilde konumlanır)

@MainActor
final class DropdownPanel {
    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let makeView: () -> PanelView
    // Görünüm sadece panel açıkken var; kapalıyken hiç çizim yapılmaz
    private var hosting: NSHostingView<PanelView>?
    private var anchorTop: CGFloat = 0
    private var buttonFrame: NSRect = .zero
    private var clickMonitor: Any?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    init(makeView: @escaping () -> PanelView) {
        self.makeView = makeView
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        onOpen?()
        buttonFrame = buttonWindow.frame
        let visible = screen.visibleFrame  // menü çubuğu hariç alan
        anchorTop = min(buttonFrame.minY, visible.maxY) - 6
        let hosting = NSHostingView(rootView: makeView())
        hosting.autoresizingMask = [.width, .height]
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        background.addSubview(hosting)
        self.hosting = hosting
        var x = buttonFrame.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        panel.setFrame(NSRect(x: x, y: max(visible.minY, anchorTop - size.height),
                              width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Simgenin kendisine tıklama: kapatmayı simgenin düğmesi yapar (yoksa hemen yeniden açılırdı)
                if self.buttonFrame.contains(NSEvent.mouseLocation) { return }
                self.close()
            }
        }
    }

    /// İçerik yüksekliği değişirse üst kenarı sabit tutarak boyutu güncelle.
    func relayout() {
        guard panel.isVisible, let hosting else { return }
        let size = hosting.fittingSize
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 else { return }
        frame.size.height = size.height
        frame.origin.y = anchorTop - size.height
        panel.setFrame(frame, display: true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        hosting?.removeFromSuperview()
        hosting = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        onClose?()
    }
}

// MARK: - Menü çubuğu

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lastTitle = ""
    private var lastConnected: Bool?
    private var smoothLoad: Double?
    private var smoothInput: Double?
    private let power = PowerMonitor()
    private let system = SystemMonitor()
    private lazy var dropdown = DropdownPanel { [unowned self] in
        PanelView(power: self.power, system: self.system)
    }

    static func main() {
        if CommandLine.arguments.contains("--dump") { dump(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Arayüzsüz test: sensör okumalarını terminale yazar.
    private static func dump() {
        let system = SystemMonitor()
        system.begin()
        Thread.sleep(forTimeInterval: 1)
        system.sample()
        let s = system.stats
        let t = s.temps
        print(String(format: "Sıcaklık  CPU %.1f (max %.1f)  GPU %.1f  SSD %.1f  Pil %.1f  durum %d",
                     t.cpu ?? -1, t.cpuMax ?? -1, t.gpu ?? -1, t.ssd ?? -1, t.battery ?? -1, s.thermalState.rawValue))
        print("CPU       toplam \(percent(s.cpuTotal))  P \(percent(s.pLoad))  E \(percent(s.eLoad))  aktif \(s.activeCores)/\(s.cores.count)")
        print("Çekirdek  " + s.cores.enumerated().map { "\($0.offset < s.eCores ? "E" : "P")\(Int($0.element * 100))" }.joined(separator: " "))
        print("GPU       \(percent(s.gpu.utilization))  kullanımda \(gb(s.gpu.inUseBytes))  ayrılmış \(gb(s.gpu.allocatedBytes))  çekirdek \(s.gpu.coreCount ?? -1)")
        let m = s.memory
        print("Bellek    kullanılan \(gb(m.used)) / \(gb(m.total))  uyg \(gb(m.app))  sistem \(gb(m.wired))  sıkış \(gb(m.compressed))  önbellek \(gb(m.cached))  swap \(gb(m.swapUsed))  baskı \(m.pressure)")
        if let r = SmartBattery.read() {
            print(String(format: "Güç      giriş %.1f W  tüketim %.1f W  pil %.1f W", r.inputW, r.loadW, r.batteryW))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Adaptörden giren ▸ Sistem tüketimi\nSağ tık: menü"
        }
        dropdown.onOpen = { [unowned self] in
            self.power.panelOpen = true   // okuma aralığı 1 sn'ye iner
            self.system.begin()
        }
        dropdown.onClose = { [unowned self] in
            self.power.panelOpen = false
        }
        power.onUpdate = { [weak self] r in
            guard let self else { return }
            self.updateTitle(r)
            // Sistem verileri (sıcaklık, CPU, GPU, bellek) sadece panel açıkken okunur
            if self.dropdown.isVisible {
                self.system.sample()
                DispatchQueue.main.async { self.dropdown.relayout() }
            }
        }
        power.start()
        enableLoginItemOnFirstRun()
    }

    // MARK: Menü çubuğu yazısı

    private func updateTitle(_ r: PowerReading) {
        guard let button = statusItem.button else { return }
        if r.externalConnected != lastConnected {
            lastConnected = r.externalConnected
            let symbol = r.externalConnected ? "powerplug.fill" : "battery.75percent"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            // Güç kaynağı değişti: eski değerlerden yumuşatma yapma, hemen yeni değeri göster
            smoothLoad = nil
            smoothInput = nil
        }
        // Üstel yumuşatma: anlık oynamalar yazıyı her okumada değiştirmesin (daha az yeniden çizim, titreme yok)
        func ema(_ old: Double?, _ new: Double) -> Double { old.map { $0 + 0.35 * (new - $0) } ?? new }
        let loadW = ema(smoothLoad, r.loadW), inputW = ema(smoothInput, r.inputW)
        smoothLoad = loadW
        smoothInput = inputW
        // Kısa biçim: "42 ▸ 15 W". Tam sayıya yuvarlamak menü çubuğunun daha seyrek yeniden çizilmesini sağlar.
        let load = loadW < 10 ? String(format: "%.1f", loadW) : String(format: "%.0f", loadW)
        let text = r.externalConnected
            ? String(format: "%.0f ▸ %@ W", inputW, load)
            : "\(load) W"
        guard text != lastTitle else { return }  // değişmediyse yeniden çizme
        lastTitle = text
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
    }

    // MARK: Tıklama: sol tık paneli açar/kapatır, sağ tık menüyü açar

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if dropdown.isVisible {
            dropdown.close()
        } else {
            dropdown.show(below: button)
        }
    }

    private func showMenu() {
        dropdown.close()
        let menu = NSMenu()
        menu.addItem(withTitle: "Paneli göster", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Ortalamaları sıfırla", action: #selector(resetAverages), keyEquivalent: "")
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Oturum açılışında başlat",
                                 action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Panel'den çık", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)  // menüyü simgenin altında aç
        statusItem.menu = nil                  // sol tık yine paneli açsın
    }

    @objc private func resetAverages() { power.reset() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Oturum açılışında başlatma

    private func enableLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        // Sadece Uygulamalar klasöründen çalışırken kaydet (derleme klasörü kayıt edilmesin)
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Panel: giriş öğesi eklenemedi: \(error)")
        }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSLog("Panel: giriş öğesi değiştirilemedi: \(error)")
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
