FROM node:20-alpine

# Mongo credentials are NOT baked into the image any more.
# They are injected at runtime (docker compose reads them from /opt/app/.env on the VM).

WORKDIR /home/app

# install deps first so this layer is cached between builds
COPY app/package.json app/package-lock.json ./
RUN npm ci --omit=dev

COPY app/ ./

ENV NODE_ENV=production
EXPOSE 3000
USER node

CMD ["node", "server.js"]
