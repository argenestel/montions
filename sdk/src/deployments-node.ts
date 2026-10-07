import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseDeployment, type Deployment } from "./deployments.js";

/**
 * Loads `deployments/<chain>.json` from a repository or deployment directory.
 * This node-only helper is kept out of the browser entry point so importing
 * the SDK never pulls in `node:fs` or `node:path`.
 */
export function loadDeployments(chain: number | string, directory = resolve(process.cwd(), "deployments")): Deployment {
  if (typeof chain === "string" && (chain.length === 0 || chain.includes("/") || chain.includes("\\") || chain === "." || chain === "..")) {
    throw new Error("Montions deployment chain name must be a single path segment");
  }
  const path = join(directory, `${chain}.json`);
  let json: string;
  try {
    json = readFileSync(path, "utf8");
  } catch (error) {
    throw new Error(`Unable to read Montions deployment ${path}`, { cause: error });
  }
  try {
    return parseDeployment(JSON.parse(json) as unknown);
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("Invalid Montions deployment:")) throw error;
    throw new Error(`Unable to parse Montions deployment ${path}`, { cause: error });
  }
}

/** A descriptive alias for callers that load one network manifest at a time. */
export const loadDeployment = loadDeployments;
