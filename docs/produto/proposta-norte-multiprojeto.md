# Proposta: norte para vários projetos

> Proposta ao dono. Este arquivo **não altera** `docs/produto/caminho.md`; a
> mudança do norte é decisão do dono (R5). O card FRA-701 no Linear é o lugar da
> decisão.

## O que mudaria no §1

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

## O que precisaria entrar no §2

- **R1 (novo texto):** cada **vaga de lane** leva um card, um worktree git e um
  agente por vez. Um mesmo agente pode ter uma vaga por projeto **quando o estado
  e a sessão forem namespaced por projeto**; sem esse namespacing, a lane é global.
- **R3/R4:** continuam iguais (prova remota, revisor, freios e caminhos protegidos).
- **R6:** a chave do Linear continua só no Keychain e no proxy; multi-projeto não
  cria uma segunda cópia.

## Decisões que o dono precisa tomar

1. **Modo:** rodízio sequencial (padrão) ou execução simultânea (experimental)?
2. **Concorrência da mesma lane:** permitir a mesma lane em dois projetos exige
   namespacing de estado/sessão; o produto deve prometer isso ou manter uma vaga
   global por agente?
3. **Multi-repo:** um projeto pode ter vários repositórios; quantos e como o card
   escolhe (`repo:<slug>`)?
4. **Escopo local:** continua um desenvolvedor no Mac, ou passa a multiusuário?
5. **Isolamento (FRA-719):** a lane ainda roda com o usuário do Mac; prometer
   isolamento exige uma fase de segurança separada.

## Enquanto a decisão não vem

- comportamento antigo preservado: `agenda.multiprojeto` desligado;
- modo simultâneo só com `agenda.simultaneo` explícito;
- `gasto doutor` avisa quando a agenda multi-projeto está ligada e o norte ainda
  diz «um projeto».
