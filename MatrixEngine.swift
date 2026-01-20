//
//  MatrixEngine.swift
//  Emotrix
//

import Foundation
import AppKit
import CoreText
import CoreGraphics

final class MatrixEngine {

    // MARK: - Tunables

    /// Speed in rows/sec (front layer). Back layer is slower.
    var rowsPerSecondRange: ClosedRange<CGFloat> = 4.0...9.0

    /// Density: how many columns are active (0..1)
    var activeColumnChance: CGFloat = 0.50

    /// Chance a payload chunk uses readable text (0..100)
    var readablePercent: CGFloat = 35

    /// Chance readable chunk is reversed (0..1)
    var readableFlipChance: CGFloat = 0.02

    /// While building readable chunks, chance each character is replaced with a katakana glyph (0..1)
    var readableNoiseCharChance: CGFloat = 0.1

    /// Noise composition: chance noise is katakana vs ASCII (0..1)
    var noiseKatakanaChance: CGFloat = 0.90

    /// How many rows long the visible trail is (auto-sized to screen height)
    private var trailLen: Int = 80

    /// White head chance: lower = more frequent
    var whiteChance: Int = 45
    var whiteHeadLen: Int = 1

    /// FPS (must match EmotrixView: 1/20)
    private let fps: CGFloat = 20

    // Depth/layers
    /// 1 = only front layer. 2 = back + front (movie-like)
    var depthLayers: Int = 2
    /// Background layer alpha (dim)
    var backLayerAlpha: CGFloat = 0.16
    /// Background layer speed multiplier (slower)
    var backLayerSpeedScale: CGFloat = 0.65
    /// Horizontal jitter amount in fraction of charW
    var xJitter: CGFloat = 0.12

    // MARK: - Font / Metrics

    var fontSize: CGFloat = 20 { didSet { recalcMetricsAndReseed() } }
    private(set) var charW: CGFloat = 12
    private(set) var charH: CGFloat = 20

    private var bounds: CGRect
    private var cols: Int = 1
    private var rowsOnScreen: Int = 60

    // Primary (latin) font
    private var ctFont: CTFont
    private var cgFont: CGFont
    private var descent: CGFloat = 0

    // Hiragino fallback for Katakana noise
    private var kanaCTFont: CTFont
    private var kanaCGFont: CGFont
    private var kanaDescent: CGFloat = 0

    // Glyph caches per-font
    private var glyphCacheLatin: [UInt16: CGGlyph] = [:]
    private var glyphCacheKana: [UInt16: CGGlyph] = [:]

    // MARK: - Data

    private var lines: [String] = []
    private var linesUtf16: [[UniChar]] = []

    private let katakanaGlyphs: [UniChar] = {
        var arr: [UniChar] = []
        for u in 0x30A0...0x30FF { arr.append(UniChar(u)) } // Katakana
        for u in 0x30...0x39 { arr.append(UniChar(u)) }     // digits
        return arr
    }()

    private let asciiNoise: [UniChar] = Array("abcdefghijklmnopqrstuvwxyz0123456789#$%&*+=-:/<>[]{}()|~".utf16)

    // Colors (dark -> bright)
    private let greenShades: [CGColor] = [
        NSColor(calibratedRed: 0, green: 0.20, blue: 0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0, green: 0.33, blue: 0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0, green: 0.52, blue: 0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0, green: 0.72, blue: 0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.24, green: 1.00, blue: 0.24, alpha: 1).cgColor
    ]

    // MARK: - Fixed-payload Drop (tape falls as a whole object)

    private struct Drop {
        var baseX: CGFloat
        var x: CGFloat

        var headY: CGFloat
        var speedPxPerFrame: CGFloat
        var rowAccum: CGFloat
        var active: Bool

        /// Fixed payload tape. Index 0 is the head glyph, 1 is below it, etc.
        var tape: [UniChar]

        /// Whether the head flashes white this tick
        var headWhite: Bool

        /// 0 = back layer, 1 = front layer
        var layer: Int
    }

    private var drops: [Drop] = []

    // MARK: - Init / Resize

    init(bounds: CGRect) {
        self.bounds = bounds

        // Primary font
        let latinCandidates = ["SFMono-Regular", "SF Mono", "Menlo"]
        var created = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        for name in latinCandidates {
            created = CTFontCreateWithName(name as CFString, fontSize, nil)
            break
        }
        self.ctFont = created
        self.cgFont = CTFontCopyGraphicsFont(created, nil)

        // Hiragino fallback for Katakana
        let kanaCandidates = ["HiraginoSans-W3", "HiraginoSans-W2", "HiraginoSans-W1", "Hiragino Sans"]
        var kanaCreated = CTFontCreateWithName("HiraginoSans-W3" as CFString, fontSize, nil)
        for name in kanaCandidates {
            kanaCreated = CTFontCreateWithName(name as CFString, fontSize, nil)
            break
        }
        self.kanaCTFont = kanaCreated
        self.kanaCGFont = CTFontCopyGraphicsFont(kanaCreated, nil)

        recalcMetricsAndReseed()
        // NOTE: drops will be seeded on first draw or after loadSentences().
    }

    func resize(to newBounds: CGRect) {
        bounds = newBounds
        recalcMetricsAndReseed()
        seedDrops()
    }

    // MARK: - Loading text

    func loadSentences(from url: URL) {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "this is a test\n"
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // keep letters/numbers/spaces/newlines, drop punctuation
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let stripped = String(cleaned.unicodeScalars.compactMap { s in
            allowed.contains(s) ? Character(s) : nil
        }).lowercased()

        var rawLines = stripped
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Merge short lines into longer ones (better for long drops)
        var merged: [String] = []
        var current = ""
        let targetLen = 160

        for line in rawLines {
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= targetLen {
                current += " " + line
            } else {
                merged.append(current)
                current = line
            }
        }
        if !current.isEmpty { merged.append(current) }

        rawLines = merged.filter { $0.count >= 80 }

        lines = rawLines.isEmpty ? ["hello world from emotrix"] : rawLines
        linesUtf16 = lines.map { Array($0.utf16) }

        // Important: seed AFTER text is loaded
        seedDrops()
    }

    private func installDefaultTextIfNeeded() {
        if !lines.isEmpty, !linesUtf16.isEmpty { return }
        lines = ["hello world from emotrix"]
        linesUtf16 = lines.map { Array($0.utf16) }
    }

    // MARK: - Metrics / Seeding

    private func recalcMetricsAndReseed() {
        glyphCacheLatin.removeAll(keepingCapacity: true)
        glyphCacheKana.removeAll(keepingCapacity: true)

        descent = CTFontGetDescent(ctFont)
        kanaDescent = CTFontGetDescent(kanaCTFont)

        // Cell metrics
        charH = fontSize
        charW = max(8, fontSize * 0.65)

        cols = max(1, Int(bounds.width / charW))
        rowsOnScreen = max(10, Int(bounds.height / charH) + 2)

        // Visible trail roughly screen height
        trailLen = max(30, min(180, rowsOnScreen + 26))
    }

    private func seedDrops() {
        installDefaultTextIfNeeded()

        drops.removeAll(keepingCapacity: true)
        drops.reserveCapacity(cols * max(1, depthLayers))

        for c in 0..<cols {
            let baseX = CGFloat(c) * charW

            // Back layer (dim + slower)
            if depthLayers >= 2 {
                drops.append(makeDrop(atBaseX: baseX, layer: 0))
            }
            // Front layer
            drops.append(makeDrop(atBaseX: baseX, layer: 1))
        }
    }

    private func makeDrop(atBaseX baseX: CGFloat, layer: Int) -> Drop {
        let active = CGFloat.random(in: 0...1) < activeColumnChance

        // Slight x jitter to create depth
        let jitter = CGFloat.random(in: -1...1) * (charW * xJitter)
        let x2 = baseX + jitter

        // Start above screen
        let startY = CGFloat.random(in: -bounds.height...(-charH))

        var rps = CGFloat.random(in: rowsPerSecondRange)
        if layer == 0 { rps *= backLayerSpeedScale }

        let speed = (rps * charH) / fps

        // Build a fixed tape long enough for full-screen fall (plus padding)
        let tape = buildTape(minLen: trailLen + rowsOnScreen + 140)

        return Drop(
            baseX: baseX,
            x: x2,
            headY: startY,
            speedPxPerFrame: speed,
            rowAccum: 0,
            active: active,
            tape: tape,
            headWhite: Int.random(in: 0..<max(1, whiteChance)) == 0,
            layer: layer
        )
    }

    // MARK: - Step / Draw

    func stepAndDraw(in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        if drops.isEmpty { seedDrops() }

        // Reduce shimmer
        ctx.setShouldAntialias(false)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)

        ctx.textMatrix = .identity
        ctx.setFontSize(fontSize)
        ctx.setTextDrawingMode(.fill)

        for i in drops.indices {
            if !drops[i].active {
                // Occasionally enable a dead column
                if CGFloat.random(in: 0...1) < 0.004 {
                    drops[i] = makeDrop(atBaseX: drops[i].baseX, layer: drops[i].layer) // ✅ use baseX
                }
                continue
            }

            draw(drop: drops[i], in: ctx)

            // Move head down
            drops[i].headY += drops[i].speedPxPerFrame

            // Head white flicker timing only
            drops[i].rowAccum += drops[i].speedPxPerFrame
            if CGFloat.random(in: 0...1) < 0.08 {
                drops[i].headWhite = Int.random(in: 0..<max(1, whiteChance)) == 0
            }

            // Reset after tail fully offscreen
            let tailYDown = drops[i].headY - CGFloat(trailLen - 1) * charH
            if tailYDown > bounds.height + charH {
                drops[i] = makeDrop(atBaseX: drops[i].baseX, layer: drops[i].layer) // ✅ use baseX
            }
        }
    }

    // MARK: - Draw (fixed tape)

    private enum FontKind { case latin, kana }

    private func draw(drop: Drop, in ctx: CGContext) {
        var currentFont: FontKind = .latin
        ctx.setFont(cgFont)

        // Depth alpha
        let alphaScale: CGFloat = (drop.layer == 0) ? backLayerAlpha : 1.0

        let x = floor(drop.x)

        // Draw the visible window of the tape (head + trail)
        for t in 0..<trailLen {
            // Mapping: tape[0] is top of trail, tape[trailLen-1] is head
            let yDown = drop.headY - CGFloat(trailLen - 1 - t) * charH

            // yDown increases with t: above => continue, below => break
            if yDown < -charH { continue }
            if yDown > bounds.height + charH { break }

            let ch: UniChar = (t < drop.tape.count) ? drop.tape[t] : UniChar(32)

            let useKana = (ch >= 0x30A0 && ch <= 0x30FF)
            let needed: FontKind = useKana ? .kana : .latin
            if needed != currentFont {
                currentFont = needed
                ctx.setFont(useKana ? kanaCGFont : cgFont)
            }

            // Color
            if drop.headWhite && t < whiteHeadLen {
                ctx.setFillColor(NSColor.white.withAlphaComponent(alphaScale).cgColor)
            } else {
                let shadeIndex = min(greenShades.count - 1,
                                     (t * greenShades.count) / max(1, trailLen - 1))
                let base = greenShades[(greenShades.count - 1) - shadeIndex]
                ctx.setFillColor(base.copy(alpha: alphaScale) ?? base)
            }

            let yQuartz = bounds.height - yDown
            let d = useKana ? kanaDescent : descent
            let baselineY = floor(yQuartz - d)

            let g = useKana ? glyphKana(for: ch) : glyphLatin(for: ch)
            ctx.showGlyphs([g], at: [CGPoint(x: x, y: baselineY)])
        }
    }

    // MARK: - Tape building (sentence + glyphs + spaces + more…)

    private func buildTape(minLen: Int) -> [UniChar] {
        var tape: [UniChar] = []
        tape.reserveCapacity(minLen)

        while tape.count < minLen {
            if CGFloat.random(in: 0...100) < readablePercent {
                appendReadableChunk(into: &tape)
            } else {
                appendNoiseChunk(into: &tape)
            }

            // breathing space between chunks
            let gap = Int.random(in: 0...5)
            if gap > 0 {
                tape.append(contentsOf: Array(repeating: UniChar(32), count: gap))
            }
        }

        return tape
    }

    private func appendReadableChunk(into tape: inout [UniChar]) {
        guard !linesUtf16.isEmpty else {
            appendNoiseChunk(into: &tape)
            return
        }

        let idx = Int.random(in: 0..<linesUtf16.count)
        let line = linesUtf16[idx]
        if line.isEmpty { return }

        let flipped = (CGFloat.random(in: 0...1) < readableFlipChance)

        // seq is always [UniChar] (stable type)
        let seq: [UniChar] = flipped ? Array(line.reversed()) : line

        for ch0 in seq {
            if CGFloat.random(in: 0...1) < readableNoiseCharChance {
                tape.append(randomNoiseGlyph())
            } else {
                tape.append(ch0)
            }
        }
    }

    private func appendNoiseChunk(into tape: inout [UniChar]) {
        let len = Int.random(in: 12...45)
        for _ in 0..<len {
            tape.append(randomNoiseGlyph())
        }
    }

    private func randomNoiseGlyph() -> UniChar {
        if CGFloat.random(in: 0...1) < noiseKatakanaChance {
            return katakanaGlyphs.randomElement() ?? UniChar(0x30A2) // ア
        }
        return asciiNoise.randomElement() ?? UniChar(0x61) // a
    }

    // MARK: - Glyph cache

    private func glyphLatin(for ch: UniChar) -> CGGlyph {
        let key = UInt16(ch)
        if let g = glyphCacheLatin[key] { return g }
        var c = ch
        var g: CGGlyph = 0
        CTFontGetGlyphsForCharacters(ctFont, &c, &g, 1)
        glyphCacheLatin[key] = g
        return g
    }

    private func glyphKana(for ch: UniChar) -> CGGlyph {
        let key = UInt16(ch)
        if let g = glyphCacheKana[key] { return g }
        var c = ch
        var g: CGGlyph = 0
        CTFontGetGlyphsForCharacters(kanaCTFont, &c, &g, 1)
        glyphCacheKana[key] = g
        return g
    }
}
