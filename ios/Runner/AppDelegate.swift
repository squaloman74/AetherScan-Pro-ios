import Flutter
import UIKit
import AVFoundation
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {
  private let channelName = "com.aetherscan.pro/audio"

  // UserDefaults suite dedicata — più affidabile di .standard su force-quit iOS 17+
  private let defaults: UserDefaults = {
    return UserDefaults(suiteName: "com.aetherscan.pro.prefs") ?? UserDefaults.standard
  }()
  private let licenseKey = "saved_license_key"

  private let synth = AVSpeechSynthesizer()
  private var audioPlayer: AVAudioPlayer?

  // ─── Log diagnostico audio ───────────────────────────────────────────────
  private func audioLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[AETHER-AUDIO \(ts)] \(msg)")
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    synth.delegate = self
    UIApplication.shared.isIdleTimerDisabled = true

    // Configura sessione audio al lancio
    setupAudioSession()

    if let controller = window?.rootViewController as? FlutterViewController {
      let ch = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)

      ch.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }
        switch call.method {

        case "getDeviceHwid":
          result(self.computeHwid())

        case "getSavedLicense":
          let saved = self.defaults.string(forKey: self.licenseKey) ?? ""
          self.audioLog("getSavedLicense → '\(saved.isEmpty ? "(vuota)" : "KEY TROVATA")'")
          result(saved)

        case "saveLicense":
          let args = call.arguments as? [String: Any]
          let key = args?["licenseKey"] as? String ?? ""
          self.defaults.set(key, forKey: self.licenseKey)
          self.defaults.synchronize()
          self.audioLog("saveLicense → chiave salvata (\(key.count) caratteri)")
          result(true)

        case "speak":
          let args = call.arguments as? [String: Any]
          let text = args?["text"] as? String ?? ""
          let vol  = (args?["volume"] as? Double).map { Float($0) } ?? 1.0
          self.audioLog("speak chiamato → testo='\(text)' volume=\(vol)")
          self.speakText(text: text, volume: vol)
          result(true)

        case "playBeep":
          let args = call.arguments as? [String: Any]
          let freq = args?["freq"] as? Int ?? 880
          let dur  = args?["durationMs"] as? Int ?? 100
          self.audioLog("playBeep → freq=\(freq)Hz dur=\(dur)ms")
          self.playTone(freqHz: freq, durationMs: dur)
          result(true)

        case "playChime":
          self.audioLog("playChime chiamato")
          self.playChime()
          result(true)

        case "setWakeLock":
          let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
          DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = enabled
          }
          result(true)

        case "openUrl":
          let args = call.arguments as? [String: Any]
          if let s = args?["url"] as? String, let url = URL(string: s) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
            result(true)
          } else {
            result(false)
          }

        // Canale diagnostico — restituisce stato sessione audio a Flutter
        case "audioDiagnostic":
          result(self.buildAudioDiagnostic())

        case "startStatic", "stopStatic":
          result(true)

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // ─── MARK: Audio Session ─────────────────────────────────────────────────
  private func setupAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // .playback : bypassa il tasto silenzioso
      // .spokenAudio : ottimizzato per TTS (iOS gestisce priorità voce)
      // .duckOthers : abbassa altri audio durante la voce
      // .defaultToSpeaker : forza altoparlante (evita routing su auricolare/cuffia)
      try session.setCategory(
        .playback,
        mode: .spokenAudio,
        options: [.duckOthers, .defaultToSpeaker]
      )
      try session.setActive(true)
      audioLog("AudioSession OK → categoria=\(session.category.rawValue) mode=\(session.mode.rawValue) outputRoute=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
    } catch {
      audioLog("AudioSession ERRORE setup: \(error)")
    }
  }

  // ─── MARK: TTS ───────────────────────────────────────────────────────────
  private func speakText(text: String, volume: Float) {
    let session = AVAudioSession.sharedInstance()

    // Riattiva sessione (potrebbe essere stata disattivata da altra app)
    do {
      try session.setActive(true)
      audioLog("speakText → sessione riattivata, outputRoute=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
    } catch {
      audioLog("speakText → ERRORE setActive: \(error)")
    }

    if synth.isSpeaking {
      audioLog("speakText → sintetizzatore occupato, stop immediato")
      synth.stopSpeaking(at: .immediate)
    }

    let utt = AVSpeechUtterance(string: text)

    // Selezione voce con log diagnostico
    if let voice = AVSpeechSynthesisVoice(language: "it-IT") {
      utt.voice = voice
      audioLog("speakText → voce it-IT trovata: \(voice.name)")
    } else if let voice = AVSpeechSynthesisVoice(language: "en-US") {
      utt.voice = voice
      audioLog("speakText → voce it-IT NON trovata, fallback en-US: \(voice.name)")
    } else {
      audioLog("speakText → NESSUNA voce trovata, uso voce sistema")
    }

    utt.rate            = AVSpeechUtteranceDefaultSpeechRate * 0.85
    utt.pitchMultiplier = 0.95
    utt.volume          = max(0.1, min(1.0, volume))

    audioLog("speakText → avvio sintesi: rate=\(utt.rate) vol=\(utt.volume)")
    synth.speak(utt)
  }

  // ─── AVSpeechSynthesizerDelegate — log eventi TTS ────────────────────────
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    audioLog("TTS → INIZIATO a parlare")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    audioLog("TTS → COMPLETATO")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    audioLog("TTS → ANNULLATO")
  }

  // ─── MARK: Diagnostica audio → restituita a Flutter ──────────────────────
  private func buildAudioDiagnostic() -> String {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
    let inputs  = session.currentRoute.inputs.map  { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
    let voices  = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("it") }.map { "\($0.name)(\($0.quality.rawValue))" }.joined(separator: ", ")

    let report = """
    === AUDIO DIAGNOSTICA ===
    Categoria: \(session.category.rawValue)
    Mode: \(session.mode.rawValue)
    Output attivo: \(outputs.isEmpty ? "NESSUNO" : outputs)
    Input attivo: \(inputs.isEmpty ? "NESSUNO" : inputs)
    Volume output: \(session.outputVolume)
    Voci italiane: \(voices.isEmpty ? "NESSUNA INSTALLATA" : voices)
    Synth attivo: \(synth.isSpeaking)
    """
    audioLog(report)
    return report
  }

  // ─── MARK: Device HWID ───────────────────────────────────────────────────
  private func computeHwid() -> String {
    let id  = UIDevice.current.identifierForVendor?.uuidString ?? "IOS_UNKNOWN"
    let raw = "IOS:\(id)"
    guard let data = raw.data(using: .utf8) else { return "000000000000000000000000000000000" }
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // ─── MARK: Beep / Chime ──────────────────────────────────────────────────
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
        self.audioLog("playTone ERRORE: \(error)")
      }
    }
  }

  private func playChime() {
    let freqs = [650, 950, 1300]
    for (i, f) in freqs.enumerated() {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(i) * 0.085) {
        self.playTone(freqHz: f, durationMs: 90)
      }
    }
  }

  // ─── MARK: WAV builder ───────────────────────────────────────────────────
  private func makeWav(pcm: Data, sr: Int) -> Data {
    var w = Data()
    let ch = 1, bps = 16
    let br = sr * ch * bps / 8
    let ba = ch * bps / 8
    let sub2  = pcm.count
    let chunk = 36 + sub2
    func le32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(v).littleEndian) { Array($0) } }
    func le16(_ v: Int) -> [UInt8] { withUnsafeBytes(of: UInt16(v).littleEndian) { Array($0) } }
    w.append(contentsOf: "RIFF".utf8); w.append(contentsOf: le32(chunk))
    w.append(contentsOf: "WAVE".utf8); w.append(contentsOf: "fmt ".utf8)
    w.append(contentsOf: le32(16));    w.append(contentsOf: le16(1))
    w.append(contentsOf: le16(ch));    w.append(contentsOf: le32(sr))
    w.append(contentsOf: le32(br));    w.append(contentsOf: le16(ba))
    w.append(contentsOf: le16(bps));   w.append(contentsOf: "data".utf8)
    w.append(contentsOf: le32(sub2));  w.append(pcm)
    return w
  }
}
