# Udha relay — self-hostable WebSocket relay.
#
#   docker build -t udha-relay .
#   docker run --rm -p 8080:8080 --env-file .env -v udha-relay-data:/data udha-relay
#
# Or just `docker compose up -d`, which does both plus restart-on-boot.

FROM node:22-alpine

# Tini reaps the zombie children a PID-1 Node process would otherwise leave,
# and forwards SIGTERM so the graceful shutdown path actually runs.
RUN apk add --no-cache tini wget

WORKDIR /app

# Dependencies first, so a source-only change does not re-resolve the tree.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./
COPY tests ./tests

# Paired-instance state lives here. Mount it (compose does) or pairings are
# forgotten on every `docker compose up --force-recreate`.
ENV DATA_DIR=/data
RUN mkdir -p /data && chown -R node:node /data /app

# Never run the relay as root: it is the one process in this system that is
# deliberately reachable from the open internet.
USER node

ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

# The health route answers even when Auth0 is unreachable — "up but cannot
# verify tokens" is a state you want to be able to see.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/health" >/dev/null || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
