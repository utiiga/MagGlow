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
        /// Whether today is a workday by the work calendar; nil when the
        /// server doesn't know (or is older and doesn't say).
        var toca_fichar: Bool?
    }

    @Published private(set) var connected = false
    @Published private(set) var estado: Estado?
    @Published private(set) var busy = false
    /// The last problem talking to the server, in words to show.
    @Published private(set) var error: String?
    /// A workday to keep in view: clocked in, paused before the day's hours
    /// are done, or not started yet on a day you are due to work. Worth a
    /// live activity on the island, to start or resume it from there.
    @Published private(set) var live = false

    /// A workday today, not started yet.
    var notStarted: Bool {
        guard let estado else { return false }
        return estado.primera_entrada == nil && estado.toca_fichar == true
    }

    /// Started today but clocked out before finishing the day's hours.
    var paused: Bool {
        guard let estado else { return false }
        return !estado.dentro && estado.primera_entrada != nil
    }

    /// When `estado` arrived, to keep the clock running between refreshes.
    private var fetchedAt = Date()
    private var poll: Timer?

    /// The server's address, as given when connecting.
    private var host: String? {
        UserDefaults.standard.string(forKey: "fichajeHost")
    }

    /// `-FichajePreview pendiente` shows a sample day you are due to work
    /// and haven't started, without talking to the server: to check the look.
    private let preview = UserDefaults.standard.string(forKey: "FichajePreview") == "pendiente"

    init() {
        if preview {
            connected = true
            apply(Estado(dentro: false, siguiente_sentido: "entrada", primera_entrada: nil, minutos_trabajados: 0,
                         horas_requeridas: 8, salida_prevista: nil, titulo: "Iniciar jornada",
                         subtitulo: "Haz click para empezar", boton: "Fichar entrada", toca_fichar: true))
            return
        }
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
        guard connected, !preview, let token = Keychain.token else { return }
        Task {
            if let estado: Estado = await request("GET", "estado", token: token) { apply(estado) }
        }
    }

    /// Clocks in or out, whichever is next; the server stamps the time.
    func marcar() {
        guard connected, !busy, !preview, let token = Keychain.token else { return }
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
        let pending = estado.primera_entrada != nil
            && estado.minutos_trabajados < Int((estado.horas_requeridas * 60).rounded())
        let due = estado.primera_entrada == nil && estado.toca_fichar == true
        let underWay = estado.dentro || pending || due
        if live != underWay { live = underWay }
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

    static let wings = IslandModel.Wings(left: 46, right: 46)

    var body: some View {
        WingsLayout(wings: wings, notch: notch) {
            if fichaje.notStarted {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(HubColor.orange)
                    .transition(.blurFade)
            } else if fichaje.paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(HubColor.orange)
                    .transition(.blurFade)
            } else {
                LiveDot().transition(.blurFade)
            }
        } right: {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(Fichaje.hm(fichaje.minutesWorked(at: context.date)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(fichaje.paused || fichaje.notStarted ? 0.5 : 1))
                    .contentTransition(.numericText())
            }
        }
    }
}

/// An orange dot breathing, like a recording light: the workday is running.
private struct LiveDot: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(HubColor.orange.opacity(0.4)).frame(width: 15, height: 15)
                .scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 1)
            Circle().fill(HubColor.orange).frame(width: 8, height: 8)
                .shadow(color: HubColor.orange.opacity(0.7), radius: 3)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true }
        }
    }

}

/// The open island's workday page, laid out like the hub's own dashboard
/// card: the state with its dot, the last clock-in and the button on the
/// left; an arc from the first clock-in to the expected end on the right,
/// with the time worked inside. Everything starts below the notch.
struct FichajeView: View {
    @ObservedObject var fichaje: Fichaje
    @ObservedObject var island: IslandModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let estado = fichaje.estado
            let dentro = estado?.dentro ?? false
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Text(estado?.titulo ?? String(localized: "Workday"))
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Circle()
                            .fill(dentro ? HubColor.orange : .white.opacity(0.3))
                            .frame(width: 10, height: 10)
                            .shadow(color: dentro ? HubColor.orange.opacity(0.6) : .clear, radius: 4)
                    }
                    Text(detail)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(fichaje.error == nil ? .white.opacity(0.45) : Color(red: 1, green: 0.45, blue: 0.4))
                        .lineLimit(2)
                        .padding(.top, 4)
                    Spacer(minLength: 10)
                    Button(action: fichaje.marcar) {
                        HStack(spacing: 8) {
                            if fichaje.busy {
                                ProgressView().controlSize(.small).tint(HubColor.light)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: dentro ? "stop.circle" : "play.circle")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text(estado?.boton ?? String(localized: "Clock in"))
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundStyle(HubColor.light)
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(Capsule().fill(HubColor.orange.opacity(0.2)))
                        .overlay(Capsule().strokeBorder(HubColor.orange.opacity(0.4)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressButton())
                    .disabled(fichaje.busy || estado == nil)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 0)

                WorkdayArc(progress: fichaje.progress(at: context.date),
                           worked: fichaje.minutesWorked(at: context.date),
                           start: estado?.primera_entrada,
                           end: estado?.salida_prevista,
                           active: dentro)
            }
            .padding(.top, island.notch.height + 8)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    private var detail: String {
        if let error = fichaje.error { return error }
        guard let estado = fichaje.estado else { return "" }
        if let subtitulo = estado.subtitulo, !subtitulo.isEmpty { return subtitulo }
        if let salida = estado.salida_prevista { return String(localized: "Expected out \(salida)") }
        return ""
    }
}

/// The hub's accent.
enum HubColor {
    static let orange = Color(red: 0.88, green: 0.56, blue: 0.19)
    /// For text and icons on an orange tint.
    static let light = Color(red: 0.99, green: 0.76, blue: 0.47)
}

/// Shrinks a little while pressed.
private struct PressButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// The day as an open arc, three quarters of a circle with the gap at the
/// bottom: it fills from the first clock-in towards the expected end, with
/// the time worked in the middle and both times under the arc's ends.
private struct WorkdayArc: View {
    let progress: Double
    let worked: Int
    let start: String?
    let end: String?
    let active: Bool

    private static let sweep = 0.75
    private let size: CGFloat = 92
    private let line: CGFloat = 8

    var body: some View {
        VStack(spacing: -6) {
            ZStack {
                arc(to: Self.sweep).stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: line, lineCap: .round))
                arc(to: Self.sweep * min(max(progress, 0), 1))
                    .stroke(active ? HubColor.orange : .white.opacity(0.45),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .shadow(color: active ? HubColor.orange.opacity(0.35) : .clear, radius: 4)
                Text(String(format: "%02d:%02d", max(worked, 0) / 60, max(worked, 0) % 60))
                    .font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.6), value: progress)

            HStack {
                Text(start ?? "--:--")
                Spacer(minLength: 0)
                Text(end ?? "--:--")
            }
            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.4))
            .frame(width: size + 6)
        }
    }

    /// The arc from its start (bottom left) to `fraction` of a full turn.
    private func arc(to fraction: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: fraction)
            .rotation(.degrees(135))
    }
}
