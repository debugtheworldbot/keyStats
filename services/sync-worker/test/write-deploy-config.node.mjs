import assert from "node:assert/strict";
import test from "node:test";
import { renderDeployConfig } from "../scripts/write-deploy-config.mjs";

test("renderDeployConfig accepts JSONC and emits strict JSON", () => {
  const databaseId = "11111111-1111-4111-8111-111111111111";
  const source = `{
    // Deployment replaces this placeholder for the selected environment.
    "env": {
      "staging": {
        "d1_databases": [
          {
            "binding": "DB",
            "database_id": "00000000-0000-0000-0000-000000000000",
          },
        ],
      },
    },
  }`;

  const rendered = renderDeployConfig(source, "staging", databaseId);
  const parsed = JSON.parse(rendered);

  assert.equal(parsed.env.staging.d1_databases[0].database_id, databaseId);
});
