import RosenCore
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: WindowID.credentials) } label: {
                    Label("Credenciais", systemImage: "key")
                }
                .help("Gerenciar credenciais (⇧⌘K)")
                Button { store.newTunnel() } label: {
                    Label("Novo túnel", systemImage: "plus")
                }
                .help("Novo túnel (⌘N)")
            }
        }
        .sheet(item: $store.editorRequest) { request in
            TunnelEditor(request: request)
                .environment(store)
        }
        .confirmationDialog(
            "Excluir “\(store.pendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Excluir túnel", role: .destructive) {
                if let t = store.pendingDeletion { withAnimation(.snappy) { store.delete(t.id) } }
                store.pendingDeletion = nil
            }
        } message: {
            Text("O túnel será desconectado. As credenciais não são apagadas.")
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(text: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
    }

    @ViewBuilder
    private var detail: some View {
        switch store.loadState {
        case .loading:
            ProgressView("Abrindo o cofre…")
        case .failed(let message):
            VaultErrorView(message: message)
        case .ready:
            if let id = store.selection, store.tunnel(id) != nil {
                TunnelDetailView(tunnelID: id)
                    .id(id)
            } else if store.tunnels.isEmpty {
                EmptyStateView()
            } else {
                ContentUnavailableView {
                    Label { Text("Escolha um túnel") } icon: { RosenMarkView(size: 34) }
                } description: {
                    Text("Selecione um túnel na barra lateral.")
                }
            }
        }
    }
}

// MARK: - Estado vazio

struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    /// Túnel de exemplo, animado, para mostrar o que o app faz antes de qualquer configuração.
    private let demo = Tunnel(host: "seu-servidor.com", user: "usuario", listenPort: 5433,
                              targetHost: "127.0.0.1", targetPort: 5432, tag: .indigo)

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                Text("Abra seu primeiro túnel")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("O PostgreSQL do servidor vira 127.0.0.1:5433 no seu Mac. Cole um comando ssh -L ou preencha os campos.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }

            TunnelStage(tunnel: demo, status: .connected(since: Date()))
                .padding(.horizontal, 14)
                .padding(.vertical, 26)
                .frame(maxWidth: 560)
                .background(RosenBackdrop(color: demo.tag.color))

            HStack(spacing: 12) {
                Button { store.newTunnel() } label: {
                    Label("Criar túnel", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(fill: .indigo, filled: true))
                .keyboardShortcut(.defaultAction)

                Button { store.newTunnelFromClipboard() } label: {
                    Label("Colar comando ssh", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(PillButtonStyle(fill: .indigo, filled: false))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VaultErrorView: View {
    @Environment(AppStore.self) private var store
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Não foi possível abrir o cofre", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Tentar novamente") { store.load() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""

    private var filtered: [Tunnel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.tunnels }
        return store.tunnels.filter {
            "\($0.displayName) \($0.host) \($0.user) \($0.listenPort) \($0.targetPort) \($0.serviceName ?? "")"
                .lowercased().contains(q)
        }
    }

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            Section {
                ForEach(filtered) { tunnel in
                    TunnelRow(tunnel: tunnel)
                        .tag(tunnel.id)
                        .contextMenu { TunnelContextMenu(id: tunnel.id) }
                }
                .onMove(perform: query.isEmpty ? { store.move(from: $0, to: $1) } : nil)
            } header: {
                HStack {
                    Text("Túneis")
                    Spacer()
                    if store.activeCount > 0 {
                        Text("\(store.connectedCount)/\(store.activeCount) ativos")
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Buscar")
        .onDeleteCommand { if let id = store.selection { store.requestDelete(id) } }
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button { store.newTunnel() } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                    .help("Novo túnel (⌘N)")
                Spacer()
                if store.activeCount > 0 {
                    Button("Desconectar todos") { store.disconnectAll() }
                        .font(.caption)
                } else if !store.tunnels.isEmpty {
                    Button("Conectar todos") { store.connectAll() }
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct TunnelRow: View {
    @Environment(AppStore.self) private var store
    let tunnel: Tunnel

    var body: some View {
        let session = store.session(tunnel.id)
        let status = session?.status ?? .idle

        HStack(spacing: 10) {
            TunnelIcon(tunnel: tunnel, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(status: status, size: 9)
                        .padding(1.5)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 4, y: 4)
                        .opacity(status == .idle ? 0 : 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Group {
                    switch status {
                    case .failed: Text("Erro — clique para ver").foregroundStyle(.red)
                    case .waiting: Text("Reconectando…").foregroundStyle(.orange)
                    default: Text(tunnel.compactSummary).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(
                get: { session?.isOn ?? false },
                set: { on in on ? store.connect(tunnel.id) : store.disconnect(tunnel.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(.green)
            .help(session?.isOn == true ? "Desconectar" : "Conectar")
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: status)
    }
}

struct TunnelContextMenu: View {
    @Environment(AppStore.self) private var store
    let id: UUID

    var body: some View {
        let isOn = store.session(id)?.isOn ?? false
        Button(isOn ? "Desconectar" : "Conectar") { store.toggle(id) }
        Divider()
        Button("Copiar endereço local") { store.copyAddress(id) }
        Button("Copiar comando ssh") { store.copyCommand(id) }
        Divider()
        Button("Editar…") { store.edit(id) }
        Button("Duplicar") { store.duplicate(id) }
        Divider()
        Button("Excluir…", role: .destructive) { store.requestDelete(id) }
    }
}
