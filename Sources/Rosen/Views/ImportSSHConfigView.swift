import RosenCore
import SwiftUI

/// Escolhe hosts do ~/.ssh/config para virar servidores do Rosen.
struct ImportSSHConfigView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var hosts: [SSHConfigHost]?
    @State private var selected: Set<String> = []

    private var importable: [SSHConfigHost] { (hosts ?? []).filter { !store.isImported($0) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importar do ~/.ssh/config")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Cada host vira um servidor que usa o próprio alias: o ssh continua lendo HostName, chave e ProxyJump do seu config.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var content: some View {
        if let hosts {
            if hosts.isEmpty {
                ContentUnavailableView("Nenhum host encontrado", systemImage: "doc.text.magnifyingglass",
                                       description: Text("O ~/.ssh/config não tem blocos Host sem curingas."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(hosts, id: \.alias) { host in
                        let imported = store.isImported(host)
                        Toggle(isOn: Binding(
                            get: { imported || selected.contains(host.alias) },
                            set: { on in if on { selected.insert(host.alias) } else { selected.remove(host.alias) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(host.alias).font(.body.weight(.medium))
                                    if imported {
                                        Text("já importado").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(host.summary)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(imported)
                    }
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView("Sem ~/.ssh/config", systemImage: "doc.questionmark",
                                   description: Text("Não encontrei o arquivo \(Paths.abbreviate(SSHConfigParser.defaultURL.path))."))
                .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !importable.isEmpty {
                Button(selected.count == importable.count ? "Desmarcar todos" : "Marcar todos") {
                    selected = selected.count == importable.count ? [] : Set(importable.map(\.alias))
                }
                .buttonStyle(.link)
            }
            Spacer()
            Button("Cancelar", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(selected.isEmpty ? "Importar" : "Importar \(selected.count)") {
                let chosen = importable.filter { selected.contains($0.alias) }
                let n = store.importHosts(chosen)
                store.showToast(n == 1 ? "1 servidor importado" : "\(n) servidores importados")
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() {
        hosts = SSHConfigParser.load()
        selected = Set(importable.map(\.alias))
    }
}
