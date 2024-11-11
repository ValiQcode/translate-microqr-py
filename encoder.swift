import Foundation
import CoreGraphics

// MARK: - Constants and Enums

enum Mode {
    static let NUMERIC = 1
    static let ALPHANUMERIC = 2
    static let BYTE = 4
    static let KANJI = 8
    static let ECI = 7
}

enum ErrorLevel {
    static let L = 1  // 7% error correction
    static let M = 0  // 15% error correction
    static let Q = 3  // 25% error correction
    static let H = 2  // 30% error correction
}

enum Version {
    static let M1 = -1
    static let M2 = -2
    static let M3 = -3
    static let M4 = -4
}

// MARK: - Mode Support Functions

func isModeSupported(mode: Int, version: Int) -> Bool {
    if version == Version.M1 {
        return mode == Mode.NUMERIC
    }
    if version == Version.M2 {
        return mode == Mode.NUMERIC || mode == Mode.ALPHANUMERIC
    }
    if version == Version.M3 || version == Version.M4 {
        return mode == Mode.NUMERIC || mode == Mode.ALPHANUMERIC || mode == Mode.BYTE
    }
    return true
}

func getModeName(_ mode: Int) -> String {
    switch mode {
    case Mode.NUMERIC:
        return "NUMERIC"
    case Mode.ALPHANUMERIC:
        return "ALPHANUMERIC"
    case Mode.BYTE:
        return "BYTE"
    case Mode.KANJI:
        return "KANJI"
    case Mode.ECI:
        return "ECI"
    default:
        return "UNKNOWN"
    }
}

func isMicroVersion(_ version: Int) -> Bool {
    return version < 1
}

func getVersionName(_ version: Int) -> String {
    switch version {
    case Version.M1:
        return "M1"
    case Version.M2:
        return "M2"
    case Version.M3:
        return "M3"
    case Version.M4:
        return "M4"
    default:
        return String(version)
    }
}

// MARK: - Data Preparation

func prepareData(content: Any, mode: Int?, encoding: String?) throws -> [Segment] {
    if let stringContent = content as? String {
        return try prepareText(text: stringContent, mode: mode, encoding: encoding)
    } else if let dataContent = content as? Data {
        return try prepareBytes(bytes: dataContent, mode: mode)
    } else {
        throw QREncoderError.invalidMode(message: "Unsupported content type")
    }
}

func prepareText(text: String, mode: Int?, encoding: String?) throws -> [Segment] {
    if text.isEmpty {
        throw QREncoderError.dataOverflow(message: "Empty input")
    }
    
    if let mode = mode {
        return try [createSegment(text: text, mode: mode, encoding: encoding)]
    }
    
    // Auto-select optimal encoding mode
    if isNumeric(text) {
        return try [createSegment(text: text, mode: Mode.NUMERIC, encoding: nil)]
    }
    if isAlphanumeric(text) {
        return try [createSegment(text: text, mode: Mode.ALPHANUMERIC, encoding: nil)]
    }
    
    return try [createSegment(text: text, mode: Mode.BYTE, encoding: encoding)]
}

func isNumeric(_ text: String) -> Bool {
    let numericCharSet = CharacterSet.decimalDigits
    return text.unicodeScalars.allSatisfy { numericCharSet.contains($0) }
}

func isAlphanumeric(_ text: String) -> Bool {
    let alphanumericSet = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    return text.uppercased().unicodeScalars.allSatisfy { alphanumericSet.contains($0) }
}

// MARK: - Segment Creation

func createSegment(text: String, mode: Int, encoding: String?) throws -> Segment {
    let bits: [UInt8]
    let charCount: Int
    
    switch mode {
    case Mode.NUMERIC:
        (bits, charCount) = try encodeNumeric(text)
    case Mode.ALPHANUMERIC:
        (bits, charCount) = try encodeAlphanumeric(text)
    case Mode.BYTE:
        (bits, charCount) = try encodeByte(text, encoding: encoding)
    case Mode.KANJI:
        (bits, charCount) = try encodeKanji(text)
    default:
        throw QREncoderError.invalidMode(message: "Unsupported mode: \(mode)")
    }
    
    return Segment(bits: bits, charCount: charCount, mode: mode, encoding: encoding)
}

// MARK: - Main Encoding Functions

public func encode(
    content: Any,
    error: Int? = nil,
    version: Int? = nil,
    mode: Int? = nil,
    mask: Int? = nil,
    encoding: String? = nil,
    eci: Bool = false,
    micro: Bool? = nil,
    boostError: Bool = true
) throws -> Code {
    let normalizedVersion = try normalizeVersion(version)
    
    // Validate micro QR code parameters
    if let isMicro = micro {
        if isMicro {
            if normalizedVersion < 1 {
                throw QREncoderError.invalidVersion(
                    message: "A Micro QR Code version '\(getVersionName(normalizedVersion))' is provided but parameter 'micro' is false"
                )
            }
        } else {
            if normalizedVersion >= 1 {
                throw QREncoderError.invalidVersion(
                    message: "Illegal Micro QR Code version '\(getVersionName(normalizedVersion))'"
                )
            }
        }
    }
    
    let normalizedError = try normalizeErrorLevel(error, acceptNone: true)
    let normalizedMode = try normalizeMode(mode)
    
    // Validate mode support
    if let mode = normalizedMode, 
       let version = normalizedVersion,
       !isModeSupported(mode: mode, version: version) {
        throw QREncoderError.invalidMode(
            message: "Mode '\(getModeName(mode))' is not available in version '\(getVersionName(version))'"
        )
    }
    
    // Validate error correction level
    if let errorLevel = error {
        if errorLevel == ErrorLevel.H && (micro ?? false || isMicroVersion(normalizedVersion)) {
            throw QREncoderError.invalidErrorLevel(
                message: "Error correction level 'H' is not available for Micro QR Codes"
            )
        }
    } else {
        throw QREncoderError.invalidErrorLevel(message: "Error level must be provided")
    }
    
    // Validate ECI mode
    if eci && (micro ?? false || isMicroVersion(normalizedVersion)) {
        throw QREncoderError.invalidMode(
            message: "The ECI mode is not available for Micro QR Codes"
        )
    }
    
    let segments = try prepareData(content: content, mode: normalizedMode, encoding: encoding)
    let guessedVersion = try findVersion(segments: segments, error: normalizedError, eci: eci, micro: micro)
    
    let finalVersion = version ?? guessedVersion
    if guessedVersion > finalVersion {
        throw QREncoderError.dataOverflow(
            message: "The provided data does not fit into version '\(getVersionName(finalVersion))'. Proposal: version \(getVersionName(guessedVersion))"
        )
    }
    
    let finalError = finalVersion == VersionM1 ? nil : (error ?? ErrorLevel.L)
    let isMicro = finalVersion < 1
    let finalMask = try normalizeMask(mask: mask, isMicro: isMicro)
    
    return try encode(
        segments: segments,
        error: finalError,
        version: finalVersion,
        mask: finalMask,
        eci: eci,
        boostError: boostError
    )
}

// MARK: - Helper Functions

private func normalizeVersion(_ version: Int?) throws -> Int {
    guard let version = version else { return 0 }
    
    if version < 1 || (version > 40 && !isMicroVersion(version)) {
        throw QREncoderError.invalidVersion(
            message: "Unsupported version '\(version)'. Supported: M1, M2, M3, M4 and 1 .. 40"
        )
    }
    return version
}

private func normalizeMode(_ mode: Int?) throws -> Int? {
    guard let mode = mode else { return nil }
    
    if isValidMode(mode) {
        return mode
    }
    throw QREncoderError.invalidMode(
        message: "Illegal mode '\(mode)'. Supported values: \(supportedModes())"
    )
}

private func normalizeErrorLevel(_ error: Int?, acceptNone: Bool) throws -> Int? {
    if error == nil && acceptNone {
        return nil
    }
    
    guard let error = error else {
        throw QREncoderError.invalidErrorLevel(
            message: "The error level must be provided"
        )
    }
    
    if isValidErrorLevel(error) {
        return error
    }
    
    throw QREncoderError.invalidErrorLevel(
        message: "Illegal error correction level: '\(error)'. Supported levels: L, M, Q, H"
    )
}

// Additional helper functions would be implemented here...

// MARK: - Private Implementation Details

private class Buffer {
    private var data: [UInt8]
    
    init() {
        self.data = []
    }
    
    func append(_ bits: [UInt8]) {
        data.append(contentsOf: bits)
    }
    
    func appendBits(_ value: Int, length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) {
            data.append(UInt8((value >> i) & 1))
        }
    }
    
    func getBits() -> [UInt8] {
        return data
    }
    
    var count: Int {
        return data.count
    }
}

// Additional implementation details would follow...

// MARK: - Encoding Functions

func encodeNumeric(_ text: String) throws -> ([UInt8], Int) {
    let buffer = Buffer()
    var i = 0
    let length = text.count
    
    while i < length {
        var count = min(3, length - i)
        let chunk = String(text[text.index(text.startIndex, offsetBy: i)..<text.index(text.startIndex, offsetBy: i + count)])
        
        guard let value = Int(chunk) else {
            throw QREncoderError.invalidMode(message: "Invalid numeric value")
        }
        
        // Number of bits per chunk based on digit count
        let numBits: Int
        switch count {
        case 1: numBits = 4
        case 2: numBits = 7
        default: numBits = 10
        }
        
        buffer.appendBits(value, length: numBits)
        i += count
    }
    
    return (buffer.getBits(), text.count)
}

func encodeAlphanumeric(_ text: String) throws -> ([UInt8], Int) {
    let alphanumericValues: [Character: Int] = [
        "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
        "A": 10, "B": 11, "C": 12, "D": 13, "E": 14, "F": 15, "G": 16, "H": 17, "I": 18,
        "J": 19, "K": 20, "L": 21, "M": 22, "N": 23, "O": 24, "P": 25, "Q": 26, "R": 27,
        "S": 28, "T": 29, "U": 30, "V": 31, "W": 32, "X": 33, "Y": 34, "Z": 35,
        " ": 36, "$": 37, "%": 38, "*": 39, "+": 40, "-": 41, ".": 42, "/": 43, ":": 44
    ]
    
    let buffer = Buffer()
    var i = 0
    let length = text.count
    let upperText = text.uppercased()
    
    while i < length {
        let char1 = upperText[upperText.index(upperText.startIndex, offsetBy: i)]
        guard let value1 = alphanumericValues[char1] else {
            throw QREncoderError.invalidMode(message: "Invalid alphanumeric character: \(char1)")
        }
        
        if i + 1 < length {
            let char2 = upperText[upperText.index(upperText.startIndex, offsetBy: i + 1)]
            guard let value2 = alphanumericValues[char2] else {
                throw QREncoderError.invalidMode(message: "Invalid alphanumeric character: \(char2)")
            }
            
            // Encode pairs of characters (11 bits)
            buffer.appendBits(value1 * 45 + value2, length: 11)
            i += 2
        } else {
            // Encode single character (6 bits)
            buffer.appendBits(value1, length: 6)
            i += 1
        }
    }
    
    return (buffer.getBits(), text.count)
}

func encodeByte(_ text: String, encoding: String?) throws -> ([UInt8], Int) {
    let encoding = encoding ?? "utf8"
    guard let data = text.data(using: .utf8) else {
        throw QREncoderError.invalidMode(message: "Failed to encode string using \(encoding)")
    }
    
    let buffer = Buffer()
    for byte in data {
        buffer.appendBits(Int(byte), length: 8)
    }
    
    return (buffer.getBits(), data.count)
}

func encodeKanji(_ text: String) throws -> ([UInt8], Int) {
    guard let data = text.data(using: .shiftJIS) else {
        throw QREncoderError.invalidMode(message: "Failed to encode string as Shift JIS")
    }
    
    let buffer = Buffer()
    var i = 0
    let bytes = [UInt8](data)
    
    while i < bytes.count {
        guard i + 1 < bytes.count else {
            throw QREncoderError.invalidMode(message: "Invalid Kanji byte sequence")
        }
        
        let byte1 = Int(bytes[i])
        let byte2 = Int(bytes[i + 1])
        var value = byte1 << 8 | byte2
        
        // Convert Shift JIS value to QR Code Kanji value
        if value >= 0x8140 && value <= 0x9FFC {
            value -= 0x8140
        } else if value >= 0xE040 && value <= 0xEBBF {
            value -= 0xC140
        } else {
            throw QREncoderError.invalidMode(message: "Invalid Kanji byte sequence")
        }
        
        value = ((value >> 8) * 0xC0) + (value & 0xFF)
        buffer.appendBits(value, length: 13)
        i += 2
    }
    
    return (buffer.getBits(), bytes.count / 2)
}

// Helper extension for Buffer if not already defined
extension Buffer {
    func appendBits(_ value: Int, length: Int) {
        for i in stride(from: length - 1, through: 0, by: -1) {
            data.append(UInt8((value >> i) & 1))
        }
    }
}

// MARK: - Core Encoding Implementation

func encode(segments: [Segment], 
           error: Int?,
           version: Int,
           mask: Int?,
           eci: Bool,
           boostError: Bool) throws -> Code {
    
    // Prepare data bits
    let buffer = Buffer()
    
    // Add ECI header if needed
    if eci {
        buffer.appendBits(Mode.ECI, length: 4)
        buffer.appendBits(26, length: 8)  // UTF-8 ECI assignment value
    }
    
    // Add segment data
    for segment in segments {
        try addSegmentData(segment: segment, version: version, buffer: buffer)
    }
    
    // Get the required number of bits for this version and error level
    let required = try getRequiredBits(version: version, error: error)
    
    // Add terminator and pad up to required length
    try addTerminatorAndPad(buffer: buffer, required: required, version: version)
    
    // Get error correction blocks
    let blocks = try getErrorCorrectionBlocks(version: version, error: error)
    
    // Convert bit buffer to bytes
    let data = convertBitsToBytes(buffer.getBits())
    
    // Split data into blocks and add error correction
    let (dataBlocks, ecBlocks) = try splitAndCorrect(data: data, blocks: blocks)
    
    // Interleave blocks
    let finalData = interleaveBlocks(dataBlocks: dataBlocks, ecBlocks: ecBlocks)
    
    // Create the matrix
    let matrix = try createMatrix(version: version)
    
    // Add function patterns
    try addFunctionPatterns(matrix: matrix, version: version)
    
    // Add data
    try addData(matrix: matrix, data: finalData, mask: mask)
    
    // Apply final mask pattern
    let finalMask = try selectMask(matrix: matrix, mask: mask, version: version)
    
    return Code(
        matrix: matrix,
        version: version,
        error: error,
        mask: finalMask,
        segments: segments
    )
}

// MARK: - Helper Functions

private func addSegmentData(segment: Segment, version: Int, buffer: Buffer) throws {
    let mode = segment.mode
    let bits = segment.bits
    
    // Add mode indicator
    let modeInfo = try getModeInfo(mode: mode, version: version)
    buffer.appendBits(modeInfo.indicator, length: modeInfo.size)
    
    // Add character count
    let ccSize = try getCharacterCountSize(mode: mode, version: version)
    buffer.appendBits(segment.charCount, length: ccSize)
    
    // Add data
    buffer.append(bits)
}

private func getModeInfo(mode: Int, version: Int) throws -> (indicator: Int, size: Int) {
    if isMicroVersion(version) {
        switch version {
        case Version.M1:
            return (0, 0)  // Only numeric mode, no mode indicator
        case Version.M2:
            return (mode == Mode.NUMERIC ? 0 : 1, 1)
        case Version.M3:
            return (mode == Mode.NUMERIC ? 0 : (mode == Mode.ALPHANUMERIC ? 1 : 2), 2)
        case Version.M4:
            return (mode == Mode.NUMERIC ? 0 : (mode == Mode.ALPHANUMERIC ? 1 : 2), 3)
        default:
            throw QREncoderError.invalidVersion(message: "Invalid micro version")
        }
    }
    
    return (mode, 4)  // Regular QR Code uses 4 bits for mode indicator
}

private func getCharacterCountSize(mode: Int, version: Int) throws -> Int {
    if isMicroVersion(version) {
        let sizes: [Int: [Int]] = [
            Version.M1: [3, 0, 0, 0],
            Version.M2: [4, 3, 0, 0],
            Version.M3: [5, 4, 4, 0],
            Version.M4: [6, 5, 5, 0]
        ]
        
        guard let versionSizes = sizes[version] else {
            throw QREncoderError.invalidVersion(message: "Invalid micro version")
        }
        
        switch mode {
        case Mode.NUMERIC: return versionSizes[0]
        case Mode.ALPHANUMERIC: return versionSizes[1]
        case Mode.BYTE: return versionSizes[2]
        case Mode.KANJI: return versionSizes[3]
        default:
            throw QREncoderError.invalidMode(message: "Invalid mode for micro version")
        }
    }
    
    // Regular QR Code character count sizes
    let sizes: [[Int]] = [
        [10, 9, 8, 8],    // Version 1-9
        [12, 11, 16, 10], // Version 10-26
        [14, 13, 16, 12]  // Version 27-40
    ]
    
    let sizeIndex: Int
    if version <= 9 {
        sizeIndex = 0
    } else if version <= 26 {
        sizeIndex = 1
    } else {
        sizeIndex = 2
    }
    
    switch mode {
    case Mode.NUMERIC: return sizes[sizeIndex][0]
    case Mode.ALPHANUMERIC: return sizes[sizeIndex][1]
    case Mode.BYTE: return sizes[sizeIndex][2]
    case Mode.KANJI: return sizes[sizeIndex][3]
    default:
        throw QREncoderError.invalidMode(message: "Invalid mode")
    }
}

private func addTerminatorAndPad(buffer: Buffer, required: Int, version: Int) throws {
    let terminator = isMicroVersion(version) ? 3 : 4
    let remaining = required - buffer.count
    
    if remaining > 0 {
        buffer.appendBits(0, length: min(remaining, terminator))
    }
    
    // Add pad bits to make length multiple of 8
    let padBits = (8 - (buffer.count % 8)) % 8
    if padBits > 0 {
        buffer.appendBits(0, length: padBits)
    }
    
    // Add pad bytes if necessary
    let padBytes = (required - buffer.count) / 8
    let padPatterns: [Int] = [0xEC, 0x11]
    for i in 0..<padBytes {
        buffer.appendBits(padPatterns[i % 2], length: 8)
    }
}

// MARK: - Matrix Creation and Manipulation

func createMatrix(version: Int) throws -> [[UInt8]] {
    let size = getMatrixSize(version)
    // Initialize matrix with -1 (undefined state)
    return Array(repeating: Array(repeating: 255, count: size), count: size)
}

func getMatrixSize(_ version: Int) -> Int {
    if isMicroVersion(version) {
        switch version {
        case Version.M1: return 11
        case Version.M2: return 13
        case Version.M3: return 15
        case Version.M4: return 17
        default: return 0
        }
    }
    return version * 4 + 17
}

func addFunctionPatterns(matrix: inout [[UInt8]], version: Int) throws {
    // Add finder patterns for regular QR codes
    if !isMicroVersion(version) {
        addFinderPattern(matrix: &matrix, row: 0, col: 0)                    // Top-left
        addFinderPattern(matrix: &matrix, row: 0, col: matrix.count - 7)     // Top-right
        addFinderPattern(matrix: &matrix, row: matrix.count - 7, col: 0)     // Bottom-left
        addSeparators(matrix: &matrix)
    } else {
        // Add finder pattern for Micro QR codes (only top-left)
        addMicroFinderPattern(matrix: &matrix)
    }
    
    // Add alignment patterns for regular QR codes (version 2 and above)
    if version >= 2 && !isMicroVersion(version) {
        addAlignmentPatterns(matrix: &matrix, version: version)
    }
    
    // Add timing patterns
    addTimingPatterns(matrix: &matrix)
    
    // Add version information for regular QR codes (version 7 and above)
    if version >= 7 && !isMicroVersion(version) {
        try addVersionInfo(matrix: &matrix, version: version)
    }
    
    // Reserve format information area
    reserveFormatArea(matrix: &matrix, version: version)
}

func addFinderPattern(matrix: inout [[UInt8]], row: Int, col: Int) {
    // 7x7 finder pattern:
    // ■■■■■■■
    // ■□□□□□■
    // ■□■■■□■
    // ■□■■■□■
    // ■□■■■□■
    // ■□□□□□■
    // ■■■■■■■
    
    for r in 0..<7 {
        for c in 0..<7 {
            let value: UInt8 = (r == 0 || r == 6 || c == 0 || c == 6 || 
                               (r >= 2 && r <= 4 && c >= 2 && c <= 4)) ? 0 : 1
            matrix[row + r][col + c] = value
        }
    }
}

func addMicroFinderPattern(matrix: inout [[UInt8]]) {
    // Similar to regular finder pattern but smaller
    for r in 0..<7 {
        for c in 0..<7 {
            let value: UInt8 = (r == 0 || r == 6 || c == 0 || c == 6 || 
                               (r >= 2 && r <= 4 && c >= 2 && c <= 4)) ? 0 : 1
            matrix[r][c] = value
        }
    }
}

func addSeparators(matrix: inout [[UInt8]]) {
    let size = matrix.count
    
    // Horizontal separators
    for i in 0..<8 {
        matrix[7][i] = 1          // Top-left
        matrix[7][size - 8 + i] = 1  // Top-right
        matrix[size - 8][i] = 1      // Bottom-left
    }
    
    // Vertical separators
    for i in 0..<8 {
        matrix[i][7] = 1          // Top-left
        matrix[size - i - 1][7] = 1  // Bottom-left
        matrix[i][size - 8] = 1      // Top-right
    }
}

func addTimingPatterns(matrix: inout [[UInt8]]) {
    let size = matrix.count
    
    // Horizontal timing pattern
    for i in 8..<(size - 8) {
        matrix[6][i] = UInt8(i % 2)
    }
    
    // Vertical timing pattern
    for i in 8..<(size - 8) {
        matrix[i][6] = UInt8(i % 2)
    }
}

func addAlignmentPatterns(matrix: inout [[UInt8]], version: Int) {
    let positions = getAlignmentPatternPositions(version)
    
    for row in positions {
        for col in positions {
            // Skip if overlapping with finder patterns
            if !isOverlappingWithFinder(row: row, col: col, size: matrix.count) {
                addAlignmentPattern(matrix: &matrix, row: row, col: col)
            }
        }
    }
}

func addAlignmentPattern(matrix: inout [[UInt8]], row: Int, col: Int) {
    // 5x5 alignment pattern:
    // ■■■■■
    // ■□□□■
    // ■□■□■
    // ■□□□■
    // ■■■■■
    
    for r in -2...2 {
        for c in -2...2 {
            let value: UInt8 = (abs(r) == 2 || abs(c) == 2 || (r == 0 && c == 0)) ? 0 : 1
            matrix[row + r][col + c] = value
        }
    }
}

func getAlignmentPatternPositions(_ version: Int) -> [Int] {
    if version == 1 {
        return []
    }
    
    let first = 6
    let last = version * 4 + 10
    let count = version / 7 + 2
    let step = (version == 32) ? 26 : ((last - first) / (count - 1) / 2) * 2
    
    var positions = [first]
    var pos = first
    while pos < last - 10 {
        pos += step
        positions.append(pos)
    }
    positions.append(last)
    
    return positions
}

func isOverlappingWithFinder(row: Int, col: Int, size: Int) -> Bool {
    // Check if alignment pattern would overlap with finder patterns
    let overlapsTopLeft = row <= 8 && col <= 8
    let overlapsTopRight = row <= 8 && col >= size - 9
    let overlapsBottomLeft = row >= size - 9 && col <= 8
    
    return overlapsTopLeft || overlapsTopRight || overlapsBottomLeft
}

func reserveFormatArea(matrix: inout [[UInt8]], version: Int) {
    let size = matrix.count
    
    // Mark format information areas as reserved (value: 2)
    if !isMicroVersion(version) {
        // Around top-left finder pattern
        for i in 0..<9 {
            matrix[8][i] = 2      // Horizontal
            matrix[i][8] = 2      // Vertical
        }
        
        // Around top-right finder pattern
        for i in 0..<8 {
            matrix[8][size - 1 - i] = 2
        }
        
        // Around bottom-left finder pattern
        for i in 0..<7 {
            matrix[size - 1 - i][8] = 2
        }
    } else {
        // Micro QR format information area
        for i in 0..<8 {
            matrix[i][8] = 2      // Vertical
            matrix[8][i] = 2      // Horizontal
        }
        matrix[8][8] = 2
    }
}

// MARK: - Error Correction Coding

struct ECBlock {
    let count: Int
    let dataCount: Int
}

// Galois field operations
class GaloisField {
    static let EXP = [1, 2, 4, 8, 16, 32, 64, 128, 29, 58, 116, 232, 205, 135, 19, 38, 76, 152, 45, 90, 180, 117, 234, 201, 143, 3, 6, 12, 24, 48, 96, 192, 157, 39, 78, 156, 37, 74, 148, 53, 106, 212, 181, 119, 238, 193, 159, 35, 70, 140, 5, 10, 20, 40, 80, 160, 93, 186, 105, 210, 185, 111, 222, 161, 95, 190, 97, 194, 153, 47, 94, 188, 101, 202, 137, 15, 30, 60, 120, 240, 253, 231, 211, 187, 107, 214, 177, 127, 254, 225, 223, 163, 91, 182, 113, 226, 217, 175, 67, 134, 17, 34, 68, 136, 13, 26, 52, 104, 208, 189, 103, 206, 129, 31, 62, 124, 248, 237, 199, 147, 59, 118, 236, 197, 151, 51, 102, 204, 133, 23, 46, 92, 184, 109, 218, 169, 79, 158, 33, 66, 132, 21, 42, 84, 168, 77, 154, 41, 82, 164, 85, 170, 73, 146, 57, 114, 228, 213, 183, 115, 230, 209, 191, 99, 198, 145, 63, 126, 252, 229, 215, 179, 123, 246, 241, 255, 227, 219, 171, 75, 150, 49, 98, 196, 149, 55, 110, 220, 165, 87, 174, 65, 130, 25, 50, 100, 200, 141, 7, 14, 28, 56, 112, 224, 221, 167, 83, 166, 81, 162, 89, 178, 121, 242, 249, 239, 195, 155, 43, 86, 172, 69, 138, 9, 18, 36, 72, 144, 61, 122, 244, 245, 247, 243, 251, 235, 203, 139, 11, 22, 44, 88, 176, 125, 250, 233, 207, 131, 27, 54, 108, 216, 173, 71, 142, 1]
    
    static let LOG = [0, 0, 1, 25, 2, 50, 26, 198, 3, 223, 51, 238, 27, 104, 199, 75, 4, 100, 224, 14, 52, 141, 239, 129, 28, 193, 105, 248, 200, 8, 76, 113, 5, 138, 101, 47, 225, 36, 15, 33, 53, 147, 142, 218, 240, 18, 130, 69, 29, 181, 194, 125, 106, 39, 249, 185, 201, 154, 9, 120, 77, 228, 114, 166, 6, 191, 139, 98, 102, 221, 48, 253, 226, 152, 37, 179, 16, 145, 34, 136, 54, 208, 148, 206, 143, 150, 219, 189, 241, 210, 19, 92, 131, 56, 70, 64, 30, 66, 182, 163, 195, 72, 126, 110, 107, 58, 40, 84, 250, 133, 186, 61, 202, 94, 155, 159, 10, 21, 121, 43, 78, 212, 229, 172, 115, 243, 167, 87, 7, 112, 192, 247, 140, 128, 99, 13, 103, 74, 222, 237, 49, 197, 254, 24, 227, 165, 153, 119, 38, 184, 180, 124, 17, 68, 146, 217, 35, 32, 137, 46, 55, 63, 209, 91, 149, 188, 207, 205, 144, 135, 151, 178, 220, 252, 190, 97, 242, 86, 211, 171, 20, 42, 93, 158, 132, 60, 57, 83, 71, 109, 65, 162, 31, 45, 67, 216, 183, 123, 164, 118, 196, 23, 73, 236, 127, 12, 111, 246, 108, 161, 59, 82, 41, 157, 85, 170, 251, 96, 134, 177, 187, 204, 62, 90, 203, 89, 95, 176, 156, 169, 160, 81, 11, 245, 22, 235, 122, 117, 44, 215, 79, 174, 213, 233, 230, 231, 173, 232, 116, 214, 244, 234, 168, 80, 88, 175]
    
    static func multiply(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 {
            return 0
        }
        return EXP[(LOG[a] + LOG[b]) % 255]
    }
}

// Reed-Solomon error correction
class ReedSolomon {
    static func encode(_ data: [UInt8], ecCount: Int) -> [UInt8] {
        var generator = generateGenerator(ecCount)
        var message = Array(data)
        
        // Pad message with zeros
        message.append(contentsOf: Array(repeating: 0, count: ecCount))
        
        // Perform polynomial division
        for i in 0..<data.count {
            let coef = Int(message[i])
            if coef != 0 {
                for j in 0..<generator.count {
                    message[i + j] ^= UInt8(GaloisField.multiply(generator[j], coef))
                }
            }
        }
        
        // Return only the error correction bytes
        return Array(message[data.count...])
    }
    
    static func generateGenerator(_ count: Int) -> [Int] {
        var generator = [1]
        
        for i in 0..<count {
            // Multiply generator by (x + α^i)
            var newGen = [0] + generator
            let factor = GaloisField.EXP[i]
            
            for j in 0..<generator.count {
                newGen[j] ^= GaloisField.multiply(generator[j], factor)
            }
            
            generator = newGen
        }
        
        return generator
    }
}

// Error correction block information
func getErrorCorrectionBlocks(version: Int, error: Int?) throws -> [ECBlock] {
    guard let error = error else {
        if version == Version.M1 {
            return [ECBlock(count: 1, dataCount: 3)]
        }
        throw QREncoderError.invalidErrorLevel(message: "Error correction level must be provided")
    }
    
    if isMicroVersion(version) {
        return try getMicroQRErrorCorrectionBlocks(version: version, error: error)
    }
    
    return try getQRErrorCorrectionBlocks(version: version, error: error)
}

func getMicroQRErrorCorrectionBlocks(version: Int, error: Int) throws -> [ECBlock] {
    // Micro QR Code EC blocks
    let blocks: [Int: [Int: ECBlock]] = [
        Version.M2: [
            ErrorLevel.L: ECBlock(count: 1, dataCount: 5),
            ErrorLevel.M: ECBlock(count: 1, dataCount: 4)
        ],
        Version.M3: [
            ErrorLevel.L: ECBlock(count: 1, dataCount: 11),
            ErrorLevel.M: ECBlock(count: 1, dataCount: 9)
        ],
        Version.M4: [
            ErrorLevel.L: ECBlock(count: 1, dataCount: 16),
            ErrorLevel.M: ECBlock(count: 1, dataCount: 14),
            ErrorLevel.Q: ECBlock(count: 1, dataCount: 10)
        ]
    ]
    
    guard let versionBlocks = blocks[version],
          let block = versionBlocks[error] else {
        throw QREncoderError.invalidErrorLevel(message: "Invalid error correction level for version")
    }
    
    return [block]
}

func splitAndCorrect(data: [UInt8], blocks: [ECBlock]) throws -> ([[UInt8]], [[UInt8]]) {
    var dataBlocks: [[UInt8]] = []
    var ecBlocks: [[UInt8]] = []
    
    var offset = 0
    for block in blocks {
        let blockData = Array(data[offset..<offset + block.dataCount])
        offset += block.dataCount
        
        let ecData = ReedSolomon.encode(blockData, ecCount: block.count - block.dataCount)
        
        dataBlocks.append(blockData)
        ecBlocks.append(ecData)
    }
    
    return (dataBlocks, ecBlocks)
}

func interleaveBlocks(dataBlocks: [[UInt8]], ecBlocks: [[UInt8]]) -> [UInt8] {
    var result: [UInt8] = []
    
    // Interleave data blocks
    let maxDataLength = dataBlocks.map { $0.count }.max() ?? 0
    for i in 0..<maxDataLength {
        for block in dataBlocks {
            if i < block.count {
                result.append(block[i])
            }
    }
    
    // Interleave error correction blocks
    let maxECLength = ecBlocks.map { $0.count }.max() ?? 0
    for i in 0..<maxECLength {
        for block in ecBlocks {
            if i < block.count {
                result.append(block[i])
            }
        }
    }
    
    return result
}

// MARK: - Data Masking

struct MaskPattern {
    let mask: Int
    let matrix: [[UInt8]]
    let score: Int
}

func addData(matrix: inout [[UInt8]], data: [UInt8], mask: Int?) throws {
    var bitIndex = 0
    let size = matrix.count
    
    // QR codes are filled from bottom-right to top-left, in a zig-zag pattern
    // Moving upward in columns of 2
    for right in stride(from: size - 1, through: 0, by: -2) {
        // Skip the vertical timing pattern
        let actualRight = right <= 6 ? right - 1 : right
        
        // For each column pair
        for vertical in 0..<size {
            for horizontal in 0...1 {
                let col = actualRight - horizontal
                
                // Skip if column is invalid or cell is reserved
                guard col >= 0 && matrix[vertical][col] == 255 else { continue }
                
                let bit = (bitIndex < data.count * 8) && ((data[bitIndex / 8] >> (7 - (bitIndex % 8))) & 1) == 1
                matrix[vertical][col] = bit ? 1 : 0
                bitIndex += 1
            }
        }
    }
}

func selectMask(matrix: [[UInt8]], mask: Int?, version: Int) throws -> Int {
    if let mask = mask {
        // Apply specified mask
        applyMask(matrix: &matrix, pattern: mask, version: version)
        return mask
    }
    
    // Try all masks and select the best one
    var bestPattern = MaskPattern(mask: 0, matrix: matrix, score: Int.max)
    
    for pattern in 0..<(isMicroVersion(version) ? 4 : 8) {
        let testMatrix = matrix.map { $0 } // Create a copy
        applyMask(matrix: &testMatrix, pattern: pattern, version: version)
        let score = calculatePenaltyScore(matrix: testMatrix)
        
        if score < bestPattern.score {
            bestPattern = MaskPattern(mask: pattern, matrix: testMatrix, score: score)
        }
    }
    
    // Apply the best mask to the original matrix
    matrix.indices.forEach { row in
        matrix[row].indices.forEach { col in
            matrix[row][col] = bestPattern.matrix[row][col]
        }
    }
    
    return bestPattern.mask
}

func applyMask(matrix: inout [[UInt8]], pattern: Int, version: Int) {
    let size = matrix.count
    
    for row in 0..<size {
        for col in 0..<size {
            // Skip if cell is reserved or not a data/error correction bit
            guard matrix[row][col] != 255 && matrix[row][col] != 2 else { continue }
            
            let masked = shouldMaskCell(row: row, col: col, pattern: pattern)
            if masked {
                matrix[row][col] ^= 1
            }
        }
    }
    
    // Add format information
    addFormatInfo(matrix: &matrix, mask: pattern, version: version)
}

func shouldMaskCell(row: Int, col: Int, pattern: Int) -> Bool {
    switch pattern {
    case 0: return (row + col) % 2 == 0
    case 1: return row % 2 == 0
    case 2: return col % 3 == 0
    case 3: return (row + col) % 3 == 0
    case 4: return (row / 2 + col / 3) % 2 == 0
    case 5: return (((row * col) % 2) + ((row * col) % 3)) != 0
    case 6: return (((row + col) % 2) + ((row * col) % 3)) % 2 == 0
    case 7: return (((row + col) % 2) + ((row * col) % 3)) % 2 == 0
    default: return false
    }
}

func calculatePenaltyScore(matrix: [[UInt8]]) -> Int {
    var score = 0
    
    // Rule 1: Five or more same-colored modules in a row/column
    score += calculateConsecutivePatternPenalty(matrix: matrix)
    
    // Rule 2: 2x2 blocks of same-colored modules
    score += calculateBlockPatternPenalty(matrix: matrix)
    
    // Rule 3: Specific patterns that look similar to finder patterns
    score += calculateFinderPatternPenalty(matrix: matrix)
    
    // Rule 4: Balance of dark and light modules
    score += calculateBalancePenalty(matrix: matrix)
    
    return score
}

func calculateConsecutivePatternPenalty(matrix: [[UInt8]]) -> Int {
    var score = 0
    let size = matrix.count
    
    // Horizontal check
    for row in 0..<size {
        var count = 1
        var lastBit = matrix[row][0]
        
        for col in 1..<size {
            if matrix[row][col] == lastBit {
                count += 1
            } else {
                if count >= 5 {
                    score += count - 2
                }
                count = 1
                lastBit = matrix[row][col]
            }
        }
        if count >= 5 {
            score += count - 2
        }
    }
    
    // Vertical check
    for col in 0..<size {
        var count = 1
        var lastBit = matrix[0][col]
        
        for row in 1..<size {
            if matrix[row][col] == lastBit {
                count += 1
            } else {
                if count >= 5 {
                    score += count - 2
                }
                count = 1
                lastBit = matrix[row][col]
            }
        }
        if count >= 5 {
            score += count - 2
        }
    }
    
    return score
}

func calculateBlockPatternPenalty(matrix: [[UInt8]]) -> Int {
    var score = 0
    let size = matrix.count
    
    for row in 0..<(size - 1) {
        for col in 0..<(size - 1) {
            let value = matrix[row][col]
            if value == matrix[row + 1][col] &&
               value == matrix[row][col + 1] &&
               value == matrix[row + 1][col + 1] {
                score += 3
            }
        }
    }
    
    return score
}

func calculateFinderPatternPenalty(matrix: [[UInt8]]) -> Int {
    var score = 0
    let size = matrix.count
    let pattern = [1, 0, 1, 1, 1, 0, 1]
    
    // Horizontal check
    for row in 0..<size {
        for col in 0..<(size - 6) {
            var matches = true
            for i in 0..<7 {
                if Int(matrix[row][col + i]) != pattern[i] {
                    matches = false
                    break
                }
            }
            if matches {
                score += 40
            }
        }
    }
    
    // Vertical check
    for col in 0..<size {
        for row in 0..<(size - 6) {
            var matches = true
            for i in 0..<7 {
                if Int(matrix[row + i][col]) != pattern[i] {
                    matches = false
                    break
                }
            }
            if matches {
                score += 40
            }
        }
    }
    
    return score
}

func calculateBalancePenalty(matrix: [[UInt8]]) -> Int {
    var darkCount = 0
    let size = matrix.count
    let totalCount = size * size
    
    for row in 0..<size {
        for col in 0..<size {
            if matrix[row][col] == 1 {
                darkCount += 1
            }
        }
    }
    
    let percentage = (darkCount * 100) / totalCount
    let deviation = abs(percentage - 50)
    return (deviation / 5) * 10
}

// MARK: - Final Assembly

public struct QRCode {
    public let matrix: [[Bool]]
    public let version: Int
    public let errorLevel: Int?
    public let mask: Int
    public let microQR: Bool
    
    public var size: Int {
        return matrix.count
    }
}

func assembleQRCode(
    content: Any,
    errorLevel: Int? = nil,
    version: Int? = nil,
    mode: Int? = nil,
    mask: Int? = nil,
    encoding: String? = nil,
    eci: Bool = false,
    micro: Bool? = nil,
    boostError: Bool = true
) throws -> QRCode {
    // 1. Encode the data and get the Code structure
    let code = try encode(
        content: content,
        error: errorLevel,
        version: version,
        mode: mode,
        mask: mask,
        encoding: encoding,
        eci: eci,
        micro: micro,
        boostError: boostError
    )
    
    // 2. Convert the working matrix (UInt8) to final boolean matrix
    let finalMatrix = convertToFinalMatrix(code.matrix)
    
    // 3. Create and return the final QR code structure
    return QRCode(
        matrix: finalMatrix,
        version: code.version,
        errorLevel: code.error,
        mask: code.mask,
        microQR: isMicroVersion(code.version)
    )
}

private func convertToFinalMatrix(_ matrix: [[UInt8]]) -> [[Bool]] {
    return matrix.map { row in
        row.map { cell in
            // Convert module values to boolean (true = black, false = white)
            // 0 = black module, 1 = white module
            cell == 0
        }
    }
}

// MARK: - Public Interface

public enum QRErrorLevel {
    case L  // Low (7%)
    case M  // Medium (15%)
    case Q  // Quartile (25%)
    case H  // High (30%)
    
    var value: Int {
        switch self {
        case .L: return ErrorLevel.L
        case .M: return ErrorLevel.M
        case .Q: return ErrorLevel.Q
        case .H: return ErrorLevel.H
        }
    }
}

public struct QRCodeGenerator {
    public static func generate(
        from content: String,
        errorLevel: QRErrorLevel = .L,
        version: Int? = nil,
        micro: Bool? = nil
    ) throws -> QRCode {
        return try assembleQRCode(
            content: content,
            errorLevel: errorLevel.value,
            version: version,
            micro: micro
        )
    }
    
    public static func generateBinary(
        from data: Data,
        errorLevel: QRErrorLevel = .L,
        version: Int? = nil,
        micro: Bool? = nil
    ) throws -> QRCode {
        return try assembleQRCode(
            content: data,
            errorLevel: errorLevel.value,
            version: version,
            micro: micro
        )
    }
}

// MARK: - Convenience Extensions

extension QRCode {
    // Convert QR code to string representation (for debugging)
    public var debugDescription: String {
        matrix.map { row in
            row.map { $0 ? "■" : "□" }.joined()
        }.joined(separator: "\n")
    }
    
    // Get module at specific position
    public func module(at row: Int, _ col: Int) -> Bool {
        guard row >= 0 && row < size && col >= 0 && col < size else {
            return false
        }
        return matrix[row][col]
    }
    
    // Convert to image (basic implementation, can be extended)
    public func toImage(moduleSize: Int = 10) -> CGImage? {
        let size = self.size * moduleSize
        let bytesPerRow = (size + 7) / 8
        var data = Data(repeating: 0, count: bytesPerRow * size)
        
        for row in 0..<self.size {
            for col in 0..<self.size {
                if matrix[row][col] {
                    for dy in 0..<moduleSize {
                        for dx in 0..<moduleSize {
                            let x = col * moduleSize + dx
                            let y = row * moduleSize + dy
                            let byteIndex = y * bytesPerRow + x / 8
                            let bitOffset = 7 - (x % 8)
                            data[byteIndex] |= 1 << bitOffset
                        }
                    }
                }
            }
        }
        
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

// Example usage:
/*
do {
    let qrCode = try QRCodeGenerator.generate(
        from: "Hello, World!",
        errorLevel: .M
    )
    print(qrCode.debugDescription)
    
    // Or generate from binary data
    let data = "Binary Data".data(using: .utf8)!
    let binaryQR = try QRCodeGenerator.generateBinary(
        from: data,
        errorLevel: .H
    )
} catch {
    print("Error generating QR code: \(error)")
}
*/
