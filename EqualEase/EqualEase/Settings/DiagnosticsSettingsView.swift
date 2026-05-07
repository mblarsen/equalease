//
//  DiagnosticsSettingsView.swift
//  EqualEase
//

import SwiftUI

struct DiagnosticsSettingsView: View {
    @ObservedObject var router: CoreAudioRouter
    @ObservedObject var inputDeviceController: InputDeviceController

    var body: some View {
        Form {
            Section("Routing status") {
                LabeledContent("State") {
                    Label(statusTitle, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                }
                LabeledContent("Message", value: router.statusText)
                LabeledContent("Selected output", value: router.outputDeviceName)
                LabeledContent("Follow system output", value: router.followsSystemOutput ? "On" : "Off")
            }

            Section("Input") {
                LabeledContent("Current input", value: inputDeviceController.inputDeviceName)
                LabeledContent("Input volume", value: inputDeviceController.inputVolumeSummary)
                LabeledContent("Volume control", value: inputDeviceController.inputVolumeCapabilitySummary)

                Text("EqualEase shows input state for convenience only. Input-device selection, microphone routing, and microphone EQ are intentionally out of scope.")
                    .foregroundStyle(.secondary)
            }

            Section("Low Microphone Volume Protection") {
                LabeledContent("State") {
                    Label(inputDeviceController.isInputVolumeLow ? "Low" : "OK", systemImage: inputDeviceController.isInputVolumeLow ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(inputDeviceController.isInputVolumeLow ? .orange : .green)
                }
                LabeledContent("Status", value: inputDeviceController.lowVolumeProtectionStatus)
                LabeledContent("Threshold", value: "\(Int(inputDeviceController.protectionSettings.threshold * 100))%")
                LabeledContent("Minimum cap", value: inputDeviceController.protectionSettings.capEnabled ? "\(Int(inputDeviceController.protectionSettings.capMinimum * 100))%" : "Off")
                LabeledContent("Notifications", value: inputDeviceController.protectionSettings.notificationsEnabled ? inputDeviceController.notificationAuthorizationStatus.summary : "Off")
                LabeledContent("Last notification", value: inputDeviceController.lastLowVolumeNotificationSummary)
                LabeledContent("Last cap attempt", value: inputDeviceController.lastCapAttemptSummary)

                Text("Protection keeps running even when EqualEase Active is off because it observes the macOS input-volume property, not the system-audio routing path.")
                    .foregroundStyle(.secondary)
            }

            Section("DSP bypass") {
                Toggle("Bypass EQ processing", isOn: $router.isBypassed)
                    .disabled(!router.isRunning || router.isRoutingTransitioning)

                Text("Diagnostic control only: audio still routes through EqualEase while this is on. Use the main Active toggle to turn EqualEase off completely.")
                    .foregroundStyle(.secondary)
            }

            Section("Recovery") {
                HStack {
                    Button(router.isRunning ? "Stop Routing" : "Start Routing") {
                        if router.isRunning {
                            router.stop()
                        } else {
                            router.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(router.isRoutingTransitioning)

                    Button("Restart") {
                        router.restart()
                    }
                    .disabled(!router.isRunning || router.isRoutingTransitioning)

                    Button("Cleanup Audio State") {
                        router.cleanupAudioState()
                    }
                }

                Text("If development audio gets stuck silent, stop routing and clean up EqualEase-owned Core Audio taps and aggregate devices.")
                    .foregroundStyle(.secondary)
            }

            Section("Available outputs") {
                ForEach(router.outputDevices) { device in
                    HStack(spacing: 12) {
                        DeviceIconView(systemName: device.iconSystemName)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(device.name)
                                Spacer()
                                if device.uid == router.outputDeviceUID {
                                    Label("Current", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(device.uid)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680, alignment: .leading)
        .onAppear {
            inputDeviceController.refreshInputDevice()
        }
    }

    private var statusTitle: String {
        if router.isRunning && router.isBypassed {
            return "DSP bypassed"
        }

        return switch router.state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    private var statusIcon: String {
        if router.isRunning && router.isBypassed {
            return "pause.circle.fill"
        }

        return switch router.state {
        case .stopped: "stop.circle"
        case .starting: "hourglass"
        case .running: "waveform.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if router.isRunning && router.isBypassed {
            return .orange
        }

        return switch router.state {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }
}

#Preview {
    DiagnosticsSettingsView(router: CoreAudioRouter(), inputDeviceController: InputDeviceController())
        .padding()
}
