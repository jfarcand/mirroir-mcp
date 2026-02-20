#!/usr/bin/env node
// Sets up the iphone-mirroir-helper daemon as a macOS LaunchDaemon.
// Requires sudo for copying the helper binary and plist to system directories.

const { execSync, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const PLIST_NAME = "com.jfarcand.iphone-mirroir-helper";
const HELPER_SOCK = "/var/run/iphone-mirroir-helper.sock";
const HELPER_DEST = "/usr/local/bin/iphone-mirroir-helper";
const PLIST_DEST = `/Library/LaunchDaemons/${PLIST_NAME}.plist`;
const KARABINER_SOCK_DIR = "/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server";
const DRIVERKIT_MANAGER = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager";
const DRIVERKIT_VERSION = "6.10.0";
const DRIVERKIT_URL = `https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v${DRIVERKIT_VERSION}/Karabiner-DriverKit-VirtualHIDDevice-${DRIVERKIT_VERSION}.pkg`;

function main() {
  const binDir = path.join(__dirname, "bin");
  const helperSrc = path.join(binDir, "iphone-mirroir-helper");
  const plistSrc = path.join(binDir, `${PLIST_NAME}.plist`);

  if (!fs.existsSync(helperSrc)) {
    console.error("Helper binary not found. Run: npm rebuild iphone-mirroir-mcp");
    process.exit(1);
  }

  if (!fs.existsSync(plistSrc)) {
    console.error("LaunchDaemon plist not found. Run: npm rebuild iphone-mirroir-mcp");
    process.exit(1);
  }

  // Check if DriverKit virtual HID is available (works for both standalone and Karabiner-Elements)
  if (!hasVhiddSocket()) {
    if (fs.existsSync("/Applications/Karabiner-Elements.app")) {
      console.log("");
      console.log("Karabiner-Elements is installed but the DriverKit extension is not running.");
      console.log("Approve the extension in System Settings:");
      console.log("  System Settings > General > Login Items & Extensions");
      console.log("  Enable all toggles under Karabiner-Elements");
      console.log("");
      console.log("After that, re-run setup.");
      process.exit(1);
    } else if (fs.existsSync(DRIVERKIT_MANAGER)) {
      console.log("");
      console.log("Standalone DriverKit is installed but the extension is not running.");
      console.log("Activate it:");
      console.log(`  ${DRIVERKIT_MANAGER} activate`);
      console.log("");
      console.log("Then approve in System Settings > General > Login Items & Extensions.");
      console.log("After that, re-run setup.");
      process.exit(1);
    } else {
      console.log("");
      console.log("A DriverKit virtual HID device is required for tap and swipe input.");
      console.log("");
      console.log("Install the standalone Karabiner DriverKit package:");
      console.log(`  curl -fSL -o /tmp/driverkit.pkg "${DRIVERKIT_URL}"`);
      console.log("  sudo installer -pkg /tmp/driverkit.pkg -target /");
      console.log(`  ${DRIVERKIT_MANAGER} activate`);
      console.log("");
      console.log("Then approve the extension in System Settings > General > Login Items & Extensions.");
      console.log("After that, re-run setup.");
      process.exit(1);
    }
  }

  console.log("=== Setting up iphone-mirroir-helper daemon ===");
  console.log("");
  console.log("This requires administrator privileges to install the helper daemon.");
  console.log("");

  // Stop existing daemon if running
  try {
    execSync(`sudo launchctl bootout system/${PLIST_NAME} 2>/dev/null`, { stdio: "inherit" });
    spawnSync("sleep", ["1"]);
  } catch (ignoreNotRunning) {
    // Daemon wasn't loaded, safe to continue
  }

  // Copy helper binary
  execSync(`sudo cp "${helperSrc}" "${HELPER_DEST}"`, { stdio: "inherit" });
  execSync(`sudo chmod 755 "${HELPER_DEST}"`, { stdio: "inherit" });

  // Copy and configure plist
  execSync(`sudo cp "${plistSrc}" "${PLIST_DEST}"`, { stdio: "inherit" });
  execSync(`sudo chown root:wheel "${PLIST_DEST}"`, { stdio: "inherit" });
  execSync(`sudo chmod 644 "${PLIST_DEST}"`, { stdio: "inherit" });

  // Start daemon
  execSync(`sudo launchctl bootstrap system "${PLIST_DEST}"`, { stdio: "inherit" });

  // Configure Karabiner ignore rule only when Karabiner-Elements is installed
  // (the ignore rule prevents the grabber from intercepting our virtual keyboard;
  // standalone DriverKit has no grabber)
  if (fs.existsSync("/Applications/Karabiner-Elements.app")) {
    configureKarabiner();
  } else {
    console.log("Using standalone DriverKit (no Karabiner grabber, ignore rule not needed).");
  }

  // Wait for helper to become ready
  console.log("");
  console.log("Waiting for helper daemon...");
  let ready = false;
  for (let i = 0; i < 15; i++) {
    spawnSync("sleep", ["2"]);
    if (checkHelper()) {
      ready = true;
      break;
    }
  }

  console.log("");
  if (ready) {
    console.log("=== Helper daemon is running ===");
  } else {
    console.log("Helper daemon started but may need more time to initialize.");
    console.log("Check: echo '{\"action\":\"status\"}' | nc -U " + HELPER_SOCK);
  }

  // Install prompts and agent profiles to global config dir
  installPromptsAndAgents();
}

function installPromptsAndAgents() {
  const globalConfigDir = path.join(process.env.HOME || "", ".iphone-mirroir-mcp");
  const promptsDir = path.join(globalConfigDir, "prompts");
  const agentsDir = path.join(globalConfigDir, "agents");

  fs.mkdirSync(promptsDir, { recursive: true });
  fs.mkdirSync(agentsDir, { recursive: true });

  // Source directories are in the npm package alongside setup.js
  const srcPromptsDir = path.join(__dirname, "prompts");
  const srcAgentsDir = path.join(__dirname, "agents");

  // Copy prompts (skip if user has customized)
  if (fs.existsSync(srcPromptsDir)) {
    for (const file of fs.readdirSync(srcPromptsDir)) {
      if (!file.endsWith(".md")) continue;
      const dest = path.join(promptsDir, file);
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(path.join(srcPromptsDir, file), dest);
        console.log(`  Installed: ${dest}`);
      }
    }
  }

  // Copy agent profiles (skip if user has customized)
  if (fs.existsSync(srcAgentsDir)) {
    for (const file of fs.readdirSync(srcAgentsDir)) {
      if (!file.endsWith(".yaml")) continue;
      const dest = path.join(agentsDir, file);
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(path.join(srcAgentsDir, file), dest);
        console.log(`  Installed: ${dest}`);
      }
    }
  }
}

function checkHelper() {
  if (!fs.existsSync(HELPER_SOCK)) return false;
  try {
    const result = spawnSync("bash", ["-c",
      `echo '{"action":"status"}' | nc -U ${HELPER_SOCK} 2>/dev/null`
    ], { timeout: 3000 });
    const output = result.stdout ? result.stdout.toString() : "";
    return output.includes('"ok"');
  } catch (socketError) {
    return false;
  }
}

function hasVhiddSocket() {
  try {
    // Socket dir is mode 700 — glob expansion needs sudo bash -c
    const result = spawnSync("sudo", ["bash", "-c",
      `ls '${KARABINER_SOCK_DIR}'/*.sock`
    ], { timeout: 5000, stdio: ["pipe", "pipe", "pipe"] });
    return result.status === 0;
  } catch (checkError) {
    return false;
  }
}

function configureKarabiner() {
  const configPath = path.join(
    process.env.HOME || "",
    ".config/karabiner/karabiner.json"
  );

  if (!fs.existsSync(configPath)) {
    // Create minimal config with ignore rule
    const configDir = path.dirname(configPath);
    fs.mkdirSync(configDir, { recursive: true });
    const config = {
      profiles: [{
        devices: [{
          identifiers: { is_keyboard: true, product_id: 592, vendor_id: 1452 },
          ignore: true
        }],
        name: "Default profile",
        selected: true,
        virtual_hid_keyboard: { keyboard_type_v2: "ansi" }
      }]
    };
    fs.writeFileSync(configPath, JSON.stringify(config, null, 4));
    console.log("Created Karabiner config with device ignore rule.");
    return;
  }

  // Check if rule already exists
  const content = fs.readFileSync(configPath, "utf8");
  if (content.includes('"product_id": 592') || content.includes('"product_id":592')) {
    return;
  }

  // Add ignore rule to first profile
  try {
    const config = JSON.parse(content);
    const profile = config.profiles[0];
    if (!profile.devices) profile.devices = [];
    profile.devices.push({
      identifiers: { is_keyboard: true, product_id: 592, vendor_id: 1452 },
      ignore: true
    });
    fs.writeFileSync(configPath, JSON.stringify(config, null, 4));
    console.log("Added device ignore rule to Karabiner config.");
  } catch (parseError) {
    console.log("Warning: Could not update Karabiner config automatically.");
    console.log("Add this device ignore rule manually: product_id 592, vendor_id 1452");
  }
}

main();
