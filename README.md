# Mutualized Traefik Docker

Traefik mutualisé pour héberger plusieurs projets Docker sur une même VM.

## Objectif

- Déployer un seul Traefik global par serveur.
- Exposer automatiquement les projets Docker via des labels Traefik.
- Utiliser un réseau Docker partagé `traefik_proxy`.
- Garder une configuration simple côté projet avec un fichier `docker-compose-traefik.yml`.
- Déployer via GitHub Actions sur `allitu.cloug.fr`, `utilla.cloug.fr` et `bde-ensar.fr`.
- **Aucun secret, aucune interface exposée** : le proxy ne fait que router.

## Principe de déploiement

**L'image est buildée hors des serveurs et poussée sur GHCR ; la VM ne fait que
tirer.** Aucun build sur la VM, aucun `scp` du dépôt : le déploiement ne rsync
que `docker-compose.yml` et `.env.dist`, puis exécute un script généré en CI via
`ssh 'sh -s'` (méthode aYaline `remote_deploy_v2`).

```
ghcr.io/armand-cloug/traefik-mutualized/traefik:<version-traefik>
```

Le tag de l'image **est** la version de Traefik, donc `TRAEFIK_VERSION` dans le
`.env` du serveur pilote la version déployée.

La configuration dynamique (`traefik/dynamic/middlewares.yml`) est embarquée
dans l'image et validée pendant le build en démarrant le vrai binaire Traefik :
une conf cassée n'est jamais poussée, donc jamais déployable.

Ce conteneur n'expose **rien** — pas de dashboard, pas d'API. Comme le proxy
mutualisé `aya-proxy` d'aYaline, il n'a donc aucun secret : il route les autres
stacks via leurs labels, un point c'est tout.

Tout le détail CI/CD est dans **[.github/README.md](.github/README.md)**.

## Structure

```text
.
├── .github/
│   ├── workflows/
│   │   ├── build.yml              # build + push GHCR
│   │   ├── _deploy.yml            # workflow réutilisable (workflow_call)
│   │   ├── deploy-allitu.yml      # wrapper VM
│   │   ├── deploy-utilla.yml      # wrapper VM
│   │   └── deploy-bde-prod.yml    # wrapper VM (confirmation obligatoire)
│   ├── scripts/
│   │   ├── init_ssh.sh
│   │   ├── check_docker_compose.sh
│   │   ├── remote_deploy.sh
│   │   └── verify_dynamic_conf.sh
│   ├── known_hosts
│   └── README.md                  # doc CI/CD complète
├── Dockerfile
├── docker-compose.yml
├── .env.dist                      # modèle du .env serveur
├── .env.example
├── traefik/
│   └── dynamic/
│       └── middlewares.yml        # conf NON secrète, embarquée dans l'image
├── templates/
│   └── docker-compose-traefik.yml
├── README.md
└── LICENSE
```

## Configuration GitHub

Un **seul** environnement GitHub (`vms`) porte tout, les clés étant nommées par
serveur :

| Type | Nom | Description |
|---|---|---|
| Secret | `SSH_DEPLOY_KEY_ALLITU` | clé privée SSH `deploy@allitu.cloug.fr` |
| Secret | `SSH_DEPLOY_KEY_UTILLA` | clé privée SSH `deploy@utilla.cloug.fr` |
| Secret | `SSH_DEPLOY_KEY_BDE_PROD` | clé privée SSH `deploy@bde-ensar.fr` |
| Variable | `TRAEFIK_ACME_EMAIL` | e-mail du compte Let's Encrypt |

Rien d'autre : hôtes, users SSH, chemins `/opt/traefik` et namespace registry
sont en dur dans les workflows. Les clés SSH sont les seuls secrets, et elles ne
concernent que l'accès aux machines — le proxy lui-même n'en a aucun.

| Suffixe | Hôte |
|---|---|
| `ALLITU` | `allitu.cloug.fr` |
| `UTILLA` | `utilla.cloug.fr` |
| `BDE_PROD` | `bde-ensar.fr` |

## Déploiement

Depuis l'onglet **Actions** :

1. **🏗️ Build & push image** — `traefik_version` (défaut `v3.7.10`) → Run.
2. **🚀 Deploy — allitu / utilla / bde-prod** → Run.
   - `traefik_version` vide ⇒ la version reste celle du `.env` de la VM ;
   - `traefik_version` rempli ⇒ figée dans le `.env` de la VM après vérification
     du tag sur GHCR.
   - `bde-prod` demande en plus la confirmation `deploy-prod`.

Le pipeline :

- vérifie le compose (`cap_drop`, `logging`, `restart`, `cpus`, `memory`,
  absence de `build:`) ;
- se connecte en SSH (`known_hosts` versionné, strict host checking) ;
- rsync `docker-compose.yml` + `.env.dist` **et rien d'autre** ;
- garantit `traefik/acme.json` (600), `traefik/logs/` et le réseau
  `traefik_proxy` ;
- se logue à GHCR le temps du pull (logout par `trap`), puis
  `docker compose up -d --force-recreate traefik` ;
- vérifie que le conteneur tourne et répond à `traefik healthcheck --ping` ;
- smoke test HTTP sur `http://<hôte>/` (301 attendu = redirection HTTPS active).

Le répertoire de déploiement n'est **jamais** supprimé : `traefik/acme.json`
(compte Let's Encrypt + certificats) et les logs restent sur la VM.

## Version de Traefik

Défaut actuel : **`v3.7.10`** (dernière stable). Elle se change à deux endroits
indépendants :

- **globalement** : input `traefik_version` du workflow de build, puis du
  déploiement ;
- **par serveur** : `TRAEFIK_VERSION` dans `/opt/traefik/.env`.

Toute version doit avoir été buildée et poussée sur GHCR au préalable.

## Diagnostic

Il n'y a pas de dashboard : le proxy n'expose aucune interface. Tout se fait
depuis la VM.

```bash
cd /opt/traefik
docker compose logs -f traefik                          # routage, ACME, erreurs
docker compose exec traefik traefik healthcheck --ping  # sonde interne
tail -f traefik/logs/access.log                          # requêtes
```

Pour tracer un problème de routage, passer `TRAEFIK_LOG_LEVEL=DEBUG` dans
`/opt/traefik/.env` puis `docker compose up -d --force-recreate traefik`.

## Utilisation dans un projet Docker

Dans un projet, ajouter un fichier :

```text
docker-compose-traefik.yml
```

Exemple :

```yaml
services:
  web:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.monapp.rule=Host(`app.example.com`)"
      - "traefik.http.routers.monapp.entrypoints=websecure"
      - "traefik.http.routers.monapp.tls=true"
      - "traefik.http.routers.monapp.tls.certresolver=letsencrypt"
      - "traefik.http.routers.monapp.middlewares=security-headers@file"
      - "traefik.http.services.monapp.loadbalancer.server.port=3000"
      - "traefik.docker.network=traefik_proxy"
    networks:
      - traefik_proxy

networks:
  traefik_proxy:
    external: true
    name: traefik_proxy
```

Puis lancer :

```bash
docker compose -f docker-compose.yml -f docker-compose-traefik.yml up -d
```

## Règle importante

Traefik ne lit pas directement les fichiers `docker-compose-traefik.yml` des projets.

Le fonctionnement réel est :

1. Docker Compose démarre le projet avec ses labels.
2. Traefik lit les labels via le socket Docker.
3. Traefik crée automatiquement les routers, services et certificats.

## Licence

MIT.
