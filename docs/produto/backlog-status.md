# Backlog multi-projeto — estado

Atualizado em 23/11/2026. Commits relevantes: `5c28e9a`, `30774de`, `50c4cf9`,
`4de0cf3`, `a5d9269`, `3815bf7`, `f6df8e1`, `05fe30e`, `9c53f4c`, `526ebed`.

## Feito

| Card | O que está no código |
|---|---|
| FRA-702 | `projeto`/`projeto_nome` no estado, claim e log; nomes namespaced aceitos pelo app e pelo vigia; modo simultâneo grava `lane-<projeto>-<lane>`. |
| FRA-701 | Norte atualizado: um ou mais projetos, lane agnóstica de projeto; R1 e glossário ajustados. |
| FRA-703 | Projeto no parser, ledger, `gasto relatorio`, `fluxo`, painel (custo 7 dias). |
| FRA-704 | Orçamento, timeouts, `max_lanes`, prioridade e tarefas por lane no cadastro; UI de edição; herança do global. |
| FRA-705 | Agenda sequencial/rodízio, prioridade, limites por projeto; distribuição de slots. |
| FRA-707 | Vigia percorre todos os projetos no tick, estado por projeto, merge/rebase por repo. |
| FRA-708 | Página **Projetos**, seletor de principal, custo e fluxo por projeto, projeto na lane. |
| FRA-709 | Custo e entregas por projeto no CLI/painel (dados). |
| FRA-710 | Testes de integração multi-projeto e de roteamento repo/lane. |
| FRA-711 | Cadastro `repos`, claim por `repo:<slug>`, vigia e entrega por repo. |
| FRA-712/713 | Eventos claim/finalize/merge; `gasto fluxo` e resumo no painel. |
| FRA-714 | `gasto semanal` por projeto. |
| FRA-715 | Planejamento: objetivo, situação, datas, marcos; CLI e UI. |
| FRA-716 | `gasto auditoria` por projeto/card/etapa/data. |
| FRA-717 | `gasto backup`/`restaurar`, `gasto doutor`, `gasto retencao`, `gasto seguranca`. |
| FRA-721 | Webhook `gasto notificar` e `semanal --enviar`. |
| FRA-718 | `agenda.headless`: app sai, proxy e agentes continuam; dispatcher/vigia aceitam proxy vivo; testado com app fechado. |
| FRA-719 | Isolamento **lógico por projeto** na mesma conta do Mac: worktree/log/claim/estado do projeto, `gasto isolamento`, R10 no norte. Sem sandbox de SO (decisão do dono). |
| FRA-722 | Guia do portfólio e docs de operação. |

## Parcial / limitações conhecidas

- **FRA-706**: execução simultânea é experimental; exige lane explícita; janela tmux por sessão, parada e recusa por sessão; limites de conta continuam globais por lane (correto).
- **App**: build `branch-main-fb256fe` instalado e **aberto** após renovar o provisioning profile (`renovar-perfil.sh`); o profile vence em 30/11/2026.
- **FRA-720**: build assinado e `tools/release.sh`; **não notarizado**. Explicação e passos em `notarizacao.md`; decisão depende de distribuir ou não.
- **FRA-701**: norte atualizado; a proposta em `proposta-norte-multiprojeto.md` fica como registro.

## Pendente

- limites/arquivos auxiliares namespaced (FRA-706);
- notarização/distribuição (FRA-720).
