import { cp, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

const root = process.cwd();
const output = resolve(root, "dist");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const path of ["index.html", "css", "js"]) {
  await cp(resolve(root, path), resolve(output, path), { recursive: true });
}
console.log("Static production files written to dist/.");
