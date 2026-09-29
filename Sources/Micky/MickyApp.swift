import AppKit
import Combine
import SwiftUI

private enum OverlayLayout {
    static let width: CGFloat = 160
    static let height: CGFloat = 64
}

@main
struct MickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MicMeterSettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let meter = MicrophoneMeter()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var meterItem: NSMenuItem!
    private var fallbackSettingsWindow: NSWindow?
    private var muteStateObservation: AnyCancellable?
    private var panelMoveObserver: NSObjectProtocol?
    private var verticalPositionObserver: NSObjectProtocol?
    private var overlayGeometryObserver: NSObjectProtocol?
    private var inputSelectionObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        makePanel()
        makeStatusItem()
        muteStateObservation = meter.$isMuted.sink { [weak self] isMuted in
            Task { @MainActor in
                self?.updateStatusItemIcon(isMuted: isMuted)
            }
        }
        meter.start()
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        meter.stop()
    }

    private func makePanel() {
        let view = MeterCapsule(meter: meter)
        let hostingView = NSHostingView(rootView: view)
        let size = overlayPanelSize()
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        positionPanel()

        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.savePanelPosition()
            }
        }
        verticalPositionObserver = NotificationCenter.default.addObserver(
            forName: .micMeterVerticalPositionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.positionPanel()
            }
        }
        overlayGeometryObserver = NotificationCenter.default.addObserver(
            forName: .micMeterOverlayGeometryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resizePanelForOverlaySettings()
            }
        }
        inputSelectionObserver = NotificationCenter.default.addObserver(
            forName: .micMeterInputSelectionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let uid = notification.object as? String ?? ""
            Task { @MainActor in
                self?.meter.selectInputDevice(uid: uid)
            }
        }
    }

    private func overlayPanelSize() -> NSSize {
        let scale = CGFloat(UserDefaults.standard.object(forKey: "overlayScale") as? Double ?? 1)
        return NSSize(width: OverlayLayout.width * scale, height: OverlayLayout.height * scale)
    }

    private func resizePanelForOverlaySettings() {
        let size = overlayPanelSize()
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        positionPanel()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let horizontal = CGFloat(UserDefaults.standard.object(forKey: "overlayHorizontalPosition") as? Double ?? 0.5)
        let vertical = CGFloat(UserDefaults.standard.object(forKey: "overlayVerticalPosition") as? Double ?? 0.02)
        let horizontalRange = max(0, frame.width - panel.frame.width)
        let verticalRange = max(0, frame.height - panel.frame.height - 18)
        panel.setFrameOrigin(NSPoint(
            x: frame.minX + horizontalRange * min(1, max(0, horizontal)),
            y: frame.minY + 18 + verticalRange * min(1, max(0, vertical))
        ))
    }

    private func savePanelPosition() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let horizontalRange = max(1, visibleFrame.width - panel.frame.width)
        let verticalRange = max(1, visibleFrame.height - panel.frame.height - 18)
        let horizontal = Double((panel.frame.minX - visibleFrame.minX) / horizontalRange)
        let vertical = Double((panel.frame.minY - visibleFrame.minY - 18) / verticalRange)
        UserDefaults.standard.set(min(1, max(0, horizontal)), forKey: "overlayHorizontalPosition")
        UserDefaults.standard.set(min(1, max(0, vertical)), forKey: "overlayVerticalPosition")
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.toolTip = "Micky"
        statusItem.isVisible = true
        updateStatusItemIcon(isMuted: meter.isMuted)

        let menu = NSMenu()
        meterItem = NSMenuItem(title: "Pause / Resume Meter", action: #selector(toggleMeter), keyEquivalent: "")
        meterItem.target = self
        menu.addItem(meterItem)

        let showItem = NSMenuItem(title: "Show Overlay", action: #selector(showOverlay), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Micky", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func toggleMeter() {
        if meter.isEnabled {
            meter.stop()
        } else {
            meter.start()
        }
    }

    private func updateStatusItemIcon(isMuted: Bool) {
        let image = MicMeterIcons.image(isMuted: isMuted)
        image.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = image
        statusItem.button?.image?.isTemplate = false
        statusItem.button?.toolTip = isMuted ? "Micky — Microphone muted" : "Micky — Microphone on"
    }

    @objc private func showOverlay() {
        panel.orderFrontRegardless()
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let openedSettingsScene = NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
        guard !openedSettingsScene else { return }

        if fallbackSettingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 535),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Micky Settings"
            window.contentView = NSHostingView(rootView: MicMeterSettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            fallbackSettingsWindow = window
        }
        fallbackSettingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private struct MicMeterSettingsView: View {
    @AppStorage("overlayBackgroundOpacity") private var backgroundOpacity = 0.58
    @AppStorage("overlayScale") private var overlayScale = 1.0
    @AppStorage("overlayHorizontalPosition") private var horizontalPosition = 0.5
    @AppStorage("overlayVerticalPosition") private var verticalPosition = 0.02
    @AppStorage("selectedMicrophoneUID") private var selectedMicrophoneUID = ""
    @State private var availableMicrophones: [MicrophoneInputDevice] = []

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input device", selection: $selectedMicrophoneUID) {
                    Text("System Default (\(MicrophoneMeter.systemDefaultInputName() ?? "Unavailable"))")
                        .tag("")

                    ForEach(availableMicrophones) { device in
                        Text(device.isSystemDefault ? "\(device.name) (System Default)" : device.name)
                            .tag(device.uid)
                    }

                    if !selectedMicrophoneUID.isEmpty,
                       !availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }) {
                        Text("Selected microphone unavailable")
                            .tag(selectedMicrophoneUID)
                    }
                }
                .onChange(of: selectedMicrophoneUID) { uid in
                    NotificationCenter.default.post(name: .micMeterInputSelectionChanged, object: uid)
                }

                HStack {
                    Spacer()
                    Button {
                        refreshMicrophoneList()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                Text("System Default follows the microphone selected in System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Overlay") {
                HStack {
                    Text("Background opacity")
                    Spacer()
                    Text("\(Int((backgroundOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $backgroundOpacity, in: 0.2...1.0)
                    .accessibilityLabel("Overlay background opacity")

                HStack {
                    Text("More transparent")
                    Spacer()
                    Text("More opaque")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("The change applies to the overlay immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Overlay size")
                    Spacer()
                    Text("\(Int((overlayScale * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $overlayScale, in: 0.65...1.8, step: 0.05)
                    .accessibilityLabel("Overlay size")
                    .onChange(of: overlayScale) { _ in
                        NotificationCenter.default.post(name: .micMeterOverlayGeometryChanged, object: nil)
                    }

                HStack {
                    Text("Smaller")
                    Spacer()
                    Text("Larger")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text("Horizontal position")
                    Spacer()
                    Text("\(Int((horizontalPosition * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $horizontalPosition, in: 0...1)
                    .accessibilityLabel("Overlay horizontal position")
                    .onChange(of: horizontalPosition) { _ in
                        NotificationCenter.default.post(name: .micMeterOverlayGeometryChanged, object: nil)
                    }

                HStack {
                    Text("Left")
                    Spacer()
                    Text("Right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text("Vertical position")
                    Spacer()
                    Text("\(Int((verticalPosition * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $verticalPosition, in: 0...1)
                    .accessibilityLabel("Overlay vertical position")
                    .onChange(of: verticalPosition) { _ in
                        NotificationCenter.default.post(name: .micMeterVerticalPositionChanged, object: nil)
                    }

                HStack {
                    Text("Bottom")
                    Spacer()
                    Text("Top")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Speech peak guide") {
                ForEach(SpeechLevelGuide.all) { guide in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(guide.color)
                            .frame(width: 9, height: 9)
                        Text(guide.label)
                        Spacer(minLength: 12)
                        Text(guide.range)
                            .font(.custom("SplineSansMono-Regular", size: 11, relativeTo: .caption))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Aim for peaks around −18 to −6 dBFS. Levels are a local guide; call apps may apply automatic gain control. Select System Default above to follow System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 430, height: 535)
        .onAppear(perform: refreshMicrophoneList)
        .onReceive(NotificationCenter.default.publisher(for: .micMeterInputDevicesChanged)) { _ in
            refreshMicrophoneList()
        }
    }

    private func refreshMicrophoneList() {
        availableMicrophones = MicrophoneMeter.availableInputDevices()
    }
}

extension Notification.Name {
    static let micMeterVerticalPositionChanged = Notification.Name("MicMeterVerticalPositionChanged")
    static let micMeterOverlayGeometryChanged = Notification.Name("MicMeterOverlayGeometryChanged")
    static let micMeterInputSelectionChanged = Notification.Name("MicMeterInputSelectionChanged")
    static let micMeterInputDevicesChanged = Notification.Name("MicMeterInputDevicesChanged")
}

private struct SpeechLevelGuide: Identifiable {
    let label: String
    let range: String
    let color: Color

    var id: String { label }

    static let all = [
        SpeechLevelGuide(label: "Too quiet", range: "Below −30 dBFS", color: Color(red: 0.40, green: 0.78, blue: 1.0)),
        SpeechLevelGuide(label: "Quiet", range: "−30 to −18 dBFS", color: Color(red: 0.30, green: 0.90, blue: 1.0)),
        SpeechLevelGuide(label: "Good call level", range: "−18 to −6 dBFS", color: Color(red: 0.45, green: 1.0, blue: 0.64)),
        SpeechLevelGuide(label: "Loud", range: "−6 to −1 dBFS", color: Color(red: 1.0, green: 0.75, blue: 0.32)),
        SpeechLevelGuide(label: "Near clipping", range: "−1 dBFS or higher", color: Color(red: 1.0, green: 0.43, blue: 0.40))
    ]
}

private struct MeterCapsule: View {
    @ObservedObject var meter: MicrophoneMeter
    @AppStorage("overlayBackgroundOpacity") private var backgroundOpacity = 0.58
    @AppStorage("overlayScale") private var overlayScale = 1.0
    @State private var isHovering = false
    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule()
                        .fill(segmentColor(at: index))
                        .frame(width: 4.5, height: barHeight(at: index))
                        .overlay(Capsule().strokeBorder(.black.opacity(0.75), lineWidth: 0.7))
                        .shadow(color: segmentColor(at: index).opacity(0.45), radius: 2)
                        .animation(.easeOut(duration: 0.09), value: meter.peakDBFS)
                }
            }
            .accessibilityHidden(true)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.6))
            .overlay {
                if isHovering {
                    Text("\(Int(meter.peakDBFS.rounded())) dBFS")
                        .font(.custom("SplineSansMono-Regular", size: 11, relativeTo: .caption))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.96), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.7))
                        .transition(.opacity)
                }
            }

        }
        .padding(.horizontal, 10)
        .frame(width: OverlayLayout.width, height: OverlayLayout.height)
        .background {
            if #available(macOS 26.0, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(.black.opacity(backgroundOpacity)))
                    .overlay(Capsule().fill(.black.opacity(backgroundOpacity)))
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(.black.opacity(backgroundOpacity)))
            }
        }
        .scaleEffect(CGFloat(overlayScale))
        .frame(width: OverlayLayout.width * CGFloat(overlayScale), height: OverlayLayout.height * CGFloat(overlayScale))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.isMuted ? "Microphone muted" : "Microphone on"). Peak \(Int(meter.peakDBFS.rounded())) dBFS. \(meter.levelDescription).")
    }

    private func barHeight(at index: Int) -> CGFloat {
        let shape: [CGFloat] = [0.22, 0.34, 0.50, 0.70, 0.90, 0.62, 0.42, 0.76, 1.0,
                                0.76, 0.42, 0.62, 0.90, 0.70, 0.50, 0.34, 0.22, 0.12]
        let input = CGFloat(max(0, min(1, (meter.peakDBFS + 48) / 48)))
        return 3 + shape[index] * (5 + input * 19)
    }

    private func segmentColor(at index: Int) -> Color {
        if meter.isMuted {
            return Color(red: 1.0, green: 0.28, blue: 0.30)
        }

        let isLit = meter.isRunning && index < meter.litSegmentCount
        let color: Color
        switch index {
        case 0...3:
            color = Color(red: 0.40, green: 0.78, blue: 1.0) // Too quiet
        case 4...7:
            color = Color(red: 0.30, green: 0.90, blue: 1.0) // Quiet
        case 8...11:
            color = Color(red: 0.45, green: 1.0, blue: 0.64) // Good call level
        case 12...16:
            color = Color(red: 1.0, green: 0.75, blue: 0.32) // Loud
        default:
            color = Color(red: 1.0, green: 0.43, blue: 0.40) // Near digital clipping
        }
        return color.opacity(isLit ? 1 : 0.58)
    }

}

private enum MicMeterIcons {
    private static let on = load(name: "mic-on", symbol: "mic.fill", description: "Microphone on")
    private static let off = load(name: "mic-off", symbol: "mic.slash.fill", description: "Microphone muted")

    static func image(isMuted: Bool) -> NSImage {
        isMuted ? off : on
    }

    private static func load(name: String, symbol: String, description: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        return NSImage(systemSymbolName: symbol, accessibilityDescription: description) ?? NSImage(size: NSSize(width: 18, height: 18))
    }
}
