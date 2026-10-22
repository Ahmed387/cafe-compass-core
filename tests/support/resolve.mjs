import { existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

const SRC = fileURLToPath(new URL("../../src/", import.meta.url));

function withExtension(path) {
  if (existsSync(path) && !path.endsWith("/")) return path;
  for (const ext of [".ts", "/index.ts"]) if (existsSync(path + ext)) return path + ext;
  return null;
}

export async function resolve(specifier, context, next) {
  if (specifier.startsWith("@/")) {
    const file = withExtension(SRC + specifier.slice(2));
    if (file) return next(pathToFileURL(file).href, context);
  }
  if ((specifier.startsWith("./") || specifier.startsWith("../")) && context.parentURL?.startsWith("file:")) {
    const base = fileURLToPath(new URL(specifier, context.parentURL));
    if (!/\.[cm]?[jt]sx?$/.test(base)) {
      const file = withExtension(base);
      if (file) return next(pathToFileURL(file).href, context);
    }
  }
  return next(specifier, context);
}
