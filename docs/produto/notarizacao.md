# Notarização (FRA-720) — explicação curta

**Notarização** é o serviço da Apple que escaneia um app distribuído fora da App
Store em busca de malware e devolve um “bilhete” assinado. Você então grampeia
(`stapler`) esse bilhete no app. Sem ele, em outra máquina o macOS pode mostrar
“desenvolvedor não verificado” e bloquear a abertura.

## O que o TuttiDash tem hoje

- Build **assinado** com Apple Development (equipe `3QA76CY27W`).
- Provisioning profile de desenvolvimento válido até **30/11/2026**. Esse perfil
  é o que permite o app abrir **neste Mac**; vencido, o macOS mata o processo no
  launch.
- `tools/release.sh` pronto para gerar zip/SHA-256 e, opcionalmente, notarizar.

## Quando notarizar

| Uso | Precisa? | O que fazer |
|---|---|---|
| Só neste Mac, para você | **Não** | Renovar o profile de desenvolvimento antes de vencer (`tools/renovar-perfil.sh`). |
| Distribuir para outros Macs | **Sim, idealmente** | Ter Apple Developer Program, certificado **Developer ID Application**, perfil de `notarytool` e rodar `tools/release.sh --notarizar <perfil>`. |

## O que falta para notarizar

1. Conta paga do Apple Developer Program (a gratuita não emite Developer ID).
2. Certificado **Developer ID Application** instalado no Keychain.
3. Credenciais do `notarytool`:

```bash
xcrun notarytool store-credentials tuttidash
# pede Apple ID, senha de app e Team ID
```

4. Rodar:

```bash
tools/release.sh --notarizar tuttidash
```

Sem os itens 1–3, o script para antes do upload e o app continua apenas assinado.
Para uso local, isso não impede o app de abrir enquanto o profile estiver válido.

## Recomendação

Se o TuttiDash é para uso próprio neste Mac, **não notarizar agora**: basta
renovar o profile periodicamente. Se for entregar para outra pessoa, vale abrir
a conta paga e seguir os passos acima.
