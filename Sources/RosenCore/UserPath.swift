import Foundation

/// O `PATH` que o `ssh` recebe do Rosen.
///
/// Um app aberto pelo Finder, pelo Dock ou pelo `open` é iniciado pelo `launchd` e herda um
/// ambiente mínimo, com `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Ele não passa pelo `.zprofile`
/// do shell do usuário, então não enxerga nada instalado fora do sistema.
///
/// Isso só aparece quando o `ssh` precisa chamar outro programa: o `ProxyCommand` de um
/// `~/.ssh/config` (o caso do `cloudflared access ssh`) ou o `ProxyJump` com um bastion. O
/// ssh roda esse comando pelo shell do usuário, que responde
/// `zsh:1: command not found: cloudflared` mesmo com o binário instalado e funcionando no
/// terminal.
public enum UserPath {
    /// Onde ficam os binários instalados fora do sistema, na ordem em que o terminal do
    /// usuário costuma encontrá-los: Homebrew no Apple Silicon, Homebrew no Intel e MacPorts.
    public static let extraDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]

    /// O `PATH` mínimo de um processo iniciado pelo launchd, usado quando não há nenhum.
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// O `PATH` com os diretórios extras à frente, sem repetir o que já estava lá.
    ///
    /// Os extras vêm primeiro para que o binário do Homebrew ganhe do homônimo do sistema,
    /// como acontece no terminal. Diretórios vazios são descartados: um `::` no PATH vale
    /// como o diretório atual.
    public static func augmented(_ path: String?) -> String {
        let current: String
        if let path, !path.isEmpty { current = path } else { current = systemPath }

        var seen = Set<String>()
        var directories: [String] = []
        for directory in extraDirectories + current.split(separator: ":").map(String.init) {
            guard !directory.isEmpty, seen.insert(directory).inserted else { continue }
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }
}
