#!/usr/bin/env bash
# Despliega el relé en Cloud Run. Uso: ./desplegar.sh [region]   (por defecto europe-southwest1, Madrid)
# Usa el proyecto activo de gcloud (gcloud config get-value project).
set -euo pipefail
cd "$(dirname "$0")"
REGION="${1:-europe-southwest1}"
SERVICIO="casa-rele"

# --max-instances=1: las salas viven en memoria, los dos jugadores tienen que caer en la misma.
# --timeout=3600: lo máximo que Cloud Run deja abierto un WebSocket (el juego reconecta si se corta).
# --min-instances=0: sin nadie jugando no cuesta nada (la primera conexión tarda un par de segundos).
gcloud run deploy "$SERVICIO" \
  --source . \
  --region "$REGION" \
  --allow-unauthenticated \
  --max-instances=1 --min-instances=0 \
  --concurrency=500 \
  --timeout=3600 \
  --cpu=1 --memory=256Mi \
  --session-affinity

URL="$(gcloud run services describe "$SERVICIO" --region "$REGION" --format='value(status.url)')"
echo
echo "Relé desplegado. Pon esto en online.cfg, sección [multijugador]:"
echo "servidor=\"${URL/https:/wss:}\""
