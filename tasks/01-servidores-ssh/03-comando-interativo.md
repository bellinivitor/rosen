# Comando ssh interativo e parser

> Status: done · Ordem: 03 · Depende de: 02

## Objetivo
Gerar os argumentos do `ssh` interativo para um `Server` e reaproveitar o `SSHCommandParser` para criar um `Server` a partir de um comando colado.

## Contexto
- Arquivos: `Sources/RosenCore/SSHCommand.swift`, `Sources/RosenCore/SSHCommandParser.swift`, testes.
- Hoje `SSHCommand.arguments(for: Tunnel, auth:)` usa `-N -T -v` e opções de túnel; `displayString` mostra o comando legível.
- Interativo: `-t`, opções do usuário primeiro, `ServerAliveInterval=15`, `ConnectTimeout=10`, `StrictHostKeyChecking=accept-new`, `NumberOfPasswordPrompts=3`, `-p`, auth como hoje (`-i … IdentitiesOnly=yes` / password prefs), destino. Sem `ExitOnForwardFailure`, `-N`, `-v`.

## Critérios de aceite
- [x] `SSHCommand.interactiveArguments(for: Server, auth:)` sem segredos, com as flags acima.
- [x] `SSHCommand.displayString(for: Server, credential:)` legível e com aspas seguras.
- [x] Parser: `ssh -p 2222 -i ~/.ssh/k -J bastion user@host` vira `Server` (porta, usuário, `ProxyJump` em `extraOptions`, caminho da chave exposto para casar/criar credencial). Comando com `-L` também é aceito (ignora o encaminhamento).
- [x] Testes para cada caso acima, inclusive IPv6 e porta padrão omitida.

## Fora de escopo
- Executar o ssh; geração do script (task 05).

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
