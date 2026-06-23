import 'dart:async'; // For asynchronous programming and Future, Stream, Completer, etc.
import 'dart:collection'; // For Queue (FIFO routing of untagged replies)
import 'dart:convert'; // For encoding and decoding UTF-8 strings
import 'dart:io'; // For working with files, sockets, and other I/O

import 'package:logger/logger.dart'; // For structured logging

import 'src/protocol.dart';

// Re-export the protocol-level exception so it stays part of the public API.
export 'src/protocol.dart' show WordTooLong;

/// Response object that includes tag information
class TaggedResponse {
  /// The parsed response data
  final List<Map<String, String>> data;

  /// The tag associated with this response (null if no tag was used)
  final String? tag;

  /// Whether this response indicates completion (!done)
  final bool isDone;

  /// Whether this response indicates an error (!trap)
  final bool isError;

  /// Error message if this is an error response
  final String? errorMessage;

  /// Creates a [TaggedResponse].
  TaggedResponse({
    required this.data,
    this.tag,
    this.isDone = false,
    this.isError = false,
    this.errorMessage,
  });
}

/// Internal bookkeeping for an in-flight untagged command. RouterOS processes
/// untagged commands sequentially, so replies are matched to commands in FIFO
/// order, each command's reply ending at its `!done` sentence.
class _UntaggedPending {
  final Completer<List<List<String>>> completer =
      Completer<List<List<String>>>();
  final List<List<String>> received = [];
}

/// The `RouterOSClient` class handles the connection to a RouterOS device via a socket.
class RouterOSClient {
  /// RouterOS device IP address or hostname.
  final String address;

  /// Username for authentication.
  String user;

  /// Password for authentication.
  String password;

  /// Whether to use SSL for the connection.
  bool useSsl;

  /// The port to connect to (8728 for non-SSL, 8729 for SSL).
  int port;

  /// If `true`, additional debug information will be printed.
  bool verbose;

  /// SSL context for secure connections (if `useSsl` is `true`).
  SecurityContext? context;

  /// Optional timeout applied to connecting and to awaiting command replies.
  Duration? timeout;

  /// Logger instance for logging events and debug information.
  var logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  // Internal socket references
  Socket? _socket;
  SecureSocket? _secureSocket;

  /// Stream for handling incoming data from the socket.
  late Stream<List<int>> _socketStream;

  /// Generates unique, collision-free command tags.
  final TagGenerator _tagGenerator = TagGenerator();

  /// Tags currently being tracked (so incoming sentences route correctly even
  /// for fire-and-forget consumers like [streamData]).
  final Set<String> _activeTags = {};

  /// Pending tagged commands awaiting their `!done`.
  final Map<String, Completer<TaggedResponse>> _pendingTaggedCommands = {};

  /// Accumulated data sentences per tag, assembled until `!done`.
  final Map<String, List<Map<String, String>>> _taggedAccumulator = {};

  /// Error message per tag (key present means a `!trap` was seen).
  final Map<String, String?> _taggedError = {};

  /// FIFO queue of in-flight untagged commands.
  final Queue<_UntaggedPending> _untaggedQueue = Queue<_UntaggedPending>();

  /// Stream controller for broadcasting tagged responses.
  /// Recreated on (re)connect because a closed broadcast controller cannot be
  /// reused.
  StreamController<TaggedResponse> _taggedResponseController =
      StreamController<TaggedResponse>.broadcast();

  /// Constructor for the `RouterOSClient` class, initializing the properties.
  RouterOSClient({
    required this.address,
    this.user = 'admin',
    this.password = '',
    this.useSsl = false,
    int? port,
    this.verbose = false,
    this.context,
    this.timeout,
  }) : port = port ?? (useSsl ? 8729 : 8728);

  /// Opens a socket connection to the RouterOS device.
  Future<void> _openSocket() async {
    try {
      if (!verbose) {
        Logger.level = Level.off;
      }

      // A closed broadcast controller cannot be reused; recreate it so the
      // client can reconnect after a previous close().
      if (_taggedResponseController.isClosed) {
        _taggedResponseController = StreamController<TaggedResponse>.broadcast();
      }

      if (useSsl) {
        _secureSocket = await SecureSocket.connect(
          address,
          port,
          context: context,
          timeout: timeout,
        );
        _socket = _secureSocket;
      } else {
        _socket = await Socket.connect(address, port, timeout: timeout);
      }
      _socket?.setOption(SocketOption.tcpNoDelay, true);
      logger.i("RouterOSClient socket connection opened.");
      _socketStream = _socket!.asBroadcastStream();
      _startListening();
    } on SocketException catch (e) {
      throw CreateSocketError(
        'Failed to connect to socket. Host: $address, port: $port. Error: ${e.message}',
      );
    }
  }

  /// Starts listening for responses and routes them based on tags.
  void _startListening() {
    final sentenceBuffer = SentenceBuffer();

    _socketStream.listen((event) {
      sentenceBuffer.addBytes(event);
      while (true) {
        final sentence = sentenceBuffer.nextSentence();
        if (sentence == null) {
          break; // Wait for more bytes.
        }
        _handleReceivedSentence(sentence);
      }
    });
  }

  /// Handles a received sentence and routes it based on tag.
  void _handleReceivedSentence(List<String> sentence) {
    final tag = _extractTag(sentence);
    final isDone = sentence.contains('!done');
    final isError = sentence.contains('!trap');

    if (tag != null && _activeTags.contains(tag)) {
      _handleTaggedSentence(sentence, tag, isDone: isDone, isError: isError);
    } else {
      _handleUntaggedSentence(sentence, isDone: isDone);
    }
  }

  /// Routes a sentence belonging to a tracked tag.
  void _handleTaggedSentence(List<String> sentence, String tag,
      {required bool isDone, required bool isError}) {
    final parsed = parseSentence(sentence);
    final errorMessage = isError ? _extractErrorMessage(sentence) : null;

    // Broadcast the individual sentence for stream consumers.
    _taggedResponseController.add(TaggedResponse(
      data: parsed.isEmpty ? const [] : [parsed],
      tag: tag,
      isDone: isDone,
      isError: isError,
      errorMessage: errorMessage,
    ));

    if (parsed.isNotEmpty) {
      (_taggedAccumulator[tag] ??= []).add(parsed);
    }
    if (isError) {
      _taggedError[tag] = errorMessage;
    }

    // RouterOS terminates every command reply with !done (a !trap is followed
    // by its own !done), so only !done completes the command.
    if (isDone) {
      _activeTags.remove(tag);
      final data = _taggedAccumulator.remove(tag) ?? [];
      final hadError = _taggedError.containsKey(tag);
      final message = _taggedError.remove(tag);
      final completer = _pendingTaggedCommands.remove(tag);
      completer?.complete(TaggedResponse(
        data: data,
        tag: tag,
        isDone: true,
        isError: hadError,
        errorMessage: message,
      ));
    }
  }

  /// Routes a sentence belonging to the current untagged command (FIFO).
  void _handleUntaggedSentence(List<String> sentence, {required bool isDone}) {
    if (_untaggedQueue.isEmpty) {
      logger.w('Received an untagged sentence with no pending command: $sentence');
      return;
    }

    final pending = _untaggedQueue.first;
    pending.received.add(sentence);

    if (isDone) {
      _untaggedQueue.removeFirst();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(pending.received);
      }
    }
  }

  /// Begins tracking a tag, optionally registering a completer to await.
  void _beginTagged(String tag, {Completer<TaggedResponse>? completer}) {
    _activeTags.add(tag);
    _taggedAccumulator[tag] = [];
    if (completer != null) {
      _pendingTaggedCommands[tag] = completer;
    }
  }

  /// Extracts the tag from a sentence.
  String? _extractTag(List<String> sentence) {
    for (final word in sentence) {
      if (word.startsWith('.tag=')) {
        return word.substring(5); // Remove '.tag=' prefix
      }
    }
    return null;
  }

  /// Extracts the error message from a !trap sentence.
  String? _extractErrorMessage(List<String> sentence) {
    for (final word in sentence) {
      if (word.startsWith('=message=')) {
        return word.substring(9); // Remove '=message=' prefix
      }
    }
    return null;
  }

  /// Logs in to the RouterOS device using the provided credentials.
  ///
  /// Returns `true` if the login was successful.
  Future<bool> login() async {
    try {
      await _openSocket();
      final sentence = ['/login', '=name=$user', '=password=$password'];
      final reply = await _sendUntagged(sentence);
      _checkLoginReply(reply);
      return true;
    } catch (e) {
      logger.e('Login failed: $e');
      return false;
    }
  }

  /// Sends a command to the RouterOS device and returns the parsed response.
  ///
  /// [command] - The command to send (String or List<String>)
  /// [params] - Optional parameters as key-value pairs
  /// [tag] - Optional tag to identify this command and its responses
  Future<List<Map<String, String>>> talk(dynamic command,
      [Map<String, String>? params, String? tag]) async {
    if (tag != null) {
      final response = await talkTagged(command, params, tag);
      if (response.isError) {
        throw RouterOSTrapError(
            'Command: $command\nReturned an error: ${response.errorMessage}');
      }
      return response.data;
    } else {
      // Legacy behavior for non-tagged commands.
      final sentence = _buildSentence(command, params, null);
      return await _send(sentence);
    }
  }

  /// Sends a tagged command to the RouterOS device and returns the tagged response.
  ///
  /// [command] - The command to send (String or List<String>)
  /// [params] - Optional parameters as key-value pairs
  /// [tag] - Tag to identify this command and its responses
  Future<TaggedResponse> talkTagged(dynamic command,
      [Map<String, String>? params, String? tag]) async {
    tag ??= _tagGenerator.next();
    final sentence = _buildSentence(command, params, tag);

    final completer = Completer<TaggedResponse>();
    _beginTagged(tag, completer: completer);

    await _sendTaggedCommand(sentence);

    final future = completer.future;
    return timeout != null ? future.timeout(timeout!) : future;
  }

  /// Sends multiple commands simultaneously with tags.
  ///
  /// [commands] - List of commands with their parameters and optional tags
  /// Returns a stream of tagged responses as they arrive.
  Stream<TaggedResponse> talkMultiple(List<TaggedCommand> commands) async* {
    final tags = <String>{};

    // Send all commands.
    for (final cmd in commands) {
      final tag = cmd.tag ?? _tagGenerator.next();
      tags.add(tag);
      final sentence = _buildSentence(cmd.command, cmd.params, tag);
      _beginTagged(tag);
      await _sendTaggedCommand(sentence);
    }

    // Yield responses as they arrive.
    await for (final response in _taggedResponseController.stream) {
      if (response.tag != null && tags.contains(response.tag)) {
        yield response;

        if (response.isDone) {
          tags.remove(response.tag);
        }
        if (tags.isEmpty) {
          break;
        }
      }
    }
  }

  /// Cancels a command with the specified tag.
  Future<void> cancelTagged(String tag) async {
    final sentence = ['/cancel', '=tag=$tag'];
    await _sendTaggedCommand(sentence);
  }

  /// Builds a sentence from command, parameters, and tag.
  List<String> _buildSentence(
      dynamic command, Map<String, String>? params, String? tag) {
    final sentence = <String>[];

    if (command is String) {
      sentence.add(command);
    } else if (command is List<String>) {
      sentence.addAll(command);
    } else {
      throw ArgumentError('Invalid command type: $command');
    }

    if (params != null) {
      params.forEach((key, value) {
        sentence.add('=$key=$value');
      });
    }

    if (tag != null && tag.isNotEmpty) {
      sentence.add('.tag=$tag');
    }

    return sentence;
  }

  /// Sends a tagged command without waiting for its reply.
  Future<void> _sendTaggedCommand(List<String> sentence) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }
    _writeSentence(socket, sentence);
  }

  /// Streams data from the RouterOS device, useful for long-running commands.
  ///
  /// [command] - The command to send
  /// [params] - Optional parameters
  /// [tag] - Optional tag for this stream
  Stream<Map<String, String>> streamData(dynamic command,
      [Map<String, String>? params, String? tag]) async* {
    tag ??= _tagGenerator.next();
    final sentence = _buildSentence(command, params, tag);

    final socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    _beginTagged(tag);
    _writeSentence(socket, sentence);

    await for (final response in _taggedResponseController.stream) {
      if (response.tag == tag) {
        for (final data in response.data) {
          yield data;
        }
        if (response.isDone || response.isError) {
          break;
        }
      }
    }
  }

  /// Sends an untagged command and returns the raw reply sentences.
  ///
  /// The pending entry is queued before the bytes are written, with no `await`
  /// in between, so that concurrent untagged commands keep their FIFO order.
  Future<List<List<String>>> _sendUntagged(List<String> sentence) {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    final pending = _UntaggedPending();
    _untaggedQueue.add(pending);
    _writeSentence(socket, sentence);

    final future = pending.completer.future;
    return timeout != null ? future.timeout(timeout!) : future;
  }

  /// Writes a full sentence (length-prefixed words + terminator) to the socket.
  void _writeSentence(Socket socket, List<String> words) {
    for (final word in words) {
      final encoded = utf8.encode(word);
      socket.add(encodeLength(encoded.length));
      socket.add(encoded);
      logger.d('>>> $word');
    }
    socket.add([0]); // End of sentence indicator
  }

  /// Checks the reply from the RouterOS device after a login attempt.
  void _checkLoginReply(List<List<String>> reply) {
    if (reply.isNotEmpty && reply[0].isNotEmpty && reply[0][0] == '!trap') {
      final message = reply[0].length > 1 ? reply[0][1] : 'unknown error';
      throw LoginError('Login error: $message');
    } else if (reply.isNotEmpty &&
        reply[0].length == 1 &&
        reply[0][0] == '!done') {
      logger.i('Login successful!');
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][1].startsWith('=ret=')) {
      logger.w('Using legacy login process.');
    } else {
      throw LoginError('Unexpected login reply: $reply');
    }
  }

  /// Sends an untagged command and returns the parsed response.
  Future<List<Map<String, String>>> _send(List<String> sentence) async {
    final reply = await _sendUntagged(sentence);
    final hasTrap = reply.any((s) => s.isNotEmpty && s[0] == '!trap');
    if (hasTrap) {
      logger.e('Command: $sentence\nReturned an error: $reply');
      throw RouterOSTrapError("Command: $sentence\nReturned an error: $reply");
    }
    return _parseReply(reply);
  }

  /// Parses a reply from the RouterOS device into a list of maps.
  List<Map<String, String>> _parseReply(List<List<String>> reply) {
    final parsedReplies = <Map<String, String>>[];
    for (final sentence in reply) {
      final parsed = parseSentence(sentence);
      if (parsed.isNotEmpty) {
        parsedReplies.add(parsed);
      }
    }
    return parsedReplies;
  }

  /// Checks if the socket connection is still alive by sending a simple command.
  ///
  /// Returns `true` if the device responds within two seconds.
  Future<bool> isAlive() async {
    if (_socket == null) {
      logger.w('Socket is not open.');
      return false;
    }

    try {
      final result = await talk(['/system/identity/print'])
          .timeout(const Duration(seconds: 2));
      logger.d('Result: $result');
      return true;
    } on TimeoutException {
      logger.w('Socket read timeout.');
      close();
      return false;
    } catch (e) {
      logger.e('Socket is closed or router does not respond: $e');
      close();
      return false;
    }
  }

  /// Closes the socket connection to the RouterOS device.
  void close() {
    _socket?.destroy();
    _socket = null;
    _secureSocket = null;

    // Fail any in-flight commands rather than leaving their futures hanging.
    for (final pending in _untaggedQueue) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(StateError('Connection closed.'));
      }
    }
    _untaggedQueue.clear();
    for (final completer in _pendingTaggedCommands.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Connection closed.'));
      }
    }
    _pendingTaggedCommands.clear();
    _activeTags.clear();
    _taggedAccumulator.clear();
    _taggedError.clear();

    if (!_taggedResponseController.isClosed) {
      _taggedResponseController.close();
    }
    logger.i('RouterOSClient socket connection closed.');
  }
}

/// Represents a tagged command for batch operations.
class TaggedCommand {
  /// The command to execute.
  final dynamic command;

  /// Parameters for the command.
  final Map<String, String>? params;

  /// Optional tag (will be auto-generated if null).
  final String? tag;

  /// Creates a [TaggedCommand].
  TaggedCommand({
    required this.command,
    this.params,
    this.tag,
  });
}

/// Custom exception for login errors.
class LoginError implements Exception {
  /// The error message associated with the login error.
  final String message;

  /// Creates a [LoginError] with the given error [message].
  LoginError(this.message);

  @override
  String toString() => message;
}

/// Custom exception for socket creation errors.
///
/// This exception is thrown when a socket connection cannot be established.
class CreateSocketError implements Exception {
  /// The error message associated with the socket creation error.
  final String message;

  /// Creates a [CreateSocketError] with the given error [message].
  CreateSocketError(this.message);

  @override
  String toString() => message;
}

/// Custom exception for RouterOS-specific errors (trap errors).
///
/// This exception is thrown when a command sent to the RouterOS device results in an error.
class RouterOSTrapError implements Exception {
  /// The error message associated with the RouterOS trap error.
  final String message;

  /// Creates a [RouterOSTrapError] with the given error [message].
  RouterOSTrapError(this.message);

  @override
  String toString() => message;
}
