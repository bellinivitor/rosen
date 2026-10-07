# Spike: como o Warp roda um comando ao abrir

> Status: done · Ordem: 01 · Depende de: —

## Objetivo
Descobrir, na versão instalada do Warp (0.2026.09.30), um jeito confiável de abrir uma aba/janela já executando um comando, para basear o `WarpLauncher`.

## Contexto
- O Warp registra o esquema `warp://`. `~/.warp` tem `tab_configs/` (TOML) e não tem `launch_configurations/`, sinal de que o formato pode ter mudado.
- Candidatos, em ordem:
  1. Launch Configuration YAML em `~/.warp/launch_configurations/<nome>.yaml` (`commands: - exec: …`) + `open warp://launch/<nome>`.
  2. `tab_configs` TOML com comando de startup, se houver chave suportada e URL para abrir.
  3. `open -a Warp script.command` (o Warp executa scripts abertos com ele?).
- Restrições: nada destrutivo em `~/.warp` (arquivos de teste com prefixo `rosen-`, removidos ao final).

## Critérios de aceite
- [x] Resultado de cada candidato registrado nesta task (funciona? nova aba ou janela? o arquivo de config precisa persistir enquanto a aba abre?).
- [x] Mecanismo escolhido e formato exato do arquivo/URL documentados aqui.
- [x] Se nenhum funcionar: plano B registrado (ex.: só Terminal.app na v1) e o usuário avisado.

## Fora de escopo
- Código de produção.

## Definição de pronto
- [x] Achados registrados nesta task
- [x] Arquivos de teste removidos
- [x] Commit depois do teste do usuário

## Achados (2026-10-07, Warp 0.2026.09.30)
- O `Info.plist` do Warp declara `CFBundleDocumentTypes` com papel **Shell** para `com.apple.terminal.shell-script` (`.command`) e `public.unix-executable`.
- **Candidato 3 funciona:** `open -a Warp /caminho/rosen-test.command` (script 0700) executou o script num TTY real (`tty=/dev/ttys006`, `TERM_PROGRAM=WarpTerminal`). Serve para `ssh -t` interativo.
- Candidatos 1 e 2 (Launch Configuration YAML / `tab_configs` TOML) **não foram necessários**: a versão atual não tem `~/.warp/launch_configurations/` e o formato `tab_configs` é voltado a worktrees; dependeria de recurso instável.
- **Decisão:** Warp e Terminal.app usam o mesmo mecanismo — gravar `connect.command` (0700) no `ConnectionWorkspace` e chamar `open -a <bundle> connect.command` (via `NSWorkspace.open(_:withApplicationAt:)`). O script precisa existir só até o terminal iniciá-lo; a limpeza de 2 min cobre isso.
- Arquivo de teste ficou só no scratchpad da sessão (nada em `~/.warp`).
