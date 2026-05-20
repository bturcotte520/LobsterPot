import { lobsterPotChannelPlugin } from "./src/channel.js";

// This default export is intentionally minimal until it is loaded inside an
// OpenClaw runtime during live integration. The package already ships the
// manifest/schema and a bridge client; the runtime adapter will be wired to the
// exact channel SDK entrypoints for the targeted OpenClaw stable release.
export default {
  id: "lobsterpot",
  name: "LobsterPot",
  description: "Connect OpenClaw to the LobsterPot iOS app.",
  plugin: lobsterPotChannelPlugin
};

export { createLobsterPotRuntime, lobsterPotChannelPlugin } from "./src/channel.js";
export { LobsterPotBridgeClient } from "./src/bridge-client.js";
export { resolveLobsterPotConfig } from "./src/config.js";
