"""Notificação externa por webhook (Slack ou compatível).

O webhook é segredo: não vai para o log nem para a saída de erro. O envio é
opcional e desligado por padrão; sem `integracoes.webhook` na config, nada sai.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request


def webhook(get) -> str:
    """URL configurada em `integracoes.webhook`; vazia = desligado."""
    try:
        valor = get("integracoes.webhook", "") or ""
    except Exception:  # noqa: BLE001
        return ""
    valor = str(valor).strip()
    if not (valor.startswith("https://") or valor.startswith("http://")):
        return ""
    return valor


def redigir(texto, url: str) -> str:
    return str(texto).replace(url, "***") if url else str(texto)


def enviar(url: str, texto: str, timeout: int = 15) -> dict:
    """Envia `{"text": ...}`. Devolve `{"ok", "status", "erro"}`; nunca o webhook."""
    if not url:
        return {"ok": False, "status": 0, "erro": "webhook não configurado"}
    corpo = json.dumps({"text": str(texto)[:12000]}, ensure_ascii=False).encode("utf-8")
    pedido = urllib.request.Request(url, data=corpo, method="POST",
                                    headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(pedido, timeout=timeout) as resp:
            return {"ok": 200 <= resp.status < 300, "status": resp.status, "erro": ""}
    except urllib.error.HTTPError as exc:
        return {"ok": False, "status": exc.code, "erro": redigir(f"HTTP {exc.code}", url)}
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"ok": False, "status": 0, "erro": redigir(str(exc), url)}
