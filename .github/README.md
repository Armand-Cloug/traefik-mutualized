# CI/CD — Traefik mutualisé

Pipelines GitHub Actions calqués sur la méthode aYaline (`docker-ci-builder` /
`remote_deploy_v2`, dont leur proxy mutualisé `aya-proxy`) : **l'image est
buildée hors des serveurs, poussée sur GHCR, puis seulement tirée par la VM.**
Aucun build sur la VM, aucun `scp` du dépôt, aucun secret applicatif dans la CI.

## Workflows

| Fichier | Rôle | Déclenchement |
|---|---|---|
| `build.yml` | Valide le compose, builde l'image (conf dynamique validée dedans), push GHCR | Manuel |
| `deploy-allitu.yml` | Déploie sur `allitu.cloug.fr` | Manuel |
| `deploy-utilla.yml` | Déploie sur `utilla.cloug.fr` | Manuel |
| `deploy-bde-prod.yml` | Déploie sur `bde-ensar.fr`, confirmation `deploy-prod` | Manuel |
| `_deploy.yml` | Workflow réutilisable appelé par les trois wrappers | `workflow_call` |

Rien ne se déclenche sur `push` : c'est le déclenchement manuel qui décide de
ce qui part en ligne.

**Ajouter une VM** = copier un wrapper (~25 lignes), changer `secret_suffix` et
`deploy_host`, ajouter la clé SSH dans l'environnement et la ligne
`known_hosts`.

## Image

```
ghcr.io/armand-cloug/traefik-mutualized/traefik
```

Le **tag EST la version de Traefik** (`v3.7.10`), pour que `TRAEFIK_VERSION`
dans le `.env` de chaque serveur continue de piloter la version déployée.
Chaque build pousse deux tags :

| Tag | Usage |
|---|---|
| `v3.7.10` | tag courant de la version — écrasé à chaque rebuild de cette version |
| `v3.7.10-<run_number>` | immuable — à utiliser pour épingler une conf précise et pour les rollbacks |

L'image contient uniquement `traefik:<version>` officiel + la conf dynamique
**non secrète** (`traefik/dynamic/`) dans `/etc/traefik/dynamic`.

### Validation de la conf au build (équivalent du `nginx -t` d'aYaline)

Traefik n'a pas de sous-commande de validation. Le stage `verify` du
`Dockerfile` fait donc tourner **le vrai binaire** sur la vraie conf pendant le
build (`.github/scripts/verify_dynamic_conf.sh`) et vérifie :

1. aucun log `level: error` / `fatal` ;
2. une ligne `Configuration received` avec `providerName: file` ;
3. les clés attendues (`middlewares`, `security-headers`) présentes dans la conf
   effectivement chargée.

Le stage final récupère la conf par `COPY --from=verify`, ce qui rend la
validation non contournable (buildkit ne peut pas élaguer le stage).
**Conf cassée = image jamais poussée = jamais déployable.**

## Prérequis

### 1. Environnement GitHub (une seule fois)

Un **seul** environnement, `vms` (Settings → Environments), porte toutes les
clés — nommées par serveur :

| Type | Nom | Contenu |
|---|---|---|
| Secret | `SSH_DEPLOY_KEY_ALLITU` | clé privée SSH de `deploy@allitu.cloug.fr` |
| Secret | `SSH_DEPLOY_KEY_UTILLA` | clé privée SSH de `deploy@utilla.cloug.fr` |
| Secret | `SSH_DEPLOY_KEY_BDE_PROD` | clé privée SSH de `deploy@bde-ensar.fr` |
| Variable | `TRAEFIK_ACME_EMAIL` | e-mail du compte Let's Encrypt (partagé) |

C'est **tout** ce qui vit dans GitHub — et ce sont les seuls secrets du projet,
tous liés à l'accès aux machines. Le proxy lui-même n'a aucun secret : pas de
dashboard, pas d'UI, rien d'exposé, comme `aya-proxy` chez aYaline. Hôtes,
users SSH, chemins `/opt` et namespace registry sont en dur dans les workflows.

Surcharge possible par VM : une variable `TRAEFIK_ACME_EMAIL_<SUFFIX>`
(ex. `TRAEFIK_ACME_EMAIL_BDE_PROD`) prend le pas sur la variable partagée.

> Les secrets d'environnement ne sont résolus que par un job qui porte
> `environment:`. C'est `_deploy.yml` qui le déclare ; les wrappers appellent
> avec `secrets: inherit` et **aucun** bloc `secrets:` n'est déclaré. La clé est
> ensuite choisie dynamiquement : `secrets[format('SSH_DEPLOY_KEY_{0}', suffix)]`.

Une *required reviewer rule* sur l'environnement `vms` ajoute une double
validation sur tous les déploiements.

### 2. Packages GHCR privés

Le package reste **privé** : rien à faire après le premier `build.yml`.

Le pull authentifié fonctionne sans credential permanent sur la VM. Le job de
déploiement pousse un `docker login ghcr.io` avec le `GITHUB_TOKEN` du run
(permission `packages: read`) via stdin, et un `trap EXIT INT TERM` déloge la VM
même si le déploiement échoue — mécanisme de `remote_deploy_v2.sh` chez aYaline
avec `CI_JOB_TOKEN`. Le token expire avec le job.

Vérifier une fois que le package est bien lié au dépôt (**Package settings →
Manage Actions access** : `traefik-mutualized` en rôle `Write`).

### 3. `known_hosts`

`.github/known_hosts` est versionné et contient déjà les trois VMs. Sans entrée
pour un hôte, la CI se connecte en `accept-new` avec un avertissement MITM.

```bash
ssh-keyscan -H nouvelle-vm.exemple.fr >> .github/known_hosts
# puis vérifier les empreintes sur la VM :
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Les empreintes ED25519 relevées sont en commentaire en tête du fichier — **à
confirmer une fois sur chaque VM.**

### 4. Sur chaque VM (une seule fois)

Le user `deploy` n'a **pas** sudo ; il est membre du groupe `docker`.

```bash
# en root
sudo mkdir -p /opt/traefik
sudo chown -R deploy: /opt/traefik
sudo usermod -aG docker deploy
# clé publique de déploiement dans ~deploy/.ssh/authorized_keys

# réseau partagé (le script de déploiement le crée aussi s'il manque)
docker network create traefik_proxy 2>/dev/null || true
```

Le reste est géré par le déploiement : `.env` créé depuis `.env.dist`,
`traefik/logs/` et `traefik/acme.json` (mode 600) créés s'ils manquent.
**Rien d'autre n'est à créer à la main sur la VM.**

## Utilisation

1. **Build** — Actions → *🏗️ Build & push image* → `traefik_version = v3.7.10`
   → Run. Le récapitulatif affiche les deux tags poussés.
2. **Deploy** — Actions → *🚀 Deploy — allitu / utilla / bde-prod* → Run.
   - `traefik_version` **vide** ⇒ la version reste celle du `.env` de la VM
     (la CI ne touche pas à `TRAEFIK_VERSION`) ;
   - `traefik_version` rempli ⇒ la CI vérifie que le tag existe sur GHCR, puis
     l'écrit dans le `.env` de la VM.
3. **bde-prod** exige en plus `confirm = deploy-prod`.

Le job termine par un smoke test HTTP sur `http://<hôte>/` : un `301` prouve que
Traefik écoute sur `:80` et applique la redirection HTTPS, sans dépendre d'une
stack projet.

### Diagnostic

Pas de dashboard : tout passe par la VM.

```bash
cd /opt/traefik
docker compose logs -f traefik
docker compose exec traefik traefik healthcheck --ping
tail -f traefik/logs/access.log
```

Passer `TRAEFIK_LOG_LEVEL=DEBUG` dans le `.env` puis
`docker compose up -d --force-recreate traefik` pour tracer le routage.

### Ce que la CI envoie sur la VM

Uniquement `docker-compose.yml` et `.env.dist` (rsync avec `--exclude='*'`).
Le déploiement lui-même est un script généré par `scripts/remote_deploy.sh` et
exécuté via `ssh 'sh -s'` :

```
.env (créé si absent) → set_env TRAEFIK_ACME_EMAIL
→ acme.json + logs garantis → réseau traefik_proxy
→ login GHCR → pull → up -d --force-recreate
→ conteneur running ? → traefik healthcheck --ping → resolver ACME chargé ?
```

Le script échoue, en dumpant les logs, si le conteneur ne tourne pas, s'il ne
répond pas à son propre `/ping`, ou si le resolver Let's Encrypt a été
abandonné : un `up` qui rend la main ne prouve pas que Traefik a démarré, et un
Traefik `healthy` ne prouve pas qu'il émettra des certificats.

Le répertoire de déploiement n'est **jamais** supprimé. `traefik/acme.json`
(compte Let's Encrypt + certificats) et `traefik/logs/` sont de l'état serveur et survivent à tous les déploiements — l'ancienne gymnastique
de sauvegarde/restauration d'`acme.json` en `/tmp` a disparu avec le `rm -rf`.

### Rollback

Relancer le workflow de déploiement avec un tag antérieur, par exemple
`traefik_version = v3.7.10-41` (ou une version plus ancienne, `v3.6.25`, si
elle a déjà été buildée). Aucun rebuild : l'image est déjà sur GHCR.

Comme la version vit dans le `.env` de la VM, un rollback à chaud est aussi
possible directement sur le serveur :

```bash
cd /opt/traefik && sed -i 's|^TRAEFIK_VERSION=.*|TRAEFIK_VERSION=v3.7.10-41|' .env
docker compose up -d --force-recreate traefik
```

### Prune d'images

L'input `prune_dangling_images` lance `docker image prune -f` (**dangling
uniquement**) avant le pull. `docker image prune -a` n'est **jamais** utilisé :
les VMs hébergent d'autres stacks sur le réseau partagé `traefik_proxy`, dont
les images non démarrées seraient supprimées.

## Scripts

| Script | Origine aYaline |
|---|---|
| `scripts/init_ssh.sh` | `init_deploy.sh` + `check_host.sh` |
| `scripts/check_docker_compose.sh` | `check_docker_compose.sh` (directives obligatoires) |
| `scripts/remote_deploy.sh` | `remote_deploy_v2.sh` |
| `scripts/verify_dynamic_conf.sh` | équivalent du `nginx -t` du build nginx |

`check_docker_compose.sh` impose `cap_drop`, `logging` (`max-size` / `max-file`),
`restart`, `cpus`, `memory`, et refuse : une directive `build:`, un montage de
`.env` depuis le dépôt, un montage de `./traefik/dynamic` depuis la VM, et un
`cap_drop` sans `NET_BIND_SERVICE`.

### Capabilities du conteneur

`cap_drop: [ALL]` + `cap_add: [NET_BIND_SERVICE, DAC_OVERRIDE]`.

`DAC_OVERRIDE` n'est pas cosmétique : le conteneur tourne en root (uid 0) alors
que `acme.json` et `traefik/logs/` appartiennent au user `deploy` de la VM. Sans
cette capability, root ne contourne plus les bits de permission, Traefik ne peut
pas ouvrir `/acme.json` et **abandonne silencieusement le resolver Let's
Encrypt** — le conteneur reste `healthy` et répond en HTTP, mais aucun
certificat n'est jamais émis. `deploy` n'a pas sudo (donc pas de `chown` vers
root) et relâcher les permissions d'`acme.json`, qui contient des clés privées,
n'est pas une option.

Le script de déploiement échoue explicitement s'il trouve
`ACME resolve is skipped` dans les logs après le démarrage.

## Pourquoi pas de dashboard

Le proxy mutualisé d'aYaline (`aya-proxy` : nginx + modsecurity, crowdsec,
fail2ban, certbot) n'expose aucune interface d'administration. Le dashboard
Traefik listerait publiquement tous les routers, services, conteneurs internes,
ports backend et domaines de chaque projet de la VM — pour un usage que les logs
et `traefik healthcheck` couvrent. Il a donc été retiré, avec le secret
d'authentification qui allait avec.
