import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LoginError implements Exception {
  final String message;

  LoginError(this.message);
}

class WordTooLong implements Exception {
  final String message;

  WordTooLong(this.message);
}

class CreateSocketError implements Exception {
  final String message;

  CreateSocketError(this.message);
}

class RouterOSTrapError implements Exception {
  final String message;

  RouterOSTrapError(this.message);
}

class Api {
  final String address;
  String user;
  String password;
  bool useSsl;
  int port;
  bool verbose;
  SecurityContext? context;
  Duration? timeout;

  Socket? _socket;
  SecureSocket? _secureSocket;
  late Stream<List<int>> _socketStream; // Add a stream field

  Api({
    required this.address,
    this.user = 'admin',
    this.password = '',
    this.useSsl = false,
    int? port,
    this.verbose = false,
    this.context,
    this.timeout,
  }) : port = port ?? (useSsl ? 8729 : 8728);

  void log(String message) {
    if (verbose) {
      print(message);
    }
  }

  Future<void> openSocket() async {
    try {
      if (useSsl) {
        _secureSocket = await SecureSocket.connect(address, port, context: context);
        _socket = _secureSocket;
      } else {
        _socket = await Socket.connect(address, port);
      }
      _socket?.setOption(SocketOption.tcpNoDelay, true);
      log('API socket connection opened.');

      // Convert the socket stream to a broadcast stream
      _socketStream = _socket!.asBroadcastStream();
    } on SocketException catch (e) {
      throw CreateSocketError(
          'Error: API failed to connect to socket. Host: $address, port: $port. Error: ${e.message}');
    }
  }

  Future<bool> login() async {
    try {
      await openSocket();
      var sentence = ['/login', '=name=$user', '=password=$password'];
      var reply = await communicate(sentence);
      _checkReply(reply);
      return true; // Login successful
    } catch (e) {
      log('Login failed: $e');
      return false; // Login failed
    }
  }

  Future<List<List<String>>> communicate(List<String> sentenceToSend) async {
    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    for (var word in sentenceToSend) {
      _sendLength(socket, word.length);
      socket.add(utf8.encode(word));
      log('>>> $word');
    }

    socket.add([0]); // Send zero length word to mark end of the sentence

    var receivedData = await _receiveData();
    return receivedData;
  }


  Future<List<List<String>>> _receiveData() async {
    var buffer = <int>[];
    var receivedData = <List<String>>[];
    var completer = Completer<List<List<String>>>();

    // Listen to the broadcast stream
    _socketStream.listen((event) {
      buffer.addAll(event);
      while (buffer.isNotEmpty) {
        var sentence = _readSentenceFromBuffer(buffer);
        receivedData.add(sentence);
        if (sentence.contains('!done')) {
          // log('Received: $receivedData');
          if (!completer.isCompleted) {
            completer.complete(receivedData);
            // log('SHAFIQ: $receivedData');
          }
          break;
        }
      }
    });
    return completer.future;
  }

  List<String> _readSentenceFromBuffer(List<int> buffer) {
    var sentence = <String>[];

    while (buffer.isNotEmpty) {
      var length = _readLengthFromBuffer(buffer);
      if (length == 0) {
        break;
      }

      var word = utf8.decode(buffer.sublist(0, length));
      sentence.add(word);
      buffer.removeRange(0, length); // Remove the processed word from the buffer
    }

    return sentence;
  }

  // List<String> _readSentenceFromBuffer(List<int> buffer) {
  //   var sentence = <String>[];
  //
  //   while (buffer.isNotEmpty) {
  //     var length = _readLengthFromBuffer(buffer);
  //     if (length == 0) {
  //       break;
  //     }
  //
  //     var word = utf8.decode(buffer.sublist(0, length));
  //     sentence.add(word);
  //     buffer.removeRange(
  //         0, length); // Remove the processed word from the buffer
  //   }
  //
  //   return sentence;
  // }

  int _readLengthFromBuffer(List<int> buffer) {
    var firstByte = buffer.removeAt(0);
    int length;

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
      throw WordTooLong('Word is too long. Max length of word is 4294967295.');
    }
  }

  void _checkReply(List<List<String>> reply) {
    if (reply.isNotEmpty && reply[0].length == 1 && reply[0][0] == '!done') {
      log('Logged in successfully!');
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][0] == '!trap') {
      throw LoginError('Error in login process: ${reply[0][1]}');
    } else if (reply.isNotEmpty &&
        reply[0].length == 2 &&
        reply[0][1].startsWith('=ret=')) {
      log('Using old login process.');
    } else {
      throw LoginError('Unexpected reply to login: $reply');
    }
  }

  Future<List<Map<String, String>>> talk(dynamic message) async {
    if (message is String || message is List<String>) {
      return send(message);
    } else if (message is List<dynamic>) {
      var reply = <List<Map<String, String>>>[];
      for (var sentence in message) {
        reply.add(await send(sentence));
      }
      return reply.expand((element) => element).toList();
    } else {
      throw ArgumentError('Invalid argument type for talk: $message');
    }
  }

  Stream<Map<String, String>> streamData(List<String> sentenceToSend) async* {
    var socket = _socket;
    if (socket == null) {
      throw StateError('Socket is not open.');
    }

    // Send the command to the RouterOS device
    for (var word in sentenceToSend) {
      _sendLength(socket, word.length);
      socket.add(utf8.encode(word));
      log('>>> $word');
    }

    socket.add([0]); // Send zero length word to mark end of the sentence

    // Continuously listen to the data from the RouterOS device
    await for (var event in _socketStream) {
      var buffer = <int>[];
      buffer.addAll(event);
      while (buffer.isNotEmpty) {
        var sentence = _readSentenceFromBuffer(buffer);
        if (sentence.isNotEmpty) {
          var parsedData = _parseSentence(sentence);
          yield parsedData;
        }

        // Stop streaming if we receive a "!done" or "!trap" message
        if (sentence.contains('!done') || sentence.contains('!trap')) {
          return;
        }
      }
    }
  }

// Helper method to parse a sentence into a Map<String, String>
  Map<String, String> _parseSentence(List<String> sentence) {
    var parsedData = <String, String>{};
    for (var word in sentence) {
      if (word.startsWith('!')) {
        continue; // Skip control words like !re, !done, etc.
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

  Future<List<Map<String, String>>> send(List<String> sentence) async {
    var reply = await communicate(sentence);

    // Check if there was an error in the reply
    if (reply.isNotEmpty && reply[0].isNotEmpty && reply[0][0] == '!trap') {
      print('Command: $sentence\nReturned an error: $reply');
      throw RouterOSTrapError("Command: $sentence\nReturned an error: $reply");
    }

    return _parseReply(reply);
  }

  List<Map<String, String>> _parseReply(List<List<String>> reply) {
    var parsedReplies = <Map<String, String>>[];

    for (var sentence in reply) {
      var parsedReply = <String, String>{};
      for (var word in sentence) {
        if(word.startsWith('!')) {
          continue;
        }
        if (word.startsWith('=')) {
          var parts = word.substring(1).split('=');
          if (parts.length == 2) {
            parsedReply[parts[0]] = parts[1];
          }
        }
      }
      parsedReplies.add(parsedReply);
    }

    return parsedReplies;
  }


  bool isAlive() {
    if (_socket == null) {
      log('Socket is not open.');
      return false;
    }

    try {
      final result =
          talk(['/system/identity/print']).timeout(Duration(seconds: 2));
      print('Result: $result');
      return result != null;
    } on TimeoutException {
      log('Socket read timeout.');
      close();
      return false;
    } catch (e) {
      log('Socket is closed or router does not respond: $e');
      close();
      return false;
    }
  }

  void close() {
    _socket?.destroy();
    _socket = null;
    _secureSocket = null;
    log('API socket connection closed.');
  }
}

extension on int {
  List<int> toBytes(int byteCount) {
    var result = <int>[];
    for (var i = 0; i < byteCount; i++) {
      result.add((this >> (8 * (byteCount - i - 1))) & 0xFF);
    }
    return result;
  }
}
