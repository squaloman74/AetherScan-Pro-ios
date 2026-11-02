import Flutter
import UIKit
import AVFoundation
import CommonCrypto
import CoreMotion

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate, FlutterStreamHandler {

  private let channelName       = "com.aetherscan.pro/audio"
  private let sensorChannelName = "com.aetherscan.pro/sensors"
  private let licenseKey        = "aetherscan_pro_license"
  private let synth             = AVSpeechSynthesizer()
  private var audioPlayer       : AVAudioPlayer?
  private var creepyPlayer      : AVAudioPlayer?
  private var channelRegistered = false

  // Sensori
  private let motionManager     = CMMotionManager()
  private var sensorEventSink   : FlutterEventSink?
  private var lastProximityNear = false
  private var emfBaseline       : Double = -1
  private var emfSpikeActive    = false

  // Rilevamento tocco / sfioramento (anti-falsi positivi impugnatura)
  private var lastGravityX: Double = 0.0
  private var lastGravityY: Double = 0.0
  private var lastGravityZ: Double = -1.0
  private var lastTouchTriggerTime: TimeInterval = 0

  private func log(_ msg: String) { NSLog("[AETHER] %@", msg) }

  // ──────────────────────────────────────────────────────────────────
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    synth.delegate = self
    UIApplication.shared.isIdleTimerDisabled = true
    setupAudioSession()

    registerChannel()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onAppBecameActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    return result
  }

  @objc private func onAppBecameActive() { registerChannel() }

  // ──────────────────────────────────────────────────────────────────
  private func registerChannel() {
    guard !channelRegistered else { return }

    var flutterVC: FlutterViewController?

    if let vc = window?.rootViewController as? FlutterViewController {
      flutterVC = vc
    } else {
      for scene in UIApplication.shared.connectedScenes {
        guard let ws = scene as? UIWindowScene,
              ws.activationState == .foregroundActive,
              let vc = ws.windows.first?.rootViewController as? FlutterViewController
        else { continue }
        flutterVC = vc
        break
      }
    }

    guard let vc = flutterVC else {
      log("window non ancora pronta - attendo didBecomeActive")
      return
    }

    channelRegistered = true
    log("MethodChannel + EventChannel registrati")

    // ── MethodChannel ──
    let ch = FlutterMethodChannel(name: channelName, binaryMessenger: vc.binaryMessenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {

      case "getDeviceHwid":
        result(self.computeHwid())

      case "getSavedLicense":
        let v = UserDefaults.standard.string(forKey: self.licenseKey) ?? ""
        self.log("getSavedLicense -> \(v.isEmpty ? "VUOTA" : "OK (\(v.count) chars)")")
        result(v)

      case "saveLicense":
        let k = (call.arguments as? [String: Any])?["licenseKey"] as? String ?? ""
        UserDefaults.standard.set(k, forKey: self.licenseKey)
        UserDefaults.standard.synchronize()
        self.log("saveLicense -> \(k.count) chars salvati")
        result(true)

      case "speak":
        let args = call.arguments as? [String: Any]
        let text   = args?["text"] as? String ?? ""
        let vol    = (args?["volume"] as? Double).map { Float($0) } ?? 1.0
        let gender = args?["gender"] as? String ?? "female"
        self.log("speak -> \"\(text)\" gender=\(gender)")
        self.speak(text: text, vol: vol, gender: gender)
        result(true)

      case "playBeep":
        let args = call.arguments as? [String: Any]
        let hz = args?["freq"] as? Int ?? 880
        let ms = args?["durationMs"] as? Int ?? 100
        self.playTone(hz: hz, ms: ms)
        result(true)

      case "playChime":
        self.playChime()
        result(true)

      case "playProximityAlert":
        self.playProximityAlert()
        result(true)

      case "playEmfAlert":
        self.playEmfAlert()
        result(true)

      case "playCreepyLaugh":
        self.playCreepyLaugh()
        result(true)

      case "setWakeLock":
        let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
        result(true)

      case "openUrl":
        guard let s = (call.arguments as? [String: Any])?["url"] as? String,
              let u = URL(string: s) else { result(false); return }
        DispatchQueue.main.async { UIApplication.shared.open(u) }
        result(true)

      case "audioDiagnostic":
        result(self.buildDiagnostic())

      case "startStatic", "stopStatic":
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ── EventChannel (sensori) ──
    let sensorCh = FlutterEventChannel(name: sensorChannelName, binaryMessenger: vc.binaryMessenger)
    sensorCh.setStreamHandler(self)
  }

  // ──────────────────────────────────────────────────────────────────
  // FlutterStreamHandler
  // ──────────────────────────────────────────────────────────────────
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sensorEventSink = events
    startProximitySensor()
    startMagnetometer()
    startAccelerometer()
    log("Sensori avviati: prossimita + EMF + tocco (accelerometro)")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopSensors()
    sensorEventSink = nil
    log("Sensori fermati")
    return nil
  }

  // ──────────────────────────────────────────────────────────────────
  // Sensore di Prossimita (Anteriore)
  // ──────────────────────────────────────────────────────────────────
  private func startProximitySensor() {
    UIDevice.current.isProximityMonitoringEnabled = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(proximityChanged),
      name: UIDevice.proximityStateDidChangeNotification,
      object: nil
    )
  }

  @objc private func proximityChanged() {
    let near = UIDevice.current.proximityState
    guard near != lastProximityNear else { return }
    lastProximityNear = near
    log("Prossimita: \(near ? "VICINO" : "LONTANO")")
    DispatchQueue.main.async {
      self.sensorEventSink?(["type": "proximity", "near": near])
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Sensore Accelerometro (Rilevamento Tocco / Contatto Posteriore e Frontale)
  // ──────────────────────────────────────────────────────────────────
  private func startAccelerometer() {
    guard motionManager.isAccelerometerAvailable else {
      log("Accelerometro non disponibile")
      return
    }
    motionManager.accelerometerUpdateInterval = 0.05 // 20 Hz
    motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let data = data else { return }
      let alpha = 0.85
      self.lastGravityX = alpha * self.lastGravityX + (1.0 - alpha) * data.acceleration.x
      self.lastGravityY = alpha * self.lastGravityY + (1.0 - alpha) * data.acceleration.y
      self.lastGravityZ = alpha * self.lastGravityZ + (1.0 - alpha) * data.acceleration.z

      let linearX = data.acceleration.x - self.lastGravityX
      let linearY = data.acceleration.y - self.lastGravityY
      let linearZ = data.acceleration.z - self.lastGravityZ
      let impulse = sqrt(linearX*linearX + linearY*linearY + linearZ*linearZ)

      // Soglia: 0.35 g (tocchetto secco/sfioramento, ma ignora movimento lento della mano)
      let now = Date().timeIntervalSince1970
      if impulse > 0.35 && (now - self.lastTouchTriggerTime > 5.0) {
        self.lastTouchTriggerTime = now
        self.log("TOUCH RILEVATO impulse=\(impulse)")
        self.sensorEventSink?(["type": "touch", "intensity": impulse])
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Magnetometro EMF
  // ──────────────────────────────────────────────────────────────────
  private func startMagnetometer() {
    guard motionManager.isMagnetometerAvailable else {
      log("Magnetometro non disponibile")
      return
    }
    motionManager.magnetometerUpdateInterval = 0.4
    motionManager.startMagnetometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let data = data else { return }
      let x = data.magneticField.x
      let y = data.magneticField.y
      let z = data.magneticField.z
      let magnitude = sqrt(x*x + y*y + z*z)

      if self.emfBaseline < 0 {
        self.emfBaseline = magnitude
        return
      }

      let delta = abs(magnitude - self.emfBaseline)
      let spikeThreshold = 25.0

      let isSpike: Bool
      if delta > spikeThreshold && !self.emfSpikeActive {
        self.emfSpikeActive = true
        isSpike = true
        self.log("EMF SPIKE: \(String(format: "%.1f", delta)) uT sopra baseline")
      } else if delta <= spikeThreshold * 0.5 {
        self.emfSpikeActive = false
        isSpike = false
      } else {
        isSpike = false
      }

      self.emfBaseline = self.emfBaseline * 0.98 + magnitude * 0.02
      self.sensorEventSink?(["type": "emf", "value": magnitude, "delta": delta, "spike": isSpike])
    }
  }

  private func stopSensors() {
    UIDevice.current.isProximityMonitoringEnabled = false
    NotificationCenter.default.removeObserver(self, name: UIDevice.proximityStateDidChangeNotification, object: nil)
    motionManager.stopMagnetometerUpdates()
    motionManager.stopAccelerometerUpdates()
  }

  // ──────────────────────────────────────────────────────────────────
  // Audio Session
  // ──────────────────────────────────────────────────────────────────
  private func setupAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
      log("AudioSession .playback attiva")
    } catch {
      log("AudioSession errore: \(error.localizedDescription)")
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // TTS
  // ──────────────────────────────────────────────────────────────────
  private func speak(text: String, vol: Float, gender: String = "female") {
    try? AVAudioSession.sharedInstance().setActive(true)
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

    let utt = AVSpeechUtterance(string: text)
    let voices = AVSpeechSynthesisVoice.speechVoices()

    let wantedGender: AVSpeechSynthesisVoiceGender = gender == "male" ? .male : .female
    if let v = voices.first(where: { $0.language == "it-IT" && $0.gender == wantedGender }) {
      utt.voice = v; log("TTS voce: \(v.name) [\(gender)]")
    } else if let v = voices.first(where: { $0.language == "it-IT" }) {
      utt.voice = v; log("TTS voce fallback it-IT: \(v.name)")
    } else if let v = voices.first(where: { $0.language.hasPrefix("en") && $0.gender == wantedGender }) {
      utt.voice = v; log("TTS fallback en [\(gender)]: \(v.name)")
    } else if let v = voices.first(where: { $0.language.hasPrefix("en") }) {
      utt.voice = v; log("TTS fallback en: \(v.name)")
    } else {
      log("TTS: nessuna voce specifica, uso sistema")
    }
    utt.rate            = AVSpeechUtteranceDefaultSpeechRate * 0.85
    utt.pitchMultiplier = gender == "male" ? 0.80 : 1.10
    utt.volume          = max(0.1, min(1.0, vol))
    synth.speak(utt)
    log("TTS speak() eseguito, isSpeaking=\(synth.isSpeaking)")
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart _: AVSpeechUtterance)  { log("TTS STARTED") }
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) { log("TTS FINISHED") }
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) { log("TTS CANCELLED") }

  // ──────────────────────────────────────────────────────────────────
  // Diagnostica
  // ──────────────────────────────────────────────────────────────────
  private func buildDiagnostic() -> String {
    let session = AVAudioSession.sharedInstance()
    let route   = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
    let voci    = AVSpeechSynthesisVoice.speechVoices()
                    .filter { $0.language.hasPrefix("it") }
                    .map { $0.name }.joined(separator: ", ")
    let saved   = UserDefaults.standard.string(forKey: licenseKey) ?? ""
    let report  = """
=== DIAGNOSTICA AETHERSCAN ===
Channel registrato: \(channelRegistered)
Audio categoria: \(session.category.rawValue)
Audio output: \(route.isEmpty ? "NESSUNO" : route)
Volume sistema: \(session.outputVolume)
Voci IT installate: \(voci.isEmpty ? "NESSUNA" : voci)
TTS in corso: \(synth.isSpeaking)
Licenza salvata: \(saved.isEmpty ? "NO" : "SI (\(saved.count) chars)")
Magnetometro (EMF): \(motionManager.isMagnetometerActive ? "ATTIVO" : "INATTIVO")
Sensore Tocco (Accel): \(motionManager.isAccelerometerActive ? "ATTIVO" : "INATTIVO")
EMF baseline: \(String(format: "%.1f", emfBaseline)) uT
"""
    log(report)
    return report
  }

  // ──────────────────────────────────────────────────────────────────
  // HWID
  // ──────────────────────────────────────────────────────────────────
  private func computeHwid() -> String {
    let raw = "IOS:\(UIDevice.current.identifierForVendor?.uuidString ?? "UNKNOWN")"
    guard let data = raw.data(using: .utf8) else { return String(repeating: "0", count: 32) }
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // ──────────────────────────────────────────────────────────────────
  // Riproduzione Suono Risata Inquietante (Creepy Laugh)
  // ──────────────────────────────────────────────────────────────────
  private func playCreepyLaugh() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      try? AVAudioSession.sharedInstance().setActive(true)

      var soundURL: URL?
      if let url = Bundle.main.url(forResource: "creepy_laugh", withExtension: "mp3") {
        soundURL = url
      } else if let key = FlutterDartProject.lookupKey(forAsset: "assets/audio/creepy_laugh.mp3") as String?,
                let path = Bundle.main.path(forResource: key, ofType: nil) {
        soundURL = URL(fileURLWithPath: path)
      }

      guard let url = soundURL else {
        self.log("creepy_laugh.mp3 non trovato nel bundle, fallback chime")
        self.playChime()
        return
      }

      do {
        self.creepyPlayer = try AVAudioPlayer(contentsOf: url)
        self.creepyPlayer?.volume = 1.0
        self.creepyPlayer?.prepareToPlay()
        let ok = self.creepyPlayer?.play() ?? false
        self.log("playCreepyLaugh -> play()=\(ok)")
      } catch {
        self.log("playCreepyLaugh errore: \(error.localizedDescription)")
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Beep / Chime / Alert suoni
  // ──────────────────────────────────────────────────────────────────
  private func playTone(hz: Int, ms: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sr  = 22050.0
      let n   = Int(sr * Double(ms) / 1000.0)
      var buf = [Int16]()
      buf.reserveCapacity(n)
      for i in 0..<n {
        let angle = 2.0 * Double.pi * Double(i) * Double(hz) / sr
        let env   = 1.0 - Double(i) / Double(n)
        buf.append(Int16(sin(angle) * Double(Int16.max) * 0.4 * env))
      }
      let pcm = buf.withUnsafeBufferPointer { Data(buffer: $0) }
      do {
        let wavData = self.buildWav(pcm: pcm, sampleRate: Int(sr))
        self.audioPlayer = try AVAudioPlayer(data: wavData)
        self.audioPlayer?.prepareToPlay()
        let ok = self.audioPlayer?.play() ?? false
        self.log("playTone \(hz)Hz -> play()=\(ok)")
      } catch {
        self.log("playTone errore: \(error.localizedDescription)")
      }
    }
  }

  private func playChime() {
    for (i, freq) in [650, 950, 1300].enumerated() {
      DispatchQueue.global(qos: .userInitiated)
        .asyncAfter(deadline: .now() + Double(i) * 0.085) {
          self.playTone(hz: freq, ms: 90)
        }
    }
  }

  func playProximityAlert() {
    for (i, freq) in [1200, 900, 1200, 900].enumerated() {
      DispatchQueue.global(qos: .userInitiated)
        .asyncAfter(deadline: .now() + Double(i) * 0.12) {
          self.playTone(hz: freq, ms: 80)
        }
    }
  }

  func playEmfAlert() {
    for (i, freq) in [200, 220, 200].enumerated() {
      DispatchQueue.global(qos: .userInitiated)
        .asyncAfter(deadline: .now() + Double(i) * 0.18) {
          self.playTone(hz: freq, ms: 150)
        }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // WAV builder
  // ──────────────────────────────────────────────────────────────────
  private func buildWav(pcm: Data, sampleRate: Int) -> Data {
    let channels    = 1
    let bitsPerSamp = 16
    let byteRate    = sampleRate * channels * bitsPerSamp / 8
    let blockAlign  = channels * bitsPerSamp / 8
    let dataSize    = pcm.count
    let chunkSize   = 36 + dataSize

    var wav = Data()
    wav.append(contentsOf: [UInt8]("RIFF".utf8))
    wav.append(contentsOf: le32(chunkSize))
    wav.append(contentsOf: [UInt8]("WAVE".utf8))
    wav.append(contentsOf: [UInt8]("fmt ".utf8))
    wav.append(contentsOf: le32(16))
    wav.append(contentsOf: le16(1))
    wav.append(contentsOf: le16(channels))
    wav.append(contentsOf: le32(sampleRate))
    wav.append(contentsOf: le32(byteRate))
    wav.append(contentsOf: le16(blockAlign))
    wav.append(contentsOf: le16(bitsPerSamp))
    wav.append(contentsOf: [UInt8]("data".utf8))
    wav.append(contentsOf: le32(dataSize))
    wav.append(pcm)
    return wav
  }

  private func le32(_ v: Int) -> [UInt8] {
    withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) }
  }
  private func le16(_ v: Int) -> [UInt8] {
    withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) }
  }
}
