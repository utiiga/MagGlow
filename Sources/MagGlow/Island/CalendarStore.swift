import AppKit
import EventKit
import SwiftUI

/// Today's and the coming days' events for the island, read with EventKit.
@MainActor
final class CalendarStore: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date
        let allDay: Bool
        let color: NSColor
        let birthday: Bool
    }

    struct Day: Identifiable {
        let date: Date
        let items: [Item]
        var id: Date { date }
    }

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var today: [Item] = []
    @Published private(set) var upcoming: [Day] = []

    private let store = EKEventStore()

    init() {
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Called each time the island opens: asks for access the first time,
    /// then refreshes the events.
    func refresh() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in
                    self?.access = Self.currentAccess()
                    self?.reload()
                }
            }
        default:
            access = Self.currentAccess()
            reload()
        }
    }

    func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    private func reload() {
        guard access == .granted else {
            today = []
            upcoming = []
            return
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: start),
              let end = cal.date(byAdding: .day, value: 8, to: start) else { return }

        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }

        func item(_ e: EKEvent) -> Item {
            Item(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                 title: e.title ?? "",
                 start: e.startDate,
                 allDay: e.isAllDay,
                 color: e.calendar.color ?? .systemBlue,
                 birthday: e.calendar.type == .birthday)
        }

        today = events.filter { $0.startDate < tomorrow && $0.endDate > Date() }.map(item)

        var days: [Date: [Item]] = [:]
        for e in events where e.startDate >= tomorrow {
            days[cal.startOfDay(for: e.startDate), default: []].append(item(e))
        }
        upcoming = days.keys.sorted().map { Day(date: $0, items: days[$0]!) }
    }
}
