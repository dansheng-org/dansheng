import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const sdkDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(sdkDir, "..");
const runtimePath = resolve(
  repoRoot,
  "crates",
  "dansheng-core",
  "src",
  "plugins",
  "runtime.rs",
);
const declarationPath = resolve(sdkDir, "index.d.ts");
const readmePath = resolve(sdkDir, "README.md");

const runtime = readFileSync(runtimePath, "utf8");
const declarations = readFileSync(declarationPath, "utf8");
const readme = readFileSync(readmePath, "utf8");
const failures = [];

function fail(message) {
  failures.push(message);
}

function setDifference(left, right) {
  return [...left].filter((value) => !right.has(value)).sort();
}

function printSet(label, values) {
  if (values.length > 0) fail(`${label}: ${values.join(", ")}`);
}

const methodsMatch = runtime.match(
  /const METHODS:\s*&\[&str\]\s*=\s*&\[([\s\S]*?)\];/,
);
if (!methodsMatch) {
  fail("cannot locate runtime METHODS allowlist");
}

const runtimeMethods = [
  ...(methodsMatch?.[1] ?? "").matchAll(
    /"([a-z][a-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*)"/g,
  ),
].map((match) => match[1]);
const runtimeSet = new Set(runtimeMethods);

if (runtimeSet.size !== runtimeMethods.length) {
  fail("runtime METHODS contains duplicate entries");
}

const factoryMatch = runtime.match(
  /const CTX_FACTORY:\s*&str\s*=\s*r#"([\s\S]*?)"#;/,
);
if (!factoryMatch) {
  fail("cannot locate runtime CTX_FACTORY");
}

const factoryMethods = [
  ...(factoryMatch?.[1] ?? "").matchAll(/invoke\('([^']+)'/g),
].map((match) => match[1]);
const factorySet = new Set(factoryMethods);

printSet("runtime allowlist methods missing from CTX_FACTORY", setDifference(runtimeSet, factorySet));
printSet("CTX_FACTORY methods missing from runtime allowlist", setDifference(factorySet, runtimeSet));

const contextMatch = declarations.match(
  /export interface PluginContext \{([\s\S]*?)\n\}/,
);
if (!contextMatch) {
  fail("cannot locate PluginContext in index.d.ts");
}

const namespaceInterfaces = new Map(
  [...(contextMatch?.[1] ?? "").matchAll(/readonly\s+(\w+):\s*(\w+);/g)].map(
    (match) => [match[1], match[2]],
  ),
);
const runtimeNamespaces = new Set(
  runtimeMethods.map((method) => method.split(".", 1)[0]),
);
const declaredNamespaces = new Set(namespaceInterfaces.keys());

printSet(
  "runtime namespaces missing from PluginContext",
  setDifference(runtimeNamespaces, declaredNamespaces),
);
printSet(
  "PluginContext namespaces absent from runtime",
  setDifference(declaredNamespaces, runtimeNamespaces),
);

const declaredMethods = new Set();
for (const [namespace, interfaceName] of namespaceInterfaces) {
  const interfaceMatch = declarations.match(
    new RegExp(`export interface ${interfaceName} \\{([\\s\\S]*?)\\n\\}`),
  );
  if (!interfaceMatch) {
    fail(`cannot locate ${interfaceName} for namespace ${namespace}`);
    continue;
  }
  for (const match of interfaceMatch[1].matchAll(
    /^  ([A-Za-z_$][\w$]*)(?:<[^\n(]*>)?\s*\(/gm,
  )) {
    declaredMethods.add(`${namespace}.${match[1]}`);
  }
}

printSet(
  "runtime methods missing from TypeScript declarations",
  setDifference(runtimeSet, declaredMethods),
);
printSet(
  "TypeScript methods absent from runtime",
  setDifference(declaredMethods, runtimeSet),
);

const undocumented = [...runtimeSet]
  .filter((method) => !readme.includes(method))
  .sort();
printSet("runtime methods missing from README", undocumented);

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`runtime facade audit: ${failure}`);
  }
  process.exit(1);
}

console.log(
  `runtime facade audit OK: ${runtimeSet.size} methods across ${runtimeNamespaces.size} namespaces`,
);
