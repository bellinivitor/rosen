# Fonte do Cask. O Scripts/release.sh grava versão e sha256 aqui e copia para o tap
# bellinivitor/homebrew-rosen, de onde vem o:  brew install --cask bellinivitor/rosen/rosen
cask "rosen" do
  version "0.3.0-beta"
  sha256 "8ce4b84e7a02936732e35f2571dca15c8139693f2b5c2c848df0dae29954cda0"

  url "https://github.com/bellinivitor/rosen/releases/download/v#{version}/Rosen-#{version}.zip"
  name "Rosen"
  desc "Gerenciador nativo de túneis SSH"
  homepage "https://github.com/bellinivitor/rosen"

  depends_on macos: :sonoma

  app "Rosen.app"

  uninstall quit: "app.rosen.mac"

  zap trash: [
    "~/Library/Application Support/Rosen",
    "~/Library/Preferences/app.rosen.mac.plist",
    "~/Library/Saved Application State/app.rosen.mac.savedState",
  ]

  caveats <<~EOS
    O Rosen ainda não é assinado com um certificado de desenvolvedor Apple.
    Na primeira abertura, libere o app com:

      xattr -dr com.apple.quarantine #{appdir}/Rosen.app

    Túneis e segredos ficam num cofre criptografado (AES-256-GCM) cuja chave
    está no Keychain. Com --zap o cofre é apagado; a chave ("app.rosen.vault")
    pode ser removida no app Acesso às Chaves.
  EOS
end
