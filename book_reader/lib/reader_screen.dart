import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:epubx/epubx.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SegmentType { narration, dialogue }

class TextSegment {
  final String text;
  final SegmentType type;
  TextSegment(this.text, this.type);
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  static const _platform = MethodChannel('com.example.book_reader/tts_service');
  List<TextSegment> _segments = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  String _status = 'Open an ePub or TXT file to begin';
  String _bookTitle = '';
  double _speed = 1.0;
  double _pitch = 1.0;
  String _selectedLocale = 'en-GB';
  final ScrollController _scrollController = ScrollController();

  final List<Map<String, String>> _accents = [
    {'label': '🇬🇧 British English', 'locale': 'en-GB'},
    {'label': '🇺🇸 American English', 'locale': 'en-US'},
    {'label': '🇦🇺 Australian English', 'locale': 'en-AU'},
    {'label': '🇮🇳 Indian English', 'locale': 'en-IN'},
    {'label': '🇮🇪 Irish English', 'locale': 'en-IE'},
    {'label': '🇿🇦 South African English', 'locale': 'en-ZA'},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedLocale = prefs.getString('locale') ?? 'en-GB';
      _speed = prefs.getDouble('speed') ?? 1.0;
      _pitch = prefs.getDouble('pitch') ?? 1.0;
    });
    await _applyTtsSettings();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', _selectedLocale);
    await prefs.setDouble('speed', _speed);
    await prefs.setDouble('pitch', _pitch);
  }

  Future<void> _startForegroundService(String sentence) async {
    try {
      await _platform.invokeMethod('startService', {'sentence': sentence});
    } catch (_) {}
  }

  Future<void> _stopForegroundService() async {
    try {
      await _platform.invokeMethod('stopService');
    } catch (_) {}
  }

  Future<void> _initTts() async {
    _tts.setCompletionHandler(() async {
      if (_isPlaying && _currentIndex < _segments.length - 1) {
        setState(() => _currentIndex++);
        _scrollToCurrentSentence();
        await _speakCurrent();
      } else {
        await _stopForegroundService();
        setState(() { _isPlaying = false; _status = 'Finished!'; });
      }
    });
    _tts.setErrorHandler((msg) async {
      await _stopForegroundService();
      setState(() { _isPlaying = false; _status = 'Error: $msg'; });
    });
    await _applyTtsSettings();
  }

  Future<void> _applyTtsSettings() async {
    await _tts.setLanguage(_selectedLocale);
    await _tts.setSpeechRate(_speed * 0.5);
    await _tts.setPitch(_pitch);
  }

  Future<void> _pickFile() async {
    const params = OpenFileDialogParams(
      dialogType: OpenFileDialogType.document,
      allowedUtiTypes: ['public.item'],
    );
    final filePath = await FlutterFileDialog.pickFile(params: params);
    if (filePath == null) return;

    final file = File(filePath);
    final fileName = filePath.split('/').last;
    final ext = fileName.split('.').last.toLowerCase();

    setState(() {
      _status = 'Reading file...';
      _isPlaying = false;
      _segments = [];
      _currentIndex = 0;
      _bookTitle = fileName;
    });
    await _tts.stop();
    await _stopForegroundService();

    try {
      String text = '';
      final bytes = await file.readAsBytes();
      if (ext == 'txt') {
        text = utf8.decode(bytes);
      } else if (ext == 'epub') {
        text = await _extractEpub(bytes);
      } else {
        setState(() => _status = 'Please open an ePub or TXT file');
        return;
      }
      if (text.trim().isEmpty) {
        setState(() => _status = 'Could not extract text from file');
        return;
      }
      setState(() {
        _segments = _parseSegments(text);
        _status = 'Ready — tap play to listen';
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<String> _extractEpub(List<int> bytes) async {
    final epub = await EpubReader.readBook(bytes);
    final buffer = StringBuffer();
    final chapters = epub.Chapters;
    if (chapters != null) {
      for (final chapter in chapters) {
        final content = chapter.HtmlContent ?? '';
        final text = content
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .replaceAll(RegExp(r'&[a-zA-Z]+;'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (text.isNotEmpty) buffer.writeln(text);
        if (chapter.SubChapters != null) {
          for (final sub in chapter.SubChapters!) {
            final subContent = sub.HtmlContent ?? '';
            final subText = subContent
                .replaceAll(RegExp(r'<[^>]*>'), ' ')
                .replaceAll(RegExp(r'&[a-zA-Z]+;'), ' ')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            if (subText.isNotEmpty) buffer.writeln(subText);
          }
        }
      }
    }
    return buffer.toString();
  }

  List<TextSegment> _parseSegments(String text) {
    final segments = <TextSegment>[];
    final pattern = RegExp(
      r'(["\u201C\u2018][^"\u201D\u2019]*["\u201D\u2019])|([^"\u201C\u2018\u201D\u2019]+)',
      dotAll: true,
    );
    final matches = pattern.allMatches(text);
    final buffer = StringBuffer();
    SegmentType currentType = SegmentType.narration;

    void flushBuffer() {
      final s = buffer.toString().trim();
      if (s.isNotEmpty) {
        if (currentType == SegmentType.narration) {
          final sentences = s.split(RegExp(r'(?<=[.!?])\s+'));
          for (final sentence in sentences) {
            final trimmed = sentence.trim();
            if (trimmed.length > 4) {
              segments.add(TextSegment(trimmed, SegmentType.narration));
            }
          }
        } else {
          segments.add(TextSegment(s, SegmentType.dialogue));
        }
        buffer.clear();
      }
    }

    for (final match in matches) {
      if (match.group(1) != null) {
        flushBuffer();
        currentType = SegmentType.dialogue;
        buffer.write(match.group(1));
        flushBuffer();
        currentType = SegmentType.narration;
      } else if (match.group(2) != null) {
        buffer.write(match.group(2));
      }
    }
    flushBuffer();
    return segments.where((s) => s.text.length > 4).toList();
  }

  Future<void> _speakCurrent() async {
    if (_currentIndex >= _segments.length) return;
    final text = _segments[_currentIndex].text;
    setState(() => _status = 'Speaking...');
    await _startForegroundService(text);
    await _tts.speak(text);
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _tts.stop();
      await _stopForegroundService();
      setState(() { _isPlaying = false; _status = 'Paused'; });
      return;
    }
    if (_segments.isEmpty) return;
    setState(() => _isPlaying = true);
    await _speakCurrent();
  }

  void _scrollToCurrentSentence() {
    if (!_scrollController.hasClients) return;
    final offset = _currentIndex * 80.0;
    _scrollController.animateTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _skip(int count) async {
    final wasPlaying = _isPlaying;
    await _tts.stop();
    setState(() {
      _isPlaying = false;
      _currentIndex = (_currentIndex + count).clamp(0, _segments.length - 1);
    });
    _scrollToCurrentSentence();
    if (wasPlaying) {
      setState(() => _isPlaying = true);
      await _speakCurrent();
    }
  }

  void _showAccentPicker() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Choose Accent', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          ..._accents.map((a) => ListTile(
            title: Text(a['label']!),
            trailing: _selectedLocale == a['locale']
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: () async {
              setState(() => _selectedLocale = a['locale']!);
              await _applyTtsSettings();
              await _savePrefs();
              Navigator.pop(context);
            },
          )),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tts.stop();
    _stopForegroundService();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = _segments.isEmpty ? 0.0 : (_currentIndex + 1) / _segments.length;
    final currentAccent = _accents.firstWhere(
      (a) => a['locale'] == _selectedLocale,
      orElse: () => _accents[0],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_bookTitle.isEmpty ? 'Book Reader' : _bookTitle, overflow: TextOverflow.ellipsis),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.folder_open), onPressed: _pickFile),
          IconButton(icon: const Icon(Icons.language), onPressed: _showAccentPicker),
        ],
      ),
      body: Column(
        children: [
          LinearProgressIndicator(value: progress, minHeight: 3),
          Expanded(
            child: _segments.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.book, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(_status, style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(onPressed: _pickFile, icon: const Icon(Icons.upload_file), label: const Text('Open Book')),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    itemCount: _segments.length,
                    itemBuilder: (context, index) {
                      final isActive = index == _currentIndex;
                      final segment = _segments[index];
                      final isDialogue = segment.type == SegmentType.dialogue;
                      Color bgColor = Colors.transparent;
                      if (isActive) {
                        bgColor = Theme.of(context).colorScheme.primaryContainer;
                      } else if (isDialogue) {
                        bgColor = isDark ? const Color(0xFF3D3000) : const Color(0xFFFFF8E1);
                      }
                      return GestureDetector(
                        onTap: () async {
                          final wasPlaying = _isPlaying;
                          await _tts.stop();
                          setState(() { _isPlaying = false; _currentIndex = index; });
                          _scrollToCurrentSentence();
                          if (wasPlaying) { setState(() => _isPlaying = true); await _speakCurrent(); }
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: BorderRadius.circular(8),
                            border: isDialogue && !isActive
                                ? Border.all(color: const Color(0xFFFFD54F), width: 1)
                                : null,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isDialogue)
                                const Padding(
                                  padding: EdgeInsets.only(right: 6, top: 2),
                                  child: Icon(Icons.format_quote, size: 14, color: Color(0xFFFFB300)),
                                ),
                              Expanded(
                                child: Text(
                                  segment.text,
                                  style: TextStyle(
                                    fontSize: 17,
                                    height: 1.7,
                                    fontStyle: isDialogue ? FontStyle.italic : FontStyle.normal,
                                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                                    color: isActive
                                        ? Theme.of(context).colorScheme.onPrimaryContainer
                                        : isDialogue
                                            ? (isDark ? const Color(0xFFFFE082) : const Color(0xFF6D4C00))
                                            : Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
            ),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _showAccentPicker,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(currentAccent['label']!, style: const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(_status, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                Text(
                  _segments.isEmpty ? '0 / 0' : '${_currentIndex + 1} / ${_segments.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(icon: const Icon(Icons.replay_5), iconSize: 32, onPressed: _segments.isEmpty ? null : () => _skip(-5)),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: _segments.isEmpty ? null : _togglePlay,
                      child: Container(
                        width: 64, height: 64,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.primary),
                        child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Theme.of(context).colorScheme.onPrimary, size: 36),
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton(icon: const Icon(Icons.forward_5), iconSize: 32, onPressed: _segments.isEmpty ? null : () => _skip(5)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Text('Speed', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _speed, min: 0.5, max: 2.0, divisions: 6, label: '${_speed}x',
                        onChanged: (val) async {
                          setState(() => _speed = val);
                          await _tts.setSpeechRate(val * 0.5);
                          await _savePrefs();
                        },
                      ),
                    ),
                    Text('${_speed.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 12)),
                  ],
                ),
                Row(
                  children: [
                    const Text('Pitch ', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _pitch, min: 0.5, max: 2.0, divisions: 6, label: '${_pitch}',
                        onChanged: (val) async {
                          setState(() => _pitch = val);
                          await _tts.setPitch(val);
                          await _savePrefs();
                        },
                      ),
                    ),
                    Text('${_pitch.toStringAsFixed(1)}x', style: const TextStyle(fontSize: 12)),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.format_quote, size: 12, color: Color(0xFFFFB300)),
                    const SizedBox(width: 4),
                    Text('Dialogue', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    const SizedBox(width: 16),
                    Container(width: 12, height: 12, color: Theme.of(context).colorScheme.primaryContainer),
                    const SizedBox(width: 4),
                    Text('Currently reading', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
