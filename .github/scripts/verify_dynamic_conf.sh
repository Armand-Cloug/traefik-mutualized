#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Équivalent Traefik du `nginx -t` d'aYaline, exécuté PENDANT le build docker.
#
# Traefik n'a pas de sous-commande de validation ("traefik -t" n'existe pas) :
# la seule source de vérité est le binaire lui-même. On le démarre donc quelques
# secondes sur la conf embarquée, en logs JSON, sur un entrypoint en port haut,
# puis on assert sur ce qu'il a effectivement chargé :
#
#   1. aucune ligne "level":"error" / "fatal"
#      (une conf invalide sort : Cannot start the provider *file.Provider
#       error="collecting file configs: ...: field not found, node: ...")
#   2. une ligne "Configuration received" avec "providerName":"file"
#      => le provider file a bien démarré ET livré une conf
#   3. chaque clé de REQUIRED_KEYS présente dans cette conf
#      => le fichier attendu a réellement été parsé, pas juste un répertoire vide
#
# Conf cassée = image jamais poussée, donc jamais déployable.
#
# Usage : verify_dynamic_conf.sh [dir]        (défaut /etc/traefik/dynamic)
# Env   : REQUIRED_KEYS  chaînes attendues dans la conf chargée
#                        (défaut : "middlewares security-headers")
# ─────────────────────────────────────────────────────────────────────────────
set -e

DIR="${1:-/etc/traefik/dynamic}"
REQUIRED_KEYS="${REQUIRED_KEYS:-middlewares security-headers}"
LOG=/tmp/traefik-verify.log

if [ ! -d "$DIR" ]; then
  echo "[ERREUR] Répertoire de conf dynamique introuvable : $DIR"
  exit 1
fi

echo "[verify] conf dynamique embarquée dans $DIR :"
ls -l "$DIR"

traefik \
  --log.level=DEBUG \
  --log.format=json \
  --global.checknewversion=false \
  --global.sendanonymoususage=false \
  --entrypoints.verify.address=:18099 \
  --providers.file.directory="$DIR" \
  --providers.file.watch=false \
  > "$LOG" 2>&1 &
TRAEFIK_PID=$!

# Attente active : on sort dès que le provider file a répondu (succès ou échec),
# plutôt que de dormir un temps fixe.
i=0
while [ "$i" -lt 30 ]; do
  if grep -q '"providerName":"file"' "$LOG" 2>/dev/null; then break; fi
  if grep -q '"level":"error"' "$LOG" 2>/dev/null; then break; fi
  if ! kill -0 "$TRAEFIK_PID" 2>/dev/null; then break; fi
  i=$((i + 1))
  sleep 1
done

kill -INT "$TRAEFIK_PID" 2>/dev/null || true
wait "$TRAEFIK_PID" 2>/dev/null || true

fail=0

if grep -qE '"level":"(error|fatal)"' "$LOG"; then
  echo "[ERREUR] Traefik a rejeté la conf dynamique :"
  grep -E '"level":"(error|fatal)"' "$LOG"
  fail=1
fi

FILE_CONF=$(grep '"providerName":"file"' "$LOG" | head -1 || true)
if [ -z "$FILE_CONF" ]; then
  echo "[ERREUR] Le provider file n'a livré aucune configuration en 30 s."
  echo "         Logs complets :"
  cat "$LOG"
  exit 1
fi

for key in $REQUIRED_KEYS; do
  if ! printf '%s' "$FILE_CONF" | grep -q -- "$key"; then
    echo "[ERREUR] '$key' absent de la conf chargée par le provider file."
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "── conf effectivement chargée ──"
  printf '%s\n' "$FILE_CONF"
  exit 1
fi

echo "[OK] Conf dynamique valide et chargée par Traefik ($REQUIRED_KEYS)."
printf '%s\n' "$FILE_CONF"
