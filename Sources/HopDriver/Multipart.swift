import Foundation

/// The shared `multipart/mixed` wire codec (DESIGN.md §20). One text-and/or-images message is packed into
/// ONE sealed body as `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]` and the far side
/// (Android or iOS) reassembles it. The format is SHARED with Android, so the endianness + field order are
/// load-bearing. Pure byte math (no node, no radio), extracted out of the HopBearer god-object so the codec
/// is a single-responsibility unit. `HopBearer.encodeMultipart` / `.decodeMultipart` forward here so the
/// existing call sites + tests are unchanged.
enum Multipart {
    /// Encode `(contentType, bytes)` parts into the shared multipart wire format.
    static func encode(_ parts: [(String, Data)]) -> Data {
        var out = Data()
        var count = UInt32(parts.count).bigEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        for (ct, body) in parts {
            let ctd = Data(ct.utf8)
            var cl = UInt16(ctd.count).bigEndian
            withUnsafeBytes(of: &cl) { out.append(contentsOf: $0) }
            out.append(ctd)
            var bl = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &bl) { out.append(contentsOf: $0) }
            out.append(body)
        }
        return out
    }

    /// Decode the shared multipart wire format into `(contentType, bytes)` parts. Tolerates truncated /
    /// malformed input: a part whose declared length runs past the buffer is dropped, never over-read.
    static func decode(_ data: Data) -> [(String, Data)] {
        let b = [UInt8](data)
        var i = 0
        func u(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(b[i]); i += 1 }
            return v
        }
        var parts: [(String, Data)] = []
        guard let count = u(4) else { return [] }
        for _ in 0..<count {
            guard let cl = u(2), i + cl <= b.count else { break }
            let ct = String(decoding: b[i..<i + cl], as: UTF8.self); i += cl
            guard let bl = u(4), i + bl <= b.count else { break }
            parts.append((ct, Data(b[i..<i + bl]))); i += bl
        }
        return parts
    }
}
