import SwiftUI

/// A marca do Rosen na barra de menus e nos estados vazios: um caminho entre dois pontos
/// (SF Symbol nativo). Vazado quando desligado, preenchido com túnel ativo, esmaecido conectando.
enum RosenMark {
    enum State { case idle, busy, active }

    static func symbol(for state: State) -> String {
        state == .active
            ? "point.topleft.down.to.point.bottomright.curvepath.fill"
            : "point.topleft.down.to.point.bottomright.curvepath"
    }
}

struct RosenMarkView: View {
    var state: RosenMark.State = .idle
    /// Tamanho do símbolo em pontos; `nil` usa o tamanho padrão (barra de menus).
    var size: CGFloat?

    var body: some View {
        Image(systemName: RosenMark.symbol(for: state))
            .font(size.map { .system(size: $0, weight: .regular) } ?? .body)
            .opacity(state == .busy ? 0.5 : 1)
            .accessibilityLabel("Rosen")
    }
}
