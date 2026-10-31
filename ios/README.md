# ◈ AetherScan Pro — iOS Project (v26 Beta 3)

Questo repository/cartella contiene il progetto iOS completo e nativo di **AetherScan Pro v26 Beta 3**, speculare al progetto Android.

## 📱 Funzionalità iOS Implementate

1. **Audio & Sintesi Vocale Nativa iOS**:
   - `AVSpeechSynthesizer` integrato in Swift (`AppDelegate.swift`) con lingua italiana (`it-IT`), rate calibrato e volume regolabile.
   - Generazione sintetizzatore audio hardware PCM 16-bit (`AVAudioPlayer`) per i toni radio:
     - **Beep** avvio scansione (880 Hz).
     - **Chime** a tre frequenze (650, 950, 1300 Hz) per segnalazione anomalia/picco EVP.

2. **Protezione Licenza KeyDigitale (HWID iOS)**:
   - Ricava l'HWID univoco dell'iPhone/iPad tramite `UIDevice.current.identifierForVendor` con hashing crittografico MD5 (`IOS:<UUID>`).
   - Memorizzazione permanente della licenza attivata tramite `UserDefaults.standard` (una volta attivata non viene più richiesta alla chiusura).

3. **Icone Ufficiali iOS AppIcon**:
   - Tutte le risoluzioni per iPhone, iPad e App Store generate dal logo cyber radar in `Assets.xcassets/AppIcon.appiconset`:
     - 20x20 (@1x, @2x, @3x)
     - 29x29 (@1x, @2x, @3x)
     - 40x40 (@1x, @2x, @3x)
     - 60x60 (@2x, @3x)
     - 76x76, 83.5x83.5, 1024x1024 (App Store Marketing)

## 🛠️ Come Compilare / Distribuire su iPhone / macOS

Essendo sviluppato con Flutter, il codice sorgente Dart `lib/main.dart` è condiviso al 100% tra Android e iOS.
Per compilare l'app su Mac (Xcode / TestFlight / file `.ipa`):

```bash
# Entra nella cartella Flutter
cd D:\AetherScan-Pro\android

# Su macOS con Xcode:
flutter build ipa --no-codesign
# oppure apri direttamente il progetto in Xcode:
open ios/Runner.xcworkspace
```
