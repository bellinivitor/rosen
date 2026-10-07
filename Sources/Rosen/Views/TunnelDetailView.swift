import RosenCore
import SwiftUI

struct TunnelDetailView: View {
    @Environment(AppStore.self) private var store
    let tunnelID: UUID

    var body: some View {
        if let tunnel = store.tunnel(tunnelID), let session = store.session(tunnelID) {
            let credential = tunnel.credentialID.flatMap(store.credential)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    TunnelHero(tunnel: tunnel, session: session)
                    banner(tunnel, session)
                    SettingsList(tunnel: tunnel, credential: credential)
                    TerminalPanel(tunnel: tunnel, credential: credential, session: session)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(tunnel.displayName)
            .toolbar {
                ToolbarItemGroup {
                    Button { store.edit(tunnelID) } label: { Label("Editar", systemImage: "slider.horizontal.3") }
                        .help("Editar (⌘E)")
                    Menu {
                        TunnelContextMenu(id: tunnelID)
                    } label: {
                        Label("Mais", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                }
            }
            .animation(.snappy, value: session.status)
        }
    }

    @ViewBuilder
    private func banner(_ tunnel: Tunnel, _ session: TunnelSession) -> some View {
        switch session.status {
        case .failed(let message):
            BannerView(color: .red, icon: "exclamationmark.triangle.fill", title: "O túnel não conectou", message: message) {
                Button("Editar túnel") { store.edit(tunnel.id) }
                Button("Tentar de novo") { session.connect() }
                    .keyboardShortcut(.defaultAction)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        case .waiting(let retryAt, let attempt, let reason):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                BannerView(color: .orange, icon: "arrow.triangle.2.circlepath",
                           title: "Nova tentativa em \(seconds)s (tentativa \(attempt))", message: reason) {
                    Button("Tentar agora") { session.retryNowIfWaiting() }
                    Button("Desconectar") { session.disconnect() }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        default:
            EmptyView()
        }
    }
}

// MARK: - Destaque

struct TunnelHero: View {
    @Environment(AppStore.self) private var store
    let tunnel: Tunnel
    let session: TunnelSession

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 14) {
                TunnelIcon(tunnel: tunnel, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tunnel.displayName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        StatusPill(status: session.status)
                        Text(tunnel.destination)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Button {
                    withAnimation(.snappy) { session.toggle() }
                } label: {
                    Label(session.isOn ? "Desconectar" : "Conectar",
                          systemImage: session.isOn ? "stop.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PillButtonStyle(fill: tunnel.tag.color, filled: !session.isOn))
                .help(session.isOn ? "Desconectar (⌘R)" : "Conectar (⌘R)")
            }

            TunnelStage(tunnel: tunnel, status: session.status)
                .padding(.horizontal, -8)

            HStack(spacing: 10) {
                Image(systemName: session.status.isConnected ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(session.status.isConnected ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(hint)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: copyTarget, label: "Copiar endereço")
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .font(.callout)
        }
        .padding(22)
        .background(RosenBackdrop(color: tunnel.tag.color))
    }

    private var copyTarget: String { tunnel.kind == .remote ? "localhost:\(tunnel.listenPort)" : tunnel.clientAddress }

    private var hint: String {
        switch tunnel.kind {
        case .local:
            let client = tunnel.serviceName.map { "seu cliente \($0)" } ?? "seu cliente"
            return "Conecte \(client) em \(tunnel.clientAddress)."
        case .dynamic:
            return "Use \(tunnel.clientAddress) como proxy SOCKS5."
        case .remote:
            return "No servidor, localhost:\(tunnel.listenPort) chega em \(tunnel.targetAddress) no seu Mac."
        }
    }
}

// MARK: - Configuração

struct SettingsList: View {
    @Environment(AppStore.self) private var store
    let tunnel: Tunnel
    let credential: Credential?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Configuração")
                Spacer()
                Button("Editar") { store.edit(tunnel.id) }
                    .buttonStyle(.link)
            }
            VStack(spacing: 0) {
                row("Servidor SSH") { mono("\(tunnel.destination):\(tunnel.port)") }
                divider
                row("Tipo") { Text("\(tunnel.kind.title) (\(tunnel.kind.flag))") }
                divider
                row("Autenticação") { auth }
                divider
                row("Se a conexão cair") { Text(tunnel.autoReconnect ? "Reconecta sozinho" : "Fica desligado") }
                divider
                row("Ao abrir o Rosen") { Text(tunnel.autoConnect ? "Conecta" : "Não conecta") }
                if !tunnel.extraOptions.isEmpty {
                    divider
                    row("Opções do ssh") { mono(tunnel.extraOptions.joined(separator: "  ")) }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
        }
    }

    @ViewBuilder
    private var auth: some View {
        if let credential {
            HStack(spacing: 6) {
                if let problem = credential.problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(problem)
                }
                if let symbol = credential.protectionSymbol {
                    Image(systemName: symbol).foregroundStyle(.indigo).help("Protegida por \(Unlocker.methodName)")
                } else {
                    Image(systemName: credential.kind.symbol).foregroundStyle(.secondary)
                }
                Text(credential.displayName)
                Text(credential.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } else {
            Text("ssh-agent e ~/.ssh/config")
        }
    }

    private var divider: some View { Divider().padding(.leading, 16) }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(.title3, design: .rounded).weight(.semibold))
    }
}

// MARK: - Terminal (comando + saída)

struct TerminalPanel: View {
    @Environment(\.colorScheme) private var scheme
    let tunnel: Tunnel
    let credential: Credential?
    let session: TunnelSession

    var body: some View {
        let command = SSHCommand.displayString(for: tunnel, credential: credential)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Terminal")
                Spacer()
                CopyButton(text: command, label: "Copiar comando")
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("Limpar") { withAnimation(.snappy) { session.clearLogs() } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(session.logs.isEmpty)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$").foregroundStyle(tunnel.tag.color)
                    Text(command)
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

                if session.logs.isEmpty {
                    Text("A saída da conexão aparece aqui.")
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(session.logs) { entry in
                                    LogRow(entry: entry).id(entry.id)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .frame(height: min(190, CGFloat(session.logs.count) * 20 + 26))
                        .onAppear { proxy.scrollTo(session.logs.last?.id, anchor: .bottom) }
                        .onChange(of: session.logs.last?.id) { _, last in
                            withAnimation(.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(scheme == .dark ? Color(red: 0.075, green: 0.078, blue: 0.098) : Color(red: 0.102, green: 0.106, blue: 0.129))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.25), lineWidth: 0.75)
            )
            .environment(\.colorScheme, .dark)
        }
    }
}

struct LogRow: View {
    let entry: TunnelSession.LogEntry
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.formatter.string(from: entry.date))
                .foregroundStyle(.white.opacity(0.3))
                .monospacedDigit()
            Text(marker)
                .foregroundStyle(color)
                .frame(width: 10)
            Text(entry.text)
                .foregroundStyle(entry.level == .info ? Color.white.opacity(0.62) : Color.white.opacity(0.95))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var marker: String {
        switch entry.level {
        case .info: return "·"
        case .success: return "✓"
        case .warning: return "!"
        case .error: return "✕"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: return .white.opacity(0.35)
        case .success: return Color(red: 0.36, green: 0.86, blue: 0.55)
        case .warning: return Color(red: 0.98, green: 0.70, blue: 0.25)
        case .error: return Color(red: 1.0, green: 0.42, blue: 0.40)
        }
    }
}

// MARK: - Banner

struct BannerView<Actions: View>: View {
    let color: Color
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: icon.contains("circlepath"))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.headline, design: .rounded))
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.09))
        )
        .overlay(alignment: .leading) {
            Capsule().fill(color).frame(width: 3).padding(.vertical, 10).padding(.leading, 5)
        }
    }
}
