# Norte — TuttiDash

> Norte do projeto: o que ele é e o que não pode acontecer. Só o dono altera este arquivo.
> Agentes: leiam antes de planejar. Para mudar algo aqui, proponham ao dono (needs_dono); não editem.

## §1 Objetivo

O TuttiDash é o conjunto de ferramentas locais com que um desenvolvedor, no Mac dele percorre um projeto do Linear com agentes de código em lanes paralelas: um card, um worktree git e um agente por lane por vez. No Mac desse desenvolvedor, o dispatcher conduz o card até um PR em rascunho, o vigia só faz merge com a prova-remota verde na head e a aprovação do [Revisor] (e a revisao-ia, se main tiver esse workflow), e o notch mostra lanes, builds, testes, entregas, custo e limite quando há fonte oficial ou local. A interface e a maior parte da documentação estão em português do Brasil; o projeto é pessoal, compartilhado como está, sem promessa de suporte.

## §2 Restrições inegociáveis

- R1: Cada lane leva, por vez, um card, um worktree git e um agente.
- R2: O agente da lane não fala com o Linear nem com o GitHub.
- R3: O card só entra em In Review com a prova-remota verde no SHA completo da head, e a proteção de branch de main tem de exigir esse check.
- R4: O vigia só faz merge com essa prova verde e a aprovação do [Revisor] na head; se main tiver o workflow, também com a revisao-ia rodando no GitHub Actions.
- R5: As lanes executam os agentes sem supervisão, com as contas do dono: o agente edita código, roda comando e gasta dinheiro ou cota.
- R6: Em timeout ou erro o dispatcher chama o dono; segredo de revisão ou falha repetida chama o dono com needs:dono.
- R7: A chave do Linear fica no Keychain do app, com data protection; dispatcher e vigia falam com o Linear pelo proxy local.
- R8: O TuttiDash lê logs, o próprio estado e a própria config, e não renova nem reescreve credencial de outra ferramenta.
- R9: Limite de conta só entra na tela com fonte oficial ou local: a API de billing do GitHub Copilot e a base local de sessão do OpenCode.
- R10: Leitura de uso não oficial fica desligada por conta até "nao_oficial": true.
- R11: O catálogo vigente é o agents.d do bundle assinado, modo 0600 (no desenvolvimento, o agents.d do repositório); manifesto com schema acima do que o código entende é recusado.
- R12: O launchd executa a cópia do bundle assinado; enabled, heartbeat e lane-*.json ficam em ~/.transcentia/lanes/.
- R13: Os interruptores das lanes ficam ocultos até o runner, a view e os ajustes já estarem na pasta.
- R14: O conjunto pede macOS 14 ou mais novo e Python 3.9 ou mais novo, só com a biblioteca padrão.
- R15: O app Swift não tem dependência externa; leitura e agregação ficam no GastoCore, só com Foundation.
- R16: Assinatura e perfil pessoais do build ficam em .env.

## §3 Desempate

1. A prova-remota verde no SHA completo da head vence prova local e comentário DONE para In Review e para merge.
2. A aprovação do [Revisor] na head vence um merge feito só com a prova verde; com o workflow em main, a revisao-ia entra na mesma exigência.
3. Chamar o dono vence deixar a lane seguir em timeout, erro, segredo de revisão ou falha repetida.
4. O bundle assinado, modo 0600, vence o espelho em ~/.transcentia/agents.d/, porque a lane consegue reescrever esse espelho.
5. Recusar o manifesto vence adivinhar quando o schema está acima do que o código entende.
6. Estado honesto vence painel preenchido: sem medida o texto é «sem medida»; sem arquivo o bloco diz que não há leitura; sem batimento do dispatcher o estado é «Parado».
7. Runner, view e ajustes já presentes vencem o install, que nessa pasta só refresca dispatcher, módulos compartilhados e prompts.

## §4 O que nunca se faz

- Fazer o agente da lane falar com o Linear ou com o GitHub.
- Usar prova local ou comentário DONE como autoridade de In Review ou de merge.
- Renovar ou reescrever credencial de outra ferramenta.
- Gravar a chave do Linear em arquivo ou no item de login linear-transcentia-lanes, ou deixá-la ser lida por script, dispatcher ou vigia.
- Mostrar limite de Claude Code, Codex, Grok ou Gemini.
- Tratar o espelho ~/.transcentia/agents.d/ como o catálogo que a execução ou o app obedecem.
- Copiar os scripts de controle para ~/.transcentia/lanes/.
- Criar ~/.transcentia/lanes numa instalação limpa, ou nessa instalação copiar o runner, a view ou os ajustes.
- Substituir runner, view ou ajustes quando a pasta de lanes já existe.
- Gravar enabled direto ou criar PAUSE pelo botão desativar.
- Executar a revisao-ia no processo do vigia.
- Manter lista de agentes no código em vez de um arquivo em agents.d.
- Adivinhar manifesto cujo schema o código não entende.
- Descrever a prova-remota como proteção contra leitura de ~/.ssh ou de ~/.config/gh.

## §5 Glossário

- lane: faixa com um card, um worktree git e um agente por vez.
- dispatcher: a cada 60 s pega um card pronto, cria o worktree, roda o agente sem interface no tmux, faz push e abre PR em rascunho; em timeout ou erro chama o dono.
- prova-remota: check remoto que precisa estar verde no SHA completo da head; é a prova para In Review e para o merge em main.
- vigia: faz o merge quando a prova remota está verde e o [Revisor] aprovou a head (e a revisao-ia, se main tiver o workflow), tria lane parada ou com falha e chama o dono.
- [Revisor]: aprovação exigida na head, junto com a prova-remota, para o vigia fazer merge.
- revisao-ia: check de revisão por IA no GitHub Actions quando esse workflow está em main.
- needs:dono: chamada ao dono quando um segredo de revisão ou uma falha repetida pede uma pessoa.
- In Review: estado do card no Linear; só depois da prova-remota verde no SHA completo da head.
- agents.d: catálogo, um JSON por agente; o nome do arquivo é o nome da lane e o campo nome tem de ser o mesmo.
- bundle assinado: cópia do controle gravada no app antes do codesign; é ela que o launchd executa.
- GastoCore: leitura e agregação de gasto e de uso, só Foundation.
- FonteUso: motor plugável de leitura de limite de conta.
- nao_oficial: flag por conta que liga leitura de uso que não é oficial.
- lanes.budget_usd: teto de gasto que o operador configura na lane.
- protegidos: caminhos que o operador configura como protegidos.
- proxy local: caminho pelo qual dispatcher e vigia acessam o Linear sem receber a chave.
- brainstorm: tela para discutir ideias com um agente, gerar user stories e inserir cards no Linear pelo proxy.
