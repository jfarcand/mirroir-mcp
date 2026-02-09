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

  // Check if Karabiner-Elements is installed
  if (!fs.existsSync("/Applications/Karabiner-Elements.app")) {
    console.log("");
    console.log("Karabiner-Elements is required but not installed.");
    console.log("Install it first:");
    console.log("  brew install --cask karabiner-elements");
    console.log("");
    console.log("Then open Karabiner-Elements and approve the DriverKit extension:");
    console.log("  System Settings > General > Login Items & Extensions");
    console.log("  Enable all toggles under Karabiner-Elements");
    console.log("");
    console.log("After that, re-run the MCP server and setup will continue.");
    process.exit(1);
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

  // Configure Karabiner ignore rule for the virtual keyboard
  configureKarabiner();

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
