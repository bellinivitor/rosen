# Parser do ~/.ssh/config

> Status: done · Ordem: 04 · Depende de: 02

## Objetivo
Ler os blocos `Host` do `~/.ssh/config` e transformá-los em candidatos a `Server` para a importação.

## Contexto
- Arquivo novo: `Sources/RosenCore/SSHConfigParser.swift` + testes.
- Função pura sobre o texto (`parse(_ text: String) -> [SSHConfigHost]`), e um helper que lê o arquivo do disco.
- Chaves: `Host` (múltiplos aliases), `HostName`, `User`, `Port`, `IdentityFile`, `ProxyJump`. Case-insensitive, aceita `Chave=Valor` e `Chave Valor`, comentários e aspas.
- Ignorar padrões com `*`, `?` ou `!`, e blocos `Match`. `Include`: seguir caminhos relativos a `~/.ssh` (sem curingas complexos; um nível de glob simples basta) ou registrar como fora de escopo se ficar caro.

## Critérios de aceite
- [x] Um host vira candidato com alias como nome, `host` = alias (o ssh resolve o resto pelo config) e os campos lidos para exibição.
- [x] Curingas e `Match` ignorados; `Host a b` gera dois candidatos.
- [x] Testes cobrindo formatos, comentários, aspas, curingas, `IdentityFile` com `~`.

## Fora de escopo
- UI de importação (task 09). Escrever no `~/.ssh/config`.

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
