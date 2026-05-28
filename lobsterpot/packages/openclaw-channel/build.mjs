/**
 * Build script for the OpenClaw plugin distribution.
 *
 * Produces a self-contained package in dist-bundle/ that can be installed
 * directly into OpenClaw with `openclaw plugins install <path>`. Workspace
 * deps (@lobsterpot/protocol, @lobsterpot/shared) are inlined by esbuild.
 * Runtime deps (ws, zod) are installed with npm. The peer dep `openclaw`
 * is provided by the host at runtime.
 */

import { build } from "esbuild";
import { mkdirSync, copyFileSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const out = join(__dirname, "dist-bundle");

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
mkdirSync(join(out, "dist"), { recursive: true });

// Externals: peer deps (provided by host) and runtime deps installed via npm
const external = ["openclaw", "openclaw/*", "ws", "zod"];

const common = {
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  external,
  sourcemap: true
};

await build({
  ...common,
  entryPoints: [join(__dirname, "index.ts")],
  outfile: join(out, "dist/index.js")
});

await build({
  ...common,
  entryPoints: [join(__dirname, "setup-entry.ts")],
  outfile: join(out, "dist/setup-entry.js")
});

const pkg = JSON.parse(readFileSync(join(__dirname, "package.json"), "utf8"));
const distPkg = {
  name: pkg.name,
  version: pkg.version,
  description: pkg.description,
  type: "module",
  main: "dist/index.js",
  exports: {
    ".": "./dist/index.js",
    "./setup-entry": "./dist/setup-entry.js"
  },
  openclaw: pkg.openclaw,
  dependencies: {
    ws: pkg.dependencies.ws,
    zod: pkg.dependencies.zod
  },
  peerDependencies: pkg.peerDependencies,
  peerDependenciesMeta: pkg.peerDependenciesMeta
};
writeFileSync(join(out, "package.json"), JSON.stringify(distPkg, null, 2));

copyFileSync(
  join(__dirname, "openclaw.plugin.json"),
  join(out, "openclaw.plugin.json")
);

console.log("Installing runtime deps with npm (no symlinks)...");
execSync("npm install --no-audit --no-fund --omit=dev --omit=peer", {
  cwd: out,
  stdio: "inherit"
});

console.log(`\n✓ Plugin bundled to ${out}`);
console.log(`Install with: openclaw plugins install ${out}`);
