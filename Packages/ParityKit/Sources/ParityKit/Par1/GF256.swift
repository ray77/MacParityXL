/// Arithmetic over GF(2^8) with the generator polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D),
/// as used by PAR 1.0. Addition and subtraction are XOR.
enum GF256 {
    static let (log, exp): ([UInt8], [UInt8]) = {
        var log = [UInt8](repeating: 0, count: 256)
        var exp = [UInt8](repeating: 0, count: 512)
        var b = 1
        for l in 0..<255 {
            log[b] = UInt8(l)
            exp[l] = UInt8(b)
            b <<= 1
            if b & 0x100 != 0 { b ^= 0x11D }
        }
        for l in 255..<512 {
            exp[l] = exp[l - 255]
        }
        return (log, exp)
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    static func divide(_ a: UInt8, _ b: UInt8) -> UInt8 {
        guard a != 0, b != 0 else { return 0 }
        return exp[Int(log[Int(a)]) - Int(log[Int(b)]) + 255]
    }

    static func power(_ a: UInt8, _ n: Int) -> UInt8 {
        guard a != 0 else { return 0 }
        return exp[(Int(log[Int(a)]) * n) % 255]
    }

    /// Lookup table for multiplying every byte value by `factor`.
    static func multiplicationTable(for factor: UInt8) -> [UInt8] {
        (0..<256).map { multiply(UInt8($0), factor) }
    }

    /// Coefficient of data file `rank` (1-based among protected files) in recovery volume `volume` (1-based).
    static func coefficient(rank: Int, volume: Int) -> UInt8 {
        power(UInt8(rank), volume - 1)
    }

    /// Inverts a square matrix. Returns nil if it is singular.
    static func invert(_ matrix: [[UInt8]]) -> [[UInt8]]? {
        let n = matrix.count
        var m = matrix
        var inverse = (0..<n).map { row in (0..<n).map { $0 == row ? UInt8(1) : 0 } }
        for column in 0..<n {
            guard let pivot = (column..<n).first(where: { m[$0][column] != 0 }) else { return nil }
            m.swapAt(column, pivot)
            inverse.swapAt(column, pivot)
            let d = m[column][column]
            for j in 0..<n {
                m[column][j] = divide(m[column][j], d)
                inverse[column][j] = divide(inverse[column][j], d)
            }
            for row in 0..<n where row != column {
                let f = m[row][column]
                guard f != 0 else { continue }
                for j in 0..<n {
                    m[row][j] ^= multiply(m[column][j], f)
                    inverse[row][j] ^= multiply(inverse[column][j], f)
                }
            }
        }
        return inverse
    }
}
