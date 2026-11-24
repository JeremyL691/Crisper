import XCTest

final class SystemMonitorModelsTests: XCTestCase {
    // MARK: - RingBuffer

    func testRingBufferAppendsAndWrapsInFIFOOrder() {
        var ring = RingBuffer<Int>(capacity: 4)
        XCTAssertEqual(ring.capacity, 4)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.elements, [])

        ring.append(1)
        ring.append(2)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring.elements, [1, 2])

        ring.append(3)
        ring.append(4)
        XCTAssertEqual(ring.elements, [1, 2, 3, 4])

        ring.append(5)
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.elements, [2, 3, 4, 5])

        ring.append(6)
        ring.append(7)
        ring.append(8)
        ring.append(9)
        XCTAssertEqual(ring.elements, [6, 7, 8, 9])

        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.elements, [])
    }

    func testRingBufferClampsNonPositiveCapacityAndEquatesByLogicalOrder() {
        var tiny = RingBuffer<String>(capacity: 0)
        XCTAssertEqual(tiny.capacity, 1)
        tiny.append("a")
        tiny.append("b")
        XCTAssertEqual(tiny.elements, ["b"])

        var rotated = RingBuffer<Int>(capacity: 3)
        rotated.append(0)
        rotated.append(1)
        rotated.append(2)
        rotated.append(3) // [1, 2, 3] with head == 1

        var linear = RingBuffer<Int>(capacity: 3)
        linear.append(1)
        linear.append(2)
        linear.append(3) // [1, 2, 3] with head == 0

        XCTAssertEqual(rotated, linear)
    }

    // MARK: - CPUSample & GPUSample

    func testCPUSampleTickDeltaCalculationAndClamping() {
        XCTAssertEqual(CPUSample.zero, CPUSample(user: 0, system: 0, idle: 100, temperatureC: nil))

        let sample = CPUSample.fromTickDeltas(
            user: 20,
            nice: 5,
            system: 15,
            idle: 60,
            temperatureC: 51.4
        )
        XCTAssertEqual(sample.user, 25.0, accuracy: 0.001)
        XCTAssertEqual(sample.system, 15.0, accuracy: 0.001)
        XCTAssertEqual(sample.idle, 60.0, accuracy: 0.001)
        XCTAssertEqual(sample.temperatureC ?? 0, 51.4, accuracy: 0.001)

        let zeroTicks = CPUSample.fromTickDeltas(user: 0, nice: 0, system: 0, idle: 0, temperatureC: 45.0)
        XCTAssertEqual(zeroTicks.user, 0)
        XCTAssertEqual(zeroTicks.system, 0)
        XCTAssertEqual(zeroTicks.idle, 100)
        XCTAssertEqual(zeroTicks.temperatureC, 45.0)

        let clamped = CPUSample(user: -10, system: 150, idle: .nan, temperatureC: .infinity)
        XCTAssertEqual(clamped.user, 0)
        XCTAssertEqual(clamped.system, 100)
        XCTAssertEqual(clamped.idle, 0)
        XCTAssertNil(clamped.temperatureC)
    }

    func testGPUSampleClampingAndZero() {
        XCTAssertEqual(GPUSample.zero, GPUSample(device: 0, render: 0, tiler: 0))

        let clamped = GPUSample(device: 120, render: -5, tiler: .nan)
        XCTAssertEqual(clamped.device, 100)
        XCTAssertEqual(clamped.render, 0)
        XCTAssertEqual(clamped.tiler, 0)
    }

    // MARK: - VolumeInfo, DiskSnapshot & RAMSnapshot

    func testVolumeAndDiskSnapshotFractionsAndEmpty() {
        XCTAssertEqual(DiskSnapshot.empty.usedBytes, 0)
        XCTAssertEqual(DiskSnapshot.empty.availableBytes, 0)
        XCTAssertEqual(DiskSnapshot.empty.usedFraction, 0)
        XCTAssertTrue(DiskSnapshot.empty.volumes.isEmpty)

        XCTAssertEqual(VolumeInfo.clampedFraction(usedBytes: 0, totalBytes: 0), 0)
        XCTAssertEqual(VolumeInfo.clampedFraction(usedBytes: 250, totalBytes: 1000), 0.25, accuracy: 0.0001)
        XCTAssertEqual(VolumeInfo.clampedFraction(usedBytes: 1500, totalBytes: 1000), 1.0, accuracy: 0.0001)

        let volume = VolumeInfo(
            id: "/",
            name: "Macintosh HD",
            mountPath: "/",
            fileSystem: "APFS",
            usedBytes: 110_000_000_000,
            totalBytes: 500_000_000_000,
            isInternal: true,
            usedFraction: 0.22
        )
        XCTAssertEqual(volume.availableBytes, 390_000_000_000)

        let overused = VolumeInfo(
            id: "/Volumes/Full",
            name: "Full",
            mountPath: "/Volumes/Full",
            fileSystem: "APFS",
            usedBytes: 600,
            totalBytes: 500,
            isInternal: false,
            usedFraction: 1.0
        )
        XCTAssertEqual(overused.availableBytes, 0)

        let disk = DiskSnapshot(
            name: "Macintosh HD",
            usedBytes: 109_210_000_000,
            totalBytes: 494_380_000_000,
            readBytesPerSec: 0,
            writeBytesPerSec: 0,
            temperatureC: 29.0,
            volumes: [volume],
            usedFraction: 0.22
        )
        XCTAssertEqual(disk.availableBytes, 385_170_000_000)
    }

    func testRAMSnapshotFromVMPageCountsMatchesActivityMonitorFormula() {
        XCTAssertEqual(RAMSnapshot.empty.usedBytes, 0)
        XCTAssertEqual(RAMSnapshot.empty.totalBytes, 0)

        let pageSize: UInt64 = 16_384
        let totalBytes: UInt64 = 18 * 1_073_741_824 // 18 GiB

        // gross = 200k + 100k + 10k + 80k + 50k = 440k pages
        // deduct = 20k + 120k = 140k pages
        // used = 300k pages = 300_000 * 16_384 = 4_915_200_000 bytes
        let counts = VMPageCounts(
            totalBytes: totalBytes,
            pageSize: pageSize,
            activePages: 200_000,
            inactivePages: 100_000,
            speculativePages: 10_000,
            wiredPages: 80_000,
            compressedPages: 50_000,
            purgeablePages: 20_000,
            externalPages: 120_000,
            pressureLevel: 1
        )
        let ram = RAMSnapshot.from(vmCounts: counts)

        XCTAssertEqual(ram.totalBytes, totalBytes)
        XCTAssertEqual(ram.usedBytes, 300_000 * pageSize)
        XCTAssertEqual(ram.wiredBytes, 80_000 * pageSize)
        XCTAssertEqual(ram.compressedBytes, 50_000 * pageSize)
        XCTAssertEqual(ram.cachedBytes, 140_000 * pageSize)
        XCTAssertEqual(ram.appBytes, 170_000 * pageSize)
        XCTAssertEqual(ram.pressureLevel, 1)
        XCTAssertEqual(ram.usedFraction, Double(300_000 * pageSize) / Double(totalBytes), accuracy: 0.0001)
    }

    func testRAMSnapshotPreventsUnderflowWhenDeductionsExceedGross() {
        let counts = VMPageCounts(
            totalBytes: 8 * 1_073_741_824,
            pageSize: 4096,
            activePages: 10,
            inactivePages: 10,
            speculativePages: 0,
            wiredPages: 10,
            compressedPages: 0,
            purgeablePages: 100,
            externalPages: 100,
            pressureLevel: 0
        )
        let ram = RAMSnapshot.from(vmCounts: counts)
        XCTAssertEqual(ram.usedBytes, 0)
        XCTAssertEqual(ram.appBytes, 0)
        XCTAssertEqual(ram.usedFraction, 0)
    }

    // MARK: - ByteRateFormatter

    func testByteRateFormatterDecimalGB() {
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(0), "0 B")
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(512), "512 B")
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(12_000), "12 KB")
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(250_000_000), "250.0 MB")
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(109_210_000_000), "109.21 GB")
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(494_380_000_000), "494.38 GB")
        XCTAssertEqual(ByteRateFormatter.formatDecimalGB(2_000_000_000_000), "2.00 TB")
    }

    func testByteRateFormatterBinaryGB() {
        XCTAssertEqual(ByteRateFormatter.formatBinaryGB(0), "0.0 GB")
        XCTAssertEqual(ByteRateFormatter.formatBinaryGB(512), "512 B")
        XCTAssertEqual(ByteRateFormatter.formatBinaryGB(512 * 1_024), "512 KB")
        XCTAssertEqual(ByteRateFormatter.formatBinaryGB(512 * 1_048_576), "512 MB")
        XCTAssertEqual(ByteRateFormatter.formatBinaryGB(UInt64(3.2 * 1_073_741_824.0)), "3.2 GB")
        XCTAssertEqual(ByteRateFormatter.formatBinaryGB(18 * 1_073_741_824), "18.0 GB")
    }

    func testByteRateFormatterSpeed() {
        XCTAssertEqual(ByteRateFormatter.formatSpeed(0), "0 B/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(-100), "0 B/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(.nan), "0 B/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(.infinity), "0 B/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(512), "512 B/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(688_000), "688 KB/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(12_400_000), "12.4 MB/s")
        XCTAssertEqual(ByteRateFormatter.formatSpeed(1_500_000_000), "1.50 GB/s")
    }

    // MARK: - SMCTemperatureCodec

    func testSMCTemperatureCodecFourCCAndDecoders() {
        let code = SMCTemperatureCodec.fourCC(from: "Tp04")
        XCTAssertNotNil(code)
        XCTAssertEqual(SMCTemperatureCodec.string(fromFourCC: code ?? 0), "Tp04")
        XCTAssertNil(SMCTemperatureCodec.fourCC(from: "TOO_LONG"))
        XCTAssertNil(SMCTemperatureCodec.fourCC(from: "T0"))

        // IEEE 754 float32 little-endian for 49.8°C
        let floatBits = Float32(49.8).bitPattern
        let fltBytes: [UInt8] = [
            UInt8(floatBits & 0xFF),
            UInt8((floatBits >> 8) & 0xFF),
            UInt8((floatBits >> 16) & 0xFF),
            UInt8((floatBits >> 24) & 0xFF)
        ]
        let decodedFloat = SMCTemperatureCodec.decode(
            dataType: SMCTemperatureCodec.typeFLT,
            dataSize: 4,
            bytes: fltBytes
        )
        XCTAssertNotNil(decodedFloat)
        XCTAssertEqual(decodedFloat ?? 0, 49.8, accuracy: 0.01)

        // sp78 big-endian signed 8.8 fixed-point: 52.5°C = 0x3480
        let decodedSP78 = SMCTemperatureCodec.decode(
            dataType: SMCTemperatureCodec.typeSP78,
            dataSize: 2,
            bytes: [0x34, 0x80]
        )
        XCTAssertNotNil(decodedSP78)
        XCTAssertEqual(decodedSP78 ?? 0, 52.5, accuracy: 0.001)

        // Negative sp78: -1.0°C = 0xFF00
        let negativeSP78 = SMCTemperatureCodec.decode(
            dataType: SMCTemperatureCodec.typeSP78,
            dataSize: 2,
            bytes: [0xFF, 0x00]
        )
        XCTAssertEqual(negativeSP78 ?? 0, -1.0, accuracy: 0.001)

        XCTAssertTrue(SMCTemperatureCodec.isValidTemperature(15.0))
        XCTAssertTrue(SMCTemperatureCodec.isValidTemperature(49.8))
        XCTAssertTrue(SMCTemperatureCodec.isValidTemperature(115.0))
        XCTAssertFalse(SMCTemperatureCodec.isValidTemperature(14.9))
        XCTAssertFalse(SMCTemperatureCodec.isValidTemperature(115.1))
        XCTAssertFalse(SMCTemperatureCodec.isValidTemperature(.nan))
    }
}
