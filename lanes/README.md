# Scripts das lanes (fonte canônica, FRA-374)

O launchd executa a cópia no bundle assinado
(`TuttiDash.app/Contents/Resources/controle/lanes/`), gravada pelo `build.sh`
antes do `codesign`. O estado (`enabled`, heartbeat, `lane-*.json`) continua
em `~/.transcentia/lanes/`. Não copie estes scripts para lá: uma cópia antiga
é legado inerte.

Os módulos que o dispatcher, o vigia e a ListaModelos importam
(`catalogo.py`, `projetos.py`, `privacidade.py`, `linear_ids.py`, e
`gasto_privado.py` quando o build pessoal existe) ficam numa pasta só:
`TuttiDash.app/Contents/Resources/controle/gasto_lanes/`. `fila.py` e
`config.py` vão junto porque o import deles é da mesma pasta. Essa cópia
não é `~/.transcentia`.

```
dispatcher.py    dispatcher das lanes (60 s, launchd app.tuttidash.agente.dispatcher)
permissao.py     glob de Bash do CLI (o mesmo que o allow/deny usa)
run_lane.sh      runner de uma lane dentro da sessão tmux (comando por argv, fora do worktree)
lanes_window.py  janela única tmux 'lanes' (um painel por lane habilitada)
lanes_ctl.py     controles da janela
lane_view.py     formata a saída do agente no painel
test_lanes.py    testes offline (sem Linear, sem rede): python3 lanes/test_lanes.py
```

## O que o launchd roda

`tuttidash-agente` (dentro do `.app`) resolve o script pelo próprio executável.
Alterar `~/.transcentia/lanes/dispatcher.py` não muda o processo. Para testar
sem o app:

```bash
python3 lanes/dispatcher.py --dry-run
```

## Estado da lane (FRA-600)

Antes de fechar o card, o `lane-<lane>.json` tem de passar no contrato: worktree
resolvido sob a pasta de worktrees do projeto, sessão `lane-<lane>`, card
`^[A-Za-z]+-\d+$`, branch no formato do git (a que o claim gravou), `issue_id`
igual ao que o `claim` gravou, `base` um commit que o worktree alcança e `log`
sob o diretório de logs. Estado que falha vai para o log. O dispatcher não chama
`finalize`, não mata sessão que não seja `lane-<lane>` e não move o card.
`save_state` legítimo continua gravando e a leitura devolve o que foi gravado.

`proof_pid` e `caffeinate.pid` só recebem sinal se o processo ainda é o que o
dispatcher gerou: mesmo dono, mesmo início e o command esperado (o bash da prova
naquele worktree, ou `/usr/bin/caffeinate -i -s -t 150`). O pid que decide se a
prova vive é a foto em `STATE_DIR/proof-proc/`, fora do worktree. Se
`.lane/proof_pid` divergir, o arquivo é ignorado. `os.kill` e `waitpid` só no
pid da foto, e só com dono, início e command conferidos. Processo ausente no
`ps` conta como prova morta; no refazer, o dispatcher mata o grupo enquanto a
foto antiga ainda autoriza o processo, e só então começa a prova de novo.

Isto é consistência, não barreira. O mesmo usuário do macOS ainda pode forjar o
JSON, o `claim-<lane>.json`, a foto em `STATE_DIR/proof-proc/` e o
`caffeinate.pid`: os quatro estão no home dele. A garantia real é a
fase 5 (estado fora do alcance do agente).

Lane já em andamento sem `claim-<lane>.json` cai em "sem claim gravado". O
`watch` volta antes do timeout, da parada manual e do `finalize`, e a sessão
tmux segue. O card não entra na reserva, então outra lane pode assumir o mesmo
card; a lane em si continua ocupada enquanto o `lane-<lane>.json` existir. Quem
sobe o dispatcher encerra essa lane ou grava o claim à mão antes.

## Instalar a cópia viva

`tools/install.sh` não cria `~/.transcentia/lanes` numa instalação limpa e não copia
`run_lane.sh`, `lane_view.py`, `claude-settings.json` nem `lane-mcp.json`. Se a pasta
já existe, atualiza o dispatcher, os módulos e os prompts, e deixa runner, view e
settings como estão.

Nunca edite a cópia em `~/.transcentia/lanes/`: a fonte é esta pasta, e a
cópia executada é a do bundle.

## Prova, exit e agent_cmd fora do worktree (FRA-595)

A prova mora em `~/.transcentia/lanes/provas/<lane>/<card>/<run_id>` (modo `0700`),
escrita pelo dispatcher e pelo runner: `proof.log`, `proof_exit`, `proof_started`,
`proof_pid`, `proof_meta.json`. O `finalize` ignora `.lane/proof_*` e
`.lane/exit_code`. O `exit_code` e o `finalized` também ficam nessa pasta.

`.lane` no worktree só existe para o agente gravar `result.json`. O dispatcher
não escreve esse arquivo. Abrir `.lane` ou um arquivo dele passa por `lstat` e
`O_NOFOLLOW|O_EXCL`; symlink é recusado.

`agent_cmd` sai do worktree: o dispatcher grava `agent_cmd.<nonce>` na pasta da
rodada e o `run_lane.sh` recebe o caminho por argv. Reescrever `.lane/agent_cmd`
não muda o comando da rodada. O `proof_pid` só leva `killpg` se dono, início e
comando conferem com o registro; pid de outro processo não é morto.

No mesmo usuário isso é higiene, não isolamento. O fechamento real é a fase 5
do FRA-589.

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

Fonte: o bundle assinado (`Contents/Resources/claude-settings.json`) ou, no
checkout, `apps/notch-mac/Resources/claude-settings.json`. O perfil é o
estrito da FRA-598. A cópia em `lanes/` e em `~/.transcentia/lanes/` não
manda na lane. Claude e Grok usam o mesmo allow/deny. O modo é `dontAsk`,
não `acceptEdits`.

O que a lane pode rodar no terminal é `git status`, `git diff`, `git add` e
`git commit`. O allow é `Bash(git diff *)` (espaço antes do `*`): no CLI,
`Bash(git diff:*)` é prefixo sem fronteira e também casa `git difftool`.
`git difftool` e `git commit-tree` estão no deny. Arquivo entra pelas
ferramentas (`Read`/`Edit`/`Write`/`Grep` em `./**`). `python3`, `cat`,
`head`, `tail`, `sort` e `security` estão no deny, inclusive com caminho
absoluto (`/usr/bin/security`, `/usr/bin/sort`): o basename casa a regra.

`Read`/`Grep`/`Edit`/`Write` de `**/.grok/**` estão no deny. Numa regra de
permissão o `~` casa o caractere, não a home. `Bash(git commit *-F*)`,
`Bash(git commit *--file*)` e `Bash(git diff *--no-index*)` estão no deny:
o `*` no meio casa a flag em qualquer posição. Esses comandos leem um arquivo
qualquer e o texto entra no commit que o dispatcher publica. O caminho
depois de `=` também entra no deny de Read. Quem casa o glob é
`lanes/permissao.py`.

Rede e `security` não ficam só na regex:

- Claude: `sandbox.enabled`, `failIfUnavailable`, `allowUnsandboxedCommands`
  false, `network.allowedDomains` vazio e `strictAllowlist`. `denyRead` cobre
  `~/.ssh`, `~/.config/gh`, `~/.transcentia`, `~/.grok` e `/usr/bin/security`.
  `denyWrite` cobre `.git/config` e `.git/hooks` (o pushurl e o hook).
- Grok: `--sandbox lane`. O claim grava `[profiles.lane]` em
  `~/.grok/sandbox.toml` (`extends = strict`, `restrict_network`, deny desses
  caminhos) sem apagar os outros perfis. Sem o perfil o CLI recusa subir. O
  deny do TOML não inclui `~/.grok/auth.json`: o processo precisa desse
  arquivo para autenticar. Quem tampa o token para o agente é o deny das
  ferramentas e dos comandos acima.

Residual, de propósito: isso não substitui o usuário separado nem o sandbox da
fase 5. No macOS o próprio Grok documenta que `restrict_network` não corta a
rede dos processos filhos (no Linux corta). O processo continua o do usuário,
então um bug do CLI ainda enxerga o que o usuário enxerga. O matcher em
Python não sobe o processo. `cut`, `uniq`, `tr` e `ps` seguem na lista de
só-leitura do CLI. OpenCode, Codex e DeepSeek não recebem este teto, e o
allow do Claude ainda tem `mcp__transcentia-docs`. O `run_lane.sh` exporta
`DEEPSEEK_API_KEY`. O follow-up desse residual é a FRA-587 (follow-ups das
lanes). Não é outro card.

## Modo bancada (FRA-618)

Para card de hardware na USB (ex.: ESP32-S3). Liga só com as três condições
juntas: a etiqueta `lane:bancada` no card, `"bancada": {"ativo": true}` no
projeto do cadastro (`config.json`, que a lane não escreve) e a lane `claude`.
Sem as três, a lane recebe os settings estritos de sempre.

Com as três, o claim grava no RUN_DIR uma cópia dos settings com duas linhas a
mais, e nada além disso: `Bash(<bundle>/lanes/bancada.py *)` no allow e o mesmo
padrão em `sandbox.excludedCommands`. O Claude Code roda fora do sandbox só a
linha que casa inteira com esse caminho absoluto; `&&`, `|`, redirecionamento,
`cd` ou `$(...)` mantêm a linha no sandbox. Rede, Docker, Python e shell livres
continuam negados.

O próprio `bancada.py` (Python do sistema com `-I`, no bundle e na âncora) confere tudo:

| Subcomando | Regra |
|---|---|
| `portas` | só `/dev/cu.usbmodem*` e `/dev/cu.usbserial*`, dispositivo de caractere |
| `chip [--porta] [--chip]` | `esptool chip_id`, só leitura |
| `gravar [--porta] [--chip] ENDERECO ARQUIVO…` | `.bin` regular dentro do worktree, sem symlink no caminho, até 16 MB, endereço alinhado a 4 KB, até 4 pares |
| `serial [--porta] [--baud] SEGUNDOS` | até 120 s e 64 KB, saída no stdout |

O diretório atual tem de estar dentro das worktrees de um projeto com bancada
ligada. O `esptool` roda com versão fixa (`uv tool run --from esptool==…`), por
um `uv` de caminho fixo. Cada uso (inclusive recusa) vira uma linha em
`~/Library/Logs/TranscentIA/bancada.log`.

Residual: com o modo ligado, a lane grava qualquer `.bin` do worktree no
aparelho da porta escolhida. Por isso a etiqueta é do dono, por card. A primeira
execução do `esptool` baixa a versão fixa do PyPI (fora do sandbox).
Confirmação de privacidade e assinatura continuam com o dono.

## Revisão de IA no runner limpo (FRA-621)

O check `revisao-ia` (FRA-612) roda `gasto_lanes/revisao_ia.py` com `modelo_padrao`: "revisão sem modelo externo". Ele não lê o código, só monta um texto fixo, e o workflow não tem chave de API nem permissão de comentar. Por isso leva ~5 s e fica verde em qualquer PR. A revisão de verdade é o `[Revisor]` do vigia (`veredito_do_head`), que roda no Mac.

**Decisão (01/11/2026):** remover o check do TuttiDash. O vigia já dispensa a `revisao-ia` quando a `main` não tem o workflow (feito no PR do FRA-620), então tirar o workflow do TuttiDash não trava o merge; a revisão real continua sendo o `[Revisor]`.

A caixa segura do runner limpo (sem segredo, sem home, saída redigida, segredo detectado → não publica) continua válida. Enquanto isso, o check não deve ser descrito como "revisão de IA" na documentação.

Referências: FRA-612, FRA-620; `bots/watch.py` (`exige_revisao_ia`, `merge_ready`).

## Modo bancada, fase 2: Docker + consumidor Python (FRA-619)

Fase 1 (FRA-618) deu à lane a USB pelo comando `bancada`. A bancada do FRA-539 também precisa de Docker (broker Mosquitto com TLS e RuView simulado) e do consumidor `csi_poc.py` ouvindo o broker.

**Implementação:** `tools/poc/docker/compose.yml` e `tools/poc/consumidor/csi_poc.py`

- **Compose:** Imagem fixada por digest (Python 3.12 + Mosquitto 2.0.18), broker com TLS via certificados autoassinados no worktree, RuView simulado enviando status no tópico `ruview/#`, rede interna ao projeto bancada, recursos limitados (1 CPU, 512 MB RAM).
- **Consumidor:** Roda dentro do sandbox `bancada`, com `allow_local_binding=True` e `allowed_domains=["127.0.0.1", "<LAN_IP>"]`. Escuta no tópico `csi/#`, log em `~/Library/Logs/TranscentIA/bancada-csi/`, escrita só no worktree ou na pasta de log declarada.
- **Comandos do `bancada`:**
  - `bancada docker subir` — cria volumes e rede, sobe os containers
  - `bancada docker logs` — tail dos logs do broker e RuView
  - `bancada docker baixar` — desce e limpa os containers

Aceite:
- [x] Compose com volume fora do worktree, `privileged` ou imagem fora do cadastro é recusado (validado no `bancada.py`).
- [x] Consumidor sem rota para a internet (prova no container `--network none`).
- [x] Auditoria de cada uso no mesmo log da fase 1.

## prova-remota em outros projetos (FRA-620)

O dispatcher só leva o card a In Review com o check `prova-remota` verde no PR
(FRA-611), e o vigia só mergeia com ele. Projeto cujo app não compila no CI
(app da Apple em repositório privado, Xcode beta) recebe a prova no Linux:

```bash
tools/instalar-prova-remota "TranscentIA iOS" --pr      # worktree, commit, push e PR no repo do projeto
tools/instalar-prova-remota "TranscentIA iOS" --saida /tmp/x   # só gera os arquivos
```

O modelo fica em `tools/prova-remota-linux/`; o projeto recebe
`.github/workflows/prova-remota.yml` e `.github/prova-remota/` (script,
classificador e `config.json`). As pastas do app vêm do cadastro
(`"prova_remota": {"pastas_do_app": [...]}`).

A prova roda num container de imagem fixa, `--network none`, `--read-only`,
com o código do PR só leitura. Fica **verde** só quando todos os arquivos do PR
são Python, shell, docs ou dados fora das pastas do app (compila os `.py`,
`bash -n` nos `.sh`, roda os `test_*.py` das pastas tocadas). Arquivo do app,
tipo fora da lista ou `.github/` deixam o check **vermelho** ("precisa da prova
no Mac"): nunca há verde sem teste. Ponha `.github/*` nos `protegidos` do
projeto. Para mudar a prova, mude o modelo aqui e reinstale.

