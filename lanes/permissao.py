"""Casa uma regra Bash com o comando, do mesmo jeito que o CLI.

Um só lugar (guia de permissões, "Rule Matching Reference"). O dispatcher
copia o allow/deny para o processo; este módulo é o que o teste confere.
"""
from __future__ import annotations

import re


def bash_casa(padrao: str, comando: str) -> bool:
    """`:*` no fim é prefixo cru, sem fronteira de palavra.

    `Bash(git diff:*)` casa `git difftool`. Um token só nessa forma também
    casa o basename (`/usr/bin/security` ≡ `security`). `Bash(git diff *)`
    exige o espaço, ou o comando igual a `git diff`. `*` no meio é glob do
    comando inteiro: casa qualquer caractere, inclusive espaço e barra, como
    `Bash(git commit *-F*)` casa `git commit -q -F~/.grok/auth.json`. `?` e
    `[...]` também.
    """
    cmd = comando.strip()
    if not cmd or not padrao:
        return False
    if padrao.endswith(":*"):
        prefixo = padrao[:-2]
        if cmd.startswith(prefixo):
            return True
        if " " not in prefixo.strip():
            primeiro = cmd.split()[0]
            if primeiro.rsplit("/", 1)[-1] == prefixo.strip():
                return True
        return False
    if padrao.endswith(" *") and not any(c in padrao[:-2] for c in "*?["):
        prefixo = padrao[:-2]
        return cmd == prefixo or cmd.startswith(prefixo + " ") or cmd.startswith(prefixo + "\t")
    if any(c in padrao for c in "*?["):
        return re.fullmatch(_re_glob_bash(padrao), cmd) is not None
    return cmd.startswith(padrao) and (len(cmd) == len(padrao) or cmd[len(padrao)] in " \t")


def _re_glob_bash(padrao: str) -> str:
    """`*` casa qualquer sequência. O padrão tem de cobrir o comando inteiro."""
    i, n = 0, len(padrao)
    out = ["^"]
    while i < n:
        ch = padrao[i]
        if ch == "*":
            out.append(".*")
            i += 1
            continue
        if ch == "?":
            out.append(".")
            i += 1
            continue
        if ch == "[":
            fim = padrao.find("]", i + 1)
            if fim > i + 1:
                classe = padrao[i + 1:fim]
                if classe.startswith("!"):
                    out.append("[^" + classe[1:] + "]")
                else:
                    out.append("[" + classe + "]")
                i = fim + 1
                continue
        out.append(re.escape(ch))
        i += 1
    out.append("$")
    return "".join(out)
