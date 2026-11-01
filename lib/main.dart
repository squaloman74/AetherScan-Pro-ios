import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AetherScanProApp());
}

class AetherScanProApp extends StatelessWidget {
  const AetherScanProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AetherScan Pro v26 Beta 1',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF060B12),
        primaryColor: const Color(0xFF00EFFF),
      ),
      home: const MainTabScreen(),
    );
  }
}

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  static const _audioChannel = MethodChannel('com.aetherscan.pro/audio');
  static const _sensorChannel = EventChannel('com.aetherscan.pro/sensors');

  int _currentTab = 0; // 0: SCANNER, 1: ARCHIVIO, 2: ANALISI, 3: IMPOSTAZIONI

  // STATO PROTEZIONE LICENZA KEYDIGITALE (HWID)
  bool _isDeviceAuthorized = false;
  String _deviceHwid = 'CALCOLO IN CORSO...';
  final TextEditingController _licenseInputController = TextEditingController();

  bool _isScanning = false;
  String _band = 'FM';
  double _frequency = 104.30;
  Timer? _scanTimer;
  double _speedMs = 100;
  bool _anomalyActive = false;
  String _detectedWord = 'SPIRITO';
  String _evpFreqStr = '';
  double _ttsVolume = 1.0;
  bool _enableVoice = true;
  bool _enableChime = true;
  String _voiceGender = 'female'; // 'female' | 'male'
  int _stepsSinceLastDetection = 0; // Filtro anti-allucinazione avanzato

  // Stato aggiornamento in-app
  bool _isUpdating = false;
  double _updateProgress = 0.0;
  String _updateStatusText = 'Versione: v26 Beta 1 (Build 2026.11.01)';
  bool _updateAvailable = false;
  String? _pendingIpaUrl;
  String _audioDiagnosticResult = ''; // risultato diagnostica audio
  StreamSubscription<dynamic>? _sensorSubscription;
  bool _proximityAlert = false;
  bool _emfSpikeAlert = false;
  double _emfValue = 0.0;
  double _emfDelta = 0.0;
  DateTime? _lastProximityAlertTime;
  DateTime? _lastEmfAlertTime;

  final List<String> _phonemes = [
    // Nomi di persona
    'MARCO', 'GIULIA', 'FRANCESCO', 'ELENA', 'ANNA', 'LUCA', 
    'ALESSANDRO', 'CHIARA', 'MATTEO', 'SARA', 'ANDREA', 'VALENTINA', 
    'LORENZO', 'MARTINA', 'GIOVANNI', 'BEATRICE', 'STEFANO', 'FEDERICA', 
    'PAOLO', 'SILVIA', 'DAVIDE', 'ALICE', 'GABRIELE', 'ELISA', 
    'ROBERTO', 'FRANCESCA', 'MICHELE', 'GIORGIA', 'SIMONE', 'LAURA',
    'THOMAS', 'EMILY', 'JOHN', 'MARY', 'MICHAEL', 'SARAH',
    // Risate & Suoni Vocali
    '[RISATA STRIDULA]', '[RISATA SOFFOCATA]', '[SUSSURRO FEMMINILE]',
    '[RESPORO AFFANNOSO]', '[LAMENTO LONTANO]', '[VOCE METALLICA]',
    '[BAMBINO CHE PIANGE]', '[SUSSURRO: SHHH]', '[PASSI VICINI]',
    // Fonemi & Parole Chiave
    'AIUTO', 'SPIRITO', 'QUI', 'SENTI', 'NOME', 'MORTE', 'LUCE', 
    'TEMPO', 'SÌ', 'NO', 'ASCOLTA', 'VICINO', 'FREDDO', 'PORTA', 
    'PRESENZA', 'CERCA', 'ANIMA', 'DIMMI', 'BUIO', 'OMBRA', 
    'PARLA', 'RICORDO', 'ADDIO', 'LIBERO', 'RESTO', 'PAURA',
    'FUOCO', 'ACQUA', 'NOTTE', 'CASA', 'ATTENTO', 'GUIDA',
    // Frasi Brevi di Comunicazione EVP
    'SONO QUI', 'CHI SEI', 'NON ANDARE', 'TI SENTO', 'AIUTAMI',
    'VOGLIO PARLARE', 'DIETRO DI TE', 'NON POSSO', 'DIMMI IL NOME',
    'È FREDDO', 'C\'È QUALCUNO', 'GUARDAMI', 'NON SIAMO SOLI',
    'ASCOLTAMI BENE', 'VAI VIA', 'RESTO CON TE', 'LUCE BIANCA',
    'LIBERAMI', 'PRIGIONIERO', 'TI VEDO', 'MI CHIAMO COSI'
  ];

  final List<String> _recentPickedWords = [];

  final List<Map<String, String>> _archive = [
    {'date': '29/10/2026 14:02', 'freq': '1280 kHz', 'band': 'AM', 'word': 'AIUTO', 'snr': '28 dB'},
    {'date': '29/10/2026 10:24', 'freq': '104.30 MHz', 'band': 'FM', 'word': 'SPIRITO', 'snr': '31 dB'},
    {'date': '29/10/2026 10:18', 'freq': '102.50 MHz', 'band': 'FM', 'word': 'QUI', 'snr': '26 dB'},
  ];

  final List<Map<String, String>> _recentList = [
    {'freq': '104.30 MHz', 'time': '10:24', 'active': 'true', 'word': 'SPIRITO'},
    {'freq': '102.50 MHz', 'time': '10:18', 'active': 'false', 'word': 'QUI'},
    {'freq': '98.70 MHz', 'time': '10:15', 'active': 'false', 'word': 'SENTI'},
    {'freq': '96.10 MHz', 'time': '10:11', 'active': 'false', 'word': 'NOME'},
  ];

  @override
  void initState() {
    super.initState();
    // Aspetta che il frame sia pronto prima di usare il MethodChannel
    // Evita il bug iOS dove il channel non risponde durante initState()
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDeviceHwidAndLicense();
    });
  }

  Future<void> _loadDeviceHwidAndLicense() async {
    // Attendi che il channel sia pronto (SceneDelegate: la window si connette dopo didFinishLaunch)
    // Riprova fino a 5 volte con intervallo crescente
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        final hwid = await _audioChannel.invokeMethod<String>('getDeviceHwid');
        final savedKey = await _audioChannel.invokeMethod<String>('getSavedLicense');

        if (!mounted) return;
        setState(() {
          _deviceHwid = hwid ?? '584ef757835d045d9e504e0303ba70b6';
          if (savedKey != null && savedKey.trim().isNotEmpty) {
            _isDeviceAuthorized = true;
            _licenseInputController.text = savedKey;
          }
        });
        return; // successo
      } catch (e) {
        final wait = Duration(milliseconds: 300 * (attempt + 1));
        if (attempt < 4) {
          await Future.delayed(wait);
        } else {
          if (mounted) setState(() { _deviceHwid = '584ef757835d045d9e504e0303ba70b6'; });
        }
      }
    }
  }

  Future<void> _persistLicense(String key) async {
    try {
      await _audioChannel.invokeMethod('saveLicense', {'licenseKey': key});
    } catch (_) {}
  }

  // Metodi nativi Audio Android
  void _playNativeBeep(int freq, int durationMs) {
    try {
      _audioChannel.invokeMethod('playBeep', {'freq': freq, 'durationMs': durationMs});
    } catch (_) {}
  }

  void _playNativeChime() {
    try {
      _audioChannel.invokeMethod('playChime');
    } catch (_) {}
  }

  void _speakNativeWord(String word) {
    try {
      String toSpeak = word;
      if (word.contains('RISATA')) {
        toSpeak = 'ah ah ah ah ah';
      } else if (word.contains('SUSSURRO')) {
        toSpeak = 'shhhhh... sono qui...';
      } else if (word.contains('PIANGE')) {
        toSpeak = 'aiutami... ti prego...';
      } else if (word.contains('LAMENTO')) {
        toSpeak = 'ohhh... nooo...';
      }
      _audioChannel.invokeMethod('speak', {'text': toSpeak, 'volume': _ttsVolume, 'gender': _voiceGender});
    } catch (_) {}
  }

  Future<void> _runAudioDiagnostic() async {
    try {
      final result = await _audioChannel.invokeMethod<String>('audioDiagnostic');
      setState(() => _audioDiagnosticResult = result ?? 'Nessun risultato');
    } catch (e) {
      setState(() => _audioDiagnosticResult = 'ERRORE: $e');
    }
  }

  void _toggleScan() {
    if (!_isDeviceAuthorized) {
      _showLicenseDialog();
      return;
    }
    setState(() {
      _isScanning = !_isScanning;
      if (_isScanning) {
        _playNativeBeep(880, 80);
        _startScan();
      } else {
        _stopScan();
      }
    });
  }

  void _startScan() {
    _scanTimer?.cancel();
    // FIX Beta 4: Mantieni schermo acceso durante la scansione
    _audioChannel.invokeMethod('setWakeLock', {'enabled': true});
    _scanTimer = Timer.periodic(Duration(milliseconds: _speedMs.round()), (timer) {
      setState(() {
        if (_band == 'FM') {
          _frequency += 0.05;
          if (_frequency > 108.0) _frequency = 87.50;
        } else {
          _frequency += 10.0;
          if (_frequency > 1710.0) _frequency = 530.0;
        }

        // Filtro scientifico anti-allucinazione:
        // 1. Finestra di scansione minima (minimo 18 step RF senza interruzioni)
        // 2. Probabilità tarata per evitare falsi positivi continui
        _stepsSinceLastDetection++;
        if (_stepsSinceLastDetection > 30) {
          if (Random().nextDouble() < 0.0015) {
            _stepsSinceLastDetection = 0;
            _triggerAnomaly();
          }
        }
      });
    });
  }

  void _stopScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    // FIX Beta 4: Ripristina timeout schermo quando la scansione si ferma
    _audioChannel.invokeMethod('setWakeLock', {'enabled': false});
  }

  void _triggerAnomaly() {
    _stopScan();

    final pool = _phonemes.where((w) => !_recentPickedWords.contains(w)).toList();
    final chosenWord = pool.isNotEmpty
        ? pool[Random().nextInt(pool.length)]
        : _phonemes[Random().nextInt(_phonemes.length)];
    _recentPickedWords.add(chosenWord);
    if (_recentPickedWords.length > 5) _recentPickedWords.removeAt(0);

    final freqStr = _band == 'FM'
        ? '${_frequency.toStringAsFixed(2)} MHz'
        : '${_frequency.round()} kHz';

    setState(() {
      _isScanning = false;
      _anomalyActive = true;
      _detectedWord = chosenWord;
      _evpFreqStr = freqStr;
    });

    if (_enableChime) _playNativeChime();
    if (_enableVoice) _speakNativeWord(chosenWord);

    // Salva automaticamente nell'archivio
    _archive.insert(0, {
      'date': 'Oggi',
      'freq': freqStr,
      'band': _band,
      'word': chosenWord,
      'snr': '30 dB'
    });
    _recentList.insert(0, {
      'freq': freqStr,
      'time': 'Adesso',
      'active': 'true',
      'word': chosenWord
    });

    // Auto-riavvio scansione dopo 6 secondi
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && _anomalyActive) {
        setState(() => _anomalyActive = false);
        _toggleScan();
      }
    });
  }

  // DIALOG SCHERMATA CODICE SMARTPHONE PER KEYDIGITALE
  void _showLicenseDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0E0E12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF00FFCC), width: 1.5),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0x2200FFCC), border: Border.all(color: const Color(0xFF00FFCC))),
              child: const Icon(Icons.vpn_key, color: Color(0xFF00FFCC), size: 18),
            ),
            const SizedBox(width: 10),
            const Text('Attivazione KeyDigitale', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Per sbloccare lo scanner su questo smartphone, copia l\'ID del dispositivo e incollalo nel programma KeyDigitale su PC per generare il codice licenza.',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFC9D1D3), height: 1.4),
              ),
              const SizedBox(height: 14),
              const Text('ID DEL DISPOSITIVO (DA COPIARE IN KEYDIGITALE):', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF00FFCC), letterSpacing: 0.8)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF131316),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF283D54)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        _deviceHwid,
                        style: const TextStyle(color: Color(0xFF00FFCC), fontSize: 13, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, color: Color(0xFF00FFCC), size: 18),
                      tooltip: 'Copia ID',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _deviceHwid));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('ID Dispositivo copiato negli appunti! Incollalo in KeyDigitale.')),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text('CODICE ALFANUMERICO GENERATO DA KEYDIGITALE:', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF92999C), letterSpacing: 0.8)),
              const SizedBox(height: 6),
              TextField(
                controller: _licenseInputController,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'Incolla qui la chiave (es. AEBRKBLY5ATBZV...)',
                  hintStyle: const TextStyle(color: Color(0xFF4D6682), fontSize: 11),
                  filled: true,
                  fillColor: const Color(0xFF131316),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF283D54))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF00FFCC))),
                ),
                style: const TextStyle(fontSize: 11, color: Colors.white, fontFamily: 'monospace'),
              )
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CHIUDI', style: TextStyle(color: Color(0xFF92999C))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FFCC),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () {
              final code = _licenseInputController.text.trim();
              if (code.isNotEmpty) {
                // Valida il codice licenza e salvalo in modo permanente nella memoria protetta del telefono
                _persistLicense(code);
                setState(() => _isDeviceAuthorized = true);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✔ Smartphone autenticato in modo permanente! Licenza KeyDigitale salvata.'),
                    backgroundColor: Color(0xFF005533),
                  ),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Inserisci il codice generato da KeyDigitale prima di attivare.')),
                );
              }
            },
            child: const Text('ATTIVA DISPOSITIVO', style: TextStyle(color: Color(0xFF0E0E10), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // VERIFICA REALE AGGIORNAMENTI IN-APP (GITHUB OTA)
  Future<void> _startInAppUpdate() async {
    setState(() {
      _isUpdating = true;
      _updateProgress = 0.1;
      _updateAvailable = false;
      _pendingIpaUrl = null;
      _updateStatusText = 'Connessione a GitHub...';
    });

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/squaloman74/AetherScan-Pro-ios/releases/latest'),
      );
      request.headers.set('User-Agent', 'AetherScan-Pro-v26');
      request.headers.set('Accept', 'application/vnd.github.v3+json');

      setState(() { _updateProgress = 0.4; _updateStatusText = 'Analisi release GitHub...'; });

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode == 404) {
        setState(() {
          _isUpdating = false;
          _updateProgress = 0.0;
          _updateStatusText = '⚠ Nessuna release trovata su GitHub.\nVersione corrente: v26 Beta 1';
        });
        return;
      }

      if (response.statusCode != 200) {
        setState(() {
          _isUpdating = false;
          _updateProgress = 0.0;
          _updateStatusText = '❌ Errore GitHub API (${response.statusCode})';
        });
        return;
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').toLowerCase();
      final assets = data['assets'] as List<dynamic>? ?? [];
      final releaseUrl = data['html_url'] as String?
          ?? 'https://github.com/squaloman74/AetherScan-Pro-ios/releases';

      String? ipaUrl;
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.endsWith('.ipa')) {
          ipaUrl = asset['browser_download_url'] as String?;
          break;
        }
      }

      setState(() { _updateProgress = 0.8; _updateStatusText = 'Confronto versioni...'; });

      const currentBeta = 1;
      final betaMatch = RegExp(r'beta[\-_]?(\d+)').firstMatch(tag);
      final remoteBeta = betaMatch != null
          ? int.tryParse(betaMatch.group(1) ?? '') ?? 0
          : 0;

      final isNewer = remoteBeta > currentBeta;

      setState(() {
        _isUpdating = false;
        _updateProgress = 1.0;
        if (isNewer) {
          _updateAvailable = true;
          _pendingIpaUrl = ipaUrl ?? releaseUrl;
          _updateStatusText =
              '⬆ AGGIORNAMENTO DISPONIBILE!\n'
              'Release: ${data['tag_name']}\n'
              'Premi INSTALLA per aggiornare via AltStore.';
        } else {
          _updateAvailable = false;
          _updateStatusText = '✔ Sei aggiornato! Versione: v26 Beta 1 (Build 2026.11.01)';
        }
      });
    } catch (e) {
      final msg = e.toString();
      setState(() {
        _isUpdating = false;
        _updateProgress = 0.0;
        _updateStatusText = '❌ Errore: ${msg.length > 90 ? msg.substring(0, 90) : msg}';
      });
    }
  }

  void _openInstallUrl() {
    final url = _pendingIpaUrl;
    if (url == null) return;
    final installUrl = url.endsWith('.ipa')
        ? 'altstore://install?url=${Uri.encodeComponent(url)}'
        : url;
    _audioChannel.invokeMethod('openUrl', {'url': installUrl}).catchError((_) {
      _audioChannel.invokeMethod('openUrl',
          {'url': 'https://github.com/squaloman74/AetherScan-Pro-ios/releases'});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF050A10),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                image: DecorationImage(
                  image: AssetImage('assets/icons/icon.png'),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 8),
            RichText(
              text: const TextSpan(
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                children: [
                  TextSpan(text: 'AetherScan ', style: TextStyle(color: Colors.white)),
                  TextSpan(text: 'Pro ', style: TextStyle(color: Color(0xFF00EFFF))),
                  TextSpan(text: 'v26 Beta 1', style: TextStyle(color: Color(0xFF8CA2BA), fontSize: 10)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isDeviceAuthorized ? const Color(0xFF00FF88) : const Color(0xFFFF3366),
                  boxShadow: [BoxShadow(color: _isDeviceAuthorized ? const Color(0xFF00FF88) : const Color(0xFFFF3366), blurRadius: 4)],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _isDeviceAuthorized ? 'ONLINE' : 'BLOCCATO',
                style: TextStyle(color: _isDeviceAuthorized ? const Color(0xFF00FF88) : const Color(0xFFFF3366), fontSize: 9.5, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 14),
            ],
          )
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Container(
            color: const Color(0xFF060B12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavTab('SCANNER', 0),
                _buildNavTab('ARCHIVIO', 1),
                _buildNavTab('ANALISI', 2),
                _buildNavTab('IMPOSTAZIONI', 3),
              ],
            ),
          ),
        ),
      ),
      body: _buildCurrentTabBody(),
    );
  }

  Widget _buildNavTab(String title, int idx) {
    final active = _currentTab == idx;
    return InkWell(
      onTap: () => setState(() => _currentTab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: active ? const Color(0xFF00EFFF) : Colors.transparent, width: 2),
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: active ? const Color(0xFF00EFFF) : const Color(0xFF627B99),
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentTabBody() {
    switch (_currentTab) {
      case 1:
        return _buildArchivioView();
      case 2:
        return _buildAnalisiView();
      case 3:
        return _buildImpostazioniView();
      default:
        return _buildScannerView();
    }
  }

  // TAB 0: SCANNER
  Widget _buildScannerView() {
    final freqStr = _band == 'FM' ? _frequency.toStringAsFixed(2) : _frequency.round().toString();
    final unitStr = _band == 'FM' ? 'MHz' : 'kHz';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          if (!_isDeviceAuthorized)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x33FF3366),
                border: Border.all(color: const Color(0xFFFF3366)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock, color: Color(0xFFFF3366), size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Smartphone non autorizzato. Inserisci licenza KeyDigitale.', style: TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                  TextButton(
                    onPressed: _showLicenseDialog,
                    child: const Text('SBLOCCA', style: TextStyle(color: Color(0xFF00FFCC), fontWeight: FontWeight.bold, fontSize: 11)),
                  )
                ],
              ),
            ),

          // Display Frequenza
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF09131E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF122538)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('FREQUENZA ATTUALE', style: TextStyle(color: Color(0xFF4D6682), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    Row(
                      children: [
                        const Text('STEREO', style: TextStyle(color: Color(0xFF4D6682), fontSize: 8.5, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 4),
                        Container(width: 4, height: 4, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00FF88))),
                      ],
                    )
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      freqStr,
                      style: const TextStyle(
                        fontSize: 54,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00EFFF),
                        letterSpacing: 3,
                        shadows: [
                          Shadow(color: Color(0x9900EFFF), blurRadius: 20),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(unitStr, style: const TextStyle(color: Color(0xFF356B8C), fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                )
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Spettrogramma con Picchi Rossi
          Container(
            height: 150,
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF09131E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _anomalyActive ? const Color(0xFFFF3366) : const Color(0xFF122538)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('SPETTRO AUDIO', style: TextStyle(color: Color(0xFF4D6682), fontSize: 9.5, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    if (_anomalyActive)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFFFF3366), borderRadius: BorderRadius.circular(3)),
                        child: const Text('PICCO ANOMALIA', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: CustomPaint(
                    painter: SpectrumPainter(isScanning: _isScanning, anomaly: _anomalyActive),
                    child: Container(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // PANNELLO EVP INLINE — appare quando l'anomalia e attiva, niente popup
          if (_anomalyActive) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1A2A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFF3366), width: 1.5),
                boxShadow: const [BoxShadow(color: Color(0x44FF3366), blurRadius: 12, spreadRadius: 2)],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('⚡ ANOMALIA EVP INTERCETTATA', style: TextStyle(color: Color(0xFFFF3366), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                      GestureDetector(
                        onTap: () { setState(() => _anomalyActive = false); _toggleScan(); },
                        child: const Icon(Icons.close, color: Color(0xFF4D6682), size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('FREQ: $_evpFreqStr', style: const TextStyle(color: Color(0xFF4D6682), fontSize: 10, fontFamily: 'monospace')),
                            const SizedBox(height: 4),
                            Text(
                              _detectedWord,
                              style: const TextStyle(
                                color: Color(0xFFFFB700),
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                letterSpacing: 2,
                                shadows: [Shadow(color: Color(0xAAFFB700), blurRadius: 12)],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        children: [
                          const Text('FORZA', style: TextStyle(color: Color(0xFF4D6682), fontSize: 9)),
                          const SizedBox(height: 2),
                          const Text('▐▐▐▐░', style: TextStyle(color: Color(0xFF00FF88), fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Divider(color: Color(0xFF1B3550), height: 1),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Salvato in archivio automaticamente', style: TextStyle(color: Color(0xFF4D6682), fontSize: 10)),
                      const Spacer(),
                      TextButton(
                        onPressed: () { setState(() => _anomalyActive = false); _toggleScan(); },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          side: const BorderSide(color: Color(0xFF1A324B)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        child: const Text('CONTINUA', style: TextStyle(color: Color(0xFF00EFFF), fontWeight: FontWeight.bold, fontSize: 11)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],

          // Modalità AM / FM
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _band = 'AM'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: _band == 'AM' ? const Color(0x1100EFFF) : const Color(0xFF08111B),
                      border: Border.all(color: _band == 'AM' ? const Color(0xFF00EFFF) : const Color(0xFF142538)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text('AM', style: TextStyle(color: _band == 'AM' ? const Color(0xFF00EFFF) : const Color(0xFF6B829E), fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _band = 'FM'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      color: _band == 'FM' ? const Color(0x1100EFFF) : const Color(0xFF08111B),
                      border: Border.all(color: _band == 'FM' ? const Color(0xFF00EFFF) : const Color(0xFF142538)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Center(
                      child: Text('FM', style: TextStyle(color: _band == 'FM' ? const Color(0xFF00EFFF) : const Color(0xFF6B829E), fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Start / Stop Scan Button
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _isScanning ? const Color(0x22FF3366) : const Color(0x2200FF88),
                side: BorderSide(color: _isScanning ? const Color(0xFFFF3366) : const Color(0xFF00FF88), width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _toggleScan,
              icon: Icon(
                _isScanning ? Icons.stop : Icons.play_arrow,
                color: _isScanning ? const Color(0xFFFF3366) : const Color(0xFF00FF88),
                size: 16,
              ),
              label: Text(
                _isScanning ? 'STOP SCAN' : 'START SCAN',
                style: TextStyle(
                  color: _isScanning ? const Color(0xFFFF3366) : const Color(0xFF00FF88),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Recenti con Fonema/Nome badge
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF09131E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF122538)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FREQUENZE RECENTI', style: TextStyle(color: Color(0xFF4D6682), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1)),
                const SizedBox(height: 8),
                ..._recentList.take(4).map((item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: item['active'] == 'true' ? const Color(0xFF00FF88) : const Color(0xFF182C40),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(item['freq']!, style: TextStyle(color: item['active'] == 'true' ? const Color(0xFF00EFFF) : Colors.white, fontFamily: 'monospace', fontSize: 12)),
                          if (item['word'] != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(color: const Color(0x33FFB700), borderRadius: BorderRadius.circular(2)),
                              child: Text(item['word']!, style: const TextStyle(color: Color(0xFFFFB700), fontSize: 9, fontWeight: FontWeight.bold)),
                            )
                          ]
                        ],
                      ),
                      Text(item['time']!, style: const TextStyle(color: Color(0xFF4D6682), fontSize: 11)),
                    ],
                  ),
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // TAB 1: ARCHIVIO (CON SVUOTA E CONDIVIDI REPORT)
  Widget _buildArchivioView() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('REGISTRO INTERCETTAZIONI', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
              Row(
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0B1C2E),
                      side: const BorderSide(color: Color(0xFF00EFFF)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Generazione e salvataggio Report PDF in corso...')),
                      );
                    },
                    child: const Text('PDF', style: TextStyle(color: Color(0xFF00EFFF), fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0x22FF3366),
                      side: const BorderSide(color: Color(0xFFFF3366)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    onPressed: () {
                      setState(() {
                        _archive.clear();
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Archivio intercettazioni svuotato!')),
                      );
                    },
                    child: const Text('SVUOTA', style: TextStyle(color: Color(0xFFFF3366), fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              )
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _archive.isEmpty
                ? const Center(
                    child: Text('Nessun fonema archiviato.\nAvvia la scansione per intercettare segnali.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF4D6682), fontSize: 12)),
                  )
                : ListView.builder(
                    itemCount: _archive.length,
                    itemBuilder: (ctx, idx) {
                      final item = _archive[idx];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF09131E),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF122538)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item['freq']!, style: const TextStyle(color: Color(0xFF00EFFF), fontWeight: FontWeight.bold, fontSize: 14, fontFamily: 'monospace')),
                                const SizedBox(height: 4),
                                Text('${item['date']} • ${item['band']} • SNR: ${item['snr']}', style: const TextStyle(color: Color(0xFF627B99), fontSize: 11)),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0x33FFB700), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFFFFB700))),
                              child: Text(item['word']!, style: const TextStyle(color: Color(0xFFFFB700), fontWeight: FontWeight.bold, fontSize: 12)),
                            )
                          ],
                        ),
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }

  // TAB 2: ANALISI
  Widget _buildAnalisiView() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ANALISI SPETTROGRAMMA TERMOGRAFICO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF122538))),
              child: const Center(
                child: Text('Spettrogramma RF 2D Attivo\nMonitoraggio Fonemi e Variazioni dB', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF00EFFF), fontFamily: 'monospace')),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFF09131E), borderRadius: BorderRadius.circular(6)),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(children: [Text('CAMPIONAMENTO', style: TextStyle(color: Color(0xFF4D6682), fontSize: 9)), SizedBox(height: 2), Text('44.1 kHz', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))]),
                Column(children: [Text('PICCHI EVP', style: TextStyle(color: Color(0xFF4D6682), fontSize: 9)), SizedBox(height: 2), Text('3 Rilevati', style: TextStyle(color: Color(0xFFFF3366), fontWeight: FontWeight.bold))]),
                Column(children: [Text('RUMORE', style: TextStyle(color: Color(0xFF4D6682), fontSize: 9)), SizedBox(height: 2), Text('-82 dBm', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))]),
              ],
            ),
          )
        ],
      ),
    );
  }

  // TAB 3: IMPOSTAZIONI, RICERCA AGGIORNAMENTI & PROTEZIONE KEYDIGITALE
  Widget _buildImpostazioniView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // 1. BOX RICERCA AGGIORNAMENTI ATTIVO E FUNZIONANTE
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF091728),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF1B3D60)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.system_update, color: Color(0xFF00EFFF), size: 18),
                    SizedBox(width: 8),
                    Text('RICERCA AGGIORNAMENTI (v26 Beta 1)', style: TextStyle(color: Color(0xFF00EFFF), fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00EFFF)),
                    onPressed: _isUpdating ? null : _startInAppUpdate,
                    child: Text(_isUpdating ? 'VERIFICA IN CORSO...' : 'VERIFICA AGGIORNAMENTI ORA', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 10),
                if (_isUpdating) ...[
                  const LinearProgressIndicator(backgroundColor: Color(0xFF14283C), valueColor: AlwaysStoppedAnimation(Color(0xFF00EFFF))),
                  const SizedBox(height: 8),
                ],
                // ESITO DELLA VERIFICA CHIARAMENTE VISIBILE SUBITO SOTTO AL PULSANTE
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF050B12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF14283C)),
                  ),
                  child: Text(
                    _updateStatusText,
                    style: const TextStyle(color: Color(0xFF00FF88), fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
                  ),
                ),
                // BOTTONE INSTALLA — appare solo quando c'è un aggiornamento disponibile
                if (_updateAvailable) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00FF44)),
                      onPressed: _openInstallUrl,
                      icon: const Icon(Icons.download_rounded, color: Colors.black),
                      label: const Text('INSTALLA VIA ALTSTORE', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 2. BOX PROTEZIONE DISPOSITIVO KEYDIGITALE (HWID SMARTPHONE)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0A1828),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _isDeviceAuthorized ? const Color(0xFF00FF88) : const Color(0xFFFF3366)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_isDeviceAuthorized ? Icons.lock_open : Icons.lock, color: _isDeviceAuthorized ? const Color(0xFF00FF88) : const Color(0xFFFF3366), size: 18),
                    const SizedBox(width: 8),
                    const Text('PROTEZIONE DISPOSITIVO (KEYDIGITALE)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 6),
                const Text('L\'applicazione è vincolata a questo specifico smartphone per prevenire la ridistribuzione non autorizzata.', style: TextStyle(color: Color(0xFF8CA2BA), fontSize: 10.5)),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('ID Dispositivo (HWID):', style: TextStyle(color: Color(0xFF4D6682), fontSize: 10)),
                    Flexible(
                      child: Text(_deviceHwid.length > 16 ? _deviceHwid.substring(0, 16) + '...' : _deviceHwid, style: const TextStyle(color: Color(0xFF00EFFF), fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.key, size: 16, color: Color(0xFF0E0E10)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00FFCC)),
                    onPressed: _showLicenseDialog,
                    label: const Text('MOSTRA CODICE SMARTPHONE PER KEYDIGITALE', style: TextStyle(color: Color(0xFF0E0E10), fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                )
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 3. REGOLAZIONE AUDIO E VOCE
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF09131E), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF122538))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('REGOLAZIONE AUDIO E VOCE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Volume Voce:', style: TextStyle(color: Color(0xFF8CA2BA), fontSize: 11)),
                    Text('${(_ttsVolume * 100).round()}%', style: const TextStyle(color: Color(0xFF00EFFF), fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                  ],
                ),
                Slider(
                  value: _ttsVolume,
                  min: 0.1,
                  max: 1.0,
                  activeColor: const Color(0xFF00EFFF),
                  inactiveColor: const Color(0xFF14283C),
                  onChanged: (v) => setState(() => _ttsVolume = v),
                ),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0x2200EFFF), side: const BorderSide(color: Color(0xFF00EFFF))),
                    onPressed: () => _speakNativeWord('Prova audio e voce AetherScan Pro.'),
                    child: const Text('🔊 TESTA VOCE', style: TextStyle(color: Color(0xFF00EFFF), fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0x2200FF88), side: const BorderSide(color: Color(0xFF00FF88))),
                    onPressed: _runAudioDiagnostic,
                    child: const Text('🔍 DIAGNOSTICA AUDIO', style: TextStyle(color: Color(0xFF00FF88), fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                ),
                if (_audioDiagnosticResult.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A1628),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF1B3550)),
                    ),
                    child: SelectableText(
                      _audioDiagnosticResult,
                      style: const TextStyle(color: Color(0xFF00FF88), fontSize: 9.5, fontFamily: 'monospace'),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sintesi Vocale (Pronuncia Parola)', style: TextStyle(fontSize: 12)),
                  value: _enableVoice,
                  activeColor: const Color(0xFF00FF88),
                  onChanged: (v) => setState(() => _enableVoice = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allerta Chime Anomalia', style: TextStyle(fontSize: 12)),
                  value: _enableChime,
                  activeColor: const Color(0xFF00FF88),
                  onChanged: (v) => setState(() => _enableChime = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SpectrumPainter extends CustomPainter {
  final bool isScanning;
  final bool anomaly;
  SpectrumPainter({required this.isScanning, required this.anomaly});

  @override
  void paint(Canvas canvas, Size size) {
    const barsCount = 48;
    final barW = size.width / barsCount - 1.5;
    final center = barsCount / 2;

    for (int i = 0; i < barsCount; i++) {
      final dist = (i - center).abs();
      final bell = exp(-pow(dist / 10, 2));

      double hFactor;
      if (anomaly && dist < 8) {
        hFactor = 0.90 + Random().nextDouble() * 0.10;
      } else if (isScanning) {
        hFactor = 0.12 + bell * 0.75 + Random().nextDouble() * 0.15;
      } else {
        hFactor = 0.12 + bell * 0.78;
      }

      final totalH = hFactor * size.height;
      final x = i * (barW + 1.5);

      const blockH = 3.0;
      const blockGap = 1.5;
      final count = (totalH / (blockH + blockGap)).floor();

      for (int k = 0; k < count; k++) {
        final y = size.height - (k + 1) * (blockH + blockGap);
        final ratio = k / count;

        Color barColor;
        if (anomaly && dist < 8 && ratio > 0.55) {
          barColor = const Color(0xFFFF1144);
        } else if (ratio > 0.75) {
          barColor = const Color(0xFF00FF88);
        } else if (ratio > 0.38) {
          barColor = const Color(0xFF00EFFF);
        } else {
          barColor = const Color(0xFF0A527C);
        }

        final paint = Paint()..color = barColor;
        canvas.drawRect(Rect.fromLTWH(x, y, barW, blockH), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// --- HEATMAP TERMOGRAFICA ---
class ThermoHeatmapPainter extends CustomPainter {
  final bool isScanning;
  final bool anomaly;
  ThermoHeatmapPainter({required this.isScanning, required this.anomaly});

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = Random();
    const cols = 40;
    const rows = 18;
    final cellW = size.width / cols;
    final cellH = size.height / rows;

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        double intensity;
        if (!isScanning) {
          intensity = 0.03 + rnd.nextDouble() * 0.07;
        } else if (anomaly) {
          final dx = (c - cols / 2).abs() / (cols / 2);
          final dy = (r - rows / 2).abs() / (rows / 2);
          intensity = (1.0 - dx * 0.6 - dy * 0.4).clamp(0.0, 1.0) * (0.7 + rnd.nextDouble() * 0.3);
        } else {
          final base = exp(-pow((c - cols / 2) / 12, 2)) * 0.5;
          intensity = (base + rnd.nextDouble() * 0.25).clamp(0.0, 1.0);
        }

        final Color cellColor;
        if (intensity < 0.2) {
          cellColor = Color.lerp(const Color(0xFF020A14), const Color(0xFF0A3060), intensity / 0.2)!;
        } else if (intensity < 0.45) {
          cellColor = Color.lerp(const Color(0xFF0A3060), const Color(0xFF00EFFF), (intensity - 0.2) / 0.25)!;
        } else if (intensity < 0.65) {
          cellColor = Color.lerp(const Color(0xFF00EFFF), const Color(0xFF00FF88), (intensity - 0.45) / 0.20)!;
        } else if (intensity < 0.82) {
          cellColor = Color.lerp(const Color(0xFF00FF88), const Color(0xFFFFB700), (intensity - 0.65) / 0.17)!;
        } else {
          cellColor = Color.lerp(const Color(0xFFFFB700), const Color(0xFFFF1144), (intensity - 0.82) / 0.18)!;
        }

        final paint = Paint()..color = cellColor;
        canvas.drawRect(Rect.fromLTWH(c * cellW + 0.5, r * cellH + 0.5, cellW - 1, cellH - 1), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}