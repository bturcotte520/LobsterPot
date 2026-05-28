/**
 * Setup entry for the LobsterPot channel plugin.
 *
 * Imported by OpenClaw during setup-only flows (config wizard, status,
 * channels list) before the full channel runtime activates. Must not import
 * the bridge client, WebSocket, or any runtime-heavy modules.
 */
import { defineSetupPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { lobsterPotPlugin } from "./src/channel.js";

export default defineSetupPluginEntry(lobsterPotPlugin);
