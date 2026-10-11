// corpusgen.swift — deterministic benchmark corpus generator (issue #38).
//
// Emits fixed-width ASCII files whose content depends only on the seed, so
// every editor under test opens byte-identical input. Three variants per size:
//
//   fixed  — every line exactly WIDTH printable alphanumeric chars + \n
//   mixed  — line lengths seeded in [MIN,MAX], wrap-prone
//   minified — the whole document on ONE line (no interior \n)
//
// PRNG is a SplitMix64 so results are identical across machines/runs.
//
// Usage: corpusgen <outDir> <lines,comma-separated> [seed]

import Foundation

let WIDTH = 80
let MIN_LEN = 5
let MAX_LEN = 300

struct Rng {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_8CE4_E580
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 'a'..<='z', 'A'..'Z', '0'..'9' — 62 symbols.
    mutating func symbol() -> UInt8 {
        let v = next() % 62
        return v < 26 ? UInt8(97 + v) : (v < 52 ? UInt8(65 + v - 26) : UInt8(48 + v - 52))
    }
    mutating func length() -> Int { MIN_LEN + Int(next() % UInt64(MAX_LEN - MIN_LEN + 1)) }
}

func buildFile(variant: String, lines: Int, seed: UInt64) -> Data {
    var rng = Rng(seed: seed)
    var bytes = [UInt8]()
    bytes.reserveCapacity(lines * (WIDTH + 1))
    switch variant {
    case "fixed":
        for _ in 0..<lines {
            for _ in 0..<WIDTH { bytes.append(rng.symbol()) }
            bytes.append(0x0A)
        }
    case "mixed":
        for _ in 0..<lines {
            let len = rng.length()
            for _ in 0..<len { bytes.append(rng.symbol()) }
            bytes.append(0x0A)
        }
    case "minified":
        // One giant line: same byte budget as `fixed`, no interior newlines.
        for _ in 0..<(lines * WIDTH) { bytes.append(rng.symbol()) }
        bytes.append(0x0A)
    default:
        fatalError("unknown variant \(variant)")
    }
    return Data(bytes)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: corpusgen <outDir> <sizes,comma-sep> [seed]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]
let sizes = args[2].split(separator: ",").compactMap { Int($0) }
let seed = args.count > 3 ? UInt64(args[3]) ?? 42 : 42

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for size in sizes {
    for variant in ["fixed", "mixed", "minified"] {
        // `fixed` is the plain-text matrix file (.txt); the same content as a
        // .py copy lets OpenEdit-only runs exercise the highlighting path.
        let data = buildFile(variant: variant, lines: size, seed: seed &+ UInt64(size))
        let base = outDir + "/\(variant)-\(size)lines"
        try data.write(to: URL(fileURLWithPath: base + ".txt"))
        try data.write(to: URL(fileURLWithPath: base + ".py"))
        print("\(base).txt  \(data.count) bytes")
    }
}
