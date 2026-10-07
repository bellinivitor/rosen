# Modelo Server no cofre

> Status: done · Ordem: 02 · Depende de: —

## Objetivo
Criar o modelo `Server` e guardá-lo no `VaultPayload` sem quebrar cofres existentes.

## Contexto
- Arquivos: `Sources/RosenCore/Models.swift`, `Tests/RosenCoreTests/RosenCoreTests.swift`.
- Hoje `VaultPayload` tem `tunnels` e `credentials`; `Tunnel`/`Credential` usam `init(from:)` tolerante.
- Campos: `id`, `name`, `host`, `port` (22), `user`, `credentialID`, `tag`, `extraOptions`, `createdAt`. Extensão com `destination`, `displayName` (fallback `user@host`/host), `summary`.

## Critérios de aceite
- [x] `Server` Codable/Identifiable/Hashable/Sendable com decodificação tolerante.
- [x] `VaultPayload.servers` (default `[]`), decodificado com `decodeIfPresent`.
- [x] Teste: JSON de cofre antigo (sem `servers`) decodifica com `servers == []`.
- [x] Teste: ida e volta encode/decode preserva um servidor.

## Fora de escopo
- AppStore/UI (task 06/07). Relação com `Tunnel`.

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
