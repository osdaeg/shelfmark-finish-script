# shelfmark.sh

Script post-descarga para [Shelfmark](https://github.com/calibrain/shelfmark) (anteriormente conocido como calibre-web-automated-book-downloader). Se ejecuta automáticamente cada vez que finaliza la descarga de un libro y orquesta un pipeline de escaneo, transferencia y generación de fichas.

## ¿Qué hace?

Cada vez que Shelfmark descarga un libro, el script realiza los siguientes pasos en orden:

1. **Notificación de descarga** — Envía un aviso a Gotify con el nombre del archivo y su tamaño en MB.
2. **Escaneo antivirus** — Analiza el archivo con ClamAV REST API. Si está infectado, lo elimina del disco y notifica con prioridad máxima.
3. **Transferencia** — Si el archivo está limpio, lo transfiere a Booklore mediante Transferr.
4. **Generación de ficha** — Llama a Butler-API para generar una ficha HTML con reseña del libro vía Gemini.

Cada paso puede habilitarse o deshabilitarse de forma independiente desde el archivo de configuración.

Ante cualquier error, el script sube automáticamente las últimas líneas del log a [paste.sh](https://github.com/osdaeg/paste.sh) y envía una notificación a Gotify con el link directo.

## Dependencias

El script forma parte de un ecosistema de microservicios self-hosted corriendo en Docker:

| Servicio | Puerto | Descripción |
|---|---|---|
| [Gotify](https://gotify.net/) | 8088 | Notificaciones push |
| [ClamAV REST API](https://github.com/benzino77/clamav-rest-api) | 3311 | Escaneo antivirus |
| [Transferr](https://github.com/osdaeg/transferr) | 7900 | Enrutamiento de archivos |
| [Butler-API](https://github.com/osdaeg/butler) | 7999 | Generación de fichas con Gemini |
| [paste.sh](https://github.com/osdaeg/paste.sh) | 8090 | Pastebin self-hosted para logs de error |

## Instalación

1. Copiar ambos archivos al volumen de configuración de Shelfmark:

```bash
cp shelfmark.sh /config/shelfmark.sh
cp shelfmark.env /config/shelfmark.env
chmod +x /config/shelfmark.sh
```

2. Editar `/config/shelfmark.env` con los valores de tu entorno:

```env
LOG_FILE="/config/finished.log"
GOTIFY_TOKEN="tu_token_aqui"
GOTIFY_URL="http://TU_HOST:8088/message"
CLAMAV_URL="http://TU_HOST:3311/api/v1/scan"
TRANSFER_URL="http://TU_HOST:7900/transfer"
BUTLER_URL="http://TU_HOST:7999/process"
PASTEBIN_URL="http://TU_HOST:8090"

TRANSFER_DESTINATION="booklore"

PASTEBIN="yes"
NOTIFICATIONS="yes"
SCAN="yes"
CARDS="yes"
TRANSFER="yes"
```

3. Configurar Shelfmark para que invoque el script al finalizar cada descarga, pasando la ruta completa del archivo como `$1`.

## Configuración

Todos los parámetros se definen en `shelfmark.env`. Los flags permiten habilitar o deshabilitar cada paso del pipeline de forma independiente:

| Variable | Valores | Descripción |
|---|---|---|
| `NOTIFICATIONS` | `yes` / `no` | Enviar notificaciones a Gotify |
| `SCAN` | `yes` / `no` | Escanear con ClamAV |
| `TRANSFER` | `yes` / `no` | Transferir a Booklore |
| `CARDS` | `yes` / `no` | Generar ficha con Butler-API |
| `PASTEBIN` | `yes` / `no` | Subir logs de error a paste.sh |

## Manejo de errores

Cuando `PASTEBIN=yes`, el script instala un trap global que captura cualquier error inesperado. Ante un fallo, sube automáticamente las últimas 100 líneas del log a paste.sh (con TTL de 7 días) y envía a Gotify una notificación con el link directo al log.

## Notas técnicas

- No requiere `jq`. El parseo de JSON se realiza con `grep`, `cut` y `tr`.
- Todas las rutas de archivo en llamadas `curl` usan comillas dobles escapadas (`-F "file=@\"${filepath}\""`) para soportar espacios, comas, corchetes y paréntesis — frecuentes en nombres de libros.
- La respuesta de ClamAV devuelve `result` como array; el script accede al primer elemento con `head -1`.
- Si `SCAN=no`, el archivo se considera limpio directamente y el pipeline continúa.

## Ejemplo de log

```
============================================================
[2026-02-25 02:21:44] Nueva descarga recibida
============================================================

[PASO 1] Notificación de descarga
[INFO] Archivo : /books/H.P. Lovecraft - Necronomicon (2008).epub
[INFO] Tamaño  : 1.87 MB
[Gotify] Notificación enviada: 📥 Shelfmark - Descarga completada

[PASO 2] Escaneo antivirus
[ClamAV] Escaneando: H.P. Lovecraft - Necronomicon (2008).epub
[ClamAV] ✅ Limpio: H.P. Lovecraft - Necronomicon (2008).epub
[Gotify] Notificación enviada: 🛡️ Shelfmark - Escaneo completado

[PASO 3] Transferencia de archivos
[Transfer] Enviando: H.P. Lovecraft - Necronomicon (2008).epub → destino: booklore

[PASO 4] Generación de ficha (Butler-API)
[Butler] ✅ Ficha generada: H.P. Lovecraft - Necronomicon (2008)

[2026-02-25 02:22:49] Script finalizado.
============================================================
```

## Licencia

GPL V3
