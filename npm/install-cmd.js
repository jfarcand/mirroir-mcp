#!/usr/bin/env node
// ABOUTME: Interactive one-command installer for iphone-mirroir-mcp.
// ABOUTME: Handles standalone DriverKit install (or reuses Karabiner-Elements), helper daemon setup, and MCP client configuration.

const { execSync, execFileSync, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const HELPER_SOCK = "/var/run/iphone-mirroir-helper.sock";
const KARABINER_APP = "/Applications/Karabiner-Elements.app";
const DRIVERKIT_MANAGER = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager";
const DRIVERKIT_VERSION = "6.10.0";
const DRIVERKIT_PKG = `Karabiner-DriverKit-VirtualHIDDevice-${DRIVERKIT_VERSION}.pkg`;
const DRIVERKIT_URL = `https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v${DRIVERKIT_VERSION}/${DRIVERKIT_PKG}`;
const KARABINER_SOCK_DIR = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server";
const SETUP_SCRIPT = path.join(__dirname, "setup.js");
const BIN_DIR = path.join(__dirname, "bin");
const REPO_ROOT = path.dirname(__dirname);

// --- DriverKit ---

function hasVhiddSocket() {
  try {
    const result = spawnSync("sudo", ["bash", "-c",
      `ls '${KARABINER_SOCK_DIR}'/*.sock`
    ], { timeout: 5000, stdio: ["pipe", "pipe", "pipe"] });
    return result.status === 0;
  } catch (checkErr) {
    return false;
  }
}

function ensureDriverKit() {
  if (hasVhiddSocket()) {
    const provider = fs.existsSync(KARABINER_APP) ? "Karabiner-Elements" : "standalone DriverKit";
    console.log(`[1/3] DriverKit virtual HID is running (${provider}).`);
    return;
  }

  if (fs.existsSync(KARABINER_APP)) {
    console.log("[1/3] Karabiner-Elements is installed but the DriverKit extension is not running.");
    console.log("  Approve the extension in System Settings:");
    console.log("  System Settings > General > Login Items & Extensions");
    console.log("  Enable all toggles under Karabiner-Elements");
    console.log("");
    console.log("Press Enter once you have approved the extension...");
    spawnSync("bash", ["-c", "read -r"], { stdio: "inherit" });
    return;
  }

  if (fs.existsSync(DRIVERKIT_MANAGER)) {
    console.log("[1/3] Standalone DriverKit is installed but the extension is not running.");
    console.log("  Activating...");
    try {
      execSync(`"${DRIVERKIT_MANAGER}" activate`, { stdio: "inherit" });
    } catch (activateErr) {
      // Activation may fail if already activated — continue
    }
    console.log("  Approve the extension in System Settings > General > Login Items & Extensions.");
    console.log("");
    console.log("Press Enter once you have approved the extension...");
    spawnSync("bash", ["-c", "read -r"], { stdio: "inherit" });
    return;
  }

  console.log("[1/3] Installing standalone Karabiner DriverKit package...");

  const tmpPkg = `/tmp/${DRIVERKIT_PKG}`;
  try {
    execSync(`curl -fSL -o "${tmpPkg}" "${DRIVERKIT_URL}"`, { stdio: "inherit" });
    execSync(`sudo installer -pkg "${tmpPkg}" -target /`, { stdio: "inherit" });
    execSync(`rm -f "${tmpPkg}"`, { stdio: "ignore" });
  } catch (installErr) {
    console.error("Failed to install DriverKit package.");
    console.error(`Download manually from: https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases`);
    process.exit(1);
  }

  console.log("");
  console.log("Activating DriverKit system extension...");
  try {
    execSync(`"${DRIVERKIT_MANAGER}" activate`, { stdio: "inherit" });
  } catch (activateErr) {
    // Continue — user will approve in System Settings
  }

  console.log("");
  console.log("Approve the system extension in System Settings:");
  console.log("  System Settings > General > Login Items & Extensions");
  console.log("  Enable the Karabiner-DriverKit-VirtualHIDDevice toggle");
  console.log("");
  console.log("Press Enter once you have approved the extension...");

  spawnSync("bash", ["-c", "read -r"], { stdio: "inherit" });
}

// --- Source Build ---

function isSourceCheckout() {
  return fs.existsSync(path.join(REPO_ROOT, "Package.swift"));
}

function buildFromSource() {
  console.log("  Source checkout detected — building from source...");
  execSync("swift build -c release", { cwd: REPO_ROOT, stdio: "inherit" });

  const releaseBin = path.join(REPO_ROOT, ".build", "release");
  const plistSrc = path.join(REPO_ROOT, "Resources", "com.jfarcand.iphone-mirroir-helper.plist");

  fs.mkdirSync(BIN_DIR, { recursive: true });
  fs.copyFileSync(path.join(releaseBin, "iphone-mirroir-helper"), path.join(BIN_DIR, "iphone-mirroir-helper"));
  fs.chmodSync(path.join(BIN_DIR, "iphone-mirroir-helper"), 0o755);
  fs.copyFileSync(path.join(releaseBin, "iphone-mirroir-mcp"), path.join(BIN_DIR, "iphone-mirroir-mcp-native"));
  fs.chmodSync(path.join(BIN_DIR, "iphone-mirroir-mcp-native"), 0o755);
  fs.copyFileSync(plistSrc, path.join(BIN_DIR, "com.jfarcand.iphone-mirroir-helper.plist"));
}

// --- Helper Daemon ---

function isHelperRunning() {
  if (!fs.existsSync(HELPER_SOCK)) return false;
  try {
    const result = spawnSync("bash", ["-c",
      `echo '{"action":"status"}' | nc -U ${HELPER_SOCK} 2>/dev/null`
    ], { timeout: 3000 });
    const output = result.stdout ? result.stdout.toString() : "";
    return output.includes('"ok"');
  } catch (socketErr) {
    return false;
  }
}

function ensureHelper() {
  if (isHelperRunning()) {
    console.log("[2/3] Helper daemon is running.");
    return;
  }

  console.log("[2/3] Helper daemon not running. Setting up...");

  // If helper binary is missing and we're in a source checkout, build first
  const helperBin = path.join(BIN_DIR, "iphone-mirroir-helper");
  if (!fs.existsSync(helperBin) && isSourceCheckout()) {
    buildFromSource();
  }

  if (!fs.existsSync(SETUP_SCRIPT)) {
    console.error("Setup script not found. Run: npm rebuild iphone-mirroir-mcp");
    process.exit(1);
  }

  try {
    execFileSync("node", [SETUP_SCRIPT], { stdio: "inherit" });
  } catch (setupErr) {
    console.error("Helper setup failed. See https://github.com/jfarcand/iphone-mirroir-mcp for manual install.");
    process.exit(1);
  }
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
  console.log("[3/3] Configure MCP client");
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
      console.log("Skipped. See https://github.com/jfarcand/iphone-mirroir-mcp for manual config.");
      break;
    default:
      console.log("Invalid choice. Skipping client configuration.");
      console.log("See https://github.com/jfarcand/iphone-mirroir-mcp for manual config.");
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
        'claude mcp add --transport stdio mirroir -- npx -y iphone-mirroir-mcp',
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
      console.log('  claude mcp add --transport stdio mirroir -- npx -y iphone-mirroir-mcp');
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
    args: ["-y", "iphone-mirroir-mcp"]
  };

  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
  console.log(`Claude Code configured: ${configPath}`);
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
    args: ["-y", "iphone-mirroir-mcp"]
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
    args: ["-y", "iphone-mirroir-mcp"]
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
      'codex mcp add mirroir -- npx -y iphone-mirroir-mcp',
      { stdio: "inherit" }
    );
    console.log("Codex configured.");
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
    'args = ["-y", "iphone-mirroir-mcp"]',
    ""
  ].join("\n");

  fs.mkdirSync(codexDir, { recursive: true });
  fs.appendFileSync(configPath, tomlBlock);
  console.log("Codex configured via ~/.codex/config.toml");
}

// --- Main ---

async function main() {
  console.log("");
  console.log("=== iphone-mirroir-mcp installer ===");
  console.log("");

  ensureDriverKit();
  ensureHelper();
  await configureMcpClient();

  console.log("");
  console.log("Setup complete. Open iPhone Mirroring on your Mac and start using your MCP client.");
  console.log("");
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
