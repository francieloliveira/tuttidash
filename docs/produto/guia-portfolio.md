# Guia do portfólio — TuttiDash

Este guia mostra como operar **vários projetos** no TuttiDash sem editar código.
Ele pressupõe a instalação normal do app e das ferramentas (`tools/install.sh`).

> O norte atual ainda descreve «um projeto por vez». A agenda multi-projeto é
> opcional e sequencial; não trate o produto como multiusuário ou concorrente
> enquanto o §1 do norte não for atualizado pelo dono.

## 1. Cadastrar dois projetos

1. Abra **Ajustes › Lanes › Projetos**.
2. Ligue o primeiro projeto e escolha:
   - o projeto do Linear;
   - o repositório do GitHub;
   - a pasta do repositório neste Mac;
   - a prova (`{suite}` no lugar do teste);
   - os caminhos protegidos.
3. Em **Avançado**, ajuste prioridade, orçamento por esforço, timeouts e máximo
   de lanes/tarefas.
4. Se quiser acompanhar gestão, preencha `planejamento.objetivo`, `situacao`,
   `inicio`, `alvo` e `marcos` no config (o app preserva; a edição visual ainda
   não cobre esses campos).
5. Repita para o segundo projeto.
5. Use **Tornar principal** para o projeto que deve ser o padrão quando a agenda
   estiver desligada.

O cadastro fica em `~/Library/Application Support/TuttiDash/config.json`.
A chave do Linear fica no Keychain do app; nenhum script a lê.

## 2. Agenda multi-projeto

Em **Ajustes › Lanes › Projetos**, ligue **Agenda multi-projeto**.

- desligada: o dispatcher trabalha só o projeto principal;
- ligada: o dispatcher alterna os projetos ativos, respeitando prioridade e
  mantendo a lane em andamento no projeto dela;
- o vigia percorre os projetos ativos no mesmo tick;
- o estado do vigia é separado em `~/.transcentia/bots/projetos/<id>.json`.

**Ainda é sequencial.** Não há dois projetos executando ao mesmo tempo e a mesma
lane não roda em dois projetos. Para desligar:

```json
{ "agenda": { "multiprojeto": false } }
```

## 3. Acompanhar

No app:

- **Dashboard** e **Lanes**: projeto do ciclo, lanes e custo;
- **Projetos**: cadastro, ligado/desligado, principal, prioridade, custo dos
  últimos 7 dias, claims/merges/duração e ação de trocar o principal;
- **Custos**: visão geral; o CLI separa por projeto.

No terminal:

```bash
python3 gasto.py planejamento
python3 gasto.py semanal
python3 gasto.py fluxo
python3 gasto.py auditoria --projeto <id>
python3 gasto.py relatorio --por projeto
```

## 4. Ver o que está quebrado

```bash
python3 gasto.py doutor
```

Confere config, pastas, ledger, eventos, proxy do Linear, `gh`, repo, `.git`,
worktrees e norte de cada projeto. `ok`, `aviso` e `erro` são separados; sai com
código 1 se houver erro.

## 5. Backup e restauração

```bash
python3 gasto.py backup --destino ~/tuttidash-backup.tar.gz
python3 gasto.py backup --destino ~/backup.tar.gz --incluir-config
python3 gasto.py restaurar --arquivo ~/backup.tar.gz
```

O backup leva estado, ledger e eventos; `config.json` só com `--incluir-config`.
A restauração confere manifesto e SHA-256 e recusa destino ocupado sem
`--forcar`.

## 6. Erros comuns

| Sintoma | O que conferir |
|---|---|
| «sem projeto» | Ajustes › Projetos e a chave `projetos` no config |
| Lane parada | `gasto doutor`; worktree e repo do projeto |
| Custo por projeto vazio | log antigo não tem cabeçalho; só novas execuções são atribuídas |
| Vigia não mergeia | prova remota, `[Revisor]` na head, `gasto doutor` |
| Agenda não alterna | `agenda.multiprojeto` ligado e mais de um projeto ativo |

## 7. Vários repositórios por projeto

O cadastro aceita `repos` (lista com `slug`, `repo`, `github`, `worktrees`,
`prova`, `protegidos` e `pastas_do_app`). O app preserva e o Python lê. No claim,
o card escolhe o repositório pelo rótulo `repo:<slug>`; sem rótulo, usa o principal.
O estado grava `repo_slug` e o dispatcher acompanha a lane no repositório certo.
O vigia revisa e mergeia **cada repo do projeto** no tick, com chave de estado
`app` para o primeiro e `<slug>` para os demais. Cada repo pode ter seu `entrega`
e a instalação da main usa o repo do último merge.

## 8. Empacotar uma versão

```bash
tools/release.sh
tools/release.sh --notarizar <perfil-do-notarytool>
```

O script exige árvore git limpa, roda as suítes, chama o build assinado, gera
`dist/TuttiDash-<versão>-<build>.zip` e o SHA-256. Sem `--notarizar`, o zip fica
assinado mas não notarizado.

## 9. O que ainda não existe

- dois projetos executando ao mesmo tempo;
- múltiplos repositórios por projeto (FRA-711);
- sessão/estado namespaced para a mesma lane em projetos diferentes;
- operação headless sem o app aberto;
- distribuição assinada/notarizada.

Enquanto esses itens não fecharem, use a agenda como rodízio, não como
concorrência.
