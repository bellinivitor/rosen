import AppKit
import Observation
import RosenCore
import SwiftUI

// MARK: - Barra lateral

struct ServerRow: View {
    @Environment(AppStore.self) private var store
    let server: Server

    var body: some View {
        HStack(spacing: 10) {
            ServerIcon(server: server, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(server.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.openingServers.contains(server.id) {
                ProgressView().controlSize(.mini)
            } else {
                Button { store.openServer(server.id) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Abrir no \(TerminalApp.preferred.title)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct ServerContextMenu: View {
    @Environment(AppStore.self) private var store
    let id: UUID

    var body: some View {
        Button("Abrir no \(TerminalApp.preferred.title)") { store.openServer(id) }
        Divider()
        Button("Copiar comando ssh") { store.copyServerCommand(id) }
        Button("Criar túnel a partir deste servidor…") { store.newTunnel(from: id) }
        Divider()
        Button("Editar…") { store.editServer(id) }
        Button("Duplicar") { store.duplicateServer(id) }
        Divider()
        Button("Excluir…", role: .destructive) { store.requestDeleteServer(id) }
    }
}

// MARK: - Detalhe

struct ServerDetailView: View {
    @Environment(AppStore.self) private var store
    let serverID: UUID
    @State private var probe = LatencyProbe()

    var body: some View {
        if let server = store.server(serverID) {
            let credential = server.credentialID.flatMap(store.credential)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ServerHero(server: server, probe: probe)
                    ServerSettingsList(server: server, credential: credential)
                    commandPanel(server, credential)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(server.displayName)
            .toolbar {
                ToolbarItemGroup {
                    Button { store.editServer(serverID) } label: { Label("Editar", systemImage: "slider.horizontal.3") }
                        .help("Editar (⌘E)")
                    Menu {
                        ServerContextMenu(id: serverID)
                    } label: {
                        Label("Mais", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                }
            }
            // Mede só enquanto a tela está visível; reinicia se host, porta ou opções mudarem.
            .task(id: LatencyKey(server)) { await probe.run(for: server) }
        }
    }

    private func commandPanel(_ server: Server, _ credential: Credential?) -> some View {
        let command = SSHCommand.displayString(for: server, credential: credential)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Comando")
                Spacer()
                CopyButton(text: command, label: "Copiar comando")
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").foregroundStyle(server.tag.color)
                Text(command)
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.09, green: 0.094, blue: 0.114)))
            .environment(\.colorScheme, .dark)
            Text(footnote(credential))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footnote(_ credential: Credential?) -> String {
        switch credential?.kind {
        case nil, .agent?:
            return "O ssh roda no terminal como de costume: senhas e códigos são digitados lá."
        default:
            return "Senha, passphrase e códigos 2FA são pedidos pelo Rosen, que precisa estar aberto até o login terminar."
        }
    }
}

private struct LatencyKey: Equatable {
    let host: String, port: Int, user: String, options: [String]
    init(_ s: Server) { host = s.host; port = s.port; user = s.user; options = s.extraOptions }
}

struct ServerHero: View {
    @Environment(AppStore.self) private var store
    let server: Server
    let probe: LatencyProbe

    var body: some View {
        let terminal = TerminalApp.preferred
        let opening = store.openingServers.contains(server.id)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ServerIcon(server: server, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(server.displayName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(server.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button { store.openServer(server.id) } label: {
                    Label(opening ? "Abrindo…" : "Abrir no \(terminal.title)", systemImage: "terminal.fill")
                }
                .buttonStyle(PillButtonStyle(fill: server.tag.color, filled: true))
                .disabled(opening)
                .help("Abrir uma sessão SSH no \(terminal.title) (⌘R)")
            }
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Abre uma aba nova no \(terminal.title). Troque o terminal nos Ajustes.")
                    .foregroundStyle(.secondary)
                Spacer()
                LatencyReadout(samples: probe.samples, available: probe.available, showsSparkline: true)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(22)
        .background(RosenBackdrop(color: server.tag.color))
    }
}

struct ServerSettingsList: View {
    @Environment(AppStore.self) private var store
    let server: Server
    let credential: Credential?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Configuração")
                Spacer()
                Button("Editar") { store.editServer(server.id) }
                    .buttonStyle(.link)
            }
            VStack(spacing: 0) {
                row("Servidor SSH") { mono("\(server.destination):\(server.port)") }
                divider
                row("Autenticação") { auth }
                if !server.extraOptions.isEmpty {
                    divider
                    row("Opções do ssh") { mono(server.extraOptions.joined(separator: "  ")) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
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

/// Ping até o servidor enquanto o detalhe está aberto (servidores não têm conexão viva para acompanhar).
@MainActor
@Observable
final class LatencyProbe {
    private(set) var samples: [Double?] = []
    private(set) var available = true

    func run(for server: Server) async {
        samples = []
        available = true
        guard let target = await TunnelSession.resolveTarget(server.makeTunnel()), !Task.isCancelled else { return }
        if target.viaProxy { available = false; return }
        var failures = 0
        while !Task.isCancelled {
            let ms = await TunnelSession.ping(target.host)
            guard !Task.isCancelled else { return }
            samples.append(ms)
            if samples.count > 30 { samples.removeFirst() }
            failures = ms == nil ? failures + 1 : 0
            available = failures < 3
            try? await Task.sleep(for: .seconds(failures >= 3 ? 30 : 5))
        }
    }
}

// MARK: - Editor

struct ServerEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let request: ServerEditorRequest
    @State private var draft: Server
    @State private var pasteText = ""
    @State private var pasteFeedback: TunnelEditor.PasteFeedback?
    @State private var showNewCredential = false
    @State private var extraOptionsText: String
    @State private var pendingIdentity: String?
    @FocusState private var focus: TunnelEditor.Field?

    init(request: ServerEditorRequest) {
        self.request = request
        _draft = State(initialValue: request.server)
        _extraOptionsText = State(initialValue: request.server.extraOptions.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .onAppear { focus = request.isNew ? .paste : .name }
        .sheet(isPresented: $showNewCredential) {
            CredentialEditorSheet { id in draft.credentialID = id }
                .environment(store)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ServerIcon(server: draft, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.isNew ? "Novo servidor" : draft.displayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(SSHCommand.displayString(for: draft, credential: draft.credentialID.flatMap(store.credential)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RosenBackdrop(color: draft.tag.color, radius: 0).animation(.smooth, value: draft.tag))
    }

    private var form: some View {
        Form {
            if request.isNew {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                        TextField("Colar comando", text: $pasteText, prompt: Text("Cole um comando ssh para preencher tudo"))
                            .textFieldStyle(.plain)
                            .font(.body.monospaced())
                            .focused($focus, equals: .paste)
                            .onChange(of: pasteText) { _, value in applyPaste(value) }
                            .labelsHidden()
                        if let clip = NSPasteboard.general.string(forType: .string),
                           pasteText.isEmpty, SSHCommandParser.parse(clip) != nil {
                            Button("Colar") { pasteText = clip }.controlSize(.small)
                        }
                    }
                    if let feedback = pasteFeedback {
                        switch feedback {
                        case .ok(let message):
                            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        case .invalid:
                            Label("Não reconheci esse comando ssh. Confira ou preencha abaixo.", systemImage: "questionmark.circle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                    }
                }
            }

            Section("Identificação") {
                TextField("Nome", text: $draft.name, prompt: Text(draft.host.isEmpty ? "Ex.: Produção" : draft.destination))
                    .focused($focus, equals: .name)
                LabeledContent("Cor") { ColorTagPicker(selection: $draft.tag) }
            }

            Section("Servidor SSH") {
                TextField("Host", text: $draft.host, prompt: Text("servidor.com, IP ou alias do ~/.ssh/config"))
                    .focused($focus, equals: .host)
                TextField("Usuário", text: $draft.user, prompt: Text("opcional — usa o do ~/.ssh/config"))
                TextField("Porta SSH", value: $draft.port, format: .number.grouping(.never))
                    .monospacedDigit()
            }

            Section("Autenticação") {
                Picker("Credencial", selection: $draft.credentialID) {
                    Label("Padrão do sistema (ssh-agent)", systemImage: "person.badge.key").tag(UUID?.none)
                    if !store.credentials.isEmpty { Divider() }
                    ForEach(store.credentials) { c in
                        Label("\(c.displayName) — \(c.kind.title)", systemImage: c.kind.symbol).tag(UUID?.some(c.id))
                    }
                }
                HStack {
                    if draft.credentialID == nil, let identity = pendingIdentity {
                        Label("Ao salvar, crio a credencial “\((identity as NSString).lastPathComponent)” para \(identity).",
                              systemImage: "sparkles")
                            .foregroundStyle(Color.accentColor).font(.callout)
                    } else if let c = draft.credentialID.flatMap(store.credential), let problem = c.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    } else {
                        Label("Senhas e chaves ficam no cofre criptografado.", systemImage: "lock.shield")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button("Nova credencial…") { showNewCredential = true }
                }
            }

            Section {
                TextField("Opções -o", text: $extraOptionsText, prompt: Text("ProxyJump=bastion, Compression=yes"))
                    .font(.body.monospaced())
                    .onChange(of: extraOptionsText) { _, text in
                        draft.extraOptions = text.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            } header: {
                Text("Avançado")
            } footer: {
                Text("Opções -o são passadas direto ao ssh.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var validationIssue: String? {
        if draft.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Informe o host do servidor." }
        if !(1...65535).contains(draft.port) { return "A porta deve estar entre 1 e 65535." }
        return nil
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let issue = validationIssue {
                Label(issue, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancelar", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if request.isNew {
                Button("Só salvar") { commit(open: false) }
                    .disabled(validationIssue != nil)
                    .keyboardShortcut("s")
                Button("Salvar e abrir") { commit(open: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationIssue != nil)
            } else {
                Button("Salvar") { commit(open: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationIssue != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func commit(open: Bool) {
        var s = draft
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.user = s.user.trimmingCharacters(in: .whitespaces)
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if s.credentialID == nil, let identity = pendingIdentity {
            s.credentialID = store.credentialID(forIdentityFile: identity)
        }
        store.save(s)
        dismiss()
        if open { store.openServer(s.id) }
    }

    private func applyPaste(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { pasteFeedback = nil; return }
        guard let parsed = SSHCommandParser.parse(text) else {
            withAnimation(.snappy) { pasteFeedback = .invalid }
            return
        }
        var s = parsed.server
        s.id = draft.id
        s.name = draft.name
        s.tag = draft.tag
        s.createdAt = draft.createdAt
        if let identity = parsed.identityFile {
            s.credentialID = store.existingCredentialID(forIdentityFile: identity)
            pendingIdentity = s.credentialID == nil ? identity : nil
        } else {
            s.credentialID = draft.credentialID
            pendingIdentity = nil
        }
        withAnimation(.snappy) {
            draft = s
            extraOptionsText = s.extraOptions.joined(separator: ", ")
            pasteFeedback = .ok(parsed.identityFile != nil ? "Pronto! Preenchi servidor e chave." : "Pronto! Preenchi o servidor.")
        }
    }
}
