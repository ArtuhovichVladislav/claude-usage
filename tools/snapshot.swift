// Renders the README screenshot with sample data:
// swiftc -parse-as-library -D SNAPSHOT main.swift tools/snapshot.swift -o /tmp/snapshot && /tmp/snapshot screenshot.png
import SwiftUI
import AppKit

struct SnapshotView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Menu bar item
            HStack(spacing: 4) {
                Image(systemName: store.symbol)
                Text(store.label)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 28)
            .background(Color(white: 0.14))

            // Popover
            ContentView(store: store)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
        .frame(width: 360)
        .background(Color(white: 0.08))
    }
}

@main
struct Snapshot {
    @MainActor static func main() {
        _ = NSApplication.shared
        let now = Date()
        func reset(in seconds: TimeInterval) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
        }

        let store = Store()
        store.limits = [
            Limit(kind: "session", percent: 34, resets_at: reset(in: 2 * 3600 + 900), scope: nil),
            Limit(kind: "weekly_all", percent: 18, resets_at: reset(in: 4 * 86400 + 3600), scope: nil),
            Limit(kind: "weekly_scoped", percent: 27, resets_at: reset(in: 4 * 86400 + 3600),
                  scope: .init(model: .init(display_name: "Fable"))),
        ]
        store.spend = Spend(used: .init(amount_minor: 320, currency: "USD", exponent: 2),
                            limit: .init(amount_minor: 5000, currency: "USD", exponent: 2),
                            percent: 6.4, enabled: true)
        store.updated = now

        let host = NSHostingView(rootView: SnapshotView(store: store))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = CommandLine.arguments.first { $0.hasSuffix(".png") } ?? "screenshot.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("Wrote \(out) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
}
