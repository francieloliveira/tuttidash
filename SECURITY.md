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
- The control-plane integrity anchor is not in the app bundle and not under `~/.transcentia`. It is the root-owned file `/private/var/db/tuttidash/controle.sha256` (`/var` is a symlink on macOS). `tuttidash-agente` checks that file and the Apple Development designated requirement for team `3QA76CY27W` before exec. A mismatch aborts the launch. The check is not a CDHash pin.
  A âncora de integridade do plano de controle não fica no bundle nem em `~/.transcentia`. É o arquivo `/private/var/db/tuttidash/controle.sha256`, dono root. O `tuttidash-agente` confere esse arquivo e o designated requirement Apple Development da equipe `3QA76CY27W` antes de executar. Divergência aborta. A checagem não é um CDHash.

It does not read, renew or rewrite the credentials of the agent CLIs.
Ele não lê, não renova e não regrava as credenciais dos CLIs dos agentes.
