import CoreAudio
import Testing
@testable import eqYourMacbook

/// Tests for OutputDeviceCatalog's pure filterAndSort policy — no CoreAudio calls
/// involved, just plain RawDeviceInfo input/output.
@Suite struct OutputDeviceCatalogTests {

    private let outputTransport: UInt32 = kAudioDeviceTransportTypeUSB
    private let builtInTransport: UInt32 = kAudioDeviceTransportTypeBuiltIn
    private let aggregateTransport: UInt32 = kAudioDeviceTransportTypeAggregate

    @Test func builtInSortsFirstEvenIfListedLater() {
        let usb = RawDeviceInfo(id: 1, uid: "usb", name: "USB Speakers",
                                transportType: outputTransport, hasOutputStreams: true)
        let builtIn = RawDeviceInfo(id: 2, uid: "builtin", name: "MacBook Speakers",
                                    transportType: builtInTransport, hasOutputStreams: true)
        let result = OutputDeviceCatalog.filterAndSort([usb, builtIn])
        #expect(result.map(\.id) == [2, 1])
        #expect(result[0].isBuiltIn)
    }

    @Test func aggregateTransportDevicesAreExcluded() {
        let aggregate = RawDeviceInfo(id: 3, uid: "agg", name: "Private Aggregate",
                                      transportType: aggregateTransport, hasOutputStreams: true)
        let usb = RawDeviceInfo(id: 1, uid: "usb", name: "USB Speakers",
                                transportType: outputTransport, hasOutputStreams: true)
        let result = OutputDeviceCatalog.filterAndSort([aggregate, usb])
        #expect(result.map(\.id) == [1])
    }

    @Test func devicesWithoutOutputStreamsAreExcluded() {
        let inputOnly = RawDeviceInfo(id: 4, uid: "mic", name: "Built-in Mic",
                                      transportType: builtInTransport, hasOutputStreams: false)
        let usb = RawDeviceInfo(id: 1, uid: "usb", name: "USB Speakers",
                                transportType: outputTransport, hasOutputStreams: true)
        let result = OutputDeviceCatalog.filterAndSort([inputOnly, usb])
        #expect(result.map(\.id) == [1])
    }

    @Test func nonBuiltInOrderIsPreservedFromInput() {
        let usb = RawDeviceInfo(id: 1, uid: "usb", name: "USB Speakers",
                                transportType: outputTransport, hasOutputStreams: true)
        let bt = RawDeviceInfo(id: 2, uid: "bt", name: "Bluetooth Headphones",
                               transportType: kAudioDeviceTransportTypeBluetooth, hasOutputStreams: true)
        let hdmi = RawDeviceInfo(id: 3, uid: "hdmi", name: "HDMI Display",
                                 transportType: kAudioDeviceTransportTypeDisplayPort, hasOutputStreams: true)
        let result = OutputDeviceCatalog.filterAndSort([usb, bt, hdmi])
        #expect(result.map(\.id) == [1, 2, 3])
    }
}
