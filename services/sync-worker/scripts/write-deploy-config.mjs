import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parse } from "jsonc-parser";

export function renderDeployConfig(sourceText, environment, databaseId) {
  if (!["staging", "production"].includes(environment)) {
    throw new Error("Environment must be staging or production");
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(databaseId) ||
      databaseId === "00000000-0000-0000-0000-000000000000") {
    throw new Error("CLOUDFLARE_D1_DATABASE_ID must be the provisioned environment D1 UUID");
  }

  const errors = [];
  const source = parse(sourceText, errors, { allowTrailingComma: true });
  if (errors.length > 0 || !source || typeof source !== "object" || Array.isArray(source)) {
    throw new Error("wrangler.jsonc is not valid JSONC");
  }
  const target = source.env?.[environment];
  if (!target || !Array.isArray(target.d1_databases) || target.d1_databases.length !== 1) {
    throw new Error(`wrangler.jsonc does not define exactly one D1 binding for ${environment}`);
  }
  target.d1_databases[0].database_id = databaseId;
  return `${JSON.stringify(source, null, 2)}\n`;
}

async function main() {
  const [environment, outputPath] = process.argv.slice(2);
  if (!environment || !outputPath) {
    throw new Error("Usage: node scripts/write-deploy-config.mjs <staging|production> <output-path>");
  }
  const sourceText = await readFile(new URL("../wrangler.jsonc", import.meta.url), "utf8");
  const rendered = renderDeployConfig(
    sourceText,
    environment,
    process.env.CLOUDFLARE_D1_DATABASE_ID ?? "",
  );
  await writeFile(outputPath, rendered, { encoding: "utf8", mode: 0o600 });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
