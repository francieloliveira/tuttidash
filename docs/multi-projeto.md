# Multi-projeto — fundação implementada

> Documento técnico do que já existe no código. O norte (`docs/produto/caminho.md`)
> continua dizendo «um projeto»; a agenda só liga por decisão do dono e o §1 ainda
> precisa ser atualizado por ele. Este documento não muda o norte.

## Estado (22/11/2026)

O núcleo da fundação FRA-702..705 está no código e testado: projeto no estado/log/ledger,
custo por projeto, limites por projeto, agenda sequencial, vigia por ciclo e página de
portfólio. A agenda continua **desligada por padrão** e o norte não foi alterado.

Proposta de mudança do norte: [proposta-norte-multiprojeto.md](proposta-norte-multiprojeto.md).

Ainda fora desta entrega: slots simultâneos (FRA-706), nome de sessão por projeto,
multi-repo (FRA-711), headless (FRA-718), segurança (FRA-719) e distribuição (FRA-720).
O guia de uso está em [docs/produto/guia-portfolio.md](guia-portfolio.md).

## O que já funciona

| Peça | Onde | Comportamento |
|---|---|---|
| Identidade no estado | `lanes/dispatcher.py`, `gasto_lanes/estado.py` | `lane-<lane>.json` e `claim-<lane>.json` gravam `projeto` e `projeto_nome`. |
| Log atribuível | `lanes/run_lane.sh`, `gasto_lanes/parser.py` | O log começa com `{"type":"tutti_projeto","projeto":"<id>","nome":"<nome>"}`; log antigo fica sem projeto, sem ser descartado. |
| Custo por projeto | `gasto_lanes/ledger.py`, `report.py`, `cli.py` | O ledger grava `projeto`/`projeto_nome`; `relatorio` tem a dimensão `projeto` e o filtro `--projeto ID,NOME`. |
| Limites por projeto | `gasto_lanes/projetos.py`, `lanes/dispatcher.py` | `operacao.budget_usd`, `lane_timeout_min`, `proof_timeout_min`, `max_lanes` e `max_tarefas_por_lane`; vazio/0 herda o global `lanes.*`. |
| Prioridade | `gasto_lanes/projetos.py` | `prioridade` (0–9) entra na ordem inicial da agenda; não dá exclusividade. |
| Agenda | `gasto_lanes/agenda.py` | Rodízio entre projetos ativos, com prioridade na ordem inicial e lane em andamento mandando. Desligada por padrão. |
| Vigia por ciclo | `bots/watch.py` | Com a agenda ligada, percorre todos os projetos ativos no mesmo tick, aponta `REPOS`/ids e isola o estado por projeto. |
| Projeto no painel | `apps/notch-mac` | O topo mostra o projeto do ciclo; a página **Projetos** lista o cadastro, o estado ligado/desligado, a prioridade, quem está no ciclo e o custo conhecido dos últimos 7 dias por projeto, e permite tornar outro projeto principal. Lanes e histórico de entregas de outros ciclos ainda não aparecem. |
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
automática) e **não roda a mesma lane em dois projetos**. Sem a flag, nada muda.
A flag aparece em Ajustes › Lanes › Projetos.

```json
{ "agenda": { "multiprojeto": true, "simultaneo": true } }
```

Ainda falta namespacing de sessão/estado para a mesma lane e a promoção do Todo por
projeto; por isso o modo é experimental e não está na interface.

## Limites conhecidos desta fase

- **É sequencial.** Um projeto por vez; ainda não há slots simultâneos (FRA-706).
- **O vigia percorre todos os projetos ativos no tick.** Cada um tem seu
  `~/.transcentia/bots/projetos/<id>.json`; `watch.repos` manual não é usado nesse modo.
- **Sessão e arquivos de estado ainda são globais.** Como só um projeto roda por
  vez, não colidem; a identidade por sessão/arquivo é o FRA-702 completo.
- **O painel ainda é single-project.** O heartbeat já traz `projects`, mas o notch
  não usa (FRA-708).
- **Nada disso muda o norte.** A mudança do §1 é o FRA-701, do dono.

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
