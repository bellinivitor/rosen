# 01 — Servidores SSH

> Status: done

## Objetivo
Uma seção **Servidores** no Rosen: cadastrar servidores no cofre e abrir uma sessão SSH interativa no terminal escolhido nos Ajustes (Warp e Terminal.app na v1), reaproveitando credenciais, Touch ID e o askpass por FIFO.

## Critérios de aceite
- [ ] Cadastrar, editar, duplicar e excluir servidores; colar um comando `ssh` preenche o formulário.
- [ ] **Conectar** (`⌘R`) abre uma aba no Warp (ou Terminal.app) com o `ssh` já rodando.
- [ ] Senha/passphrase salva é entregue pelo Rosen (com Touch ID se exigido); sem segredo salvo, o painel pergunta e oferece salvar.
- [ ] Chave guardada no cofre nunca fica em disco além do login (diretório temporário removido).
- [ ] Importar hosts do `~/.ssh/config`, escolhendo quais.
- [ ] Servidores na barra de menus; latência no detalhe.
- [ ] "Criar túnel a partir deste servidor".
- [ ] Cofres antigos continuam abrindo; `make test` passa.

## Decisões
- Terminais na v1: **Warp + Terminal.app**, atrás de uma interface `TerminalLauncher` (iTerm2/Ghostty/WezTerm depois).
- Segredos no terminal externo: **askpass do Rosen + Touch ID** (requer o Rosen aberto; fechado, o ssh pergunta no terminal).
- Modelo: **`Server` independente de `Tunnel`**; só um atalho copia host/porta/usuário/credencial para um túnel novo. Sem migração do cofre.
- Importar `~/.ssh/config`: **nesta feature**, manual (botão + seleção).
- O terminal executa um **script privado por conexão** (0700, no `ConnectionWorkspace`) que define `SSH_ASKPASS*`/`ROSEN_ASKPASS_*` e faz `exec /usr/bin/ssh …`. Nada secreto em argumento.
- Askpass só quando há credencial que não seja ssh-agent; com agent/sem credencial, `ssh` puro.
- Terminal.app via `open -a Terminal arquivo.command` (sem AppleScript → sem permissão de Automação).
- Limpeza: broker escuta até 2 min após o último pedido (ou após abrir, se nenhum pedido vier); então apaga o workspace.
- Flags interativas: `-t`, sem `-N`/`-v`; `StrictHostKeyChecking=accept-new` como nos túneis.

## Como testar
- `make test` (modelo, cofre antigo, parsers, geração de script/configs).
- Manual: `make run`, conectar a um servidor real pelo Warp e pelo Terminal.app com senha salva, chave no cofre e agent; conferir que `/tmp/rosen-*` some.
- `make snapshot` para revisão visual.

## Tasks
- [x] [01 — Spike: como o Warp roda um comando](01-spike-warp.md)
- [x] [02 — Modelo Server no cofre](02-modelo-server.md)
- [x] [03 — Comando ssh interativo e parser](03-comando-interativo.md)
- [x] [04 — Parser do ~/.ssh/config](04-ssh-config-parser.md)
- [x] [05 — TerminalLauncher (Warp e Terminal.app)](05-terminal-launcher.md)
- [x] [06 — ServerConnection e AppStore](06-server-connection.md)
- [x] [07 — Interface: barra lateral, detalhe e editor](07-interface-servidores.md)
- [x] [08 — Ajustes do terminal, barra de menus e latência](08-ajustes-menubar.md)
- [x] [09 — Importar ~/.ssh/config e criar túnel a partir do servidor](09-importacao.md)
- [x] [10 — README e capturas](10-docs.md)
