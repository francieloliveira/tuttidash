# Mapa — TuttiDash

<!-- gerado:inicio — não editar à mão; o TuttiDash regenera -->
## Módulos
- `.github/`
  - `.github/workflows/`
- `agents.d/`
- `apps/`
  - `apps/notch-mac/`
- `bots/`
  - `bots/launchd/`
  - `bots/prompts/`
- `docs/`
  - `docs/exemplo/`
  - `docs/imagens/`
  - `docs/marca/`
  - `docs/produto/`
- `gasto_lanes/`
- `lanes/`
- `scripts/`
- `tools/`
  - `tools/lane-pct/`
  - `tools/prova-remota-linux/`

## Prova
- Comando: `./scripts/testar.sh {suite}`
- Suíte declarada: `tests.test_parser`
- Testes em `apps/notch-mac/Tests/`
- Testes em `tests/`
<!-- gerado:fim -->

## Convenções
- Textos de interface, docs e comentários em português do Brasil.
- Lógica testável no GastoCore (só Foundation); NotchGasto só monta a tela. O app não tem dependência externa.
- Python 3.9+ só com a biblioteca padrão; macOS 14+.
- Catálogo de agentes: um JSON por agente em `agents.d/`; o nome do arquivo é o nome da lane e o campo `nome` é igual. Manifesto com schema acima do que o código entende é recusado. O vigente é o do bundle assinado (modo 0600), não o espelho em `~/.transcentia/agents.d/`.
- O launchd executa a cópia do bundle; `enabled`, `heartbeat` e `lane-*.json` ficam em `~/.transcentia/lanes/`.
- Instalação limpa não cria `~/.transcentia/lanes` nem copia runner, view ou ajustes; com a pasta já existente, o install só atualiza dispatcher, módulos compartilhados e prompts. Os interruptores das lanes ficam ocultos até runner, view e ajustes estarem lá.
- Desativar uma lane não grava `enabled` direto nem cria PAUSE.
- Limite de conta com fonte oficial ou local: billing do GitHub Copilot e base local de sessão do OpenCode.
- Assinatura e perfil pessoais do build ficam em `.env`, fora do git.
