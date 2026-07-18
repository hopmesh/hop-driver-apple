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
        precondition(parts.count <= 32, "too many multipart parts")
        var out = Data()
        var count = UInt32(parts.count).bigEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        var aggregate = 0
        for (ct, body) in parts {
            let ctd = Data(ct.utf8)
            precondition(ctd.count <= 1_024, "multipart content type too large")
            precondition(body.count <= RetentionPolicy.defaults.attachmentBytes, "multipart part too large")
            aggregate += ctd.count + body.count
            precondition(aggregate <= 15 * 1024 * 1024, "multipart aggregate too large")
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
        var i = 0
        func u(_ n: Int) -> Int? {
            guard n <= data.count - i else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(data[data.index(data.startIndex, offsetBy: i)]); i += 1 }
            return v
        }
        var parts: [(String, Data)] = []
        var aggregate = 0
        guard let count = u(4), count <= 32 else { return [] }
        for _ in 0..<count {
            guard let cl = u(2), cl <= 1_024, cl <= data.count - i,
                  aggregate <= 15 * 1024 * 1024 - cl else { return [] }
            let contentStart = data.index(data.startIndex, offsetBy: i)
            let contentEnd = data.index(contentStart, offsetBy: cl)
            let ct = String(decoding: data[contentStart..<contentEnd], as: UTF8.self)
            i += cl; aggregate += cl
            guard let bl = u(4), bl <= RetentionPolicy.defaults.attachmentBytes,
                  bl <= data.count - i, aggregate <= 15 * 1024 * 1024 - bl else { return [] }
            let bodyStart = data.index(data.startIndex, offsetBy: i)
            let bodyEnd = data.index(bodyStart, offsetBy: bl)
            parts.append((ct, Data(data[bodyStart..<bodyEnd])))
            i += bl; aggregate += bl
        }
        return i == data.count ? parts : []
    }
}
