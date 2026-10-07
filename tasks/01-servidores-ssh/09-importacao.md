# Importar ~/.ssh/config e criar túnel a partir do servidor

> Status: done · Ordem: 09 · Depende de: 04, 07

## Objetivo
Trazer hosts do `~/.ssh/config` em lote e criar um túnel a partir de um servidor sem redigitar.

## Contexto
- Arquivos: novo `Views/ImportSSHConfigView.swift`, `AppStore.swift`, `ServerDetailView.swift`.
- Sheet com a lista do `SSHConfigParser`, checkbox por host, marcando os que já existem (mesmo `host`) como importados.
- Hosts com `IdentityFile`: credencial "ssh-agent / ~/.ssh/config" por padrão (o ssh já usa o config), sem criar credenciais em massa.
- Criar túnel: abre o `TunnelEditor` com host/porta/usuário/credencial/`extraOptions` do servidor.

## Critérios de aceite
- [x] Importar N hosts selecionados cria N servidores, sem duplicar os existentes.
- [x] Arquivo ausente/vazio mostra mensagem clara.
- [x] "Criar túnel a partir deste servidor" abre o editor preenchido.

## Fora de escopo
- Sincronização contínua com o `~/.ssh/config`.

## Definição de pronto
- [x] Testes escritos e passando (`make test`, suíte completa sem quebrar)
- [x] Mutação manual nos arquivos tocados do RosenCore (não há ferramenta de mutação no projeto): inverter condições-chave e confirmar que algum teste quebra
- [x] Segue os padrões do projeto (Swift/SwiftUI, textos em pt-BR, decodificação tolerante no cofre)
- [x] Sem segredos, sem comando destrutivo, sem mudança de dependência
- [x] Commit depois do teste do usuário
