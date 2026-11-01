# Resolve um script do plano de controle no TuttiDash.app assinado (FRA-613).
# Uso, depois de source: script_controle lanes/lanes_window.py
# Não devolve caminho dentro de ~/.transcentia.
script_controle() {
  local rel="$1" dir vizinho app cand
  [[ -n "$rel" && "$rel" != *".transcentia"* && "$rel" != *".."* ]] || return 1
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  vizinho="$dir/../$rel"
  if [[ -f "$vizinho" ]]; then
    vizinho="$(cd "$(dirname "$vizinho")" && pwd)/$(basename "$vizinho")"
    if [[ "$vizinho" != *".transcentia"* ]]; then
      printf '%s\n' "$vizinho"
      return 0
    fi
  fi
  if [[ -n ${TUTTIDASH_APP:-} && ${TUTTIDASH_APP} != *".transcentia"* && ${TUTTIDASH_APP} != *".."* ]]; then
    cand="${TUTTIDASH_APP}/Contents/Resources/controle/${rel}"
    if [[ -f "$cand" ]]; then printf '%s\n' "$cand"; return 0; fi
  fi
  for app in "/Applications/TuttiDash.app" "${HOME}/Applications/TuttiDash.app"; do
    cand="${app}/Contents/Resources/controle/${rel}"
    if [[ -f "$cand" && "$cand" != *".transcentia"* ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}
