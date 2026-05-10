#!/bin/bash
# =============================================================
# shelfmark.sh - Script post-descarga de Shelfmark
# Ubicación: /config/shelfmark.sh
# =============================================================

# ── Configuración ─────────────────────────────────────────────
source "/config/shelfmark.env"

exec >> "$LOG_FILE" 2>&1

echo ""
echo "============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nueva descarga recibida"
echo "============================================================"

# ── Parámetros ────────────────────────────────────────────────
FILEPATH="$1"

if [[ -z "$FILEPATH" ]]; then
  echo "[ERROR] No se recibió ruta de archivo (\$1 vacío). Abortando."
  paste_error "FILEPATH vacío — el script fue llamado sin argumentos"
  exit 1
fi

FILENAME="$(basename "$FILEPATH")"

# ── Helper: enviar notificación Gotify ────────────────────────
gotify_notify() {
  local title="$1"
  local message="$2"
  local priority="${3:-5}"

  if [ "$NOTIFICATIONS" == "yes" ]; then
      curl -s -X POST "$GOTIFY_URL" \
        -H "X-Gotify-Key: ${GOTIFY_TOKEN}" \
        -F "title=${title}" \
        -F "message=${message}" \
        -F "priority=${priority}" > /dev/null

      echo "[Gotify] Notificación enviada: ${title}"
  fi    
}

# ── Helper: subir log a pastebin y notificar error ────────────
paste_error() {
  local context="${1:-error desconocido}"
  local log_content
  log_content=$(tail -100 "$LOG_FILE" 2>/dev/null)
  [ -z "$log_content" ] && log_content="(sin log disponible)"

  local payload
  payload=$(printf '{"title":"shelfmark: %s — %s","content":%s,"language":"plaintext","ttl_seconds":604800}' \
    "${FILENAME:-desconocido}" \
    "$context" \
    "$(echo "$log_content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")

  local resp paste_id paste_url
  resp=$(curl -s -X POST "${PASTEBIN_URL}/api/pastes" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)

  paste_id=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -n "$paste_id" ]; then
    paste_url="${PASTEBIN_URL}/p/${paste_id}"
    echo "[Pastebin] Log subido: ${paste_url}"
    gotify_notify \
      "❌ Shelfmark - Error" \
      "📄 ${FILENAME:-desconocido}
⚠️ ${context}
📋 Log: ${paste_url}" \
      10
  else
    echo "[Pastebin] No se pudo subir el log."
    gotify_notify \
      "❌ Shelfmark - Error" \
      "📄 ${FILENAME:-desconocido}
⚠️ ${context}
(pastebin no disponible)" \
      10
  fi
}

# Trap global para errores inesperados
if [ "$PASTEBIN" == "yes" ]; then
    trap 'paste_error "error inesperado en línea $LINENO (exit $?)"' ERR
fi    

# =============================================================
# PASO 1 — Notificación de descarga finalizada
# =============================================================
echo ""
echo "[PASO 1] Notificación de descarga"

if [[ ! -f "$FILEPATH" ]]; then
  echo "[ERROR] El archivo no existe: $FILEPATH"
  if [ "$PASTEBIN" == "yes" ]; then
      paste_error "archivo no encontrado: ${FILENAME}"
  fi    
  exit 1
fi

FILE_SIZE_BYTES=$(stat -c%s "$FILEPATH" 2>/dev/null || echo 0)
FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", ${FILE_SIZE_BYTES}/1048576}")

echo "[INFO] Archivo : $FILEPATH"
echo "[INFO] Tamaño  : ${FILE_SIZE_MB} MB"

gotify_notify \
  "📥 Shelfmark - Descarga completada" \
  "📖 ${FILENAME}\n💾 Tamaño: ${FILE_SIZE_MB} MB" \
  5

# =============================================================
# PASO 2 — Escaneo antivirus (ClamAV)
# =============================================================
if [ "$SCAN" == "yes" ]; then
    echo ""
    echo "[PASO 2] Escaneo antivirus"

    CLEAN_FILE=""
    INFECTED_COUNT=0

    echo "[ClamAV] Escaneando: $FILENAME"

    CLAM_RESPONSE=$(curl -s -X POST "$CLAMAV_URL" \
      -F "FILES=@\"${FILEPATH}\"")

    echo "[ClamAV] Respuesta raw: $CLAM_RESPONSE"

    # Parseo sin jq — extraer is_infected del primer resultado
    IS_INFECTED=$(echo "$CLAM_RESPONSE" | grep -o '"is_infected":[^,}]*' | head -1 | cut -d':' -f2 | tr -d ' "')

    if [[ "$IS_INFECTED" == "true" ]]; then
        # Extraer nombre del virus
        VIRUS_NAME=$(echo "$CLAM_RESPONSE" | grep -o '"viruses":\["[^"]*"' | head -1 | cut -d'"' -f4)
        echo "[ClamAV] ⚠️  INFECTADO: $FILENAME — $VIRUS_NAME"
        rm -f "$FILEPATH"
        echo "[ClamAV] Archivo eliminado del disco."
        INFECTED_COUNT=1

        gotify_notify \
           "🦠 Shelfmark - Virus detectado" \
           "⚠️ Archivo infectado y eliminado:\n📄 ${FILENAME}\n🔬 Virus: ${VIRUS_NAME}" \
          10
    else
        echo "[ClamAV] ✅ Limpio: $FILENAME"
        CLEAN_FILE="$FILEPATH"

        gotify_notify \
          "🛡️ Shelfmark - Escaneo completado" \
          "✅ Archivo limpio: ${FILENAME}\n🦠 Infectados eliminados: ${INFECTED_COUNT}" \
          1
    fi
else
    CLEAN_FILE="$FILEPATH"
fi    

# =============================================================
# PASO 3 — Transferencia
# =============================================================
if [ "$TRANSFER" == "yes" ]; then
    echo ""
    echo "[PASO 3] Transferencia de archivos"

    if [[ -z "$CLEAN_FILE" ]]; then
      echo "[INFO] No hay archivos limpios para transferir. Saltando."
    else
      echo "[Transfer] Enviando: $FILENAME → destino: $TRANSFER_DESTINATION"

      TRANSFER_RESPONSE=$(curl -s -X POST "$TRANSFER_URL" \
        -F "file=@\"${CLEAN_FILE}\"" \
        -F "destination=${TRANSFER_DESTINATION}")

      echo "[Transfer] Respuesta: $TRANSFER_RESPONSE"
    fi
fi    

# =============================================================
# PASO 4 — Generación de ficha con Butler-API
# =============================================================
if [ "$CARDS" == "yes" ]; then
    echo ""
    echo "[PASO 4] Generación de ficha (Butler-API)"

    if [[ -z "$CLEAN_FILE" ]]; then
      echo "[INFO] No hay archivos limpios para procesar con Butler-API. Saltando."
    else
      echo "[Butler] Procesando: $FILENAME"

      BUTLER_RESPONSE=$(curl -s -X POST "$BUTLER_URL" \
        -F "filename=${FILENAME}")

      echo "[Butler] Respuesta: $BUTLER_RESPONSE"

      # Extraer status sin jq
      BUTLER_STATUS=$(echo "$BUTLER_RESPONSE" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
      BUTLER_TITULO=$(echo "$BUTLER_RESPONSE" | grep -o '"titulo":"[^"]*"' | cut -d'"' -f4)
  
      if [ "$BUTLER_STATUS" = "ok" ]; then
            echo "Ficha generada: ${BUTLER_TITULO}"
      else
            echo "WARN: Butler-API no devolvió ok para ${FILENAME}. Respuesta: ${BUTLER_RESPONSE}"
            gotify_notify \
            "⚠️ Shelfmark - Butler-API" \
            "No se pudo generar la ficha para:\n${FILENAME}" \
            5
      fi
    fi
fi

# =============================================================
echo ""
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Script finalizado."
echo "============================================================"

exit 0
