#!/usr/bin/env bash
# Confere, antes de publicar, que os arquivos versionados não levam dado pessoal nem leitura
# não oficial (FRA-565). Olha só o que o git versiona (git ls-files), menos este script.
#   tools/checar-publicacao.sh          sai 0 sem achados, 1 com achados
# Com o gitleaks instalado (brew install gitleaks), roda também a busca de segredos no histórico.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

achados=0
avisar(){ echo "✗ $1"; echo "$2" | sed 's/^/    /' | head -20; achados=1; }

arquivos=()
while IFS= read -r f; do
  [[ "$f" == tools/checar-publicacao.sh ]] && continue
  [[ -f "$f" ]] && arquivos+=("$f")
done < <(git ls-files)

buscar(){ # descrição, regex (grep -E)
  local desc="$1" re="$2" r
  r=$(grep -nIE -- "$re" "${arquivos[@]}" 2>/dev/null)
  [[ -n "$r" ]] && avisar "$desc" "$r"
}

# 1. Pastas que nunca vão para o público
r=$(printf '%s\n' "${arquivos[@]}" | grep -E '(^|/)Privado/|(^|/)GOAL\.md$|\.env$' )
[[ -n "$r" ]] && avisar "arquivo que não deve ser versionado" "$r"

# 2. Pessoas e projetos pessoais (os nomes antigos dos agentes viraram funções)
buscar "nome pessoal ou de persona" '\b([Tt]heo|[Jj]ulia|[Oo]llie|[Ll]aya)(\b|_)|francieltechnix|[Ff]ranciel\b|TranscentIA-App'
r=$(grep -nIE 'francieloliveira' "${arquivos[@]}" 2>/dev/null | grep -vE 'github\.com/francieloliveira/tuttidash')
[[ -n "$r" ]] && avisar "usuário pessoal fora da URL do repositório" "$r"

# 3. Ids reais: UUID que não seja de teste (aaaaaaaa-…, 00000000-…)
r=$(grep -nIoE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${arquivos[@]}" 2>/dev/null \
    | grep -vE ':(aaaaaaaa|00000000|11111111|12345678)-')
[[ -n "$r" ]] && avisar "UUID que parece real" "$r"

# 4. Identidade de assinatura (40 hex maiúsculos)
buscar "hash de certificado" '\b[0-9A-F]{40}\b'

# 5. Endpoints e credenciais de login fora das APIs oficiais
buscar "endpoint ou credencial não oficial" 'api/oauth/usage|oauth-2025-04-20|cli-chat-proxy\.grok|api2\.cursor\.sh|wham/usage|chatgpt\.com/backend-api|opencode\.ai/console|cloudcode-pa\.googleapis|retrieveUserQuota|loadCodeAssist|Claude Code-credentials|\.credentials\.json|oauth_creds\.json|state\.vscdb'

# 6. Segredos óbvios
buscar "possível segredo" '(sk-ant-|sk-proj-|ghp_[A-Za-z0-9]{20}|github_pat_|lin_api_[A-Za-z0-9]{10}|xai-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)'

if command -v gitleaks >/dev/null; then
  # Só a cópia atual dos arquivos versionados (o que vai para o público), sem pastas ignoradas.
  copia=$(mktemp -d); relatorio="$copia.gitleaks.txt"
  printf '%s\n' "${arquivos[@]}" | rsync -a --files-from=- . "$copia/"
  gitleaks detect --no-git --no-banner --redact -s "$copia" >"$relatorio" 2>&1 \
    || avisar "gitleaks achou algo (detalhe em $relatorio)" "$(tail -5 "$relatorio")"
  rm -rf "$copia"
else
  echo "· gitleaks não instalado: só as buscas acima (brew install gitleaks)"
fi

if (( achados )); then echo "Há achados. Corrija antes de publicar."; exit 1; fi
echo "✓ nada encontrado em ${#arquivos[@]} arquivos"
