/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Settings for the mirroir-mcp process itself rather than the device: its log, doctor --fix, the display it keeps awake.
// ABOUTME: Read from settings.json or MIRROIR_* environment variables like every other EnvConfig value.

import Foundation

extension EnvConfig {

    /// The debug log's size, in bytes, past which a starting process moves it
    /// to `debug.log.1` and begins a new one.
    static let defaultDebugLogMaxBytes = 10 * 1024 * 1024

    /// How often `doctor --fix` asks a fresh process whether a grant is on.
    static let defaultGrantPollUs: UInt32 = 2_000_000

    /// How long `doctor --fix` waits for one grant before moving on.
    static let defaultGrantWaitUs: UInt32 = 300_000_000

    /// Verbose logging, as `--debug` turns on. The environment variable lets a
    /// host that cannot add arguments turn it on: the Claude extension maps its
    /// "Debug logging" option to `MIRROIR_DEBUG`.
    public static var debugLogging: Bool {
        readBool("debugLogging", envVar: "MIRROIR_DEBUG", default: false)
    }

    /// Size in bytes at which the debug log is rotated when a process starts.
    public static var debugLogMaxBytes: Int {
        readInt("debugLogMaxBytes", default: defaultDebugLogMaxBytes)
    }

    /// Interval between `doctor --fix`'s probes of a grant, in microseconds.
    public static var grantPollUs: UInt32 {
        readUInt32("grantPollUs", default: defaultGrantPollUs)
    }

    /// How long `doctor --fix` waits for each grant, in microseconds.
    public static var grantWaitUs: UInt32 {
        readUInt32("grantWaitUs", default: defaultGrantWaitUs)
    }

    /// Keep the Mac's display awake (no display sleep, no screen saver) while a
    /// tool call, a test, compile or record run, or a screen recording is active.
    public static var keepDisplayAwake: Bool {
        readBool("keepDisplayAwake", default: true)
    }

    /// How input reaches iPhone Mirroring: `auto` posts taps, keys and swipes
    /// to its window on the macOS versions that was measured on and uses HID
    /// input elsewhere; `on` and `off` force the window path or HID input.
    public static var windowInput: String {
        readString("windowInput", envVar: "MIRROIR_WINDOW_INPUT", default: "auto")
    }
}
