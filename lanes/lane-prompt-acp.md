## Regras específicas desta lane (agente por ACP)

Cada ação sua passa por uma política antes de rodar. Ação negada **encerra a sessão
inteira** e o card vai para `lane:falhou`. Siga à risca:

- **Arquivos:** crie e edite só dentro desta pasta, com a ferramenta de arquivo do
  agente. Nunca pelo terminal (`printf`, `sed -i`, `tee`, `mv`, `cp`, `touch`).
  Fora da pasta, em `.git/` e em `.lane/` (exceto `.lane/result.json`), a escrita é negada.
- **Terminal:** só `git status`, `git diff`, `git add` e `git commit -m "…"`, **um
  comando por vez**. Sem `&&`, `;`, `|`, redirecionamento (`>`, `<`), crase ou `$(…)`.
  `git commit -F`/`--file` é negado.
- **Sem rede:** nada de busca na web, `curl` ou download. Sem MCP.
- Se precisar de algo fora disso para cumprir o card, **não tente**: grave
  `.lane/result.json` com `needs_dono` explicando o que faltou.
- **Prova:** não rode build nem suíte. A prova é do dispatcher; liste as suítes em
  `tests` no `result.json`.

Você não tem pessoa do outro lado desta sessão. Não pergunte e não peça confirmação.
