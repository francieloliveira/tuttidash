#!/usr/bin/env bash
# Testa o cfg num HOME vazio: sem arquivo devolve os padrões; legado e novo têm prioridade certa.
set -euo pipefail
CFG="$(cd "$(dirname "$0")" && pwd)/cfg"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME=$T; unset TRANSCENTIA_GASTO_CONFIG
f=0; ok(){ [ "$1" == "$2" ] && echo "ok  $3" || { echo "FALHA $3: '$1' != '$2'"; f=1; }; }
ok "$("$CFG" get estresse.saida)" "~/Library/Logs/TuttiDash/carga-mac.tsv" "padrão da carga do Mac"
ok "$("$CFG" get estresse.intervalo_s)" 15 "intervalo segue na chave antiga"
ok "$("$CFG" get preflight.max_load 16)" 16 "sem arquivo: padrão da linha de comando"
ok "$("$CFG" get bots_chave.limite_pct)" 90 "sem arquivo: padrão interno"
ok "$("$CFG" get lane_view.pensamento)" true "lane_view: raciocínio ligado por padrão"
ok "$("$CFG" get lane_view.pensamento_linhas)" 14 "lane_view: linhas de raciocínio"
ok "$("$CFG" get lane_view.diff_linhas)" 14 "lane_view: linhas de diff"
ok "$("$CFG" get nao.existe xyz)" xyz "chave desconhecida"
ok "$("$CFG" get preflight.skip_preflight_first)" true "bool"
ok "$("$CFG" path)" "" "sem arquivo: path vazio"
mkdir -p "$T/.transcentia/tools"; echo '{"aviso_pct":70,"preflight":{"max_load":20}}' > "$T/.transcentia/tools/config.json"
ok "$("$CFG" get preflight.max_load 16)" 20 "legado lido"
"$CFG" migrate >/dev/null
N="$T/Library/Application Support/TuttiDash/config.json"
LK="$T/Library/Application Support/Lanekeeper/config.json"
ok "$([ -f "$T/.transcentia/tools/config.json" ] && echo sim)" sim "migração mantém legado"
ok "$("$CFG" get version)" 1 "versão"
ok "$("$CFG" get aviso_pct)" 70 "migração leva chaves antigas"
ok "$("$CFG" get preflight.min_free_gb)" 10 "migração completa padrões"
echo '{"version":1,"preflight":{"max_load":30}}' > "$N"
ok "$("$CFG" get preflight.max_load 16)" 30 "novo tem prioridade"
mkdir -p "$T/Library/Application Support/TranscentIA Gasto"; echo '{"preflight":{"max_load":40}}' > "$T/Library/Application Support/TranscentIA Gasto/config.json"
ok "$("$CFG" get preflight.max_load 16)" 30 "TuttiDash vence TranscentIA Gasto"
rm "$N"; ok "$("$CFG" get preflight.max_load 16)" 40 "TranscentIA Gasto aceito"
"$CFG" migrate >/dev/null; ok "$("$CFG" get preflight.max_load 16)" 40 "migra de TranscentIA Gasto"
echo '{"version":1,"preflight":{"max_load":33}}' > "$N"; "$CFG" migrate >/dev/null
ok "$("$CFG" get preflight.max_load 16)" 33 "migrate não muda valor existente"
ok "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['linear']['owner_label'])" "$N")" "needs:dono" "migrate completa chaves novas"
rm "$N"; mkdir -p "$(dirname "$LK")"; echo '{"version":1,"preflight":{"max_load":44}}' > "$LK"; echo '{"x":1}' > "$(dirname "$LK")/agendas.json"
ok "$("$CFG" get preflight.max_load 16)" 44 "Lanekeeper aceito como reserva"
"$CFG" migrate >/dev/null; ok "$("$CFG" get preflight.max_load 16)" 44 "migra de Lanekeeper"
ok "$([ -f "$LK" ] && [ -f "$(dirname "$N")/agendas.json" ] && echo sim)" sim "copia a pasta Lanekeeper sem apagar"
echo 'lixo' > "$N"
ok "$("$CFG" get preflight.max_load 16)" 16 "ilegível cai no padrão"

# medir-estresse: padrão novo; arquivo legado já gravado continua; config explícita vence.
MEDIR="$(cd "$(dirname "$0")" && pwd)/medir-estresse.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H2=$(mktemp -d)
HOME=$H2
unset TRANSCENTIA_GASTO_CONFIG
ok "$(bash "$MEDIR" --saida)" "$H2/Library/Logs/TuttiDash/carga-mac.tsv" "sem arquivo antigo: log do TuttiDash"
mkdir -p "$H2/Library/Logs/TranscentIA"
printf 'hora\n' > "$H2/Library/Logs/TranscentIA/estresse.tsv"
ok "$(bash "$MEDIR" --saida)" "$H2/Library/Logs/TranscentIA/estresse.tsv" "arquivo antigo continua"
mkdir -p "$H2/.transcentia/tools" "$H2/Library/Application Support/TuttiDash"
cp "$CFG" "$H2/.transcentia/tools/cfg"; chmod +x "$H2/.transcentia/tools/cfg"
echo '{"version":1,"estresse":{"saida":"/tmp/carga-custom.tsv","intervalo_s":30}}' > "$H2/Library/Application Support/TuttiDash/config.json"
ok "$(cd "$ROOT" && HOME=$H2 bash "$MEDIR" --saida)" "/tmp/carga-custom.tsv" "estresse.saida da config vence o arquivo antigo"
rm -rf "$H2"
exit $f
