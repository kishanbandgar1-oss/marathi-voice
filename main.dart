import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

// ElevenLabs API helper
// ---------------------------------------------------------------------------
class Eleven {
  static const _base = 'https://api.elevenlabs.io/v1';

  static String _err(http.Response res) {
    var msg = utf8.decode(res.bodyBytes, allowMalformed: true);
    try {
      final j = jsonDecode(msg);
      final d = j is Map ? j['detail'] : null;
      if (d is Map && d['message'] != null) {
        msg = d['message'].toString();
      } else if (d is String) {
        msg = d;
      } else if (d is List && d.isNotEmpty) {
        msg = d.first.toString();
      }
    } catch (_) {}
    if (msg.length > 300) msg = msg.substring(0, 300);
    return 'Error ${res.statusCode}: $msg';
  }

  /// Creates an Instant Voice Clone from a recorded sample. Returns voice_id.
  static Future<String> createVoice(
      String apiKey, String name, String filePath) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/voices/add'));
    req.headers['xi-api-key'] = apiKey;
    req.fields['name'] = name;
    req.fields['remove_background_noise'] = 'false';
    req.files.add(await http.MultipartFile.fromPath('files', filePath));
    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200) {
      throw Exception('${_err(res)}\n'
          '(Instant voice cloning needs a paid ElevenLabs plan and a valid API key.)');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return j['voice_id'] as String;
  }

  /// Converts text to speech in the cloned voice. Returns an mp3 file.
  static Future<File> speak({
    required String apiKey,
    required String voiceId,
    required String text,
    required String model,
  }) async {
    final res = await http
        .post(
          Uri.parse('$_base/text-to-speech/$voiceId?output_format=mp3_44100_128'),
          headers: {
            'xi-api-key': apiKey,
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
          },
          body: jsonEncode({
            'text': text,
            'model_id': model,
            'voice_settings': {
              'stability': 0.5,
              'similarity_boost': 0.85,
              'style': 0.3,
              'use_speaker_boost': true,
            },
          }),
        )
        .timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) throw Exception(_err(res));
    final dir = await getTemporaryDirectory();
    final f = File(
        '${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await f.writeAsBytes(res.bodyBytes);
    return f;
  }

  /// Voice-to-voice conversion: takes an audio recording of ANY speaker and
  /// re-renders it in the target cloned voice, keeping the original timing,
  /// pacing and delivery. This is what makes the target voice sound most
  /// realistic, since it copies the actual performance, not just the text.
  static Future<File> convert({
    required String apiKey,
    required String voiceId,
    required String sourceFilePath,
    required bool removeBackgroundNoise,
  }) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('$_base/speech-to-speech/$voiceId?output_format=mp3_44100_128'));
    req.headers['xi-api-key'] = apiKey;
    req.fields['model_id'] = 'eleven_multilingual_sts_v2';
    req.fields['remove_background_noise'] = removeBackgroundNoise.toString();
    req.fields['voice_settings'] = jsonEncode({
      'stability': 0.5,
      'similarity_boost': 0.85,
    });
    req.files.add(await http.MultipartFile.fromPath('audio', sourceFilePath));
    final streamed = await req.send().timeout(const Duration(seconds: 120));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200) throw Exception(_err(res));
    final dir = await getTemporaryDirectory();
    final f = File(
        '${dir.path}/sts_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await f.writeAsBytes(res.bodyBytes);
    return f;
  }

  /// Deletes a cloned voice from the ElevenLabs account.
  static Future<void> deleteVoice(String apiKey, String voiceId) async {
    await http.delete(
      Uri.parse('$_base/voices/$voiceId'),
      headers: {'xi-api-key': apiKey},
    );
  }
}

// ---------------------------------------------------------------------------
// Saved voice model + storage (SharedPreferences, JSON list)
// ---------------------------------------------------------------------------
class SavedVoice {
  String id; // ElevenLabs voice_id
  String name; // e.g. "Mother", "Father"

  SavedVoice(this.id, this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory SavedVoice.fromJson(Map<String, dynamic> j) =>
      SavedVoice(j['id'] as String, j['name'] as String);
}

class VoiceStore {
  static const _key = 'saved_voices';

  static List<SavedVoice> load(SharedPreferences p) {
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => SavedVoice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(SharedPreferences p, List<SavedVoice> voices) async {
    await p.setString(_key, jsonEncode(voices.map((v) => v.toJson()).toList()));
  }
}

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Marathi Voice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  SharedPreferences? _prefs;
  List<SavedVoice> _voices = [];
  bool _busyDelete = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _prefs = p;
      _voices = VoiceStore.load(p);
    });
  }

  String get _apiKey => _prefs?.getString('api_key') ?? '';

  Future<void> _needKey() async {
    final ctrl = TextEditingController(text: _apiKey);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ElevenLabs API key'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), labelText: 'API key'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && _prefs != null) {
      await _prefs!.setString('api_key', result);
      setState(() {});
    }
  }

  Future<void> _addVoice() async {
    if (_apiKey.isEmpty) {
      await _needKey();
      if (_apiKey.isEmpty) return;
    }
    if (!mounted) return;
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AddVoicePage(prefs: _prefs!)),
    );
    if (added == true) _load();
  }

  Future<void> _deleteVoice(SavedVoice v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this voice?'),
        content: Text('"${v.name}" will be removed from your saved voices.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyDelete = true);
    try {
      await Eleven.deleteVoice(_apiKey, v.id);
    } catch (_) {
      // Even if the remote delete fails (e.g. already removed), drop it locally.
    }
    _voices.removeWhere((e) => e.id == v.id);
    await VoiceStore.save(_prefs!, _voices);
    if (mounted) setState(() => _busyDelete = false);
  }

  Future<void> _rename(SavedVoice v) async {
    final ctrl = TextEditingController(text: v.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename voice'),
        content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      v.name = name;
      await VoiceStore.save(_prefs!, _voices);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _prefs;
    if (p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('माझे आवाज (My voices)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.vpn_key_outlined),
            tooltip: 'API key',
            onPressed: _needKey,
          ),
        ],
      ),
      body: _busyDelete
          ? const Center(child: CircularProgressIndicator())
          : (_voices.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.record_voice_over,
                            size: 64, color: Colors.grey),
                        const SizedBox(height: 12),
                        const Text(
                          'No saved voices yet.\nRecord a voice sample (e.g. your mother\'s) '
                          'and save it here.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _addVoice,
                          icon: const Icon(Icons.add),
                          label: const Text('Add a voice'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _voices.length,
                  itemBuilder: (_, i) {
                    final v = _voices[i];
                    return Card(
                      child: ListTile(
                        leading: const CircleAvatar(
                            child: Icon(Icons.person)),
                        title: Text(v.name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('Type text, or convert a recording'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  ChatPage(prefs: p, voice: v)),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v2) {
                            if (v2 == 'rename') _rename(v);
                            if (v2 == 'delete') _deleteVoice(v);
                            if (v2 == 'convert') {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        ConvertPage(prefs: p, voice: v)),
                              );
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'convert',
                                child: Text('Convert a recording')),
                            PopupMenuItem(
                                value: 'rename', child: Text('Rename')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    );
                  },
                )),
      floatingActionButton: _voices.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _addVoice,
              icon: const Icon(Icons.add),
              label: const Text('Add voice'),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add / record a new voice sample, clone it, save it with a name
// ---------------------------------------------------------------------------
const String kSampleText =
    'नमस्कार, मी आज तुम्हाला माझ्या गावाबद्दल थोडं सांगणार आहे. '
    'सकाळी लवकर उठून चहा घेतला की दिवस कसा सुरू होतो तेच कळत नाही. '
    'पावसाळ्यात आजूबाजूची शेतं हिरवीगार होतात आणि मन प्रसन्न होतं. '
    'तुम्ही कधी आलात तर नक्की भेटा, आपण गप्पा मारू आणि गरमागरम भजी खाऊ. '
    'तुला काय वाटतं? हे खरंच शक्य आहे का? अरे वा, किती छान! '
    'आता मी थोडं हळू बोलतो, आणि मग पुन्हा वेगाने बोलतो, म्हणजे माझा आवाज नीट ओळखता येईल.';

class AddVoicePage extends StatefulWidget {
  final SharedPreferences prefs;

  const AddVoicePage({super.key, required this.prefs});

  @override
  State<AddVoicePage> createState() => _AddVoicePageState();
}

class _AddVoicePageState extends State<AddVoicePage> {
  final _nameCtrl = TextEditingController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  Timer? _timer;
  bool _recording = false;
  bool _consent = false;
  bool _busy = false;
  int _secs = 0;
  String? _samplePath;

  static const _maxSecs = 180;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 6)));
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stopRecord();
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        _snack('Microphone permission is needed to record.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/sample_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
            encoder: AudioEncoder.wav, sampleRate: 32000, numChannels: 1),
        path: path,
      );
      setState(() {
        _recording = true;
        _secs = 0;
        _samplePath = null;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() => _secs++);
        if (_secs >= _maxSecs) _stopRecord();
      });
    } catch (e) {
      _snack('Could not start recording: $e');
    }
  }

  Future<void> _stopRecord() async {
    _timer?.cancel();
    try {
      final p = await _recorder.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _samplePath = p;
      });
      if (_secs < 30) {
        _snack('Sample is short (${_secs}s). 1-3 minutes gives a more realistic match.');
      }
    } catch (e) {
      if (mounted) setState(() => _recording = false);
      _snack('Could not stop recording: $e');
    }
  }

  Future<void> _playSample() async {
    final p = _samplePath;
    if (p == null) return;
    await _player.stop();
    await _player.play(DeviceFileSource(p));
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _snack('Give this voice a name, e.g. "Mother".');
      return;
    }
    if (_samplePath == null) {
      _snack('Please record a voice sample first.');
      return;
    }
    if (!_consent) {
      _snack('Please confirm you have permission to use this voice.');
      return;
    }
    setState(() => _busy = true);
    try {
      final key = widget.prefs.getString('api_key') ?? '';
      final id = await Eleven.createVoice(key, name, _samplePath!);
      final voices = VoiceStore.load(widget.prefs);
      voices.add(SavedVoice(id, name));
      await VoiceStore.save(widget.prefs, voices);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasSample = _samplePath != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Add a voice')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('1. Name this voice',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'e.g. Mother, Father, Friend',
            ),
          ),
          const SizedBox(height: 20),
          Text('2. Record their voice',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
              'Quiet room, phone about 20 cm from the mouth. They should read the text '
              'below naturally, 1-3 minutes, with normal emotion and pauses — more '
              'audio and varied tone gives a more realistic clone.'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(kSampleText, style: TextStyle(fontSize: 17, height: 1.5)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _toggleRecord,
                icon: Icon(_recording ? Icons.stop : Icons.mic),
                label: Text(_recording ? 'Stop' : (hasSample ? 'Record again' : 'Record')),
                style: FilledButton.styleFrom(
                  backgroundColor: _recording ? Colors.red : null,
                ),
              ),
              const SizedBox(width: 12),
              Text(_fmt(_secs), style: const TextStyle(fontSize: 18)),
              const Spacer(),
              if (hasSample && !_recording)
                OutlinedButton.icon(
                  onPressed: _playSample,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
            ],
          ),
          const SizedBox(height: 20),
          CheckboxListTile(
            value: _consent,
            onChanged: (v) => setState(() => _consent = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text(
                'I have permission from the person whose voice this is.'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: (_busy || _recording) ? null : _create,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save this voice'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Convert page: record ANY voice, re-speak it in a saved voice's tone/pitch
// ---------------------------------------------------------------------------
class ConvertPage extends StatefulWidget {
  final SharedPreferences prefs;
  final SavedVoice voice;

  const ConvertPage({super.key, required this.prefs, required this.voice});

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  Timer? _timer;
  bool _recording = false;
  bool _busy = false;
  bool _removeNoise = true;
  int _secs = 0;
  String? _sourcePath;
  File? _resultFile;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 6)));
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stopRecord();
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        _snack('Microphone permission is needed to record.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/src_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
            encoder: AudioEncoder.wav, sampleRate: 32000, numChannels: 1),
        path: path,
      );
      setState(() {
        _recording = true;
        _secs = 0;
        _sourcePath = null;
        _resultFile = null;
        _error = null;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() => _secs++);
      });
    } catch (e) {
      _snack('Could not start recording: $e');
    }
  }

  Future<void> _stopRecord() async {
    _timer?.cancel();
    try {
      final p = await _recorder.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _sourcePath = p;
      });
    } catch (e) {
      if (mounted) setState(() => _recording = false);
      _snack('Could not stop recording: $e');
    }
  }

  Future<void> _playSource() async {
    final p = _sourcePath;
    if (p == null) return;
    await _player.stop();
    await _player.play(DeviceFileSource(p));
  }

  Future<void> _playResult() async {
    final f = _resultFile;
    if (f == null) return;
    await _player.stop();
    await _player.play(DeviceFileSource(f.path));
  }

  Future<void> _convert() async {
    if (_sourcePath == null) {
      _snack('Record what you want to convert first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _resultFile = null;
    });
    try {
      final key = widget.prefs.getString('api_key') ?? '';
      final f = await Eleven.convert(
        apiKey: key,
        voiceId: widget.voice.id,
        sourceFilePath: _sourcePath!,
        removeBackgroundNoise: _removeNoise,
      );
      setState(() => _resultFile = f);
      await _playResult();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Convert into "${widget.voice.name}"')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Record anything — in your own voice — and it will be re-spoken in '
              '${widget.voice.name}\'s tone and pitch, keeping your pacing and delivery.',
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: _busy ? null : _toggleRecord,
                  child: CircleAvatar(
                    radius: 44,
                    backgroundColor: _recording ? Colors.red : cs.primary,
                    child: Icon(_recording ? Icons.stop : Icons.mic,
                        color: Colors.white, size: 36),
                  ),
                ),
                const SizedBox(height: 8),
                Text(_fmt(_secs), style: const TextStyle(fontSize: 20)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_sourcePath != null && !_recording)
            Center(
              child: OutlinedButton.icon(
                onPressed: _playSource,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play my recording'),
              ),
            ),
          const SizedBox(height: 16),
          SwitchListTile(
            value: _removeNoise,
            onChanged: (v) => setState(() => _removeNoise = v),
            title: const Text('Remove background noise'),
            subtitle: const Text('Cleans up the source recording before converting'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: (_busy || _recording || _sourcePath == null) ? null : _convert,
            icon: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.autorenew),
            label: Text(_busy ? 'Converting...' : 'Convert to ${widget.voice.name}\'s voice'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: cs.error)),
          ],
          if (_resultFile != null) ...[
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 8),
            Text('Result', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _playResult,
              icon: const Icon(Icons.play_circle_fill),
              label: const Text('Play converted voice'),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chat page: type text -> hear it in the selected saved voice
// ---------------------------------------------------------------------------
class Msg {
  final String text;
  File? audio;
  bool loading;
  String? error;

  Msg(this.text, {this.loading = true});
}

class ChatPage extends StatefulWidget {
  final SharedPreferences prefs;
  final SavedVoice voice;

  const ChatPage({super.key, required this.prefs, required this.voice});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _ctrl = TextEditingController();
  final _player = AudioPlayer();
  final List<Msg> _msgs = [];
  String _model = 'eleven_v3';

  @override
  void initState() {
    super.initState();
    _model = widget.prefs.getString('model') ?? 'eleven_v3';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _play(File f) async {
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(f.path));
    } catch (_) {}
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _ctrl.clear();
    final m = Msg(t);
    setState(() => _msgs.add(m));
    await _generate(m);
  }

  Future<void> _generate(Msg m) async {
    setState(() {
      m.loading = true;
      m.error = null;
    });
    try {
      final f = await Eleven.speak(
        apiKey: widget.prefs.getString('api_key') ?? '',
        voiceId: widget.voice.id,
        text: m.text,
        model: _model,
      );
      m.audio = f;
      if (mounted) setState(() => m.loading = false);
      await _play(f);
    } catch (e) {
      if (mounted) {
        setState(() {
          m.loading = false;
          m.error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Widget _bubble(Msg m) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(m.text, style: const TextStyle(fontSize: 18)),
              ),
              if (m.loading)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (m.error != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(m.error!,
                          style: TextStyle(color: cs.error, fontSize: 13)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () => _generate(m),
                    ),
                  ],
                )
              else if (m.audio != null)
                IconButton(
                  icon: const Icon(Icons.play_circle_fill, size: 32),
                  onPressed: () => _play(m.audio!),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.voice.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.autorenew),
            tooltip: 'Convert a recording instead',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      ConvertPage(prefs: widget.prefs, voice: widget.voice)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Type something in Marathi below.\nIt will be spoken in this voice.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.only(top: 8),
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) => _bubble(_msgs[_msgs.length - 1 - i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(fontSize: 18),
                      decoration: InputDecoration(
                        hintText: 'येथे मराठीत लिहा...',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
