#!/usr/bin/env node
// ABOUTME: Generates a static skills-index.json for the website build.
// ABOUTME: Fetches skill metadata from the GitHub API and writes a JSON file that Astro reads at build time.

const REPO = "jfarcand/mirroir-skills";
const SKILLS_BASE = `https://github.com/${REPO}`;
const RAW_BASE = `https://raw.githubusercontent.com/${REPO}/main`;
const OUTPUT = new URL("../website/src/data/skills-index.json", import.meta.url);

const headers = { Accept: "application/vnd.github.v3+json" };
const token = process.env.GITHUB_TOKEN;
if (token) {
  headers.Authorization = `Bearer ${token}`;
}

function yamlValue(content, key) {
  const lineMatch = content.match(new RegExp(`^${key}:\\s*(.*)$`, "m"));
  if (!lineMatch) return "";
  const rest = lineMatch[1].trim();
  if (rest && rest !== ">" && rest !== "|") return rest;
  const lines = content.split("\n");
  const startIdx = lines.findIndex((l) => l.match(new RegExp(`^${key}:`)));
  if (startIdx < 0) return rest;
  const blockLines = [];
  for (let i = startIdx + 1; i < lines.length; i++) {
    if (/^\s+\S/.test(lines[i])) {
      blockLines.push(lines[i].trim());
    } else if (lines[i].trim() === "") {
      blockLines.push("");
    } else {
      break;
    }
  }
  const firstPara = [];
  for (const line of blockLines) {
    if (line === "") break;
    firstPara.push(line);
  }
  return firstPara.join(" ");
}

async function main() {
  console.log(`Fetching skill index from ${REPO}...`);

  const treeRes = await fetch(
    `https://api.github.com/repos/${REPO}/git/trees/main?recursive=1`,
    { headers }
  );

  if (!treeRes.ok) {
    console.error(`GitHub API returned ${treeRes.status}: ${treeRes.statusText}`);
    process.exit(1);
  }

  const tree = await treeRes.json();
  const yamlFiles = (tree.tree ?? []).filter(
    (f) => f.path.endsWith(".yaml") || f.path.endsWith(".yml")
  );

  console.log(`Found ${yamlFiles.length} YAML files`);

  const skills = [];
  for (const f of yamlFiles) {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/contents/${f.path}`,
      { headers }
    );
    if (!res.ok) {
      console.warn(`  Skipping ${f.path}: ${res.status}`);
      continue;
    }
    const data = await res.json();
    const content = atob(data.content.replace(/\n/g, ""));
    const parts = f.path.split("/");
    const category = parts.length > 1 ? parts.slice(0, -1).join("/") : "";
    skills.push({
      name: yamlValue(content, "name") || f.path,
      description: yamlValue(content, "description"),
      app: yamlValue(content, "app"),
      path: f.path,
      category,
      url: `${SKILLS_BASE}/blob/main/${f.path}`,
      rawUrl: `${RAW_BASE}/${f.path}`,
    });
  }

  const { writeFileSync } = await import("node:fs");
  const { fileURLToPath } = await import("node:url");
  const outPath = fileURLToPath(OUTPUT);
  writeFileSync(outPath, JSON.stringify(skills, null, 2) + "\n");
  console.log(`Wrote ${skills.length} skills to ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
