//
//  ContentView.swift
//  jarvis
//
//  Created by Arnav Sharma on 7/1/26.
//

import SwiftUI
import Combine
import Foundation
import Speech
import AVFoundation
import EventKit
import UniformTypeIdentifiers
import Charts
import UserNotifications
import AppIntents
#if canImport(AppKit)
import AppKit
import IOKit.ps
import ScreenCaptureKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Theme
enum Theme {
    static let accent  = Color(red: 0.62, green: 0.45, blue: 1.0)   // violet
    static let accent2 = Color(red: 1.0, green: 0.35, blue: 0.75)   // magenta
    static let good    = Color(red: 0.45, green: 1.0, blue: 0.8)    // mint
}

// MARK: - Message model
struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    let isUser: Bool
    var date = Date()
    var imageData: Data? = nil
}

// MARK: - Nutrition tracker (Cal-AI-style, local)
struct FoodEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var name: String
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
}

class NutritionStore: ObservableObject {
    static let shared = NutritionStore()

    @Published var entries: [FoodEntry] = []
    @Published var goal: Double {
        didSet { UserDefaults.standard.set(goal, forKey: "jarvis_cal_goal") }
    }

    @Published var waterLog: [String: Double] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(waterLog) {
                UserDefaults.standard.set(data, forKey: "jarvis_water")
            }
        }
    }

    init() {
        goal = UserDefaults.standard.double(forKey: "jarvis_cal_goal")
        if goal <= 0 { goal = 2200 }
        if let data = UserDefaults.standard.data(forKey: "jarvis_food_log"),
           let saved = try? JSONDecoder().decode([FoodEntry].self, from: data) {
            entries = saved
        }
        if let data = UserDefaults.standard.data(forKey: "jarvis_water"),
           let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
            waterLog = saved
        }
    }

    private var todayKey: String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
    var todayWater: Double { waterLog[todayKey] ?? 0 }
    func addWater(_ oz: Double) { waterLog[todayKey] = todayWater + oz }

    /// Calories per day for the last 7 days, oldest first.
    var last7Days: [(day: String, kcal: Double)] {
        let df = DateFormatter(); df.dateFormat = "E"
        return (0..<7).reversed().map { offset in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            let total = entries.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                .reduce(0) { $0 + $1.calories }
            return (df.string(from: day), total)
        }
    }

    var todayEntries: [FoodEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }
    var todayCalories: Double { todayEntries.reduce(0) { $0 + $1.calories } }
    var todayProtein: Double { todayEntries.reduce(0) { $0 + $1.protein } }
    var todayCarbs: Double { todayEntries.reduce(0) { $0 + $1.carbs } }
    var todayFat: Double { todayEntries.reduce(0) { $0 + $1.fat } }

    func add(_ entry: FoodEntry) {
        entries.append(entry)
        persist()
    }

    func delete(_ entry: FoodEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func summary() -> String {
        let head = "Today so far: \(Int(todayCalories)) of \(Int(goal)) kcal — \(Int(todayProtein))g protein, \(Int(todayCarbs))g carbs, \(Int(todayFat))g fat."
        if todayEntries.isEmpty { return "Nothing logged today. Daily goal: \(Int(goal)) kcal." }
        let lines = todayEntries.map { "• \($0.name): \(Int($0.calories)) kcal (P\(Int($0.protein)) C\(Int($0.carbs)) F\(Int($0.fat)))" }
        return ([head] + lines).joined(separator: "\n")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries.suffix(500)) {
            UserDefaults.standard.set(data, forKey: "jarvis_food_log")
        }
    }
}

// MARK: - Calendar service (Apple Calendar incl. synced Google Calendar)
class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func upcoming(days: Int) async -> String {
        guard await requestAccess() else {
            return "Calendar access was denied. Sir, please allow it in System Settings → Privacy & Security → Calendars. If your Google Calendar isn't on this Mac yet, add your Google account under System Settings → Internet Accounts."
        }
        let span = max(1, min(days, 60))
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: span, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(25)
        if events.isEmpty { return "No calendar events in the next \(span) day(s)." }
        let df = DateFormatter(); df.dateFormat = "EEE MMM d, h:mm a"
        return events.map { e in
            let cal = e.calendar?.title ?? ""
            let when = e.isAllDay ? (e.startDate.formatted(date: .abbreviated, time: .omitted) + " (all day)") : df.string(from: e.startDate)
            return "• \(when) — \(e.title ?? "Untitled")\(cal.isEmpty ? "" : " [\(cal)]")"
        }.joined(separator: "\n")
    }

    func createEvent(title: String, start: String, durationMinutes: Double) async -> String {
        guard await requestAccess() else {
            return "Calendar access was denied, sir. Allow it in System Settings → Privacy & Security → Calendars."
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var date = df.date(from: start)
        if date == nil {
            let iso = ISO8601DateFormatter()
            date = iso.date(from: start)
        }
        guard let date else {
            return "I couldn't parse the start time '\(start)'. It must be formatted like 2026-07-02 15:30."
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(max(5, durationMinutes) * 60)
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return "Added '\(title)' to the calendar for \(date.formatted(date: .abbreviated, time: .shortened)) (\(Int(durationMinutes)) min)."
        } catch {
            return "Couldn't save the event: \(error.localizedDescription)"
        }
    }

    // MARK: Reminders
    private func remindersAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    private func parseDateTime(_ s: String) -> Date? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = df.date(from: s) { return d }
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    func addReminder(title: String, due: String) async -> String {
        guard await remindersAccess() else {
            return "Reminders access was denied, sir. Allow it in System Settings → Privacy & Security → Reminders."
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        var dueText = ""
        if !due.isEmpty, let date = parseDateTime(due) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
            dueText = " due \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        do {
            try store.save(reminder, commit: true)
            return "Reminder added: '\(title)'\(dueText). It will sync to all your Apple devices."
        } catch {
            return "Couldn't save the reminder: \(error.localizedDescription)"
        }
    }

    func pendingReminders() async -> String {
        guard await remindersAccess() else {
            return "Reminders access was denied, sir. Allow it in System Settings → Privacy & Security → Reminders."
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        if reminders.isEmpty { return "No pending reminders, sir. A clean slate." }
        let df = DateFormatter(); df.dateFormat = "EEE MMM d, h:mm a"
        return reminders.prefix(15).map { r in
            var line = "• \(r.title ?? "Untitled")"
            if let comps = r.dueDateComponents, let date = Calendar.current.date(from: comps) {
                line += " (due \(df.string(from: date)))"
            }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - Schoology service (two-legged OAuth 1.0a)
final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SchoologyService {
    static func authHeader(key: String, secret: String) -> String {
        let nonce = UUID().uuidString
        let ts = String(Int(Date().timeIntervalSince1970))
        return "OAuth realm=\"Schoology API\", oauth_consumer_key=\"\(key)\", oauth_token=\"\", oauth_nonce=\"\(nonce)\", oauth_timestamp=\"\(ts)\", oauth_signature_method=\"PLAINTEXT\", oauth_version=\"1.0\", oauth_signature=\"\(secret)%26\""
    }

    static func upcomingEvents() async -> String {
        let key = UserDefaults.standard.string(forKey: "schoology_key") ?? ""
        let secret = UserDefaults.standard.string(forKey: "schoology_secret") ?? ""
        guard !key.isEmpty, !secret.isEmpty else {
            return "Schoology isn't connected yet, sir. Open ECHO settings (gear icon, top right) and enter your Schoology API key and secret — you can generate them at yourschool.schoology.com/api."
        }
        do {
            // Step 1: find our user id (users/me responds with a 303 redirect)
            var meReq = URLRequest(url: URL(string: "https://api.schoology.com/v1/users/me")!)
            meReq.setValue(authHeader(key: key, secret: secret), forHTTPHeaderField: "Authorization")
            let (_, meResp) = try await URLSession.shared.data(for: meReq, delegate: RedirectBlocker())
            guard let http = meResp as? HTTPURLResponse else { return "Schoology gave an unexpected response." }
            var uid: String?
            if let loc = http.value(forHTTPHeaderField: "Location"),
               let match = loc.range(of: #"users/(\d+)"#, options: .regularExpression) {
                uid = String(loc[match]).replacingOccurrences(of: "users/", with: "")
            }
            guard let uid else {
                return "Couldn't sign in to Schoology (status \(http.statusCode)). Sir, double-check the API key and secret in settings."
            }

            // Step 2: pull events/assignments for the next two weeks
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let start = df.string(from: Date())
            let end = df.string(from: Calendar.current.date(byAdding: .day, value: 14, to: Date())!)
            var evReq = URLRequest(url: URL(string: "https://api.schoology.com/v1/users/\(uid)/events?start_date=\(start)&end_date=\(end)&limit=50")!)
            evReq.setValue(authHeader(key: key, secret: secret), forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: evReq)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = obj["event"] as? [[String: Any]] else {
                return "Connected to Schoology, but found no events in the next two weeks."
            }
            if events.isEmpty { return "Nothing due on Schoology in the next two weeks. Well done, sir." }
            return events.prefix(25).map { e in
                let title = e["title"] as? String ?? "Untitled"
                let when = e["start"] as? String ?? ""
                let type = e["type"] as? String ?? "event"
                return "• \(when) — \(title) (\(type))"
            }.joined(separator: "\n")
        } catch {
            return "Schoology connection failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Timers
class TimerManager: ObservableObject {
    static let shared = TimerManager()

    struct ActiveTimer: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let end: Date
    }

    @Published var timers: [ActiveTimer] = []
    var onFire: ((String) -> Void)?

    func add(minutes: Double, label: String) -> String {
        let mins = max(0.1, min(minutes, 24 * 60))
        let timer = ActiveTimer(label: label, end: Date().addingTimeInterval(mins * 60))
        timers.append(timer)
        // Ask for notification permission up front so the alert can fire later
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(mins * 60 * 1_000_000_000))
            guard timers.contains(timer) else { return } // cancelled
            timers.removeAll { $0.id == timer.id }
            SystemTools.notify(title: "E.C.H.O.",
                               body: "Sir — your \(label.isEmpty ? "timer" : "\(label) timer") is up.")
            onFire?(label)
        }
        let pretty = mins >= 1 ? "\(Int(mins)) minute\(Int(mins) == 1 ? "" : "s")" : "\(Int(mins * 60)) seconds"
        return "Timer set for \(pretty)\(label.isEmpty ? "" : " — \(label)")."
    }

    func cancelAll() { timers.removeAll() }
}

// MARK: - Weather (Open-Meteo, no API key)
enum WeatherService {
    static func forecast(city rawCity: String) async -> String {
        let city = rawCity.isEmpty ? (UserDefaults.standard.string(forKey: "jarvis_city") ?? "") : rawCity
        guard !city.isEmpty else {
            return "I don't know your city yet, sir. Set it in ECHO settings (gear icon), or tell me which city to check."
        }
        do {
            let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
            let (gd, _) = try await URLSession.shared.data(from: URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1")!)
            guard let gobj = try? JSONSerialization.jsonObject(with: gd) as? [String: Any],
                  let results = gobj["results"] as? [[String: Any]], let place = results.first,
                  let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double else {
                return "I couldn't find \(city) on the map, sir."
            }
            let name = place["name"] as? String ?? city
            let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=auto&forecast_days=3"
            let (wd, _) = try await URLSession.shared.data(from: URL(string: url)!)
            guard let w = try? JSONSerialization.jsonObject(with: wd) as? [String: Any] else {
                return "The weather data came back garbled, sir."
            }
            var out = "Weather for \(name):"
            if let cur = w["current"] as? [String: Any] {
                let t = cur["temperature_2m"] as? Double ?? 0
                let feels = cur["apparent_temperature"] as? Double ?? t
                let code = cur["weather_code"] as? Int ?? 0
                let wind = cur["wind_speed_10m"] as? Double ?? 0
                out += "\nRight now: \(Int(t))°F (feels like \(Int(feels))°F), \(describe(code)), wind \(Int(wind)) mph."
            }
            if let daily = w["daily"] as? [String: Any],
               let days = daily["time"] as? [String],
               let highs = daily["temperature_2m_max"] as? [Double],
               let lows = daily["temperature_2m_min"] as? [Double] {
                let codes = daily["weather_code"] as? [Int] ?? []
                let rains = daily["precipitation_probability_max"] as? [Any] ?? []
                for i in 0..<min(3, days.count, highs.count, lows.count) {
                    let code = i < codes.count ? codes[i] : 0
                    let rain = (i < rains.count ? rains[i] as? Double : nil) ?? 0
                    out += "\n• \(days[i]): \(describe(code)), \(Int(lows[i]))–\(Int(highs[i]))°F, \(Int(rain))% chance of rain"
                }
            }
            return out
        } catch {
            return "Weather systems unreachable: \(error.localizedDescription)"
        }
    }

    private static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzle"
        case 61...67: return "rain"
        case 71...77: return "snow"
        case 80...82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95...99: return "thunderstorms"
        default: return "mixed conditions"
        }
    }
}

// MARK: - System tools (apps, music, diagnostics)
enum SystemTools {
    static func openItem(_ target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespaces)
        #if canImport(AppKit)
        // Looks like a URL / website?
        if t.lowercased().hasPrefix("http") || (t.contains(".") && !t.contains(" ")) {
            let urlString = t.lowercased().hasPrefix("http") ? t : "https://\(t)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return "Opened \(urlString) in the browser."
            }
        }
        // Otherwise treat it as an app name
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let path = "\(dir)/\(t).app"
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return "Opening \(t), sir."
            }
        }
        if NSWorkspace.shared.launchApplication(t) {
            return "Opening \(t), sir."
        }
        return "I couldn't find an app called '\(t)', sir."
        #elseif canImport(UIKit)
        if t.lowercased().hasPrefix("http") || (t.contains(".") && !t.contains(" ")) {
            let urlString = t.lowercased().hasPrefix("http") ? t : "https://\(t)"
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
                return "Opened \(urlString) in the browser."
            }
        }
        return "Opening apps by name is a Mac ability, sir — but I can open websites."
        #else
        return "Not supported on this platform."
        #endif
    }

    /// Which player to command: user preference, else whichever is running (Spotify wins), else Apple Music.
    static func currentPlayer() -> String {
        let pref = UserDefaults.standard.string(forKey: "jarvis_player") ?? "Auto"
        if pref == "Spotify" || pref == "Music" { return pref }
        #if canImport(AppKit)
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if running.contains("com.spotify.client") { return "Spotify" }
        #endif
        return "Music"
    }

    static func music(_ action: String) -> String {
        #if canImport(AppKit)
        let app = currentPlayer()
        let nowPlaying = "try\n return name of current track & \" by \" & artist of current track\non error\n return \"\"\nend try"
        let script: String
        switch action.lowercased() {
        case "play":     script = "tell application \"\(app)\"\nplay\ndelay 0.3\n\(nowPlaying)\nend tell"
        case "pause":    script = "tell application \"\(app)\"\npause\nreturn \"\"\nend tell"
        case "next":     script = "tell application \"\(app)\"\nnext track\ndelay 0.3\n\(nowPlaying)\nend tell"
        case "previous": script = "tell application \"\(app)\"\nprevious track\ndelay 0.3\n\(nowPlaying)\nend tell"
        default:         script = "tell application \"\(app)\"\n\(nowPlaying)\nend tell"
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            return "\(app) control failed (\(msg)). If macOS asked for permission to control \(app), please click OK and try again."
        }
        let track = result?.stringValue ?? ""
        switch action.lowercased() {
        case "pause": return "\(app) paused."
        case "play", "next", "previous": return track.isEmpty ? "Done." : "Now playing on \(app): \(track)."
        default: return track.isEmpty ? "Nothing is playing right now, sir." : "Currently playing on \(app): \(track)."
        }
        #else
        return "Music control is available in my Mac form, sir."
        #endif
    }

    static func status() -> String {
        var lines: [String] = []
        #if canImport(AppKit)
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           let src = sources.first,
           let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any] {
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            lines.append("Battery: \(Int(Double(cur) / Double(max) * 100))%\(charging ? ", charging" : "")")
        } else {
            lines.append("Power: on AC (no battery detected)")
        }
        #endif
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 { lines.append("Battery: \(Int(level * 100))%") }
        #endif
        if let vals = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = vals.volumeAvailableCapacityForImportantUsage, let total = vals.volumeTotalCapacity {
            lines.append(String(format: "Disk: %.0f GB free of %.0f GB", Double(free) / 1e9, Double(total) / 1e9))
        }
        lines.append("Memory: \(ProcessInfo.processInfo.physicalMemory / (1 << 30)) GB installed")
        let up = ProcessInfo.processInfo.systemUptime
        lines.append("Uptime: \(Int(up) / 3600)h \(Int(up) % 3600 / 60)m")
        lines.append("Cores: \(ProcessInfo.processInfo.processorCount)")
        return lines.joined(separator: "\n")
    }

    static func remember(_ fact: String) -> String {
        var memories = UserDefaults.standard.stringArray(forKey: "jarvis_memories") ?? []
        memories.append(fact)
        if memories.count > 50 { memories.removeFirst(memories.count - 50) }
        UserDefaults.standard.set(memories, forKey: "jarvis_memories")
        return "Committed to memory, sir: \(fact)"
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Screenshot of the main display (excluding the ECHO window itself).
    static func captureScreen() async -> Data? {
        #if canImport(AppKit)
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return nil
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return nil }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        #else
        return nil
        #endif
    }

    static func headlines(topic: String) async -> String {
        let urlString: String
        if topic.isEmpty {
            urlString = "https://news.google.com/rss"
        } else {
            let q = topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? topic
            urlString = "https://news.google.com/rss/search?q=\(q)"
        }
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8) else {
            return "News feed unreachable, sir."
        }
        guard let regex = try? NSRegularExpression(pattern: "<title>(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?</title>", options: [.dotMatchesLineSeparators]) else {
            return "News parser fault."
        }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        var titles = matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: xml) else { return nil }
            return String(xml[r])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }
        titles.removeAll { $0.contains("Google News") } // channel/junk titles
        guard !titles.isEmpty else { return "No headlines found\(topic.isEmpty ? "" : " for \(topic)")." }
        return titles.prefix(8).map { "• \($0)" }.joined(separator: "\n")
    }

    static func price(symbol raw: String, type: String) async -> String {
        let symbol = raw.trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty else { return "Which symbol, sir?" }
        if type.lowercased() == "crypto" {
            let aliases = ["btc": "bitcoin", "eth": "ethereum", "doge": "dogecoin", "sol": "solana",
                           "ada": "cardano", "xrp": "ripple", "ltc": "litecoin", "bnb": "binancecoin"]
            let id = aliases[symbol.lowercased()] ?? symbol.lowercased().replacingOccurrences(of: " ", with: "-")
            guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(id)&vs_currencies=usd&include_24hr_change=true"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let coin = obj[id] as? [String: Any],
                  let usd = coin["usd"] as? Double else {
                return "Couldn't find a crypto called '\(symbol)', sir."
            }
            let change = coin["usd_24h_change"] as? Double ?? 0
            return String(format: "%@: $%.2f (%+.1f%% in 24h)", id.capitalized, usd, change)
        } else {
            let ticker = symbol.uppercased().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol.uppercased()
            var request = URLRequest(url: URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)?interval=1d&range=1d")!)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = obj["chart"] as? [String: Any],
                  let results = chart["result"] as? [[String: Any]],
                  let meta = results.first?["meta"] as? [String: Any],
                  let price = meta["regularMarketPrice"] as? Double else {
                return "Couldn't find a stock ticker '\(symbol)', sir."
            }
            let prev = meta["chartPreviousClose"] as? Double ?? price
            let pct = prev > 0 ? (price - prev) / prev * 100 : 0
            return String(format: "%@: $%.2f (%+.1f%% vs previous close)", symbol.uppercased(), price, pct)
        }
    }
}

// MARK: - Gmail (unread inbox via atom feed + app password)
enum GmailService {
    static func unread() async -> String {
        let address = (UserDefaults.standard.string(forKey: "gmail_address") ?? "").trimmingCharacters(in: .whitespaces)
        let password = (UserDefaults.standard.string(forKey: "gmail_app_password") ?? "").replacingOccurrences(of: " ", with: "")
        guard !address.isEmpty, !password.isEmpty else {
            return "Gmail isn't connected yet, sir. Open ECHO settings (gear icon) → Gmail and add your address plus a Google App Password."
        }
        var request = URLRequest(url: URL(string: "https://mail.google.com/mail/feed/atom")!)
        let token = Data("\(address):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                return "Gmail rejected the login, sir. Check the address and App Password in settings — it must be the 16-character App Password, not the normal Google password."
            }
            guard code == 200, let xml = String(data: data, encoding: .utf8) else {
                return "Gmail gave an unexpected response (\(code))."
            }
            let entries = xml.components(separatedBy: "<entry>").dropFirst()
            if entries.isEmpty { return "Inbox zero, sir — no unread emails. Remarkable." }

            func tag(_ name: String, _ s: String) -> String {
                guard let r = s.range(of: "<\(name)>([^<]*)</\(name)>", options: .regularExpression) else { return "" }
                return String(s[r])
                    .replacingOccurrences(of: "<\(name)>", with: "")
                    .replacingOccurrences(of: "</\(name)>", with: "")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
            }
            let lines = entries.prefix(10).map { entry -> String in
                let e = String(entry)
                let subject = tag("title", e).isEmpty ? "(no subject)" : tag("title", e)
                let from = tag("name", e).isEmpty ? tag("email", e) : tag("name", e)
                let preview = String(tag("summary", e).prefix(100))
                return "• From \(from): \(subject)\(preview.isEmpty ? "" : " — \(preview)")"
            }
            return "Unread emails (\(entries.count)):\n" + lines.joined(separator: "\n")
        } catch {
            return "Couldn't reach Gmail: \(error.localizedDescription)"
        }
    }
}

// MARK: - Ollama client (streaming + tool calling) + voice output
class JarvisBrain: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var isSpeaking = false
    @Published var voiceEnabled = true
    @Published var availableModels: [String] = []
    @Published var visionModels: [String] = []
    @Published var toolActivity: String?

    var visionModel: String? { visionModels.first }

    /// Base URL of the Ollama server — configurable so the iPhone build can reach the Mac.
    /// Forgiving about phone-keyboard sabotage: spaces, newlines, capital letters, trailing slashes.
    static var ollamaBase: String {
        var s = (UserDefaults.standard.string(forKey: "ollama_host") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if s.isEmpty { s = "http://localhost:11434" }
        if !s.hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func api(_ path: String) -> URL {
        URL(string: ollamaBase + path) ?? URL(string: "http://localhost:11434" + path)!
    }

    /// The neural voice server lives on the same machine as the brain, port 8880.
    static var ttsBase: String {
        var comps = URLComponents(string: ollamaBase)
        comps?.port = 8880
        return comps?.string ?? "http://localhost:8880"
    }
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: "jarvis_model")
            warmUp()
        }
    }

    /// Preloads the chat model into the server's RAM so the first reply is instant.
    func warmUp() {
        Task {
            var request = URLRequest(url: Self.api("/api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": "", "keep_alive": -1] as [String: Any])
            _ = try? await URLSession.shared.data(for: request)
        }
    }
    @Published var lastStats = ""

    /// Fires when ECHO has fully finished responding (spoken or silent).
    var onReplyDone: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var streamTask: Task<Void, Never>?

    private static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "get_calendar_events",
            "description": "Get the user's upcoming calendar events (Apple Calendar and any synced Google Calendar). Use for any question about the user's schedule, meetings, plans, or agenda.",
            "parameters": ["type": "object", "properties": [
                "days": ["type": "integer", "description": "How many days ahead to look (default 7)"]
            ], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "get_schoology_upcoming",
            "description": "Get the user's upcoming Schoology school assignments, tests, and events for the next two weeks. Use for any question about homework, assignments, school due dates, or classes.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "log_food",
            "description": "Log food the user ate to their calorie tracker. YOU must estimate realistic calories and macros for the food described. Call this whenever the user says they ate or drank something.",
            "parameters": ["type": "object", "properties": [
                "name": ["type": "string", "description": "Short name of the food, e.g. 'Chicken burrito'"],
                "calories": ["type": "number", "description": "Estimated total calories"],
                "protein_g": ["type": "number", "description": "Estimated protein in grams"],
                "carbs_g": ["type": "number", "description": "Estimated carbs in grams"],
                "fat_g": ["type": "number", "description": "Estimated fat in grams"]
            ], "required": ["name", "calories"]]
        ]],
        ["type": "function", "function": [
            "name": "get_nutrition_summary",
            "description": "Get today's calorie and macro totals plus the list of foods the user has logged today. Use for questions about calories eaten, remaining, diet progress.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "add_calendar_event",
            "description": "Add an event to the user's calendar. Use when the user asks to schedule, book, or add something to their calendar.",
            "parameters": ["type": "object", "properties": [
                "title": ["type": "string", "description": "Event title"],
                "start": ["type": "string", "description": "Start time formatted exactly as YYYY-MM-DD HH:mm in 24-hour time"],
                "duration_minutes": ["type": "number", "description": "Length in minutes (default 60)"]
            ], "required": ["title", "start"]]
        ]],
        ["type": "function", "function": [
            "name": "get_weather",
            "description": "Get current weather and 3-day forecast. Use for any weather question.",
            "parameters": ["type": "object", "properties": [
                "city": ["type": "string", "description": "City name. Omit to use the user's home city."]
            ], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "daily_briefing",
            "description": "Get everything at once: weather, today's calendar, Schoology assignments, and nutrition. Use when the user asks for a briefing, morning rundown, or 'catch me up'.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "set_timer",
            "description": "Set a countdown timer. Use when the user asks for a timer or to be told when time is up.",
            "parameters": ["type": "object", "properties": [
                "minutes": ["type": "number", "description": "Timer length in minutes"],
                "label": ["type": "string", "description": "Short label like 'pasta' (optional)"]
            ], "required": ["minutes"]]
        ]],
        ["type": "function", "function": [
            "name": "open_item",
            "description": "Open a Mac app or a website. Use when the user asks to open, launch, or go to an app or site.",
            "parameters": ["type": "object", "properties": [
                "target": ["type": "string", "description": "App name like 'Safari' or a website like 'youtube.com'"]
            ], "required": ["target"]]
        ]],
        ["type": "function", "function": [
            "name": "music_control",
            "description": "Control Spotify or Apple Music playback. Use when the user asks to play, pause, or skip music, or asks what's playing.",
            "parameters": ["type": "object", "properties": [
                "action": ["type": "string", "description": "One of: play, pause, next, previous, current"]
            ], "required": ["action"]]
        ]],
        ["type": "function", "function": [
            "name": "system_status",
            "description": "Get the Mac's battery, disk space, memory and uptime. Use for 'status report' or system health questions.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "remember_fact",
            "description": "Permanently save a personal fact the user tells you to remember (names, codes, preferences, dates).",
            "parameters": ["type": "object", "properties": [
                "fact": ["type": "string", "description": "The fact to remember, phrased in third person"]
            ], "required": ["fact"]]
        ]],
        ["type": "function", "function": [
            "name": "log_water",
            "description": "Log water the user drank, in ounces. Use when the user says they drank water.",
            "parameters": ["type": "object", "properties": [
                "ounces": ["type": "number", "description": "Ounces of water (default 8)"]
            ], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "analyze_screen",
            "description": "Take a screenshot of the user's Mac screen and describe or explain what's on it. Use when the user asks 'what am I looking at', asks for help with something on their screen, or asks you to read/summarize the screen.",
            "parameters": ["type": "object", "properties": [
                "question": ["type": "string", "description": "What the user wants to know about the screen"]
            ], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "get_news",
            "description": "Get current news headlines. Use for any question about news or current events.",
            "parameters": ["type": "object", "properties": [
                "topic": ["type": "string", "description": "Topic to search for. Omit for top stories."]
            ], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "get_price",
            "description": "Get the current price of a stock or cryptocurrency.",
            "parameters": ["type": "object", "properties": [
                "symbol": ["type": "string", "description": "Ticker like AAPL, or crypto name like bitcoin"],
                "type": ["type": "string", "description": "Either 'stock' or 'crypto'"]
            ], "required": ["symbol", "type"]]
        ]],
        ["type": "function", "function": [
            "name": "add_reminder",
            "description": "Add a to-do to the user's Apple Reminders (syncs to their iPhone). Use when the user says 'remind me to...'",
            "parameters": ["type": "object", "properties": [
                "title": ["type": "string", "description": "What to remind them about"],
                "due": ["type": "string", "description": "Due time as YYYY-MM-DD HH:mm (optional)"]
            ], "required": ["title"]]
        ]],
        ["type": "function", "function": [
            "name": "get_reminders",
            "description": "List the user's pending Apple Reminders / to-dos.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": []]
        ]],
        ["type": "function", "function": [
            "name": "check_email",
            "description": "Check the user's Gmail inbox for unread emails (sender, subject, preview). Use for any question about email or messages in their inbox.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": []]
        ]]
    ]

    override init() {
        model = UserDefaults.standard.string(forKey: "jarvis_model") ?? "llama3.2"
        super.init()
        synthesizer.delegate = self
        loadHistory()
        fetchModels()
        warmUp()
    }

    /// Set when ECHO has asked "Ready for your briefing?" — the next affirmative reply triggers it.
    var briefingOffered = false

    func offerBriefing() {
        guard !isThinking else { return }
        briefingOffered = true
        let msg = "Good morning, sir. Ready for your briefing?"
        messages.append(ChatMessage(text: msg, isUser: false))
        persist()
        speak(msg)
    }

    // MARK: Chat
    func send(_ prompt: String) {
        guard !isThinking else { return }
        stopSpeaking()
        var text = prompt
        if briefingOffered {
            briefingOffered = false
            let lower = text.lowercased()
            let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted))
            let yesWords: Set<String> = ["yes", "yeah", "yep", "sure", "ok", "okay", "ready", "go", "please", "absolutely"]
            if lower.count < 30, !words.intersection(yesWords).isEmpty {
                text = "Give me my daily briefing"
            }
        }
        messages.append(ChatMessage(text: text, isUser: true))
        isThinking = true
        persist()
        let history = buildHistory()

        streamTask = Task {
            let pipelined = startSpeechPipeline()
            let replyIndex = await runTurn(history: history, depth: 0)
            isThinking = false
            toolActivity = nil
            persist()
            if pipelined {
                if replyIndex == nil && !Task.isCancelled {
                    let apology = "Apologies sir, I received a garbled transmission from my core systems."
                    messages.append(ChatMessage(text: apology, isUser: false))
                    persist()
                    speechCont?.yield(apology)
                }
                finishSpeechPipeline()
            } else if Task.isCancelled {
                onReplyDone?()
            } else if let i = replyIndex {
                speak(messages[i].text)
            } else {
                let apology = "Apologies sir, I received a garbled transmission from my core systems."
                messages.append(ChatMessage(text: apology, isUser: false))
                persist()
                speak(apology)
            }
        }
    }

    /// Full tool-enabled exchange without streaming UI or speech — used by Siri/Shortcuts.
    func answerQuietly(_ prompt: String) async -> String {
        messages.append(ChatMessage(text: prompt, isUser: true))
        let history = buildHistory()
        let replyIndex = await runTurn(history: history, depth: 0)
        persist()
        if let i = replyIndex { return messages[i].text }
        return "Apologies sir, my core systems didn't respond. Is the Mac awake?"
    }

    private func buildHistory() -> [[String: Any]] {
        let df = DateFormatter(); df.dateFormat = "EEEE, MMMM d yyyy, h:mm a"
        let nutrition = NutritionStore.shared
        let memories = UserDefaults.standard.stringArray(forKey: "jarvis_memories") ?? []
        let memoryBlock = memories.isEmpty ? "" : "\nFacts you know about the user:\n" + memories.map { "- \($0)" }.joined(separator: "\n")
        let city = UserDefaults.standard.string(forKey: "jarvis_city") ?? ""
        let persona: String
        switch UserDefaults.standard.string(forKey: "echo_personality") ?? "Classic" {
        case "Sassy":
            persona = "Your personality: sharp, playful wit. Tease the user affectionately, drop the occasional deadpan roast or pun, act mildly unimpressed by everything — but always deliver flawlessly. Call him 'sir' with a detectable smirk."
        case "Hype":
            persona = "Your personality: the user's biggest supporter. High energy, celebrate wins like a locker-room speech, frame tasks as missions. Sprinkle in 'let's go' energy without being exhausting. Still call him 'sir' like he's the commander."
        case "Zen":
            persona = "Your personality: calm, unhurried, quietly confident. Short soothing sentences, gentle encouragement, never flustered. A serene monk who happens to run a Mac."
        default:
            persona = "Your personality: the quintessential British butler AI — dry understatement, impeccable manners, subtle wit in the vein of Alfred Pennyworth and JARVIS. Gracefully sardonic when the user procrastinates."
        }
        var history: [[String: Any]] = [
            ["role": "system", "content": """
            You are ECHO, a loyal AI assistant running locally on the user's own hardware. \(persona)
            Address the user as 'sir', or by his name if you know it from saved facts. Be concise — replies are spoken aloud, so keep them conversational; avoid heavy markdown or tables.
            Current date and time: \(df.string(from: Date())).\(city.isEmpty ? "" : " Home city: \(city).")
            You have tools — use one whenever the request involves: schedule (get_calendar_events / add_calendar_event), to-dos (add_reminder / get_reminders), school work (get_schoology_upcoming), food and diet (log_food — estimate calories yourself, get_nutrition_summary, log_water), weather (get_weather), news (get_news), stock or crypto prices (get_price), a full rundown (daily_briefing), timers (set_timer), opening apps or websites (open_item), music (music_control), the Mac's health (system_status), what's on the user's screen (analyze_screen), unread email (check_email), or saving personal facts (remember_fact). Otherwise just answer normally.
            Today's intake so far: \(Int(nutrition.todayCalories)) of \(Int(nutrition.goal)) kcal, \(Int(nutrition.todayWater)) oz water.\(memoryBlock)
            HARD RULES — never break these: You can ONLY see what your tools return. Email goes through check_email only; you have NO access to text messages, social media, photos, or anything without a tool. If asked about something you can't access, say plainly that you can't see it — NEVER invent events, appointments, messages, or facts about the user's life. If a tool returns nothing, say nothing was found. It is always better to say "I don't know, sir" than to guess.
            """]
        ]
        for m in messages.suffix(20) {
            history.append(["role": m.isUser ? "user" : "assistant", "content": m.text])
        }
        return history
    }

    /// One round-trip to Ollama. If the model calls tools, executes them and recurses.
    /// Returns the index in `messages` of the final spoken reply, or nil.
    private func runTurn(history: [[String: Any]], depth: Int) async -> Int? {
        var request = URLRequest(url: Self.api("/api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": history, "stream": true, "keep_alive": -1,
                                   "options": ["num_ctx": 8192]]
        if depth < 3 { body["tools"] = Self.tools }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var replyIndex: Int?
        var partialText = ""
        var toolCalls: [[String: Any]] = []

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                if Task.isCancelled { return replyIndex }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let msg = obj["message"] as? [String: Any] {
                    if let calls = msg["tool_calls"] as? [[String: Any]] {
                        toolCalls.append(contentsOf: calls)
                    }
                    if let chunk = msg["content"] as? String, !chunk.isEmpty {
                        partialText += chunk
                        if let i = replyIndex {
                            messages[i].text += chunk
                        } else {
                            messages.append(ChatMessage(text: chunk, isUser: false))
                            replyIndex = messages.count - 1
                        }
                        if speechCont != nil {
                            speechBuffer += chunk
                            for sentence in extractSentences() { speechCont?.yield(sentence) }
                        }
                    }
                }
                if obj["done"] as? Bool == true {
                    if let count = obj["eval_count"] as? Int,
                       let dur = obj["eval_duration"] as? Double, dur > 0 {
                        lastStats = String(format: "%.0f tok/s", Double(count) / (dur / 1e9))
                    }
                    break
                }
            }
        } catch {
            if !Task.isCancelled {
                let msg = "Apologies sir, I can't reach my core systems. Is the desktop awake?"
                messages.append(ChatMessage(text: msg, isUser: false))
                speechCont?.yield(msg)
                return messages.count - 1
            }
            return replyIndex
        }

        guard !toolCalls.isEmpty, depth < 3 else { return replyIndex }

        // Execute tools, then let the model see the results and answer.
        var next = history
        next.append(["role": "assistant", "content": partialText, "tool_calls": toolCalls])
        for call in toolCalls {
            guard let fn = call["function"] as? [String: Any],
                  let name = fn["name"] as? String else { continue }
            let args = fn["arguments"] as? [String: Any] ?? [:]
            toolActivity = activityLabel(for: name)
            let result = await runTool(name, args)
            next.append(["role": "tool", "content": result])
        }
        toolActivity = nil
        let finalIndex = await runTurn(history: next, depth: depth + 1)
        return finalIndex ?? replyIndex
    }

    private func activityLabel(for tool: String) -> String {
        switch tool {
        case "get_calendar_events": return "Accessing calendar..."
        case "add_calendar_event": return "Updating calendar..."
        case "get_schoology_upcoming": return "Contacting Schoology..."
        case "log_food": return "Logging to nutrition tracker..."
        case "get_nutrition_summary": return "Reading nutrition log..."
        case "log_water": return "Logging hydration..."
        case "get_weather": return "Checking the skies..."
        case "daily_briefing": return "Compiling your briefing..."
        case "set_timer": return "Setting timer..."
        case "open_item": return "Opening..."
        case "music_control": return "Controlling music..."
        case "system_status": return "Running diagnostics..."
        case "remember_fact": return "Committing to memory..."
        case "analyze_screen": return "Looking at your screen..."
        case "get_news": return "Scanning the wires..."
        case "get_price": return "Checking the markets..."
        case "add_reminder": return "Adding reminder..."
        case "get_reminders": return "Reading your reminders..."
        case "check_email": return "Checking your inbox..."
        default: return "Running \(tool)..."
        }
    }

    private func runTool(_ name: String, _ args: [String: Any]) async -> String {
        func num(_ key: String) -> Double {
            if let d = args[key] as? Double { return d }
            if let i = args[key] as? Int { return Double(i) }
            if let s = args[key] as? String, let d = Double(s) { return d }
            return 0
        }
        switch name {
        case "get_calendar_events":
            let days = (args["days"] as? Int) ?? Int(num("days") > 0 ? num("days") : 7)
            return await CalendarService.shared.upcoming(days: days)
        case "get_schoology_upcoming":
            return await SchoologyService.upcomingEvents()
        case "log_food":
            let entry = FoodEntry(name: (args["name"] as? String ?? "Food").capitalized,
                                  calories: num("calories"),
                                  protein: num("protein_g"),
                                  carbs: num("carbs_g"),
                                  fat: num("fat_g"))
            NutritionStore.shared.add(entry)
            let store = NutritionStore.shared
            return "Logged \(entry.name): \(Int(entry.calories)) kcal. Total today: \(Int(store.todayCalories)) of \(Int(store.goal)) kcal (\(Int(store.goal - store.todayCalories)) remaining)."
        case "get_nutrition_summary":
            return NutritionStore.shared.summary()
        case "log_water":
            let oz = num("ounces") > 0 ? num("ounces") : 8
            NutritionStore.shared.addWater(oz)
            return "Logged \(Int(oz)) oz of water. Total today: \(Int(NutritionStore.shared.todayWater)) oz."
        case "add_calendar_event":
            let title = args["title"] as? String ?? "Event"
            let start = args["start"] as? String ?? ""
            let dur = num("duration_minutes") > 0 ? num("duration_minutes") : 60
            return await CalendarService.shared.createEvent(title: title, start: start, durationMinutes: dur)
        case "get_weather":
            return await WeatherService.forecast(city: args["city"] as? String ?? "")
        case "daily_briefing":
            async let weather = WeatherService.forecast(city: "")
            async let calendar = CalendarService.shared.upcoming(days: 1)
            async let school = SchoologyService.upcomingEvents()
            let food = NutritionStore.shared.summary()
            return await "WEATHER:\n\(weather)\n\nTODAY'S CALENDAR:\n\(calendar)\n\nSCHOOLOGY:\n\(school)\n\nNUTRITION:\n\(food)"
        case "set_timer":
            let mins = num("minutes")
            guard mins > 0 else { return "I need a timer length in minutes, sir." }
            return TimerManager.shared.add(minutes: mins, label: args["label"] as? String ?? "")
        case "open_item":
            return SystemTools.openItem(args["target"] as? String ?? "")
        case "music_control":
            return SystemTools.music(args["action"] as? String ?? "current")
        case "system_status":
            return SystemTools.status()
        case "remember_fact":
            let fact = args["fact"] as? String ?? ""
            guard !fact.isEmpty else { return "There was nothing to remember, sir." }
            return SystemTools.remember(fact)
        case "analyze_screen":
            #if !os(macOS)
            return "Screen sight is only available in my Mac form, sir."
            #else
            let question = args["question"] as? String ?? "Describe what's on the screen."
            guard let shot = await SystemTools.captureScreen() else {
                return "I can't see the screen yet, sir. Grant 'ECHO' Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then relaunch me and ask again."
            }
            let jpeg = downscaledJPEG(shot, maxDim: 1344, quality: 0.6) ?? shot
            return await describeImage(jpeg, question: question)
            #endif
        case "get_news":
            return await SystemTools.headlines(topic: args["topic"] as? String ?? "")
        case "get_price":
            return await SystemTools.price(symbol: args["symbol"] as? String ?? "",
                                           type: args["type"] as? String ?? "stock")
        case "add_reminder":
            return await CalendarService.shared.addReminder(title: args["title"] as? String ?? "Reminder",
                                                            due: args["due"] as? String ?? "")
        case "get_reminders":
            return await CalendarService.shared.pendingReminders()
        case "check_email":
            return await GmailService.unread()
        default:
            return "Unknown tool: \(name)"
        }
    }

    /// Sends an image to the local vision model and returns its description.
    private func describeImage(_ jpeg: Data, question: String) async -> String {
        fetchModels()
        guard let vm = visionModel else {
            return "No vision model installed. The user should run: ollama pull gemma3:4b"
        }
        var request = URLRequest(url: Self.api("/api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": vm,
            "stream": false,
            "keep_alive": "30m",
            "messages": [["role": "user",
                          "content": "This is a screenshot of the user's Mac screen. The user asks: \(question)\nAnswer concisely and helpfully based on what is visible.",
                          "images": [jpeg.base64EncodedString()]]],
            "options": ["temperature": 0.3]
        ] as [String: Any])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return "Vision systems returned something unintelligible."
            }
            return content
        } catch {
            return "Vision systems offline: \(error.localizedDescription)"
        }
    }

    func stopGeneration() {
        streamTask?.cancel()
        stopSpeaking()
        isThinking = false
        toolActivity = nil
    }

    func clearChat() {
        stopGeneration()
        stopSpeaking()
        messages = [ChatMessage(text: "Memory banks wiped, sir. Fresh start.", isUser: false)]
        persist()
    }

    // MARK: Models
    func fetchModels() {
        Task {
            let url = Self.api("/api/tags")
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["models"] as? [[String: Any]] else { return }
            let names = arr.compactMap { $0["name"] as? String }
            if !names.isEmpty {
                availableModels = names
                if !names.contains(model), !names.contains(model + ":latest") {
                    model = names[0]
                }
            }
            visionModels = arr.filter { ($0["capabilities"] as? [String])?.contains("vision") == true }
                .compactMap { $0["name"] as? String }
        }
    }

    // MARK: Food photo analysis
    func analyzeFoodPhoto(_ raw: Data) {
        guard !isThinking else { return }
        stopSpeaking()
        guard let jpeg = downscaledJPEG(raw, maxDim: 768, quality: 0.6) else {
            messages.append(ChatMessage(text: "I couldn't read that image, sir.", isUser: false))
            return
        }
        let thumb = downscaledJPEG(raw, maxDim: 320, quality: 0.5)
        messages.append(ChatMessage(text: "What do you make of this meal, ECHO?", isUser: true, imageData: thumb))
        isThinking = true
        toolActivity = "Analyzing photo..."

        streamTask = Task {
            defer {
                isThinking = false
                toolActivity = nil
                persist()
            }
            fetchModels()
            guard let vm = visionModel else {
                let msg = "I need vision systems for that, sir. Run `ollama pull gemma3:4b` in Terminal, then show me the photo again."
                messages.append(ChatMessage(text: msg, isUser: false))
                speak(msg)
                return
            }
            var request = URLRequest(url: Self.api("/api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 300
            let prompt = """
            You are a nutritionist AI. Look at this photo. Identify the food and estimate total calories and macros for the visible portion. Respond with ONLY a compact JSON object, no other text:
            {"name": "short food name", "calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0}
            If no food or drink is visible, respond with {"name": "none", "calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0}.
            """
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": vm,
                "stream": false,
                "keep_alive": "30m",
                "messages": [["role": "user", "content": prompt, "images": [jpeg.base64EncodedString()]]],
                "options": ["temperature": 0.2]
            ] as [String: Any])

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    let msg = "My vision systems returned something unintelligible, sir."
                    messages.append(ChatMessage(text: msg, isUser: false))
                    speak(msg)
                    return
                }
                if let food = parseFoodJSON(content) {
                    if food.name.lowercased().contains("none") || food.calories <= 0 {
                        let msg = "I don't see any food in that photo, sir."
                        messages.append(ChatMessage(text: msg, isUser: false))
                        speak(msg)
                    } else {
                        NutritionStore.shared.add(food)
                        let store = NutritionStore.shared
                        let msg = "That looks like \(food.name), sir — roughly \(Int(food.calories)) calories (\(Int(food.protein))g protein, \(Int(food.carbs))g carbs, \(Int(food.fat))g fat). Logged. You're at \(Int(store.todayCalories)) of \(Int(store.goal)) kcal today."
                        messages.append(ChatMessage(text: msg, isUser: false))
                        speak(msg)
                    }
                } else {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    messages.append(ChatMessage(text: trimmed.isEmpty ? "I couldn't make sense of that photo, sir." : trimmed, isUser: false))
                    speak(trimmed)
                }
            } catch {
                if !Task.isCancelled {
                    let msg = "Vision systems offline, sir. Is Ollama running?"
                    messages.append(ChatMessage(text: msg, isUser: false))
                    speak(msg)
                }
            }
        }
    }

    private func parseFoodJSON(_ content: String) -> FoodEntry? {
        guard let s = content.firstIndex(of: "{"), let e = content.lastIndex(of: "}"), s < e else { return nil }
        guard let data = String(content[s...e]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        func num(_ key: String) -> Double {
            if let d = obj[key] as? Double { return d }
            if let i = obj[key] as? Int { return Double(i) }
            if let s = obj[key] as? String, let d = Double(s) { return d }
            return 0
        }
        return FoodEntry(name: name.capitalized, calories: num("calories"),
                         protein: num("protein_g"), carbs: num("carbs_g"), fat: num("fat_g"))
    }

    private func downscaledJPEG(_ data: Data, maxDim: CGFloat, quality: CGFloat) -> Data? {
        #if canImport(AppKit)
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let scale = min(1, maxDim / max(img.size.width, img.size.height))
        let w = Int(img.size.width * scale), h = Int(img.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #elseif canImport(UIKit)
        guard let img = UIImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let scale = min(1, maxDim / max(img.size.width, img.size.height))
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
        #else
        return data
        #endif
    }

    // MARK: Persistence
    private func persist() {
        // Photos are session-only; strip them so history stays small
        let slim = messages.suffix(200).map { m -> ChatMessage in
            var c = m; c.imageData = nil; return c
        }
        if let data = try? JSONEncoder().encode(slim) {
            UserDefaults.standard.set(data, forKey: "jarvis_history")
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "jarvis_history"),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data), !saved.isEmpty {
            messages = saved
        } else {
            messages = [ChatMessage(text: "Good evening, sir. All systems online.", isUser: false)]
        }
    }

    // MARK: Voice output
    /// Best-quality British voice installed on this Mac (premium > enhanced > default).
    private static let jarvisVoice: AVSpeechSynthesisVoice? = {
        let gb = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        return gb.first { $0.quality == .premium }
            ?? gb.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    private var player: AVAudioPlayer?
    private var playContinuation: CheckedContinuation<Void, Never>?

    /// User's speaking-speed multiplier (1.0 = normal).
    private var voiceSpeed: Float {
        let v = UserDefaults.standard.object(forKey: "voice_speed") as? Double ?? 1.15
        return Float(min(max(v, 0.8), 1.8))
    }

    private func cleaned(_ text: String) -> String {
        var clean = text
        for token in ["**", "*", "###", "##", "#", "`", "_", "•"] {
            clean = clean.replacingOccurrences(of: token, with: "")
        }
        return clean
    }

    func speak(_ text: String) {
        guard voiceEnabled else { onReplyDone?(); return }
        let clean = cleaned(text)
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { onReplyDone?(); return }
        isSpeaking = true
        switch UserDefaults.standard.string(forKey: "tts_engine") ?? "neural" {
        case "eleven": speakEleven(clean)
        case "system": speakSystem(clean)
        default: speakNeural(clean)
        }
    }

    // MARK: Streaming speech pipeline — speaks sentences while the reply is still generating
    var speechCont: AsyncStream<String>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    var speechBuffer = ""

    /// Starts the sentence-by-sentence pipeline. Returns true if it's handling speech for this turn.
    func startSpeechPipeline() -> Bool {
        guard voiceEnabled,
              (UserDefaults.standard.string(forKey: "tts_engine") ?? "neural") == "neural" else { return false }
        speechBuffer = ""
        let stream = AsyncStream<String> { cont in self.speechCont = cont }
        pipelineTask = Task {
            for await sentence in stream {
                if Task.isCancelled { break }
                let clean = cleaned(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.count > 1 else { continue }
                isSpeaking = true
                if let data = await fetchNeuralData(clean) {
                    if Task.isCancelled { break }
                    await playAndWait(data)
                } else {
                    speakSystem(clean) // server hiccup — system voice covers this sentence
                }
            }
            isSpeaking = false
            pipelineTask = nil
            onReplyDone?()
        }
        return true
    }

    /// Flushes any trailing partial sentence and closes the pipeline input.
    func finishSpeechPipeline() {
        let rest = speechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { speechCont?.yield(rest) }
        speechBuffer = ""
        speechCont?.finish()
        speechCont = nil
    }

    /// Pulls complete sentences off the front of `speechBuffer`.
    func extractSentences() -> [String] {
        var out: [String] = []
        let enders: Set<Character> = [".", "!", "?", "…", "\n"]
        var lastCut = speechBuffer.startIndex
        var idx = speechBuffer.startIndex
        while idx < speechBuffer.endIndex {
            if enders.contains(speechBuffer[idx]) {
                let next = speechBuffer.index(after: idx)
                let isDecimal = speechBuffer[idx] == "." && next < speechBuffer.endIndex && speechBuffer[next].isNumber
                if !isDecimal {
                    let sentence = String(speechBuffer[lastCut..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if sentence.count > 1 { out.append(sentence) }
                    lastCut = next
                }
            }
            idx = speechBuffer.index(after: idx)
        }
        speechBuffer = String(speechBuffer[lastCut...])
        return out
    }

    private func fetchNeuralData(_ clean: String) async -> Data? {
        let voice = UserDefaults.standard.string(forKey: "kokoro_voice") ?? "bf_emma"
        var comps = URLComponents(string: Self.ttsBase + "/tts")
        comps?.queryItems = [URLQueryItem(name: "text", value: clean),
                             URLQueryItem(name: "voice", value: voice)]
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 500 else { return nil }
        return data
    }

    private func playAndWait(_ data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            do {
                let p = try AVAudioPlayer(data: data)
                p.enableRate = true
                p.rate = voiceSpeed
                p.delegate = self
                player = p
                playContinuation = cont
                p.play()
            } catch {
                cont.resume()
            }
        }
    }

    /// Kokoro neural voice server (falls back to the system voice if unreachable).
    private func speakNeural(_ clean: String) {
        Task {
            if let data = await fetchNeuralData(clean) {
                guard isSpeaking else { return } // user hit stop while we were generating
                do { try playAudio(data) } catch { speakSystem(clean) }
            } else if isSpeaking {
                speakSystem(clean)
            }
        }
    }

    /// ElevenLabs cloud voice (needs API key in settings; falls back to system voice).
    private func speakEleven(_ clean: String) {
        Task {
            let key = UserDefaults.standard.string(forKey: "eleven_key") ?? ""
            guard !key.isEmpty else { speakSystem(clean); return }
            let voiceID = UserDefaults.standard.string(forKey: "eleven_voice_id").flatMap { $0.isEmpty ? nil : $0 } ?? "EXAVITQu4vr4xnSDxMaL"
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": clean, "model_id": "eleven_turbo_v2_5"])
            do {
                let (data, resp) = try await URLSession.shared.data(for: request)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard isSpeaking else { return }
                try playAudio(data)
            } catch {
                if isSpeaking { speakSystem(clean) }
            }
        }
    }

    private func speakSystem(_ clean: String) {
        let utterance = AVSpeechUtterance(string: clean)
        if let id = UserDefaults.standard.string(forKey: "echo_voice_id"), !id.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = chosen
        } else {
            utterance.voice = Self.jarvisVoice
        }
        utterance.rate = min(0.62, 0.44 * voiceSpeed)
        utterance.pitchMultiplier = 0.95
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func playAudio(_ data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        p.enableRate = true
        p.rate = voiceSpeed
        p.delegate = self
        player = p
        p.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if let cont = self.playContinuation {
                // pipeline mode — hand control back to the sentence loop
                self.playContinuation = nil
                cont.resume()
            } else {
                self.isSpeaking = false
                self.onReplyDone?()
            }
        }
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        pipelineTask?.cancel()
        pipelineTask = nil
        speechCont?.finish()
        speechCont = nil
        speechBuffer = ""
        player?.stop()
        player = nil
        if let cont = playContinuation {
            playContinuation = nil
            cont.resume()
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onReplyDone?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

// MARK: - Speech recognition (with silence auto-send + mic level)
class VoiceListener: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var level: Double = 0

    /// Fired when the user stops talking; passes the final transcript.
    var onCommand: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var generation = 0

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            Task { @MainActor in self.beginRecording() }
        }
    }

    private func beginRecording() {
        guard !isListening else { return }
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try? audioSession.setActive(true)
        #endif
        generation += 1
        let gen = generation
        transcript = ""
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request = request else { return }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = Double(sqrt(sum / Float(max(n, 1))))
                Task { @MainActor in self.level = min(1, rms * 10) }
            }
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }
        isListening = true

        task = recognizer?.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                guard gen == self.generation else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    self.bumpSilenceTimer()
                }
                if error != nil || (result?.isFinal ?? false) {
                    if self.isListening {
                        let pending = self.transcript
                        self.stop()
                        if pending.trimmingCharacters(in: .whitespaces).isEmpty {
                            self.beginRecording()
                        } else {
                            self.onCommand?(pending)
                        }
                    }
                }
            }
        }
    }

    private func bumpSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            let text = self.transcript.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, self.isListening else { return }
            self.stop()
            self.onCommand?(text)
        }
    }

    func stop() {
        generation += 1
        silenceTask?.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        level = 0
    }
}

// MARK: - Arc reactor
struct ArcReactor: View {
    enum Mode { case idle, listening, thinking, speaking }
    var mode: Mode
    var level: Double

    private var color: Color {
        switch mode {
        case .idle: return Theme.accent
        case .listening: return Theme.good
        case .thinking: return .orange
        case .speaking: return Color(red: 0.4, green: 0.8, blue: 1.0)
        }
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 2
                let speed: Double = mode == .thinking ? 1.2 : 0.45
                ctx.addFilter(.shadow(color: color.opacity(0.8), radius: 6))

                // Expanding echo ripples
                for i in 0..<3 {
                    let phase = (t * speed + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let r = R * (0.3 + 0.7 * phase)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(color.opacity((1 - phase) * 0.75)), lineWidth: 2)
                }

                // Steady outer ring
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)),
                           with: .color(color.opacity(0.35)), lineWidth: 1)

                let pulse = 1 + 0.15 * sin(t * (mode == .speaking ? 8 : 3))
                let coreR = R * 0.38 * pulse * (1 + level * 0.7)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                         with: .radialGradient(Gradient(colors: [.white, color, color.opacity(0)]),
                                               center: c, startRadius: 0, endRadius: coreR * 1.4))
            }
        }
    }
}

// MARK: - Camera (food scanner, supports iPhone via Continuity Camera)
class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var devices: [AVCaptureDevice] = []
    @Published var selectedID = ""

    var onPhoto: ((Data) -> Void)?
    var onDenied: (() -> Void)?

    private let photoOutput = AVCapturePhotoOutput()

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if granted { self.configure() } else { self.onDenied?() }
            }
        }
    }

    func configure() {
        #if os(macOS)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]
        #else
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera]
        #endif
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video, position: .unspecified)
        devices = discovery.devices
        guard !devices.isEmpty else { return }
        if selectedID.isEmpty || !devices.contains(where: { $0.uniqueID == selectedID }) {
            selectedID = devices.first!.uniqueID
        }
        guard let device = devices.first(where: { $0.uniqueID == selectedID }) else { return }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
    }

    func capture() {
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor in self.onPhoto?(data) }
    }
}

#if canImport(AppKit)
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#elseif canImport(UIKit)
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        if let layer = view.layer as? AVCaptureVideoPreviewLayer {
            layer.session = session
            layer.videoGravity = .resizeAspectFill
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}
#endif

struct CameraSheet: View {
    var onPhoto: (Data) -> Void
    @StateObject private var cam = CameraController()
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        VStack(spacing: 12) {
            Text("FOOD SCANNER")
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(Theme.accent)

            if denied {
                Text("Camera access denied — enable it in System Settings → Privacy & Security → Camera.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: 420)
            } else {
                CameraPreview(session: cam.session)
                    .frame(maxWidth: 440)
                    .frame(height: 300)
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.4)))
            }

            if cam.devices.count > 1 {
                Picker("Camera", selection: $cam.selectedID) {
                    ForEach(cam.devices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(d.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)
            }

            HStack(spacing: 16) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button {
                    cam.capture()
                } label: {
                    Label("Capture & Analyze", systemImage: "camera.fill")
                        .foregroundColor(Theme.accent)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(denied)
            }

            Text("Tip: with your iPhone nearby and signed into the same Apple ID, it appears in the camera list — point it at your plate.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .frame(maxWidth: 420)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(Color.black)
        .onAppear {
            cam.onPhoto = { data in
                dismiss()
                onPhoto(data)
            }
            cam.onDenied = { denied = true }
            cam.start()
        }
        .onDisappear { cam.stop() }
        .onChange(of: cam.selectedID) { cam.configure() }
    }
}

// MARK: - Nutrition sheet
struct NutritionSheet: View {
    @ObservedObject var nutrition = NutritionStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("NUTRITION")
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(Theme.accent)

            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(1, nutrition.todayCalories / max(nutrition.goal, 1)))
                    .stroke(nutrition.todayCalories > nutrition.goal ? Color.orange : Theme.accent,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(Int(nutrition.todayCalories))")
                        .font(.system(.title, design: .monospaced).bold())
                        .foregroundColor(.white)
                    Text("of \(Int(nutrition.goal)) kcal")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(width: 150, height: 150)

            HStack(spacing: 24) {
                macro("PROTEIN", nutrition.todayProtein, Theme.accent)
                macro("CARBS", nutrition.todayCarbs, .orange)
                macro("FAT", nutrition.todayFat, .yellow)
            }

            HStack(spacing: 16) {
                HStack {
                    Text("Daily goal")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                    TextField("kcal", value: $nutrition.goal, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                HStack(spacing: 6) {
                    Image(systemName: "drop.fill").foregroundColor(.blue)
                    Text("\(Int(nutrition.todayWater)) oz")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                    Button("+8 oz") { nutrition.addWater(8) }
                        .font(.system(.caption, design: .monospaced))
                }
            }

            // Last 7 days
            Chart {
                ForEach(nutrition.last7Days, id: \.day) { item in
                    BarMark(x: .value("Day", item.day), y: .value("kcal", item.kcal))
                        .foregroundStyle(Theme.accent.gradient)
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Goal", nutrition.goal))
                    .foregroundStyle(Color.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .frame(height: 100)
            .chartYAxis {
                AxisMarks { AxisValueLabel().font(.system(size: 8, design: .monospaced)) }
            }
            .chartXAxis {
                AxisMarks { AxisValueLabel().font(.system(size: 8, design: .monospaced)) }
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            if nutrition.todayEntries.isEmpty {
                Text("Nothing logged today.\nTell ECHO: \"I ate a chicken burrito\"")
                    .multilineTextAlignment(.center)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(nutrition.todayEntries.reversed()) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name).foregroundColor(.white)
                                    Text("P\(Int(entry.protein)) C\(Int(entry.carbs)) F\(Int(entry.fat))")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                                Spacer()
                                Text("\(Int(entry.calories)) kcal")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(Theme.accent)
                                Button { nutrition.delete(entry) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white.opacity(0.3))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 380)
        .background(Color.black)
    }

    private func macro(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value))g")
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

// MARK: - Settings sheet
struct SettingsSheet: View {
    @AppStorage("schoology_key") private var schoologyKey = ""
    @AppStorage("schoology_secret") private var schoologySecret = ""
    @AppStorage("gmail_address") private var gmailAddress = ""
    @AppStorage("gmail_app_password") private var gmailAppPassword = ""
    @AppStorage("jarvis_city") private var homeCity = ""
    @AppStorage("jarvis_player") private var musicPlayer = "Auto"
    @AppStorage("ollama_host") private var ollamaHost = ""
    @AppStorage("echo_personality") private var personality = "Classic"
    @AppStorage("echo_voice_id") private var voiceID = ""
    @AppStorage("tts_engine") private var ttsEngine = "neural"
    @AppStorage("kokoro_voice") private var kokoroVoice = "bf_emma"
    @AppStorage("eleven_key") private var elevenKey = ""
    @AppStorage("voice_speed") private var voiceSpeed = 1.15
    @AppStorage("briefing_enabled") private var briefingOn = false
    @AppStorage("briefing_minutes") private var briefingMinutes = 420
    @Environment(\.dismiss) private var dismiss

    private var briefingTime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: briefingMinutes / 60, minute: briefingMinutes % 60, second: 0, of: Date()) ?? Date()
        } set: { newDate in
            let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
            briefingMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
        }
    }

    @MainActor private static let testBrain = JarvisBrain()
    private var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                if ($0.language == "en-GB") != ($1.language == "en-GB") { return $0.language == "en-GB" }
                return $0.name < $1.name
            }
    }

    private func qualityTag(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return " ★ Premium"
        case .enhanced: return " ✦ Enhanced"
        default: return ""
        }
    }

    private func testVoice() {
        Self.testBrain.stopSpeaking()
        Self.testBrain.speak("Good evening, sir. ECHO at your service — and might I say, everything is running beautifully.")
    }
    @State private var calendarStatus = ""
    @State private var brainStatus = ""
    @State private var memoryCount = (UserDefaults.standard.stringArray(forKey: "jarvis_memories") ?? []).count

    private func testBrainConnection() {
        brainStatus = "Testing..."
        Task {
            var request = URLRequest(url: JarvisBrain.api("/api/tags"))
            request.timeoutInterval = 8
            do {
                let (data, resp) = try await URLSession.shared.data(for: request)
                if (resp as? HTTPURLResponse)?.statusCode == 200,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = obj["models"] as? [[String: Any]] {
                    brainStatus = "✓ Brain online — \(models.count) model(s) at \(JarvisBrain.ollamaBase)"
                } else {
                    brainStatus = "✗ Something answered, but it doesn't look like Ollama"
                }
            } catch {
                brainStatus = "✗ Can't reach \(JarvisBrain.ollamaBase) — check the address and that Tailscale is ON"
            }
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("CONNECTIONS")
                .font(.system(.headline, design: .monospaced))
                .foregroundColor(Theme.accent)
                .frame(maxWidth: .infinity)

            // AI server
            VStack(alignment: .leading, spacing: 6) {
                Label("AI Brain (Ollama server)", systemImage: "server.rack")
                    .foregroundColor(.white)
                HStack {
                    TextField("http://localhost:11434", text: $ollamaHost)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Button("Test") { testBrainConnection() }
                }
                if !brainStatus.isEmpty {
                    Text(brainStatus)
                        .font(.caption)
                        .foregroundColor(brainStatus.hasPrefix("✓") ? .green : .orange)
                }
                Text("Where the AI lives. Empty = this machine. Using \(JarvisBrain.ollamaBase)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Calendar
            VStack(alignment: .leading, spacing: 6) {
                Label("Google / Apple Calendar", systemImage: "calendar")
                    .foregroundColor(.white)
                Text("ECHO reads the Mac Calendar app — which includes Google Calendar once your Google account is added to this Mac.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                HStack {
                    Button("Grant Calendar Access") {
                        Task {
                            let ok = await CalendarService.shared.requestAccess()
                            calendarStatus = ok ? "✓ Calendar connected" : "✗ Denied — enable in System Settings → Privacy & Security → Calendars"
                        }
                    }
                    #if os(macOS)
                    Button("Add Google Account...") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    #endif
                }
                if !calendarStatus.isEmpty {
                    Text(calendarStatus)
                        .font(.caption)
                        .foregroundColor(calendarStatus.hasPrefix("✓") ? .green : .orange)
                }
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Schoology
            VStack(alignment: .leading, spacing: 6) {
                Label("Schoology", systemImage: "graduationcap")
                    .foregroundColor(.white)
                Text("Get your personal API key and secret at yourschool.schoology.com/api (log in first). Then ask ECHO: \"What's due on Schoology?\"")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                TextField("Consumer Key", text: $schoologyKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Consumer Secret", text: $schoologySecret)
                    .textFieldStyle(.roundedBorder)
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Gmail
            VStack(alignment: .leading, spacing: 6) {
                Label("Gmail", systemImage: "envelope")
                    .foregroundColor(.white)
                TextField("Gmail address", text: $gmailAddress)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                SecureField("16-character App Password", text: $gmailAppPassword)
                    .textFieldStyle(.roundedBorder)
                Text("Lets ECHO answer \"any new emails?\" (unread inbox only — it can't read full emails or send). Setup: your Google account needs 2-Step Verification ON, then create an App Password at the link below and paste it here.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Link("Open Google App Passwords page", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                    .font(.caption)
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Weather
            VStack(alignment: .leading, spacing: 6) {
                Label("Weather", systemImage: "cloud.sun")
                    .foregroundColor(.white)
                TextField("Home city (e.g. Boston)", text: $homeCity)
                    .textFieldStyle(.roundedBorder)
                Text("Used for \"what's the weather?\" and daily briefings.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Personality
            VStack(alignment: .leading, spacing: 6) {
                Label("Personality", systemImage: "theatermasks")
                    .foregroundColor(.white)
                Picker("", selection: $personality) {
                    Text("🎩 Classic").tag("Classic")
                    Text("😏 Sassy").tag("Sassy")
                    Text("🔥 Hype").tag("Hype")
                    Text("🧘 Zen").tag("Zen")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Classic is the dry British butler. Sassy roasts you lovingly. Hype is your personal coach. Zen keeps it calm.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Morning briefing
            VStack(alignment: .leading, spacing: 6) {
                Label("Morning Briefing", systemImage: "sunrise")
                    .foregroundColor(.white)
                HStack {
                    Toggle("Brief me daily at", isOn: $briefingOn)
                    DatePicker("", selection: briefingTime, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .disabled(!briefingOn)
                }
                Text("At this time (or when the Mac wakes, if it was asleep) ECHO asks \"Ready for your briefing?\" — say yes and she delivers it. Skipped quietly if it's already past noon. ECHO must be running — it lives in your menu bar.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            .onChange(of: briefingOn) { BriefingScheduler.shared.reschedule() }
            .onChange(of: briefingMinutes) { BriefingScheduler.shared.reschedule() }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Voice
            VStack(alignment: .leading, spacing: 6) {
                Label("Voice", systemImage: "waveform")
                    .foregroundColor(.white)
                Picker("", selection: $ttsEngine) {
                    Text("Neural ★").tag("neural")
                    Text("ElevenLabs").tag("eleven")
                    Text("System").tag("system")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    Image(systemName: "tortoise.fill")
                        .foregroundColor(.white.opacity(0.4))
                    Slider(value: $voiceSpeed, in: 0.9...1.6, step: 0.05)
                    Image(systemName: "hare.fill")
                        .foregroundColor(.white.opacity(0.4))
                    Text(String(format: "%.2fx", voiceSpeed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .frame(width: 44)
                }

                if ttsEngine == "neural" {
                    HStack {
                        Picker("", selection: $kokoroVoice) {
                            Text("Emma — warm British (FRIDAY)").tag("bf_emma")
                            Text("Isabella — bright British").tag("bf_isabella")
                            Text("George — deep British (JARVIS)").tag("bm_george")
                            Text("Lewis — British").tag("bm_lewis")
                            Text("Sarah — American").tag("af_sarah")
                            Text("Michael — American").tag("am_michael")
                        }
                        .labelsHidden()
                        Button("Test") { testVoice() }
                    }
                    Text("Movie-quality AI voice generated on your Mac (port 8880). Fully offline. Falls back to System voice if the voice server isn't running.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                } else if ttsEngine == "eleven" {
                    HStack {
                        SecureField("ElevenLabs API key", text: $elevenKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Test") { testVoice() }
                    }
                    Text("Hollywood-grade cloud voices. Free key at elevenlabs.io (10k characters/month free). Needs internet.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    HStack {
                        Picker("", selection: $voiceID) {
                            Text("Auto (best British)").tag("")
                            ForEach(englishVoices, id: \.identifier) { v in
                                Text("\(v.name)\(qualityTag(v)) — \(v.language)").tag(v.identifier)
                            }
                        }
                        .labelsHidden()
                        Button("Test") { testVoice() }
                    }
                    Text("Built-in voices. For better ones: System Settings → Accessibility → Spoken Content → Manage Voices → download a Premium English (UK) voice.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Music player
            VStack(alignment: .leading, spacing: 6) {
                Label("Music Player", systemImage: "music.note")
                    .foregroundColor(.white)
                Picker("", selection: $musicPlayer) {
                    Text("Auto (Spotify if running)").tag("Auto")
                    Text("Spotify").tag("Spotify")
                    Text("Apple Music").tag("Music")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("\"Echo, play some music\" controls this player.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Memory
            VStack(alignment: .leading, spacing: 6) {
                Label("Memory", systemImage: "brain")
                    .foregroundColor(.white)
                HStack {
                    Text("\(memoryCount) saved fact\(memoryCount == 1 ? "" : "s") — say \"Echo, remember...\" to add more.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Button("Forget all") {
                        UserDefaults.standard.removeObject(forKey: "jarvis_memories")
                        memoryCount = 0
                    }
                    .disabled(memoryCount == 0)
                }
            }

            Divider().overlay(Theme.accent.opacity(0.3))

            // Cal AI note
            VStack(alignment: .leading, spacing: 6) {
                Label("Calorie Tracking", systemImage: "flame")
                    .foregroundColor(.white)
                Text("Cal AI has no public API, so ECHO has its own tracker. Say what you ate, or snap a photo with the camera button, and it estimates and logs the calories. Tap the flame in the header for today's totals.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
            }
        }
        .padding(20)
        }
        .frame(minWidth: 340, idealWidth: 420, idealHeight: 700)
        .background(Color.black)
    }
}

// MARK: - Siri & Shortcuts (App Intents)
struct AskEchoIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask ECHO"
    static let description = IntentDescription("Ask ECHO anything — it can check your calendar, weather, Schoology, log food, and more.")

    @Parameter(title: "Question", requestValueDialog: "What shall I ask ECHO?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let brain = JarvisBrain()
        let reply = await brain.answerQuietly(prompt)
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

struct EchoBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "ECHO Briefing"
    static let description = IntentDescription("Weather, calendar, Schoology, and nutrition in one rundown.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let brain = JarvisBrain()
        let reply = await brain.answerQuietly("Give me my daily briefing")
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

struct LogWaterIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Water"
    static let description = IntentDescription("Log water to ECHO's hydration tracker.")

    @Parameter(title: "Ounces", default: 8)
    var ounces: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NutritionStore.shared.addWater(ounces)
        return .result(dialog: IntentDialog(stringLiteral: "Logged \(Int(ounces)) ounces, sir. \(Int(NutritionStore.shared.todayWater)) oz total today."))
    }
}

struct EchoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskEchoIntent(),
                    phrases: ["Ask \(.applicationName)"],
                    shortTitle: "Ask ECHO",
                    systemImageName: "waveform.circle.fill")
        AppShortcut(intent: EchoBriefingIntent(),
                    phrases: ["\(.applicationName) briefing", "Get my \(.applicationName) briefing"],
                    shortTitle: "Briefing",
                    systemImageName: "sun.max.fill")
        AppShortcut(intent: LogWaterIntent(),
                    phrases: ["Log water in \(.applicationName)"],
                    shortTitle: "Log Water",
                    systemImageName: "drop.fill")
    }
}

// MARK: - Morning briefing scheduler
class BriefingScheduler {
    static let shared = BriefingScheduler()
    var onFire: (() -> Void)?
    private var task: Task<Void, Never>?

    func reschedule() {
        task?.cancel()
        guard UserDefaults.standard.bool(forKey: "briefing_enabled") else { return }
        let minutes = UserDefaults.standard.object(forKey: "briefing_minutes") as? Int ?? 420
        task = Task {
            while !Task.isCancelled {
                let delay = nextFire(minutes).timeIntervalSinceNow
                try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                onFire?()
                try? await Task.sleep(nanoseconds: 90 * 1_000_000_000) // don't double-fire
            }
        }
    }

    private func nextFire(_ minutes: Int) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        comps.second = 0
        var date = cal.date(from: comps) ?? Date().addingTimeInterval(3600)
        if date <= Date() { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }
}

// MARK: - Menu bar mini-ECHO
struct MenuBarView: View {
    @ObservedObject var nutrition = NutritionStore.shared
    @ObservedObject var timers = TimerManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open ECHO") {
            openWindow(id: "main")
            #if canImport(AppKit)
            NSApp.activate(ignoringOtherApps: true)
            #endif
        }
        Divider()
        Text("Calories: \(Int(nutrition.todayCalories)) / \(Int(nutrition.goal)) kcal")
        Text("Water: \(Int(nutrition.todayWater)) oz")
        Button("Log 8 oz water") { nutrition.addWater(8) }
        if let timer = timers.timers.first {
            Divider()
            Text("Timer running until \(timer.end.formatted(date: .omitted, time: .shortened))")
            Button("Cancel timer") { timers.cancelAll() }
        }
        Divider()
        Button("Quit ECHO") {
            #if canImport(AppKit)
            NSApp.terminate(nil)
            #endif
        }
    }
}

// MARK: - Main view
struct ContentView: View {
    @StateObject private var brain = JarvisBrain()
    @StateObject private var voice = VoiceListener()
    @ObservedObject private var nutrition = NutritionStore.shared
    @ObservedObject private var timerMgr = TimerManager.shared
    @State private var input = ""
    @State private var handsFree = false
    @State private var awaitingCommand = false
    @State private var showSettings = false
    @State private var showNutrition = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var isDropTargeted = false
    @FocusState private var inputFocused: Bool

    private var reactorMode: ArcReactor.Mode {
        if brain.isThinking { return .thinking }
        if voice.isListening { return .listening }
        if brain.isSpeaking { return .speaking }
        return .idle
    }

    private var statusText: String {
        if brain.isThinking { return "PROCESSING" }
        if voice.isListening { return handsFree && !awaitingCommand ? "STANDING BY — SAY \"ECHO\"" : "LISTENING" }
        if brain.isSpeaking { return "SPEAKING" }
        return "ONLINE"
    }

    private var statusColor: Color {
        if brain.isThinking { return .orange }
        if voice.isListening { return Theme.good }
        return .green
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.accent.opacity(0.3))
                chatArea
                if brain.messages.count <= 1 { quickActions }
                inputBar
            }

            if voice.isListening && !voice.transcript.isEmpty {
                VStack {
                    Spacer()
                    Text(voice.transcript)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(Theme.accent)
                        .padding()
                        .background(Color.black.opacity(0.85))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.4)))
                        .cornerRadius(12)
                        .padding(.bottom, 90)
                }
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.accent, lineWidth: 2)
                    .background(Theme.accent.opacity(0.08).cornerRadius(16))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 40))
                            Text("Drop a food photo — I'll estimate the calories")
                                .font(.system(.body, design: .monospaced))
                        }
                        .foregroundColor(Theme.accent)
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: wireUp)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: $showNutrition) { NutritionSheet() }
        .sheet(isPresented: $showCamera) { CameraSheet { data in brain.analyzeFoodPhoto(data) } }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { brain.analyzeFoodPhoto(data) }
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url = item as? URL
                    if url == nil, let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    }
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in brain.analyzeFoodPhoto(data) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in brain.analyzeFoodPhoto(data) }
                }
                return true
            }
        }
        return false
    }

    // MARK: Background
    private var background: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Canvas { ctx, size in
                var grid = Path()
                let step: CGFloat = 44
                var x: CGFloat = 0
                while x <= size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y <= size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(grid, with: .color(Theme.accent.opacity(0.05)), lineWidth: 1)
            }
            .ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.06), .clear],
                           center: .top, startRadius: 0, endRadius: 500)
                .ignoresSafeArea()
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 14) {
            ArcReactor(mode: reactorMode, level: voice.level)
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text("E.C.H.O.")
                    .font(.system(.title2, design: .monospaced).bold())
                    .foregroundColor(Theme.accent)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                        .shadow(color: statusColor, radius: 4)
                    Text(statusText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(statusColor)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 10) {
                    if let timer = timerMgr.timers.first {
                        TimelineView(.periodic(from: .now, by: 1)) { tl in
                            let remain = max(0, timer.end.timeIntervalSince(tl.date))
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                Text(String(format: "%d:%02d", Int(remain) / 60, Int(remain) % 60))
                                Button { timerMgr.cancelAll() } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.orange)
                        }
                    }
                    Button { brain.send("Give me my daily briefing") } label: {
                        Image(systemName: "sun.max.fill")
                            .foregroundColor(Theme.accent.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Daily briefing — weather, calendar, school, nutrition")
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text(tl.date.formatted(date: .omitted, time: .standard))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(Theme.accent)
                    }
                    Button { showNutrition = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill")
                            Text("\(Int(nutrition.todayCalories))")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(nutrition.todayCalories > nutrition.goal ? .orange : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Today's calories — click for details")
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(Theme.accent.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Connections & settings")
                }
                HStack(spacing: 10) {
                    if !brain.lastStats.isEmpty { Text(brain.lastStats) }
                    Menu {
                        Picker("Model", selection: $brain.model) {
                            ForEach(brain.availableModels.isEmpty ? [brain.model] : brain.availableModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "cpu")
                            Text(brain.model.replacingOccurrences(of: ":latest", with: ""))
                        }
                    }                    .fixedSize()
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(Theme.accent.opacity(0.7))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: Chat
    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(brain.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                    if let activity = brain.toolActivity {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.2.fill")
                            Text(activity)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.orange)
                    } else if brain.isThinking && brain.messages.last?.isUser == true {
                        HStack(spacing: 4) {
                            Text("Processing")
                            TimelineView(.periodic(from: .now, by: 0.4)) { tl in
                                Text(String(repeating: ".", count: Int(tl.date.timeIntervalSinceReferenceDate / 0.4) % 4))
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.orange)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .onChange(of: brain.messages.count) {
                withAnimation { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            .onChange(of: brain.messages.last?.text) {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
            }
        }
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.isUser { Spacer(minLength: 60) }
            VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 4) {
                Text(msg.isUser ? "YOU" : "ECHO")
                    .font(.system(size: 9, design: .monospaced).bold())
                    .foregroundColor(msg.isUser ? Theme.accent.opacity(0.6) : Theme.accent)
                #if canImport(AppKit)
                if let imageData = msg.imageData, let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 160)
                        .clipped()
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.3)))
                }
                #elseif canImport(UIKit)
                if let imageData = msg.imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 160)
                        .clipped()
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.3)))
                }
                #endif
                Text(rendered(msg.text + (streamingCursor(for: msg) ? " ▌" : "")))
                    .textSelection(.enabled)
                    .padding(12)
                    .background(msg.isUser ? Theme.accent.opacity(0.18) : Color.white.opacity(0.07))
                    .foregroundColor(.white)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(msg.isUser ? Theme.accent.opacity(0.35) : Color.white.opacity(0.12)))
                    .cornerRadius(14)
                Text(msg.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
            if !msg.isUser { Spacer(minLength: 60) }
        }
        .contextMenu {
            Button("Copy") {
                #if canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(msg.text, forType: .string)
                #elseif canImport(UIKit)
                UIPasteboard.general.string = msg.text
                #endif
            }
            if !msg.isUser {
                Button("Read aloud") { brain.speak(msg.text) }
            }
        }
    }

    private func streamingCursor(for msg: ChatMessage) -> Bool {
        brain.isThinking && !msg.isUser && msg.id == brain.messages.last?.id
    }

    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Quick actions
    private var quickActions: some View {
        HStack(spacing: 8) {
            ForEach(["Daily briefing", "What's the weather?", "Anything due on Schoology?", "Set a timer for 10 minutes"], id: \.self) { q in
                Button(q) { brain.send(q) }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.4)))
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Input bar
    private var inputBar: some View {
        HStack(spacing: 10) {
            Button {
                if voice.isListening {
                    let text = voice.transcript
                    voice.stop()
                    handsFree = false
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { brain.send(text) }
                } else {
                    handsFree = false
                    brain.stopSpeaking()
                    voice.start()
                }
            } label: {
                Image(systemName: voice.isListening && !handsFree ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(voice.isListening && !handsFree ? .red : Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Push to talk — click again to send")

            Button {
                handsFree.toggle()
                awaitingCommand = false
                if handsFree {
                    brain.stopSpeaking()
                    voice.start()
                } else {
                    voice.stop()
                }
            } label: {
                Image(systemName: handsFree ? "ear.fill" : "ear")
                    .font(.system(size: 22))
                    .foregroundColor(handsFree ? Theme.good : Theme.accent.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Hands-free mode — say \"Echo, ...\" any time")

            Menu {
                Button {
                    showCamera = true
                } label: {
                    Label("Scan food with camera", systemImage: "camera.fill")
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose a photo...", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.accent.opacity(0.8))
            }
            .fixedSize()
            .help("Snap or drop a food photo — ECHO estimates the calories")

            TextField("Speak or type, sir...", text: $input)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .padding(10)
                .background(Color.white.opacity(0.08))
                .foregroundColor(.white)
                .cornerRadius(10)
                .onSubmit { submit() }

            if brain.isThinking {
                Button { brain.stopGeneration() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Button {
                brain.voiceEnabled.toggle()
                if !brain.voiceEnabled { brain.stopSpeaking() }
            } label: {
                Image(systemName: brain.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 18))
                    .foregroundColor(brain.voiceEnabled ? Theme.accent : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Toggle voice output")

            Button { brain.clearChat() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding()
    }

    // MARK: Wiring for voice flow
    private func wireUp() {
        voice.onCommand = { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if handsFree {
                if awaitingCommand {
                    awaitingCommand = false
                    if !trimmed.isEmpty { brain.send(trimmed) } else { voice.start() }
                } else if let cmd = extractWakeCommand(from: trimmed) {
                    if cmd.count > 2 {
                        brain.send(cmd)
                    } else {
                        awaitingCommand = true
                        brain.speak("Yes, sir?")
                    }
                } else {
                    voice.start()
                }
            } else {
                if !trimmed.isEmpty { brain.send(trimmed) }
            }
        }
        brain.onReplyDone = {
            if handsFree && !brain.isThinking {
                voice.start()
            }
        }
        TimerManager.shared.onFire = { label in
            let msg = "Sir — your \(label.isEmpty ? "timer" : "\(label) timer") is up."
            brain.messages.append(ChatMessage(text: msg, isUser: false))
            brain.speak(msg)
        }
        BriefingScheduler.shared.onFire = {
            // If we're catching up after noon (Mac was asleep all morning), skip quietly.
            guard Calendar.current.component(.hour, from: Date()) < 12 else { return }
            SystemTools.notify(title: "E.C.H.O.", body: "Ready for your briefing, sir?")
            brain.offerBriefing()
        }
        BriefingScheduler.shared.reschedule()
    }

    private func extractWakeCommand(from text: String) -> String? {
        let lower = text.lowercased()
        guard let r = lower.range(of: "echo") else { return nil }
        let after = String(text[r.upperBound...])
        return after.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        brain.send(text)
    }
}

#Preview {
    ContentView()
}
