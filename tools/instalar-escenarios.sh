#!/bin/zsh
# Copia las capas de los packs de pixel art (descargados aparte) a App/Escenarios/<zona>/1.png, 2.png…
# (de atrás hacia delante). Esa carpeta NO va a git: las licencias de craftpix no permiten
# redistribuir los ficheros. Uso: tools/instalar-escenarios.sh [carpeta con los .zip] (por defecto, el Escritorio)
set -e
ORIGEN="${1:-$HOME/Desktop}"
DESTINO="$(cd "$(dirname "$0")/.." && pwd)/App/Escenarios"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

zip_de() { find "$ORIGEN" -maxdepth 2 -name "$1" | head -1 }

NATURE=$(zip_de "Nature Landscapes Free Pixel Art.zip")
WINTER=$(zip_de "free-winter-nature-pixel-game-backgrounds.zip")
[ -n "$NATURE" ] || { echo "No encuentro «Nature Landscapes Free Pixel Art.zip» en $ORIGEN"; exit 1 }
unzip -q -o "$NATURE" -d "$TMP/nature"
[ -n "$WINTER" ] && unzip -q -o "$WINTER" -d "$TMP/winter"

# zona  carpeta-de-origen  capas (de atrás hacia delante)
copiar() {
  local zona=$1 src=$2; shift 2
  rm -rf "$DESTINO/$zona"; mkdir -p "$DESTINO/$zona"
  local i=1
  for capa in "$@"; do cp "$src/$capa.png" "$DESTINO/$zona/$i.png"; i=$((i + 1)); done
  echo "✓ $zona: $((i - 1)) capas"
}
copiar prados   "$TMP/nature/nature_5" 1 2 3 4
copiar pradera  "$TMP/nature/nature_2" 1 2 3 4
copiar bosque   "$TMP/nature/nature_4" 1 2 3 4
copiar montana  "$TMP/nature/nature_3" 1 2 4
[ -n "$WINTER" ] && copiar invierno "$TMP/winter/3" 1 2 3 4 5 6 7 8 9

cat > "$DESTINO/LICENCIAS.txt" <<'TXT'
Fondos de pixel art de craftpix.net («Nature Landscapes Free Pixel Art», «Free Winter Nature Pixel Game Backgrounds»).
Licencia: https://craftpix.net/file-licenses/ — se pueden usar en el juego/app, no redistribuir los ficheros.
Por eso esta carpeta está en .gitignore.
TXT
echo "Escenarios en $DESTINO"
