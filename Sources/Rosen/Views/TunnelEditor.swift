import RosenCore
import SwiftUI

struct TunnelEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let request: EditorRequest
    @State private var draft: Tunnel
    @State private var pasteText: String
    @State private var pasteFeedback: PasteFeedback?
    @State private var listenPortTouched: Bool
    @State private var showNewCredential = false
    @State private var extraOptionsText: String
    /// Chave vinda de um `-i` colado, ainda sem credencial correspondente.
    @State private var pendingIdentity: String?
    @FocusState private var focus: Field?

    enum Field { case paste, name, host }
    enum PasteFeedback: Equatable { case ok(String), invalid }

    init(request: EditorRequest) {
        self.request = request
        _draft = State(initialValue: request.tunnel)
        _pasteText = State(initialValue: request.pastedCommand)
        _listenPortTouched = State(initialValue: !request.isNew)
        _extraOptionsText = State(initialValue: request.tunnel.extraOptions.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 600, height: 720)
        .onAppear {
            if !pasteText.isEmpty { applyPaste(pasteText) }
            focus = request.isNew ? .paste : .name
        }
        .sheet(isPresented: $showNewCredential) {
            CredentialEditorSheet { id in draft.credentialID = id }
                .environment(store)
        }
    }

    // MARK: Cabeçalho com prévia ao vivo

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.isNew ? "Novo túnel" : draft.displayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer()
                Text(SSHCommand.displayString(for: draft, credential: draft.credentialID.flatMap(store.credential)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
            TunnelStage(tunnel: draft, status: .idle, style: .compact, preview: true)
                .animation(.snappy, value: draft)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(RosenBackdrop(color: draft.tag.color, radius: 0).animation(.smooth, value: draft.tag))
    }

    // MARK: Formulário

    private var form: some View {
        Form {
            if request.isNew {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(Color.accentColor)
                        TextField("Colar comando", text: $pasteText,
                                  prompt: Text("Cole um comando ssh -L … para preencher tudo"))
                            .textFieldStyle(.plain)
                            .font(.body.monospaced())
                            .focused($focus, equals: .paste)
                            .onChange(of: pasteText) { _, value in applyPaste(value) }
                            .labelsHidden()
                        if let clip = NSPasteboard.general.string(forType: .string),
                           pasteText.isEmpty, SSHCommandParser.parse(clip) != nil {
                            Button("Colar") { pasteText = clip }
                                .controlSize(.small)
                        }
                    }
                    if let feedback = pasteFeedback {
                        switch feedback {
                        case .ok(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        case .invalid:
                            Label("Não reconheci esse comando ssh. Confira ou preencha abaixo.", systemImage: "questionmark.circle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                    }
                }
            }

            Section("Identificação") {
                TextField("Nome", text: $draft.name, prompt: Text(draft.suggestedName))
                    .focused($focus, equals: .name)
                LabeledContent("Cor") { ColorTagPicker(selection: $draft.tag) }
            }

            Section("Servidor SSH") {
                TextField("Host", text: $draft.host, prompt: Text("servidor.com, IP ou alias do ~/.ssh/config"))
                    .focused($focus, equals: .host)
                    .textContentType(.URL)
                TextField("Usuário", text: $draft.user, prompt: Text("opcional — usa o do ~/.ssh/config"))
                portField("Porta SSH", value: $draft.port)
            }

            Section {
                Picker("Tipo", selection: $draft.kind.animation(.snappy)) {
                    ForEach(ForwardKind.allCases) { kind in
                        Text("\(kind.title)  \(kind.flag)").tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                portField(listenLabel, value: Binding(
                    get: { draft.listenPort },
                    set: { draft.listenPort = $0; listenPortTouched = true }
                ))

                if draft.kind != .dynamic {
                    TextField(draft.kind == .remote ? "Host de destino (visto do Mac)" : "Host de destino (visto do servidor)",
                              text: $draft.targetHost, prompt: Text("127.0.0.1"))
                    portField("Porta de destino", value: $draft.targetPort)
                        .onChange(of: draft.targetPort) { _, port in
                            guard !listenPortTouched, draft.kind == .local else { return }
                            draft.listenPort = store.suggestedListenPort(for: port, excluding: draft.id)
                        }
                }

                if let other = store.conflict(for: draft) {
                    Label("A porta \(draft.listenPort) também é usada por “\(other.displayName)”. Os dois não poderão ficar ligados juntos.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Encaminhamento")
            } footer: {
                Text(draft.kind.explanation).font(.caption).foregroundStyle(.secondary)
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
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    } else {
                        Label("Senhas e chaves ficam no cofre criptografado.", systemImage: "lock.shield")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button("Nova credencial…") { showNewCredential = true }
                }
            }

            Section("Comportamento") {
                Toggle("Reconectar automaticamente se cair", isOn: $draft.autoReconnect)
                Toggle("Conectar ao abrir o Rosen", isOn: $draft.autoConnect)
            }

            Section {
                TextField(draft.kind == .remote ? "Endereço de escuta no servidor" : "Endereço de escuta no Mac",
                          text: $draft.bindAddress,
                          prompt: Text(draft.kind == .remote ? "padrão do servidor" : "127.0.0.1"))
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
                Text("Use 0.0.0.0 para aceitar conexões de outras máquinas da rede. Opções -o são passadas direto ao ssh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var listenLabel: String {
        switch draft.kind {
        case .local: return "Porta no seu Mac"
        case .remote: return "Porta no servidor"
        case .dynamic: return "Porta do proxy SOCKS"
        }
    }

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .monospacedDigit()
    }

    // MARK: Rodapé

    private var validationIssue: String? {
        if draft.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Informe o host do servidor." }
        for port in [draft.port, draft.listenPort] + (draft.kind == .dynamic ? [] : [draft.targetPort]) where !(1...65535).contains(port) {
            return "Portas devem estar entre 1 e 65535."
        }
        if draft.kind != .dynamic, draft.targetHost.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Informe o host de destino."
        }
        return nil
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let issue = validationIssue {
                Label(issue, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button("Cancelar", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if request.isNew {
                Button("Só salvar") { commit(connect: false) }
                    .disabled(validationIssue != nil)
                    .keyboardShortcut("s")
                Button("Criar e conectar") { commit(connect: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationIssue != nil)
            } else {
                Button("Salvar") { commit(connect: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationIssue != nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.snappy, value: validationIssue)
    }

    private func commit(connect: Bool) {
        var t = draft
        t.host = t.host.trimmingCharacters(in: .whitespaces)
        t.user = t.user.trimmingCharacters(in: .whitespaces)
        t.name = t.name.trimmingCharacters(in: .whitespaces)
        t.targetHost = t.targetHost.trimmingCharacters(in: .whitespaces)
        t.bindAddress = t.bindAddress.trimmingCharacters(in: .whitespaces)
        if t.credentialID == nil, let identity = pendingIdentity {
            t.credentialID = store.credentialID(forIdentityFile: identity)
        }
        store.save(t, connectAfter: connect)
        dismiss()
    }

    // MARK: Colar comando

    private func applyPaste(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { pasteFeedback = nil; return }
        guard let parsed = SSHCommandParser.parse(text) else {
            withAnimation(.snappy) { pasteFeedback = .invalid }
            return
        }
        var t = parsed.tunnel
        t.id = draft.id
        t.name = draft.name
        t.tag = draft.tag
        t.autoConnect = draft.autoConnect
        t.autoReconnect = draft.autoReconnect
        t.createdAt = draft.createdAt
        if !parsed.hasForward {
            // Só servidor: mantém o encaminhamento que já estava no rascunho.
            t.kind = draft.kind
            t.bindAddress = draft.bindAddress
            t.listenPort = draft.listenPort
            t.targetHost = draft.targetHost
            t.targetPort = draft.targetPort
        }
        if let identity = parsed.identityFile {
            t.credentialID = store.existingCredentialID(forIdentityFile: identity)
            pendingIdentity = t.credentialID == nil ? identity : nil
        } else {
            t.credentialID = draft.credentialID
            pendingIdentity = nil
        }
        withAnimation(.snappy) {
            draft = t
            extraOptionsText = t.extraOptions.joined(separator: ", ")
            listenPortTouched = true
            var message = "Pronto! Preenchi servidor\(parsed.hasForward ? ", portas" : "")"
            if parsed.identityFile != nil { message += " e chave" }
            pasteFeedback = .ok(message + ".")
        }
    }
}
