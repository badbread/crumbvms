# docs.crumbvms.com — multi-stage build: Docusaurus static build, served by nginx.
# Mirrors the crumbvms.com marketing site's pattern (node:22-alpine build ->
# nginx:alpine serve, port 3000).
#
# BUILD CONTEXT: run this build from a directory laid out as:
#   .                    <- this Dockerfile, docker-compose.yml, nginx.conf
#   ./docs-site/         <- a full copy of the repo's docs-site/ directory
#   ./docs/              <- a copy of the repo's docs/ directory (source
#                           for the Architecture section whitelist)
#   ./scripts/sync-arch-docs.mjs  <- copy of the repo's sync script
#
# i.e. NOT docs-site/ alone as the context — scripts/sync-arch-docs.mjs
# resolves docs/ and docs-site/docs/architecture/ as siblings of itself
# (repo-root-relative), so this build stage reproduces that same repo-root
# layout before running it, exactly like CI and local dev do.
# See docs-site/README.md and the repo's deploy runbook for the exact
# tar/rsync command that produces this layout on the deploy host.

FROM node:22-alpine AS build
WORKDIR /repo

COPY docs/ ./docs/
COPY scripts/sync-arch-docs.mjs ./scripts/sync-arch-docs.mjs
COPY docs-site/package.json docs-site/package-lock.json ./docs-site/
RUN npm --prefix docs-site ci

COPY docs-site/ ./docs-site/
RUN node scripts/sync-arch-docs.mjs
RUN npm --prefix docs-site run build

# stage 2: nginx serves the built output
FROM nginx:alpine
COPY --from=build /repo/docs-site/build/ /usr/share/nginx/html/
COPY docs-site/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 3000
