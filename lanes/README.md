# Scripts das lanes (fonte canônica, FRA-374)

Cópia viva: `~/.transcentia/lanes/` (é de lá que o launchd roda o dispatcher).
Backup antes de mexer: o install abaixo guarda `.bak` automático.

```
dispatcher.py    dispatcher das lanes (60 s, launchd com.transcentia.lanes.dispatcher)
run_lane.sh      runner de uma lane dentro da sessão tmux (lê .lane/agent_cmd)
lanes_window.py  janela única tmux 'lanes' (um painel por lane habilitada)
lanes_ctl.py     controles da janela
lane_view.py     formata a saída do agente no painel
test_lanes.py    testes offline (sem Linear, sem rede): python3 lanes/test_lanes.py
```

## Instalar a cópia viva

```bash
cd ~/Developer/tuttidash
for f in dispatcher.py run_lane.sh lanes_window.py lanes_ctl.py lane_view.py claude-settings.json; do
  cp ~/.transcentia/lanes/$f /tmp/lanes-$f.bak
  cp lanes/$f ~/.transcentia/lanes/$f
done
```

Nunca edite `~/.transcentia/lanes/` direto: a fonte é esta pasta.

## Lane nova (ex.: opencode, FRA-374)

1. `LANES` + `EFFORT_FLAGS` + `agent_command` no `dispatcher.py`
2. `"execucao": "implementada"` no manifesto (`agents.d/<lane>.json`)
3. Label `opencode` no grupo `lane` do Linear → `LABEL_LANE_IDS`
4. `LANES_ORDEM` no `lanes_window.py` (entra sozinha quando habilitada)
5. CLI/resume no `run_lane.sh`
6. Peso: `pick_lane`/`spread_auto` usam quota %; sem medida, menor gasto
   semanal do ledger (`week_spend`, FRA-371) — nunca silencia
7. Modelos opencode: só free do Console com teto Go (baixo →
   `nemotron-3.5-super-vl-free`, medio/alto → `deepseek-v4.1-flash-free`);
   codex usa o default do CLI. deepseek (`dsh --profile headless`) recebe um
   patch por execução com a conta do app, o modelo e o reasoning effort do peso

## Melhorias de 21/10/2026 (consumo de tokens)

Investigação: a prova do dispatcher marcava provas verdes como vermelhas
(`lane:falhou … código 0`, 20 vezes em 20–21/10). O card voltava à fila pela triagem
e a lane rodava de novo em opus. Quatro mudanças, todas sem dependência de projeto:

1. **Prova** (`dispatcher.py`): exit 0 manda; só evidência forte na *última*
   tentativa de cada suíte vira vermelho. `EVIDENCIA_RE` aceita só diagnóstico
   real (`arquivo:linha:col: error:`, `error:` no começo da linha, teste que falhou,
   `TEST/BUILD FAILED`, `with N failures`); trecho de código citado num aviso
   (`189 | func f(_ error: Error)`) nunca conta. Cada parada leva uma linha
   `- causa: `x`` estável (`causa_de`), e o vigia conta os 3 strikes por ela.
2. **Needs por evento** (`bots/watch.py`): a triagem só reconfere a etiqueta do dono (`linear.owner_label`)
   quando o card muda (descrição, labels, estado, comentário de pessoa). Rede de
   segurança: `watch.reconferir_needs_max_s` (padrão 24 h; 0 = só com mudança).
3. **Revisor dos PRs** (`bots/watch.py`, Settings → *Bots e revisão*): agente,
   modelo, esforço e teto em `revisores.pr.*`. Não é lane. Com `independente`,
   nunca revisa com o fornecedor que escreveu o PR: usa a reserva (`auto` = a conta
   com mais folga abaixo de `folga_pct`, pela medida do dispatcher). Adaptador do
   codex em `--sandbox read-only`; se falhar, revisa o Claude. Vereditos em
   `~/Library/Logs/TranscentIA/revisor-vereditos.jsonl`.
4. **Triagem local**: saiu em 29/10/2026. Nas 16 provas vermelhas que avaliou, nunca
   acertou uma falha de ambiente. A prova vermelha vai direto para `lane:falhou` e para a triagem do vigia.

## Freios por card (FRA-443)

Decisão do dono em 28/10/2026. O teto de uma execução não mudou
(`BUDGET_USD`, `LANE_TIMEOUT_MIN`, `HEADROOM_PCT`). O que passou a valer é o
acumulado do card, em qualquer lane:

| Esforço | Tentativas | Gasto acumulado | Tempo acumulado |
| --- | --- | --- | --- |
| baixo | 3 | US$ 8 | 120 min |
| médio | 3 | US$ 20 | 270 min |
| alto | 5 | US$ 40 | 360 min |

Um só contador, no arquivo que já existia (`opencode-strikes.json`, campo
`cards`). A leitura do formato antigo continua. Cada card guarda tentativas
(`n`), `gasto_usd`, `tempo_min` e o `resumo`. Estourou: label `lane:falhou` e
comentário `tentativas: N de M; gasto: US$ X de Y; tempo: A de B min`. O
worktree não é apagado. A fila não assume o card de novo enquanto o freio
estiver estourado. Chegar em In Review não zera o acumulado.

Pedido de ajuste do revisor (`REVISOR: AJUSTES`) conta 1 tentativa, uma vez
por id de comentário. A prioridade entre as lanes e a folga por esforço não
mudam. O verificador do aceite do card não entra aqui.

## Permissões mínimas (FRA-598)

Fonte: `lanes/claude-settings.json`, ao lado do dispatcher (a cópia em
`~/.transcentia/lanes/` é o que o `tools/install.sh` instala). Claude e Grok
usam o mesmo allow/deny. O modo é `dontAsk`, não `acceptEdits`.

O que a lane pode rodar no terminal é `git status`, `git diff`, `git add` e
`git commit`. Arquivo entra pelas ferramentas (`Read`/`Edit`/`Write`/`Grep`
em `./**`). `python3`, `cat`, `head`, `tail` e `security` estão no deny,
inclusive com caminho absoluto (`/usr/bin/security`): o basename casa a regra.

Rede e `security` não ficam só na regex:

- Claude: `sandbox.enabled`, `failIfUnavailable`, `allowUnsandboxedCommands`
  false, `network.allowedDomains` vazio e `strictAllowlist`. `denyRead` cobre
  `~/.ssh`, `~/.config/gh`, `~/.transcentia` e `/usr/bin/security`. `denyWrite`
  cobre `.git/config` e `.git/hooks` (o pushurl e o hook).
- Grok: `--sandbox lane`. O claim grava `[profiles.lane]` em
  `~/.grok/sandbox.toml` (`extends = strict`, `restrict_network`, deny desses
  caminhos) sem apagar os outros perfis. Sem o perfil o CLI recusa subir.

Residual, de propósito: isso não substitui o usuário separado nem o sandbox da
fase 5. No macOS o próprio Grok documenta que `restrict_network` não corta a
rede dos processos filhos (no Linux corta). O processo continua o do usuário,
então um bug do CLI ainda enxerga o que o usuário enxerga. O follow-up desse
residual é a FRA-587 (follow-ups das lanes). Não é outro card.
