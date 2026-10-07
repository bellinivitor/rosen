# ServerConnection e AppStore

> Status: done · Ordem: 06 · Depende de: 02, 03, 05

## Objetivo
Orquestrar uma conexão interativa: workspace temporário, chave temporária, broker do askpass com Touch ID e painel de pedido, abertura no terminal e limpeza. E guardar servidores no `AppStore`.

## Contexto
- Arquivos: `Sources/Rosen/ServerConnection.swift` (novo), `Sources/Rosen/AppStore.swift`.
- Reaproveitar de `TunnelSession`: `ConnectionWorkspace`, `writeKey`, `AskpassBroker`, `answer(prompt:)`/`storedSecret`/oferta de salvar, `Unlocker.shared.authorize`, `credential.problem`. Extrair helpers comuns se a duplicação ficar grande (sem mudar o comportamento dos túneis).
- Askpass só quando há credencial diferente de ssh-agent; senão o script roda `ssh` puro.
- Limpeza: até 2 min após o último pedido (ou após abrir, se nenhum vier); depois sobrescreve/apaga a chave e remove o workspace. Também no `shutdown` do app.
- `AppStore`: `servers` com `didSet { scheduleSave() }`, `payload` inclui servers, CRUD (`newServer`, `duplicate`, `delete`), `connectServer(id)`, ajuste `preferredTerminal` (UserDefaults, padrão Warp se instalado, senão Terminal).

## Critérios de aceite
- [x] Conectar com senha salva: o ssh no terminal recebe a senha sem digitar; com `requireUserPresence`, pede Touch ID antes.
- [x] Senha não salva: painel do Rosen pergunta e oferece salvar depois do login.
- [x] Chave no cofre: o arquivo temporário some depois do login/timeout.
- [x] Servidores persistem no cofre entre aberturas do app.
- [x] Túneis seguem funcionando igual.

## Fora de escopo
- Telas (task 07). Saber quando a sessão do terminal termina.

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
