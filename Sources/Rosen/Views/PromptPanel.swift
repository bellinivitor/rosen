import AppKit
import RosenCore
import SwiftUI

/// Mostra os pedidos do ssh (senha, passphrase, código) num painel flutuante,
/// um de cada vez, mesmo com a janela principal fechada.
@MainActor
final class PromptPresenter: NSObject, NSWindowDelegate {
    static let shared = PromptPresenter()

    private struct Item {
        let request: TunnelSession.InputRequest
        let completion: (TunnelSession.InputResponse) -> Void
    }

    private var queue: [Item] = []
    private var current: Item?
    private var panel: NSPanel?

    func present(_ request: TunnelSession.InputRequest, completion: @escaping (TunnelSession.InputResponse) -> Void) {
        queue.append(Item(request: request, completion: completion))
        showNext()
    }

    /// Fecha um pedido que deixou de valer (ex.: a conexão caiu enquanto o modal estava aberto).
    func dismiss(_ id: UUID) {
        if current?.request.id == id {
            finish(.cancel, notify: false)
        } else {
            queue.removeAll { $0.request.id == id }
        }
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item

        let view = PromptView(request: item.request) { [weak self] response in
            self?.finish(response, notify: true)
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = host
        panel.delegate = self
        panel.title = "Rosen"
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ response: TunnelSession.InputResponse, notify: Bool) {
        guard let item = current else { return }
        current = nil
        let closing = panel
        panel = nil
        closing?.delegate = nil
        closing?.close()
        if notify { item.completion(response) }
        // Pequena pausa para o próximo pedido não "piscar" por cima.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.showNext() }
    }

    // Fechar pelo botão vermelho = cancelar.
    func windowWillClose(_ notification: Notification) {
        finish(.cancel, notify: true)
    }
}

/// Quem pediu: um túnel ou um servidor.
struct PromptSubject {
    let name: String
    let destination: String
    let user: String
    let tag: TagColor
    let symbol: String

    init(_ t: Tunnel) {
        name = t.displayName; destination = t.destination; user = t.user; tag = t.tag; symbol = t.symbol
    }

    init(_ s: Server) {
        name = s.displayName; destination = s.destination; user = s.user; tag = s.tag; symbol = Server.symbol
    }
}

struct PromptView: View {
    let request: TunnelSession.InputRequest
    let onFinish: (TunnelSession.InputResponse) -> Void

    @State private var secret = ""
    @State private var revealed = false
    @State private var save = true
    @State private var protect = true
    @State private var shake = 0
    @FocusState private var focused: Bool

    private var subject: PromptSubject { request.subject }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                field
                if request.saveTarget != nil { saveOptions }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 20)
            Divider()
            footer
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focused = true
            if request.retry { withAnimation(.default) { shake += 1 } }
        }
    }

    // MARK: Partes

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                TagIcon(color: subject.tag.color, symbol: subject.symbol, size: 44)
                Image(systemName: headerSymbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.indigo.gradient))
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .offset(x: 5, y: 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("\(subject.name) (\(subject.destination))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RosenBackdrop(color: subject.tag.color, radius: 0))
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    if revealed {
                        TextField(placeholder, text: $secret)
                    } else {
                        SecureField(placeholder, text: $secret)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: revealed ? .monospaced : .default))
                .focused($focused)
                .onSubmit(submit)

                Button { revealed.toggle(); focused = true } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Ocultar" : "Mostrar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(request.retry ? Color.red.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .modifier(Shake(trigger: shake))

            if request.retry {
                Label(request.storedRejected
                      ? "O servidor recusou o que estava salvo. Digite de novo."
                      : "\(noun.capitalizedFirst) incorreta. Tente de novo.",
                      systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text("O ssh pediu: \(request.prompt)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private var saveOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $save.animation(.snappy)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Salvar no cofre do Rosen")
                    if let target = request.saveTarget {
                        Text("Guarda \(target), criptografada.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)

            if save {
                Toggle(isOn: $protect) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Pedir \(Unlocker.methodName) para usar", systemImage: Unlocker.symbol)
                        Text("Da próxima vez o túnel conecta sozinho, liberado pela \(Unlocker.method == .touchID ? "sua digital" : "senha do Mac").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.tertiary)
            Text(request.saveTarget != nil && save ? "Só é salva se o servidor aceitar." : "Enviada direto ao ssh, sem passar pelo disco.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancelar", role: .cancel) { onFinish(.cancel) }
                .keyboardShortcut(.cancelAction)
            Button("Conectar", action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(secret.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Textos

    private var noun: String {
        switch request.kind {
        case .password: return "senha"
        case .passphrase: return "passphrase"
        case .other: return "resposta"
        }
    }

    private var title: String {
        switch request.kind {
        case .password: return "Senha para conectar"
        case .passphrase(let path):
            if let name = request.keyName { return "Passphrase de “\(name)”" }
            return path.map { "Passphrase de \(($0 as NSString).lastPathComponent)" } ?? "Passphrase da chave"
        case .other: return "O servidor pediu uma confirmação"
        }
    }

    private var placeholder: String {
        switch request.kind {
        case .password: return "Senha de \(subject.user.isEmpty ? "usuário" : subject.user)"
        case .passphrase: return "Passphrase"
        case .other: return "Resposta (ex.: código de verificação)"
        }
    }

    private var headerSymbol: String {
        switch request.kind {
        case .password: return "ellipsis"
        case .passphrase: return "key.fill"
        case .other: return "number"
        }
    }

    private func submit() {
        guard !secret.isEmpty else { return }
        onFinish(.submit(secret: secret, save: save && request.saveTarget != nil, protect: protect))
    }
}

/// Tremidinha horizontal para "senha incorreta".
private struct Shake: GeometryEffect {
    var trigger: Int
    var animatableData: CGFloat {
        get { CGFloat(trigger) }
        set { progress = newValue }
    }
    private var progress: CGFloat = 0

    init(trigger: Int) {
        self.trigger = trigger
        progress = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(progress * .pi * 4), y: 0))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
