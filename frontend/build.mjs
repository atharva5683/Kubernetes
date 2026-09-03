import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const source = dirname(fileURLToPath(import.meta.url));
const destination = process.env.OUTPUT_DIR || "/dist";
const version = process.env.APP_VERSION || "local";

await mkdir(destination, { recursive: true });
await cp(`${source}/styles.css`, `${destination}/styles.css`);
await cp(`${source}/app.js`, `${destination}/app.js`);

const html = await readFile(`${source}/index.html`, "utf8");
await writeFile(
  `${destination}/index.html`,
  html.replaceAll("__APP_VERSION__", version),
  "utf8",
);
