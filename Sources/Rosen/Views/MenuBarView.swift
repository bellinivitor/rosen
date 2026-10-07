import RosenCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let connected = store.connectedCount
        let busy = store.sessions.values.contains { $0.status.isBusy }
        // Conectado vence: se algum túnel está de pé, os portais aparecem acesos.
        RosenMarkView(state: connected > 0 ? .active : (busy ? .busy : .idle))
            .accessibilityLabel("Rosen: \(connected) túne\(connected == 1 ? "l ativo" : "is ativos")")
    }
}

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rosen").font(.system(.headline, design: .rounded))
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if store.tunnels.isEmpty && store.servers.isEmpty {
                VStack(spacing: 10) {
                    RosenMarkView(size: 28)
                        .foregroundStyle(.secondary)
                    Text("Nenhum túnel ainda").foregroundStyle(.secondary)
                    Button("Criar túnel") { openMain(); store.newTunnel() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.tunnels) { tunnel in
                            MenuTunnelRow(tunnel: tunnel) {
                                store.selection = tunnel.id
                                openMain()
                            }
                        }
                        if !store.servers.isEmpty {
                            Text("Servidores")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, store.tunnels.isEmpty ? 2 : 8)
                            ForEach(store.servers) { server in
                                MenuServerRow(server: server) {
                                    store.selection = server.id
                                    openMain()
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 2) {
                MenuFooterButton(title: "Abrir", icon: "macwindow") { openMain() }
                MenuFooterButton(title: "Novo", icon: "plus") { openMain(); store.newTunnel() }
                Spacer()
                if store.activeCount > 0 {
                    MenuFooterButton(title: "Parar todos", icon: "stop.circle") { store.disconnectAll() }
                }
                MenuFooterButton(title: nil, icon: "info.circle") { AboutPanel.show() }
                    .help("Sobre o Rosen \(AboutPanel.version)")
                MenuFooterButton(title: nil, icon: "power") { NSApp.terminate(nil) }
                    .help("Sair do Rosen (desconecta tudo)")
            }
            .padding(6)
        }
        .frame(width: 330)
    }

    private var summary: String {
        let active = store.activeCount
        if active == 0 { return "\(store.tunnels.count) túne\(store.tunnels.count == 1 ? "l" : "is")" }
        return "\(store.connectedCount) de \(active) ativo\(active == 1 ? "" : "s")"
    }

    private func openMain() {
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuTunnelRow: View {
    @Environment(AppStore.self) private var store
    let tunnel: Tunnel
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        let session = store.session(tunnel.id)
        let status = session?.status ?? .idle
        HStack(spacing: 10) {
            TunnelIcon(tunnel: tunnel, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(status: status, size: 8)
                        .padding(1.5)
                        .background(Circle().fill(.background))
                        .offset(x: 3, y: 3)
                        .opacity(status == .idle ? 0 : 1)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Group {
                    switch status {
                    case .idle: Text(tunnel.compactSummary)
                    case .connected:
                        HStack(spacing: 8) {
                            Text(tunnel.clientAddress)
                            if let session { LatencyBadge(session: session) }
                        }
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    default: Text(status.label).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovering, status.isConnected {
                Button { store.copyAddress(tunnel.id) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copiar \(tunnel.clientAddress)")
                    .transition(.opacity)
            }
            Toggle("", isOn: Binding(
                get: { session?.isOn ?? false },
                set: { on in on ? store.connect(tunnel.id) : store.disconnect(tunnel.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(count: 2) { onOpen() }
        .animation(.snappy, value: status)
    }
}

struct MenuServerRow: View {
    @Environment(AppStore.self) private var store
    let server: Server
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ServerIcon(server: server, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(server.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if store.openingServers.contains(server.id) {
                ProgressView().controlSize(.mini)
            } else {
                Button { store.openServer(server.id) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Abrir no \(TerminalApp.preferred.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { store.openServer(server.id) }
        .contextMenu { Button("Mostrar no Rosen") { onOpen() } }
    }
}

struct MenuFooterButton: View {
    let title: String?
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                if let title { Text(title).lineLimit(1) }
            }
            .font(.callout)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
