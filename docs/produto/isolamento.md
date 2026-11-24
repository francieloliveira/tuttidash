# Isolamento por projeto (FRA-719)

Decisão: **o isolamento é por projeto e usa a conta do macOS onde o app está
instalado**. Não há, no planejamento, um serviço paralelo/usuário separado.

## O que é garantido

- A lane de um card usa o **worktree do projeto** daquele card.
- O estado (`lane-*.json`), o claim e o log carregam o projeto; a lane não troca
  de projeto no meio do card.
- A auditoria `gasto isolamento` confere:
  - worktree dentro da pasta de worktrees do projeto;
  - log dentro de `~/Library/Logs/TranscentIA`;
  - cabeçalho do log com o mesmo projeto do estado;
  - claim sem projeto fora do cadastro;
  - pasta de worktrees sem symlink.

## O que não é garantido

- Não há isolamento de sistema operacional: o agente roda com o seu usuário e
  consegue ler `~/.ssh`, `~/.config/gh` e outros projetos, se o modelo pedir.
- Não há usuário/serviço separado nem máquina virtual.
- Credenciais e chave do Linear são compartilhadas pela conta do Mac.

## Como auditar

```bash
python3 gasto.py isolamento
python3 gasto.py isolamento --json
python3 gasto.py seguranca --corrigir
```

Erro sai com código 1. O `doutor` continua conferindo config, pastas e proxy.
