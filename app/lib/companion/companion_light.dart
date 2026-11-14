// 轻量模式 (docs/design/companion.md §7): she talks to DeepSeek straight from
// the phone, with no engine and no host. The same Messages API the engine's
// DeepSeek adapter uses (@deepseek-ai/dsh-llm-deepseek), with the API key
// saved in the app; her conversation is a small file next to the pack.
//
// A channel added under 酒馆 › 渠道 (tavern_channels.dart) can answer instead:
// it speaks OpenAI's Chat Completions format, so any relay, OpenRouter or a
// model on the person's own computer works. [CompanionLightChannel] carries
// that endpoint; the key is read by the caller and never kept here.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'companion_context.dart';

const companionLightEndpoint = 'https://api.deepseek.com/anthropic/v1/messages';

/// The fast model of the official route (text and images); thinking off, so a
/// line comes back as quickly as she would say it.
const companionLightModel = 'deepseek-flash';

/// Her reply's endpoint when it is not DeepSeek's own: an OpenAI-compatible
/// Chat Completions service added in 酒馆 › 渠道. [baseUrl] is as typed (a root
/// or a whole `…/chat/completions` URL); [headers] are the channel's own.
class CompanionLightChannel {
  const CompanionLightChannel({required this.baseUrl, required this.model, this.headers = const {}});

  final String baseUrl;
  final String model;
  final Map<String, String> headers;
}

/// Where [baseUrl]'s Chat Completions sits: a whole `/chat/completions` URL is
/// kept, anything else gets the path appended (the tavern's own rule, without
/// DeepSeek's `/beta`).
Uri companionChatCompletionsUrl(String baseUrl) {
  final uri = Uri.parse(baseUrl.trim()).removeFragment();
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (!path.endsWith('/chat/completions')) path = '$path/chat/completions';
  return uri.replace(path: path, query: uri.query.isEmpty ? null : uri.query);
}

/// One verbatim transcript line. Request-only context is assembled separately.
class CompanionLine {
  const CompanionLine.user(this.text, {this.legacyText}) : fromHer = false;
  const CompanionLine.her(this.text) : fromHer = true, legacyText = null;

  static CompanionLine? fromJson(Object? json, {int version = 2}) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String || text.isEmpty) return null;
    final migrated = companionMigrateLegacyLine(text, version: version, user: json['role'] == 'user');
    return switch (json['role']) {
      'user' => CompanionLine.user(
        migrated.text,
        legacyText: migrated.legacyText ?? (json['legacyText'] is String ? json['legacyText'] as String : null),
      ),
      'assistant' => CompanionLine.her(text),
      _ => null,
    };
  }

  final bool fromHer;
  final String text;

  /// Lossless backup for a narrowly recognized v1 generated prefix.
  final String? legacyText;

  String get role => fromHer ? 'assistant' : 'user';

  Map<String, Object?> toJson() => {'role': role, 'text': text, if (legacyText != null) 'legacyText': legacyText};
}

enum CompanionLightFailure { noKey, badKey, busy, network, server }

class CompanionLightError implements Exception {
  const CompanionLightError(this.failure, [this.detail]);

  final CompanionLightFailure failure;
  final String? detail;

  @override
  String toString() => 'CompanionLightError(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Her reply to [lines], as text deltas. Cancelling the subscription drops the
/// request; [client] is the caller's to close. With [channel], the request goes
/// to that OpenAI-compatible endpoint instead of DeepSeek's own Messages API.
Stream<String> streamCompanionReply({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<CompanionLine> lines,
  CompanionTurnContext? context,
  int maxTokens = 800,
  CompanionLightChannel? channel,
}) => channel == null
    ? _streamDeepSeek(
        client: client,
        apiKey: apiKey,
        system: system,
        lines: lines,
        context: context,
        maxTokens: maxTokens,
      )
    : _streamChannel(
        client: client,
        channel: channel,
        apiKey: apiKey,
        system: system,
        lines: lines,
        context: context,
        maxTokens: maxTokens,
      );

/// DeepSeek's own Messages API, the engine's format (thinking off).
Stream<String> _streamDeepSeek({
  required http.Client client,
  required String apiKey,
  required String system,
  required List<CompanionLine> lines,
  CompanionTurnContext? context,
  required int maxTokens,
}) async* {
  final request = http.Request('POST', Uri.parse(companionLightEndpoint))
    ..headers.addAll({
      'content-type': 'application/json',
      'accept': 'text/event-stream',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    })
    ..body = jsonEncode({
      'model': companionLightModel,
      'stream': true,
      'max_tokens': maxTokens,
      'thinking': {'type': 'disabled'},
      'system': system,
      'messages': companionRequestMessages([
        for (final line in lines) (role: line.role, text: line.text),
      ], context: context),
    });
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(const Duration(seconds: 30));
  } on Object catch (error) {
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  }
  if (response.statusCode != 200) {
    // The status already says what went wrong; the body is only a note, read
    // for a moment and a few hundred bytes at most.
    final failure = switch (response.statusCode) {
      401 || 403 => CompanionLightFailure.badKey,
      429 => CompanionLightFailure.busy,
      _ => CompanionLightFailure.server,
    };
    throw CompanionLightError(failure, '${response.statusCode} ${await _note(response.stream)}');
  }
  final events = response.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      // A reply that stops arriving is a failed one, not a slow one.
      .timeout(const Duration(seconds: 45));
  try {
    await for (final line in events) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final Object? event;
      try {
        event = jsonDecode(data);
      } on FormatException {
        continue;
      }
      if (event is! Map) continue;
      // An error event, or a bare {"error": …} (the API's own timeout answer has no type).
      if (event['type'] == 'error' || (event['type'] == null && event['error'] != null)) {
        final error = event['error'];
        final kind = error is Map ? error['type'] : null;
        throw CompanionLightError(
          kind == 'overloaded_error' || kind == 'rate_limit_error'
              ? CompanionLightFailure.busy
              : CompanionLightFailure.server,
          error is Map ? '${error['message']}' : '$error',
        );
      }
      switch (event['type']) {
        case 'content_block_delta':
          final delta = event['delta'];
          if (delta is Map && delta['type'] == 'text_delta' && delta['text'] is String) {
            yield delta['text'] as String;
          }
        case 'message_stop':
          return;
      }
    }
  } on CompanionLightError {
    rethrow;
  } on Object catch (error) {
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  }
  // The connection ended before message_stop: the reply is incomplete, not done.
  throw const CompanionLightError(CompanionLightFailure.network, 'ended before message_stop');
}

/// An OpenAI-compatible Chat Completions stream (`data: {"choices": …}`).
/// A non-empty [apiKey] is the Authorization; a keyless channel's own
/// Authorization header is kept, as the tavern keeps it.
Stream<String> _streamChannel({
  required http.Client client,
  required CompanionLightChannel channel,
  required String apiKey,
  required String system,
  required List<CompanionLine> lines,
  CompanionTurnContext? context,
  required int maxTokens,
}) async* {
  final hasKey = apiKey.isNotEmpty;
  final request = http.Request('POST', companionChatCompletionsUrl(channel.baseUrl))
    ..headers.addAll({
      'content-type': 'application/json',
      'accept': 'text/event-stream',
      for (final MapEntry(:key, :value) in channel.headers.entries)
        if (!hasKey || key.toLowerCase() != 'authorization') key: value,
      if (hasKey) 'Authorization': 'Bearer $apiKey',
    })
    ..body = jsonEncode({
      'model': channel.model,
      'stream': true,
      'max_tokens': maxTokens,
      'messages': _openAiMessages(system: system, lines: lines, context: context),
    });
  final http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(const Duration(seconds: 30));
  } on Object catch (error) {
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  }
  if (response.statusCode != 200) {
    final failure = switch (response.statusCode) {
      401 || 403 => CompanionLightFailure.badKey,
      429 => CompanionLightFailure.busy,
      _ => CompanionLightFailure.server,
    };
    throw CompanionLightError(failure, '${response.statusCode} ${await _note(response.stream)}');
  }
  final events = response.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .timeout(const Duration(seconds: 45));
  try {
    await for (final line in events) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final Object? event;
      try {
        event = jsonDecode(data);
      } on FormatException {
        continue;
      }
      if (event is! Map) continue;
      // Some services report a failure as a data event rather than a status.
      if (event['error'] != null) {
        final error = event['error'];
        final kind = error is Map ? error['type'] : null;
        throw CompanionLightError(
          kind == 'overloaded_error' || kind == 'rate_limit_error' || kind == 'server_error'
              ? CompanionLightFailure.busy
              : CompanionLightFailure.server,
          error is Map ? '${error['message']}' : '$error',
        );
      }
      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map) continue;
      final delta = choice['delta'];
      if (delta is! Map) continue;
      final content = delta['content'];
      if (content is String) {
        if (content.isNotEmpty) yield content;
      } else if (content is List) {
        // A compatible service may send content parts instead of a string.
        for (final part in content) {
          if (part is Map && part['text'] is String && (part['type'] == null || part['type'] == 'text')) {
            final text = part['text'] as String;
            if (text.isNotEmpty) yield text;
          }
        }
      }
    }
  } on CompanionLightError {
    rethrow;
  } on Object catch (error) {
    throw CompanionLightError(CompanionLightFailure.network, '$error');
  }
}

/// The system line, then [lines] in Chat Completions' shape. A text block list
/// (the newest line's context) is flattened for services that only take a
/// string.
List<Map<String, Object?>> _openAiMessages({
  required String system,
  required List<CompanionLine> lines,
  CompanionTurnContext? context,
}) => [
  {'role': 'system', 'content': system},
  for (final message in companionRequestMessages([
    for (final line in lines) (role: line.role, text: line.text),
  ], context: context))
    {'role': message['role'], 'content': _plainText(message['content'])},
];

String _plainText(Object? content) => switch (content) {
  final String text => text,
  final List<Object?> blocks => [
    for (final block in blocks)
      if (block is Map && block['text'] is String) block['text'] as String,
  ].where((text) => text.isNotEmpty).join('\n\n'),
  _ => '',
};

/// Up to [limit] bytes of an error body, within [wait]; never more, never longer.
Future<String> _note(Stream<List<int>> body, {int limit = 512, Duration wait = const Duration(seconds: 2)}) async {
  final bytes = <int>[];
  final done = Completer<void>();
  late final StreamSubscription<List<int>> sub;
  sub = body.listen(
    (chunk) {
      bytes.addAll(chunk.take(limit - bytes.length));
      if (bytes.length >= limit && !done.isCompleted) done.complete();
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: true,
  );
  await done.future.timeout(wait, onTimeout: () {});
  unawaited(sub.cancel().catchError((Object _) {}));
  return utf8.decode(bytes, allowMalformed: true);
}

/// The light conversation, kept on this phone.
///
/// One page holds the current one. Reads, saves and clears of the same file
/// run one after another in the order they were asked for, across instances:
/// a page that has just closed finishes its last save before the next page
/// reads, and a clear cannot delete a save asked for after it.
class CompanionLightHistory {
  CompanionLightHistory(this.file);

  /// Next to the pack (`<root>/light-chat.json`): removing the pack keeps it.
  factory CompanionLightHistory.at(Directory root) => CompanionLightHistory(File('${root.path}/light-chat.json'));

  final File file;
  final List<CompanionLine> _lines = [];
  Future<void>? _loading;

  /// Bumped by [clear]: a read that started before it must not bring the old lines back.
  int _epoch = 0;

  /// The tail of each file's queue of reads and writes.
  static final _queues = <String, Future<void>>{};

  Future<void> _queued(Future<void> Function() op) {
    final key = file.absolute.path;
    final next = (_queues[key] ?? Future<void>.value()).then((_) => op()).catchError((Object _) {});
    _queues[key] = next;
    return next;
  }

  /// Lines kept on disk; older ones fall off.
  static const keep = 80;

  /// Lines sent with each message (about a dozen turns).
  static const window = 24;

  List<CompanionLine> get lines => List.unmodifiable(_lines);

  /// Reads the file once; every caller waits for that same read, so the old
  /// conversation always comes before anything added after it.
  Future<void> load() {
    final epoch = _epoch;
    return _loading ??= _queued(() async {
      try {
        final json = jsonDecode(await file.readAsString());
        if (epoch == _epoch && json is Map && json['lines'] is List) {
          final version = json['v'] == 1 ? 1 : 2;
          _lines.insertAll(0, [
            for (final line in json['lines'] as List) ?CompanionLine.fromJson(line, version: version),
          ]);
          if (_lines.length > keep) _lines.removeRange(0, _lines.length - keep);
        }
      } on Object {
        // Missing or unreadable: she starts afresh rather than not talking.
      }
    });
  }

  /// The caller must pass only the human's text; use streamCompanionReply's
  /// context argument for events. Integrate the page change with this schema.
  void add(CompanionLine line) {
    _lines.add(line);
    if (_lines.length > keep) _lines.removeRange(0, _lines.length - keep);
  }

  /// Takes back the last line when it's the person's and went unanswered.
  CompanionLine? dropUnanswered() => _lines.isNotEmpty && !_lines.last.fromHer ? _lines.removeLast() : null;

  /// What the model gets: the last [window] lines, starting with the person,
  /// with lines from the same side joined (the API wants them alternating).
  List<CompanionLine> context() {
    var start = max(0, _lines.length - window);
    while (start < _lines.length && _lines[start].fromHer) {
      start++;
    }
    final out = <CompanionLine>[];
    for (final line in _lines.skip(start)) {
      if (out.isNotEmpty && out.last.fromHer == line.fromHer) {
        final joined = '${out.last.text}\n${line.text}';
        out[out.length - 1] = line.fromHer ? CompanionLine.her(joined) : CompanionLine.user(joined);
      } else {
        out.add(line);
      }
    }
    return out;
  }

  /// Writes the conversation as it is now (taken at the call, not when the
  /// write's turn comes).
  Future<void> save() {
    final json = jsonEncode({
      'v': 2,
      'lines': [for (final line in _lines) line.toJson()],
    });
    return _queued(() async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(json);
        await temp.rename(file.path);
      } on Object {
        // A lost write costs her a little memory, never the conversation in progress.
      }
    });
  }

  Future<void> clear() {
    _epoch++;
    _lines.clear();
    return _queued(() async {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // Nothing to forget, or it can't be: the next save overwrites it.
      }
    });
  }
}
