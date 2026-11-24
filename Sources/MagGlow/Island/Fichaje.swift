import AppKit
import Security
import SwiftUI

/// Today's workday from a clock-in server's external API: whether you are
/// clocked in, how long you have worked, and a button to clock in or out.
///
/// It connects to the server address you give with your personal clock-in
/// token, kept in the Keychain. The server only ever shows and clocks the
/// token holder's own day.
@MainActor
final class Fichaje: ObservableObject {
    struct Estado: Decodable, Equatable {
        var dentro: Bool
        var siguiente_sentido: String
        var primera_entrada: String?
        var minutos_trabajados: Int
        var horas_requeridas: Double
        var salida_prevista: String?
        var titulo: String
        var subtitulo: String?
        var boton: String
    }

    @Published private(set) var connected = false
    @Published private(set) var estado: Estado?
    @Published private(set) var busy = false
    /// The last problem talking to the server, in words to show.
    @Published private(set) var error: String?
    /// Clocked in right now: worth a live activity on the island.
    @Published private(set) var live = false

    /// When `estado` arrived, to keep the clock running between refreshes.
    private var fetchedAt = Date()
    private var poll: Timer?

    /// The server's address, as given when connecting.
    private var host: String? {
        UserDefaults.standard.string(forKey: "fichajeHost")
    }

    init() {
        connected = Keychain.token != nil
        poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Minutes worked by `date`, counting on from the last refresh while in.
    func minutesWorked(at date: Date) -> Int {
        guard let estado else { return 0 }
        let running = estado.dentro ? Int(date.timeIntervalSince(fetchedAt) / 60) : 0
        return estado.minutos_trabajados + max(running, 0)
    }

    /// Share of today's required hours, 0…1 (can pass 1).
    func progress(at date: Date) -> Double {
        guard let estado, estado.horas_requeridas > 0 else { return 0 }
        return Double(minutesWorked(at: date)) / (estado.horas_requeridas * 60)
    }

    static func hm(_ minutes: Int) -> String {
        String(format: "%d:%02d", max(minutes, 0) / 60, max(minutes, 0) % 60)
    }

    // MARK: Connection

    /// Checks the address and token against the server and keeps them if
    /// they work.
    func connect(host: String, token: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let host = Self.normalized(host) else {
            error = String(localized: "Enter the server address and the token")
            return false
        }
        guard let estado: Estado = await request("GET", "estado", token: token, host: host) else { return false }
        UserDefaults.standard.set(host, forKey: "fichajeHost")
        Keychain.token = token
        connected = true
        apply(estado)
        return true
    }

    /// "hub.example.com" or "https://hub.example.com/" → "https://hub.example.com".
    /// Only HTTPS: the token must never travel in the clear.
    private static func normalized(_ host: String) -> String? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return text
    }

    func disconnect() {
        Keychain.token = nil
        UserDefaults.standard.removeObject(forKey: "fichajeHost")
        connected = false
        estado = nil
        error = nil
        live = false
    }

    // MARK: API

    func refresh() {
        guard connected, let token = Keychain.token else { return }
        Task {
            if let estado: Estado = await request("GET", "estado", token: token) { apply(estado) }
        }
    }

    /// Clocks in or out, whichever is next; the server stamps the time.
    func marcar() {
        guard connected, !busy, let token = Keychain.token else { return }
        busy = true
        Task {
            struct Respuesta: Decodable { var estado: Estado }
            let body = ["idempotency_key": UUID().uuidString.lowercased()]
            if let respuesta: Respuesta = await request("POST", "marcar", token: token, body: body) {
                apply(respuesta.estado)
            }
            busy = false
        }
    }

    private func apply(_ estado: Estado) {
        self.estado = estado
        fetchedAt = Date()
        error = nil
        if live != estado.dentro { live = estado.dentro }
    }

    private func request<T: Decodable>(_ method: String, _ path: String, token: String,
                                       body: [String: String]? = nil, host: String? = nil) async -> T? {
        guard let base = host ?? self.host, let url = URL(string: "\(base)/api/fichaje-externo/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                error = Self.message(status: status, data: data)
                if status == 401 { live = false } // token revoked or switched off
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            self.error = String(localized: "Can't reach the server")
            return nil
        }
    }

    /// The server's own message when it gives one (e.g. "wait a minute").
    private static func message(status: Int, data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = (json["message"] ?? json["detail"]) as? String, !text.isEmpty {
            return text
        }
        switch status {
        case 401: return String(localized: "The token isn't valid or is switched off")
        case 403: return String(localized: "The token can't clock in")
        case 429: return String(localized: "Too soon: try again in a moment")
        default: return String(localized: "The server returned an error (\(status))")
        }
    }
}

/// The token, in the login Keychain.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.magglow.fichaje",
        kSecAttrAccount as String: "token",
    ]

    static var token: String? {
        get {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

// MARK: - Views

/// The closed island while clocked in: a pulsing dot and the time worked.
struct CompactFichaje: View {
    @ObservedObject var fichaje: Fichaje
    let wings: IslandModel.Wings
    let notch: CGFloat

    static let wings = IslandModel.Wings(left: 56, right: 56)

    var body: some View {
        WingsLayout(wings: wings, notch: notch) {
            LiveDot()
        } right: {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(Fichaje.hm(fichaje.minutesWorked(at: context.date)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A green dot breathing, like a recording light: the workday is running.
private struct LiveDot: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(Self.green.opacity(0.35)).frame(width: 14, height: 14)
                .scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 1)
            Circle().fill(Self.green).frame(width: 7, height: 7)
                .shadow(color: Self.green.opacity(0.7), radius: 3)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true }
        }
    }

    static let green = Color(red: 0.35, green: 0.85, blue: 0.45)
}

/// The open island's workday page: state, time worked against the day's
/// hours, and the button to clock in or out. Everything starts below the
/// notch, which hides the top band in the middle.
struct FichajeView: View {
    @ObservedObject var fichaje: Fichaje
    @ObservedObject var island: IslandModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let estado = fichaje.estado
            let dentro = estado?.dentro ?? false
            let tint: Color = dentro ? Color(red: 0.35, green: 0.85, blue: 0.45) : .white.opacity(0.55)
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((estado?.titulo ?? String(localized: "Workday")).uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tint)
                        Text(Fichaje.hm(fichaje.minutesWorked(at: context.date)))
                            .font(.system(size: 34, weight: .regular).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ProgressRing(value: fichaje.progress(at: context.date), tint: tint)
                }
                Spacer(minLength: 10)
                HStack {
                    if let error = fichaje.error {
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                            .lineLimit(2)
                    } else if let salida = estado?.salida_prevista {
                        Text(String(localized: "Expected out \(salida)"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 8)
                    Button(action: fichaje.marcar) {
                        HStack(spacing: 6) {
                            if fichaje.busy {
                                ProgressView().controlSize(.mini).tint(.black)
                            }
                            Text(estado?.boton ?? String(localized: "Clock in"))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(dentro ? Color(red: 1, green: 0.42, blue: 0.4) : Color(red: 0.35, green: 0.85, blue: 0.45)))
                    }
                    .buttonStyle(.plain)
                    .disabled(fichaje.busy || estado == nil)
                }
            }
            .padding(.top, island.notch.height + 6)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
    }

    private var detail: String {
        guard let estado = fichaje.estado else { return fichaje.error ?? "" }
        if let subtitulo = estado.subtitulo, !subtitulo.isEmpty { return subtitulo }
        return String(localized: "Today's hours: \(Fichaje.hm(Int(estado.horas_requeridas * 60)))")
    }
}

/// Time worked against the day's hours, as a ring with the percentage.
private struct ProgressRing: View {
    let value: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.4), radius: 3)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 58, height: 58)
        .animation(.easeOut(duration: 0.6), value: value)
    }
}
