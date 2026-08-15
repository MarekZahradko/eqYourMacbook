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

    // MARK: - shouldPublishDeviceListChange (handleDevicesChanged's dedup policy,
    // extracted to be testable without CoreAudio — see OutputDeviceCatalog.swift)

    private func device(_ id: AudioObjectID, _ uid: String, name: String = "Device",
                        isBuiltIn: Bool = false) -> OutputDeviceInfo {
        OutputDeviceInfo(id: id, uid: uid, name: name, isBuiltIn: isBuiltIn)
    }

    @Test func identicalDeviceListsDoNotPublishAChange() {
        let list = [device(1, "a"), device(2, "b")]
        #expect(!OutputDeviceCatalog.shouldPublishDeviceListChange(from: list, to: list))
    }

    @Test func bothEmptyListsDoNotPublishAChange() {
        #expect(!OutputDeviceCatalog.shouldPublishDeviceListChange(from: [], to: []))
    }

    @Test func anAddedDevicePublishesAChange() {
        let old = [device(1, "a")]
        let new = [device(1, "a"), device(2, "b")]
        #expect(OutputDeviceCatalog.shouldPublishDeviceListChange(from: old, to: new))
    }

    @Test func aRemovedDevicePublishesAChange() {
        let old = [device(1, "a"), device(2, "b")]
        let new = [device(1, "a")]
        #expect(OutputDeviceCatalog.shouldPublishDeviceListChange(from: old, to: new))
    }

    /// Same devices, same content, but reordered: OutputDeviceInfo array equality is
    /// order-sensitive, so this counts as a change (matters here since filterAndSort's
    /// built-in-first ordering is meaningful UI ordering, not an incidental artifact).
    @Test func sameDevicesReorderedPublishesAChange() {
        let old = [device(1, "a"), device(2, "b")]
        let new = [device(2, "b"), device(1, "a")]
        #expect(OutputDeviceCatalog.shouldPublishDeviceListChange(from: old, to: new))
    }

    /// A field-level change (e.g. a Bluetooth device's user-visible name changing)
    /// on an otherwise-identical device list still counts as a change, since
    /// OutputDeviceInfo's synthesized Equatable compares every field.
    @Test func sameIDsDifferentNamePublishesAChange() {
        let old = [device(1, "a", name: "Old Name")]
        let new = [device(1, "a", name: "New Name")]
        #expect(OutputDeviceCatalog.shouldPublishDeviceListChange(from: old, to: new))
    }
}
