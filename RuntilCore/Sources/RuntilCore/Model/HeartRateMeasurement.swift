import Foundation

/// Decodes the Bluetooth SIG Heart Rate Measurement characteristic (0x2A37).
///
/// Lives here rather than beside the CoreBluetooth code so it can be tested against real
/// byte layouts — binary protocol parsing is where the silent bugs live, and you can't
/// discover them by staring at a strap mid-run.
///
/// Layout: byte 0 is flags, and the rest depends on them.
///   bit 0  — value format: 0 = UInt8, 1 = UInt16 little-endian
///   bit 1  — sensor contact detected
///   bit 2  — sensor contact supported
///   bit 3  — energy expended field present
///   bit 4  — RR intervals present
public struct HeartRateMeasurement: Equatable, Sendable {
    public let bpm: Int
    public let contactSupported: Bool
    public let hasContact: Bool

    /// True only when the strap both supports contact detection *and* reports none —
    /// a strap that can't tell shouldn't look like a strap that's fallen off.
    public var isPoorContact: Bool { contactSupported && !hasContact }

    public init(bpm: Int, contactSupported: Bool, hasContact: Bool) {
        self.bpm = bpm
        self.contactSupported = contactSupported
        self.hasContact = hasContact
    }

    /// Returns nil for a malformed packet or a physiologically impossible value, so a
    /// garbled notification can't drive a cue.
    public static func parse(_ bytes: [UInt8]) -> HeartRateMeasurement? {
        guard let flags = bytes.first else { return nil }

        let isWide = flags & 0x01 != 0
        let hasContact = flags & 0x02 != 0
        let contactSupported = flags & 0x04 != 0

        let bpm: Int
        if isWide {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
        } else {
            guard bytes.count >= 2 else { return nil }
            bpm = Int(bytes[1])
        }

        guard (20...250).contains(bpm) else { return nil }
        return HeartRateMeasurement(
            bpm: bpm,
            contactSupported: contactSupported,
            hasContact: hasContact
        )
    }

    public static func parse(_ data: Data) -> HeartRateMeasurement? {
        parse([UInt8](data))
    }
}
