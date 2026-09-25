import SwiftUI
import AppKit
import ContextOSCore

/// A logo to draw, and how to frame it.
struct Logo {
    var image: NSImage
    /// App icons bring their own squircle and margin; a favicon or logo file
    /// sits on a tile instead.
    var isAppIcon: Bool
}

/// Real logos for AI tools and projects, looked up once and kept small.
///
/// An AI tool's logo is the icon of its installed app — the Claude app for
/// Claude Code, OpenAI's app for Codex — read from the app itself, so nothing
/// is bundled or redrawn. A project's is the file it already uses as one (see
/// `ProjectLogo`). Every image is shrunk to a 72px thumbnail on the way in, so
/// the cache costs a few kilobytes however large the source was.
@MainActor
final class LogoStore: ObservableObject {

    static let shared = LogoStore()

    /// Bumped when a project search finishes, so badges waiting on it redraw.
    /// The cache itself is not published: agent icons are looked up while a
    /// view draws, and publishing from inside a view update is not allowed.
    @Published private(set) var revision = 0
    private var cache: [String: Logo] = [:]
    private var searched: Set<String> = []

    /// Installed apps that stand for each agent, by bundle id, best first.
    private static let agentApps: [String: [String]] = [
        "Claude Code": ["com.anthropic.claudefordesktop"],
        "Codex": ["com.openai.codex", "com.openai.chat"],
        "Gemini CLI": ["com.google.GeminiMacOS", "com.google.Gemini"],
        "Cursor": ["com.todesktop.230313mzl4w4u92"],
        "Windsurf": ["com.exafunction.windsurf"],
        "GitHub Copilot": ["com.github.GitHubClient"]
    ]

    /// App names to try when no bundle id matched.
    private static let agentAppNames: [String: [String]] = [
        "Claude Code": ["Claude"], "Codex": ["Codex", "ChatGPT"], "Gemini CLI": ["Gemini"],
        "Cursor": ["Cursor"], "Windsurf": ["Windsurf"], "AgentCat": ["AgentCat"],
        "Continue": ["Continue"], "Aider": ["Aider"]
    ]

    /// The icon of the app an agent ships as, when one is installed.
    func agent(_ name: String) -> Logo? {
        let key = "agent:" + name
        if let hit = cache[key] { return hit }
        guard !searched.contains(key) else { return nil }
        searched.insert(key)
        guard let app = Self.appURL(for: name) else { return nil }
        let logo = Logo(image: Self.thumbnail(NSWorkspace.shared.icon(forFile: app.path)), isAppIcon: true)
        cache[key] = logo
        return logo
    }

    /// The project's own logo. The first ask starts a search off the main
    /// thread and returns nil; the badge redraws when it lands.
    func project(_ path: String) -> Logo? {
        let key = "project:" + path
        if let hit = cache[key] { return hit }
        guard !searched.contains(key) else { return nil }
        searched.insert(key)
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                ProjectLogo.find(in: URL(fileURLWithPath: path))
            }.value
            guard let self, let found, let image = NSImage(contentsOf: found),
                  image.isValid, image.size.width > 0 else { return }
            self.cache[key] = Logo(image: Self.thumbnail(image),
                                   isAppIcon: found.pathExtension.lowercased() == "icns")
            self.revision += 1
        }
        return nil
    }

    /// Forget everything — the ↻ button, in case a logo was added or changed.
    func reset() {
        cache.removeAll()
        searched.removeAll()
        revision += 1
    }

    private static func appURL(for agent: String) -> URL? {
        for id in agentApps[agent] ?? [] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        for name in agentAppNames[agent] ?? [] {
            for folder in folders where FileManager.default.fileExists(atPath: "\(folder)/\(name).app") {
                return URL(fileURLWithPath: "\(folder)/\(name).app")
            }
        }
        return nil
    }

    /// Draw `image` aspect-fit into a square bitmap, dropping every larger
    /// representation an app icon or `.icns` carries.
    private static func thumbnail(_ image: NSImage, pixels: Int = 72) -> NSImage {
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return image }
        let side = CGFloat(pixels)
        let scale = min(side / image.size.width, side / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: side / 2, height: side / 2))
        out.addRepresentation(rep)
        return out
    }
}

/// A logo in a fixed square: an app icon as is, a logo file on a soft tile,
/// and — when there is no logo at all — a generic AI mark.
struct LogoBadge: View {
    enum Subject {
        case agent(String)
        /// A project, falling back to the logo of the AI that worked on it most.
        case project(path: String, mainAgent: String?)
    }

    let subject: Subject
    var side: CGFloat = 30
    @ObservedObject private var store = LogoStore.shared

    var body: some View {
        let logo = resolve()
        ZStack {
            if let logo, logo.isAppIcon {
                // An app icon's squircle fills ~80% of its canvas; draw the
                // canvas a little larger so the squircle itself is `side`.
                Image(nsImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side * 1.22, height: side * 1.22)
            } else if let logo {
                Image(nsImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side * 0.62, height: side * 0.62)
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: side * 0.3, style: .continuous))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: side * 0.3, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func resolve() -> Logo? {
        _ = store.revision
        switch subject {
        case .agent(let name):
            return store.agent(name)
        case .project(let path, let mainAgent):
            return store.project(path) ?? mainAgent.flatMap { store.agent($0) }
        }
    }
}
