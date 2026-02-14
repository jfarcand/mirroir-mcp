#!/usr/bin/env node
// Downloads the pre-built iphone-mirroir-mcp and iphone-mirroir-helper binaries
// plus the LaunchDaemon plist from GitHub releases.
// Only supports macOS (darwin) since iPhone Mirroring is a macOS feature.

const https = require("https");
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const VERSION = "0.9.1";
const REPO = "jfarcand/iphone-mirroir-mcp";
const BINARY = "iphone-mirroir-mcp";

function main() {
  if (process.platform !== "darwin") {
    console.error(
      "iphone-mirroir-mcp only supports macOS (requires iPhone Mirroring)"
    );
    process.exit(1);
  }

  const arch = process.arch === "arm64" ? "arm64" : "x86_64";
  const tarball = `${BINARY}-darwin-${arch}.tar.gz`;
  const url = `https://github.com/${REPO}/releases/download/v${VERSION}/${tarball}`;
  const binDir = path.join(__dirname, "bin");
  const nativeBin = path.join(binDir, "iphone-mirroir-mcp-native");

  // Skip if already downloaded
  if (fs.existsSync(nativeBin)) {
    return;
  }

  fs.mkdirSync(binDir, { recursive: true });

  const tmpFile = path.join(binDir, tarball);

  console.log(`Downloading ${BINARY} v${VERSION} (darwin-${arch})...`);

  // Save the JS wrapper before tar extraction (the tarball contains a native
  // binary with the same name that would overwrite it)
  const jsWrapper = path.join(binDir, "iphone-mirroir-mcp");
  const jsWrapperBackup = path.join(binDir, "iphone-mirroir-mcp.js.bak");
  if (fs.existsSync(jsWrapper)) {
    fs.copyFileSync(jsWrapper, jsWrapperBackup);
  }

  download(url, tmpFile, () => {
    // Extract all files: iphone-mirroir-mcp, iphone-mirroir-helper, plist
    execSync(`tar xzf "${tmpFile}" -C "${binDir}"`, { stdio: "inherit" });

    // Rename native binary to -native to avoid conflicting with the JS wrapper
    fs.renameSync(path.join(binDir, "iphone-mirroir-mcp"), nativeBin);
    fs.chmodSync(nativeBin, 0o755);

    // Restore the JS wrapper that tar extraction overwrote
    if (fs.existsSync(jsWrapperBackup)) {
      fs.copyFileSync(jsWrapperBackup, jsWrapper);
      fs.chmodSync(jsWrapper, 0o755);
      fs.unlinkSync(jsWrapperBackup);
    }

    // Make helper executable
    const helperBin = path.join(binDir, "iphone-mirroir-helper");
    if (fs.existsSync(helperBin)) {
      fs.chmodSync(helperBin, 0o755);
    }

    fs.unlinkSync(tmpFile);
    console.log(`Installed binaries to ${binDir}`);
  });
}

function download(url, dest, cb) {
  const file = fs.createWriteStream(dest);
  https
    .get(url, (res) => {
      // Follow redirects (GitHub releases redirect to S3)
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        file.close();
        fs.unlinkSync(dest);
        download(res.headers.location, dest, cb);
        return;
      }
      if (res.statusCode !== 200) {
        file.close();
        fs.unlinkSync(dest);
        console.error(`Download failed: HTTP ${res.statusCode}`);
        console.error(
          "Install from source instead: https://github.com/" + REPO
        );
        process.exit(1);
      }
      res.pipe(file);
      file.on("finish", () => {
        file.close(cb);
      });
    })
    .on("error", (err) => {
      fs.unlinkSync(dest);
      console.error(`Download failed: ${err.message}`);
      process.exit(1);
    });
}

main();
