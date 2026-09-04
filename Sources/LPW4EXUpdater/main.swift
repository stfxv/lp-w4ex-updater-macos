import CryptoKit
import Foundation
import LPUSBBridge

private enum AppError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private struct USBDevice: CustomStringConvertible {
    let vendorID: UInt16
    let productID: UInt16

    var description: String {
        String(format: "VID_%04X&PID_%04X", vendorID, productID)
    }
}

private struct FirmwareImage {
    let url: URL
    let bytes: Data
    let sha256: String

    static func load(path: String) throws -> FirmwareImage {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "bin" else {
            throw AppError.message("ファームウェアは公式パッケージ内の .bin ファイルを指定する必要がある: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AppError.message("ファイルを読み込めない: \(url.path)")
        }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard bytes.count >= 4096 else {
            throw AppError.message("ファームウェアが小さすぎる (\(bytes.count) bytes)。公式W4用 .bin か確認する")
        }
        // The Windows CT7601 tool's update range is bounded at 1 MiB. Keep
        // the Mac tool from accepting a file that could address beyond that
        // range until a device-specific flash-capacity query is implemented.
        guard bytes.count <= 1 * 1024 * 1024 else {
            throw AppError.message("ファームウェアが大きすぎる (\(bytes.count) bytes)。現在の安全上限は1 MiBである")
        }
        guard bytes.contains(where: { $0 != 0 && $0 != 0xFF }) else {
            throw AppError.message("ファームウェアが空、または全て0x00/0xFFである")
        }

        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return FirmwareImage(url: url, bytes: bytes, sha256: digest)
    }
}

private final class USBHandle {
    let raw: UnsafeMutableRawPointer
    let descriptor: USBDevice
    private var closed = false

    init?(vendorID: UInt16, productID: UInt16, seize: Bool = false) {
        let raw = seize
            ? lp_usb_open_seize(vendorID, productID)
            : lp_usb_open(vendorID, productID)
        guard let raw else { return nil }
        self.raw = raw
        self.descriptor = USBDevice(vendorID: vendorID, productID: productID)
    }

    func close() {
        guard !closed else { return }
        closed = true
        lp_usb_close(raw)
    }

    deinit { close() }

    func controlOut(
        requestType: UInt8,
        request: UInt8,
        value: UInt16 = 0,
        index: UInt16 = 0,
        data: Data = Data()
    ) throws {
        let result: Int32 = data.withUnsafeBytes { buffer in
            lp_usb_control_out(
                raw,
                requestType,
                request,
                value,
                index,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt16(data.count)
            )
        }
        try check(result, operation: String(format: "USB OUT 0x%02X", request))
    }

    func controlIn(
        requestType: UInt8,
        request: UInt8,
        value: UInt16 = 0,
        index: UInt16 = 0,
        length: Int
    ) throws -> Data {
        guard length >= 0 && length <= Int(UInt16.max) else {
            throw AppError.message("USB読み取り長が範囲外: \(length)")
        }
        var data = Data(repeating: 0, count: length)
        let result: Int32 = data.withUnsafeMutableBytes { buffer in
            lp_usb_control_in(
                raw,
                requestType,
                request,
                value,
                index,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt16(length)
            )
        }
        try check(result, operation: String(format: "USB IN 0x%02X", request))
        return data
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            let message = lp_usb_error_string(result).map { String(cString: $0) } ?? "unknown IOKit error"
            throw AppError.message("\(operation) failed (\(result)): \(message)")
        }
    }
}

private final class CT7601ISP {
    private let device: USBHandle
    private let controllerRequestTypeOut: UInt8 = 0x43
    private let controllerRequestTypeIn: UInt8 = 0xC3

    init(device: USBHandle) {
        self.device = device
    }

    func readJEDECID() throws -> [UInt8] {
        Array(try issueSPI(command: 0x9F, responseLength: 3))
    }

    func readPrefix(length: Int) throws -> Data {
        try readFlash(address: 0, length: length)
    }

    func readRange(address: Int, length: Int) throws -> Data {
        try readFlash(address: address, length: length)
    }

    func eraseAndProgram(_ image: FirmwareImage, progress: (Int, Int) -> Void) throws {
        let jedec = try readJEDECID()
        guard jedec.count == 3, !jedec.allSatisfy({ $0 == 0 || $0 == 0xFF }) else {
            throw AppError.message("SPIフラッシュのJEDEC IDを取得できない: \(hex(jedec))")
        }
        print("ISP device: \(device.descriptor), JEDEC ID: \(hex(jedec))")

        // The vendor tool uses 0x20-byte pages for C2/22 and 0x100 otherwise.
        let pageSize = jedec[0] == 0xC2 && jedec[1] == 0x22 ? 0x20 : 0x100
        print("書き込み単位: 0x\(String(pageSize, radix: 16)) bytes")

        // This is the sequence used by Comtrue's CT7601 ISP application.
        try spiWriteInstruction(0x06)       // Write Enable
        try spiWriteInstruction(0x01, payload: [0x00]) // clear status protection bits
        try waitControllerReady(timeout: 2.0)
        try waitFlashReady(timeout: 2.0)
        // Writing the status register clears WEL, so chip erase needs its own
        // Write Enable command.
        try spiWriteInstruction(0x06)       // Write Enable for Chip Erase
        try spiWriteInstruction(0xC7)       // Chip Erase
        print("フラッシュ消去中…")
        try waitControllerReady(timeout: 2.0)
        try waitFlashReady(timeout: 30.0)
        try verifyBlank(length: image.bytes.count)

        let totalPages = (image.bytes.count + pageSize - 1) / pageSize
        var pageNumber = 0
        var offset = 0
        while offset < image.bytes.count {
            let end = min(offset + pageSize, image.bytes.count)
            var chunk = Data(image.bytes[offset..<end])
            if chunk.count < pageSize {
                chunk.append(Data(repeating: 0xFF, count: pageSize - chunk.count))
            }

            // USB control completion only means that CT7601 accepted the
            // command. The SPI flash may still have WIP set, so mirror the
            // vendor tool and wait for the flash status before each page.
            try waitFlashReady(timeout: 2.0)
            if chunk.contains(where: { $0 != 0xFF }) {
                try spiWriteInstruction(0x06) // Write Enable before every page
                try programPage(address: offset, bytes: chunk)
                try waitControllerReady(timeout: 2.0)
                if ProcessInfo.processInfo.environment["LP_USB_LIVE_CHECK"] != nil,
                   offset == 0x40000 || offset == 0x63A00 {
                    try waitFlashReady(timeout: 2.0)
                    let live = try readRange(address: offset, length: min(0x80, chunk.count))
                    print(String(format: "直後読み戻し address=0x%X: %@", offset, hex(Array(live))))
                }
            }

            pageNumber += 1
            progress(pageNumber, totalPages)
            offset += pageSize
        }

        try waitFlashReady(timeout: 2.0)
        print("書き込み完了。検証中…")
        try verify(image)
    }

    private func programPage(address: Int, bytes: Data) throws {
        guard address <= 0xFFFFFF else {
            throw AppError.message(String(format: "フラッシュアドレスが24bit範囲外: 0x%X", address))
        }
        let header = Data([
            0x02,
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF)
        ])
        try device.controlOut(
            requestType: controllerRequestTypeOut,
            request: 0x80,
            index: 0,
            data: header
        )
        try device.controlOut(
            requestType: controllerRequestTypeOut,
            request: 0x80,
            value: UInt16(bytes.count),
            index: 1,
            data: bytes
        )
    }

    func verify(_ image: FirmwareImage) throws {
        let blockSize = 0x40
        var offset = 0
        while offset < image.bytes.count {
            let length = min(blockSize, image.bytes.count - offset)
            var actual = Data()
            var lastError: Error?
            for _ in 0..<3 {
                do {
                    actual = try readFlash(address: offset, length: length)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            if let lastError {
                throw lastError
            }
            let expected = Data(image.bytes[offset..<(offset + length)])
            guard actual == expected else {
                let mismatch = firstMismatch(expected: expected, actual: actual)
                let contextStart = max(0, mismatch - 4)
                let contextEnd = min(length, mismatch + 12)
                let expectedContext = hex(Array(expected[contextStart..<contextEnd]))
                let actualContext = hex(Array(actual[contextStart..<contextEnd]))
                throw AppError.message(String(format: "検証失敗: address 0x%X (offset +0x%X) expected=[%@] actual=[%@]", offset + mismatch, mismatch, expectedContext, actualContext))
            }
            offset += length
            if offset == image.bytes.count || offset % 0x1000 == 0 {
                print(String(format: "検証 %3d%%", (offset * 100) / image.bytes.count))
            }
        }
        print("Verifying Success")
    }

    func reportMismatches(_ image: FirmwareImage) throws {
        let blockSize = 0x40
        var offset = 0
        var mismatches: [(address: Int, expected: UInt8, actual: UInt8)] = []

        while offset < image.bytes.count {
            let length = min(blockSize, image.bytes.count - offset)
            let actual = try readFlash(address: offset, length: length)
            let expected = Data(image.bytes[offset..<(offset + length)])
            for index in 0..<length where actual[index] != expected[index] {
                mismatches.append((offset + index, expected[index], actual[index]))
            }
            offset += length
        }

        if mismatches.isEmpty {
            print("全バイト一致")
            return
        }

        print("不一致バイト数: \(mismatches.count)")
        var ranges: [(start: Int, end: Int, count: Int)] = []
        for mismatch in mismatches {
            if let last = ranges.last, mismatch.address == last.end + 1 {
                ranges[ranges.count - 1] = (last.start, mismatch.address, last.count + 1)
            } else {
                ranges.append((mismatch.address, mismatch.address, 1))
            }
        }
        print("不一致範囲数: \(ranges.count)")
        for range in ranges.prefix(32) {
            print(String(format: "range 0x%X-0x%X (%d bytes)", range.start, range.end, range.count))
        }
        if ranges.count > 32 {
            print("(先頭32範囲のみ表示)")
        }
        for mismatch in mismatches.prefix(64) {
            print(String(format: "address 0x%X expected=%02X actual=%02X", mismatch.address, mismatch.expected, mismatch.actual))
        }
        if mismatches.count > 64 {
            print("(先頭64件のみ表示)")
        }
    }

    private func verifyBlank(length: Int) throws {
        let blockSize = 0x40
        var offset = 0
        while offset < length {
            let blockLength = min(blockSize, length - offset)
            let actual = try readFlash(address: offset, length: blockLength)
            if let mismatch = actual.firstIndex(where: { $0 != 0xFF }) {
                throw AppError.message(String(format: "消去確認失敗: address 0x%X actual=%02X", offset + mismatch, actual[mismatch]))
            }
            offset += blockLength
        }
        print("Blanking Success")
    }

    private func readFlash(address: Int, length: Int) throws -> Data {
        let payload = Data([
            0x03,
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF)
        ])
        try device.controlOut(
            requestType: controllerRequestTypeOut,
            request: 0x81,
            value: UInt16(length),
            index: 1,
            data: payload
        )
        try waitControllerReady(timeout: 1.0)
        return try device.controlIn(
            requestType: controllerRequestTypeIn,
            request: 0x82,
            index: 0,
            length: length
        )
    }

    private func spiWriteInstruction(_ command: UInt8, payload: [UInt8] = []) throws {
        var bytes = Data([command])
        bytes.append(contentsOf: payload)
        try device.controlOut(
            requestType: controllerRequestTypeOut,
            request: 0x80,
            index: 1,
            data: bytes
        )
    }

    private func issueSPI(command: UInt8, responseLength: Int) throws -> Data {
        try device.controlOut(
            requestType: controllerRequestTypeOut,
            request: 0x81,
            value: UInt16(responseLength),
            index: 1,
            data: Data([command])
        )
        try waitControllerReady(timeout: 1.0)
        return try device.controlIn(
            requestType: controllerRequestTypeIn,
            request: 0x82,
            index: 0,
            length: responseLength
        )
    }

    private func readFlashStatus() throws -> UInt8 {
        let status = try issueSPI(command: 0x05, responseLength: 1)
        guard let value = status.first else {
            throw AppError.message("SPIフラッシュstatusの応答が空である")
        }
        return value
    }

    private func waitFlashReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastStatus: UInt8 = 0
        var lastError: Error?
        while Date() < deadline {
            do {
                lastStatus = try readFlashStatus()
                lastError = nil
                // SPI NOR status register bit 0 is WIP (write in progress).
                if (lastStatus & 0x01) == 0 {
                    return
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let lastError {
            throw lastError
        }
        throw AppError.message(String(format: "SPIフラッシュがreadyにならない (timeout %.1fs, status=0x%02X)", timeout, lastStatus))
    }

    private func waitControllerReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                let status = try device.controlIn(
                    requestType: controllerRequestTypeIn,
                    request: 0x83,
                    index: 0,
                    length: 1
                )
                if status.first != 0 {
                    return
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        if let lastError {
            throw lastError
        }
        throw AppError.message("CT7601がreadyにならない (timeout \(String(format: "%.1f", timeout))s)")
    }

    private func firstMismatch(expected: Data, actual: Data) -> Int {
        for index in 0..<min(expected.count, actual.count) where expected[index] != actual[index] {
            return index
        }
        return min(expected.count, actual.count)
    }
}

private let knownVendorIDs: [UInt16] = [0x2FC6, 0x0EA0]
private let bootloaderProductID: UInt16 = 0x6000
private let normalProductIDs: [UInt16] = [0xF82D, 0xF82E, 0x6002]

private func hex(_ values: [UInt8]) -> String {
    values.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func parseInteger(_ value: String) -> Int? {
    if value.lowercased().hasPrefix("0x") {
        return Int(value.dropFirst(2), radix: 16)
    }
    return Int(value)
}

private func allUSBDevices() throws -> [USBDevice] {
    let capacity = 256
    var buffer = Array(repeating: LPUSBDeviceInfo(), count: capacity)
    let result: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
        lp_usb_list(pointer.baseAddress, Int32(capacity))
    }
    guard result >= 0 else {
        throw AppError.message("USBデバイス一覧を取得できない: \(result)")
    }
    let count = min(Int(result), capacity)
    return buffer.prefix(count).map {
        USBDevice(vendorID: $0.vendor_id, productID: $0.product_id)
    }
}

private func printScan() throws {
    let devices = try allUSBDevices()
    let known = devices.filter { knownVendorIDs.contains($0.vendorID) }
    if known.isEmpty {
        print("L&P/Comtrue系USBデバイスは見つからない")
        print("W4EXを電源ONでUSB接続し、別のUSBケーブル／ポートも確認する")
        return
    }
    for device in known {
        let role: String
        if device.productID == bootloaderProductID {
            role = "ISP/bootloader候補"
        } else if normalProductIDs.contains(device.productID) {
            role = "通常FW候補"
        } else {
            role = "未確認PID"
        }
        print("\(device) — \(role)")
    }
}

private func openBootloader() -> USBHandle? {
    for vendorID in knownVendorIDs {
        if let handle = USBHandle(vendorID: vendorID, productID: bootloaderProductID) {
            return handle
        }
    }
    return nil
}

private func requestISPMode() throws -> USBHandle {
    for vendorID in knownVendorIDs {
        for productID in normalProductIDs {
            guard let handle = USBHandle(vendorID: vendorID, productID: productID, seize: true) else { continue }
            print("通常FWデバイス \(handle.descriptor) にISPモード移行を要求中…")
            do {
                // CT7601 vendor tool sends the mode request followed by a
                // three-request 0x90 arm sequence before closing the handle.
                // The latter was omitted in the first Mac implementation.
                try handle.controlOut(
                    requestType: 0x43,
                    request: 0x84,
                    value: 0x5354,
                    index: 0x2080
                )
                try handle.controlOut(requestType: 0x43, request: 0x90, index: 0, data: Data([0x0D]))
                try handle.controlOut(requestType: 0x43, request: 0x90, index: 7, data: Data([0x10]))
                try handle.controlOut(requestType: 0x43, request: 0x90, index: 1, data: Data([0x03]))
                print("ISP移行シーケンス送信完了。同じUSB接続で書き込みを開始する…")
                return handle
            } catch {
                handle.close()
                print("  \(error)")
            }
        }
    }
    throw AppError.message("通常FWデバイスを開けない。まず `scan` でPIDを確認する")
}

private func probeNormalFirmware() throws {
    for vendorID in knownVendorIDs {
        for productID in normalProductIDs {
            guard let handle = USBHandle(vendorID: vendorID, productID: productID) else { continue }
            defer { handle.close() }
            let isp = CT7601ISP(device: handle)
            let jedec = try isp.readJEDECID()
            print(String(format: "通常FW %@ でSPI JEDEC IDを取得: %@", handle.descriptor.description, hex(jedec)))
            let prefix = try isp.readPrefix(length: 16)
            print("フラッシュ先頭16 bytes: \(hex(Array(prefix)))")
            let sample = try isp.readRange(address: 0x4200, length: 0x40)
            print("フラッシュ0x4200-0x423F: \(hex(Array(sample)))")
            return
        }
    }
    throw AppError.message("通常FWデバイスを開けない。まず `scan` でPIDを確認する")
}

private func verifyNormalFirmware(_ image: FirmwareImage) throws {
    for vendorID in knownVendorIDs {
        for productID in normalProductIDs {
            guard let handle = USBHandle(vendorID: vendorID, productID: productID) else { continue }
            defer { handle.close() }
            print("通常FW \(handle.descriptor) を読み戻して検証中…")
            try CT7601ISP(device: handle).verify(image)
            return
        }
    }
    throw AppError.message("通常FWデバイスを開けない。まず `scan` でPIDを確認する")
}

private func readNormalFirmware(address: Int, length: Int) throws {
    guard address >= 0, address <= 0xFFFFFF, length > 0, length <= 0x1000 else {
        throw AppError.message("read-normalの範囲が不正（addressは24bit、lengthは1..0x1000）")
    }
    for vendorID in knownVendorIDs {
        for productID in normalProductIDs {
            guard let handle = USBHandle(vendorID: vendorID, productID: productID) else { continue }
            defer { handle.close() }
            let data = try CT7601ISP(device: handle).readRange(address: address, length: length)
            print(String(format: "通常FW %@ address=0x%X length=0x%X", handle.descriptor.description, address, length))
            print(hex(Array(data)))
            return
        }
    }
    throw AppError.message("通常FWデバイスを開けない。まず `scan` でPIDを確認する")
}

private func usage() {
    print("""
    Usage:
      lpw4ex-updater scan
      lpw4ex-updater probe-normal
      lpw4ex-updater verify-normal <official-W4-firmware.bin>
      lpw4ex-updater diff-normal <official-W4-firmware.bin>
      lpw4ex-updater read-normal <hex-address> <hex-length>
      lpw4ex-updater inspect <official-W4-firmware.bin>
      lpw4ex-updater update <official-W4-firmware.bin> --model W4EX --accept-unverified-w4ex-firmware --yes

    update is intentionally explicit because a failed firmware write can brick the device.
    """)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        usage()
        return
    }

    switch command {
    case "scan":
        try printScan()

    case "probe-normal":
        try probeNormalFirmware()

    case "inspect":
        guard arguments.count >= 2 else { throw AppError.message("inspectには .bin のパスが必要") }
        let image = try FirmwareImage.load(path: arguments[1])
        print("file: \(image.url.path)")
        print("size: \(image.bytes.count) bytes (\(String(format: "%.1f", Double(image.bytes.count) / 1024.0)) KiB)")
        print("sha256: \(image.sha256)")
        print("先頭16 bytes: \(hex(Array(image.bytes.prefix(16))))")

    case "verify-normal":
        guard arguments.count >= 2 else { throw AppError.message("verify-normalには .bin のパスが必要") }
        let image = try FirmwareImage.load(path: arguments[1])
        try verifyNormalFirmware(image)

    case "diff-normal":
        guard arguments.count >= 2 else { throw AppError.message("diff-normalには .bin のパスが必要") }
        let image = try FirmwareImage.load(path: arguments[1])
        for vendorID in knownVendorIDs {
            for productID in normalProductIDs {
                guard let handle = USBHandle(vendorID: vendorID, productID: productID) else { continue }
                defer { handle.close() }
                print("通常FW \(handle.descriptor) を全領域読み戻し中…")
                try CT7601ISP(device: handle).reportMismatches(image)
                return
            }
        }
        throw AppError.message("通常FWデバイスを開けない。まず `scan` でPIDを確認する")

    case "read-normal":
        guard arguments.count >= 3,
              let address = parseInteger(arguments[1]),
              let length = parseInteger(arguments[2]) else {
            throw AppError.message("read-normalにはaddressとlengthが必要（例: read-normal 0x40000 0x80）")
        }
        try readNormalFirmware(address: address, length: length)

    case "update":
        guard arguments.count >= 2 else { throw AppError.message("updateには .bin のパスが必要") }
        guard arguments.contains("--yes") else {
            throw AppError.message("安全確認のため `update <file.bin> --yes` のように --yes を付ける必要がある")
        }
        guard let modelIndex = arguments.firstIndex(of: "--model"),
              modelIndex + 1 < arguments.count,
              arguments[modelIndex + 1].uppercased() == "W4EX" else {
            throw AppError.message("機種を自動判定できないため、`--model W4EX` を明示する必要がある")
        }
        guard arguments.contains("--accept-unverified-w4ex-firmware") else {
            throw AppError.message("W4シリーズ用ファイルがW4EX対応か未確認である。公式確認後に `--accept-unverified-w4ex-firmware` を付ける")
        }

        let image = try FirmwareImage.load(path: arguments[1])
        print("対象: \(image.url.lastPathComponent)")
        print("サイズ: \(image.bytes.count) bytes")
        print("SHA-256: \(image.sha256)")
        print("機種指定: W4EX（USB descriptorだけでは機種を検証できない）")
        print("警告: W4EX適合性未確認ファイルの実行を明示的に受諾した")
        print("電源断・USB抜去・スリープは禁止。続行するには --yes が必要である。")

        let bootloader: USBHandle
        if let existingBootloader = openBootloader() {
            bootloader = existingBootloader
        } else {
            bootloader = try requestISPMode()
        }
        defer { bootloader.close() }

        let isp = CT7601ISP(device: bootloader)
        try isp.eraseAndProgram(image) { completed, total in
            if completed == total || completed % max(1, total / 20) == 0 {
                print(String(format: "書き込み %3d%%", (completed * 100) / total))
            }
        }
        print("更新処理は完了。W4系の手順に従い、USBを一度抜いて再接続する。")

    case "help", "-h", "--help":
        usage()

    default:
        usage()
        throw AppError.message("未知のコマンド: \(command)")
    }
}

do {
    try run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
