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

// Read a frontmatter `key: value` from the leading --- block of a SKILL.md.
function frontmatterField(content, key) {
  const fm = content.match(/^---\n([\s\S]*?)\n---/);
  const block = fm ? fm[1] : content;
  const m = block.match(new RegExp(`^${key}:\\s*(.+)$`, "m"));
  return m ? m[1].trim() : "";
}

// A SKILL.md's description is the first prose paragraph after the frontmatter,
// before the first markdown heading.
function descriptionField(content) {
  const body = content.replace(/^---\n[\s\S]*?\n---\n?/, "");
  const para = [];
  for (const line of body.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") {
      if (para.length > 0) break;
      continue;
    }
    if (trimmed.startsWith("#")) break;
    para.push(trimmed);
  }
  return para.join(" ");
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
  // Canonical corpus: Agent-Skills SKILL.md files under skills/. Excludes
  // legacy *.yaml, archetypes/, and .github/ CI workflows.
  const skillFiles = (tree.tree ?? []).filter(
    (f) => f.path.startsWith("skills/") && f.path.endsWith(".md")
  );

  console.log(`Found ${skillFiles.length} skill files`);

  const skills = [];
  for (const f of skillFiles) {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/contents/${f.path}`,
      { headers }
    );
    if (!res.ok) {
      console.warn(`  Skipping ${f.path}: ${res.status}`);
      continue;
    }
    const data = await res.json();
    // Decode the base64 blob as UTF-8 (atob yields latin1 → mojibake on accents).
    const content = Buffer.from(data.content, "base64").toString("utf-8");
    const parts = f.path.split("/");
    // Drop the leading `skills/` segment from the displayed category.
    const category = parts.slice(1, -1).join("/");
    skills.push({
      name: frontmatterField(content, "name") || f.path,
      description: descriptionField(content),
      app: frontmatterField(content, "app"),
      path: f.path,
      category,
      url: `${SKILLS_BASE}/blob/main/${f.path}`,
      rawUrl: `${RAW_BASE}/${f.path}`,
    });
  }

  const { mkdirSync, writeFileSync } = await import("node:fs");
  const { dirname } = await import("node:path");
  const { fileURLToPath } = await import("node:url");
  const outPath = fileURLToPath(OUTPUT);
  // src/data/ holds only this generated, git-ignored file, so a fresh checkout lacks it.
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(skills, null, 2) + "\n");
  console.log(`Wrote ${skills.length} skills to ${outPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
