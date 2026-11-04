#!/usr/bin/env node
// ABOUTME: Interactive one-command installer for mirroir-mcp.
// ABOUTME: Builds from source if in a checkout, then configures the MCP client.

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const BIN_DIR = path.join(__dirname, "bin");
const REPO_ROOT = path.dirname(__dirname);

// --- Source Build ---

function isSourceCheckout() {
  return fs.existsSync(path.join(REPO_ROOT, "Package.swift"));
}

function buildFromSource() {
  console.log("  Source checkout detected — building from source...");
  execSync("swift build -c release", { cwd: REPO_ROOT, stdio: "inherit" });

  const releaseBin = path.join(REPO_ROOT, ".build", "release");

  fs.mkdirSync(BIN_DIR, { recursive: true });
  fs.copyFileSync(path.join(releaseBin, "mirroir-mcp"), path.join(BIN_DIR, "mirroir-mcp-native"));
  fs.chmodSync(path.join(BIN_DIR, "mirroir-mcp-native"), 0o755);
}

// --- MCP Client Configuration ---

function ask(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout
    });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function configureMcpClient() {
  console.log("[1/1] Configure MCP client");
  console.log("");
  console.log("  1) Claude Code");
  console.log("  2) Cursor");
  console.log("  3) GitHub Copilot (VS Code)");
  console.log("  4) OpenAI Codex");
  console.log("  5) Skip — I'll configure it myself");
  console.log("");

  const choice = await ask("Select your MCP client [1-5]: ");

  switch (choice) {
    case "1":
      configureClaudeCode();
      break;
    case "2":
      configureCursor();
      break;
    case "3":
      configureCopilot();
      break;
    case "4":
      configureCodex();
      break;
    case "5":
      console.log("Skipped. See https://github.com/jfarcand/mirroir-mcp for manual config.");
      break;
    default:
      console.log("Invalid choice. Skipping client configuration.");
      console.log("See https://github.com/jfarcand/mirroir-mcp for manual config.");
      break;
  }
}

function configureClaudeCode() {
  // Prefer the claude CLI for safe config merging
  let hasCli = false;
  try {
    execSync("which claude", { stdio: "ignore" });
    hasCli = true;
  } catch (noCli) {
    // claude CLI not in PATH
  }

  if (hasCli) {
    console.log("Adding mirroir to Claude Code via CLI...");
    try {
      execSync(
        'claude mcp add --transport stdio mirroir -- npx -y mirroir-mcp',
        { stdio: "inherit" }
      );
    } catch (addErr) {
      // "already exists" exits non-zero — that's fine
      const msg = addErr.stderr ? addErr.stderr.toString() : "";
      if (!msg.includes("already exists")) {
        console.log("  (server may already be configured)");
      }
    }
    console.log("Claude Code configured.");
    installSkill();
    return;
  }

  console.log("'claude' CLI not found. Updating .mcp.json directly...");
  const configPath = path.join(process.cwd(), ".mcp.json");
  let config = {};

  if (fs.existsSync(configPath)) {
    try {
      config = JSON.parse(fs.readFileSync(configPath, "utf8"));
    } catch (parseErr) {
      console.error(`Could not parse ${configPath} — add the MCP server manually.`);
      console.log('  claude mcp add --transport stdio mirroir -- npx -y mirroir-mcp');
      return;
    }
  }

  if (!config.mcpServers) config.mcpServers = {};

  if (config.mcpServers["mirroir"]) {
    console.log(`mirroir already configured in ${configPath}`);
    return;
  }

  config.mcpServers["mirroir"] = {
    type: "stdio",
    command: "npx",
    args: ["-y", "mirroir-mcp"]
  };

  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
  console.log(`Claude Code configured: ${configPath}`);
  installSkill();
}

// --- Agent Skill ---

// Writes the operating manual (how to drive the iPhone with the mirroir tools)
// where Claude Code and Codex load skills: `mirroir-mcp skill --install`.
function installSkill() {
  const nativeBin = path.join(BIN_DIR, "mirroir-mcp-native");
  try {
    execSync(`"${nativeBin}" skill --install`, { stdio: "inherit" });
  } catch (skillErr) {
    console.log("  Could not install the mirroir skill. Run: npx -y mirroir-mcp skill --install");
  }
}

function configureCursor() {
  const dir = path.join(process.cwd(), ".cursor");
  const configPath = path.join(dir, "mcp.json");
  let config = {};

  if (fs.existsSync(configPath)) {
    try {
      config = JSON.parse(fs.readFileSync(configPath, "utf8"));
    } catch (parseErr) {
      console.error(`Could not parse ${configPath} — add the MCP server manually.`);
      return;
    }
  }

  if (!config.mcpServers) config.mcpServers = {};

  if (config.mcpServers["mirroir"]) {
    console.log(`mirroir already configured in ${configPath}`);
    return;
  }

  config.mcpServers["mirroir"] = {
    command: "npx",
    args: ["-y", "mirroir-mcp"]
  };

  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
  console.log(`Cursor configured: ${configPath}`);
}

function configureCopilot() {
  const dir = path.join(process.cwd(), ".vscode");
  const configPath = path.join(dir, "mcp.json");
  let config = {};

  if (fs.existsSync(configPath)) {
    try {
      config = JSON.parse(fs.readFileSync(configPath, "utf8"));
    } catch (parseErr) {
      console.error(`Could not parse ${configPath} — add the MCP server manually.`);
      return;
    }
  }

  if (!config.servers) config.servers = {};

  if (config.servers["mirroir"]) {
    console.log(`mirroir already configured in ${configPath}`);
    return;
  }

  config.servers["mirroir"] = {
    type: "stdio",
    command: "npx",
    args: ["-y", "mirroir-mcp"]
  };

  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
  console.log(`GitHub Copilot configured: ${configPath}`);
}

function configureCodex() {
  // Prefer the codex CLI if available
  try {
    execSync("which codex", { stdio: "ignore" });
    console.log("Adding mirroir to Codex via CLI...");
    execSync(
      'codex mcp add mirroir -- npx -y mirroir-mcp',
      { stdio: "inherit" }
    );
    console.log("Codex configured.");
    installSkill();
    return;
  } catch (noCli) {
    // codex CLI not in PATH — fall back to TOML append
  }

  console.log("'codex' CLI not found. Updating ~/.codex/config.toml directly...");
  const codexDir = path.join(process.env.HOME || "", ".codex");
  const configPath = path.join(codexDir, "config.toml");

  if (fs.existsSync(configPath)) {
    const content = fs.readFileSync(configPath, "utf8");
    if (content.includes("[mcp_servers.mirroir]")) {
      console.log("mirroir already configured in ~/.codex/config.toml");
      return;
    }
  }

  const tomlBlock = [
    "",
    "[mcp_servers.mirroir]",
    'command = "npx"',
    'args = ["-y", "mirroir-mcp"]',
    ""
  ].join("\n");

  fs.mkdirSync(codexDir, { recursive: true });
  fs.appendFileSync(configPath, tomlBlock);
  console.log("Codex configured via ~/.codex/config.toml");
  installSkill();
}

// --- Main ---

async function main() {
  console.log("");
  console.log("=== mirroir-mcp installer ===");
  console.log("");

  // Build from source if in a development checkout
  const nativeBin = path.join(BIN_DIR, "mirroir-mcp-native");
  if (!fs.existsSync(nativeBin) && isSourceCheckout()) {
    buildFromSource();
  }

  await configureMcpClient();

  console.log("");
  console.log("Setup complete. Open iPhone Mirroring on your Mac and start using your MCP client.");
  console.log("");
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
