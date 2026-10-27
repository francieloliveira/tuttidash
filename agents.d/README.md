# `agents.d/` — catálogo de CLIs e lanes

**Fonte única** da lista de agentes. Um arquivo por agente; o nome do arquivo é o
nome da lane (`<nome>.json`, o campo `nome` precisa bater com o nome do arquivo).

Adicionar um CLI novo = **criar um arquivo aqui**. Não se edita nenhuma lista em
código: Swift (`GastoCore`), Python (`gasto_lanes`, dispatcher e vigia) e a janela
das lanes leem estes mesmos arquivos.

## Quem lê

| Consumidor | Quando lê |
|---|---|
| `apps/notch-mac` (GastoCore → `CatalogoAgentes`) | `~/.transcentia/agents.d/`, depois `agents.d/` dentro do bundle |
| `gasto_lanes/catalogo.py` | `~/.transcentia/agents.d/`, depois `agents.d/` na raiz do repo, depois o fallback embutido no próprio arquivo |
| `lanes/dispatcher.py`, `lanes/lanes_window.py`, `bots/watch.py` | importam o `catalogo.py` que o `tools/install.sh` instala ao lado deles |

A cópia instalada (`~/.transcentia/`) é gerada pelo `tools/install.sh` a partir
do repo (E13). Ninguém edita a cópia viva.

## Campos

| Campo | Obrigatório | O que é |
|---|---|---|
| `schema` | sim | Versão do formato. `1` é a atual; um app/código que entende menos **recusa** o manifesto em vez de adivinhar. |
| `nome` | sim | Identificador da lane. Igual ao nome do arquivo. |
| `rotulo` | sim | Nome mostrado na UI ("OpenCode Go"). |
| `sigla` | não | 2 letras na UI (`"OG"`). Default: inicial do rótulo. |
| `cli` | não | Executável. `null` = conta de uso sem CLI próprio (cursor). |
| `ordem` | não | Ordem de exibição no painel e no notch (menor primeiro). |
| `prioridade` | para lanes | Ordem de rotação do dispatcher. Precisa existir para toda lane de execução; **é um eixo diferente de `ordem`** (codex aparece 2º no painel e por último na rotação). |
| `painel` | não | Entra na lista de lanes do painel/notch. `false` = conta de uso. |
| `optIn` | não | `true` = não entra na lista padrão de contas. A pessoa adiciona em Ajustes › Contas. Ausente = ligada no padrão. |
| `execucao` | para lanes | `"implementada"` (o dispatcher pode assumir card). Ausente = não é lane. |
| `cor` | não | `{ base, gradiente, claro }` em `#RRGGBB`. Ausente = matiz determinística do nome. |
| `corPainel` | não | Cor da lane no painel v1. Ausente = usa `cor.base`. |
| `custo` | não | `"estimado"` (preço de tabela) ou `"informado"` (servidor). Default: informado. |
| `resume` | para lanes | CLI do `<cli> --resume <id>`. `null` = cai em `claude`. |
| `pesoFontes` | não | Fontes de peso do dispatcher, em ordem: `quota` → `gasto` → `manual`. |
| `modelos` | para lanes | `{ baixo, medio, alto }`, cada um `{ id, flags }`. `flags` é o que o dispatcher passa ao CLI; vazio = default do CLI. |
| `uso` | sim | `{ tipo, fonte, credencial }`. `tipo` é a chave que o `ColetorUso` usa para achar o código de medição (duas lanes podem medir a mesma conta — `opencode` e `opencode-go`). `fonte` e `credencial` são texto de apoio. |
| `label_linear` | não | UUID do label da lane no Linear. `null` = ainda sem label. |
| `instalar` | não | `{ comando, entrar, dica_entrar, docs, nome? }`. O app mostra o agente em Ajustes › Geral › Ferramentas com os botões Instalar e Entrar, que abrem o Terminal com estes comandos (a pessoa vê e confirma antes de rodar). Use só o comando da documentação oficial em `docs`. Sem `comando` = sem botão. |
| `nota` | recomendado | Por que a lane é do jeito que é (ZDR, promoção, IDs que quebram a lane…). O que era comentário no código vive aqui agora. |

## O que continua sendo código (e por quê)

O manifesto carrega o que é **dado**. O que é comportamento de cada CLI continua
em código, porque é sintaxe única por ferramenta:

- `ColetorUso.alvosPorTipo` (Swift): como autenticar e como parsear a resposta de
  cada provedor. O `uso.tipo` do manifesto é a chave que liga um ao outro.
- `dispatcher.agent_command` (Python): a invocação headless de cada CLI
  (`--output-format`, `--max-turns`, `--` para fechar o parsing de flags…).
- `watch.py`: o formato dos eventos que ele lê.

Nenhuma delas é uma *lista de agentes*: um agente novo sem essa parte só falha
quando a lane é exercida, e há teste cobrindo isso.

## Ao adicionar um agente

1. Crie `agents.d/<nome>.json` com `schema: 1`.
2. Se for lane de execução: `prioridade`, `execucao`, `cli`, `resume` e os três
   níveis de `modelos`.
3. `bash tools/install.sh --sem-launchd` (atualiza a cópia instalada).
4. `python3 -m unittest tests.test_catalogo` e `python3 lanes/test_lanes.py`.
5. Se a lane roda de verdade, acrescente o comando em
   `dispatcher.agent_command` — o teste `test_toda_lane_do_manifesto_tem_comando_no_dispatcher`
   cobra isso.
6. Se a conta for medida, acrescente o `Alvo` em `ColetorUso.alvosPorTipo`.

O fallback embutido do Python (`EMBUTIDOS_JSON`, em `gasto_lanes/catalogo.py`) é
a cópia literal dos manifests, usada só quando o diretório não existe. Ao mexer
nos manifests, regere esse bloco:

```bash
python3 - <<'PY'
import json, pathlib
blobs = []
for f in pathlib.Path('agents.d').glob('*.json'):
    obj = json.loads(f.read_text(encoding='utf-8'))
    blobs.append((obj['ordem'], f.read_text(encoding='utf-8').strip()))
blobs.sort()
novo = "\n\n".join(b[1] for b in blobs)
p = pathlib.Path('gasto_lanes/catalogo.py')
t = p.read_text(encoding='utf-8')
ini = t.index('EMBUTIDOS_JSON = """\\\n') + len('EMBUTIDOS_JSON = """\\\n')
fim = t.index('"""', ini)
p.write_text(t[:ini] + novo + t[fim:], encoding='utf-8')
PY
```

`tests/test_catalogo.py::ParidadeTest::test_embutido_igual_ao_disco` falha se
esquecer.
## Revisão de PR (`revisao`, opcional)

Agente com o bloco `revisao` pode ser o revisor dos PRs (Ajustes → *Bots e revisão*).
Sem o bloco, não revisa (ex.: cursor, sem CLI sem tela). Quem roda é o `bots/watch.py`.

| Campo | O que é |
|---|---|
| `comando` | argv **só leitura**. Marcadores: `{flags}` (modelo e esforço), `{prompt}` (o prompt como argumento), `{saida}` (arquivo da resposta), `{settings}`, `{mcp}`, `{teto}` |
| `flag_modelo` / `flag_esforco` | flags com `{modelo}` / `{esforco}`; entram em `{flags}` só quando há valor (`padrao` = o do CLI) |
| `entrada` | `stdin` ou `argumento` |
| `saida` | `stdout` ou `arquivo` (lê `{saida}`) |
| `papel` | `sozinho` (aprova e bloqueia) ou `segunda_opiniao` (só bloqueia; aprovação é confirmada por um `sozinho`) |
| `auto` | entra na reserva automática. `false` = só se escolhido à mão (ex.: modelo free que treina com os dados) |
| `modelos`, `modelo_padrao`, `esforcos`, `esforco_padrao` | opções que a tela de Ajustes mostra |

A resposta passa por `limpar_saida` (tira cor de terminal e o que vem antes de `[Revisor]`).
