FROM node:22-slim AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-workspace.yaml tsconfig.base.json ./
COPY apps/push-relay/package.json apps/push-relay/package.json
COPY packages/shared/package.json packages/shared/package.json
RUN pnpm install --frozen-lockfile=false

FROM deps AS build
COPY packages/shared packages/shared
COPY apps/push-relay apps/push-relay
RUN pnpm --filter @lobsterpot/shared build && pnpm --filter @lobsterpot/push-relay build

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
RUN corepack enable
COPY --from=build /app/package.json /app/pnpm-workspace.yaml ./
COPY --from=build /app/node_modules node_modules
COPY --from=build /app/packages/shared packages/shared
COPY --from=build /app/apps/push-relay apps/push-relay
EXPOSE 3100
CMD ["node", "apps/push-relay/dist/index.js"]
