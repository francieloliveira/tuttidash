# Security / Segurança

TuttiDash runs coding agents on your machine with your accounts. Treat its configuration like code.
O TuttiDash roda agentes de código na sua máquina com as suas contas. Trate a configuração como código.

## Reporting / Como avisar

Please report vulnerabilities privately through GitHub: **Security › Report a vulnerability** on this
repository. Do not open a public issue for them.
Avise vulnerabilidades em particular pelo GitHub: **Security › Report a vulnerability** neste
repositório. Não abra issue pública.

There is no bug bounty and no response-time promise; reports are read and answered as time allows.
Não há recompensa nem prazo de resposta garantido.

## What TuttiDash stores / O que o TuttiDash guarda

- The Linear API key in the macOS Keychain (`linear-transcentia-lanes`), read on each use, never written to files or logs.
- An optional GitHub token for Copilot usage in the app's Keychain item (`app.tuttidash.mac`), or the path to a file you choose.
- Config, state and logs under `~/Library/Application Support/TuttiDash`, `~/.transcentia` and `~/Library/Logs/TranscentIA`.

It does not read, renew or rewrite the credentials of the agent CLIs.
Ele não lê, não renova e não regrava as credenciais dos CLIs dos agentes.

## Remote proof / Prova remota

Pull requests into `main` run the check `prova-remota`. The workflow is triggered by
`pull_request` (never `pull_request_target`), with `contents: read` and no secrets.
The script that runs is the git blob `scripts/prova-remota.sh` at
`github.event.pull_request.base.sha`. The head is checked out in another directory,
at the full head SHA, and its scripts are not executed. The check is attached to
that full head SHA.

This is the proof of the merge. Branch protection on `main` has to require the
check `prova-remota` before merge; the workflow token cannot change that setting.
It does not limit the lane. A lane still runs as the owner of the machine and
can read `~/.ssh` and `~/.config/gh`.

PRs para a `main` rodam o check `prova-remota`. O workflow dispara em `pull_request`
(nunca `pull_request_target`), com `contents: read` e sem secrets. O script é o blob
`scripts/prova-remota.sh` no SHA `github.event.pull_request.base.sha`. O head entra
noutro checkout, no SHA completo, e os scripts dele não rodam. O check fica nesse
SHA completo.

Isso é a prova do merge. A proteção da `main` tem de exigir o check `prova-remota`
antes do merge; o token do workflow não altera essa configuração. Não limita a
lane. A lane continua rodando como o dono da máquina e pode ler `~/.ssh` e
`~/.config/gh`.
