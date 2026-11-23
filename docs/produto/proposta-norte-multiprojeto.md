# Proposta: norte para vários projetos

> **Aplicada em 23/11/2026 com autorização do dono.** O §1 e o R1 de
> `docs/produto/caminho.md` já foram atualizados; este arquivo fica como registro
> da decisão e das limitações.

## O que mudou no §1

Texto atual: «…percorre um projeto do Linear… Serve a qualquer projeto cadastrado
com um projeto no Linear e um repositório no GitHub…».

Proposta:

> O TuttiDash é um conjunto de ferramentas locais com que um desenvolvedor, no Mac
> dele, percorre **um ou mais projetos do Linear** com agentes de código em lanes
> paralelas: um card, um worktree git e um agente por lane. O dispatcher leva o
> card até um PR em rascunho, o vigia só faz merge com prova remota e revisão
> aprovadas, e o notch mostra lanes, builds, testes, entregas, custo e cota. Serve
> a qualquer projeto cadastrado com um projeto no Linear e um ou mais repositórios
> no GitHub; é compartilhado como está.

## O que entrou no §2

- **R1 (texto aplicado):** cada **vaga de lane** leva um card, um worktree git e
  um agente por vez. A lane não pertence a projeto; o projeto, o repositório e o
  card vêm do dispatcher. A mesma lane pode ter uma vaga por projeto quando estado
  e sessão forem namespaced por projeto.
- **R3/R4:** continuam iguais (prova remota, revisor, freios e caminhos protegidos).
- **R6:** a chave do Linear continua só no Keychain e no proxy; multi-projeto não
  cria uma segunda cópia.

## Decisões tomadas

1. **Modo:** rodízio sequencial é o padrão; simultâneo é experimental.
2. **Lane agnóstica:** a lane não tem dono de projeto; o dispatcher passa projeto,
   repositório e card. A mesma lane pode ter uma vaga por projeto com estado e
   sessão namespaced (`lane-<projeto>-<lane>`).
3. **Multi-repo:** o card escolhe pelo rótulo `repo:<slug>`; sem rótulo, o principal.
4. **Escopo local:** continua um desenvolvedor no Mac.
5. **Isolamento (FRA-719):** ainda pendente; a lane roda com o usuário do Mac.

## Enquanto a decisão não vem

- comportamento antigo preservado: `agenda.multiprojeto` desligado;
- modo simultâneo só com `agenda.simultaneo` explícito;
- `gasto doutor` avisa quando a agenda multi-projeto está ligada e o norte ainda
  diz «um projeto».
