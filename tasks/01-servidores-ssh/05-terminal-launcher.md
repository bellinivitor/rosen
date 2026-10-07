# TerminalLauncher (Warp e Terminal.app)

> Status: done · Ordem: 05 · Depende de: 01, 03

## Objetivo
Abrir um comando num terminal externo por uma interface extensível, com implementações para Warp (mecanismo da task 01) e Terminal.app.

## Contexto
- Arquivos novos: `Sources/RosenCore/TerminalLauncher.swift` (geração pura e testável) e a parte que chama `open`/`NSWorkspace` no app.
- `enum TerminalApp: String, Codable, CaseIterable { case warp, terminal }` com `title`, `bundleID` (`dev.warp.Warp-Stable`, `com.apple.Terminal`) e `isInstalled`.
- `ConnectScript.make(arguments:environment:)`: script `#!/bin/sh` com `export` das variáveis (`SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force`, `ROSEN_ASKPASS_REQ/RESP`) e `exec /usr/bin/ssh …` com aspas seguras (reaproveitar `shellQuote`). Gravado 0700 no `ConnectionWorkspace` como `connect.command`.
- Terminal.app: `open -a Terminal connect.command`.
- Warp: conforme a task 01 (arquivo de config com prefixo `rosen-` + URL, ou `open -a Warp`). Config temporária apagada depois.

## Critérios de aceite
- [x] Protocolo `TerminalLauncher` com `launch(script: URL, title: String) throws`.
- [x] Script gerado executa o ssh certo, sem segredos, com aspas corretas (teste com espaços e aspas simples no caminho).
- [x] Conteúdo do arquivo de config do Warp gerado e testado.
- [x] Erro claro em pt-BR se o terminal não estiver instalado ou o `open` falhar.

## Fora de escopo
- iTerm2, Ghostty, WezTerm. Broker/askpass (task 06).

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
