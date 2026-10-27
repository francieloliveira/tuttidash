# Contributing / Como contribuir

Thanks for the interest. TuttiDash is a personal project shared as-is, so reviews can be slow.
Obrigado pelo interesse. O TuttiDash é um projeto pessoal compartilhado como está; a revisão pode demorar.

## Before a pull request / Antes de um PR

- Open an issue first for anything bigger than a small fix. / Abra uma issue antes de qualquer coisa maior que uma correção pequena.
- Run the tests / Rode os testes:

  ```bash
  python3 -m unittest discover -s tests -t .
  python3 -m unittest lanes.test_lanes
  cd apps/notch-mac && swift test
  ```

- Run the publication check / Rode a conferência de publicação: `tools/checar-publicacao.sh`.
- Keep the Python side standard library only, and the Swift side without external packages.
  / Python só com a biblioteca padrão; Swift sem pacotes externos.
- Adding an agent is one manifest in `agents.d/` (see `docs/gasto.md`). / Agente novo = um manifesto em `agents.d/`.

## Rules the code keeps / Regras que o código segue

- Never write, renew or rotate another tool's credentials. / Nunca gravar, renovar nem trocar credencial de outra ferramenta.
- Usage readings only from official APIs or local files of the tool itself. / Leitura de uso só de API oficial ou de arquivo local.
- Unknown cost or usage is "no data", never zero. / Custo ou uso desconhecido é "sem dado", nunca zero.
- No ids, tokens, personal paths or account data in code, tests or fixtures. / Nada de ids, tokens, caminhos pessoais ou dados de conta no código, nos testes ou nas fixtures.

By contributing you agree that your contribution is licensed under the MIT License.
Ao contribuir, você concorda que a contribuição fica sob a licença MIT.
