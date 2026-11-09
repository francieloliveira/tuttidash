# Norte — TuttiDash

> Norte do projeto: o que ele é e o que não pode acontecer. Só o dono altera este arquivo.
> Agentes: leiam antes de planejar. Para mudar algo aqui, proponham ao dono (needs_dono); não editem.

## §1 Objetivo

O TuttiDash é um conjunto de ferramentas locais com que um desenvolvedor, no Mac dele, percorre um projeto do Linear com agentes de código em lanes paralelas: um card, um worktree git e um agente por lane de cada vez. O dispatcher leva o card até um PR em rascunho, o vigia só faz merge com prova remota e revisão aprovadas, e o notch mostra lanes, builds, testes, entregas, custo e cota. Serve a qualquer projeto cadastrado com um projeto no Linear e um repositório no GitHub; é compartilhado como está.

## §2 Restrições inegociáveis

- R1: Cada lane leva um card, um worktree git e um agente por vez.
- R2: O agente da lane não fala com o Linear nem com o GitHub; quem move o card, comenta e abre o PR é o dispatcher.
- R3: O card só vai para In Review, e só há merge, com a prova-remota verde no SHA completo da head e a aprovação do [Revisor] nessa head (e a revisao-ia, quando a main tem esse workflow).
- R4: Os freios por card (tentativas, gasto, tempo) e os caminhos protegidos valem acima de concluir o card.
- R5: Nenhuma lane edita o norte; mudança no norte é proposta ao dono.
- R6: A chave do Linear fica só no Keychain do app; dispatcher e vigia usam o proxy local. O TuttiDash não renova nem reescreve credencial de outra ferramenta.
- R7: Limite de conta só aparece com fonte oficial ou local; leitura não oficial fica desligada por conta até "nao_oficial": true.
- R8: Nada pessoal vai para o repositório público.
- R9: A execução obedece à cópia assinada no bundle, nunca a arquivos que a lane consegue reescrever.

## §3 Desempate

1. Prova remota verde na head vence prova local e comentário DONE.
2. Freios e caminhos protegidos vencem concluir o card.
3. Estado honesto vence painel preenchido: sem medida, o texto é «sem medida».
4. Recusar vence adivinhar (manifesto com schema que o código não entende, dado ilegível).
5. Parar e chamar o dono vence insistir na mesma falha.

## §4 O que nunca se faz

- Deixar o agente da lane falar com o Linear ou com o GitHub.
- Usar prova local ou comentário DONE como autoridade de In Review ou de merge.
- Renovar ou reescrever credencial de outra ferramenta, ou gravar a chave do Linear em arquivo.
- Mostrar limite de conta sem fonte oficial ou local, ou sem "nao_oficial" ligado nessa conta.
- Deixar a lane editar o norte, o catálogo assinado ou os scripts de controle.
- Rodar a revisao-ia dentro do processo do vigia.
- Pôr dado pessoal no repositório público.

## §5 Glossário

- lane: faixa com um card, um worktree git e um agente por vez.
- dispatcher: a cada 60 s pega um card pronto, cria o worktree, roda o agente sem interface no tmux, faz push e abre PR em rascunho. Timeout ou erro marca o card com lane:parada ou lane:falhou.
- vigia: faz o merge com prova remota e revisão aprovadas, tria lanes paradas ou com falha e devolve o card à fila; na 3ª parada pelo mesmo motivo chama o dono.
- prova-remota: check remoto que precisa estar verde no SHA completo da head; é a prova para In Review e para o merge.
- [Revisor]: aprovação exigida na head, junto com a prova-remota, para o merge.
- revisao-ia: check de revisão por IA no GitHub Actions, quando esse workflow está na main.
- needs:dono: o card precisa de uma decisão do dono; aparece em «Esperando você».
- freio: limite acumulado por card (tentativas, gasto, tempo) conforme o esforço; estourado, o card fica fora da fila.
- protegidos: caminhos que nenhuma lane pode tocar; o norte entra sempre.
- norte: este arquivo. mapa: docs/produto/mapa.md, a parte factual (módulos, prova, convenções).
- nao_oficial: flag por conta que liga a leitura de uso não oficial.
- bundle assinado: cópia do controle gravada no app; é ela que o launchd executa.
