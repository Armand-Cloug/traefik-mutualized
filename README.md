# Mutualized Traefik Docker

Projet de Traefik mutualisé pour héberger plusieurs projets Docker sur une même VM.

## Objectif

- Déployer un seul Traefik global par serveur.
- Exposer automatiquement les projets Docker via des labels Traefik.
- Utiliser un réseau Docker partagé `traefik_proxy`.
- Garder une configuration simple côté projet avec un fichier `docker-compose-traefik.yml`.
- Déployer Traefik via GitHub Actions sur `allitu.cloug.fr` ou `utilla.cloug.fr`.

## Structure

```text
.
├── .github/workflows/
│   ├── deploy-traefik-allitu.yml
│   └── deploy-traefik-utilla.yml
├── docker-compose.yml
├── .env.example
├── traefik/
│   └── dynamic/
│       └── middlewares.yml
├── templates/
│   └── docker-compose-traefik.yml
├── examples/
│   └── docker-compose-traefik-nextjs.yml
├── README.md
└── LICENSE
```

## Secrets GitHub nécessaires

Dans `Settings > Secrets and variables > Actions` :

| Nom | Type | Description |
|---|---|---|
| `SERVER_USER` | Secret | Utilisateur SSH sur les serveurs |
| `ALLITU_SSH_KEY` | Secret | Clé privée SSH pour `allitu.cloug.fr` |
| `UTILLA_SSH_KEY` | Secret | Clé privée SSH pour `utilla.cloug.fr` |

Les hosts sont directement définis dans les workflows :

- `allitu.cloug.fr`
- `utilla.cloug.fr`

## Déploiement

Depuis GitHub Actions :

1. Aller dans l'onglet `Actions`.
2. Choisir :
   - `Deploy Traefik — allitu.cloug.fr`
   - ou `Deploy Traefik — utilla.cloug.fr`
3. Cliquer sur `Run workflow`.
4. Saisir exactement :

```text
deploy-traefik
```

Le pipeline va :

- se connecter au serveur en SSH ;
- créer `/opt/traefik` ;
- préserver `traefik/acme.json` s'il existe déjà ;
- envoyer les fichiers du dépôt ;
- installer Docker si nécessaire ;
- créer le réseau `traefik_proxy` ;
- lancer Traefik.

## Configuration Traefik globale

Le fichier principal est :

```text
docker-compose.yml
```

Il expose :

- HTTP : port `80`
- HTTPS : port `443`
- dashboard Traefik sur :
  - `traefik.allitu.cloug.fr`
  - `traefik.utilla.cloug.fr`

Selon le serveur ciblé.

## Sécuriser le dashboard

Le dashboard utilise un middleware `basicAuth` dans :

```text
traefik/dynamic/middlewares.yml
```

Générer un hash :

```bash
sudo apt install apache2-utils -y
htpasswd -nbB admin 'mot-de-passe-fort'
```

Puis remplacer la ligne :

```yaml
- "admin:$$2y$$05$$CHANGE_ME_CHANGE_ME_CHANGE_ME_CHANGE_ME_CHANGE_ME"
```

Attention : dans un fichier YAML Docker/Traefik, les `$` doivent être doublés en `$$`.

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
