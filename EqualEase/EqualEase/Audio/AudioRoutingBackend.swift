//
//  AudioRoutingBackend.swift
//  EqualEase
//

import Combine

enum AudioOutputTransport: Equatable {
    case builtIn
    case bluetooth
    case display
    case usb
    case airPlay
    case aggregate
    case virtual
    case other
}

struct AudioOutputDevice: Identifiable, Equatable {
    var id: String { uid }
    var uid: String
    var name: String
    var transport: AudioOutputTransport?

    var iconSystemName: String {
        switch transport {
        case .builtIn:
            "speaker.wave.2.fill"
        case .bluetooth:
            "headphones"
        case .display:
            "display"
        case .usb:
            "cable.connector"
        case .airPlay:
            "airplayaudio"
        case .aggregate, .virtual:
            "waveform"
        case .other, nil:
            fallbackIconSystemName
        }
    }

    static func fallbackIconSystemName(forName name: String) -> String {
        let normalizedName = name.localizedLowercase
        if normalizedName.contains("airpods") {
            return "airpodspro"
        }
        if normalizedName.contains("headphone") || normalizedName.contains("bluetooth") {
            return "headphones"
        }
        if normalizedName.contains("display") || normalizedName.contains("hdmi") || normalizedName.contains("monitor") {
            return "display"
        }
        if normalizedName.contains("usb") || normalizedName.contains("dock") {
            return "cable.connector"
        }
        return "speaker.wave.2.fill"
    }

    private var fallbackIconSystemName: String {
        Self.fallbackIconSystemName(forName: name)
    }
}

@MainActor
enum AudioRoutingState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}

@MainActor
protocol AudioRoutingBackend: ObservableObject {
    var state: AudioRoutingState { get }
    var statusText: String { get }
    var outputDeviceName: String { get }
    var outputDeviceUID: String? { get }
    var outputDevices: [AudioOutputDevice] { get }
    var selectedOutputDeviceUID: String? { get set }
    var followsSystemOutput: Bool { get set }
    var isRunning: Bool { get }
    var isRoutingTransitioning: Bool { get }
    var isBypassed: Bool { get set }
    var outputVolume: Double { get set }
    var canSetOutputVolume: Bool { get }
    var outputGain: Double { get set }
    var equalizerEnabled: Bool { get set }
    var bandGains: [Double] { get set }

    func setBandGain(_ gain: Double, at index: Int)
    func selectOutputDevice(uid: String?)
    func start()
    func stop()
    func restart()
    func cleanupAudioState()
}
