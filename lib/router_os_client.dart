import 'dart:async'; // For asynchronous programming and Future, Stream, Completer, etc.
import 'dart:convert'; // For encoding and decoding UTF-8 strings
import 'dart:io'; // For working with files, sockets, and other I/O

import 'package:logger/logger.dart'; // For Flutter-specific utilities like debugPrint

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
      if (useSsl) {
        _secureSocket = await SecureSocket.connect(address, port, context: context);
        _socket = _secureSocket;
      } else {
        _socket = await Socket.connect(address, port);
      }
      _socket?.setOption(SocketOption.tcpNoDelay, true);
      logger.i("RouterOSClient socket connection opened.");
      _socketStream = _socket!.asBroadcastStream();
    } on SocketException catch (e) {
      throw CreateSocketError(
        'Failed to connect to socket. Host: $address, port: $port. Error: ${e.message}',
      );
    }
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
    var buffer = <int>[];
    var receivedData = <List<String>>[];
    var completer = Completer<List<List<String>>>();

    _socketStream.listen((event) {
      buffer.addAll(event);
      while (true) {
        var sentence = _readSentenceFromBuffer(buffer);
        if (sentence.isEmpty) {
          break;
        }
        receivedData.add(sentence);
        if (sentence.contains('!done')) {
          if (!completer.isCompleted) {
            completer.complete(receivedData);
          }
          break;
        }
      }
    });

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
      length = ((firstByte << 24) | (bytes[0] << 16) | (bytes[1] << 8) | bytes[2]) - 0xE0000000;
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

  /// Checks the reply from the RouterOS device after a login attempt.
  void _checkLoginReply(List<List<String>> reply) {
    if (reply.isNotEmpty && reply[0].length == 1 && reply[0][0] == '!done') {
      logger.i('Login successful!');
    } else if (reply.isNotEmpty && reply[0].length == 2 && reply[0][0] == '!trap') {
      throw LoginError('Login error: ${reply[0][1]}');
    } else if (reply.isNotEmpty && reply[0].length == 2 && reply[0][1].startsWith('=ret=')) {
      logger.w('Using legacy login process.');
    } else {
      throw LoginError('Unexpected login reply: $reply');
    }
  }

  /// Sends a command to the RouterOS device and returns the parsed response.
  Future<List<Map<String, String>>> talk(dynamic message) async {
    if (message is String && message.contains(" ")) {
      message = _parseCommand(message);
    }

    if (message is String) {
      return _send([message]);
    } else if (message is List<String>) {
      return _send(message);
    } else if (message is List<dynamic>) {
      var reply = <List<Map<String, String>>>[];
      for (var sentence in message) {
        reply.add(await _send(sentence));
      }
      return reply.expand((element) => element).toList();
    } else {
      throw ArgumentError('Invalid message type for talk: $message');
    }
  }

  /// Streams data from the RouterOS device, useful for long-running commands.
  Stream<Map<String, String>> streamData(dynamic command) async* {
    var sentenceToSend = _parseCommand(command);
    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    for (var word in sentenceToSend) {
      _sendLength(socket, word.length);
      socket.add(utf8.encode(word));
      logger.d('>>> $word');
    }
    socket.add([0]);

    await for (var event in _socketStream) {
      var buffer = <int>[];
      buffer.addAll(event);
      while (buffer.isNotEmpty) {
        var sentence = _readSentenceFromBuffer(buffer);
        if (sentence.isNotEmpty) {
          var parsedData = _parseSentence(sentence);
          yield parsedData;
        }
        if (sentence.contains('!done') || sentence.contains('!trap')) {
          return;
        }
      }
    }
  }

  /// Parses a command string into the format required by RouterOS.
  List<String> _parseCommand(String command) {
    var parts = command.split(' ');
    return parts.map((part) => part.contains('=') ? part : part).toList();
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
    }
    return parsedData;
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
      final result = talk(['/system/identity/print']).timeout(const Duration(seconds: 2));
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
    logger.i('RouterOSClient socket connection closed.');
  }
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
