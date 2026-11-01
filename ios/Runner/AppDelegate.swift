import Flutter
import UIKit
import AVFoundation
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {

  private let channelName = "com.aetherscan.pro/audio"

  // LICENZA: UserDefaults.standard — sempre disponibile, nessun App Group richiesto
  // NON usare suite name custom senza App Group configurato in Xcode
  private let licenseKey = "aetherscan_license_key_v1"

  private let synth = AVSpeechSynthesizer()
  private var audioPlayer: AVAudioPlayer?

  private func audioLog(_ msg: String) {
    NSLog("[AETHER] %@", msg)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // 1. Prima registra i plugin Flutter
    GeneratedPluginRegistrant.register(with: self)

    // 2. Poi chiama super (inizializza FlutterEngine e window)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // 3. Configura sessione audio
    setupAudioSession()

    // 4. Schermo sempre acceso
    UIApplication.shared.isIdleTimerDisabled = true

    // 5. Registra il MethodChannel DOPO super (window è garantita pronta)
    synth.delegate = self
    registerMethodChannel()

    return result
  }

  // MARK: - Registrazione Channel (chiamata dopo super, window pronta)
  private func registerMethodChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      audioLog("ERRORE: rootViewController non è FlutterViewController — channel non registrato")
      return
    }
    audioLog("Channel registrato su FlutterViewController")

    let ch = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
    ch.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {

      case "getDeviceHwid":
        let hwid = self.computeHwid()
        self.audioLog("getDeviceHwid → \(hwid.prefix(8))...")
        result(hwid)

      case "getSavedLicense":
        let saved = UserDefaults.standard.string(forKey: self.licenseKey) ?? ""
        self.audioLog("getSavedLicense → \(saved.isEmpty ? "VUOTA" : "TROVATA (\(saved.count) chars)")")
        result(saved)

      case "saveLicense":
        let args = call.arguments as? [String: Any]
        let key = args?["licenseKey"] as? String ?? ""
        UserDefaults.standard.set(key, forKey: self.licenseKey)
        UserDefaults.standard.synchronize()
        self.audioLog("saveLicense → salvata '\(key.prefix(8))...' (\(key.count) chars)")
        result(true)

      case "speak":
        let args = call.arguments as? [String: Any]
        let text = args?["text"] as? String ?? ""
        let vol  = (args?["volume"] as? Double).map { Float($0) } ?? 1.0
        self.audioLog("speak → '\(text)' vol=\(vol)")
        self.speakText(text: text, volume: vol)
        result(true)

      case "playBeep":
        let args = call.arguments as? [String: Any]
        let freq = args?["freq"] as? Int ?? 880
        let dur  = args?["durationMs"] as? Int ?? 100
        self.audioLog("playBeep → \(freq)Hz \(dur)ms")
        self.playTone(freqHz: freq, durationMs: dur)
        result(true)

      case "playChime":
        self.audioLog("playChime")
        self.playChime()
        result(true)

      case "setWakeLock":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = enabled }
        result(true)

      case "openUrl":
        let args = call.arguments as? [String: Any]
        if let s = args?["url"] as? String, let url = URL(string: s) {
          DispatchQueue.main.async { UIApplication.shared.open(url) }
          result(true)
        } else { result(false) }

      case "audioDiagnostic":
        result(self.buildDiagnostic())

      case "startStatic", "stopStatic":
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Audio Session
  // Configurazione minima: .playback bypassa silent switch
  // Nessuna option extra che richiede entitlements (app sideloaded)
  private func setupAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
      audioLog("AudioSession OK → .playback attiva")
    } catch {
      audioLog("AudioSession ERRORE: \(error.localizedDescription)")
    }
  }

  // MARK: - TTS
  private func speakText(text: String, volume: Float) {
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      audioLog("speakText setActive ERRORE: \(error.localizedDescription)")
    }

    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

    let utt = AVSpeechUtterance(string: text)

    let availableVoices = AVSpeechSynthesisVoice.speechVoices()
    if let itVoice = availableVoices.first(where: { $0.language == "it-IT" }) {
      utt.voice = itVoice
      audioLog("speakText → voce it-IT: \(itVoice.name)")
    } else if let enVoice = availableVoices.first(where: { $0.language.hasPrefix("en") }) {
      utt.voice = enVoice
      audioLog("speakText → fallback en: \(enVoice.name)")
    } else {
      audioLog("speakText → nessuna voce trovata, uso sistema")
    }

    utt.rate            = AVSpeechUtteranceDefaultSpeechRate * 0.85
    utt.pitchMultiplier = 0.95
    utt.volume          = max(0.1, min(1.0, volume))
    synth.speak(utt)
    audioLog("speakText → synth.speak() chiamato")
  }

  // MARK: - AVSpeechSynthesizerDelegate
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    audioLog("TTS STARTED")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    audioLog("TTS FINISHED")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    audioLog("TTS CANCELLED")
  }

  // MARK: - Diagnostica
  private func buildDiagnostic() -> String {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
    let voices  = AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("it") }
      .map { "\($0.name)" }
      .joined(separator: ", ")
    let savedKey = UserDefaults.standard.string(forKey: licenseKey) ?? ""
    let d = """
=== DIAGNOSTICA AetherScan ===
Bundle ID: com.aetherscan.pro.aetherscanPro
Audio categoria: \(session.category.rawValue)
Audio route output: \(outputs.isEmpty ? "NESSUNO" : outputs)
Volume sistema: \(session.outputVolume)
Voci italiane: \(voices.isEmpty ? "NESSUNA" : voices)
TTS in corso: \(synth.isSpeaking)
Licenza salvata: \(savedKey.isEmpty ? "NO" : "SI (\(savedKey.count) chars)")
UserDefaults key: \(licenseKey)
"""
    audioLog(d)
    return d
  }

  // MARK: - Device HWID
  private func computeHwid() -> String {
    let id  = UIDevice.current.identifierForVendor?.uuidString ?? "IOS_UNKNOWN"
    let raw = "IOS:\(id)"
    guard let data = raw.data(using: .utf8) else { return "000000000000000000000000000000000" }
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Beep / Chime
  private func playTone(freqHz: Int, durationMs: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sr  = 22050.0
      let n   = Int(sr * Double(durationMs) / 1000.0)
      var buf = [Int16]()
      buf.reserveCapacity(n)
      for i in 0..<n {
        let angle = 2.0 * Double.pi * Double(i) * Double(freqHz) / sr
        let env   = 1.0 - (Double(i) / Double(n))
        buf.append(Int16(sin(angle) * Double(Int16.max) * 0.4 * env))
      }
      let pcm = buf.withUnsafeBufferPointer { Data(buffer: $0) }
      do {
        let wav = self.makeWav(pcm: pcm, sr: Int(sr))
        self.audioPlayer = try AVAudioPlayer(data: wav)
        self.audioPlayer?.prepareToPlay()
        let ok = self.audioPlayer?.play() ?? false
        self.audioLog("playTone \(freqHz)Hz → play()=\(ok)")
      } catch {
        self.audioLog("playTone ERRORE: \(error.localizedDescription)")
      }
    }
  }

  private func playChime() {
    for (i, f) in [650, 950, 1300].enumerated() {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(i) * 0.085) {
        self.playTone(freqHz: f, durationMs: 90)
      }
    }
  }

  // MARK: - WAV builder
  private func makeWav(pcm: Data, sr: Int) -> Data {
    var w = Data()
    let ch = 1, bps = 16
    func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
    func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) } }
    let sub2 = pcm.count
    w.append(contentsOf: "RIFF".utf8); w.append(contentsOf: le32(36 + sub2))
    w.append(contentsOf: "WAVE".utf8); w.append(contentsOf: "fmt ".utf8)
    w.append(contentsOf: le32(16));    w.append(contentsOf: le16(1))
    w.append(contentsOf: le16(ch));    w.append(contentsOf: le32(sr))
    w.append(contentsOf: le32(sr * ch * bps / 8))
    w.append(contentsOf: le16(ch * bps / 8))
    w.append(contentsOf: le16(bps));   w.append(contentsOf: "data".utf8)
    w.append(contentsOf: le32(sub2));  w.append(pcm)
    return w
  }
}
