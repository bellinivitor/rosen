import AppKit
import Foundation
import LocalAuthentication
import Observation

/// Portão de presença do usuário: Touch ID quando houver, senha do Mac quando não houver.
/// Depois de liberar, vale por um período e é revogado quando o Mac bloqueia ou dorme.
@MainActor
@Observable
final class Unlocker {
    static let shared = Unlocker()

    enum Method { case touchID, password }

    /// Até quando o desbloqueio vale. `nil` = bloqueado.
    private(set) var unlockedUntil: Date?

    @ObservationIgnored private var pending: Task<Bool, Never>?

    /// Opções de "pedir de novo depois de" (minutos; -1 = até bloquear o Mac).
    static let graceOptions: [(minutes: Int, title: String)] = [
        (0, "Toda vez"), (5, "5 minutos"), (15, "15 minutos"), (60, "1 hora"), (-1, "Até bloquear o Mac"),
    ]
    static let graceKey = "unlockGraceMinutes"

    private init() {
        let lock: @Sendable (Notification) -> Void = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Unlocker.shared.lock() } }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock)
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock)
    }

    nonisolated static var method: Method {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) ? .touchID : .password
    }

    /// "Touch ID" ou "senha do Mac".
    nonisolated static var methodName: String { method == .touchID ? "Touch ID" : "senha do Mac" }
    nonisolated static var symbol: String { method == .touchID ? "touchid" : "lock.fill" }

    var isUnlocked: Bool {
        guard let until = unlockedUntil else { return false }
        return until > Date()
    }

    func lock() { unlockedUntil = nil }

    /// Pede Touch ID/senha. Chamadas simultâneas compartilham o mesmo pedido
    /// (ex.: "Conectar todos" ou vários túneis com "conectar ao abrir").
    func authorize(reason: String) async -> Bool {
        if isUnlocked { return true }
        if let pending { return await pending.value }

        let task = Task { @MainActor () -> Bool in
            let context = LAContext()
            context.localizedCancelTitle = "Cancelar"
            NSApp.activate(ignoringOtherApps: true)
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }
        pending = task
        let ok = await task.value
        pending = nil

        if ok {
            let minutes = UserDefaults.standard.object(forKey: Self.graceKey) as? Int ?? 15
            // Mesmo em "toda vez", alguns segundos cobrem ações em lote.
            unlockedUntil = minutes < 0 ? .distantFuture : Date().addingTimeInterval(max(4, Double(minutes) * 60))
        }
        return ok
    }
}
