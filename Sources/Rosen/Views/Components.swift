import RosenCore
import SwiftUI

// MARK: - Cores e ícones

extension TagColor {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}

extension Tunnel {
    var symbol: String {
        switch kind {
        case .dynamic: return "globe"
        case .remote: return "arrow.uturn.left"
        case .local:
            switch ServiceCatalog.category(for: targetPort) {
            case .database: return "cylinder.split.1x2.fill"
            case .web: return "safari.fill"
            case .terminal: return "terminal.fill"
            case .desktop: return "display"
            case .generic: return "arrow.left.arrow.right"
            }
        }
    }

    var targetSymbol: String {
        switch ServiceCatalog.category(for: targetPort) {
        case .database: return "cylinder.split.1x2"
        case .web: return "safari"
        case .terminal: return "terminal"
        case .desktop: return "display"
        case .generic: return "shippingbox"
        }
    }
}

extension Credential {
    /// Ícone de cadeado/digital para credenciais protegidas.
    var protectionSymbol: String? { needsUnlock ? Unlocker.symbol : nil }
}

extension CredentialKind {
    var symbol: String {
        switch self {
        case .keyFile: return "doc.badge.ellipsis"
        case .keyContent: return "key.fill"
        case .password: return "ellipsis.rectangle.fill"
        case .agent: return "person.badge.key.fill"
        }
    }
}

extension TunnelSession.Status {
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .unlocking, .prompting: return .indigo
        case .connecting: return .orange
        case .connected: return .green
        case .waiting: return .orange
        case .failed: return .red
        }
    }

    var label: String {
        switch self {
        case .idle: return "Desconectado"
        case .unlocking: return "Aguardando \(Unlocker.methodName)…"
        case .prompting: return "Aguardando sua resposta…"
        case .connecting: return "Conectando…"
        case .connected: return "Conectado"
        case .waiting: return "Reconectando…"
        case .failed: return "Erro"
        }
    }
}

// MARK: - Peças

struct TunnelIcon: View {
    let tunnel: Tunnel
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tunnel.tag.color.gradient)
            .overlay {
                Image(systemName: tunnel.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: tunnel.tag.color.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

struct StatusDot: View {
    let status: TunnelSession.Status
    var size: CGFloat = 9
    @State private var pulse = false

    var body: some View {
        ZStack {
            if status.isBusy || status.isConnected {
                Circle()
                    .fill(status.color.opacity(status.isConnected ? 0.35 : 0.5))
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 1)
                    .animation(
                        .easeOut(duration: status.isConnected ? 2.4 : 1.1).repeatForever(autoreverses: false),
                        value: pulse
                    )
            }
            Circle()
                .fill(status.color)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .frame(width: size, height: size)
        .id(status.label) // reinicia a animação ao mudar de estado
        .onAppear { pulse = true }
        .accessibilityLabel(status.label)
    }
}

struct StatusPill: View {
    let status: TunnelSession.Status

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, size: 7)
            Text(status.label)
            if case .connected(let since) = status {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .foregroundStyle(status == .idle ? Color.secondary : status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(status.color.opacity(status == .idle ? 0.08 : 0.13)))
        .animation(.snappy, value: status)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

struct CopyButton: View {
    let text: String
    var label: String = "Copiar"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.snappy) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.snappy) { copied = false } }
        } label: {
            Label(copied ? "Copiado" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("Copiar para a área de transferência")
    }
}

struct ColorTagPicker: View {
    @Binding var selection: TagColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TagColor.allCases) { tag in
                Circle()
                    .fill(tag.color.gradient)
                    .frame(width: 18, height: 18)
                    .overlay {
                        if tag == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(2)
                    .overlay(Circle().strokeBorder(tag == selection ? tag.color : .clear, lineWidth: 1.5))
                    .contentShape(Circle())
                    .onTapGesture { withAnimation(.snappy) { selection = tag } }
                    .accessibilityLabel(tag.rawValue)
            }
        }
    }
}

/// Campo de segredo com botão de olho.
struct SecretField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(title, text: $text, prompt: Text(prompt))
                } else {
                    SecureField(title, text: $text, prompt: Text(prompt))
                }
            }
            .font(revealed ? .body.monospaced() : .body)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(revealed ? "Ocultar" : "Mostrar")
        }
    }
}

/// Mensagem rápida no rodapé da janela.
struct ToastView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

// MARK: - Latência

extension Latency.Quality {
    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    var label: String {
        switch self {
        case .good: return "boa"
        case .fair: return "razoável"
        case .poor: return "alta"
        }
    }
}

/// "23 ms", colorido pela qualidade. Some quando o túnel não está conectado.
struct LatencyBadge: View {
    let session: TunnelSession
    var showsSparkline = false

    var body: some View {
        if session.status.isConnected {
            HStack(spacing: 6) {
                if !session.latencyAvailable {
                    Text("sem ping")
                        .foregroundStyle(.tertiary)
                        .help("O servidor não responde a ping, ou há um bastion no meio. O túnel funciona normalmente.")
                } else if let ms = session.latency {
                    let quality = Latency.quality(ms)
                    if showsSparkline {
                        Sparkline(samples: session.latencySamples, color: quality.color)
                            .frame(width: 54, height: 16)
                    }
                    Circle().fill(quality.color).frame(width: 6, height: 6)
                    Text("\(Int(ms.rounded())) ms")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Int(ms.rounded()))
                } else {
                    Text("medindo…").foregroundStyle(.tertiary)
                }
            }
            .help(helpText)
        }
    }

    private var helpText: String {
        guard let ms = session.latency else { return "Latência até o servidor (ping)" }
        return "Latência até o servidor: \(Int(ms.rounded())) ms (\(Latency.quality(ms).label)). Medida por ping a cada 5 s."
    }
}

/// Mini gráfico das últimas medições; falhas aparecem como lacunas.
struct Sparkline: View {
    let samples: [Double?]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let values = samples.compactMap { $0 }
            guard values.count >= 2, let maxV = values.max(), let minV = values.min() else { return }
            let span = max(maxV - minV, 10) // evita exagerar variações de 1–2 ms
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            var path = Path()
            var drawing = false
            for (i, sample) in samples.enumerated() {
                guard let v = sample else { drawing = false; continue }
                let point = CGPoint(x: CGFloat(i) * step,
                                    y: size.height - 1.5 - CGFloat((v - minV) / span) * (size.height - 3))
                if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
            }
            ctx.stroke(path, with: .color(color.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
