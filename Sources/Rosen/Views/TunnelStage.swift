import RosenCore
import SwiftUI

/// O túnel desenhado: três portais ligados por um tubo por onde passam pacotes.
/// É a peça central da identidade visual do Rosen.
struct TunnelStage: View {
    enum Style { case hero, compact }

    let tunnel: Tunnel
    let status: TunnelSession.Status
    var style: Style = .hero
    /// Prévia (editor): pinta com a cor do túnel, sem movimento.
    var preview = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case flowing, seeking, broken, still, preview }

    private var phase: Phase {
        switch status {
        case .connected: return .flowing
        case .unlocking, .prompting, .connecting, .waiting: return .seeking
        case .failed: return .broken
        case .idle: return preview ? .preview : .still
        }
    }

    private var tint: Color {
        switch phase {
        case .flowing, .preview: return tunnel.tag.color
        case .seeking: return (status == .unlocking || status == .prompting) ? .indigo : .orange
        case .broken: return .red
        case .still: return .secondary
        }
    }

    private var animates: Bool {
        !reduceMotion && (phase == .flowing || phase == .seeking)
    }

    private var tubeHeight: CGFloat { style == .hero ? 14 : 10 }
    private var portalSize: CGFloat { style == .hero ? 54 : 38 }

    var body: some View {
        let ends = endpoints
        VStack(spacing: style == .hero ? 12 : 8) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !animates)) { context in
                    Canvas { g, size in
                        draw(&g, size: size, time: animates ? context.date.timeIntervalSinceReferenceDate : 0)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(ends.indices, id: \.self) { i in
                        Portal(icon: ends[i].icon, tint: tint, lit: phase == .flowing || phase == .preview,
                               size: portalSize, hub: i == 1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: portalSize + 8)

            HStack(alignment: .top, spacing: 0) {
                ForEach(ends.indices, id: \.self) { i in
                    EndLabel(end: ends[i], style: style, emphasized: i != 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Desenho do tubo

    private func draw(_ g: inout GraphicsContext, size: CGSize, time: Double) {
        let x0 = size.width / 6, x1 = size.width * 5 / 6, y = size.height / 2
        let t = tubeHeight
        let tube = Path(roundedRect: CGRect(x: x0, y: y - t / 2, width: x1 - x0, height: t), cornerRadius: t / 2)

        let base: Double = phase == .still ? 0.10 : 0.16
        g.fill(tube, with: .color(tint.opacity(base)))
        g.stroke(tube, with: .color(tint.opacity(phase == .still ? 0.18 : 0.35)), lineWidth: 0.75)

        switch phase {
        case .flowing, .preview:
            g.drawLayer { layer in
                layer.clip(to: tube)
                // brilho por trás
                layer.drawLayer { glow in
                    glow.addFilter(.blur(radius: t * 0.35))
                    drawPackets(&glow, x0: x0, x1: x1, y: y, time: time, alpha: 0.9)
                }
                drawPackets(&layer, x0: x0, x1: x1, y: y, time: time, alpha: 1)
            }
        case .seeking:
            let period = 1.5
            let p = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
            let len = x1 - x0
            let head = x0 + p * (len + 90) - 20
            let comet = CGRect(x: head - 70, y: y - t / 2, width: 70, height: t)
            g.drawLayer { layer in
                layer.clip(to: tube)
                layer.fill(Path(comet), with: .linearGradient(
                    Gradient(colors: [tint.opacity(0), tint.opacity(0.85)]),
                    startPoint: CGPoint(x: comet.minX, y: y), endPoint: CGPoint(x: comet.maxX, y: y)))
            }
        case .broken:
            // rachadura no meio do segundo trecho
            let cx = size.width * 2 / 3, h = t * 0.9
            var crack = Path()
            crack.move(to: CGPoint(x: cx - 3, y: y - h))
            crack.addLine(to: CGPoint(x: cx + 2, y: y - 1))
            crack.addLine(to: CGPoint(x: cx - 2, y: y + 1))
            crack.addLine(to: CGPoint(x: cx + 3, y: y + h))
            g.stroke(crack, with: .color(.red), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .still:
            var line = Path()
            line.move(to: CGPoint(x: x0 + 8, y: y))
            line.addLine(to: CGPoint(x: x1 - 8, y: y))
            g.stroke(line, with: .color(.secondary.opacity(0.35)),
                     style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 6]))
        }
    }

    /// Ida (maiores, em cima) e volta (menores, embaixo): o túnel é uma via de mão dupla.
    private func drawPackets(_ g: inout GraphicsContext, x0: CGFloat, x1: CGFloat, y: CGFloat, time: Double, alpha: Double) {
        let t = tubeHeight
        let lanes: [(spacing: CGFloat, speed: CGFloat, width: CGFloat, height: CGFloat, dy: CGFloat, dir: CGFloat, opacity: Double)] = [
            (34, 52, t * 0.75, t * 0.26, -t * 0.17, 1, 1),
            (47, 34, t * 0.45, t * 0.2, t * 0.2, -1, 0.55),
        ]
        for lane in lanes {
            let shift = CGFloat(time) * lane.speed
            let offset = shift.truncatingRemainder(dividingBy: lane.spacing)
            var x = x0 - lane.spacing + (lane.dir > 0 ? offset : lane.spacing - offset)
            while x < x1 + lane.spacing {
                let rect = CGRect(x: x - lane.width / 2, y: y + lane.dy - lane.height / 2, width: lane.width, height: lane.height)
                g.fill(Path(roundedRect: rect, cornerRadius: lane.height / 2),
                       with: .color(tint.opacity(lane.opacity * alpha)))
                x += lane.spacing
            }
        }
    }

    // MARK: Pontas

    struct End {
        let icon: String
        let headline: String
        let caption: String
        var detail: String?
    }

    private var endpoints: [End] {
        let server = tunnel.host.isEmpty ? "servidor" : tunnel.host
        switch tunnel.kind {
        case .local:
            return [
                End(icon: "laptopcomputer", headline: ":\(tunnel.listenPort)", caption: "Seu Mac",
                    detail: SSHCommand.isLoopback(tunnel.bindAddress) ? nil : tunnel.bindAddress),
                End(icon: "server.rack", headline: server, caption: "via SSH"),
                End(icon: tunnel.targetSymbol, headline: ":\(tunnel.targetPort)", caption: tunnel.serviceName ?? "Destino",
                    detail: tunnel.targetHost),
            ]
        case .remote:
            return [
                End(icon: "server.rack", headline: ":\(tunnel.listenPort)", caption: server),
                End(icon: "laptopcomputer", headline: "Seu Mac", caption: "via SSH"),
                End(icon: tunnel.targetSymbol, headline: ":\(tunnel.targetPort)", caption: tunnel.serviceName ?? "Destino",
                    detail: tunnel.targetHost),
            ]
        case .dynamic:
            return [
                End(icon: "laptopcomputer", headline: ":\(tunnel.listenPort)", caption: "Proxy SOCKS5"),
                End(icon: "server.rack", headline: server, caption: "via SSH"),
                End(icon: "globe", headline: "Rede", caption: "do servidor"),
            ]
        }
    }

    private var accessibilityText: String {
        let e = endpoints
        return "\(status.label). \(e[0].caption) \(e[0].headline), \(e[1].caption) \(e[1].headline), \(e[2].caption) \(e[2].headline)."
    }
}

private struct Portal: View {
    let icon: String
    let tint: Color
    let lit: Bool
    let size: CGFloat
    let hub: Bool

    var body: some View {
        ZStack {
            // "boca" do túnel: fundo opaco para o tubo parecer entrar no portal
            Circle().fill(Color(nsColor: .controlBackgroundColor))
            Circle().fill(lit ? tint.opacity(0.14) : Color.primary.opacity(0.04))
            Circle().strokeBorder(lit ? tint.opacity(0.9) : Color.primary.opacity(0.14), lineWidth: lit ? 1.5 : 1)
            if hub {
                Circle()
                    .strokeBorder(lit ? tint.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
                    .padding(size * 0.12)
            }
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(lit ? tint : Color.secondary)
        }
        .frame(width: size, height: size)
        .shadow(color: lit ? tint.opacity(0.35) : .clear, radius: size * 0.18)
    }
}

private struct EndLabel: View {
    let end: TunnelStage.End
    let style: TunnelStage.Style
    let emphasized: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(end.headline)
                .font(.system(size: size, weight: emphasized ? .semibold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasized ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
                .textSelection(.enabled)
            Text(end.caption)
                .font(style == .hero ? .callout : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if style == .hero, let detail = end.detail, !detail.isEmpty, detail != "127.0.0.1", detail != "localhost" {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
    }

    private var size: CGFloat {
        switch style {
        case .hero: return emphasized ? 26 : 15
        case .compact: return emphasized ? 17 : 12
        }
    }
}

/// Fundo do palco: superfície com um leve banho da cor do túnel e os arcos do ícone.
struct RosenBackdrop: View {
    let color: Color
    var radius: CGFloat = 20

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                LinearGradient(colors: [color.opacity(scheme == .dark ? 0.20 : 0.11), color.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(shape)
            }
            .overlay {
                Canvas { g, size in
                    let center = CGPoint(x: size.width / 2, y: size.height + size.height * 0.15)
                    for i in 0..<5 {
                        let r = size.height * (0.55 + CGFloat(i) * 0.32)
                        var arc = Path()
                        arc.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                        g.stroke(arc, with: .color(color.opacity(scheme == .dark ? 0.08 : 0.055)), lineWidth: 1)
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(color.opacity(scheme == .dark ? 0.25 : 0.18), lineWidth: 0.75))
    }
}

/// Botão principal em pílula: preenchido com a cor do túnel para ligar, neutro para desligar.
struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(filled ? Color.white : Color.primary)
            .background {
                Capsule().fill(filled ? AnyShapeStyle(fill.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
            }
            .overlay(Capsule().strokeBorder(filled ? Color.white.opacity(0.18) : Color.primary.opacity(0.10), lineWidth: 0.75))
            .shadow(color: filled ? fill.opacity(0.35) : .clear, radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
