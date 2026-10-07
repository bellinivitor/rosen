# Interface: barra lateral, detalhe e editor

> Status: done · Ordem: 07 · Depende de: 06

## Objetivo
Exibir e editar servidores na janela principal, ao lado dos túneis.

## Contexto
- Arquivos: `Sources/Rosen/Views/ContentView.swift` (`SidebarView`), novos `ServerDetailView.swift` e `ServerEditor.swift`, `RosenApp.swift` (comandos).
- Seguir o visual existente (`Components.swift`, `TunnelDetailView`, `TunnelEditor`).
- Seleção hoje é `UUID?` de túnel: generalizar para túnel ou servidor sem quebrar atalhos.
- Detalhe: nome, `user@host:porta`, credencial, comando equivalente (copiar `⇧⌘C`), botão **Abrir no <terminal>** (`⌘R`).
- Editor: campos do `Server`, colar comando `ssh` preenche (parser da task 03), escolher/criar credencial.
- Toolbar: menu "+" com Novo túnel (`⌘N`) e Novo servidor (`⌥⌘N`).

## Critérios de aceite
- [x] Seções "Túneis" e "Servidores" na barra lateral; selecionar mostra o detalhe certo.
- [x] Criar/editar/duplicar/excluir servidor pela UI e pelos atalhos.
- [x] Estado vazio de servidores com chamada para cadastrar/importar.
- [x] Telas de túnel sem regressão.

## Fora de escopo
- Ajustes, barra de menus, importação (tasks 08/09).

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
