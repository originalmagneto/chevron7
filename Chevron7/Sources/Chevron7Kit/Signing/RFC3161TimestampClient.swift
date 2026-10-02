// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import CryptoKit

public enum TimestampError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case httpStatus(Int)
    case rejected(status: Int)
    case malformedResponse(String)
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Adresa časovej pečiatky (TSA) je neplatná."
        case .httpStatus(let code):
            return "TSA server vrátil HTTP \(code)."
        case .rejected(let status):
            return "TSA zamietla žiadosť o časovú pečiatku (status \(status))."
        case .malformedResponse(let detail):
            return "Nečitateľná odpoveď TSA: \(detail)"
        case .transportFailure(let detail):
            return "Spojenie s TSA zlyhalo: \(detail)"
        }
    }
}

public struct TimestampReply: Sendable, Equatable {
    public var token: Data
    public var genTime: Date?
    public var rawResponse: Data
}

public struct RFC3161TimestampClient: Sendable {
    public var transport: any LLMTransport

    public init(transport: any LLMTransport = URLSessionLLMTransport(timeout: 12)) {
        self.transport = transport
    }

    public static func buildRequest(for data: Data, nonce: UInt64) -> Data {
        let digest = Data(SHA256.hash(data: data))
        let sha256OID = DER.oid("2.16.840.1.101.3.4.2.1")
        let messageImprint = DER.sequence([DER.sequence([sha256OID]), DER.octetString(digest)])
        return DER.sequence([
            DER.integer(1),
            messageImprint,
            DER.integer(nonce),
            DER.boolean(true)
        ])    }

    public func requestToken(for data: Data, tsaURL: URL) async throws -> TimestampReply {
        var lastError: Error = TimestampError.transportFailure("žiadny TSA")
        var candidates: [URL] = []
        let selectedUnqualified = TimestampAuthority.isRetiredUnqualified(tsaURL.absoluteString)
        if !selectedUnqualified { candidates.append(tsaURL) }
        for extra in TimestampAuthority.qualifiedURLs where !candidates.contains(extra) {
            candidates.append(extra)
        }
        for url in candidates {
            do {
                return try await requestOnce(data: data, tsaURL: url)
            } catch {
                lastError = error
            }
        }
        if let last = lastError as? TimestampError { throw last }
        throw TimestampError.transportFailure(lastError.localizedDescription)
    }

    private func requestOnce(data: Data, tsaURL: URL) async throws -> TimestampReply {
        let nonce = UInt64.random(in: 1...UInt64.max)
        let requestBody = Self.buildRequest(for: data, nonce: nonce)
        do {
            let response = try await transport.post(
                url: tsaURL,
                headers: ["Content-Type": "application/timestamp-query",
                          "Accept": "application/timestamp-reply"],
                body: requestBody)
            return try Self.parseResponse(response)
        } catch let error as AIProviderError {
            if case .httpStatus(let code) = error {
                throw TimestampError.httpStatus(code)
            }
            throw TimestampError.transportFailure("\(error)")
        } catch let error as TimestampError {
            throw error
        } catch {
            throw TimestampError.transportFailure(error.localizedDescription)
        }
    }

    public static func parseResponse(_ data: Data) throws -> TimestampReply {
        let bytes = [UInt8](data)
        guard let root = DERNode.firstTLV(bytes: bytes, at: 0), root.tag == 0x30 else {
            throw TimestampError.malformedResponse("Chýba koreňová SEQUENCE.")
        }
        let statusChildren = DERNode.children(bytes: bytes, in: root.contentRange)
        guard let statusSequence = statusChildren.first, statusSequence.tag == 0x30 else {
            throw TimestampError.malformedResponse("Chýba PKIStatusInfo.")
        }
        guard let statusInteger = DERNode.children(bytes: bytes, in: statusSequence.contentRange).first,
              statusInteger.tag == 0x02 else {
            throw TimestampError.malformedResponse("Chýba status.")
        }
        let status = Int(statusInteger.integerValue(bytes: bytes))
        guard status == 0 || status == 1 else {
            throw TimestampError.rejected(status: status)
        }

        var token = Data()
        var genTime: Date?
        if let contentInfo = statusChildren.dropFirst().first, contentInfo.tag == 0x30 {
            token = Data(bytes[contentInfo.fullRange])
            genTime = try extractGenTime(bytes: bytes, contentInfo: contentInfo)
        }
        return TimestampReply(token: token, genTime: genTime, rawResponse: data)
    }

    static func extractGenTime(bytes: [UInt8], contentInfo: DERNode) throws -> Date? {
        let outer = DERNode.children(bytes: bytes, in: contentInfo.contentRange)
        guard outer.count >= 2,
              outer[0].tag == 0x06,
              outer[0].oidString(bytes: bytes) == "1.2.840.113549.1.7.2",
              let explicitContent = outer.dropFirst().first,
              explicitContent.tag == 0xA0 else {
            throw TimestampError.malformedResponse("TimeStampToken nemá CMS ContentInfo.")
        }
        guard let signedData = DERNode.children(bytes: bytes, in: explicitContent.contentRange).first,
              signedData.tag == 0x30 else {
            throw TimestampError.malformedResponse("Chýba SignedData.")
        }
        let sdChildren = DERNode.children(bytes: bytes, in: signedData.contentRange)
        guard let encap = sdChildren.first(where: { $0.tag == 0x30 && $0.offset > sdChildren[0].offset }),
              encap.tag == 0x30 else {
            throw TimestampError.malformedResponse("Chýba encapContentInfo.")
        }
        let encapChildren = DERNode.children(bytes: bytes, in: encap.contentRange)
        guard encapChildren.count >= 2,
              encapChildren[1].tag == 0xA0,
              let octets = DERNode.children(bytes: bytes, in: encapChildren[1].contentRange).first,
              octets.tag == 0x04 else {
            throw TimestampError.malformedResponse("Chýba TSTInfo obsah.")
        }
        let innerStart = octets.contentRange.lowerBound
        guard let tstInfo = DERNode.firstTLV(bytes: bytes, at: innerStart), tstInfo.tag == 0x30 else {
            throw TimestampError.malformedResponse("Chýba TSTInfo SEQUENCE.")
        }
        for child in DERNode.children(bytes: bytes, in: tstInfo.contentRange) where child.tag == 0x18 || child.tag == 0x17 {
            let text = String(decoding: bytes[child.contentRange], as: UTF8.self)
            return Self.parseTimestamp(text, isGeneralized: child.tag == 0x18)
        }
        return nil
    }

    static func parseTimestamp(_ text: String, isGeneralized: Bool) -> Date? {
        let formats = isGeneralized ? ["yyyyMMddHHmmss'Z'", "yyyyMMddHHmmss.SSS'Z'", "yyyyMMddHHmm"] : ["yyMMddHHmmss'Z'"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

struct DERNode {
    let tag: UInt8
    let offset: Int
    let contentRange: Range<Int>

    var fullRange: Range<Int> {
        offset..<contentRange.upperBound
    }

    static func firstTLV(bytes: [UInt8], at start: Int) -> DERNode? {
        guard start < bytes.count else { return nil }
        let tag = bytes[start]
        var cursor = start + 1
        guard cursor < bytes.count else { return nil }
        let firstLengthByte = bytes[cursor]
        cursor += 1
        var contentLength = 0
        if firstLengthByte < 0x80 {
            contentLength = Int(firstLengthByte)
        } else {
            let lengthOfLength = Int(firstLengthByte & 0x7F)
            guard lengthOfLength > 0, cursor + lengthOfLength <= bytes.count else { return nil }
            for _ in 0..<lengthOfLength {
                contentLength = (contentLength << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard cursor + contentLength <= bytes.count else { return nil }
        return DERNode(tag: tag, offset: start, contentRange: cursor..<(cursor + contentLength))
    }

    static func children(bytes: [UInt8], in range: Range<Int>) -> [DERNode] {
        var result: [DERNode] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard let node = firstTLV(bytes: bytes, at: cursor) else { break }
            result.append(node)
            cursor = node.fullRange.upperBound
        }
        return result
    }

    func integerValue(bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes[contentRange] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    func oidString(bytes: [UInt8]) -> String {
        guard let first = bytes[contentRange].first else { return "" }
        var components = ["\((Int(first)) / 40)", "\((Int(first)) % 40)"]
        var value = 0
        for byte in bytes[contentRange].dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                components.append(String(value))
                value = 0
            }
        }
        return components.joined(separator: ".")
    }
}

enum DER {
    static func sequence(_ parts: [Data]) -> Data {
        tlv(0x30, parts.reduce(Data(), +))
    }

    static func integer(_ value: UInt64) -> Data {
        if value == 0 { return tlv(0x02, Data([0x00])) }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes.first ?? 0 >= 0x80 { bytes.insert(0x00, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func integerFromRaw(_ raw: [UInt8]) -> Data {
        var bytes = raw
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if bytes.first ?? 0 >= 0x80 { bytes.insert(0x00, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func octetString(_ data: Data) -> Data {
        tlv(0x04, data)
    }

    static func boolean(_ value: Bool) -> Data {
        tlv(0x01, Data([value ? 0xFF : 0x00]))
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return Data() }
        var body = Data([UInt8(parts[0] * 40 + min(parts[1], 119))])
        for part in parts.dropFirst(2) {
            var value = part
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                chunk.insert(UInt8((value & 0x7F) | 0x80), at: 0)
                value >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let length = content.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var lengthBytes: [UInt8] = []
            var remaining = length
            while remaining > 0 {
                lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(UInt8(0x80 | lengthBytes.count))
            out.append(contentsOf: lengthBytes)
        }
        out.append(content)
        return out
    }
}
