#!/bin/bash
# Compila MediaInfo y produce dist/MediaInfo.app con ffprobe incluido.
#
#   ./build.sh            compila en release y empaqueta
#   ./build.sh --run      además lanza la app al terminar
#   ./build.sh --debug    compila en debug (más rápido de iterar)
#   ./build.sh --no-ffprobe   no empaqueta ffprobe (usará el del sistema si existe)

set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION=release
LAUNCH=false
BUNDLE_FFPROBE=true

for argument in "$@"; do
  case "$argument" in
    --run) LAUNCH=true ;;
    --debug) CONFIGURATION=debug ;;
    --no-ffprobe) BUNDLE_FFPROBE=false ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opción desconocida: $argument" >&2; exit 1 ;;
  esac
done

APP="dist/MediaInfo.app"
CONTENTS="$APP/Contents"

echo "▸ Compilando ($CONFIGURATION)…"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/MediaInfo"

echo "▸ Montando el bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$CONTENTS/Helpers"
cp "$BINARY" "$CONTENTS/MacOS/MediaInfo"
cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "▸ Generando el icono…"
ICONSET="$(mktemp -d)/MediaInfo.iconset"
swift Tools/MakeIcon.swift "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

if [ "$BUNDLE_FFPROBE" = true ]; then
  echo "▸ Empaquetando ffprobe…"
  FFPROBE="$(command -v ffprobe || true)"
  FFMPEG="$(command -v ffmpeg || true)"
  if [ -z "$FFPROBE" ]; then
    echo "  ✗ No se encontró ffprobe en el PATH. Instálalo con:  brew install ffmpeg" >&2
    echo "    (o compila con ./build.sh --no-ffprobe para usar el del sistema en tiempo de ejecución)" >&2
    exit 1
  fi
  # ffmpeg va también: comparte las mismas bibliotecas (0,4 MB extra) y permite
  # generar miniaturas de los formatos que AVFoundation no abre, como MKV.
  python3 Tools/bundle_helpers.py "$APP" "$FFPROBE" ${FFMPEG:+"$FFMPEG"}
fi

echo "▸ Firmando…"
# Firma ad hoc: suficiente para ejecutar en local. Para distribuir a terceros hace
# falta un Developer ID y notarización.
codesign --force --deep --sign - "$APP" 2>/dev/null

# Refresca el registro de Launch Services para que «Abrir con…» vea la app enseguida.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ Listo: $APP ($SIZE)"

if [ "$LAUNCH" = true ]; then
  open "$APP"
fi
