# Ajustes do terminal, barra de menus e latência

> Status: done · Ordem: 08 · Depende de: 07

## Objetivo
Escolher o terminal nos Ajustes, abrir servidores pela barra de menus e mostrar latência no detalhe.

## Contexto
- Arquivos: `SettingsView` (em `RosenApp.swift` ou onde estiver), `Views/MenuBarView.swift`, `ServerDetailView.swift`, `RosenCore/Latency.swift`.
- Picker de terminal só com os instalados; aviso se o escolhido sumir.
- Latência: reaproveitar o ping ICMP dos túneis, medindo enquanto o detalhe do servidor está visível (não há "conectado" para servidores).

## Critérios de aceite
- [x] Ajustes → Terminal: Warp/Terminal.app; a escolha é usada ao conectar.
- [x] Barra de menus lista servidores; clicar abre no terminal.
- [x] Detalhe mostra latência atual e mini gráfico; para ao sair da tela.

## Fora de escopo
- Ping em segundo plano para todos os servidores.

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
