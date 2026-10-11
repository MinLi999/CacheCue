import AppKit
import ServiceManagement
import SwiftUI
import CacheCueCore

/// Reads the snapshot folder and keeps the countdowns moving.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var summary: Summary
    private let directory = SnapshotStore.defaultDirectory
    private let defaults = UserDefaults.standard
    private var snapshots: [Snapshot] = []
    private var ticks = 0

    /// The session kept in view by choice; nil follows whichever did something last.
    private var pinned: String? {
        get { defaults.string(forKey: Preferences.pinnedSessionKey) }
        set { defaults.set(newValue, forKey: Preferences.pinnedSessionKey) }
    }

    func pin(_ sessionID: String?) {
        pinned = sessionID
        summary = Summary(snapshots: snapshots, now: Date(), pinned: sessionID)
    }

    init() {
        AppTheme.stored(UserDefaults.standard.string(forKey: Preferences.themeKey)).apply()
        SnapshotStore.prune(in: directory, now: Date())
        snapshots = SnapshotStore.load(from: directory)
        summary = Summary(
            snapshots: snapshots, now: Date(), pinned: UserDefaults.standard.string(forKey: Preferences.pinnedSessionKey))
        // .common keeps the countdown moving while the popover is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Every second the countdowns move; every other second the files are read again.
    private func refresh() {
        ticks += 1
        if ticks % 2 == 0 {
            snapshots = SnapshotStore.load(from: directory)
        }
        summary = Summary(snapshots: snapshots, now: Date(), pinned: pinned)
        // A pinned session that has gone quiet lets go by itself.
        if pinned != nil && !summary.isPinned {
            pinned = nil
        }
    }
}

struct UsageBarApp: App {
    @StateObject private var model = UsageModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(summary: model.summary, updater: updater, pin: model.pin)
                .background(Material.regular)
        } label: {
            Image(nsImage: MenuBarLabel.image(for: model.summary))
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        // `statusline` is what Claude Code's statusLine setting runs: session JSON on stdin,
        // one line out, and the session's snapshot left for the menu bar. No AppKit, no
        // window: it runs every few seconds.
        if arguments.dropFirst().first == "statusline" {
            let directory = SnapshotStore.defaultDirectory
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let sessionID = (try? JSONSerialization.jsonObject(with: input) as? [String: Any])?["session_id"] as? String
            let previous = sessionID.flatMap { SnapshotStore.read($0, in: directory) }
            let output = StatusLine.render(
                input: input, now: Date(), previous: previous,
                color: ProcessInfo.processInfo.environment["NO_COLOR"]?.isEmpty ?? true)
            if let snapshot = output.snapshot, snapshot != previous {
                // The menu bar going stale must not cost the terminal its line.
                try? SnapshotStore.write(snapshot, in: directory)
            }
            print(output.line)
            return
        }
        // `setup-statusline [--force]` does what the popover's Set up button does.
        if arguments.dropFirst().first == "setup-statusline" {
            if case .other(let command) = StatusLineSetup.state(), !arguments.contains("--force") {
                print("Another status line is configured:\n  \(command)\nRun again with --force to replace it.")
                exit(1)
            }
            do {
                try StatusLineSetup.install(executable: Bundle.main.executablePath ?? arguments[0])
                print("Status line set up in \(StatusLineSetup.defaultSettingsURL.path)")
            } catch {
                print("Setup failed: \(error.localizedDescription)")
                exit(1)
            }
            return
        }

        let summary = Summary(snapshots: SnapshotStore.load(from: SnapshotStore.defaultDirectory), now: Date())

        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        // `--lang <code>` picks the language for the two commands below; otherwise the
        // person's own choice stands.
        let language = Language.resolve(
            choice: value(after: "--lang") ?? UserDefaults.standard.string(forKey: Preferences.languageKey))

        // `--dump` prints the figures as text and exits: a check that needs no screen.
        if arguments.contains("--dump") {
            print(summary.titleText)
            for row in summary.rows(.of(language)) {
                print(row ?? "────")
            }
            return
        }
        // `--render-icon <file.png>` draws the app icon at 1024 points, for the build script.
        if let file = value(after: "--render-icon") {
            Render.writeIcon(to: URL(fileURLWithPath: file))
            return
        }
        // `--login-status` says whether macOS has this app down as a login item.
        if arguments.contains("--login-status") {
            switch SMAppService.mainApp.status {
            case .enabled: print("enabled")
            case .notRegistered: print("notRegistered")
            case .requiresApproval: print("requiresApproval")
            case .notFound: print("notFound")
            @unknown default: print("unknown")
            }
            return
        }
        // `--render <folder> [--dark] [--lang <code>] [--page guide|<lesson id>]` writes the
        // popover and the menu bar label as PNGs.
        if let folder = value(after: "--render") {
            let page: Page = value(after: "--page").map { $0 == "guide" ? .guide : .lesson($0) } ?? .dashboard
            Render.write(
                summary, to: URL(fileURLWithPath: folder), dark: arguments.contains("--dark"), language: language,
                page: page)
            return
        }
        // Anything else on the command line is a mistake, not a reason to open the app.
        if arguments.count > 1 {
            print("usage: CacheCue [statusline | setup-statusline [--force] | --dump | --render <folder> | --render-icon <file.png> | --login-status]")
            exit(64)
        }
        // One menu bar item is enough: a second launch leaves the first in place.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            return
        }
        UsageBarApp.main()
    }
}

/// Off-screen pictures of the two things the app draws, for looking at a design change
/// without opening the menu.
@MainActor
enum Render {
    static func write(_ summary: Summary, to folder: URL, dark: Bool, language: Language, page: Page) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApplication.shared.appearance = appearance
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var suffix = "\(language.rawValue)-\(dark ? "dark" : "light")"
        switch page {
        case .dashboard: break
        case .guide: suffix = "guide-" + suffix
        case .lesson(let id): suffix = "lesson-\(id)-" + suffix
        }

        appearance.performAsCurrentDrawingAppearance {
            let backdrop = dark ? Color(white: 0.16) : Color(white: 0.93)
            let popover = PopoverView(summary: summary, isPreview: true, previewLanguage: language, initialPage: page)
                .background(backdrop)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(16)
                .background(dark ? Color(white: 0.08) : Color(white: 0.80))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: popover)
            renderer.scale = 2
            save(renderer.nsImage, to: folder.appendingPathComponent("popover-\(suffix).png"))

            // The label on a strip the shade of a menu bar.
            let label = MenuBarLabel.image(for: summary)
            let strip = NSImage(size: NSSize(width: label.size.width + 24, height: 24), flipped: false) { rect in
                (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
                rect.fill()
                label.draw(in: NSRect(x: 12, y: 1, width: label.size.width, height: label.size.height))
                return true
            }
            save(strip, to: folder.appendingPathComponent("label-\(suffix).png"), scale: 4)
        }
    }

    /// The app icon: a terracotta crescent inside a faint corona, on a dark rounded tile.
    static func writeIcon(to url: URL) {
        let side: CGFloat = 1024
        let unit = side / 512
        let moon = Palette.terracottaLight
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let tile = NSBezierPath(
                roundedRect: rect.insetBy(dx: 32 * unit, dy: 32 * unit), xRadius: 104 * unit, yRadius: 104 * unit)
            NSColor(white: 0.08, alpha: 1).setFill()
            tile.fill()

            // The bite is cleared inside a layer of its own, so it cuts the moon and not the tile.
            if let context = NSGraphicsContext.current {
                let rects = Crescent.rects(in: side)
                context.saveGraphicsState()
                context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                moon.setFill()
                NSBezierPath(ovalIn: rects.moon).fill()
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: rects.bite).fill()
                context.cgContext.endTransparencyLayer()
                context.restoreGraphicsState()
            }

            let corona = NSBezierPath(ovalIn: rect.insetBy(dx: (256 - 175) * unit, dy: (256 - 175) * unit))
            corona.lineWidth = 14 * unit
            moon.withAlphaComponent(0.15).setStroke()
            corona.stroke()
            return true
        }
        save(icon, to: url)
    }

    private static func save(_ image: NSImage?, to url: URL, scale: CGFloat = 1) {
        guard let image else { return }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
