import Foundation

/// A QR code, for the desktop to show the pairing link (`PairingLink`) and the iPhone's
/// camera to open. Byte mode only -- a link is all it ever holds -- at the smallest version
/// that fits, with the mask the standard's penalty rules choose.
///
/// Written here rather than taken from a library so the desktop needs nothing more to be
/// installed, and so it is the same code on both. It follows Project Nayuki's QR Code
/// generator (MIT licence), and the tests check it module for module against an
/// independent encoder.
struct QRCode: Equatable, Sendable {
    enum Correction: Int, Sendable, CaseIterable {
        // In the standard's table order, which the tables below are indexed by.
        case low, medium, quartile, high

        /// The two bits the format information carries for it.
        var formatBits: Int {
            switch self {
            case .low: 1
            case .medium: 0
            case .quartile: 3
            case .high: 2
            }
        }
    }

    let version: Int
    let size: Int
    let mask: Int
    /// `modules[y][x]`, true for a dark module.
    let modules: [[Bool]]

    func isDark(x: Int, y: Int) -> Bool {
        (0..<size).contains(x) && (0..<size).contains(y) && modules[y][x]
    }

    /// Nil only when `text` is too long for any version, which a pairing link never is.
    /// `mask` forces one, for the tests; otherwise the best is chosen.
    init?(_ text: String, correction: Correction = .medium, mask forcedMask: Int? = nil) {
        let data = Array(text.utf8)
        guard let version = (1...40).first(where: { Self.fits(data.count, version: $0, correction: correction) }) else {
            return nil
        }
        var builder = Builder(version: version, correction: correction)
        builder.drawFunctionPatterns()
        builder.drawCodewords(builder.withCorrection(Self.codewords(for: data, version: version, correction: correction)))

        let mask: Int
        if let forcedMask {
            mask = forcedMask
        } else {
            var best = (mask: 0, penalty: Int.max)
            for candidate in 0..<8 {
                builder.applyMask(candidate)
                builder.drawFormatBits(mask: candidate)
                let penalty = builder.penalty()
                if penalty < best.penalty { best = (candidate, penalty) }
                builder.applyMask(candidate)  // undoes it: a mask is its own inverse
            }
            mask = best.mask
        }
        builder.applyMask(mask)
        builder.drawFormatBits(mask: mask)

        self.version = version
        size = builder.size
        self.mask = mask
        modules = builder.modules
    }

    // MARK: - Data

    private static func characterCountBits(_ version: Int) -> Int { version <= 9 ? 8 : 16 }

    private static func fits(_ count: Int, version: Int, correction: Correction) -> Bool {
        guard count < 1 << characterCountBits(version) else { return false }
        let bits = 4 + characterCountBits(version) + count * 8
        return bits <= dataCodewords(version: version, correction: correction) * 8
    }

    /// The mode, the count, the bytes, the terminator and the padding, as codewords.
    private static func codewords(for data: [UInt8], version: Int, correction: Correction) -> [UInt8] {
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for index in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> index) & 1 == 1) }
        }
        append(0b0100, 4)
        append(data.count, characterCountBits(version))
        for byte in data { append(Int(byte), 8) }

        let capacity = dataCodewords(version: version, correction: correction) * 8
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity {
            append(pad, 8)
            pad ^= 0xEC ^ 0x11
        }

        return stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<start + 8].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        }
    }

    static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    static func dataCodewords(version: Int, correction: Correction) -> Int {
        rawDataModules(version) / 8
            - eccPerBlock[correction.rawValue][version] * blocks[correction.rawValue][version]
    }

    // MARK: - Tables (index 0 unused)

    static let eccPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    static let blocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    // MARK: - Drawing

    private struct Builder {
        let version: Int
        let correction: QRCode.Correction
        let size: Int
        var modules: [[Bool]]
        var isFunction: [[Bool]]

        init(version: Int, correction: QRCode.Correction) {
            self.version = version
            self.correction = correction
            size = version * 4 + 17
            modules = Array(repeating: Array(repeating: false, count: size), count: size)
            isFunction = modules
        }

        mutating func set(_ x: Int, _ y: Int, _ dark: Bool) {
            modules[y][x] = dark
            isFunction[y][x] = true
        }

        mutating func drawFunctionPatterns() {
            for index in 0..<size {
                set(6, index, index % 2 == 0)
                set(index, 6, index % 2 == 0)
            }
            drawFinder(3, 3)
            drawFinder(size - 4, 3)
            drawFinder(3, size - 4)

            let positions = alignmentPositions()
            let count = positions.count
            for i in 0..<count {
                for j in 0..<count {
                    let corner = (i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)
                    if !corner { drawAlignment(positions[i], positions[j]) }
                }
            }
            drawFormatBits(mask: 0)
            drawVersion()
        }

        private mutating func drawFinder(_ x: Int, _ y: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let distance = max(abs(dx), abs(dy))
                    let (xx, yy) = (x + dx, y + dy)
                    if (0..<size).contains(xx), (0..<size).contains(yy) {
                        set(xx, yy, distance != 2 && distance != 4)
                    }
                }
            }
        }

        private mutating func drawAlignment(_ x: Int, _ y: Int) {
            for dy in -2...2 {
                for dx in -2...2 { set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) }
            }
        }

        private func alignmentPositions() -> [Int] {
            guard version > 1 else { return [] }
            let count = version / 7 + 2
            let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
            var result = Array(repeating: 6, count: count)
            var position = size - 7
            for index in stride(from: count - 1, through: 1, by: -1) {
                result[index] = position
                position -= step
            }
            return result
        }

        mutating func drawFormatBits(mask: Int) {
            let data = correction.formatBits << 3 | mask
            var remainder = data
            for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
            let bits = (data << 10 | remainder) ^ 0x5412
            func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }

            for index in 0...5 { set(8, index, bit(index)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for index in 9..<15 { set(14 - index, 8, bit(index)) }

            for index in 0..<8 { set(size - 1 - index, 8, bit(index)) }
            for index in 8..<15 { set(8, size - 15 + index, bit(index)) }
            set(8, size - 8, true)
        }

        private mutating func drawVersion() {
            guard version >= 7 else { return }
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for index in 0..<18 {
                let dark = (bits >> index) & 1 == 1
                let a = size - 11 + index % 3
                let b = index / 3
                set(a, b, dark)
                set(b, a, dark)
            }
        }

        /// The data split into blocks, each given its error correction, and interleaved.
        func withCorrection(_ data: [UInt8]) -> [UInt8] {
            let blockCount = QRCode.blocks[correction.rawValue][version]
            let eccLength = QRCode.eccPerBlock[correction.rawValue][version]
            let raw = QRCode.rawDataModules(version) / 8
            let shortBlocks = blockCount - raw % blockCount
            let shortLength = raw / blockCount

            let divisor = ReedSolomon.divisor(degree: eccLength)
            var blocks: [[UInt8]] = []
            var start = 0
            for index in 0..<blockCount {
                let length = shortLength - eccLength + (index < shortBlocks ? 0 : 1)
                var block = Array(data[start..<start + length])
                start += length
                let ecc = ReedSolomon.remainder(block, divisor)
                if index < shortBlocks { block.append(0) }
                blocks.append(block + ecc)
            }

            var result: [UInt8] = []
            for i in 0..<blocks[0].count {
                for (j, block) in blocks.enumerated() where i != shortLength - eccLength || j >= shortBlocks {
                    result.append(block[i])
                }
            }
            return result
        }

        mutating func drawCodewords(_ data: [UInt8]) {
            var index = 0
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vertical in 0..<size {
                    for offset in 0..<2 {
                        let x = right - offset
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vertical : vertical
                        if !isFunction[y][x], index < data.count * 8 {
                            modules[y][x] = (data[index >> 3] >> (7 - (index & 7))) & 1 == 1
                            index += 1
                        }
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !isFunction[y][x] {
                    let invert: Bool
                    switch mask {
                    case 0: invert = (x + y) % 2 == 0
                    case 1: invert = y % 2 == 0
                    case 2: invert = x % 3 == 0
                    case 3: invert = (x + y) % 3 == 0
                    case 4: invert = (x / 3 + y / 2) % 2 == 0
                    case 5: invert = x * y % 2 + x * y % 3 == 0
                    case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                    default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if invert { modules[y][x].toggle() }
                }
            }
        }

        // MARK: Penalty

        func penalty() -> Int {
            var result = 0
            for y in 0..<size { result += linePenalty { modules[y][$0] } }
            for x in 0..<size { result += linePenalty { modules[$0][x] } }

            for y in 0..<size - 1 {
                for x in 0..<size - 1 {
                    let color = modules[y][x]
                    if color == modules[y][x + 1], color == modules[y + 1][x], color == modules[y + 1][x + 1] {
                        result += 3
                    }
                }
            }

            let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
            let total = size * size
            let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
            result += k * 10
            return result
        }

        /// Runs of five or more, and finder-like patterns, along one row or column.
        private func linePenalty(_ module: (Int) -> Bool) -> Int {
            var result = 0
            var runColor = false
            var runLength = 0
            var history = Array(repeating: 0, count: 7)
            for index in 0..<size {
                if module(index) == runColor {
                    runLength += 1
                    if runLength == 5 {
                        result += 3
                    } else if runLength > 5 {
                        result += 1
                    }
                } else {
                    addHistory(runLength, &history)
                    if !runColor { result += countPatterns(history) * 40 }
                    runColor = module(index)
                    runLength = 1
                }
            }
            if runColor {
                addHistory(runLength, &history)
                runLength = 0
            }
            runLength += size
            addHistory(runLength, &history)
            result += countPatterns(history) * 40
            return result
        }

        private func addHistory(_ length: Int, _ history: inout [Int]) {
            var length = length
            if history[0] == 0 { length += size }  // the light border before the first run
            history.removeLast()
            history.insert(length, at: 0)
        }

        private func countPatterns(_ history: [Int]) -> Int {
            let n = history[1]
            let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
            return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0)
                + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
        }
    }

    // MARK: - Reed-Solomon over GF(256)

    private enum ReedSolomon {
        static func divisor(degree: Int) -> [UInt8] {
            var result = Array(repeating: UInt8(0), count: degree)
            result[degree - 1] = 1
            var root: UInt8 = 1
            for _ in 0..<degree {
                for j in 0..<degree {
                    result[j] = multiply(result[j], root)
                    if j + 1 < degree { result[j] ^= result[j + 1] }
                }
                root = multiply(root, 0x02)
            }
            return result
        }

        static func remainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
            var result = Array(repeating: UInt8(0), count: divisor.count)
            for byte in data {
                let factor = byte ^ result.removeFirst()
                result.append(0)
                for index in result.indices { result[index] ^= multiply(divisor[index], factor) }
            }
            return result
        }

        static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
            var z = 0
            for index in stride(from: 7, through: 0, by: -1) {
                z = (z << 1) ^ ((z >> 7) * 0x11D)
                z ^= Int((y >> UInt8(index)) & 1) * Int(x)
            }
            return UInt8(z & 0xFF)
        }
    }
}
