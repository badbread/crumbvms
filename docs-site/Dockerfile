# docs.crumbvms.com — multi-stage build: Docusaurus static build, served by nginx.
# Mirrors the crumbvms.com marketing site's pattern (node:22-alpine build ->
# nginx:alpine serve, port 3000).
#
# BUILD CONTEXT: run this build from a directory laid out as:
#   .                    <- this Dockerfile, docker-compose.yml, nginx.conf
#   ./docs-site/         <- a full copy of the repo's docs-site/ directory
#   ./docs/              <- a copy of the repo's docs/ directory (source
#                           for the Architecture section whitelist)
#   ./data/              <- a copy of the repo's data/ directory (source
#                           for the Camera Compatibility page)
#   ./scripts/sync-arch-docs.mjs     <- copy of the repo's arch sync script
#   ./scripts/gen-camera-compat.mjs  <- copy of the repo's compat generator
#
# i.e. NOT docs-site/ alone as the context — the generator scripts resolve
# docs/, data/, and docs-site/docs/ as siblings of themselves
# (repo-root-relative), so this build stage reproduces that same repo-root
# layout before running them, exactly like CI and local dev do.
# See docs-site/README.md and the repo's deploy runbook for the exact
# tar/rsync command that produces this layout on the deploy host.

FROM node:22-alpine AS build
WORKDIR /repo

COPY docs/ ./docs/
COPY data/ ./data/
COPY scripts/sync-arch-docs.mjs ./scripts/sync-arch-docs.mjs
COPY scripts/gen-camera-compat.mjs ./scripts/gen-camera-compat.mjs
COPY docs-site/package.json docs-site/package-lock.json ./docs-site/
RUN npm --prefix docs-site ci

COPY docs-site/ ./docs-site/
RUN node scripts/sync-arch-docs.mjs
RUN node scripts/gen-camera-compat.mjs
RUN npm --prefix docs-site run build

# stage 2: nginx serves the built output
FROM nginx:alpine
COPY --from=build /repo/docs-site/build/ /usr/share/nginx/html/
COPY docs-site/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 3000
