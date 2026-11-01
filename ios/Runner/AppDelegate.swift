import Flutter
import UIKit
import AVFoundation
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {
  private let channelName = "com.aetherscan.pro/audio"

  // UserDefaults con suite dedicata — più affidabile di .standard su force-quit iOS 17+
  private let defaults: UserDefaults = {
    return UserDefaults(suiteName: "com.aetherscan.pro.prefs") ?? UserDefaults.standard
  }()
  private let licenseKey = "saved_license_key"

  // Sintetizzatore vocale — entità separata, NON tocca AVAudioSession
  private let synth = AVSpeechSynthesizer()
  // Player per beep/chime — usa AVAudioSession solo per suoni non-vocali
  private var audioPlayer: AVAudioPlayer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    synth.delegate = self

    // Schermo sempre acceso
    UIApplication.shared.isIdleTimerDisabled = true

    // Sessione audio per beep/chime (NON per TTS — AVSpeechSynthesizer gestisce da solo)
    setupBeepAudioSession()

    if let controller = window?.rootViewController as? FlutterViewController {
      let ch = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)

      ch.setMethodCallHandler { [weak self] (call, result) in
        guard let self = self else { return }
        switch call.method {

        case "getDeviceHwid":
          result(self.computeHwid())

        case "getSavedLicense":
          // Legge da suite dedicata — sempre disponibile subito
          let saved = self.defaults.string(forKey: self.licenseKey) ?? ""
          result(saved)

        case "saveLicense":
          let args = call.arguments as? [String: Any]
          let key = args?["licenseKey"] as? String ?? ""
          self.defaults.set(key, forKey: self.licenseKey)
          // synchronize() è deprecato ma garantisce flush immediato su iOS 17+
          self.defaults.synchronize()
          result(true)

        case "speak":
          let args = call.arguments as? [String: Any]
          let text = args?["text"] as? String ?? ""
          let vol  = (args?["volume"] as? Double).map { Float($0) } ?? 1.0
          self.speakText(text: text, volume: vol)
          result(true)

        case "playBeep":
          let args = call.arguments as? [String: Any]
          let freq = args?["freq"] as? Int ?? 880
          let dur  = args?["durationMs"] as? Int ?? 100
          self.playTone(freqHz: freq, durationMs: dur)
          result(true)

        case "playChime":
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

  // MARK: - Audio Session (solo per beep/chime, NON per TTS)
  private func setupBeepAudioSession() {
    do {
      // .ambient: compatibile con TTS, non interferisce con AVSpeechSynthesizer
      try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.allowBluetooth])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AudioSession setup error: \(error)")
    }
  }

  // MARK: - TTS (AVSpeechSynthesizer gestisce da solo la sessione su iOS 17+)
  private func speakText(text: String, volume: Float) {
    if synth.isSpeaking {
      synth.stopSpeaking(at: .immediate)
    }
    let utt = AVSpeechUtterance(string: text)
    // Voce italiana se disponibile, altrimenti sistema
    utt.voice = AVSpeechSynthesisVoice(language: "it-IT")
               ?? AVSpeechSynthesisVoice(language: "en-US")
    utt.rate            = AVSpeechUtteranceDefaultSpeechRate * 0.85
    utt.pitchMultiplier = 0.95
    utt.volume          = max(0.1, min(1.0, volume))
    synth.speak(utt)
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

  // MARK: - Beep / Chime (AVAudioPlayer, sessione .ambient)
  private func playTone(freqHz: Int, durationMs: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sr   = 22050.0
      let n    = Int(sr * Double(durationMs) / 1000.0)
      var buf  = [Int16]()
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
        self.audioPlayer?.play()
      } catch {
        print("Tone error: \(error)")
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

  // MARK: - WAV builder
  private func makeWav(pcm: Data, sr: Int) -> Data {
    var w = Data()
    let ch    = 1, bps = 16
    let br    = sr * ch * bps / 8
    let ba    = ch * bps / 8
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
