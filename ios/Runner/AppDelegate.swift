import Flutter
import UIKit
import AVFoundation
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {

  private let channelName  = "com.aetherscan.pro/audio"
  private let licenseKey   = "aetherscan_pro_license"   // chiave stabile
  private let synth        = AVSpeechSynthesizer()
  private var audioPlayer  : AVAudioPlayer?
  private var channelRegistered = false   // flag anti-doppia-registrazione

  private func log(_ msg: String) { NSLog("[AETHER] %@", msg) }

  // ─────────────────────────────────────────────────────────────────
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // 1. Plugin Flutter prima di super
    GeneratedPluginRegistrant.register(with: self)

    // 2. super inizializza FlutterEngine e (per app non-scene) setta window
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    synth.delegate = self
    UIApplication.shared.isIdleTimerDisabled = true
    setupAudioSession()

    // 3. Tentativo immediato (funziona su app non-scene)
    registerChannel()

    // 4. Retry quando l'app diventa attiva:
    //    nelle app con SceneDelegate, window diventa disponibile DOPO
    //    che la scena si connette — quindi applicationDidBecomeActive
    //    è il momento giusto per un secondo tentativo.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(onAppActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    return result
  }

  @objc private func onAppActive() {
    registerChannel()
  }

  // ─────────────────────────────────────────────────────────────────
  // Registrazione channel — idempotente grazie a channelRegistered
  // ─────────────────────────────────────────────────────────────────
  private func registerChannel() {
    guard !channelRegistered else { return }

    // Con SceneDelegate, window viene gestita dalla scena:
    // proviamo prima la window dell'AppDelegate, poi quella della scena attiva
    let flutterVC: FlutterViewController?

    if let vc = window?.rootViewController as? FlutterViewController {
      flutterVC = vc
    } else if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let vc = scene.windows.first?.rootViewController as? FlutterViewController {
      flutterVC = vc
    } else {
      log("window non pronta — channel rinviato a didBecomeActive")
      return
    }

    channelRegistered = true
    log("Channel registrato su FlutterViewController")

    let ch = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: flutterVC.binaryMessenger
    )

    ch.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {

      // ── LICENZA ────────────────────────────────────────────────
      case "getDeviceHwid":
        result(self.hwid())

      case "getSavedLicense":
        let v = UserDefaults.standard.string(forKey: self.licenseKey) ?? ""
        self.log("getSavedLicense → \(v.isEmpty ? "VUOTA" : "TROVATA (\(v.count) chars)")")
        result(v)

      case "saveLicense":
        let k = (call.arguments as? [String: Any])?["licenseKey"] as? String ?? ""
        UserDefaults.standard.set(k, forKey: self.licenseKey)
        UserDefaults.standard.synchronize()
        self.log("saveLicense → '\(k.prefix(10))…' salvata")
        result(true)

      // ── AUDIO ──────────────────────────────────────────────────
      case "speak":
        let args = call.arguments as? [String: Any]
        let text = args?["text"] as? String ?? ""
        let vol  = (args?["volume"] as? Double).map { Float($0) } ?? 1.0
        self.log("speak → '\(text)'")
        self.speak(text: text, vol: vol)
        result(true)

      case "playBeep":
        let args = call.arguments as? [String: Any]
        self.playTone(hz: args?["freq"] as? Int ?? 880,
                      ms: args?["durationMs"] as? Int ?? 100)
        result(true)

      case "playChime":
        self.playChime(); result(true)

      case "setWakeLock":
        let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
        result(true)

      case "openUrl":
        if let s = (call.arguments as? [String: Any])?["url"] as? String,
           let u = URL(string: s) {
          DispatchQueue.main.async { UIApplication.shared.open(u) }
          result(true)
        } else { result(false) }

      case "audioDiagnostic":
        result(self.diagnostic())

      case "startStatic", "stopStatic":
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Audio Session — .playback bypassa silent-switch su app sideloaded
  // ─────────────────────────────────────────────────────────────────
  private func setupAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
      try AVAudioSession.sharedInstance().setActive(true)
      log("AudioSession OK → .playback")
    } catch { log("AudioSession ERRORE: \(error)") }
  }

  // ─────────────────────────────────────────────────────────────────
  // TTS
  // ─────────────────────────────────────────────────────────────────
  private func speak(text: String, vol: Float) {
    try? AVAudioSession.sharedInstance().setActive(true)
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

    let u = AVSpeechUtterance(string: text)
    let allVoices = AVSpeechSynthesisVoice.speechVoices()
    if let v = allVoices.first(where: { $0.language == "it-IT" }) {
      u.voice = v; log("TTS voce: \(v.name)")
    } else if let v = allVoices.first(where: { $0.language.hasPrefix("en") }) {
      u.voice = v; log("TTS fallback en: \(v.name)")
    } else { log("TTS: nessuna voce specifica, uso sistema") }

    u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
    u.pitchMultiplier = 0.95
    u.volume = max(0.1, min(1.0, vol))
    synth.speak(u)
    log("TTS synth.speak() eseguito, isSpeaking=\(synth.isSpeaking)")
  }

  func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance)  { log("TTS STARTED") }
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { log("TTS FINISHED") }
  func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { log("TTS CANCELLED") }

  // ─────────────────────────────────────────────────────────────────
  // Diagnostica
  // ─────────────────────────────────────────────────────────────────
  private func diagnostic() -> String {
    let s  = AVAudioSession.sharedInstance()
    let out = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
    let voc = AVSpeechSynthesisVoice.speechVoices()
               .filter { $0.language.hasPrefix("it") }
               .map { $0.name }.joined(separator: ", ")
    let key = UserDefaults.standard.string(forKey: licenseKey) ?? ""
    let r = """
=== DIAGNOSTICA ===
Channel registrato: \(channelRegistered)
Audio: \(s.category.rawValue) → \(out.isEmpty ? "NESSUN OUTPUT" : out)
Volume: \(s.outputVolume)
Voci IT: \(voc.isEmpty ? "NESSUNA" : voc)
TTS attivo: \(synth.isSpeaking)
Licenza: \(key.isEmpty ? "NON SALVATA" : "OK (\(key.count) chars)")
"""
    log(r); return r
  }

  // ─────────────────────────────────────────────────────────────────
  // HWID
  // ─────────────────────────────────────────────────────────────────
  private func hwid() -> String {
    let raw = "IOS:\(UIDevice.current.identifierForVendor?.uuidString ?? "UNKNOWN")"
    guard let data = raw.data(using: .utf8) else { return String(repeating: "0", count: 32) }
    var d = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &d) }
    return d.map { String(format: "%02x", $0) }.joined()
  }

  // ─────────────────────────────────────────────────────────────────
  // Beep / Chime
  // ─────────────────────────────────────────────────────────────────
  private func playTone(hz: Int, ms: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sr = 22050.0, n = Int(sr * Double(ms) / 1000.0)
      var buf = [Int16](); buf.reserveCapacity(n)
      for i in 0..<n {
        let a = 2.0 * Double.pi * Double(i) * Double(hz) / sr
        let e = 1.0 - Double(i) / Double(n)
        buf.append(Int16(sin(a) * Double(Int16.max) * 0.4 * e))
      }
      let pcm = buf.withUnsafeBufferPointer { Data(buffer: $0) }
      do {
        self.audioPlayer = try AVAudioPlayer(data: self.wav(pcm: pcm, sr: Int(sr)))
        self.audioPlayer?.prepareToPlay()
        self.log("playTone \(hz)Hz → play=\(self.audioPlayer?.play() ?? false)")
      } catch { self.log("playTone ERR: \(error)") }
    }
  }

  private func playChime() {
    for (i, f) in [650, 950, 1300].enumerated() {
      DispatchQueue.global(qos: .userInitiated)
        .asyncAfter(deadline: .now() + Double(i) * 0.085) { self.playTone(hz: f, ms: 90) }
    }
  }

  private func wav(pcm: Data, sr: Int) -> Data {
    var w = Data()
    func u32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
    func u16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) } }
    w += "RIFF".utf8; w += u32(36 + pcm.count)
    w += "WAVE".utf8; w += "fmt ".utf8
    w += u32(16); w += u16(1); w += u16(1)
    w += u32(sr); w += u32(sr * 2); w += u16(2); w += u16(16)
    w += "data".utf8; w += u32(pcm.count); w += pcm
    return w
  }
}
