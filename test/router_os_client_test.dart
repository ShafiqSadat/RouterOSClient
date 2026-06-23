import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:router_os_client/router_os_client.dart';
import 'package:router_os_client/src/protocol.dart';

/// A minimal RouterOS API server that speaks the real wire protocol over a
/// loopback socket. Tests run the actual client against it — no mocks.
class FakeRouterOs {
  /// Maps an incoming request sentence to the response sentences to send back.
  /// The request's `.tag` (if any) is echoed onto every response automatically.
  final List<List<String>> Function(List<String> request) handler;

  late ServerSocket _server;
  final List<Socket> _connections = [];

  FakeRouterOs(this.handler);

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _connections.add(socket);
      final buffer = SentenceBuffer();
      socket.listen((data) {
        buffer.addBytes(data);
        while (true) {
          final sentence = buffer.nextSentence();
          if (sentence == null) break;
          final tag = sentence.firstWhere(
            (w) => w.startsWith('.tag='),
            orElse: () => '',
          );
          for (final response in handler(sentence)) {
            _writeSentence(socket, [
              ...response,
              if (tag.isNotEmpty) tag,
            ]);
          }
        }
      });
    });
  }

  void _writeSentence(Socket socket, List<String> words) {
    for (final word in words) {
      final encoded = utf8.encode(word);
      socket.add(encodeLength(encoded.length));
      socket.add(encoded);
    }
    socket.add([0]);
  }

  Future<void> stop() async {
    for (final c in _connections) {
      c.destroy();
    }
    await _server.close();
  }
}

void main() {
  late FakeRouterOs server;

  RouterOSClient clientFor(FakeRouterOs s) => RouterOSClient(
        address: '127.0.0.1',
        port: s.port,
        user: 'admin',
        password: 'pw',
        timeout: const Duration(seconds: 5),
      );

  tearDown(() async {
    await server.stop();
  });

  test('login succeeds when the router replies !done', () async {
    server = FakeRouterOs((req) => [
          ['!done']
        ]);
    await server.start();

    final client = clientFor(server);
    expect(await client.login(), isTrue);
    client.close();
  });

  test('login fails when the router replies !trap', () async {
    server = FakeRouterOs((req) {
      if (req.first == '/login') {
        return [
          ['!trap', '=message=invalid user name or password'],
          ['!done'],
        ];
      }
      return [
        ['!done']
      ];
    });
    await server.start();

    final client = clientFor(server);
    expect(await client.login(), isFalse);
    client.close();
  });

  test('tagged talk preserves values containing "="', () async {
    server = FakeRouterOs((req) {
      if (req.first == '/login') {
        return [
          ['!done']
        ];
      }
      return [
        ['!re', '=name=MyRouter', '=secret=YWJjPT0='],
        ['!done'],
      ];
    });
    await server.start();

    final client = clientFor(server);
    await client.login();
    final result =
        await client.talk('/system/identity/print', null, 'mytag');

    expect(result, [
      {'name': 'MyRouter', 'secret': 'YWJjPT0='}
    ]);
    client.close();
  });

  test('two concurrent untagged commands both resolve correctly', () async {
    server = FakeRouterOs((req) {
      if (req.first == '/login') {
        return [
          ['!done']
        ];
      }
      if (req.first == '/a') {
        return [
          ['!re', '=which=a'],
          ['!done'],
        ];
      }
      return [
        ['!re', '=which=b'],
        ['!done'],
      ];
    });
    await server.start();

    final client = clientFor(server);
    await client.login();

    final results = await Future.wait([
      client.talk('/a'),
      client.talk('/b'),
    ]);

    expect(results[0], [
      {'which': 'a'}
    ]);
    expect(results[1], [
      {'which': 'b'}
    ]);
    client.close();
  });

  test('client can reconnect after close()', () async {
    server = FakeRouterOs((req) => [
          ['!done']
        ]);
    await server.start();

    final client = clientFor(server);
    expect(await client.login(), isTrue);
    client.close();

    // Reconnecting must not throw "Cannot add new events after calling close".
    expect(await client.login(), isTrue);
    client.close();
  });

  test('isAlive() returns an awaitable bool', () async {
    server = FakeRouterOs((req) {
      if (req.first == '/login') {
        return [
          ['!done']
        ];
      }
      return [
        ['!re', '=name=MyRouter'],
        ['!done'],
      ];
    });
    await server.start();

    final client = clientFor(server);
    await client.login();

    final alive = await client.isAlive();
    expect(alive, isTrue);
    client.close();
  });
}
