import SwiftUI
import Carbon.HIToolbox
import os.log

@main
struct BauApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var floatingWindow: FloatingWindow?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "AppDelegate")

    private var fokus: String {
        get { UserDefaults.standard.string(forKey: Constants.fokusKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Constants.fokusKey) }
    }

    private var windowPosition: CGPoint? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Constants.positionKey),
                  let point = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: data) else {
                return nil
            }
            return point.pointValue
        }
        set {
            if let point = newValue {
                let value = NSValue(point: point)
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: Constants.positionKey)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Constants.positionKey)
            }
        }
    }

    private enum Constants {
        static let bundleIdentifier = "org.coignard.Bau"
        static let fokusKey = "fokus"
        static let positionKey = "windowPosition"
        static let hotKeySignature: OSType = 0x42617521
        static let maxTextLength = 32
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application starting")
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()
        registerHotKeys()

        if !fokus.isEmpty {
            showFloatingWindow(resetPosition: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application terminating")
        unregisterHotKeys()
        floatingWindow?.close()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            logger.error("Failed to create status bar button")
            return
        }

        button.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Bau")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Text festlegen (⌘⇧↵)", action: #selector(showInputDialog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Löschen (⌘⇧⌫)", action: #selector(clearText), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func registerHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let eventHandler: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            guard let userData = userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else { return status }

            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            DispatchQueue.main.async {
                switch hotKeyID.id {
                case 1: delegate.showInputDialog()
                case 2: delegate.clearText()
                default: break
                }
            }

            return noErr
        }

        var eventHandlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            logger.error("Failed to install event handler: \(installStatus)")
            return
        }

        registerHotKey(id: 1, keyCode: UInt32(kVK_Return))
        registerHotKey(id: 2, keyCode: UInt32(kVK_Delete))
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Constants.hotKeySignature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            hotKeyRefs.append(hotKeyRef)
            logger.info("Hot key \(id) registered successfully")
        } else {
            logger.error("Failed to register hot key \(id): \(status)")
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs {
            if let ref = hotKeyRef {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
    }

    @objc func showInputDialog() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Fokus eingeben"
        alert.informativeText = "Dieser Text wird über dem Dock angezeigt"

        let input = LimitedTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24), maxLength: Constants.maxTextLength)
        input.stringValue = fokus
        input.placeholderString = "Lokführer in Deutsche Bahn werden"
        input.maximumNumberOfLines = 1

        alert.accessoryView = input
        alert.addButton(withTitle: "Los geht’s")
        let cancelButton = alert.addButton(withTitle: "Abbrechen")
        cancelButton.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = input

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                let previousFokus = self.fokus
                self.fokus = text
                self.logger.debug("Fokus set: \(self.fokus)")

                if previousFokus == self.fokus && self.floatingWindow != nil {
                    return
                }

                self.showFloatingWindow(resetPosition: false)
            } else {
                self.clearText()
            }
        }
    }

    private func showFloatingWindow(resetPosition: Bool = false) {
        let savedPosition = resetPosition ? nil : windowPosition
        floatingWindow?.close()

        guard let screen = NSScreen.main else {
            logger.error("No main screen available")
            return
        }

        floatingWindow = FloatingWindow(text: fokus, screen: screen, initialPosition: savedPosition)
        floatingWindow?.onPositionChange = { [weak self] position in
            self?.windowPosition = position
        }
        floatingWindow?.show()
    }

    @objc func clearText() {
        logger.debug("Clearing fokus")
        fokus = ""
        windowPosition = nil
        floatingWindow?.close()
        floatingWindow = nil
    }

    @objc func quit() {
        logger.info("Application quitting")
        NSApplication.shared.terminate(nil)
    }
}

class LimitedTextField: NSTextField {
    var maxLength: Int

    init(frame: NSRect, maxLength: Int) {
        self.maxLength = maxLength
        super.init(frame: frame)
        self.delegate = self
    }

    required init?(coder: NSCoder) {
        self.maxLength = 200
        super.init(coder: coder)
        self.delegate = self
    }
}

extension LimitedTextField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if let textField = obj.object as? NSTextField {
            if textField.stringValue.count > maxLength {
                textField.stringValue = String(textField.stringValue.prefix(maxLength))
            }
        }
    }
}

class FloatingWindow {
    private var window: NSPanel?
    private let text: String
    private var contentView: FloatingContentView?
    private var spaceChangeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "org.coignard.Bau", category: "FloatingWindow")
    var onPositionChange: ((CGPoint) -> Void)?

    init(text: String, screen: NSScreen, initialPosition: CGPoint? = nil) {
        self.text = text
        setupWindow(on: screen, initialPosition: initialPosition)
    }

    deinit {
        if let observer = spaceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupWindow(on screen: NSScreen, initialPosition: CGPoint? = nil) {
        contentView = FloatingContentView(text: text)

        guard let contentView = contentView else {
            logger.error("Failed to create content view")
            return
        }

        contentView.wantsLayer = true

        let size = contentView.fittingSize
        guard size.width > 0 && size.height > 0 else {
            logger.error("Invalid content view size")
            return
        }

        let screenFrame = screen.visibleFrame
        let origin: CGPoint

        if let savedPosition = initialPosition {
            origin = savedPosition
        } else {
            origin = CGPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.minY + 60
            )
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        window = panel

        contentView.onPositionChange = { [weak self, weak panel] in
            if let origin = panel?.frame.origin {
                self?.onPositionChange?(origin)
            }
        }

        spaceChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak panel] _ in
            panel?.orderFront(nil)
        }
    }

    func show() {
        window?.orderFront(nil)
        logger.debug("Floating window shown")
    }

    func close() {
        if let observer = spaceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            spaceChangeObserver = nil
        }
        window?.orderOut(nil)
        window = nil
        logger.debug("Floating window closed")
    }
}

class FloatingContentView: NSView {
    private let text: String
    private var label: NSTextField?
    private var initialMouseOffset: NSPoint?
    private let logger = Logger(subsystem: "org.coignard.Bau", category: "FloatingContentView")
    var onPositionChange: (() -> Void)?

    private enum Layout {
        static let cornerRadius: CGFloat = 12
        static let padding: CGFloat = 32
        static let height: CGFloat = 50
        static let fontSize: CGFloat = 14
        static let maxWidth: CGFloat = 800
        static let stripeHeight: CGFloat = 8
        static let stripeWidth: CGFloat = 18
        static let stripeGap: CGFloat = 18
        static let backgroundColorHex = "#FACA00"
    }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not implemented")
    }

    private func setupView() {
        wantsLayer = true
        guard let layer = layer else { return }

        layer.cornerRadius = Layout.cornerRadius
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor(hex: Layout.backgroundColorHex)?.cgColor ?? NSColor.yellow.cgColor
        layer.masksToBounds = true

        let attrString = createAttributedString()
        label = NSTextField(labelWithAttributedString: attrString)
        guard let label = label else { return }

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()

        let textWidth = label.frame.width
        let stripeWidth = Layout.stripeWidth
        let stripeHeight = Layout.stripeHeight
        let stripeGap = Layout.stripeGap

        let offset = stripeHeight
        let patternStep = stripeWidth + stripeGap

        let minContentWidth = textWidth + (Layout.padding * 2)
        let requiredContentWidthForSymmetry = minContentWidth + offset - stripeWidth
        let numStripes = ceil(requiredContentWidthForSymmetry / patternStep)

        let lastStripeX = -offset + (numStripes - 1) * patternStep
        let finalWidth = lastStripeX + stripeWidth

        frame = NSRect(x: 0, y: 0, width: min(finalWidth, Layout.maxWidth), height: Layout.height)

        label.frame = NSRect(
            x: (frame.width - textWidth) / 2,
            y: (frame.height - label.frame.height) / 2,
            width: textWidth,
            height: label.frame.height
        )

        let stripesLayer = createStripesLayer(for: frame.size)
        layer.addSublayer(stripesLayer)

        addSubview(label)

        setAccessibilityLabel("Fokus auf: \(text)")
        setAccessibilityRole(.staticText)
    }

    private func createAttributedString() -> NSAttributedString {
        let attrString = NSMutableAttributedString()
        let prefixFont = NSFont.systemFont(ofSize: Layout.fontSize, weight: .regular)
        attrString.append(NSAttributedString(
            string: "Fokus auf: ",
            attributes: [.font: prefixFont, .foregroundColor: NSColor.black]
        ))

        let textFont = NSFont.systemFont(ofSize: Layout.fontSize, weight: .semibold)
        attrString.append(NSAttributedString(
            string: text,
            attributes: [.font: textFont, .foregroundColor: NSColor.black]
        ))

        return attrString
    }

    private func createStripesLayer(for size: NSSize) -> CALayer {
        let stripesLayer = CAShapeLayer()
        let path = CGMutablePath()

        let stripeHeight = Layout.stripeHeight
        let stripeWidth = Layout.stripeWidth
        let fullPatternWidth = stripeWidth + Layout.stripeGap
        let offset = stripeHeight

        var currentX: CGFloat = -offset
        while currentX < size.width + offset {
            path.move(to: CGPoint(x: currentX, y: size.height - stripeHeight))
            path.addLine(to: CGPoint(x: currentX + stripeWidth, y: size.height - stripeHeight))
            path.addLine(to: CGPoint(x: currentX + stripeWidth + offset, y: size.height))
            path.addLine(to: CGPoint(x: currentX + offset, y: size.height))
            path.closeSubpath()

            path.move(to: CGPoint(x: currentX, y: 0))
            path.addLine(to: CGPoint(x: currentX + stripeWidth, y: 0))
            path.addLine(to: CGPoint(x: currentX + stripeWidth + offset, y: stripeHeight))
            path.addLine(to: CGPoint(x: currentX + offset, y: stripeHeight))
            path.closeSubpath()

            currentX += fullPatternWidth
        }

        stripesLayer.path = path
        stripesLayer.fillColor = NSColor.black.cgColor
        return stripesLayer
    }

    override var fittingSize: NSSize {
        return frame.size
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window,
              let initialMouseOffset = initialMouseOffset else {
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        var newOrigin = NSPoint(
            x: currentMouseLocation.x - initialMouseOffset.x,
            y: currentMouseLocation.y - initialMouseOffset.y
        )

        if let screen = window.screen {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame

            newOrigin.x = max(screenFrame.minX, min(newOrigin.x, screenFrame.maxX - windowFrame.width))
            newOrigin.y = max(screenFrame.minY, min(newOrigin.y, screenFrame.maxY - windowFrame.height))
        }

        window.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseOffset = nil
        onPositionChange?()
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let r, g, b, a: CGFloat
        var start: String.Index

        if hex.hasPrefix("#") {
            start = hex.index(hex.startIndex, offsetBy: 1)
        } else {
            start = hex.startIndex
        }

        let hexColor = String(hex[start...])

        if hexColor.count == 6 {
            let scanner = Scanner(string: hexColor)
            var hexNumber: UInt64 = 0

            if scanner.scanHexInt64(&hexNumber) {
                r = CGFloat((hexNumber & 0xff0000) >> 16) / 255
                g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255
                b = CGFloat(hexNumber & 0x0000ff) / 255
                a = 1.0

                self.init(red: r, green: g, blue: b, alpha: a)
                return
            }
        }
        return nil
    }
}
