# Norte — TuttiDash

> Norte do projeto: o que ele é e o que não pode acontecer. Só o dono altera este arquivo.
> Agentes: leiam antes de planejar. Para mudar algo aqui, proponham ao dono (needs_dono); não editem.

## §1 Objetivo

O TuttiDash é o conjunto de ferramentas locais com que a TranscentIA percorre um backlog do Linear com agentes de código em lanes paralelas e acompanha esse trabalho pelo notch do Mac. Cada lane leva um card, um worktree git e um agente de cada vez; o conjunto entrega o dispatcher, o vigia, o app de notch, o ledger de gasto, o catálogo de agentes e o brainstorm, como exemplo do fluxo de um desenvolvedor, partilhado como está, com a interface e a maior parte da documentação em português do Brasil.

## §2 Restrições inegociáveis

- R1: Uma lane, de cada vez: um card, um worktree git e um agente.
- R2: In Review só com prova-remota verde no SHA completo do head. A proteção do branch de main tem de exigir essa prova.
- R3: Merge só com essa prova verde e com a aprovação do [Revisor] no mesmo head. O check revisao-ia entra quando o main tem esse workflow, e a revisão por IA corre no GitHub Actions.
- R4: Timeout ou erro chama o dono. Segredo de revisão ou falha repetida chama o dono com needs:dono.
- R5: A chave Linear fica só no Keychain do app (data protection). O dispatcher e o vigia falam com um proxy local e não recebem a chave. Os scripts não a leem.
- R6: Cota de conta só de fonte oficial ou local: a API de billing do GitHub Copilot e a base local de sessões do OpenCode. Sem API pública, o app não mostra o limite.
- R7: Leitura de uso não oficial fica desligada por conta; "nao_oficial": true liga. Assinatura e perfil do build pessoal ficam em .env.
- R8: Agente novo só entra por um manifesto em agents.d, lido pelo Swift e pelo Python. A execução obedece à cópia do bundle assinado, modo 0600.
- R9: O launchd corre a cópia das lanes no bundle assinado. O estado da lane fica em ~/.transcentia/lanes/.
- R10: macOS 14 ou mais novo, projeto pessoal, sem promessa de suporte. Python 3.9+ só com a biblioteca padrão.
- R11: O app Swift não tem dependência externa. O GastoCore só usa Foundation.
- R12: Install limpo não cria ~/.transcentia/lanes e não copia runner, vista nem ajustes. Com a pasta já existente, esses três ficam intactos. Os interruptores da lane ficam ocultos até esses arquivos estarem na pasta.
- R13: A interface do app e a maior parte da documentação ficam em português do Brasil.
- R14: A prova-remota não impede a lane de ler ~/.ssh nem ~/.config/gh.
- R15: Sem medida, a faixa diz «sem medida». Sem batimento do dispatcher, o estado é «Parado». Sem arquivo, o bloco diz que não há leitura.

## §3 Desempate

1. Para In Review e para merge, a prova-remota no SHA completo do head vence prova local e comentário DONE.
2. Merge com prova remota verde e [Revisor] no head vence merge só com a prova, só com o [Revisor] ou só com revisao-ia. revisao-ia é exigência a mais quando esse workflow está no main.
3. Chamar o dono vence timeout, erro, segredo de revisão ou falha repetida tratados só pela automação.
4. Omitir o limite vence exibir cota sem fonte oficial ou local.
5. A flag apagada vence leitura de uso não oficial.
6. «sem medida», «Parado» ou a frase de que não há leitura vencem um valor na tela quando faltam medida, batimento ou arquivo.
7. A cópia do catálogo no bundle assinado vence ~/.transcentia/agents.d/ e o espelho que o install deixa nessa pasta.
8. A cópia das lanes no bundle assinado vence script antigo em ~/.transcentia/lanes/.
9. Runner, vista e ajustes já presentes em ~/.transcentia/lanes vencem a cópia que o install traria.
10. Recusar o manifesto vence interpretá-lo quando o schema é mais novo do que o código entende.
11. o teto vence, a lane para de gastar e o dono é chamado, no mesmo espírito do timeout e do erro. O README.md manda configurar o teto e chama o dono em timeout ou erro; não descreve o estouro.

## §4 O que nunca se faz

- O agente da lane falar com o Linear ou com o GitHub.
- Tratar prova local ou comentário DONE como autoridade de In Review ou de merge.
- Renovar ou reescrever credencial de outra ferramenta.
- Gravar a chave Linear em arquivo ou no item de login linear-transcentia-lanes, ou passá-la ao dispatcher, ao vigia ou a um script.
- Correr a revisao-ia dentro do vigia.
- Exibir limite de conta sem fonte oficial ou local.
- Ligar leitura de uso não oficial sem "nao_oficial": true nessa conta.
- Mostrar número no lugar de «sem medida», «Parado» ou da frase de que não há leitura.
- Manter lista de agentes no código.
- Fazer o CLI obedecer a ~/.transcentia/agents.d/.
- Apontar o launchd para scripts copiados em ~/.transcentia/lanes/.
- Gravar enabled direto ou criar PAUSE a partir do Desativar do notch.
- Substituir, no install, runner, vista ou ajustes quando ~/.transcentia/lanes já existe.

## §5 Glossário

- lane: um card do Linear, um worktree git e um agente, um de cada vez.
- dispatcher: a cada 60 s pega um card pronto, cria o worktree, corre o agente headless no tmux, faz push e abre um PR em rascunho.
- vigia: faz o merge quando a prova remota está verde e o [Revisor] aprovou o head; tria lane parada ou falhada e chama o dono.
- prova-remota: check remoto no SHA completo do head; autoridade para In Review e, com o [Revisor], para o merge em main.
- [Revisor]: aprovação no head exigida para o merge, além da prova remota.
- revisao-ia: check de revisão por IA no GitHub Actions, exigido no merge quando o main tem esse workflow.
- needs:dono: chamada ao dono quando um segredo de revisão ou uma falha repetida precisa de uma pessoa.
- proxy local: caminho pelo qual o dispatcher e o vigia chamam o Linear sem receber a chave.
- agents.d: fonte única dos manifestos; um JSON por agente e o nome do arquivo é o nome da lane.
- GastoCore: leitura e agregação de gasto e de uso, só Foundation.
- gasto: ledger de custo lido dos logs das lanes, por dia, semana, card e lane.
- FonteUso: motor de leitura de uso, plugável.
- nao_oficial: campo por conta que liga leitura de uso fora da fonte oficial.
- protegidos: caminhos que o usuário marca como protegidos na configuração.
- lanes.budget_usd: teto de gasto configurável das lanes.
- brainstorm: tela para discutir ideias com um agente, gerar user stories e inserir cards no Linear via proxy.
- notch: app SwiftUI/AppKit no notch e na barra de menus, com lanes, builds, testes, entregas, custo e ajustes.
- bundle de controle: cópia assinada das lanes e dos módulos que o launchd executa, gravada pelo build.sh antes do codesign.
