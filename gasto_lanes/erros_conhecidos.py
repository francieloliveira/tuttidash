"""Registro canônico dos erros conhecidos das lanes (FRA-668).

Fonte única do vocabulário de erros conhecidos (E1…E22): o vigia injeta o texto
deste módulo no prompt do revisor (`bots/prompts/revisor.md`) e da triagem da
parada (`bots/prompts/triagem-parada.md`) quando o documento do Linear não tem
lista (`linear.erros_conhecidos_doc_id` vazio ou sem conteúdo). O código (E#) é
estável: mudar um nome de erro é mudança de contrato — pede um card.

Cada erro conhecido:

  codigo:  E# estável, citado na instrução da parada (stop_note) e no veredito do
           revisor. A resposta ao dono não recebe o código: é em linguagem simples
           (regra em `bots/prompts/triagem-pendencia.md`).

  titulo:  nome curto, em português, usado no texto.

  resumo:  o que é, em uma frase.

  causa:   por que acontece nesta base.

  acao:    o que a lane deve fazer diferente na próxima rodada.

Este módulo não fala com Linear, tmux, git nem com o catálogo: puro, recebendo o
código e devolvendo o registro. É importado pelos dois scripts instalados
(`bots/watch.py` e `lanes/dispatcher.py` no mesmo sentido de `fila`).
"""
from __future__ import annotations

from typing import Optional

ERROS_CONHECIDOS: tuple[dict, ...] = (
    {
        "codigo": "E3",
        "titulo": "Divisão de trabalho violada",
        "resumo": "O agente editou fora do worktree, falou com Linear/GitHub ou publicou/mergeou por conta própria.",
        "causa": "A fronteira do card não estava na instrução; o agente estendeu o escopo.",
        "acao": "Voltar ao worktree da lane e ao escopo do card; quem publica é o dispatcher.",
    },
    {
        "codigo": "E5",
        "titulo": "Comando proibido / prova fora do dispatcher",
        "resumo": "O agente roda build, testes ou `safe_xcodebuild.sh`; a prova é sempre do dispatcher.",
        "causa": "Confusão sobre quem executa a prova.",
        "acao": "Não rodar: entregar commits e deixar o dispatcher provar.",
    },
    {
        "codigo": "E13",
        "titulo": "Recurso só na cópia local",
        "resumo": "Ferramenta, prompt ou script que vive fora do repo: nada deve viver só na cópia local.",
        "causa": "Instalação sem versionar o recurso; o checkout do repo é a fonte única.",
        "acao": "Versionar o recurso no repo antes de usar.",
    },
    {
        "codigo": "E14",
        "titulo": "Instalação no aparelho falhou",
        "resumo": "Instalação automática no aparelho que não terminou limpa.",
        "causa": "Falha no fluxo de instalação do app no aparelho.",
        "acao": "Rodar a instalação manualmente (`tools/install.sh`) e registrar o erro no card.",
    },
    {
        "codigo": "E19",
        "titulo": "Card promovido não estava pronto",
        "resumo": "Promoção Backlog→Todo com decisão de produto pendente ou aceite sem checklist fechado.",
        "causa": "O card subiu com risco alto ou pendência que a triagem não tinha resolvido.",
        "acao": "Resolver a pendência antes de promover.",
    },
    {
        "codigo": "E22",
        "titulo": "Prova sem evidência",
        "resumo": "Exit 0 sem a linha de prova na última tentativa; log vazio ou com 0 testes; unittest sem OK.",
        "causa": "O agente afirmou a prova sem rodar a suíte, ou entregou formato que o dispatcher não aceita.",
        "acao": "Quem roda a prova é o dispatcher: o agente entrega código, commits e result.json.",
    },
)


def todos() -> tuple[dict, ...]:
    """Erros conhecidos no cadastro canônico, na ordem de publicação."""
    return ERROS_CONHECIDOS


def por_codigo(codigo: Optional[str]) -> Optional[dict]:
    """O erro canônico de um código (ex.: ``E22``). None se não estiver no registro."""
    alvo = (codigo or "").strip().upper()
    if not alvo:
        return None
    return next((e for e in ERROS_CONHECIDOS if str(e.get("codigo") or "").upper() == alvo), None)


def formatar() -> str:
    """Texto único para injetar nos prompts (revisor e triagem): uma linha por erro
    conhecido, no formato que os prompts pedem. Sem chaves: o prompt é montado com
    `str.format`."""
    linhas = []
    for e in ERROS_CONHECIDOS:
        linhas.append(
            f"- **{e.get('codigo')}** — {e.get('titulo')}: {e.get('resumo')} Causa: {e.get('causa')} Ação: {e.get('acao')}."
        )
    return "\n".join(linhas) if linhas else "(nenhum erro conhecido registrado)"
