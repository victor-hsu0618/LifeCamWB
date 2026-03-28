import AVFoundation
import Combine

@MainActor
final class CameraManager: ObservableObject {

    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var availableDevices: [AVCaptureDevice] = []
    @Published var selectedDevice: AVCaptureDevice? {
        didSet { guard oldValue?.uniqueID != selectedDevice?.uniqueID else { return }
                 Task { await switchDevice(to: selectedDevice) } }
    }
    @Published var permissionGranted = false
    @Published var errorMessage: String?

    private let session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    // AVFoundation requires startRunning/stopRunning on a dedicated serial queue
    private let sessionQueue = DispatchQueue(label: "com.local.LifeCamWB.session",
                                             qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []

    init() {
        Task { await setup() }
    }

    private func setup() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permissionGranted = granted
        guard granted else {
            errorMessage = "Camera access denied. Enable it in System Settings → Privacy & Security."
            return
        }

        refreshDevices()

        let lifecam = availableDevices.first {
            $0.localizedName.localizedCaseInsensitiveContains("LifeCam")
        }
        // Set selectedDevice — didSet skips if uniqueID unchanged, so set nil first
        selectedDevice = lifecam ?? availableDevices.first

        registerObservers()
    }

    private func registerObservers() {
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.errorMessage = "Camera disconnected"
            }
        })

        observers.append(nc.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.errorMessage = nil
                let sess = self.session
                let q    = self.sessionQueue
                q.async { if !sess.isRunning { sess.startRunning() } }
            }
        })

        observers.append(nc.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshDevices()
                let d = self.availableDevices.first(where: {
                    $0.localizedName.localizedCaseInsensitiveContains("LifeCam")
                }) ?? self.availableDevices.first
                await self.switchDevice(to: d)
            }
        })
    }

    func refreshDevices() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices
    }

    private func switchDevice(to device: AVCaptureDevice?) async {
        guard let device else { return }

        session.beginConfiguration()
        if let old = currentInput { session.removeInput(old) }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            } else {
                errorMessage = "Cannot add input for \(device.localizedName)"
                session.commitConfiguration()
                return
            }
        } catch {
            errorMessage = "Cannot open \(device.localizedName): \(error.localizedDescription)"
            session.commitConfiguration()
            return
        }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .hd1280x720
        }
        session.commitConfiguration()

        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspect
            previewLayer = layer
        }

        if !session.isRunning {
            let sess = session
            let q    = sessionQueue
            q.async { sess.startRunning() }
        }
    }

    deinit {
        let sess = session
        let q    = sessionQueue
        q.async { sess.stopRunning() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
