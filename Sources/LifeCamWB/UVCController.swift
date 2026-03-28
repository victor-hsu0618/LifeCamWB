import Foundation
import CoreMediaIO

// MARK: - Camera control model

struct CameraControl: Identifiable {
    let id: CMIOObjectID
    let name: String
    var value: Double
    let min: Double
    let max: Double
    var isAuto: Bool
    let hasAuto: Bool
    let isDiscrete: Bool   // true → show as picker/buttons
}

@MainActor
final class UVCController: ObservableObject {

    @Published var isConnected = false
    @Published var autoWB = true
    @Published var temperature: Double = 5500
    @Published var minTemp: Double = 2500
    @Published var maxTemp: Double = 10000
    @Published var statusMessage = "Not connected"
    @Published var cameraControls: [CameraControl] = []

    private var wbControlID:       CMIOObjectID = .zero
    private var exposureCtrlID:    CMIOObjectID = .zero  // ucea — NativeData uint32 LE
    private var zoomCtrlID:        CMIOObjectID = .zero  // ucza — NativeData uint16 LE
    private var focusCtrlID:       CMIOObjectID = .zero  // ucfa — NativeData uint16 LE
    private var deviceID:          CMIOObjectID = .zero

    private let defaults = UserDefaults.standard

    // MARK: - Public API

    func connect() {
        guard let devID = findLifeCam() else {
            let n = Int(getPropertySize(CMIOObjectID(kCMIOObjectSystemObject),
                kCMIOHardwarePropertyDevices)) / MemoryLayout<CMIOObjectID>.size
            statusMessage = "LifeCam not found (\(n) CMIO devices seen)"
            isConnected = false
            return
        }
        guard let ctrlID = findWBControl(device: devID) else {
            statusMessage = "No WB control found on device"
            isConnected = false
            return
        }
        wbControlID    = ctrlID
        exposureCtrlID = findNDCtrl(device: devID, cls: 0x75636561, minBytes: 4) // ucea
        zoomCtrlID     = findNDCtrl(device: devID, cls: 0x7563_7A61, minBytes: 2) // ucza
        focusCtrlID    = findNDCtrl(device: devID, cls: 0x75636661, minBytes: 2) // ucfa
        deviceID       = devID
        isConnected    = true
        statusMessage  = "Connected"
        fetchCurrentValues()
        findCameraControls(device: devID)
        restoreSettings()   // apply saved values after controls are discovered
    }

    func disconnect() {
        wbControlID    = .zero
        exposureCtrlID = .zero
        zoomCtrlID     = .zero
        focusCtrlID    = .zero
        deviceID       = .zero
        isConnected    = false
        cameraControls = []
        statusMessage  = "Disconnected"
    }

    func fetchCurrentValues() {
        guard isConnected else { return }
        if let av = getAutoManual() { autoWB = av != 0 }
        if let k  = getTemp()       { temperature = Double(k) }
        let (lo, hi) = getRange()
        if lo > 0 { minTemp = Double(lo) }
        if hi > 0 { maxTemp = Double(hi) }
    }

    func applyAutoWB(_ enable: Bool) {
        guard isConnected else { return }
        autoWB = enable
        setProperty(wbControlID, kCMIOFeatureControlPropertyAutomaticManual, value: UInt32(enable ? 1 : 0))
        statusMessage = enable ? "Auto WB on" : "Auto WB off"
        if !enable, let k = getTemp() { temperature = Double(k) }
        saveSettings()
    }

    func applyTemperature(_ k: Double) {
        guard isConnected else { return }
        temperature = k
        setProperty(wbControlID, kCMIOFeatureControlPropertyAutomaticManual, value: UInt32(0))
        setNDU16(wbControlID, UInt16(k))
        statusMessage = String(format: "WB %.0f K", k)
        saveSettings()
    }

    func applyControl(id: CMIOObjectID, value: Double) {
        // Exposure: write via ucea NativeData (4-byte LE uint32) — xpsr NativeValue is ignored
        if let idx = cameraControls.firstIndex(where: { $0.id == id }),
           cameraControls[idx].name == "Exposure",
           exposureCtrlID != .zero {
            let sz = getPropertySize(exposureCtrlID, kCMIOFeatureControlPropertyNativeData)
            if sz >= 4 {
                var a   = addr(kCMIOFeatureControlPropertyNativeData)
                var buf = [UInt8](repeating: 0, count: Int(sz))
                let v   = UInt32(max(1, value))
                buf[0]  = UInt8(v & 0xFF)
                buf[1]  = UInt8((v >> 8) & 0xFF)
                buf[2]  = UInt8((v >> 16) & 0xFF)
                buf[3]  = UInt8((v >> 24) & 0xFF)
                CMIOObjectSetPropertyData(exposureCtrlID, &a, 0, nil, sz, &buf)
            }
            cameraControls[idx].value = value
            return
        }
        // Zoom: write via ucza NativeData (uint16 LE)
        if let idx = cameraControls.firstIndex(where: { $0.id == id }),
           cameraControls[idx].name == "Zoom",
           zoomCtrlID != .zero {
            let v = UInt16(max(0, min(65535, value)))
            let sz = getPropertySize(zoomCtrlID, kCMIOFeatureControlPropertyNativeData)
            if sz >= 2 {
                var a = addr(kCMIOFeatureControlPropertyNativeData)
                var buf = [UInt8](repeating: 0, count: Int(sz))
                buf[0] = UInt8(v & 0xFF); buf[1] = UInt8(v >> 8)
                CMIOObjectSetPropertyData(zoomCtrlID, &a, 0, nil, sz, &buf)
            }
            cameraControls[idx].value = value
            return
        }
        // Focus: write via ucfa NativeData (uint16 LE)
        if let idx = cameraControls.firstIndex(where: { $0.id == id }),
           cameraControls[idx].name == "Focus",
           focusCtrlID != .zero {
            let v = UInt16(max(0, min(65535, value)))
            let sz = getPropertySize(focusCtrlID, kCMIOFeatureControlPropertyNativeData)
            if sz >= 2 {
                var a = addr(kCMIOFeatureControlPropertyNativeData)
                var buf = [UInt8](repeating: 0, count: Int(sz))
                buf[0] = UInt8(v & 0xFF); buf[1] = UInt8(v >> 8)
                CMIOObjectSetPropertyData(focusCtrlID, &a, 0, nil, sz, &buf)
            }
            cameraControls[idx].value = value
            return
        }
        // If this is the ucbt (Brightness) control, write via NativeData byte
        if let idx = cameraControls.firstIndex(where: { $0.id == id }),
           cameraControls[idx].name == "Brightness" {
            let sz = getPropertySize(id, kCMIOFeatureControlPropertyNativeData)
            if sz >= 1 {
                var a   = addr(kCMIOFeatureControlPropertyNativeData)
                var buf = [UInt8](repeating: 0, count: Int(sz))
                buf[0]  = UInt8(clamping: Int(value))
                CMIOObjectSetPropertyData(id, &a, 0, nil, sz, &buf)
            }
            cameraControls[idx].value = value
            return
        }
        let v = Float32(value)
        setProperty(id, kCMIOFeatureControlPropertyNativeValue, value: v)
        if let idx = cameraControls.firstIndex(where: { $0.id == id }) {
            cameraControls[idx].value = value
        }
        saveSettings()
    }

    func setControlAuto(id: CMIOObjectID, enable: Bool) {
        // For Focus/Zoom, also toggle the uc* NativeData control's AutoManual if it has one
        if let idx = cameraControls.firstIndex(where: { $0.id == id }) {
            let ndCtrl: CMIOObjectID
            switch cameraControls[idx].name {
            case "Focus": ndCtrl = focusCtrlID
            case "Zoom":  ndCtrl = zoomCtrlID
            default:      ndCtrl = .zero
            }
            if ndCtrl != .zero && hasProperty(ndCtrl, kCMIOFeatureControlPropertyAutomaticManual) {
                setProperty(ndCtrl, kCMIOFeatureControlPropertyAutomaticManual, value: UInt32(enable ? 1 : 0))
            }
        }
        setProperty(id, kCMIOFeatureControlPropertyAutomaticManual, value: UInt32(enable ? 1 : 0))
        if let idx = cameraControls.firstIndex(where: { $0.id == id }) {
            cameraControls[idx].isAuto = enable
            if !enable, let fv: Float32 = getProperty(id,
                kCMIOFeatureControlPropertyNativeValue, Float32.self) {
                cameraControls[idx].value = Double(fv)
            }
        }
        saveSettings()
    }

    // Generic: find a NativeData control by FourCC class ID
    private func findNDCtrl(device: CMIOObjectID, cls targetCls: CMIOClassID, minBytes: UInt32) -> CMIOObjectID {
        let size = getPropertySize(device, kCMIOObjectPropertyOwnedObjects)
        guard size > 0 else { return .zero }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var children = [CMIOObjectID](repeating: 0, count: count)
        var a = addr(kCMIOObjectPropertyOwnedObjects); var got = size
        CMIOObjectGetPropertyData(device, &a, 0, nil, size, &got, &children)
        for ctrlID in children.prefix(count) {
            guard let cls: CMIOClassID = getProperty(ctrlID, kCMIOObjectPropertyClass, CMIOClassID.self),
                  cls == targetCls,
                  hasProperty(ctrlID, kCMIOFeatureControlPropertyNativeData),
                  getPropertySize(ctrlID, kCMIOFeatureControlPropertyNativeData) >= minBytes else { continue }
            return ctrlID
        }
        return .zero
    }

    // MARK: - Settings persistence

    private func saveSettings() {
        defaults.set(autoWB,      forKey: "lc_wb_auto")
        defaults.set(temperature, forKey: "lc_wb_temp")
        for ctrl in cameraControls {
            defaults.set(ctrl.value,  forKey: "lc_\(ctrl.name)_value")
            if ctrl.hasAuto {
                defaults.set(ctrl.isAuto, forKey: "lc_\(ctrl.name)_auto")
            }
        }
    }

    private func restoreSettings() {
        // WB
        if defaults.object(forKey: "lc_wb_auto") != nil {
            let savedAuto = defaults.bool(forKey: "lc_wb_auto")
            if savedAuto {
                applyAutoWB(true)
            } else if let savedTemp = defaults.object(forKey: "lc_wb_temp") as? Double {
                applyTemperature(savedTemp)
            }
        }
        // Image controls
        for ctrl in cameraControls {
            let autoKey  = "lc_\(ctrl.name)_auto"
            let valueKey = "lc_\(ctrl.name)_value"
            if ctrl.hasAuto, defaults.object(forKey: autoKey) != nil {
                let savedAuto = defaults.bool(forKey: autoKey)
                setControlAuto(id: ctrl.id, enable: savedAuto)
                if !savedAuto, let v = defaults.object(forKey: valueKey) as? Double {
                    applyControl(id: ctrl.id, value: v)
                }
            } else if defaults.object(forKey: valueKey) != nil {
                let v = defaults.double(forKey: valueKey)
                applyControl(id: ctrl.id, value: v)
            }
        }
        statusMessage = "Connected (settings restored)"
        NotificationCenter.default.post(name: .lcSettingsRestored, object: nil)
    }

    // MARK: - Camera control discovery

    // (FourCC, name, isDiscrete, workingAuto)
    // workingAuto: tested on hardware — camera firmware actually self-corrects when auto is re-enabled.
    // Contrast/Sharpness/Saturation/Backlight: CMIO has AutoManual property but camera ignores it.
    // Focus: auto works via ucfa (NativeData control), toggled in setControlAuto.
    private let knownControls: [(cls: CMIOClassID, name: String, discrete: Bool, workingAuto: Bool)] = [
        (0x78707372, "Exposure",         false, true),   // xpsr  — auto works
        (0x6761696E, "Gain",             false, false),  // gain
        (0x63747374, "Contrast",         false, false),  // ctst  — auto no effect on hardware
        (0x68756520, "Hue",              false, false),  // hue
        (0x73617475, "Saturation",       false, false),  // satu  — auto no effect on hardware
        (0x73687270, "Sharpness",        false, false),  // shrp  — auto no effect on hardware
        (0x676D6D61, "Gamma",            false, false),  // gmma
        (0x626B6C74, "Backlight Comp",   false, false),  // bklt  — auto no effect on hardware
        (0x66637573, "Focus",            false, true),   // fcus  — auto via ucfa works
        (0x70776671, "Power Line Freq",  true,  false),  // pwfq  0=off 1=50Hz 2=60Hz
    ]

    // 'ucbt' (0x75636274) — UVC Brightness via NativeData (1-byte value in [30,255])
    private let ucbtClass: CMIOClassID = 0x75636274

    private func findCameraControls(device: CMIOObjectID) {
        let size = getPropertySize(device, kCMIOObjectPropertyOwnedObjects)
        guard size > 0 else { return }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var children = [CMIOObjectID](repeating: 0, count: count)
        var a = addr(kCMIOObjectPropertyOwnedObjects)
        var got = size
        CMIOObjectGetPropertyData(device, &a, 0, nil, size, &got, &children)

        var controls: [CameraControl] = []
        for (targetCls, name, discrete, workingAuto) in knownControls {
            for ctrlID in children.prefix(count) {
                guard let cls: CMIOClassID = getProperty(ctrlID, kCMIOObjectPropertyClass, CMIOClassID.self),
                      cls == targetCls else { continue }
                guard let fv: Float32 = getProperty(ctrlID,
                    kCMIOFeatureControlPropertyNativeValue, Float32.self) else { break }
                let (lo, hi) = nativeRange(ctrlID)
                let value = Double(fv)
                if !discrete {
                    guard hi > lo else { break }
                    let span = hi - lo
                    guard value >= lo - span && value <= hi + span else { break }
                }
                let hasAuto = workingAuto && hasProperty(ctrlID, kCMIOFeatureControlPropertyAutomaticManual)
                let isAuto  = hasAuto &&
                    (getProperty(ctrlID, kCMIOFeatureControlPropertyAutomaticManual, UInt32.self) ?? 0) != 0
                let effLo = discrete ? 0.0 : lo
                let effHi = discrete ? max(3.0, hi) : hi
                controls.append(CameraControl(
                    id: ctrlID, name: name,
                    value: Swift.min(effHi, Swift.max(effLo, value)),
                    min: effLo, max: effHi,
                    isAuto: isAuto, hasAuto: hasAuto, isDiscrete: discrete))
                break
            }
        }
        // Brightness via 'ucbt' NativeData — NativeValue on LifeCam is broken
        for ctrlID in children.prefix(count) {
            guard let cls: CMIOClassID = getProperty(ctrlID, kCMIOObjectPropertyClass, CMIOClassID.self),
                  cls == ucbtClass else { continue }
            guard hasProperty(ctrlID, kCMIOFeatureControlPropertyNativeData) else { break }
            let sz = getPropertySize(ctrlID, kCMIOFeatureControlPropertyNativeData)
            guard sz >= 1 else { break }
            var a   = addr(kCMIOFeatureControlPropertyNativeData)
            var buf = [UInt8](repeating: 0, count: Int(sz))
            var got = sz
            guard CMIOObjectGetPropertyData(ctrlID, &a, 0, nil, sz, &got, &buf) == 0 else { break }
            let value = Double(buf[0])  // first byte is the actual brightness
            controls.insert(CameraControl(
                id: ctrlID, name: "Brightness",
                value: value, min: 30, max: 255,
                isAuto: false, hasAuto: false, isDiscrete: false), at: 0)
            break
        }

        cameraControls = controls
    }

    private func nativeRange(_ ctrl: CMIOObjectID) -> (Double, Double) {
        guard hasProperty(ctrl, kCMIOFeatureControlPropertyNativeRange) else { return (0, 0) }
        var a    = addr(kCMIOFeatureControlPropertyNativeRange)
        var pair = (Double(0), Double(0))
        var got  = UInt32(MemoryLayout<(Double, Double)>.size)
        guard CMIOObjectGetPropertyData(ctrl, &a, 0, nil, got, &got, &pair) == 0 else { return (0, 0) }
        return pair
    }

    // MARK: - CMIO helpers

    private func addr(_ sel: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(bitPattern: Int32(truncatingIfNeeded: sel)),
            mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func hasProperty(_ obj: CMIOObjectID, _ sel: Int) -> Bool {
        var a = addr(sel); return CMIOObjectHasProperty(obj, &a)
    }

    private func getProperty<T>(_ obj: CMIOObjectID, _ sel: Int, _ type: T.Type) -> T? {
        var a    = addr(sel)
        var size = UInt32(MemoryLayout<T>.size)
        var buf  = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        let st   = buf.withUnsafeMutableBytes { raw in
            CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &size, raw.baseAddress!)
        }
        guard st == 0 else { return nil }
        return buf.withUnsafeBytes { $0.load(as: T.self) }
    }

    private func setProperty<T>(_ obj: CMIOObjectID, _ sel: Int, value: T) {
        var a = addr(sel); var v = value
        CMIOObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    private func getPropertySize(_ obj: CMIOObjectID, _ sel: Int) -> UInt32 {
        var a = addr(sel); var size = UInt32(0)
        CMIOObjectGetPropertyDataSize(obj, &a, 0, nil, &size); return size
    }

    private func getNDU16(_ ctrl: CMIOObjectID) -> UInt16? {
        guard hasProperty(ctrl, kCMIOFeatureControlPropertyNativeData) else { return nil }
        let size = getPropertySize(ctrl, kCMIOFeatureControlPropertyNativeData)
        guard size >= 2 else { return nil }
        var a = addr(kCMIOFeatureControlPropertyNativeData)
        var buf = [UInt8](repeating: 0, count: Int(size)); var got = size
        guard CMIOObjectGetPropertyData(ctrl, &a, 0, nil, size, &got, &buf) == 0 else { return nil }
        return UInt16(buf[0]) | (UInt16(buf[1]) << 8)
    }

    private func setNDU16(_ ctrl: CMIOObjectID, _ val: UInt16) {
        guard hasProperty(ctrl, kCMIOFeatureControlPropertyNativeData) else { return }
        let size = getPropertySize(ctrl, kCMIOFeatureControlPropertyNativeData)
        guard size >= 2 else { return }
        var a = addr(kCMIOFeatureControlPropertyNativeData)
        var buf = [UInt8](repeating: 0, count: Int(size))
        buf[0] = UInt8(val & 0xFF); buf[1] = UInt8(val >> 8)
        CMIOObjectSetPropertyData(ctrl, &a, 0, nil, size, &buf)
    }

    // MARK: - Device / WB discovery

    private func findLifeCam() -> CMIOObjectID? {
        let sysObj  = CMIOObjectID(kCMIOObjectSystemObject)
        let size    = getPropertySize(sysObj, kCMIOHardwarePropertyDevices)
        guard size > 0 else { return nil }
        let count   = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var a = addr(kCMIOHardwarePropertyDevices); var got = size
        CMIOObjectGetPropertyData(sysObj, &a, 0, nil, size, &got, &devices)
        for devID in devices {
            var nameRef: CFString? = nil
            var na = addr(kCMIOObjectPropertyName)
            var ns = UInt32(MemoryLayout<CFString?>.size)
            CMIOObjectGetPropertyData(devID, &na, 0, nil, ns, &ns, &nameRef)
            guard let name = nameRef as String? else { continue }
            if name.localizedCaseInsensitiveContains("LifeCam") { return devID }
        }
        return nil
    }

    private func findWBControl(device: CMIOObjectID) -> CMIOObjectID? {
        let size = getPropertySize(device, kCMIOObjectPropertyOwnedObjects)
        guard size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var children = [CMIOObjectID](repeating: 0, count: count)
        var a = addr(kCMIOObjectPropertyOwnedObjects); var got = size
        CMIOObjectGetPropertyData(device, &a, 0, nil, size, &got, &children)
        var fallback: CMIOObjectID? = nil
        for ctrlID in children {
            guard let cls: CMIOClassID = getProperty(ctrlID, kCMIOObjectPropertyClass, CMIOClassID.self) else { continue }
            let isUCWT = cls == CMIOClassID(UInt32(exactly: 0x75637774)!)
            let isTemp = cls == CMIOClassID(kCMIOTemperatureControlClassID)
            if isUCWT {
                if let k = getNDU16(ctrlID), k >= 2000 && k <= 10000 { return ctrlID }
                return ctrlID
            }
            if isTemp && fallback == nil { fallback = ctrlID }
        }
        return fallback
    }

    // MARK: - WB reads

    private func getAutoManual() -> UInt32? {
        getProperty(wbControlID, kCMIOFeatureControlPropertyAutomaticManual, UInt32.self)
    }
    private func getTemp() -> UInt16? {
        if let k = getNDU16(wbControlID), k >= 2000 && k <= 10000 { return k }
        if let fv: Float32 = getProperty(wbControlID,
            kCMIOFeatureControlPropertyNativeValue, Float32.self),
           fv >= 2000 && fv <= 10000 { return UInt16(fv) }
        return nil
    }
    private func getRange() -> (UInt16, UInt16) {
        if hasProperty(wbControlID, kCMIOFeatureControlPropertyNativeDataRange) {
            let sz = getPropertySize(wbControlID, kCMIOFeatureControlPropertyNativeDataRange)
            if sz >= 4 {
                var a = addr(kCMIOFeatureControlPropertyNativeDataRange)
                var buf = [UInt8](repeating: 0, count: Int(sz)); var got = sz
                if CMIOObjectGetPropertyData(wbControlID, &a, 0, nil, sz, &got, &buf) == 0 {
                    let lo = UInt16(buf[0]) | (UInt16(buf[1]) << 8)
                    let hi = UInt16(buf[Int(sz/2)]) | (UInt16(buf[Int(sz/2)+1]) << 8)
                    if lo > 0 || hi > 0 { return (lo, hi) }
                }
            }
        }
        if hasProperty(wbControlID, kCMIOFeatureControlPropertyNativeRange) {
            var a = addr(kCMIOFeatureControlPropertyNativeRange)
            var pair = (Double(0), Double(0)); var got = UInt32(MemoryLayout<(Double, Double)>.size)
            if CMIOObjectGetPropertyData(wbControlID, &a, 0, nil, got, &got, &pair) == 0 {
                return (UInt16(pair.0), UInt16(pair.1))
            }
        }
        return (2500, 10000)
    }
}

extension Notification.Name {
    static let lcSettingsRestored = Notification.Name("lcSettingsRestored")
}
