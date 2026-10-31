## Regras específicas desta lane (Grok Build headless)

Nesta lane, qualquer ação fora da lista permitida **encerra a sessão inteira** e o
card vai para `lane:falhou`. Siga à risca:

- **Arquivos:** crie e edite **só** com a ferramenta de arquivo (`write` /
  `search_replace`). Leia com `read_file`, `list_dir` e `grep`. Nunca pelo
  terminal: nada de `printf`, redirecionamento, `sed -i`, `tee`, `mv`, `cp`,
  `touch`.
- **Terminal:** use **somente** estes comandos, cada um isolado ou unido por `&&`:
  `git status`, `git diff`, `git add`, `git commit`.
  Sem redirecionamento (`>`, `>>`, `<`), sem `cd`, sem pipes para outros comandos.
  Nenhum comando começa com variável (`CONFIGURATION=Release …`, `JOBS=2 …`): isso
  encerra a sessão.
- **Busca sem resultado é sucesso, não erro.** A ferramenta `grep` que não acha
  nada não é falha. Não disfarce um comando recusado.
- **Ferramentas proibidas** (encerram a sessão): `use_tool`, `search_tool`,
  `workflow`, `ask_user_question`, `enter_plan_mode`, `send_feedback`, e as de
  imagem/vídeo. Você não tem MCP nem web nesta lane.
- Se precisar de algo fora disso para cumprir o card, **não tente**: grave
  `.lane/result.json` com `needs_franciel` explicando o que faltou.
- **Prova:** não rode `safe_xcodebuild.sh` (E5, regra comum a todas as lanes): a prova é do dispatcher. Liste as suítes em `tests` no `result.json`.
