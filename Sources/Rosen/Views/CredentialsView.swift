import AppKit
import RosenCore
import SwiftUI

/// Janela de gerenciamento: lista à esquerda, edição ao vivo à direita.
struct CredentialsView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?
    @State private var pendingDeletion: Credential?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.credentials) { c in
                    CredentialRow(credential: c, usage: store.usage(of: c.id).count)
                        .tag(c.id)
                        .contextMenu {
                            Button("Excluir…", role: .destructive) { pendingDeletion = c }
                        }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { if let id = selection { pendingDeletion = store.credential(id) } }
            .overlay {
                if store.credentials.isEmpty {
                    ContentUnavailableView {
                        Label("Sem credenciais", systemImage: "key")
                    } description: {
                        Text("Crie uma para reutilizar a mesma chave ou senha em vários túneis.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Menu {
                        ForEach(CredentialKind.allCases) { kind in
                            Button { add(kind) } label: { Label(kind.longTitle, systemImage: kind.symbol) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Nova credencial")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let id = selection, store.credential(id) != nil {
                CredentialForm(credential: Binding(
                    get: { store.credential(id) ?? Credential() },
                    set: { store.upsert($0) }
                ), usage: store.usage(of: id))
                .id(id)
                .toolbar {
                    ToolbarItem {
                        Button(role: .destructive) { pendingDeletion = store.credential(id) } label: {
                            Label("Excluir", systemImage: "trash")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Escolha uma credencial", systemImage: "key.horizontal",
                                       description: Text("Ou crie uma nova com o botão +."))
            }
        }
        .navigationTitle("Credenciais")
        .onAppear { if selection == nil { selection = store.credentials.first?.id } }
        .confirmationDialog(
            "Excluir “\(pendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Excluir credencial", role: .destructive) {
                if let c = pendingDeletion {
                    store.deleteCredential(c.id)
                    if selection == c.id { selection = store.credentials.first?.id }
                }
                pendingDeletion = nil
            }
        } message: {
            let count = pendingDeletion.map { store.usage(of: $0.id).count } ?? 0
            Text(count > 0
                 ? "\(count) túnel(is) usam esta credencial e passarão a usar o padrão do sistema."
                 : "Os dados secretos serão removidos do cofre.")
        }
    }

    private func add(_ kind: CredentialKind) {
        let c = Credential(name: "", kind: kind, requireUserPresence: true)
        store.upsert(c)
        selection = c.id
    }
}

struct CredentialRow: View {
    let credential: Credential
    let usage: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: credential.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(usage == 0 ? "\(credential.kind.title), sem uso" : "\(credential.kind.title), em \(usage) túne\(usage == 1 ? "l" : "is")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let symbol = credential.protectionSymbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .help("Protegida por \(Unlocker.methodName)")
            }
            if credential.problem != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(credential.problem ?? "")
            }
        }
        .padding(.vertical, 3)
    }
}

/// Formulário reutilizado na janela de credenciais e na folha de “Nova credencial”.
struct CredentialForm: View {
    @Binding var credential: Credential
    var usage: [Tunnel] = []
    @State private var discovered: [URL] = []
    /// Segredos visíveis nesta tela (só depois do Touch ID, se a credencial for protegida).
    @State private var revealed = false
    @State private var unlocking = false
    private var unlocker: Unlocker { Unlocker.shared }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $credential.name, prompt: Text(credential.displayName))
                Picker("Tipo", selection: $credential.kind.animation(.snappy)) {
                    ForEach(CredentialKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!revealed)
            } footer: {
                Text(credential.kind.explanation).font(.caption).foregroundStyle(.secondary)
            }

            if revealed {
                switch credential.kind {
                case .keyFile: keyFileSection
                case .keyContent: keyContentSection
                case .password: passwordSection
                case .agent: agentSection
                }
                if credential.kind != .agent { protectionSection }
            } else {
                lockedSection
            }

            if let problem = credential.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            if !usage.isEmpty {
                Section("Usada por") {
                    ForEach(usage) { t in
                        HStack(spacing: 8) {
                            TunnelIcon(tunnel: t, size: 20)
                            Text(t.displayName)
                            Spacer()
                            Text(t.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            discovered = SSHKeyInspector.discoverKeys()
            revealed = !credential.needsUnlock || unlocker.isUnlocked
        }
        .onChange(of: unlocker.unlockedUntil) { _, until in
            // Mac bloqueou ou dormiu: esconde de novo.
            if until == nil, credential.needsUnlock { withAnimation(.snappy) { revealed = false } }
        }
    }

    // MARK: Proteção

    private var lockedSection: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: Unlocker.symbol)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.indigo.gradient)
                    .symbolEffect(.pulse, isActive: unlocking)
                VStack(spacing: 4) {
                    Text("Segredos protegidos")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("Use o \(Unlocker.methodName) para ver ou editar \(secretNoun).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    unlock()
                } label: {
                    Label("Desbloquear", systemImage: Unlocker.symbol)
                }
                .buttonStyle(PillButtonStyle(fill: .indigo, filled: true))
                .keyboardShortcut(.defaultAction)
                .disabled(unlocking)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        }
        .transition(.opacity)
    }

    private var protectionSection: some View {
        Section {
            Toggle(isOn: $credential.requireUserPresence.animation(.snappy)) {
                Label("Pedir \(Unlocker.methodName) para usar", systemImage: Unlocker.symbol)
            }
        } footer: {
            Text(protectionFooter).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var protectionFooter: String {
        if !credential.requireUserPresence {
            return "Qualquer pessoa com acesso a este Mac desbloqueado consegue conectar com esta credencial."
        }
        if !credential.hasStoredSecret {
            return credential.kind == .keyFile
                ? "Esta chave não tem passphrase guardada, então não há o que proteger: o ssh lê o arquivo direto."
                : "A proteção passa a valer assim que houver um segredo guardado."
        }
        let fallback = Unlocker.method == .touchID ? " Sem Touch ID disponível, a senha do Mac é pedida." : ""
        return "Pedido ao conectar um túnel com esta credencial e para mostrar os segredos aqui. Vale pelo tempo definido nos Ajustes e é revogado quando o Mac bloqueia.\(fallback)"
    }

    private var secretNoun: String {
        switch credential.kind {
        case .keyFile: return "a passphrase"
        case .keyContent: return "a chave privada"
        case .password: return "a senha"
        case .agent: return "a credencial"
        }
    }

    private func unlock() {
        unlocking = true
        Task {
            let ok = await unlocker.authorize(reason: "mostrar os segredos de “\(credential.displayName)”")
            unlocking = false
            if ok { withAnimation(.snappy) { revealed = true } }
        }
    }

    // MARK: Seções

    private var keyFileSection: some View {
        Section("Arquivo da chave") {
            HStack {
                TextField("Caminho", text: $credential.keyPath, prompt: Text("~/.ssh/id_ed25519"))
                    .font(.body.monospaced())
                Button("Escolher…") { if let path = pickFile() { credential.keyPath = Paths.abbreviate(path) } }
            }
            if !discovered.isEmpty {
                LabeledContent("Encontradas em ~/.ssh") {
                    HStack(spacing: 6) {
                        ForEach(discovered.prefix(5), id: \.self) { url in
                            let path = Paths.abbreviate(url.path)
                            Button(url.lastPathComponent) { credential.keyPath = path }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(credential.keyPath == path ? .accentColor : nil)
                        }
                    }
                }
            }
            SecretField(title: "Passphrase", text: $credential.passphrase, prompt: "opcional")
        }
    }

    private var keyContentSection: some View {
        Section {
            TextEditor(text: $credential.keyContent)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if credential.keyContent.isEmpty {
                        Text("-----BEGIN OPENSSH PRIVATE KEY-----\n…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Button("Importar de arquivo…") {
                    if let path = pickFile(), let text = try? String(contentsOfFile: path, encoding: .utf8) {
                        credential.keyContent = text
                        if credential.name.isEmpty { credential.name = (path as NSString).lastPathComponent }
                    }
                }
                Button("Colar") { credential.keyContent = NSPasteboard.general.string(forType: .string) ?? "" }
                Spacer()
                if !credential.keyContent.isEmpty {
                    Label(SSHKeyInspector.keyType(of: credential.keyContent), systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SecretField(title: "Passphrase", text: $credential.passphrase, prompt: "opcional")
        } header: {
            Text("Chave privada")
        } footer: {
            Text("Criptografada com AES-256-GCM. Você pode apagar o arquivo original depois de importar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var passwordSection: some View {
        Section {
            SecretField(title: "Senha", text: $credential.password, prompt: "senha do usuário SSH")
        } footer: {
            Text("Prefira chaves quando possível — são mais seguras que senhas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var agentSection: some View {
        Section {
            Label("Nada para configurar. O ssh vai usar o agente e o ~/.ssh/config.", systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
        }
    }

    private func pickFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Escolher"
        panel.message = "Escolha o arquivo da chave privada"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Folha usada a partir do editor de túnel.
struct CredentialEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onSave: (UUID) -> Void
    @State private var draft = Credential(kind: .keyFile, requireUserPresence: true)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nova credencial").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            CredentialForm(credential: $draft)
            Divider()
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar credencial") {
                    onSave(store.upsert(draft))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 540, height: 520)
    }
}
