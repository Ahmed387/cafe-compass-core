// Lets `node --test` load app modules that use the "@/..." alias and
// extension-less relative imports (as Vite does).
import { register } from "node:module";

register("./resolve.mjs", import.meta.url);
