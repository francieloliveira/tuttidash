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
- The control-plane integrity anchor is not in the app bundle and not under `~/.transcentia`. It is the root-owned file `/private/var/db/tuttidash/controle.sha256` (`/var` is a symlink on macOS). `tuttidash-agente` checks that file and the Apple Development designated requirement for team `3QA76CY27W` before exec. A mismatch aborts the launch. The check is not a CDHash pin.
  A âncora de integridade do plano de controle não fica no bundle nem em `~/.transcentia`. É o arquivo `/private/var/db/tuttidash/controle.sha256`, dono root. O `tuttidash-agente` confere esse arquivo e o designated requirement Apple Development da equipe `3QA76CY27W` antes de executar. Divergência aborta. A checagem não é um CDHash.

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
The dispatcher opens the pull request as a draft and does not treat a local proof
or a DONE comment as authority. The card moves to In Review only after
`prova-remota` is green on the full head SHA. Timeout or an error calls the owner.
A draft pull request is not merged.
It does not limit the lane. A lane still runs as the owner of the machine and
can read `~/.ssh` and `~/.config/gh`.

PRs para a `main` rodam o check `prova-remota`. O workflow dispara em `pull_request`
(nunca `pull_request_target`), com `contents: read` e sem secrets. O script é o blob
`scripts/prova-remota.sh` no SHA `github.event.pull_request.base.sha`. O head entra
noutro checkout, no SHA completo, e os scripts dele não rodam. O check fica nesse
SHA completo.

Isso é a prova do merge. A proteção da `main` tem de exigir o check `prova-remota`
antes do merge; o token do workflow não altera essa configuração. O dispatcher
abre o PR em rascunho e não trata prova local nem comentário DONE como autoridade.
O card só vai para In Review quando `prova-remota` está verde no SHA completo.
Timeout ou erro chama o dono. PR em rascunho não é mergeado.
Não limita a lane. A lane continua rodando como o dono da máquina e pode ler
`~/.ssh` e `~/.config/gh`.

## Remote review / Revisão remota

Pull requests into `main` also run the check `revisao-ia`. The workflow is
`pull_request` (never `pull_request_target`), with `contents: read` and no
secrets. The reviewer script is the git blob `scripts/revisao-ia.sh` at the
base SHA. It receives the diff and the pull request context. It does not
receive the home directory, and it has no Bash, no global Read, no `security`
and no write-capable `gh`. The output is redacted before a comment is
published. If a secret is detected, the comment is not published and the
owner is called. The `[Revisor]` comment carries the full head SHA.

Branch protection on `main` has to require the check `revisao-ia` before
merge. This workflow does not create that ruleset: the token cannot change
branch protection. A failed check blocks the merge.

PRs para a `main` também rodam o check `revisao-ia`. O workflow dispara em
`pull_request` (nunca `pull_request_target`), com `contents: read` e sem
secrets. O script é o blob `scripts/revisao-ia.sh` no SHA da base. Ele recebe
o diff e o contexto do PR. Não recebe o home, e não tem Bash, Read global,
`security` nem `gh` de escrita. A saída é redigida antes do comentário. Se
detectar segredo, o comentário não sai e o dono é chamado. O comentário
`[Revisor]` traz o SHA completo do head.

A proteção da `main` tem de exigir o check `revisao-ia` antes do merge. Este
workflow não cria esse ruleset: o token não altera a proteção da branch.
Check vermelho bloqueia o merge.

## Reviewer approval (FRA-593) and the merge proof (FRA-611)

A `[Revisor]` comment approves a head only when GitHub reports that the authenticated `gh` user wrote it (`viewerDidAuthor`, or `author.login` of that user when the flag is absent) and the comment cites that head as a full 40-hex SHA. Equality, not a prefix: seven hex digits do not approve. The watcher merges only when the check `prova-remota` is green on that same full head SHA. A `DONE` comment on the card and the `→ verde` marker in the PR body do not authorize the merge.

In the same-user model, a compromised agent can still comment with the same token. The real barrier is isolation (FRA-589, phase 5).

## Aprovação do revisor (FRA-593) e prova do merge (FRA-611)

Um comentário `[Revisor]` aprova o head só quando o GitHub diz que o usuário autenticado no `gh` o escreveu (`viewerDidAuthor`, ou `author.login` desse usuário quando o campo não veio) e o comentário cita o head com o SHA completo de 40 hex. A comparação é igualdade, não prefixo: 7 hex não aprovam. O vigia só faz o merge com o check `prova-remota` verde nesse mesmo SHA completo. Comentário `DONE` no card e a marca `→ verde` no corpo do PR não autorizam o merge.

No modelo de mesmo usuário, um agente comprometido ainda consegue comentar com o mesmo token. A barreira real é o isolamento (FRA-589, fase 5).
