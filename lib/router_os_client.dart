import 'dart:async'; // For asynchronous programming and Future, Stream, Completer, etc.
import 'dart:convert'; // For encoding and decoding UTF-8 strings
import 'dart:io'; // For working with files, sockets, and other I/O

import 'package:logger/logger.dart'; // For Flutter-specific utilities like debugPrint

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

  TaggedResponse({
    required this.data,
    this.tag,
    this.isDone = false,
    this.isError = false,
    this.errorMessage,
  });
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

  /// Optional timeout for socket operations.
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

  /// Map to store pending tagged commands and their completers
  final Map<String, Completer<TaggedResponse>> _pendingTaggedCommands = {};

  /// Completer for non-tagged commands (legacy behavior)
  Completer<List<List<String>>>? _currentCompleter;

  /// Stream controller for broadcasting tagged responses
  final StreamController<TaggedResponse> _taggedResponseController =
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
      if (useSsl) {
        _secureSocket =
        await SecureSocket.connect(address, port, context: context);
        _socket = _secureSocket;
      } else {
        _socket = await Socket.connect(address, port);
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

  /// Starts listening for responses and routes them based on tags
  void _startListening() {
    var buffer = <int>[];

    _socketStream.listen((event) {
      buffer.addAll(event);
      while (true) {
        var sentence = _readSentenceFromBuffer(buffer);
        if (sentence.isEmpty) {
          break;
        }
        _handleReceivedSentence(sentence);
      }
    });
  }

  /// Handles a received sentence and routes it based on tag
  void _handleReceivedSentence(List<String> sentence) {
    String? tag = _extractTag(sentence);
    bool isDone = sentence.contains('!done');
    bool isError = sentence.contains('!trap');

    if (tag != null && _pendingTaggedCommands.containsKey(tag)) {
      // Handle tagged response
      var parsedData = _parseReply([sentence]);
      var response = TaggedResponse(
        data: parsedData,
        tag: tag,
        isDone: isDone,
        isError: isError,
        errorMessage: isError ? _extractErrorMessage(sentence) : null,
      );

      // Broadcast to stream
      _taggedResponseController.add(response);

      // Complete the specific tagged command if done or error
      if (isDone || isError) {
        var completer = _pendingTaggedCommands.remove(tag);
        completer?.complete(response);
      }
    } else {
      // Handle non-tagged response (legacy behavior)
      if (_currentCompleter != null && !_currentCompleter!.isCompleted) {
        if (_currentReceivedData == null) {
          _currentReceivedData = <List<String>>[];
        }
        _currentReceivedData!.add(sentence);

        if (isDone) {
          _currentCompleter!.complete(_currentReceivedData!);
          _currentReceivedData = null;
        }
      }
    }
  }

  /// Current received data for non-tagged commands
  List<List<String>>? _currentReceivedData;

  /// Extracts tag from a sentence
  String? _extractTag(List<String> sentence) {
    for (var word in sentence) {
      if (word.startsWith('.tag=')) {
        return word.substring(5); // Remove '.tag=' prefix
      }
    }
    return null;
  }

  /// Extracts error message from a !trap sentence
  String? _extractErrorMessage(List<String> sentence) {
    for (var word in sentence) {
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
      var sentence = ['/login', '=name=$user', '=password=$password'];
      var reply = await _communicate(sentence);
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
      var response = await talkTagged(command, params, tag);
      return response.data;
    } else {
      // Legacy behavior for non-tagged commands
      List<String> sentence = _buildSentence(command, params, null);
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

    tag ??= _generateTag();
    List<String> sentence = _buildSentence(command, params, tag);

    // Create completer for this tagged command
    var completer = Completer<TaggedResponse>();
    _pendingTaggedCommands[tag] = completer;

    // Send the command
    await _sendTaggedCommand(sentence);

    // Wait for response
    return await completer.future;
  }

  /// Sends multiple commands simultaneously with tags
  ///
  /// [commands] - List of commands with their parameters and optional tags
  /// Returns a stream of tagged responses as they arrive
  Stream<TaggedResponse> talkMultiple(List<TaggedCommand> commands) async* {
    // Send all commands
    for (var cmd in commands) {
      var tag = cmd.tag ?? _generateTag();
      var sentence = _buildSentence(cmd.command, cmd.params, tag);

      var completer = Completer<TaggedResponse>();
      _pendingTaggedCommands[tag] = completer;

      await _sendTaggedCommand(sentence);
    }

    // Yield responses as they arrive
    await for (var response in _taggedResponseController.stream) {
      if (commands.any((cmd) => (cmd.tag ?? '') == response.tag)) {
        yield response;

        // Stop if all commands are done
        if (_pendingTaggedCommands.isEmpty) {
          break;
        }
      }
    }
  }

  /// Cancels a command with the specified tag
  Future<void> cancelTagged(String tag) async {
    var sentence = ['/cancel', '=tag=$tag'];
    await _sendTaggedCommand(sentence);
  }

  /// Builds a sentence from command, parameters, and tag
  List<String> _buildSentence(dynamic command, Map<String, String>? params, String? tag) {
    List<String> sentence = [];

    if (command is String) {
      sentence.add(command);
    } else if (command is List<String>) {
      sentence.addAll(command);
    } else {
      throw ArgumentError('Invalid command type: $command');
    }

    // Add parameters
    if (params != null) {
      params.forEach((key, value) {
        sentence.add('=$key=$value');
      });
    }

    // Add tag if specified
    if (tag != null && tag.isNotEmpty) {
      sentence.add('.tag=$tag');
    }

    return sentence;
  }

  /// Generates a unique tag
  String _generateTag() {
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  /// Sends a tagged command without waiting for response
  Future<void> _sendTaggedCommand(List<String> sentence) async {
    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    for (var word in sentence) {
      _sendLength(socket, word.length);
      socket.add(utf8.encode(word));
      logger.d('>>> $word');
    }
    socket.add([0]); // End of sentence indicator
  }

  /// Streams data from the RouterOS device, useful for long-running commands.
  ///
  /// [command] - The command to send
  /// [params] - Optional parameters
  /// [tag] - Optional tag for this stream
  Stream<Map<String, String>> streamData(dynamic command,
      [Map<String, String>? params, String? tag]) async* {

    tag ??= _generateTag();
    List<String> sentence = _buildSentence(command, params, tag);

    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    // Send the command
    await _sendTaggedCommand(sentence);

    // Listen for tagged responses
    await for (var response in _taggedResponseController.stream) {
      if (response.tag == tag) {
        for (var data in response.data) {
          yield data;
        }

        if (response.isDone || response.isError) {
          break;
        }
      }
    }
  }

  /// Sends a command to the RouterOS device and receives the reply.
  Future<List<List<String>>> _communicate(List<String> sentenceToSend) async {
    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    for (var word in sentenceToSend) {
      _sendLength(socket, word.length);
      socket.add(utf8.encode(word));
      logger.d('>>> $word');
    }
    socket.add([0]); // End of sentence indicator

    return await _receiveData();
  }

  /// Receives data from the socket until a complete reply is received.
  Future<List<List<String>>> _receiveData() async {
    var completer = Completer<List<List<String>>>();
    _currentCompleter = completer;
    return completer.future;
  }

  /// Reads a sentence from the buffer and removes it from the buffer.
  List<String> _readSentenceFromBuffer(List<int> buffer) {
    var sentence = <String>[];
    while (buffer.isNotEmpty) {
      var length = _readLengthFromBuffer(buffer);
      if (length == 0) {
        break;
      }
      if (buffer.length < length) {
        return [];
      }
      var word = utf8.decode(buffer.sublist(0, length));
      sentence.add(word);
      buffer.removeRange(0, length);
    }
    return sentence;
  }

  /// Reads the length of the next word in the buffer.
  int _readLengthFromBuffer(List<int> buffer) {
    var firstByte = buffer.removeAt(0);
    int length;

    // Handle length encoding formats.
    if (firstByte < 0x80) {
      length = firstByte;
    } else if (firstByte < 0xC0) {
      var secondByte = buffer.removeAt(0);
      length = ((firstByte << 8) | secondByte) - 0x8000;
    } else if (firstByte < 0xE0) {
      var bytes = buffer.sublist(0, 2);
      buffer.removeRange(0, 2);
      length = ((firstByte << 16) | (bytes[0] << 8) | bytes[1]) - 0xC00000;
    } else if (firstByte < 0xF0) {
      var bytes = buffer.sublist(0, 3);
      buffer.removeRange(0, 3);
      length =
          ((firstByte << 24) | (bytes[0] << 16) | (bytes[1] << 8) | bytes[2]) -
              0xE0000000;
    } else if (firstByte == 0xF0) {
      var bytes = buffer.sublist(0, 4);
      buffer.removeRange(0, 4);
      length = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    } else {
      throw WordTooLong('Received word is too long.');
    }
    return length;
  }

  /// Sends the length of a word to the RouterOS device.
  void _sendLength(Socket socket, int length) {
    if (length < 0x80) {
      socket.add([length]);
    } else if (length < 0x4000) {
      length += 0x8000;
      socket.add(length.toBytes(2));
    } else if (length < 0x200000) {
      length += 0xC00000;
      socket.add(length.toBytes(3));
    } else if (length < 0x10000000) {
      length += 0xE0000000;
      socket.add(length.toBytes(4));
    } else if (length < 0x100000000) {
      socket.add([0xF0]);
      socket.add(length.toBytes(4));
    } else {
      throw WordTooLong('Word is too long. Max length is 4294967295.');
    }
  }

  /// Parses a sentence from the RouterOS device into a map of key-value pairs.
  Map<String, String> _parseSentence(List<String> sentence) {
    var parsedData = <String, String>{};
    for (var word in sentence) {
      if (word.startsWith('!')) {
        continue;
      }
      if (word.startsWith('=')) {
        var parts = word.substring(1).split('=');
        if (parts.length == 2) {
          parsedData[parts[0]] = parts[1];
        }
      }
      // Note: API attribute words starting with '.' (like .tag) are handled separately
    }
    return parsedData;
  }

  /// Checks the reply from the RouterOS device after a login attempt.
  void _checkLoginReply(List<List<String>> reply) {
    if (reply.isNotEmpty && reply[0].length == 1 && reply[0][0] == '!done') {
      logger.i('Login successful!');
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][0] == '!trap') {
      throw LoginError('Login error: ${reply[0][1]}');
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][1].startsWith('=ret=')) {
      logger.w('Using legacy login process.');
    } else {
      throw LoginError('Unexpected login reply: $reply');
    }
  }

  /// Sends a command and returns the parsed response.
  Future<List<Map<String, String>>> _send(List<String> sentence) async {
    var reply = await _communicate(sentence);
    if (reply.isNotEmpty && reply[0].isNotEmpty && reply[0][0] == '!trap') {
      logger.e('Command: $sentence\nReturned an error: $reply');
      throw RouterOSTrapError("Command: $sentence\nReturned an error: $reply");
    }
    return _parseReply(reply);
  }

  /// Parses a reply from the RouterOS device into a list of maps.
  List<Map<String, String>> _parseReply(List<List<String>> reply) {
    var parsedReplies = <Map<String, String>>[];
    for (var sentence in reply) {
      var parsedReply = <String, String>{};
      for (var word in sentence) {
        if (word.startsWith('!')) {
          continue;
        }
        if (word.startsWith('=')) {
          var parts = word.substring(1).split('=');
          if (parts.length == 2) {
            parsedReply[parts[0]] = parts[1];
          }
        }
      }
      if (parsedReply.isNotEmpty) {
        parsedReplies.add(parsedReply);
      }
    }
    return parsedReplies;
  }

  /// Checks if the socket connection is still alive by sending a simple command.
  Object isAlive() {
    if (_socket == null) {
      logger.w('Socket is not open.');
      return false;
    }

    try {
      final result =
      talk(['/system/identity/print']).timeout(const Duration(seconds: 2));
      logger.d('Result: $result');
      return result;
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
    _taggedResponseController.close();
    _pendingTaggedCommands.clear();
    logger.i('RouterOSClient socket connection closed.');
  }
}

/// Represents a tagged command for batch operations
class TaggedCommand {
  /// The command to execute
  final dynamic command;

  /// Parameters for the command
  final Map<String, String>? params;

  /// Optional tag (will be auto-generated if null)
  final String? tag;

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

/// Custom exception for handling long words.
///
/// This exception is thrown when the word received from the RouterOS device is too long.
class WordTooLong implements Exception {
  /// The error message associated with the long word error.
  final String message;

  /// Creates a [WordTooLong] exception with the given error [message].
  WordTooLong(this.message);

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

/// Extension method to convert an integer to a list of bytes.
extension on int {
  List<int> toBytes(int byteCount) {
    var result = <int>[];
    for (var i = 0; i < byteCount; i++) {
      result.add((this >> (8 * (byteCount - i - 1))) & 0xFF);
    }
    return result;
  }
}
