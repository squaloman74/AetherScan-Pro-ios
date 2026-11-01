import Flutter
import UIKit
import AVFoundation
import CommonCrypto

@main
@objc class AppDelegate: FlutterAppDelegate, AVSpeechSynthesizerDelegate {
  private let channelName = "com.aetherscan.pro/audio"
  private let userDefaultsLicenseKey = "saved_license_key"
  
  private let speechSynthesizer = AVSpeechSynthesizer()
  private var audioPlayer: AVAudioPlayer?
  private var ttsVolume: Float = 1.0

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    speechSynthesizer.delegate = self
    setupAudioSession()
    
    // FIX Beta 4: Schermo sempre acceso mentre l'app è aperta
    UIApplication.shared.isIdleTimerDisabled = true

    if let controller = window?.rootViewController as? FlutterViewController {
      let audioChannel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
      
      audioChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        guard let self = self else { return }
        
        switch call.method {
        case "getDeviceHwid":
          let hwid = self.getDeviceHwid()
          result(hwid)
          
        case "getSavedLicense":
          let saved = UserDefaults.standard.string(forKey: self.userDefaultsLicenseKey) ?? ""
          result(saved)
          
        case "saveLicense":
          if let args = call.arguments as? [String: Any],
             let key = args["licenseKey"] as? String {
            UserDefaults.standard.set(key, forKey: self.userDefaultsLicenseKey)
            result(true)
          } else {
            result(false)
          }
          
        case "speak":
          if let args = call.arguments as? [String: Any] {
            let text = args["text"] as? String ?? ""
            let vol = args["volume"] as? Double ?? 1.0
            self.speakText(text: text, volume: Float(vol))
          }
          result(true)
          
        case "playBeep":
          if let args = call.arguments as? [String: Any] {
            let freq = args["freq"] as? Int ?? 880
            let durationMs = args["durationMs"] as? Int ?? 100
            self.playTone(freqHz: freq, durationMs: durationMs)
          }
          result(true)
          
        case "playChime":
          self.playChimeSound()
          result(true)
          
        // FIX Beta 4: WakeLock dinamico controllabile da Flutter
        case "setWakeLock":
          let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? true
          DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = enabled
          }
          result(true)

        // Beta 4: Apre URL in Safari / AltStore per installazione aggiornamenti
        case "openUrl":
          if let args = call.arguments as? [String: Any],
             let urlString = args["url"] as? String,
             let url = URL(string: urlString) {
            DispatchQueue.main.async {
              UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
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

  private func setupAudioSession() {
    do {
      // FIX Beta 4: .spokenAudio richiesto per AVSpeechSynthesizer su iOS 17+
      // .default causava silenzio TTS su iPhone 17 / iOS 19
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AVAudioSession error: \(error)")
    }
  }

  private func getDeviceHwid() -> String {
    let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? "IOS_UNKNOWN_DEVICE"
    let raw = "IOS:\(vendorId)"
    
    guard let data = raw.data(using: .utf8) else { return "584ef757835d045d9e504e0303ba70b6" }
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes {
      CC_MD5($0.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func speakText(text: String, volume: Float) {
    if speechSynthesizer.isSpeaking {
      speechSynthesizer.stopSpeaking(at: .immediate)
    }
    
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "it-IT") ?? AVSpeechSynthesisVoice(language: "en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
    utterance.pitchMultiplier = 0.95
    utterance.volume = max(0.1, min(1.0, volume))
    speechSynthesizer.speak(utterance)
  }

  private func playTone(freqHz: Int, durationMs: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      let sampleRate: Double = 22050.0
      let numSamples = Int(sampleRate * Double(durationMs) / 1000.0)
      var samples = [Int16]()
      samples.reserveCapacity(numSamples)
      
      for i in 0..<numSamples {
        let angle = 2.0 * Double.pi * Double(i) * Double(freqHz) / sampleRate
        let env = 1.0 - (Double(i) / Double(numSamples))
        let sample = Int16(sin(angle) * Double(Int16.max) * 0.4 * env)
        samples.append(sample)
      }
      
      let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)!
      
      do {
        let wavHeaderData = self.createWavData(pcmData: data, sampleRate: Int(sampleRate), channels: 1, bitsPerSample: 16)
        self.audioPlayer = try AVAudioPlayer(data: wavHeaderData)
        self.audioPlayer?.prepareToPlay()
        self.audioPlayer?.play()
      } catch {
        print("Tone audioPlayer error: \(error)")
      }
    }
  }

  private func playChimeSound() {
    let freqs = [650, 950, 1300]
    for (idx, f) in freqs.enumerated() {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(idx) * 0.085) {
        self.playTone(freqHz: f, durationMs: 90)
      }
    }
  }

  private func createWavData(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
    var wav = Data()
    let byteRate = sampleRate * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8
    let subchunk2Size = pcmData.count
    let chunkSize = 36 + subchunk2Size

    wav.append(contentsOf: "RIFF".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Array($0) })
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
    wav.append(contentsOf: "data".utf8)
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(subchunk2Size).littleEndian) { Array($0) })
    wav.append(pcmData)
    return wav
  }
}
