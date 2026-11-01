import Flutter
import UIKit
import AVFoundation
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {

  private let channelName       = "com.aetherscan.pro/audio"
  private let licenseKey        = "aetherscan_pro_license"
  private let synth             = AVSpeechSynthesizer()
  private var audioPlayer       : AVAudioPlayer?
  private var channelRegistered = false

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

    // Tentativo immediato (app senza SceneDelegate)
    registerChannel()

    // Con SceneDelegate la window diventa disponibile solo dopo
    // che la scena si connette → ascoltiamo didBecomeActive
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

    // Cerca il FlutterViewController: prima in window AppDelegate,
    // poi nelle scene attive (SceneDelegate architecture)
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
      log("window non ancora pronta — attendo didBecomeActive")
      return
    }

    channelRegistered = true
    log("MethodChannel registrato correttamente")

    let ch = FlutterMethodChannel(name: channelName, binaryMessenger: vc.binaryMessenger)
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {

      case "getDeviceHwid":
        result(self.computeHwid())

      case "getSavedLicense":
        let v = UserDefaults.standard.string(forKey: self.licenseKey) ?? ""
        self.log("getSavedLicense → \(v.isEmpty ? "VUOTA" : "OK (\(v.count) chars)")")
        result(v)

      case "saveLicense":
        let k = (call.arguments as? [String: Any])?["licenseKey"] as? String ?? ""
        UserDefaults.standard.set(k, forKey: self.licenseKey)
        UserDefaults.standard.synchronize()
        self.log("saveLicense → \(k.count) chars salvati")
        result(true)

      case "speak":
        let args = call.arguments as? [String: Any]
        let text = args?["text"] as? String ?? ""
        let vol  = (args?["volume"] as? Double).map { Float($0) } ?? 1.0
        self.log("speak → \"\(text)\"")
        self.speak(text: text, vol: vol)
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
  private func speak(text: String, vol: Float) {
    try? AVAudioSession.sharedInstance().setActive(true)
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

    let utt = AVSpeechUtterance(string: text)
    let voices = AVSpeechSynthesisVoice.speechVoices()
    if let v = voices.first(where: { $0.language == "it-IT" }) {
      utt.voice = v; log("TTS voce: \(v.name)")
    } else if let v = voices.first(where: { $0.language.hasPrefix("en") }) {
      utt.voice = v; log("TTS fallback: \(v.name)")
    } else {
      log("TTS: nessuna voce specifica, sistema")
    }
    utt.rate            = AVSpeechUtteranceDefaultSpeechRate * 0.85
    utt.pitchMultiplier = 0.95
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
  // Beep / Chime — AVAudioPlayer con PCM generato
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
        self.log("playTone \(hz)Hz → play()=\(ok)")
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

  // ──────────────────────────────────────────────────────────────────
  // WAV builder — usa append(contentsOf:) esplicito (compila sempre)
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
    wav.append(contentsOf: le16(1))          // PCM
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
