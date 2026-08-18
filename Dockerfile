# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# Image Traefik du proxy mutualisé.
#
# Modèle aYaline : la configuration vit DANS l'image, et le build la valide.
# Le stage `verify` démarre le vrai binaire traefik sur la vraie conf ; le stage
# final récupère cette conf via COPY --from, ce qui rend la validation
# obligatoire (buildkit ne peut pas l'élaguer). Conf cassée = image jamais
# poussée = jamais déployable.
#
# Le tag de l'image EST la version de Traefik : le .env du serveur
# (TRAEFIK_VERSION) continue donc de piloter la version déployée.
#
# Build : docker build --build-arg TRAEFIK_VERSION=v3.7.10 \
#           -t ghcr.io/armand-cloug/traefik-mutualized/traefik:v3.7.10 .
# ─────────────────────────────────────────────────────────────────────────────
ARG TRAEFIK_VERSION=v3.7.10

FROM traefik:${TRAEFIK_VERSION} AS verify
COPY traefik/dynamic/ /etc/traefik/dynamic/
COPY .github/scripts/verify_dynamic_conf.sh /verify_dynamic_conf.sh
RUN sh /verify_dynamic_conf.sh /etc/traefik/dynamic

FROM traefik:${TRAEFIK_VERSION}
LABEL org.opencontainers.image.source="https://github.com/Armand-Cloug/traefik-mutualized"
LABEL org.opencontainers.image.description="Traefik mutualisé — conf dynamique embarquée et validée au build"
LABEL org.opencontainers.image.licenses="MIT"

# Uniquement la conf validée par le stage précédent. Le fichier d'auth du
# dashboard n'est PAS ici : il est bind-monté depuis la VM.
COPY --from=verify /etc/traefik/dynamic /etc/traefik/dynamic
