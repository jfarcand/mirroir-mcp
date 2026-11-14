// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Defaults for when the listen tool stops recording: the silence level, a silent start, and trailing silence.
// ABOUTME: Split from TimingConstants.swift to stay under the 500-line limit.

/// When `listen` stops before its requested length. Each has a settings key
/// of the same name, read through `EnvConfig`.
extension TimingConstants {

    /// Loudest sample, 0 to about 1, still taken as silence (about -40 dBFS).
    /// Measured on the XR: a reel's music peaked at 0.69, speech at 1.03.
    public static let listenSilencePeak: Double = 0.01

    /// Seconds of silence from the start after which `listen` stops and says
    /// nothing is playing (a muted or paused video). Measured 2026-11-12: a
    /// call on a muted reel recorded its whole 48 s of silence.
    public static let listenSilentStartSeconds: Double = 4.0

    /// Seconds of silence after sound after which `listen` stops: what played
    /// has ended. Longer than the pause between two spoken sentences.
    public static let listenTrailingSilenceSeconds: Double = 3.0
}
