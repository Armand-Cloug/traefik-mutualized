#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Vérifie que le compose déployé porte les directives obligatoires — port du
# check_docker_compose.sh de docker-ci-builder (aYaline), plus deux garde-fous
# propres à ce dépôt (conf dynamique dans l'image, jamais rsyncée).
#
# Usage : check_docker_compose.sh docker-compose.yml [autre-compose.yml ...]
# ─────────────────────────────────────────────────────────────────────────────
set -e
exitFail=0

if [ $# -eq 0 ]; then
  set -- docker-compose.yml
fi

for i in "$@"; do
  case "$i" in
    -*) continue ;;
  esac

  if [ ! -e "$i" ]; then
    echo "::error::Fichier compose introuvable : $i"
    exitFail=1
    continue
  fi

  for directive in cap_drop logging max-size max-file restart cpus memory; do
    if ! grep -q "$directive" "$i"; then
      echo "::error::$i ne contient pas la directive obligatoire '$directive'."
      exitFail=1
    fi
  done

  # Traefik écoute sur :80 et :443. Le démon Docker met par défaut
  # net.ipv4.ip_unprivileged_port_start=0 dans les conteneurs, donc le bind
  # passe même sans capability — mais ce n'est PAS garanti (démon configuré
  # autrement, rootless, durcissement). NET_BIND_SERVICE doit être déclaré
  # explicitement pour que le compose reste portable.
  if grep -q 'cap_drop' "$i" && ! grep -q 'NET_BIND_SERVICE' "$i"; then
    echo "::error::$i drop toutes les capabilities sans déclarer NET_BIND_SERVICE. Le bind de :80 / :443 dépendrait alors du sysctl ip_unprivileged_port_start du démon."
    exitFail=1
  fi

  # Une image buildée sur la cible = build sur le serveur de prod : interdit.
  if grep -qE '^\s*build:' "$i"; then
    echo "::error::$i contient une directive 'build:'. Les images doivent venir de la registry, jamais être buildées sur la VM."
    exitFail=1
  fi

  # Garde-fou : le .env serveur ne doit jamais être monté depuis le dépôt.
  if grep -qE '^\s*-\s*\./\.env' "$i"; then
    echo "::error::$i monte un .env depuis le dépôt. Le .env est géré à la main sur la VM."
    exitFail=1
  fi

  # La conf dynamique NON secrète vit dans l'image (validée au build). La monter
  # depuis la VM rouvrirait la porte à une conf cassée déployable à chaud.
  if grep -qE '^\s*-\s*\./traefik/dynamic' "$i"; then
    echo "::error::$i monte ./traefik/dynamic depuis la VM. Cette conf est embarquée dans l'image GHCR et validée au build."
    exitFail=1
  fi
done

if [ "$exitFail" -eq 1 ]; then
  echo "Compose invalide — corrige les points ci-dessus."
  exit 1
fi

echo "[OK] Directives obligatoires présentes dans : $*"
