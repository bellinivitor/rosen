import AppKit
import RosenCore
import SwiftUI

/// Portas TCP em escuta no Mac, com o programa dono de cada uma.
@MainActor
@Observable
final class PortsModel {
    private(set) var entries: [PortEntry] = []
    private(set) var updatedAt: Date?
    private(set) var isLoading = false

    func refresh() async {
        isLoading = true
        let result = await Task.detached(priority: .userInitiated) { ListeningPorts.scan() }.value
        entries = result
        updatedAt = Date()
        isLoading = false
    }

    /// Atualiza enquanto a janela estiver aberta (a tarefa é cancelada ao fechar).
    func keepFresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func terminate(_ entry: PortEntry) async -> Bool {
        let pids = entry.pids
        let ok = await Task.detached(priority: .userInitiated) { TunnelProcesses.terminate(pids) }.value
        await refresh()
        return ok
    }
}

/// Grupo de uma porta na tela, com a cor que a representa no espectro.
enum PortGroup: CaseIterable {
    case rosen, user, system

    init(_ owner: PortEntry.Owner) {
        switch owner {
        case .rosen: self = .rosen
        case .user: self = .user
        case .system: self = .system
        }
    }

    var title: String {
        switch self {
        case .rosen: return "Túneis do Rosen"
        case .user: return "Seus programas"
        case .system: return "Serviços do macOS"
        }
    }

    var color: Color {
        switch self {
        case .rosen: return .indigo
        case .user: return .blue
        case .system: return .gray
        }
    }
}

enum PortFilter: Hashable {
    case all, group(PortGroup), exposed

    var title: String {
        switch self {
        case .all: return "Todas"
        case .group(.rosen): return "Rosen"
        case .group(.user): return "Programas"
        case .group(.system): return "macOS"
        case .exposed: return "Na rede"
        }
    }

    func includes(_ entry: PortEntry) -> Bool {
        switch self {
        case .all: return true
        case .group(let g): return PortGroup(entry.owner) == g
        case .exposed: return entry.isExposed
        }
    }
}

struct PortsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var model = PortsModel()
    @State private var query = ""
    @State private var filter: PortFilter = .all
    @State private var showsSystem = false
    @State private var pendingKill: PortEntry?

    var body: some View {
        let visible = model.entries.filter { filter.includes($0) && matches($0) }

        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PortsHero(entries: model.entries, filter: $filter, title: title(for:))
                sections(visible)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if model.updatedAt == nil {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(text: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast)
        .animation(.snappy, value: filter)
        .searchable(text: $query, placement: .toolbar, prompt: "Porta ou programa")
        .navigationTitle("Portas em uso")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }
                .help("Atualizar agora (atualiza sozinho a cada 3 s)")
                .keyboardShortcut("r")
            }
        }
        .task { await model.keepFresh() }
        .confirmationDialog(
            "Encerrar \(pendingKill.map { AppIdentity.of($0).name } ?? "")?",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible,
            presenting: pendingKill
        ) { entry in
            Button("Encerrar processo", role: .destructive) { kill(entry) }
            Button("Cancelar", role: .cancel) {}
        } message: { entry in
            Text(entry.pids.count > 1
                 ? "Os \(entry.pids.count) processos de \(entry.name) serão encerrados e a porta \(entry.port), liberada. O que estiver aberto neles será perdido."
                 : "O processo \(entry.name) (PID \(entry.pid)) será encerrado e a porta \(entry.port), liberada. O que estiver aberto nele será perdido.")
        }
    }

    // MARK: - Seções

    @ViewBuilder
    private func sections(_ visible: [PortEntry]) -> some View {
        if model.updatedAt != nil, visible.isEmpty {
            Group {
                if query.isEmpty {
                    ContentUnavailableView("Nada por aqui", systemImage: "network",
                                           description: Text("Nenhuma porta em uso neste filtro."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        }
        ForEach(PortGroup.allCases, id: \.self) { group in
            let rows = visible.filter { PortGroup($0.owner) == group }
            if !rows.isEmpty {
                // O macOS fica recolhido na visão geral: são portas que raramente interessam.
                let collapsible = group == .system && filter == .all && query.isEmpty
                let expanded = !collapsible || showsSystem
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.title).font(.system(.title3, design: .rounded).weight(.bold))
                        Text(String(rows.count))
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if collapsible {
                            Button(showsSystem ? "Ocultar" : "Mostrar") {
                                withAnimation(.snappy) { showsSystem.toggle() }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    if expanded {
                        PortList(rows: rows) { entry in
                            PortRow(entry: entry, group: group, title: title(for: entry), detail: detail(for: entry),
                                    warning: warning(for: entry), tunnel: tunnel(for: entry),
                                    onCopy: { store.copy(address(of: entry), message: "Endereço copiado") }) {
                                actions(for: entry)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    // MARK: - Ações

    @ViewBuilder
    private func actions(for entry: PortEntry) -> some View {
        Button("Copiar endereço") { store.copy(address(of: entry), message: "Endereço copiado") }
        if case .rosen(let process) = entry.owner {
            let tunnel = process.tunnel(in: store.tunnels)
            if let tunnel {
                Button("Mostrar túnel") {
                    store.selection = tunnel.id
                    openWindow(id: WindowID.main)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Divider()
            if !process.isOrphan, let tunnel, store.session(tunnel.id)?.isOn == true {
                Button("Desconectar túnel") { store.disconnect(tunnel.id) }
            } else {
                Button("Encerrar conexão antiga") { kill(entry) }
            }
        } else {
            if let path = entry.appBundlePath ?? entry.path {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if entry.owner == .user {
                Divider()
                Button("Encerrar processo…", role: .destructive) { pendingKill = entry }
            }
        }
    }

    private func kill(_ entry: PortEntry) {
        Task {
            let ok = await model.terminate(entry)
            store.showToast(ok ? "Porta \(entry.port) liberada" : "Não foi possível encerrar \(entry.name)")
        }
    }

    // MARK: - Textos

    private func tunnel(for entry: PortEntry) -> Tunnel? {
        if case .rosen(let process) = entry.owner { return process.tunnel(in: store.tunnels) }
        return nil
    }

    private func title(for entry: PortEntry) -> String {
        if case .rosen = entry.owner { return tunnel(for: entry)?.displayName ?? "Túnel apagado" }
        return AppIdentity.of(entry).name
    }

    private func detail(for entry: PortEntry) -> String {
        if case .rosen(let process) = entry.owner {
            guard let tunnel = tunnel(for: entry) else { return "ssh, PID \(entry.pid)" }
            if process.isOrphan { return "Para \(tunnel.destination), sem controle do Rosen" }
            let state = store.session(tunnel.id)?.status.label.lowercased() ?? ""
            return "Para \(tunnel.destination), \(state)"
        }
        let processes = entry.pids.count > 1 ? "\(entry.pids.count) processos" : "PID \(entry.pid)"
        let identity = AppIdentity.of(entry)
        return identity.name != entry.name ? "\(entry.name), \(processes)" : processes
    }

    /// A porta é a mesma de um túnel cadastrado: ele não vai conseguir conectar.
    private func warning(for entry: PortEntry) -> String? {
        if case .rosen(let process) = entry.owner {
            return process.isOrphan ? "Sobrou de uma sessão anterior do Rosen" : nil
        }
        guard let tunnel = store.tunnels.first(where: { $0.kind != .remote && $0.listenPort == entry.port }) else { return nil }
        return "Mesma porta do túnel “\(tunnel.displayName)”"
    }

    private func address(of entry: PortEntry) -> String {
        let host = entry.addresses.first { $0.hasPrefix("127.") } ?? (entry.isExposed ? "127.0.0.1" : entry.addresses.first ?? "127.0.0.1")
        let shown = host.contains(":") ? "[\(host)]" : host == "*" ? "127.0.0.1" : host
        return "\(shown):\(entry.port)"
    }

    private func matches(_ entry: PortEntry) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if String(entry.port).hasPrefix(q) { return true }
        return [title(for: entry), entry.name, detail(for: entry), ServiceCatalog.name(for: entry.port) ?? ""]
            .contains { $0.lowercased().contains(q) }
    }
}

// MARK: - Cabeçalho com o espectro

struct PortsHero: View {
    let entries: [PortEntry]
    @Binding var filter: PortFilter
    let title: (PortEntry) -> String

    var body: some View {
        let exposed = entries.filter(\.isExposed).count
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Portas em uso")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(summary(exposed: exposed))
                    .foregroundStyle(.secondary)
            }

            PortSpectrum(entries: entries.filter { filter.includes($0) }, title: title)
                .frame(height: 74)

            HStack(spacing: 6) {
                chip(.all, count: entries.count)
                ForEach(PortGroup.allCases, id: \.self) { g in
                    chip(.group(g), count: entries.filter { PortGroup($0.owner) == g }.count, color: g.color)
                }
                chip(.exposed, count: exposed, color: .orange)
                Spacer()
            }
        }
        .padding(22)
        .background(RosenBackdrop(color: .indigo))
    }

    private func summary(exposed: Int) -> String {
        guard !entries.isEmpty else { return "Procurando programas que esperam conexões…" }
        let open = entries.count == 1 ? "1 porta aberta neste Mac" : "\(entries.count) portas abertas neste Mac"
        switch exposed {
        case 0: return "\(open), nenhuma aceitando conexões da rede."
        case 1: return "\(open), 1 delas aceitando conexões da rede."
        default: return "\(open), \(exposed) delas aceitando conexões da rede."
        }
    }

    private func chip(_ value: PortFilter, count: Int, color: Color = .primary) -> some View {
        let selected = filter == value
        return Button {
            filter = selected && value != .all ? .all : value
        } label: {
            HStack(spacing: 6) {
                if value != .all {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(value.title)
                Text(String(count)).foregroundStyle(.secondary)
            }
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0.18 : 0.06), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && value != .all)
        .opacity(count == 0 && value != .all ? 0.45 : 1)
    }
}

/// Faixa de 1 a 65535 em escala logarítmica, com um traço por porta ocupada.
/// As três zonas são as faixas da IANA: do sistema, registradas e temporárias.
struct PortSpectrum: View {
    let entries: [PortEntry]
    let title: (PortEntry) -> String
    @State private var hover: PortEntry?
    @State private var hoverX: CGFloat = 0

    private static let zones: [(range: ClosedRange<Int>, label: String)] = [
        (1...1023, "Sistema"), (1024...49151, "Serviços"), (49152...65535, "Temporárias"),
    ]

    static func position(_ port: Int, width: CGFloat) -> CGFloat {
        CGFloat(log(Double(max(port, 1))) / log(65535.0)) * width
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barTop: CGFloat = 22, barHeight: CGFloat = 30
            ZStack(alignment: .topLeading) {
                // Zonas
                ForEach(Self.zones, id: \.label) { zone in
                    let x0 = Self.position(zone.range.lowerBound, width: w)
                    let x1 = Self.position(zone.range.upperBound, width: w)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                        .frame(width: max(0, x1 - x0 - 3), height: barHeight)
                        .offset(x: x0, y: barTop)
                    // A última zona é estreita na escala log: o rótulo encosta na borda direita.
                    let last = zone.range.upperBound == 65535
                    Text(zone.label)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: last ? w : nil, alignment: last ? .trailing : .leading)
                        .offset(x: last ? 0 : x0 + 2, y: barTop + barHeight + 6)
                }
                // Portas
                ForEach(entries) { entry in
                    let x = Self.position(entry.port, width: w)
                    let color = PortGroup(entry.owner).color
                    let active = hover?.id == entry.id
                    Capsule()
                        .fill(color.opacity(hover == nil || active ? 1 : 0.35))
                        .frame(width: active ? 4 : 2.5, height: barHeight - (active ? 0 : 8))
                        .overlay(alignment: .top) {
                            if entry.isExposed {
                                Circle().fill(.orange).frame(width: 6, height: 6).offset(y: -9)
                            }
                        }
                        .offset(x: x - 1.25, y: barTop + (active ? 0 : 4))
                }
                // Rótulo da porta sob o mouse
                if let hover {
                    let label = Text(":\(String(hover.port))").bold() + Text("  \(title(hover))").foregroundStyle(.secondary)
                    label
                        .font(.system(.caption, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                        .offset(x: min(max(0, hoverX - 40), w - 200), y: -6)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover = entries.min { abs(Self.position($0.port, width: w) - point.x) < abs(Self.position($1.port, width: w) - point.x) }
                        .flatMap { abs(Self.position($0.port, width: w) - point.x) < 14 ? $0 : nil }
                    hoverX = hover.map { Self.position($0.port, width: w) } ?? point.x
                case .ended:
                    hover = nil
                }
            }
            .animation(.snappy(duration: 0.2), value: hover?.id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mapa das portas em uso, de 1 a 65535")
    }
}

// MARK: - Lista

struct PortList<Row: View>: View {
    let rows: [PortEntry]
    @ViewBuilder let row: (PortEntry) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                // Alinhado ao texto, depois da porta e do ícone.
                if index > 0 { Divider().padding(.leading, 143) }
                row(entry)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct PortRow<Actions: View>: View {
    let entry: PortEntry
    let group: PortGroup
    let title: String
    let detail: String
    let warning: String?
    let tunnel: Tunnel?
    let onCopy: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            // A porta é a âncora da linha, no mesmo estilo do :5433 do túnel.
            // A largura mínima vem do maior valor possível (:65535), invisível, para as linhas alinharem.
            // O número nunca é comprimido: se precisar de mais espaço, a coluna cresce.
            ZStack(alignment: .trailing) {
                Text(":65535").hidden()
                (Text(":").foregroundStyle(.tertiary) + Text(String(entry.port)))
                    .foregroundStyle(group == .system ? Color.secondary : Color.primary)
                    .fixedSize()
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(1)
            .overlay(alignment: .topTrailing) {
                if entry.isExposed {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                        .offset(x: 9, y: 1)
                        .help("Aceita conexões de outros dispositivos da rede (\(entry.addresses.joined(separator: ", "))).")
                }
            }

            icon.frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    if let service = ServiceCatalog.name(for: entry.port), group != .rosen {
                        Text(service)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(group.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(group.color.opacity(0.12)))
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .help(entry.path ?? entry.name)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .help("Copiar endereço")
                Menu { actions() } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(hovering ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions() }
    }

    @ViewBuilder
    private var icon: some View {
        if let tunnel {
            TunnelIcon(tunnel: tunnel, size: 30)
                .saturation(warning == nil ? 1 : 0)
        } else if group == .rosen {
            TagIcon(color: .gray, symbol: "questionmark", size: 30)
        } else {
            Image(nsImage: AppIdentity.of(entry).icon)
                .resizable()
                .interpolation(.high)
        }
    }
}

/// Nome e ícone de quem está na porta: o app (Docker, PhpStorm…) ou o executável.
struct AppIdentity {
    let name: String
    let icon: NSImage

    @MainActor private static var cache: [String: AppIdentity] = [:]

    @MainActor
    static func of(_ entry: PortEntry) -> AppIdentity {
        if case .rosen = entry.owner {
            return AppIdentity(name: "Rosen", icon: NSApp.applicationIconImage)
        }
        let key = entry.appBundlePath ?? entry.path ?? entry.name
        if let cached = cache[key] { return cached }

        let identity: AppIdentity
        if let app = NSRunningApplication(processIdentifier: entry.pid), let name = app.localizedName, let icon = app.icon {
            identity = AppIdentity(name: name, icon: icon)
        } else if let bundle = entry.appBundlePath {
            let name = (FileManager.default.displayName(atPath: bundle) as NSString).deletingPathExtension
            identity = AppIdentity(name: name, icon: NSWorkspace.shared.icon(forFile: bundle))
        } else if let path = entry.path {
            identity = AppIdentity(name: entry.name, icon: NSWorkspace.shared.icon(forFile: path))
        } else {
            identity = AppIdentity(name: entry.name, icon: NSWorkspace.shared.icon(for: .unixExecutable))
        }
        cache[key] = identity
        return identity
    }
}
