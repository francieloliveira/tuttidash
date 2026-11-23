# Backlog multi-projeto — estado

Atualizado em 23/11/2026. Commits relevantes: `5c28e9a`, `30774de`, `50c4cf9`,
`4de0cf3`, `a5d9269`, `3815bf7`, `f6df8e1`, `05fe30e`, `9c53f4c`.

## Feito

| Card | O que está no código |
|---|---|
| FRA-702 | `projeto`/`projeto_nome` no estado, claim e log; nomes namespaced aceitos pelo app e pelo vigia; modo simultâneo grava `lane-<projeto>-<lane>`. |
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
| FRA-722 | Guia do portfólio e docs de operação. |

## Parcial / limitações conhecidas

- **FRA-706**: execução simultânea é experimental; exige lane explícita; a janela tmux única não mostra duas sessões da mesma lane; alguns arquivos auxiliares ainda são globais.
- **FRA-719**: há auditoria de permissões, mas **não** isolamento real da lane (mesmo usuário, `~/.ssh` acessível). Fase 5 pendente.
- **FRA-720**: build assinado e `tools/release.sh`; **não notarizado** (sem perfil/certificado).
- **FRA-701**: proposta em `proposta-norte-multiprojeto.md`; o §1 do norte ainda diz “um projeto” e só o dono edita.
- **App**: build `branch-main-9c53f4c` instalado em `/Applications`; o `open` desta sessão falha com `RBSRequestErrorDomain Code=5`, o app precisa ser aberto pelo Finder.

## Pendente

- decisão do norte (FRA-701);
- janela tmux/limites auxiliares namespaced (FRA-706);
- headless sem app (FRA-718);
- isolamento real (FRA-719);
- notarização/distribuição (FRA-720).
