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

- The Linear API key in the app Keychain (data protection, account `linear-dispatcher`, service `app.tuttidash.mac`). Dispatcher and watcher never receive it: they call a local proxy that only runs an allowlist of operations. The old login-keychain item `linear-transcentia-lanes` is imported once and then deleted. The key is not written to files, argv, or logs. Rotate it in Linear › Settings › API, paste the new key in Ajustes › Contas, and revoke the old key.
- A chave da API do Linear no Keychain do app (proteção de dados, conta `linear-dispatcher`, serviço `app.tuttidash.mac`). O dispatcher e o vigia não a recebem: pedem um proxy local que só executa operações da allowlist. O item antigo `linear-transcentia-lanes` do login é importado uma vez e apagado. A chave não vai para arquivo, argv nem log. Para trocar: Linear › Settings › API, cole a nova em Ajustes › Contas e revogue a antiga.
- An optional GitHub token for Copilot usage in the app's Keychain item (`app.tuttidash.mac`), or the path to a file you choose.
- Config, state and logs under `~/Library/Application Support/TuttiDash`, `~/.transcentia` and `~/Library/Logs/TranscentIA`.

It does not read, renew or rewrite the credentials of the agent CLIs.
Ele não lê, não renova e não regrava as credenciais dos CLIs dos agentes.
