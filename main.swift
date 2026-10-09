import SwiftUI
import Combine
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Localization

/// Russian if it is the preferred language (system-wide or per-app), English otherwise.
private let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false

func L(_ en: String, _ ru: String) -> String { isRussian ? ru : en }

// MARK: - API model

struct UsageResponse: Decodable {
    let limits: [Limit]
    let spend: Spend?
}

struct Limit: Decodable, Identifiable {
    let kind: String
    let percent: Double
    let resets_at: String?
    let scope: Scope?

    struct Scope: Decodable {
        let model: Model?
        struct Model: Decodable { let display_name: String? }
    }

    var id: String { kind + (scope?.model?.display_name ?? "") }

    var title: String {
        switch kind {
        case "session": return L("5-hour limit", "Лимит на 5 часов")
        case "weekly_all": return L("Weekly · all models", "Неделя · все модели")
        default:
            if let name = scope?.model?.display_name { return L("Weekly · ", "Неделя · ") + name }
            return kind
        }
    }

    var resetDate: Date? { resets_at.flatMap(parseDate) }

    /// "3h", "6d", "45m"
    var shortReset: String? {
        guard let date = resetDate else { return nil }
        let sec = max(0, date.timeIntervalSinceNow)
        if sec < 3600 { return "\(Int(sec / 60))" + L("m", "м") }
        if sec < 86400 { return "\(Int(sec / 3600))" + L("h", "ч") }
        return "\(Int(sec / 86400))" + L("d", "д")
    }
}

struct Spend: Decodable {
    let used: Money?
    let limit: Money?
    let percent: Double?
    let enabled: Bool?

    struct Money: Decodable {
        let amount_minor: Int
        let currency: String
        let exponent: Int

        var formatted: String {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currency
            let value = Double(amount_minor) / pow(10, Double(exponent))
            return f.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
        }
    }
}

private func parseDate(_ s: String) -> Date? {
    // "2026-10-09T00:00:00.167859+00:00" — drop fractional seconds
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

// MARK: - Store

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Shows banners even while the popover is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var limits: [Limit] = []
    @Published var spend: Spend?
    @Published var error: String?
    @Published var updated: Date?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var timers: [Timer] = []
    @Published private(set) var isLoading = false

    // Persisted so that relaunching the app does not bypass throttling
    private let defaults = UserDefaults.standard
    private var lastFetch: Date? {
        get { defaults.object(forKey: "lastFetch") as? Date }
        set { defaults.set(newValue, forKey: "lastFetch") }
    }
    private var pausedUntil: Date? {
        get { defaults.object(forKey: "pausedUntil") as? Date }
        set { defaults.set(newValue, forKey: "pausedUntil") }
    }
    private var rateLimitStreak: Int {
        get { defaults.integer(forKey: "rateLimitStreak") }
        set { defaults.set(newValue, forKey: "rateLimitStreak") }
    }

    static let thresholds = [95, 80]

    init() {
        #if !SNAPSHOT // tools/snapshot.swift fills the store with sample data instead
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Show last known data right away
        if let data = defaults.data(forKey: "cache"),
           let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            limits = usage.limits
            spend = usage.spend
            updated = defaults.object(forKey: "cacheDate") as? Date
        }
        if let pausedUntil, pausedUntil > Date() { schedulePause(until: pausedUntil) }

        refresh()
        // Every minute: pick up Claude Code's cache and redraw "time until reset"
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.objectWillChange.send()
                }
            },
        ]
        #endif
    }

    /// The 5-hour limit — the only one shown in the menu bar (the weekly ones live in the
    /// popover), so the number there never silently switches to another limit.
    var session: Limit? { limits.first { $0.kind == "session" } }

    var label: String {
        guard let session else { return error == nil ? "–" : "!" }
        if let reset = session.shortReset { return "\(Int(session.percent))% · \(reset)" }
        return "\(Int(session.percent))%"
    }

    /// Ring + label, drawn as one template image so the two are centered on each other
    /// exactly (an SF Symbol next to the button title sat visibly off).
    var menuBarImage: NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let label = label
        let text = label as NSString
        let ring: CGFloat = 14, line: CGFloat = 2, gap: CGFloat = 5, height: CGFloat = 18
        let percent = min(session?.percent ?? 0, 100)
        let size = NSSize(width: ring + gap + ceil(text.size(withAttributes: attrs).width), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: ring / 2, y: height / 2)
            let radius = (ring - line) / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = line
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if percent > 0 { // clockwise from 12 o'clock
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * percent / 100, clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            // Put the middle of the cap height (digits) on the ring's center
            let baseline = (height - font.capHeight) / 2
            text.draw(at: NSPoint(x: ring + gap, y: baseline + font.descender), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude Usage " + label
        return image
    }

    /// Whether the Refresh button would actually make a request right now.
    var canRefresh: Bool {
        let blockedUntil = [updated?.addingTimeInterval(60), lastFetch?.addingTimeInterval(60), pausedUntil]
            .compactMap { $0 }.max()
        return !isLoading && (blockedUntil ?? .distantPast) <= Date()
    }

    /// Primary source is Claude Code's own cache in ~/.claude.json — no requests at all.
    /// The API is called only when that data is older than 5 min (1 min for the Refresh button),
    /// at most once per that interval, and never during a 429 backoff pause.
    func refresh(manual: Bool = false) {
        if let (usage, date) = readClaudeCodeCache(), date > (updated ?? .distantPast) {
            apply(usage, at: date)
        }
        let now = Date()
        let interval: TimeInterval = manual ? 60 : 300
        if let updated, now.timeIntervalSince(updated) < interval { return }
        if isLoading { return }
        if let pausedUntil, now < pausedUntil {
            error = pauseMessage(pausedUntil)
            return
        }
        if let lastFetch, now.timeIntervalSince(lastFetch) < interval { return }
        isLoading = true
        lastFetch = now
        Task {
            await load()
            isLoading = false
        }
    }

    private func apply(_ usage: UsageResponse, at date: Date) {
        limits = usage.limits
        spend = usage.spend
        updated = date
        error = nil
        notifyThresholds()
    }

    /// Claude Code stores the same /api/oauth/usage response in ~/.claude.json.
    private func readClaudeCodeCache() -> (UsageResponse, Date)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = json["cachedUsageUtilization"] as? [String: Any],
              let ms = cache["fetchedAtMs"] as? Double,
              let utilization = cache["utilization"],
              let utilData = try? JSONSerialization.data(withJSONObject: utilization),
              let usage = try? JSONDecoder().decode(UsageResponse.self, from: utilData)
        else { return nil }
        return (usage, Date(timeIntervalSince1970: ms / 1000))
    }

    private func pauseMessage(_ until: Date) -> String {
        L("Rate limited · retry at ", "Лимит запросов · повтор в ") + until.formatted(date: .omitted, time: .shortened)
    }

    private func schedulePause(until: Date) {
        error = pauseMessage(until)
        Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow + 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = L("Launch at login: ", "Автозапуск: ") + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func load() async {
        do {
            let token = try readToken()
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429 {
                // Exponential backoff: 5, 10, 20, 40, 60 min (server often sends Retry-After: 0)
                rateLimitStreak += 1
                let backoff = min(300 * pow(2, Double(rateLimitStreak - 1)), 3600)
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                let wait = max(backoff, retryAfter)
                let until = Date().addingTimeInterval(wait)
                pausedUntil = until
                schedulePause(until: until)
                return
            }
            guard code == 200 else {
                throw AppError(message: code == 401
                    ? L("Token expired — open Claude Code to refresh it",
                        "Токен истёк — запустите Claude Code, он обновит его")
                    : L("HTTP error ", "Ошибка HTTP ") + "\(code)")
            }
            let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
            defaults.set(data, forKey: "cache")
            defaults.set(Date(), forKey: "cacheDate")
            rateLimitStreak = 0
            apply(usage, at: Date())
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Notifies once per threshold per limit window; state survives restarts.
    private func notifyThresholds() {
        let key = "notified"
        var state = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        for limit in limits {
            guard let reset = limit.resetDate else { continue }
            let window = Int((reset.timeIntervalSince1970 / 60).rounded())
            let saved = state[limit.id]?.split(separator: ":").compactMap { Int($0) } ?? []
            let already = saved.count == 2 && saved[0] == window ? saved[1] : 0
            guard let hit = Self.thresholds.first(where: { limit.percent >= Double($0) }), hit > already
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Claude: \(limit.title) — \(Int(limit.percent))%"
            content.body = limit.shortReset.map { L("Resets in ", "Сброс через ") + $0 } ?? ""
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "\(limit.id)-\(hit)", content: content, trigger: nil))
            state[limit.id] = "\(window):\(hit)"
        }
        UserDefaults.standard.set(state, forKey: key)
    }

    /// Reads the OAuth token that Claude Code stores in the Keychain.
    private func readToken() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else {
            throw AppError(message: L("Claude Code token not found in Keychain — sign in to Claude Code",
                                     "Не найден токен Claude Code в Keychain — войдите в Claude Code"))
        }
        return token
    }
}

// MARK: - UI

struct UsageRow: View {
    let title: String
    let value: String
    let percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(percent >= 90 ? Color.red : percent >= 75 ? Color.orange : Color.blue)
                        .frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
                }
            }
            .frame(height: 6)
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("USAGE", "ИСПОЛЬЗОВАНИЕ"))
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if let error = store.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.limits) { limit in
                UsageRow(title: limit.title,
                         value: "\(Int(limit.percent))%" + (limit.shortReset.map { L(" · resets ", " · сброс через ") + $0 } ?? ""),
                         percent: limit.percent)
            }

            if let spend = store.spend, spend.enabled == true,
               let used = spend.used, let cap = spend.limit {
                UsageRow(title: L("Extra usage", "Доп. использование"),
                         value: "\(used.formatted) / \(cap.formatted)",
                         percent: spend.percent ?? 0)
            }

            Divider()

            Toggle(L("Launch at login", "Запускать при входе"), isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)

            HStack {
                if let updated = store.updated {
                    Text(L("Updated ", "Обновлено ") + updated.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Re-check every second so the button re-enables as soon as a request is allowed
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Button(L("Refresh", "Обновить")) { store.refresh(manual: true) }
                        .disabled(!store.canRefresh)
                }
                Button(L("Quit", "Выйти")) { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

#if !SNAPSHOT
@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// An AppKit status item instead of SwiftUI's MenuBarExtra: at login the item is created
/// before the displays are configured, after which MenuBarExtra's item stayed invisible
/// on an external monitor and its window opened in the top-left corner of the screen.
/// MenuBarExtra(isInserted:) can't recreate the item (it never comes back), this can.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var observers: [Any] = []
    private var recreateWork: DispatchWorkItem?
    private var drawnState: String? // what the button image currently shows

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: ContentView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        createStatusItem()
        observers.append(store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        })
        recreateStatusItem(after: 5) // in case the displays were still being set up at login
        for (center, name) in [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recreateStatusItem(after: 2) }
            })
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudeUsage" // keeps the position the user dragged it to
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        drawnState = nil
        updateButton()
    }

    /// Debounced: display changes arrive in bursts.
    private func recreateStatusItem(after delay: TimeInterval) {
        recreateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if popover.isShown { return recreateStatusItem(after: 2) }
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            createStatusItem()
        }
        recreateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Redraws only when the label or the ring would change: the store publishes much more
    /// often (loading flag, the minute tick, errors).
    private func updateButton() {
        let state = "\(store.label) \(store.session?.percent ?? 0)"
        guard state != drawnState, let button = statusItem?.button else { return }
        drawnState = state
        button.image = store.menuBarImage
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
#endif
