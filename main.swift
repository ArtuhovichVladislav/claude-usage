import SwiftUI
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
    private var isLoading = false

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
    }

    /// The most loaded limit — shown in the menu bar.
    var top: Limit? { limits.max { $0.percent < $1.percent } }

    var label: String {
        guard let top else { return error == nil ? "–" : "!" }
        if let reset = top.shortReset { return "\(Int(top.percent))% · \(reset)" }
        return "\(Int(top.percent))%"
    }

    var symbol: String {
        let p = top?.percent ?? 0
        let step = p >= 90 ? 100 : p >= 60 ? 67 : p >= 40 ? 50 : p >= 15 ? 33 : 0
        return "gauge.with.dots.needle.\(step)percent"
    }

    /// Primary source is Claude Code's own cache in ~/.claude.json — no requests at all.
    /// The API is called only when that data is older than 10 min, at most every 5 min,
    /// and never during a 429 backoff pause.
    func refresh() {
        if let (usage, date) = readClaudeCodeCache(), date > (updated ?? .distantPast) {
            apply(usage, at: date)
        }
        let now = Date()
        if let updated, now.timeIntervalSince(updated) < 600 { return }
        if isLoading { return }
        if let pausedUntil, now < pausedUntil {
            error = pauseMessage(pausedUntil)
            return
        }
        if let lastFetch, now.timeIntervalSince(lastFetch) < 300 { return }
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
                Button(L("Refresh", "Обновить")) { store.refresh() }
                Button(L("Quit", "Выйти")) { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        // Fires every time the popover opens (onAppear may fire only once)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refresh()
        }
    }
}

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.symbol)
                Text(store.label)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
