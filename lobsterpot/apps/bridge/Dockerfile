FROM node:22-slim AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-workspace.yaml tsconfig.base.json ./
COPY apps/bridge/package.json apps/bridge/package.json
COPY packages/protocol/package.json packages/protocol/package.json
COPY packages/shared/package.json packages/shared/package.json
RUN pnpm install --frozen-lockfile=false

FROM deps AS build
COPY packages packages
COPY apps/bridge apps/bridge
RUN pnpm --filter @lobsterpot/protocol build && \
    pnpm --filter @lobsterpot/shared build && \
    pnpm --filter @lobsterpot/bridge build

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
RUN corepack enable
COPY --from=build /app/package.json /app/pnpm-workspace.yaml ./
COPY --from=build /app/node_modules node_modules
COPY --from=build /app/packages packages
COPY --from=build /app/apps/bridge apps/bridge
EXPOSE 3000
CMD ["node", "apps/bridge/dist/index.js"]
