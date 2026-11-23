# Multi-projeto — implementado

> Documento técnico do que já existe no código. O norte foi atualizado em
> 23/11/2026: o produto percorre um ou mais projetos e a lane é agnóstica de
> projeto. A agenda continua **desligada por padrão**.

## Estado (23/11/2026)

O núcleo FRA-702..715 está no código e testado: projeto no estado/log/ledger,
custo por projeto, limites por projeto, agenda sequencial, modo simultâneo
experimental, vigia por ciclo, multi-repo, página de portfólio e planejamento.

Proposta aplicada: [proposta-norte-multiprojeto.md](proposta-norte-multiprojeto.md).
Estado card a card: [backlog-status.md](backlog-status.md).

Ainda fora desta entrega: alguns arquivos auxiliares globais, isolamento real
(FRA-719) e distribuição notarizada (FRA-720). O guia de uso está em
[docs/produto/guia-portfolio.md](guia-portfolio.md).

## O que já funciona

| Peça | Onde | Comportamento |
|---|---|---|
| Identidade no estado | `lanes/dispatcher.py`, `gasto_lanes/estado.py` | `lane-<lane>.json`/`claim-<lane>.json` gravam `projeto`/`projeto_nome`; no simultâneo viram `lane-<projeto>-<lane>.json`/`claim-<projeto>-<lane>.json`. |
| Log atribuível | `lanes/run_lane.sh`, `gasto_lanes/parser.py` | O log começa com `{"type":"tutti_projeto","projeto":"<id>","nome":"<nome>"}`; log antigo fica sem projeto, sem ser descartado. |
| Custo por projeto | `gasto_lanes/ledger.py`, `report.py`, `cli.py` | O ledger grava `projeto`/`projeto_nome`; `relatorio` tem a dimensão `projeto` e o filtro `--projeto ID,NOME`. |
| Limites por projeto | `gasto_lanes/projetos.py`, `lanes/dispatcher.py` | `operacao.budget_usd`, `lane_timeout_min`, `proof_timeout_min`, `max_lanes` e `max_tarefas_por_lane`; vazio/0 herda o global `lanes.*`. |
| Prioridade | `gasto_lanes/projetos.py` | `prioridade` (0–9) entra na ordem inicial da agenda; não dá exclusividade. |
| Agenda | `gasto_lanes/agenda.py` | Rodízio entre projetos ativos, com prioridade na ordem inicial e lane em andamento mandando. Desligada por padrão. |
| Vigia por ciclo | `bots/watch.py` | Com a agenda ligada, percorre todos os projetos ativos no mesmo tick, aponta `REPOS`/ids e isola o estado por projeto. |
| Projeto no painel | `apps/notch-mac` | O topo mostra o projeto do ciclo; a página **Projetos** lista cadastro, estado, prioridade, custo de 7 dias, fluxo e lanes/ocupação, e permite tornar outro projeto principal. A lane mostra o projeto no detalhe. |
| Eventos | `gasto_lanes/eventos.py` | Claim, finalize e merge viram linhas JSONL com projeto/card/lane/etapa; `gasto eventos` lê e filtra. |
| Fluxo | `gasto_lanes/fluxo.py` | `gasto fluxo` conta claims, finais, merges, falhas e paradas por projeto, com duração média claim→finalize; a página **Projetos** mostra o mesmo resumo. |
| Relatório | `gasto_lanes/semanal.py` | `gasto semanal` gera o relatório dos últimos 7 dias por projeto, com custo, execuções, fluxo e «sem medida». |
| Diagnóstico | `gasto_lanes/doutor.py` | `gasto doutor` confere config, pastas, repos, worktrees, norte, proxy do Linear e `gh`, com erro/aviso separados. |
| Backup | `gasto_lanes/backup.py` | `gasto backup` exporta estado/ledger/eventos (config opcional) com manifesto e SHA-256; `gasto restaurar` confere e recusa destino ocupado sem `--forcar`. |
| Auditoria | `gasto_lanes/auditoria.py` | `gasto auditoria` filtra a trilha de eventos por projeto, card, etapa e data. |
| Planejamento | `gasto_lanes/planejamento.py` | `gasto planejamento` mostra ordem, próximo, ocupação, custo, fluxo e sinais por projeto. |
| Notificação | `gasto_lanes/integracoes.py` | `gasto notificar` e `gasto semanal --enviar` mandam texto ao webhook configurado, desligado por padrão. |
| Retenção | `gasto_lanes/retencao.py` | `gasto retencao` conta/poda eventos e ledger por data; sem `--aplicar` não grava e linha sem data é mantida. |
| Segurança | `gasto_lanes/seguranca.py` | `gasto seguranca` audita 0700/0600 e symlinks no estado/config/ledger; `--corrigir` aplica. |
| Release | `tools/release.sh` | Build assinado, zip e SHA-256; `--notarizar` usa `notarytool` quando há perfil. |
| Headless | `lanes/dispatcher.py`, `bots/watch.py`, `AppDelegate.swift` | `agenda.headless: true` mantém o proxy do Linear ao sair do app e deixa dispatcher/vigia trabalharem pelo proxy vivo; sem app e sem proxy, nada roda. |
| Multi-repo | `gasto_lanes/projetos.py` | Cadastro `repos`, claim pelo rótulo `repo:<slug>`, `repo_slug` no estado e vigia revisando/mergeando cada repo do projeto. |

## Como ligar a agenda

No `config.json`:

```json
{
  "agenda": { "multiprojeto": true },
  "projetos": [
    { "id": "…", "nome": "A", "ativo": true, "prioridade": 2, "repo": "~/A" },
    { "id": "…", "nome": "B", "ativo": true, "prioridade": 0, "repo": "~/B" }
  ]
}
```

Com a agenda ligada, o dispatcher:

1. continua no projeto da lane que já está rodando;
2. sem lane rodando, escolhe o próximo da lista (maior `prioridade` primeiro);
3. grava o último escolhido em `~/.transcentia/lanes/agenda.json`;
4. atualiza o cache `linear-ids/<projeto>.json` antes de pedir cards.

Desligada, o comportamento é o de antes: só o projeto `padrao` (ou o primeiro ativo).

## Modo simultâneo (experimental)

Com `agenda.simultaneo: true`, o dispatcher tenta assumir, no mesmo ciclo, um card
In Progress por lane livre, de projetos diferentes, e puxa **um card do Todo por
projeto** quando sobra vaga. Ele **só usa lane explícita** (não escolhe lane
automática). O estado e a sessão da mesma lane levam o slug do projeto
(`lane-<projeto>-<lane>.json` e sessão `lane-<projeto>-<lane>`); a janela de tmux
ganha um painel para cada sessão namespaced. Sem a flag, nada muda.
A flag aparece em Ajustes › Lanes › Projetos.

```json
{ "agenda": { "multiprojeto": true, "simultaneo": true } }
```

A mesma lane pode ter uma vaga em cada projeto; a promoção do Todo é um card por
projeto por ciclo. A janela de tmux mostra um painel por sessão; o painel do app
também lê as duas.

## Modo headless (experimental)

Com `agenda.headless: true`, ao sair do app:

- o app **não** mata o proxy do Linear nem os agentes;
- o dispatcher e o vigia do launchd continuam, desde que o proxy esteja vivo;
- o token continua só na memória do proxy; fechar o app não o devolve ao disco.

Sem o proxy vivo (ou após reboot), o dispatcher e o vigia voltam a exigir o app.
A opção fica em Ajustes › Lanes › Projetos.

## Limites conhecidos desta fase

- **Simultâneo é experimental.** Exige lane explícita; a janela de tmux cria um
  painel extra para a sessão namespaced.
- **Arquivos auxiliares.** Stop já é por sessão; alguns limites/marcadores ainda
  são globais por lane.
- **O vigia percorre todos os projetos ativos no tick.** Cada um tem seu
  `~/.transcentia/bots/projetos/<id>.json`; `watch.repos` manual não é usado nesse modo.
- **Multi-repo é por card.** O rótulo `repo:<slug>` escolhe o repo; sem rótulo, o principal.
- **Isolamento real ainda não existe.** A lane roda com o usuário do Mac (FRA-719).

## Como conferir

```bash
python3 -m unittest tests.test_multiprojeto tests.test_eventos tests.test_agenda \
  tests.test_parser tests.test_ledger tests.test_report tests.test_cli tests.test_projetos \
  tests.test_estado tests.test_lanes_v2
cd apps/notch-mac && swift test --disable-sandbox --filter ProjetosConfigTests
cd apps/notch-mac && swift test --disable-sandbox --filter ParserLogTests
cd apps/notch-mac && swift test --disable-sandbox --filter EstadoTests
```

No DSH, alguns testes que tocam `~/Library`, Keychain ou `sudo` falham por
permissão do sandbox; não são regressão do código.

## Rollback

```json
{ "agenda": { "multiprojeto": false } }
```

O dispatcher volta ao `padrao()` no ciclo seguinte. Os campos novos no estado, no
log e no ledger são aditivos; log antigo continua legível.
