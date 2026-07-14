import { readFile, writeFile } from "node:fs/promises";

const [environment, outputPath] = process.argv.slice(2);
if (!environment || !outputPath || !["staging", "production"].includes(environment)) {
  throw new Error("Usage: node scripts/write-deploy-config.mjs <staging|production> <output-path>");
}
const databaseId = process.env.CLOUDFLARE_D1_DATABASE_ID ?? "";
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(databaseId) ||
    databaseId === "00000000-0000-0000-0000-000000000000") {
  throw new Error("CLOUDFLARE_D1_DATABASE_ID must be the provisioned environment D1 UUID");
}

const source = JSON.parse(await readFile(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
const target = source.env?.[environment];
if (!target || !Array.isArray(target.d1_databases) || target.d1_databases.length !== 1) {
  throw new Error(`wrangler.jsonc does not define exactly one D1 binding for ${environment}`);
}
target.d1_databases[0].database_id = databaseId;
await writeFile(outputPath, `${JSON.stringify(source, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
