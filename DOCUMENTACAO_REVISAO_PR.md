# Documento de Decisão — Revisão de PR

**Projeto:** TuttiDash  
**Tela:** Ajustes > Revisão  
**Status:** Proposta de simplificação  
**Data:** 29/10/2026  

---

## 1. Objetivo

Simplificar a tela de Revisão de PR, removendo configurações manuais repetitivas e delegando ao sistema a escolha do revisor, modelo e esforço com base nas lanes já cadastradas.

---

## 2. Problema da tela atual

- Mistura configurações globais (revisor dos PRs) com uma lista longa de modelos por ferramenta (Claude Code, Codex, OpenCode, Grok CLI…).
- Repete a mesma estrutura (modelo → esforço → papel) em dezenas de linhas.
- Subtítulo `"Lista que se atualiza sozinha uma vez por dia"` repetido exaustivamente.
- Botões `"Restaurar padrão"` espalhados, gerando ruído visual.
- O usuário precisa selecionar manualmente modelo e esforço para cada revisor, mesmo que esses dados já existam nas lanes.

---

## 3. Proposta de simplificação

O usuário escolhe apenas **qual lane será a revisora de PR**.  
Modelo e nível de esforço são **herdados automaticamente dessa lane**.

O Revisor Reserva é opcional e, quando automático, segue regras de fallback definidas pelo sistema.

---

## 4. Regras de negócio

### 4.1 Revisor Padrão (Lane Revisora)

| Item | Regras |
|------|--------|
| Seleção | O usuário escolhe **uma lane** como revisora de PR. |
| Modelo | Herdado da lane revisora. Não é selecionável nesta tela. |
| Esforço | **Vem da task/card do PR** (etiqueta de esforço no Linear), não da lane. |
| Atualização de modelos | Consome a listagem de modelos que as lanes já populam. Não há busca externa agendada ("uma vez por dia"). |
| Exclusão de autor | Nunca chama o mesmo fornecedor/usuário que escreveu o PR. |

### 4.2 Como o Revisor é chamado (fluxo principal)

1. O sistema identifica a **lane revisora** configurada na tela de Ajustes > Revisão.
2. Chama o revisor associado a essa lane, usando o **modelo e esforço definidos nela**.
3. Aplica a regra de exclusão: **não revisa o próprio autor do PR**.

### 4.3 Revisor Reserva (opcional)

| Item | Regras |
|------|--------|
| Ativação | Toggle: ligado ou desligado. |
| Modo | Automático (sem seleção manual de lane de reserva). |

### 4.4 Regras de Fallback do Revisor Reserva

O sistema tenta encontrar uma lane de reserva nesta ordem de prioridade:

| Prioridade | Critério de busca |
|------------|-------------------|
| **1ª tentativa** | Outra lane disponível com o **mesmo nível de esforço da task/card** do PR. |
| **2ª tentativa** | Lane com **esforço igual ou acima** do esforço da task. |
| **Resultado final** | Se nenhuma lane estiver disponível após as duas tentativas, **não há revisor reserva** para esse PR. |

> Exemplo prático: se a task do PR tem esforço *Médio*, o sistema primeiro busca outra lane com esforço *Médio* disponível. Se não houver, busca qualquer lane com esforço *Médio, Alto ou Acima*.

### 4.5 Casos extremos

| Situação | Comportamento do sistema |
|----------|--------------------------|
| Nenhuma lane revisora configurada | O PR não entra na fila de revisão automática (ou segue para fila genérica, conforme regra de produto). |
| Revisor reserva ativado, mas nenhuma lane disponível após fallback | O PR fica sem revisor reserva. Opcionalmente, o sistema pode notificar o responsável. |
| Única lane disponível é a do autor do PR | O PR não é atribuído a essa lane para revisão (regra de exclusão do autor se sobrepõe). |

---

## 5. Comparativo: Antes vs Depois

| Antes | Depois |
|-------|--------|
| Usuário seleciona revisor, modelo, esforço e papel para cada ferramenta | Usuário seleciona apenas a **lane revisora** |
| Tabela com dezenas de linhas repetitivas | Uma linha: lane, modelo (herdado), esforço (herdado) |
| Botão "Restaurar padrão" em cada seção | Removido (não há o que restaurar) |
| Subtítulo repetitivo em cada linha | Removido |
| Revisor reserva configurado manualmente | Automático com fallback de esforço |

---

## 6. Telas

### 6.1 Wireframe textual

```
Revisão de PR
Quem revisa os pull requests antes do merge

─────────────────────────────────────────────
Lane revisora: [desenvolvimento ▼]
  Modelo: opus        Esforço: Médio

☑ Revisor reserva automático
  (outra lane com mesmo esforço; senão, esforço padrão ou acima)

[Salvar]
```

### 6.2 Fluxograma

Consulte o arquivo `fluxograma_revisao_pr.mmd`.

---

## 7. Próximos passos de implementação

1. Remover da tela a tabela de "Modelo de cada revisor".
2. Substituir por seletor único de **Lane Revisora**.
3. Exibir modelo e esforço apenas como leitura, herdados da lane selecionada.
4. Implementar toggle de Revisor Reserva Automático.
5. Implementar serviço de fallback:
   - Buscar lane disponível com mesmo esforço.
   - Se não houver, buscar lane com esforço padrão ou acima.
6. Aplicar regra de exclusão do autor do PR.
7. Validar casos extremos (sem lane configurada, sem lane disponível, etc.).
