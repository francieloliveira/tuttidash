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

## Reviewer approval and DONE (FRA-593)

A `[Revisor]` comment approves a head only when GitHub reports that the authenticated `gh` user wrote it (`viewerDidAuthor`, or `author.login` of that user when the flag is absent) and the comment cites that head as a full 40-hex SHA. Equality, not a prefix: seven hex digits do not approve. A `DONE` comment on the card counts only when its `user.id` is the Linear token's `viewer.id` and the SHA is the full head. That viewer id is read from the token. It is not a config field.

In the same-user model, a compromised agent can still comment with the same token. The real barrier is isolation (FRA-589, phase 5).

## Aprovação do revisor e DONE (FRA-593)

Um comentário `[Revisor]` aprova o head só quando o GitHub diz que o usuário autenticado no `gh` o escreveu (`viewerDidAuthor`, ou `author.login` desse usuário quando o campo não veio) e o comentário cita o head com o SHA completo de 40 hex. A comparação é igualdade, não prefixo: 7 hex não aprovam. Um `DONE` no card só conta quando o `user.id` é o `viewer.id` do token do Linear e o SHA é o head inteiro. Esse id é lido do token. Não é campo da config.

No modelo de mesmo usuário, um agente comprometido ainda consegue comentar com o mesmo token. A barreira real é o isolamento (FRA-589, fase 5).
