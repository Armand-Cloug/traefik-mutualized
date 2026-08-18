#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Génère sur stdout le script shell exécuté sur la VM cible — port de
# remote_deploy_v2.sh (docker-ci-builder / aYaline).
#
# Usage :  remote_deploy.sh | ssh user@host 'sh -s'
#
# Entrées (env) :
#   DEPLOY_PATH          répertoire de déploiement sur la VM      (obligatoire)
#   TRAEFIK_VERSION      tag d'image à figer dans le .env de la VM ;
#                        VIDE => on ne touche pas au .env, c'est le serveur
#                        qui pilote la version                     (optionnel)
#   DOCKER_USE_SUDO      1 => préfixe sudo aux commandes docker    (défaut 0)
#   DOCKER_SERVICES      services à recréer                        (défaut traefik)
#   PRUNE_DANGLING       1 => docker image prune -f avant le pull  (défaut 0)
#   REGISTRY             registry pour le login distant            (défaut ghcr.io)
#   REGISTRY_USER        utilisateur du login distant              (optionnel)
#   REGISTRY_TOKEN       token du login distant                    (optionnel)
#
# Si REGISTRY_TOKEN est fourni, la VM se logue à la registry le temps du pull
# puis se délogue via un trap EXIT : aucun credential ne reste sur le serveur,
# même si le déploiement échoue.
#
# Ce script NE SUPPRIME JAMAIS le répertoire de déploiement : traefik/acme.json
# (compte Let's Encrypt + certificats) et traefik/logs/ sont de l'état
# serveur. Seuls docker-compose.yml et .env.dist sont écrasés, par le rsync.
#
# On n'utilise jamais `docker image prune -a` : les VMs hébergent d'autres
# stacks sur le réseau partagé traefik_proxy, dont les images non démarrées
# seraient supprimées.
# ─────────────────────────────────────────────────────────────────────────────
set -e

die() { echo "[remote_deploy] $1" >&2; exit 1; }

[ -n "$DEPLOY_PATH" ] || die "DEPLOY_PATH vide"

# Ces valeurs sont réinjectées telles quelles dans le script distant : on refuse
# tout ce qui pourrait en sortir (quote, backslash, retour ligne, substitution).
for v in "$DEPLOY_PATH" "$TRAEFIK_VERSION"; do
  case "$v" in
    *[\'\"\\\`\$]*|*"
"*) die "valeur invalide (caractère interdit) : $v" ;;
  esac
done

DOCKER_USE_SUDO=${DOCKER_USE_SUDO:-0}
DOCKER_SERVICES=${DOCKER_SERVICES:-traefik}
PRUNE_DANGLING=${PRUNE_DANGLING:-0}
REGISTRY=${REGISTRY:-ghcr.io}

if [ "$DOCKER_USE_SUDO" -eq 0 ]; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

# ── Préambule : répertoire + .env ────────────────────────────────────────────
cat <<EOF
set -e
cd '$DEPLOY_PATH' || { echo "[ERREUR] $DEPLOY_PATH inaccessible"; exit 1; }

echo "[Deploy] $DEPLOY_PATH sur \$(hostname)"

if [ ! -e .env ]; then
  cp .env.dist .env
  echo "[Deploy] .env absent : créé depuis .env.dist"
fi
EOF

# TRAEFIK_VERSION est la SEULE clé que la CI écrive dans le .env de la VM, et
# seulement quand une version est passée en input. Le reste du fichier est géré
# à la main sur le serveur.
if [ -n "$TRAEFIK_VERSION" ]; then
  # set_env est émis en heredoc *quoté* : son corps ne doit pas être interprété
  # côté runner. La valeur, elle, arrive par l'appel qui suit.
  cat <<'EOF'
set_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
EOF
  cat <<EOF
set_env TRAEFIK_VERSION '$TRAEFIK_VERSION'
echo "[Deploy] version figée par la CI : $TRAEFIK_VERSION"
EOF
else
  cat <<'EOF'
echo "[Deploy] version pilotée par le .env du serveur : $(grep '^TRAEFIK_VERSION=' .env || echo '(défaut du compose)')"
EOF
fi

# ── Le .env est géré À LA MAIN sur la VM : on vérifie qu'il est renseigné ────
# Modèle aYaline : la CI ne connaît aucune valeur applicative. Premier
# déploiement => .env créé depuis .env.dist, on s'arrête avec un message clair,
# l'admin le remplit, on relance.
cat <<'EOF'
ACME_EMAIL="$(grep -E '^TRAEFIK_ACME_EMAIL=' .env | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "$ACME_EMAIL" ]; then
  echo "[ERREUR] TRAEFIK_ACME_EMAIL est vide dans $PWD/.env"
  echo "         Let's Encrypt exige une adresse de contact : sans elle Traefik"
  echo "         ne peut créer aucun compte ACME, donc aucun certificat."
  echo ""
  echo "         Sur cette VM :"
  echo "           sed -i 's|^TRAEFIK_ACME_EMAIL=.*|TRAEFIK_ACME_EMAIL=toi@exemple.fr|' $PWD/.env"
  echo "         puis relance le déploiement."
  exit 1
fi
echo "[Deploy] TRAEFIK_ACME_EMAIL renseigné dans le .env du serveur"
EOF

# ── État persistant : jamais écrasé, jamais rsyncé ───────────────────────────
cat <<'EOF'
mkdir -p traefik/logs

# acme.json porte le compte Let's Encrypt et les certificats émis : on le crée
# s'il manque, on ne le réécrit jamais.
if [ ! -e traefik/acme.json ]; then
  install -m 600 /dev/null traefik/acme.json
  echo "[Deploy] traefik/acme.json créé (vide) — les certificats seront émis au démarrage"
fi
chmod 600 traefik/acme.json
EOF

# ── Réseau partagé ───────────────────────────────────────────────────────────
cat <<EOF
$DOCKER network inspect traefik_proxy >/dev/null 2>&1 || {
  echo "[Deploy] création du réseau partagé traefik_proxy"
  $DOCKER network create traefik_proxy
}
EOF

# ── Nettoyage (dangling uniquement — jamais -a, VMs multi-projets) ───────────
if [ "$PRUNE_DANGLING" -eq 1 ]; then
  cat <<EOF
echo "[Deploy] prune des images dangling"
$DOCKER image prune -f
EOF
fi

# ── Login registry éphémère ──────────────────────────────────────────────────
if [ -n "$REGISTRY_TOKEN" ]; then
  cat <<EOF
echo "[Deploy] login $REGISTRY (éphémère)"
printf '%s' '$REGISTRY_TOKEN' | $DOCKER login -u '$REGISTRY_USER' --password-stdin $REGISTRY
trap '$DOCKER logout $REGISTRY >/dev/null 2>&1 || true' EXIT INT TERM
EOF
fi

# ── Pull + up ────────────────────────────────────────────────────────────────
cat <<EOF
echo "[Deploy] pull de l'image"
$DOCKER compose pull -q $DOCKER_SERVICES

echo "[Deploy] (re)création : $DOCKER_SERVICES"
$DOCKER compose up -d --force-recreate --remove-orphans $DOCKER_SERVICES

$DOCKER compose ps

# Le conteneur doit tourner ET répondre à son propre /ping : un "up" qui rend
# la main ne prouve pas que Traefik a démarré (conf statique invalide, port
# déjà pris...).
if ! $DOCKER compose ps --status running --services | grep -qx traefik; then
  echo "[ERREUR] le conteneur traefik ne tourne pas après le déploiement :"
  $DOCKER compose logs --tail 50 traefik
  exit 1
fi
if ! $DOCKER compose exec -T traefik traefik healthcheck --ping; then
  echo "[ERREUR] Traefik ne répond pas à son healthcheck :"
  $DOCKER compose logs --tail 50 traefik
  exit 1
fi

# Le healthcheck reste vert même si le resolver ACME n'a pas pu charger
# (acme.json illisible => aucun certificat émis, jamais). Mode d'échec
# silencieux : on le rattrape explicitement.
if $DOCKER compose logs --tail 200 traefik 2>&1 | grep -q 'ACME resolve is skipped'; then
  echo "[ERREUR] Le resolver Let's Encrypt n'a pas chargé : aucun certificat ne sera émis."
  $DOCKER compose logs --tail 200 traefik 2>&1 | grep -i acme | tail -5
  echo "         Vérifie les permissions de $DEPLOY_PATH/traefik/acme.json."
  exit 1
fi

echo "[Deploy] terminé"
exit
EOF
