#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Prépare l'agent SSH du runner CI — port GitHub Actions de init_deploy.sh
# (docker-ci-builder / aYaline).
#
# Entrées (env) :
#   SSH_DEPLOY_PRIVATE_KEY  clé privée de déploiement (secret d'environnement)
#   DEPLOY_HOST             hôte cible, pour la vérification known_hosts
#   SSH_KEY_SECRET_NAME     nom du secret GitHub, pour un message d'erreur utile
# ─────────────────────────────────────────────────────────────────────────────
set -e

if [ -z "$SSH_DEPLOY_PRIVATE_KEY" ]; then
  echo "::error::Clé SSH vide. Le secret '${SSH_KEY_SECRET_NAME:-SSH_DEPLOY_PRIVATE_KEY}' est introuvable ou vide dans l'environnement GitHub ciblé par le job."
  exit 1
fi

mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Normalise les CRLF : une clé collée depuis Windows casse ssh-add sans message clair.
printf '%s\n' "$SSH_DEPLOY_PRIVATE_KEY" | sed 's/\r$//' > ~/.ssh/id_deploy
chmod 600 ~/.ssh/id_deploy

# Échoue tôt et lisiblement si la clé est tronquée ou mal formée.
ssh-keygen -y -f ~/.ssh/id_deploy > /dev/null

eval "$(ssh-agent -s)" > /dev/null
ssh-add ~/.ssh/id_deploy

# known_hosts versionné (.github/known_hosts) => host strict checking.
# Absent => fallback accept-new au premier contact, avec avertissement MITM.
KNOWN_HOSTS_FILE=".github/known_hosts"
if [ -f "$KNOWN_HOSTS_FILE" ] && ssh-keygen -F "$DEPLOY_HOST" -f "$KNOWN_HOSTS_FILE" > /dev/null 2>&1; then
  cat "$KNOWN_HOSTS_FILE" >> ~/.ssh/known_hosts
  printf 'Host *\n\tStrictHostKeyChecking yes\n' > ~/.ssh/config
  echo "[SSH] $DEPLOY_HOST trouvé dans $KNOWN_HOSTS_FILE — strict host checking actif."
else
  echo "::warning::$DEPLOY_HOST absent de $KNOWN_HOSTS_FILE — première connexion acceptée sans vérification (exposition MITM)."
  echo "::warning::Corrige avec : ssh-keyscan -H $DEPLOY_HOST >> .github/known_hosts (puis vérifie les empreintes contre /etc/ssh/*.pub sur la VM)."
  printf 'Host *\n\tStrictHostKeyChecking accept-new\n' > ~/.ssh/config
fi

printf '\tConnectTimeout 30\n\tServerAliveInterval 15\n' >> ~/.ssh/config
chmod 600 ~/.ssh/config

# Exporte l'agent pour les steps suivants du job.
if [ -n "$GITHUB_ENV" ]; then
  {
    echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK"
    echo "SSH_AGENT_PID=$SSH_AGENT_PID"
  } >> "$GITHUB_ENV"
fi
