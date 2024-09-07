import 'dart:async'; // For asynchronous programming and Future, Stream, Completer, etc.
import 'dart:convert'; // For encoding and decoding UTF-8 strings
import 'dart:io'; // For working with files, sockets, and other I/O

import 'package:logger/logger.dart'; // For Flutter-specific utilities like debugPrint

// The RouterOSClient class handles the connection to a RouterOS device via a socket.
class RouterOSClient {
  // These are the properties required to configure the connection.
  final String address; // RouterOS device IP address or hostname
  String user; // Username for authentication
  String password; // Password for authentication
  bool useSsl; // Whether to use SSL for the connection
  int port; // The port to connect to (8728 for non-SSL, 8729 for SSL)
  bool verbose; // If true, additional debug information will be printed
  SecurityContext?
  context; // SSL context for secure connections (if useSsl is true)
  Duration? timeout; // Optional timeout for socket operations

  var logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2, // Number of method calls to be displayed
      errorMethodCount: 8, // Number of method calls if stacktrace is provided
      lineLength: 120, // Width of the output
      colors: true, // Colorful log messages
      printEmojis: true, // Print an emoji for each log message
      // Should each log print contain a timestamp
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  // Internal socket references
  Socket? _socket; // Standard TCP socket
  SecureSocket? _secureSocket; // SSL-enabled TCP socket
  late Stream<List<int>>
  _socketStream; // Stream for handling incoming data from the socket

  // Constructor for the RouterOSClient class, initializing the properties.
  RouterOSClient({
    required this.address,
    this.user = 'admin', // Default username is 'admin'
    this.password = '', // Default password is empty
    this.useSsl = false, // Default is to not use SSL
    int? port, // Port is optional; default is based on useSsl
    this.verbose = false, // Default is not verbose
    this.context, // SSL context is optional
    this.timeout, // Timeout is optional
  }) : port = port ??
      (useSsl ? 8729 : 8728); // Set port based on whether SSL is used

  // Opens a socket connection to the RouterOS device.
  Future<void> _openSocket() async {
    try {
      if (useSsl) {
        // Connect using SSL if useSsl is true
        _secureSocket =
        await SecureSocket.connect(address, port, context: context);
        _socket = _secureSocket;
      } else {
        // Connect using a standard TCP socket
        _socket = await Socket.connect(address, port);
      }
      _socket?.setOption(SocketOption.tcpNoDelay,
          true); // Disable Nagle's algorithm for low latency
      logger.i("RouterOSClient socket connection opened.");

      // Convert the socket stream to a broadcast stream to allow multiple listeners.
      _socketStream = _socket!.asBroadcastStream();
    } on SocketException catch (e) {
      // Handle socket connection errors
      throw CreateSocketError(
          'Failed to connect to socket. Host: $address, port: $port. Error: ${e.message}');
    }
  }

  // Logs in to the RouterOS device using the provided credentials.
  Future<bool> login() async {
    try {
      await _openSocket(); // Open the socket connection
      var sentence = [
        '/login',
        '=name=$user',
        '=password=$password'
      ]; // Prepare login command
      var reply =
      await _communicate(sentence); // Send command and wait for reply
      _checkLoginReply(reply); // Check if login was successful
      return true;
    } catch (e) {
      logger.e('Login failed: $e');
      return false;
    }
  }

  // Sends a command to the RouterOS device and receives the reply.
  Future<List<List<String>>> _communicate(List<String> sentenceToSend) async {
    var socket = _socket;
    if (socket == null) {
      throw StateError(
          'Socket is not open.'); // Ensure the socket is open before sending data
    }

    for (var word in sentenceToSend) {
      // Send each word in the command sentence
      _sendLength(socket, word.length); // Send the length of the word
      socket.add(utf8.encode(word)); // Send the word itself encoded in UTF-8
      logger.d('>>> $word');
    }

    socket.add(
        [0]); // Send a zero-length word to indicate the end of the sentence

    return await _receiveData(); // Wait for the reply from the RouterOS device
  }

  // Receives data from the socket until a complete reply is received.
  Future<List<List<String>>> _receiveData() async {
    var buffer = <int>[]; // Buffer to accumulate received data
    var receivedData = <List<String>>[]; // List to store received sentences
    var completer = Completer<
        List<
            List<String>>>(); // Completer to signal when data is fully received

    // Listen to the incoming data stream
    _socketStream.listen((event) {
      buffer.addAll(event);

      while (true) {
        var sentence = _readSentenceFromBuffer(buffer);

        if (sentence.isEmpty) {
          // If the sentence is empty, it means we need to wait for more data
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

    return completer.future; // Return the received data as a Future
  }

  // Reads a sentence from the buffer and removes it from the buffer.
  List<String> _readSentenceFromBuffer(List<int> buffer) {
    var sentence = <String>[];

    while (buffer.isNotEmpty) {
      var length = _readLengthFromBuffer(buffer);

      if (length == 0) {
        break;
      }

      // Check if the buffer has enough data to read the full word
      if (buffer.length < length) {
        // Wait until more data arrives by returning an empty sentence
        return [];
      }

      var word = utf8.decode(buffer.sublist(0, length));
      sentence.add(word);
      buffer.removeRange(0, length);
    }

    return sentence;
  }

  // Reads the length of the next word in the buffer.
  int _readLengthFromBuffer(List<int> buffer) {
    var firstByte = buffer
        .removeAt(0); // Get the first byte, which determines the length format
    int length;

    if (firstByte < 0x80) {
      length = firstByte; // Single-byte length
    } else if (firstByte < 0xC0) {
      var secondByte = buffer.removeAt(0);
      length = ((firstByte << 8) | secondByte) - 0x8000; // Two-byte length
    } else if (firstByte < 0xE0) {
      var bytes = buffer.sublist(0, 2);
      buffer.removeRange(0, 2);
      length = ((firstByte << 16) | (bytes[0] << 8) | bytes[1]) -
          0xC00000; // Three-byte length
    } else if (firstByte < 0xF0) {
      var bytes = buffer.sublist(0, 3);
      buffer.removeRange(0, 3);
      length =
          ((firstByte << 24) | (bytes[0] << 16) | (bytes[1] << 8) | bytes[2]) -
              0xE0000000; // Four-byte length
    } else if (firstByte == 0xF0) {
      var bytes = buffer.sublist(0, 4);
      buffer.removeRange(0, 4);
      length = (bytes[0] << 24) |
      (bytes[1] << 16) |
      (bytes[2] << 8) |
      bytes[3]; // Full 32-bit length
    } else {
      throw WordTooLong(
          'Received word is too long.'); // Handle case where word is too long
    }

    return length; // Return the calculated length
  }

  // Sends the length of a word to the RouterOS device.
  void _sendLength(Socket socket, int length) {
    if (length < 0x80) {
      socket.add([length]); // Single-byte length
    } else if (length < 0x4000) {
      length += 0x8000;
      socket.add(length.toBytes(2)); // Two-byte length
    } else if (length < 0x200000) {
      length += 0xC00000;
      socket.add(length.toBytes(3)); // Three-byte length
    } else if (length < 0x10000000) {
      length += 0xE0000000;
      socket.add(length.toBytes(4)); // Four-byte length
    } else if (length < 0x100000000) {
      socket.add([0xF0]);
      socket.add(length.toBytes(4)); // Full 32-bit length
    } else {
      throw WordTooLong(
          'Word is too long. Max length is 4294967295.'); // Handle words that are too long
    }
  }

  // Checks the reply from the RouterOS device after a login attempt.
  void _checkLoginReply(List<List<String>> reply) {
    if (reply.isNotEmpty && reply[0].length == 1 && reply[0][0] == '!done') {
      logger.i('Login successful!');
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][0] == '!trap') {
      throw LoginError('Login error: ${reply[0][1]}'); // Handle login errors
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][1].startsWith('=ret=')) {
      logger.w('Using legacy login process.');
    } else {
      throw LoginError(
          'Unexpected login reply: $reply'); // Handle unexpected replies
    }
  }

  // Sends a command to the RouterOS device and returns the response.
  Future<List<Map<String, String>>> talk(dynamic message) async {
    if (message is String && message.contains(" ")) {
      message = _parseCommand(message); // Parse the command if it's a string with spaces
    }

    if (message is String) {
      // If message is a single string, wrap it in a list
      return _send([message]);
    } else if (message is List<String>) {
      return _send(message); // Send the command if it's a list of strings
    } else if (message is List<dynamic>) {
      var reply = <List<Map<String, String>>>[];
      for (var sentence in message) {
        reply.add(await _send(sentence)); // Handle multiple sentences
      }
      return reply.expand((element) => element).toList();
    } else {
      throw ArgumentError(
          'Invalid message type for talk: $message'); // Handle invalid input types
    }
  }

  // Streams data from the RouterOS device, useful for long-running commands.
  Stream<Map<String, String>> streamData(dynamic command) async* {
    var sentenceToSend =
    _parseCommand(command); // Parse the command into a sentence

    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.'); // Ensure the socket is open
    }

    for (var word in sentenceToSend) {
      _sendLength(socket, word.length); // Send each word in the sentence
      socket.add(utf8.encode(word));
      logger.d('>>> $word');
    }

    socket.add([0]); // Send a zero-length word to end the sentence

    await for (var event in _socketStream) {
      // Listen for incoming data
      var buffer = <int>[];
      buffer.addAll(event);
      while (buffer.isNotEmpty) {
        var sentence = _readSentenceFromBuffer(
            buffer); // Read the sentence from the buffer
        if (sentence.isNotEmpty) {
          var parsedData =
          _parseSentence(sentence); // Parse the sentence into a map
          yield parsedData; // Yield each parsed sentence
        }

        if (sentence.contains('!done') || sentence.contains('!trap')) {
          return; // Stop streaming if the command is done or there's an error
        }
      }
    }
  }

  // Parses a command string into the format required by RouterOS.
  List<String> _parseCommand(String command) {
    var parts = command.split(' '); // Split the command into parts by space
    return parts.map((part) {
      // Return the part as-is if it already contains '=' to avoid adding an extra '='
      return part.contains('=') ? part : '$part';
    }).toList();
  }

  // Parses a sentence from the RouterOS device into a map of key-value pairs.
  Map<String, String> _parseSentence(List<String> sentence) {
    var parsedData = <String, String>{};
    for (var word in sentence) {
      if (word.startsWith('!')) {
        continue; // Skip control words like !re, !done, etc.
      }
      if (word.startsWith('=')) {
        var parts = word.substring(1).split('=');
        if (parts.length == 2) {
          parsedData[parts[0]] = parts[1]; // Add key-value pair to the map
        }
      }
    }
    return parsedData;
  }

  // Sends a command and returns the parsed response.
  Future<List<Map<String, String>>> _send(List<String> sentence) async {
    var reply =
    await _communicate(sentence); // Send the command and wait for the reply

    if (reply.isNotEmpty && reply[0].isNotEmpty && reply[0][0] == '!trap') {
      logger.e('Command: $sentence\nReturned an error: $reply');
      throw RouterOSTrapError(
          "Command: $sentence\nReturned an error: $reply"); // Handle errors in the response
    }

    return _parseReply(reply); // Parse and return the reply
  }

  // Parses a reply from the RouterOS device into a list of maps.
  List<Map<String, String>> _parseReply(List<List<String>> reply) {
    var parsedReplies = <Map<String, String>>[];

    for (var sentence in reply) {
      var parsedReply = <String, String>{};
      for (var word in sentence) {
        if (word.startsWith('!')) {
          continue; // Skip control words like !re, !done, etc.
        }
        if (word.startsWith('=')) {
          var parts = word.substring(1).split('=');
          if (parts.length == 2) {
            parsedReply[parts[0]] = parts[1]; // Add key-value pair to the map
          }
        }
      }
      if (parsedReply.isNotEmpty) {
        parsedReplies.add(parsedReply); // Add the parsed reply only if it's not empty
      }
    }

    return parsedReplies; // Return the list of parsed replies
  }

  // Checks if the socket connection is still alive.
  Object isAlive() {
    if (_socket == null) {
      logger.w('Socket is not open.');
      return false;
    }

    try {
      final result = talk(['/system/identity/print'])
          .timeout(const Duration(seconds: 2)); // Send a simple command
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

  // Closes the socket connection to the RouterOS device.
  void close() {
    _socket?.destroy();
    _socket = null;
    _secureSocket = null;
    logger.i('RouterOSClient socket connection closed.');
  }
}

// Custom exceptions for specific errors that may occur.
class LoginError implements Exception {
  final String message;
  @override
  String toString() {
    return message;
  }
  LoginError(this.message);
}

class WordTooLong implements Exception {
  final String message;


  @override
  String toString() {
    return message;
  }

  WordTooLong(this.message);
}

class CreateSocketError implements Exception {
  final String message;

  @override
  String toString() {
    return message;
  }

  CreateSocketError(this.message);
}

class RouterOSTrapError implements Exception {
  final String message;
  @override
  String toString() {
    return message;
  }
  RouterOSTrapError(this.message);
}

// Extension method to convert an integer to a list of bytes.
extension on int {
  List<int> toBytes(int byteCount) {
    var result = <int>[];
    for (var i = 0; i < byteCount; i++) {
      result.add((this >> (8 * (byteCount - i - 1))) & 0xFF);
    }
    return result;
  }
}
