# TuttiDash: app de notch (macOS)

App nativo (SwiftUI + AppKit) que fica no notch do Mac e acompanha as lanes **claude**,
**codex**, **opencode** e **grok**. Foto do painel com dados de exemplo: `docs/imagens/painel.png`
(gerada por `docs/exemplo/foto.sh`).

- **Recolhido**: uma linha. Estado geral (tudo ok, atenção, parado), quatro pontinhos das lanes
  e a conta mais crítica em %. Sem medida, o texto é «sem medida». Sem batimento do dispatcher,
  o estado é «Parado».
- **Expandido** (passe o mouse): uma linha por lane (card, descrição curta e mini barra de uso),
  resumo dos testes, lock de build, custo do dia e três ícones sem fundo: abrir painel,
  configurações e desativar. Desativar chama `lanes_ctl.py disable <lane>`. Esse botão não
  grava `enabled` direto e não cria `PAUSE`.
- **Painel** (ícone ou menu *Abrir painel*): painel v2, desenhado para
  1600×900. Barra lateral com Dashboard, Lanes, Builds, Entregas, Testes e Custos; Configurações
  abre os Ajustes. O Dashboard tem quatro cartões (lanes ativas, builds hoje, falhas 24h, custo da
  semana), a faixa de alertas, lanes, builds, testes, dispatcher, entregas e custos (semana, mês
  e ano). As páginas trazem o resto do v1: prova em curso com fases e suítes, «Parou · retomar»,
  builds de hoje com `#N`, log do dispatcher (só em *Ver log detalhado*), aparelhos e uso por conta.
  Abaixo de 1600 px de largura o Dashboard encolhe por igual. Sem arquivo, o bloco diz que não há
  leitura. Números de exemplo não são usados (só no `docs/exemplo`, para a foto).
  - `build #N` é a posição da execução no histórico inteiro (ledger + logs), contada antes de tirar
    lanes desligadas, então não muda quando uma lane é ligada ou desligada.
  - Custo da semana compara com a semana ISO anterior até o mesmo ponto: subiu, ↑ vermelho; caiu,
    ↓ verde. Subida de 20% ou mais e falhas nas últimas 24 h entram só na faixa do painel (o estado
    do notch não muda).
  - Ainda sem função (aparecem e não fazem nada): busca ⌘K, notificações, menu da conta, variação de
    lanes ativas, `#nº` na fila do lock e testes ignorados.
- **Limites das contas**: a conta mais crítica entra no recolhido (amarelo a partir de 80%, vermelho
  a partir de 95%). O painel lista o uso de cada lane. Detalhes em *Limites de uso das contas*, abaixo.
- **Barra de menus**: ícone de anel com o resumo da semana e dos limites, *Abrir painel*, *Atualizar agora*, *Abrir
  configuração…*, *Usar a tela principal em vez do notch* e *Sair*. O ícone no Dock aparece só com o painel aberto; ao fechar a janela, fica só a pílula (FRA-553). *Sair* encerra o app.

## De onde vêm os números

Tudo é lido em Swift, **só leitura**, nos mesmos caminhos da ferramenta `gasto` (README da raiz):

| O quê | Padrão | Variável de ambiente / chave na config |
|---|---|---|
| ledger da ferramenta | `~/.transcentia/tools/ledger.jsonl` | `TRANSCENTIA_GASTO_LEDGER` / `ledger` |
| logs das lanes | `~/Library/Logs/TranscentIA/lanes` | `TRANSCENTIA_LANES_LOGS` / `logs_dir` |
| estado das lanes | `~/.transcentia/lanes` (`heartbeat.json`, `lane-<lane>.json`) | `TRANSCENTIA_LANES_STATE` / `state_dir` |
| teto semanal (US$) | sem teto | `TRANSCENTIA_GASTO_TETO` / `teto_semanal_usd` |
| reais por dólar | sem taxa: custos em US$ | `TRANSCENTIA_GASTO_USD_BRL` / `usd_brl` ou `cambio.usd_brl` |
| aviso (% do teto) | 80 | `TRANSCENTIA_GASTO_AVISO_PCT` / `aviso_pct` |
| config | `~/.transcentia/tools/config.json` | `TRANSCENTIA_GASTO_CONFIG` |
| banco do OpenCode (sessão do Console) | `~/.local/share/opencode/opencode.db` | `TRANSCENTIA_OPENCODE_DB` / `opencode_db` |
| consultar limites das contas | ligado | `TRANSCENTIA_GASTO_USO_CONTAS` / `uso_contas` |

O painel também lê, só para leitura, na pasta de estado: `medida-cache.json`, `planos.json`,
`opencode-strikes.json`, `enabled`, `disabled-by-user`, a existência de `PAUSE`, `limite-<lane>.json`
e os `stale-proof-*`. O log é `lanes-dispatcher.log` ao lado da pasta de logs. A prova em curso sai
do `.lane/proof.log` do worktree gravado em `lane-<lane>.json`. A build no iPhone e no relógio sai
do `device-build-*.log` mais novo, quando esse arquivo existe. Plano ou strikes ausentes aparecem
como «sem dado» ou «sem registro». Simulador dedicado, iPhone e Apple Watch sem arquivo aparecem
como «sem leitura ainda».

- O ledger é o histórico (inclusive logs já apagados). Log novo, log que mudou desde a última
  coleta e log em andamento são lidos direto, com as mesmas regras do `parser.py`, num cache em
  memória. Então o app não precisa do Python rodando, e o `python3 gasto.py coletar` continua
  sendo o que grava o ledger.
- Lê de novo quando o disco muda (FSEvents) e ao abrir o painel. Mudança no estado das lanes
  ou no arquivo de config aparece em segundos; logs e ledger, que crescem a cada linha, releem no máximo a cada 30 s.
  Sem mudança, só uma releitura a cada 5 min (virada do dia, limites que vencem). Se o FSEvents
  não subir, volta a ler a cada 30 s.
- **Custo desconhecido nunca entra como zero**: fica de fora da soma. No painel, a lane ou o dia
  aparece como «desconhecido» ou «sem dado».
- O custo de hoje no notch e o bloco de custos usam os últimos 7 dias (hoje incluso).
  Com taxa maior que zero em `usd_brl`, `cambio.usd_brl` ou `TRANSCENTIA_GASTO_USD_BRL`
  (reais por dólar), os valores saem em R$. Sem taxa, saem em US$ com o rótulo «US$».
  A semana ISO (segunda a domingo) continua no menu da barra. Sem teto, o menu diz «sem teto definido».
- "Agora" vem dos `lane-<lane>.json` com a forma do `save_state()` do dispatcher (o
  `lane-mcp.json` e os outros ficam de fora). `~N turnos` é a contagem de respostas do modelo no
  log em andamento (o número oficial só sai na linha `result`).

A leitura do painel não grava log nem estado e não cria `PAUSE`. O botão desativar do notch
não abre o arquivo `enabled`: ele chama `lanes_ctl.py disable <lane>`. A janela de ajustes
continua podendo gravar a lista de lanes habilitadas, como antes. O app não instala ganchos
no Claude Code. A preferência de tela fica no UserDefaults. O botão *retomar* só escreve na
área de transferência, quando clicado.

## Parou · retomar

Quando uma lane para sem fechar o card (`lane:falhou` ou a etiqueta do dono, `needs:dono`), o painel mostra o
card **Parou · retomar** (até 3 cards dos últimos 7 dias, o mais novo primeiro) e a barra de menus
ganha *Copiar para retomar <CARD>*. O botão **retomar** copia para a área de transferência o
comando pronto: `cd <worktree> && grok --resume <id>` (ou `claude --resume <id>`).

- Só o log mais novo de cada card conta. O worktree e o id da sessão vêm do próprio stream
  (`cwd` e `session_id` do `init`), e o desfecho vem de `<worktree>/.lane/finalized`, que o
  dispatcher apaga quando assume o card de novo.
- Card que está rodando agora, card fechado (`In Review`) e worktree sem `finalized` ficam de fora.
- Continua só leitura: o app não mexe no worktree nem no estado das lanes. Copiar só acontece
  quando você clica.

## Limites de uso das contas

O card **Limites das contas** mostra, por conta, quanto já foi usado da janela mais apertada, o
horário do reset e quanto falta. Verde até 80%, **amarelo de 80%** e **vermelho de 95%** em diante.
Passando de 80%, aparece também um selo no estado recolhido (`⚠ claude 93%`), que fica compacto
(`⚠ 93%`) quando há uma lane rodando ao lado. Uma volta a cada 2 min.

### Fontes de uso

O TuttiDash aberto lê só fontes oficiais ou locais:

| Conta | Leitura | Credencial |
|---|---|---|
| copilot (GitHub Copilot, opt-in) | `GET https://api.github.com/users/{username}/settings/billing/premium_request/usage?year=&month=` (API de billing do GitHub) | token no Keychain do app (`app.tuttidash.mac`, conta `copilot`) ou arquivo apontado em Ajustes |
| opencode_sessao (OpenCode) | banco local `~/.local/share/opencode/opencode.db` (`session_v2`), sem rede | nenhuma |

- **copilot** é opt-in: não entra na lista padrão de contas. Com a conta adicionada, usuário
  do GitHub, cota mensal (requisições) e token, o app lê o relatório pessoal oficial de
  billing. `% = soma de grossQuantity no mês / cota informada` (150 requisições com cota
  300 → 50%). Cota zero ou ausente fica "sem cota informada", sem número. Relatório pessoal
  vazio fica "licença gerida por organização ou empresa". O token fica no Keychain ou num
  arquivo cujo caminho a pessoa informa; nunca no `config.json`. O app não grava nem
  renova esse token. 401, 403, 404 e 429 ficam "sem dado".
- **opencode_sessao** mostra o contexto usado pela sessão mais recente do OpenCode, lido do
  banco local aberto só para leitura.

As outras lanes (Claude Code, Codex, Grok, Gemini…) não têm API oficial de cota da assinatura,
então o TuttiDash aberto não mostra o limite delas. Para quem quiser medir de outro jeito, o
GastoCore tem um registro de fontes: um módulo à parte implementa `FonteUso` e chama
`FontesUso.registrar(_:)` no início do app (`Sources/NotchGasto/main.swift`). O `Package.swift`
inclui `Privado/Sources/GastoPrivado` quando essa pasta existe; ela é ignorada pelo git.

A lista de modelos nos Ajustes vem dos CLIs (`opencode models`, `grok models`), da cache do
Codex CLI (`~/.codex/models_cache.json`) e das APIs oficiais quando há chave no ambiente
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`).

### Regras que o app segue aqui

- **Só consulta.** Nada é gravado nas pastas ou credenciais de outras ferramentas.
- **Token vencido não é renovado.** A conta fica como *sem dado*, com o motivo.
- **Sem dado nunca vira 0%.** Sem credencial, token vencido, 401, 429, timeout ou resposta sem
  janela: o painel escreve "sem dado" e o motivo.
- **Último valor bom continua valendo.** Se uma volta falhar, o número que estava na tela fica,
  com a idade dele (`há 4 min`) e o motivo da falha ao lado.
- **Freio próprio**: no máximo uma chamada por conta a cada 90 s e, depois de um 429, 15 min de
  espera. Para não chamar nada, `{"uso_contas": false}` na config (o card desaparece).


## Compilar e abrir

Requisitos: macOS 14 ou mais novo e Xcode (ou Command Line Tools) com Swift 5.9+.

```bash
cd apps/notch-mac
swift test                 # testes de parsing/agregação (XCTest)
./build.sh                 # gera build/TuttiDash.app (release, codesign ad-hoc)
./build.sh --testes        # roda os testes e depois empacota
open "build/TuttiDash.app"
```

Para rodar sem empacotar: `swift run NotchGasto`.

Para fixar o app em `/Applications`: `cp -R "build/TuttiDash.app" /Applications/`.

Opções de linha de comando (para conferir layout):

- `--expandido`: deixa o notch aberto.
- `--painel`: abre a janela do painel completo.
- `--tela-principal`: usa o topo da tela principal mesmo havendo uma tela com notch.
- `--foto <arquivo.png>`: depois da primeira leitura desenha a própria janela do notch num PNG
  (sem o blur de fundo; não precisa de permissão de gravação de tela). Use junto com `--expandido`:
  no estado recolhido o PNG pode sair vazio.
- `--foto-painel <arquivo.png>`: abre o painel e, cerca de 6 s depois, grava um PNG dessa janela.
  Também não precisa de permissão de gravação de tela.

Exemplo: `"build/TuttiDash.app/Contents/MacOS/NotchGasto" --expandido`.

## Iniciar no login (opcional)

Ajustes do Sistema → Geral → Itens de Início → **+** → escolha `TuttiDash.app`
(de preferência a cópia em `/Applications`).

Pelo Terminal:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/TuttiDash.app", hidden:true}'
```

Para tirar: remova o item na mesma tela de Itens de Início.

## Onde aparece

- Por padrão, colado no topo da tela que tem notch (MacBook), centrado no notch. A pílula usa
  a altura do notch (`safeAreaInsets.top`) e a largura dele (entre `auxiliaryTopLeftArea` e
  `auxiliaryTopRightArea`).
- Sem tela com notch (ou com *Usar a tela principal em vez do notch* ligado): colado no topo da
  tela principal, centrado, com a altura da barra de menus.
- Muda sozinho quando as telas mudam (monitor conectado/desconectado, resolução).

## Limitações

- A pílula ocupa ~112 pt de cada lado do notch e cobre o que estiver na barra de menus ali.
- O hover usa monitores de movimento do mouse (não precisam de permissão de Acessibilidade).
  Com o app em tela cheia, a pílula continua visível (fica acima da barra de menus).
- Custo do claude é estimativa a preço de tabela; grok via OAuth vem sem custo (desconhecido).
  Mesmas limitações da ferramenta `gasto`.
- Limites de conta só para as fontes oficiais ou locais (Copilot, sessão do OpenCode).
- Codesign ad-hoc: em outro Mac, o Gatekeeper pede para abrir pelo menu de contexto (Abrir).

## Estrutura

```
Package.swift
Sources/GastoCore/      leitura e agregação (só Foundation, testável)
  Configuracao.swift    ambiente > config.json > padrão (igual ao config.py)
  ParserLog.swift       um log de execução (porta do parser.py)
  Ledger.swift          ledger.jsonl da ferramenta (só leitura)
  EstadoLanes.swift     heartbeat.json e lane-<lane>.json (porta do estado.py)
  Carregador.swift      ledger + logs alterados + estado, com cache
  Resumo.swift          semana, 7 dias, cards, lanes, agora, nível do teto
  LimitesUso.swift      janelas, níveis (80/95) e os motivos de "sem dado"
  ColetorUso.swift      registro de fontes de uso, com freio, último valor bom e transporte injetável
  ParserUsoCopilot.swift  relatório de billing do GitHub Copilot
  ParserUsoOpenCodeSession.swift  contexto da sessão no banco local do OpenCode
  ListaModelos.swift    lista de modelos dos Ajustes (CLIs, cache do Codex, APIs oficiais)
  Formato.swift         US$ 1.234,56, R$ 1.234,56, "1h42", "há 12 min", "4 min", "33%"
  PainelTipos.swift     retrato do notch e do painel (FRA-412)
  PainelLeitores.swift  heartbeat, medida, planos, strikes, log, prova no disco (só leitura)
  PainelProva.swift     suítes, 0 testes = falha, lock único
  PainelMontagem.swift  alertas, top 5, estado do notch
  PainelCtl.swift       comando `lanes_ctl.py disable`, sem gravar enabled
Sources/NotchGasto/     app (janela no notch, painel SwiftUI, item na barra de menus)
Tests/GastoCoreTests/   XCTest (usa também as fixtures de tests/fixtures da raiz)
Resources/Info.plist    LSUIElement (arranca sem Dock; painel aberto pede .regular, FRA-553)
build.sh                .app em build/ com codesign ad-hoc
```
