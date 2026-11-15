import AppKit
import Carbon.HIToolbox
import Vision

// MARK: - OCR

enum OcrError: Error, CustomStringConvertible {
    case unreadableImage(URL)
    case noText

    var description: String {
        switch self {
        case .unreadableImage(let url): "Could not read an image from \(url.path)"
        case .noText: "No text found in the screenshot"
        }
    }
}

/// Runs on-device Vision OCR over an image file and returns the text in reading order.
func recognizeText(in url: URL) throws -> String {
    guard let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { throw OcrError.unreadableImage(url) }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // Shortcut: English only. Add more locales here when needed.
    request.recognitionLanguages = ["en-US"]

    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

    // Vision's origin is bottom-left, so top-to-bottom means descending midY.
    // Lines within ~1% of the same height are treated as one visual row.
    let observations = (request.results ?? []).sorted { lhs, rhs in
        let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
        if abs(dy) > 0.01 { return dy > 0 }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
    guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
        throw OcrError.noText
    }
    return lines.joined(separator: "\n")
}

// MARK: - Screen capture

enum ScreenCapture {

    /// True when this app may record the screen; prompts the user on first call.
    static func hasPermission(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return prompt ? CGRequestScreenCaptureAccess() : false
    }

    /// Shows the system crosshair selection UI and returns the captured image,
    /// or nil when the user cancels with Escape.
    static func captureRegion() throws -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("copytext-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x no shutter sound, -o no shadow
        process.arguments = ["-i", "-x", "-o", url.path]
        try process.run()
        process.waitUntilExit()

        // screencapture exits 1 when the selection is cancelled.
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - App

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "CopyText"
        )

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Copy Text from Screen",
                action: #selector(copyTextFromScreen),
                keyEquivalent: "s"
            )
            .configured { $0.keyEquivalentModifierMask = [.command, .option] }
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit CopyText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        statusItem.menu = menu

        registerHotKey()

        if !ScreenCapture.hasPermission(prompt: true) {
            showPermissionAlert()
        }
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4354_5854), id: 1) // 'CTXT'
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installed = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, nil
        )
        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        // Registration fails when another app already owns ⌥⌘S. Say so instead of
        // leaving the user pressing a key that does nothing.
        if installed != noErr || registered != noErr {
            let alert = NSAlert()
            alert.messageText = "⌥⌘S is already taken"
            alert.informativeText = "Another app has registered the shortcut. "
                + "Use the menu bar icon → Copy Text from Screen instead."
            alert.alertStyle = .warning
            present(alert)
        }
    }

    @objc func copyTextFromScreen() {
        guard !isBusy else { return }

        guard ScreenCapture.hasPermission(prompt: false) else {
            NSSound(named: "Basso")?.play()
            showPermissionAlert()
            return
        }

        isBusy = true
        defer { isBusy = false }

        // nil means the user pressed Escape during selection.
        guard let screenshot = try? ScreenCapture.captureRegion() else { return }
        defer { try? FileManager.default.removeItem(at: screenshot) }

        do {
            let text = try recognizeText(in: screenshot)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            NSSound(named: "Tink")?.play()
        } catch {
            NSSound(named: "Basso")?.play()
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not read the screenshot"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        present(alert)
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "CopyText needs Screen Recording permission"
        alert.informativeText = """
            Enable CopyText under System Settings › Privacy & Security › Screen Recording, \
            then try again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if present(alert) == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    /// An accessory app is not frontmost, so an alert would otherwise open behind
    /// whatever the user is looking at.
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

private extension NSMenuItem {
    func configured(_ body: (NSMenuItem) -> Void) -> NSMenuItem {
        body(self)
        return self
    }
}

// Carbon calls this on the main thread; the app keeps one controller for the process lifetime.
nonisolated(unsafe) private weak var appController: AppController?

private let hotKeyEventHandler: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async { appController?.copyTextFromScreen() }
    return noErr
}

// MARK: - Entry point

// `--ocr <path>` prints the text for a file and exits; useful for scripting and testing.
let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--ocr"), arguments.count > flagIndex + 1 {
    let url = URL(fileURLWithPath: arguments[flagIndex + 1])
    do {
        print(try recognizeText(in: url))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let controller = AppController()
appController = controller
app.delegate = controller
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
