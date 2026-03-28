import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var uvc    = UVCController()

    var body: some View {
        HStack(spacing: 0) {
            cameraPreview
            controlPanel
        }
        .onChange(of: camera.permissionGranted) { granted in
            if granted && !uvc.isConnected { uvc.connect() }
        }
        .onAppear {
            if camera.permissionGranted { uvc.connect() }
        }
    }

    private var cameraPreview: some View {
        ZStack {
            Color.black
            if camera.permissionGranted {
                CameraPreview(layer: camera.previewLayer)
            } else {
                Text(camera.errorMessage ?? "Requesting camera permission…")
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .aspectRatio(16/9, contentMode: .fit)
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Camera") {
                        Picker("", selection: $camera.selectedDevice) {
                            ForEach(camera.availableDevices, id: \.uniqueID) { d in
                                Text(d.localizedName).tag(Optional(d))
                            }
                        }
                        .labelsHidden()
                    }
                    WBGroupBox(uvc: uvc)
                    if uvc.isConnected && !uvc.cameraControls.isEmpty {
                        CameraControlsBox(uvc: uvc)
                    }
                }
                .padding(16)
            }
            Divider()
            StartupBox()
                .padding(12)
            Text("LifeCamWB v1.2")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }
}

// MARK: - White Balance

private struct WBGroupBox: View {
    @ObservedObject var uvc: UVCController

    private let presets: [(String, Double)] = [
        ("Candle", 1850), ("Tungsten", 2800), ("Fluorescent", 4000),
        ("Daylight", 5500), ("Cloudy", 6500), ("Shade", 7500),
    ]

    var body: some View {
        GroupBox("White Balance (UVC)") {
            VStack(alignment: .leading, spacing: 12) {
                connectionRow
                if uvc.isConnected {
                    Divider()
                    Toggle("Auto White Balance", isOn: Binding(
                        get: { uvc.autoWB },
                        set: { uvc.applyAutoWB($0) }
                    ))
                    tempSlider
                    presetsGrid
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var connectionRow: some View {
        HStack {
            Circle().fill(uvc.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(uvc.statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(uvc.isConnected ? "Disconnect" : "Connect") {
                uvc.isConnected ? uvc.disconnect() : uvc.connect()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var tempSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Temperature").font(.subheadline)
                Spacer()
                Text(String(format: "%.0f K", uvc.temperature))
                    .monospacedDigit().font(.subheadline)
                    .foregroundStyle(uvc.autoWB ? .secondary : .primary)
            }
            Slider(value: Binding(get: { uvc.temperature }, set: { uvc.applyTemperature($0) }),
                   in: uvc.minTemp...uvc.maxTemp, step: 50)
                .disabled(uvc.autoWB)
            HStack {
                Text(String(format: "%.0fK", uvc.minTemp))
                Spacer()
                Text(String(format: "%.0fK", uvc.maxTemp))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var presetsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))], spacing: 6) {
                ForEach(presets, id: \.0) { name, k in
                    Button(action: {
                        if uvc.autoWB { uvc.applyAutoWB(false) }
                        uvc.applyTemperature(k)
                    }) {
                        VStack(spacing: 2) {
                            Text(name).font(.caption)
                            Text("\(Int(k))K").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(abs(uvc.temperature - k) < 25 ? .accentColor : nil)
                    .disabled(uvc.autoWB)
                }
            }
        }
    }
}

// MARK: - Image Controls

private struct CameraControlsBox: View {
    @ObservedObject var uvc: UVCController

    var body: some View {
        GroupBox("Image Controls") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach($uvc.cameraControls) { $ctrl in
                    if ctrl.isDiscrete {
                        PowerLineRow(ctrl: $ctrl, uvc: uvc)
                    } else {
                        ControlRow(ctrl: $ctrl, uvc: uvc)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct ControlRow: View {
    @Binding var ctrl: CameraControl
    let uvc: UVCController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ctrl.name).font(.subheadline)
                Spacer()
                if ctrl.hasAuto {
                    Toggle("Auto", isOn: Binding(
                        get: { ctrl.isAuto },
                        set: { uvc.setControlAuto(id: ctrl.id, enable: $0) }
                    ))
                    .toggleStyle(.button).controlSize(.mini)
                }
                Text(formatValue(ctrl.value, min: ctrl.min, max: ctrl.max))
                    .monospacedDigit().font(.subheadline)
                    .foregroundStyle(ctrl.isAuto ? .secondary : .primary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { ctrl.value },
                set: { uvc.applyControl(id: ctrl.id, value: $0) }
            ), in: ctrl.min...ctrl.max)
            .disabled(ctrl.isAuto)
            HStack {
                Text(formatValue(ctrl.min, min: ctrl.min, max: ctrl.max))
                Spacer()
                Text(formatValue(ctrl.max, min: ctrl.min, max: ctrl.max))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func formatValue(_ v: Double, min: Double, max: Double) -> String {
        (max - min) >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }
}

private struct PowerLineRow: View {
    @Binding var ctrl: CameraControl
    let uvc: UVCController

    private let options: [(String, Double)] = [("Off", 0), ("50 Hz", 1), ("60 Hz", 2)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ctrl.name).font(.subheadline)
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { label, val in
                    Button(label) {
                        uvc.applyControl(id: ctrl.id, value: val)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(abs(ctrl.value - val) < 0.5 ? .accentColor : nil)
                }
            }
        }
    }
}

// MARK: - Startup Settings

private struct StartupBox: View {
    @AppStorage("lc_minimizeOnConnect") private var minimizeOnConnect = false
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        LoginItem.setEnabled(enabled)
                        if enabled { minimizeOnConnect = true }
                    }
                Toggle("Minimize after connect", isOn: $minimizeOnConnect)
                    .foregroundStyle(launchAtLogin ? .primary : .secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview {
    ContentView().frame(width: 940, height: 600)
}
