// Vendored from inaka/EventSource 3.0.1
// https://github.com/inaka/EventSource — Apache License 2.0
//
// Source file: EventSource/EventStreamParser.swift
// Local changes:
//   - Type renamed `EventStreamParser` → `LACEventStreamParser`.
//   - Symbols kept fileprivate / internal.
//   - Returns `LACEvent` instead of upstream `Event`.

import Foundation

final class LACEventStreamParser {

    //  Events are separated by end of line. End of line can be:
    //  \r = CR (Carriage Return) → Used as a new line character in Mac OS before X
    //  \n = LF (Line Feed) → Used as a new line character in Unix/Mac OS X
    //  \r\n = CR + LF → Used as a new line character in Windows
    private let validNewlineCharacters = ["\r\n", "\n", "\r"]
    private let dataBuffer: NSMutableData

    init() {
        dataBuffer = NSMutableData()
    }

    var currentBuffer: String? {
        return NSString(data: dataBuffer as Data, encoding: String.Encoding.utf8.rawValue) as String?
    }

    func append(data: Data?) -> [LACEvent] {
        guard let data = data else { return [] }
        dataBuffer.append(data)

        let events = extractEventsFromBuffer().compactMap { [weak self] eventString -> LACEvent? in
            guard let self = self else { return nil }
            return LACEvent(eventString: eventString, newLineCharacters: self.validNewlineCharacters)
        }

        return events
    }

    private func extractEventsFromBuffer() -> [String] {
        var events = [String]()

        var searchRange = NSRange(location: 0, length: dataBuffer.length)
        while let foundRange = searchFirstEventDelimiter(in: searchRange) {
            let dataChunk = dataBuffer.subdata(
                with: NSRange(location: searchRange.location, length: foundRange.location - searchRange.location)
            )

            if let text = String(bytes: dataChunk, encoding: .utf8) {
                events.append(text)
            }

            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = dataBuffer.length - searchRange.location
        }

        // Drop the bytes we've already consumed.
        dataBuffer.replaceBytes(in: NSRange(location: 0, length: searchRange.location), withBytes: nil, length: 0)

        return events
    }

    /// Returns the range of the first event delimiter found in the buffer.
    /// E.g. for `id: event-id-1\ndata:event-data-first\n\n`, returns the
    /// range of the final `\n\n`.
    private func searchFirstEventDelimiter(in range: NSRange) -> NSRange? {
        let delimiters = validNewlineCharacters.map { "\($0)\($0)".data(using: String.Encoding.utf8)! }

        for delimiter in delimiters {
            let foundRange = dataBuffer.range(
                of: delimiter, options: NSData.SearchOptions(), in: range
            )

            if foundRange.location != NSNotFound {
                return foundRange
            }
        }

        return nil
    }
}
