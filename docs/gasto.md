# `gasto`: controle de gasto das lanes

Lê os logs de execução das lanes (agentes headless disparados pelo dispatcher em `lanes/`)
e responde quanto cada execução gastou, por dia, semana, card e lane.

O que faz:

- lê `<CARD>-<lane>-<AAAAMMDD-HHMMSS>.jsonl` e extrai, por execução: card, lane, início,
  custo, turnos, duração, tokens, modelo e status;
- grava um `ledger.jsonl` próprio, idempotente (rodar de novo não duplica nem regrava);
- relatório em texto ou `--json`, separando **custo conhecido** de **custo desconhecido**;
- teto semanal opcional que **só avisa** (mensagem e exit code).

O que **não** faz, de propósito:

- não altera, move nem apaga logs ou arquivos das lanes (abre tudo só para leitura);
- não cria `PAUSE`, não mexe em `enabled`, `stop-<lane>` nem em `lane-*.json`;
- não fala com Linear, GitHub nem com APIs de cobrança.

O único arquivo gravado é o ledger, numa pasta da própria ferramenta. A ferramenta recusa
um ledger configurado dentro da pasta de logs ou da pasta de estado das lanes.

## Requisitos

Python 3.9 ou mais novo, só biblioteca padrão (sem `pip install`). Feito para Mac e Windows
(`pathlib`, sem caminho fixo). Os testes passam em Python 3.9 e 3.13 (Linux); ainda não
rodou numa máquina Windows de verdade.

## Instalação

### Mac

```bash
cd ~/Developer
git clone https://github.com/francieloliveira/tuttidash.git
cd tuttidash
python3 gasto.py config        # confere os caminhos
python3 gasto.py relatorio
```

O `/usr/bin/python3` do Xcode serve. Atalho opcional no `~/.zshrc`:

```bash
alias gasto='python3 ~/Developer/tuttidash/gasto.py'
```

### Windows

1. Instalar o Python 3 (python.org, marcando "Add python.exe to PATH", ou
   `winget install Python.Python.3.12`).
2. Clonar e rodar no PowerShell:

```powershell
cd $HOME\Developer
git clone https://github.com/francieloliveira/tuttidash.git
cd tuttidash
py gasto.py config
```

As lanes rodam no Mac. No Windows, aponte a ferramenta para uma cópia ou pasta sincronizada
dos logs (por exemplo uma pasta do OneDrive ou do iCloud Drive com uma cópia de
`~/Library/Logs/TranscentIA/lanes`). Duas formas:

```powershell
# variável de ambiente (vale para as próximas janelas)
setx TRANSCENTIA_LANES_LOGS "C:\Users\voce\OneDrive\TranscentIA\lanes"
```

ou o arquivo `%APPDATA%\tuttidash\config.json` (modelo em `config.example.json`):

```json
{
  "logs_dir": "%USERPROFILE%\\OneDrive\\TranscentIA\\lanes",
  "teto_semanal_usd": 100
}
```

Outra opção é copiar só o `ledger.jsonl` do Mac e usar `--sem-coletar`.

## Configuração

Prioridade: **flag > variável de ambiente > arquivo de config > padrão**.
`python3 gasto.py config` mostra o valor final de cada item e de onde ele veio.

| Item | Flag | Variável de ambiente | Chave na config | Padrão Mac | Padrão Windows |
|---|---|---|---|---|---|
| logs das lanes | `--logs` | `TRANSCENTIA_LANES_LOGS` | `logs_dir` | `~/Library/Logs/TranscentIA/lanes` | `%LOCALAPPDATA%\TranscentIA\Logs\lanes` (sugestão) |
| estado das lanes | `--estado` | `TRANSCENTIA_LANES_STATE` | `state_dir` | `~/.transcentia/lanes` | `%USERPROFILE%\.transcentia\lanes` |
| ledger | `--ledger` | `TRANSCENTIA_GASTO_LEDGER` | `ledger` | `~/.transcentia/tools/ledger.jsonl` | `%APPDATA%\tuttidash\ledger.jsonl` |
| teto semanal (US$) | `--teto-semanal` | `TRANSCENTIA_GASTO_TETO` | `teto_semanal_usd` | sem teto | sem teto |
| aviso (% do teto) | `--aviso-pct` | `TRANSCENTIA_GASTO_AVISO_PCT` | `aviso_pct` | 80 | 80 |
| arquivo de config | `--config` | `TRANSCENTIA_GASTO_CONFIG` | | `~/.transcentia/tools/config.json` | `%APPDATA%\tuttidash\config.json` |

Nos valores da config valem `~`, `$VAR` e `%VAR%`. A config padrão é opcional; uma config
indicada por flag ou variável precisa existir. Em outros sistemas (Linux) valem os padrões do Mac.

## Uso

```bash
python3 gasto.py coletar                       # lê os logs e atualiza o ledger
python3 gasto.py relatorio                     # coleta e mostra dia, semana, card e lane
python3 gasto.py relatorio --por semana,lane   # só algumas dimensões
python3 gasto.py relatorio --ultimos-dias 7 --lane claude
python3 gasto.py relatorio --card FRA-259 --json
python3 gasto.py execucoes --limite 20         # uma linha por execução
python3 gasto.py teto --teto-semanal 100       # só o aviso do teto (para agendar)
python3 gasto.py config                        # caminhos resolvidos
```

Também roda como módulo: `python3 -m gasto_lanes relatorio` (de dentro da pasta do repo).

Filtros de `relatorio` e `execucoes`: `--desde AAAA-MM-DD`, `--ate AAAA-MM-DD`,
`--ultimos-dias N`, `--lane claude,grok`, `--card FRA-1,FRA-2`, `--sem-coletar` (usa só o
ledger, sem ler logs). Semana é ISO (segunda a domingo), rótulo `2026-W41`, pela data do
início da execução (horário local do Mac, que é o do nome do arquivo).

### Status de uma execução

| Status | Quando |
|---|---|
| `ok` | tem linha `type: result` sem erro |
| `erro` | tem linha `result` com `is_error`, subtipo `error_*` (ex.: `error_max_budget_usd`, `error_during_execution`) ou `cancelled` |
| `morta` | sem linha `result` e a lane não está mais com esse log (timeout, SIGTERM, parada pelo menu) |
| `em_andamento` | sem linha `result` e o `lane-<lane>.json` atual aponta para esse log |

Da pasta de estado só contam como estado de lane os `lane-<lane>.json` com a forma gravada pelo
dispatcher (`lane` igual ao nome do arquivo, `card` e `log` preenchidos). Os demais (`lane-mcp.json`,
`lane-prompt*.md`, `claude-settings.json`...) são ignorados em silêncio.

Para `morta` e `em_andamento` não há custo, turnos nem tokens oficiais. O ledger guarda um
`parcial` (respostas do modelo e tokens somados até onde o log foi, contando cada mensagem
uma vez) e a duração estimada pela última escrita do arquivo. Na listagem aparecem com `~`.

### Custo

| Tipo | Quando |
|---|---|
| `estimado` | lane claude com `total_cost_usd` > 0 (cálculo do cliente a preço de tabela) |
| `informado` | lane grok (API key) com `total_cost_usd` > 0 |
| `desconhecido` | sem linha `result`, `total_cost_usd` ausente ou 0, `cost_is_partial` ou `usage_is_incomplete` |

Desconhecido **não entra na soma** e é contado à parte ("US$ 2,79 + 1 desconh."). Custo 0
nunca é tratado como grátis.

### Teto semanal (só aviso)

Compara o custo conhecido da semana atual com o teto. Não pausa nada.

| Exit code | Significado |
|---|---|
| 0 | dentro do teto (ou sem teto no `relatorio`) |
| 1 | erro (config inválida, teto não configurado no comando `teto`...) |
| 2 | uso inválido (flag ou dimensão errada) |
| 3 | perto do teto (>= `aviso_pct`, padrão 80%) |
| 4 | teto atingido ou estourado |

Quando a semana tem execuções com custo desconhecido, a mensagem avisa que o gasto real pode
ser maior. O `relatorio` também aplica o teto quando ele está configurado (o teto sempre olha a
semana inteira, independente dos filtros de data).

### Ledger

`ledger.jsonl`, uma linha por execução, chave = nome do log (`id`). Campos principais: `card`,
`lane`, `inicio`, `dia`, `semana`, `status`, `subtipo`, `erros`, `modelo`, `auth`, `custo_usd`,
`custo`, `turnos`, `duracao_ms`, `duracao_estimada_ms`, `tokens` (`entrada`, `saida`,
`cache_leitura`, `cache_criacao`, `total`), `parcial`, `linhas_invalidas`, `fonte` (tamanho e
mtime do log), `coletado_em`.

- Log novo entra; log que mudou (tamanho ou mtime) é relido; execução em andamento é relida até
  fechar ou morrer.
- Log apagado do disco continua no ledger (é o histórico).
- Sem mudança, o arquivo não é regravado. Gravação atômica (temporário + rename).

## Limitações

- **Custo do claude é estimativa a preço de tabela.** O `total_cost_usd` do Claude Code é calculado
  pelo próprio cliente; com assinatura (Max/Pro) não é o que sai do bolso, serve para comparar
  execuções e lanes.
- **Grok via OAuth/SuperGrok vem com custo 0**, que aqui vira `desconhecido`. Só com API key o
  servidor informa o custo. Para o grok, os números úteis são turnos, duração e tokens.
- No stream do grok, `usage` todo zero significa desconhecido (vira `tokens: null`) e
  `duration_ms` 0 também (vira `null`, com duração estimada pelo arquivo).
- Execução morta não tem custo: o gasto real da semana é maior que a soma quando há mortas.
- Duração estimada depende do mtime do log; em cópia para outra máquina o mtime pode mudar.
- Linhas que não são JSON (o `run_lane.sh` junta stderr com `2>&1`) são ignoradas e contadas em
  `linhas_invalidas`.
- O horário é o do nome do arquivo (relógio local do Mac), sem fuso.

## Testes

```bash
python3 -m unittest discover -s tests -t . -v
```

As fixtures em `tests/fixtures/` são sintéticas e imitam o formato real (claude `stream-json`,
grok `streaming-messages-json`, execução morta, cancelada, em andamento). Para regenerar:
`python3 tests/fixtures/gerar.py`.

## Estrutura

```
gasto.py              atalho: python3 gasto.py <comando>
gasto_lanes/
  cli.py              comandos e exit codes
  config.py           flag > ambiente > config > padrão (Mac e Windows)
  parser.py           leitura de um log de execução
  estado.py           leitura de heartbeat.json e lane-*.json
  ledger.py           ledger idempotente
  report.py           agregação, teto e saída texto/JSON
tests/                unittest + fixtures sintéticas
```

## Adicionar um agente novo (codex, opencode, ...)

1. **Logs:** o dispatcher grava `<CARD>-<lane>-<AAAAMMDD-HHMMSS>.jsonl`. Com a lane
   chamada `codex`, o `parse_name` (`gasto_lanes/parser.py`) já reconhece sem mudar nada.
2. **Manifesto:** 1 arquivo em `agents.d/<nome>.json` (rótulo, sigla, CLI, custo
   `estimado`/`informado`, resume, fontes de peso, cores, modelos por esforço e, se houver,
   revisão). O Python (`gasto_lanes/catalogo.py` → `agentes.py`, `watch.py`) e o Swift
   (`CatalogoAgentes`) leem o mesmo arquivo. As cópias embutidas (`EMBUTIDOS_JSON` em
   `catalogo.py` e `Agentes.embutidos` no Swift) são o último recurso; a paridade é cobrada
   por `tests/test_catalogo.py` e `AgentesTests`. Fora do catálogo, custo > 0 vira
   `informado` (nunca zero).
3. **Vigia:** lê o catálogo sozinho. Limite por agente via cfg `watch.max_tarefas_por_agente`.
4. **Limite da conta (opcional):** só se houver uma fonte: um `FonteUso` registrado em
   `FontesUso` (`ColetorUso.swift`). Sem fonte, a conta não aparece nos limites (nunca 0%).
   A cor do painel vai em `Tema.cores`.
5. **Ajustes (zero arquivo):** os campos de credencial vêm de `camposAjuste` de cada
   fonte (`credenciaisContas()` em `Ajustes.swift`); os toggles e a primeira abertura
   listam `ContaUso.todas` sozinhos. Habilitar/desabilitar vale para limites, gasto, retomadas e "agora"
   (`lanesHabilitadas` no `Carregador`).
6. **Testes:** fixture JSONL em `tests/fixtures/logs/` + caso em `test_parser.py`;
   no Swift, `AgentesTests` (nomes em paridade com o Python) + paridade de fixtures
   via `testFixturesDoRepoBatemComOPython`.
7. **Peso no dispatcher (FRA-374):** declarar as fontes de `peso` do
   registry (`quota` → `gasto` do ledger → manual); lane sem fonte aparece como
   "sem peso", nunca some em silêncio.
