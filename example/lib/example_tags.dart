import 'package:router_os_client/router_os_client.dart';


/// Example demonstrating the new tag functionality in RouterOSClient
void main() async {
  // Create client instance
  final client = RouterOSClient(
    address: '192.168.1.1',
    user: 'admin',
    password: 'password',
    verbose: true,
  );

  try {
    // Login to the device
    print('Logging in...');
    bool loginSuccess = await client.login();
    if (!loginSuccess) {
      print('Login failed!');
      return;
    }
    print('Login successful!');

    // Example 1: Traditional usage (backward compatible)
    print('\n=== Example 1: Traditional Usage ===');
    var interfaces = await client.talk('/interface/print');
    print('Found ${interfaces.length} interfaces');

    // Example 2: Using tags for single commands
    print('\n=== Example 2: Single Tagged Command ===');
    var taggedResponse = await client.talkTagged(
        '/system/resource/print',
        null,
        'system-info'
    );
    print('Response tag: ${taggedResponse.tag}');
    print('Is done: ${taggedResponse.isDone}');
    print('Data: ${taggedResponse.data}');

    // Example 3: Multiple simultaneous commands with tags
    print('\n=== Example 3: Multiple Simultaneous Commands ===');
    var commands = [
      TaggedCommand(
        command: '/interface/print',
        tag: 'interfaces-cmd',
      ),
      TaggedCommand(
        command: '/ip/address/print',
        tag: 'addresses-cmd',
      ),
      TaggedCommand(
        command: '/system/identity/print',
        tag: 'identity-cmd',
      ),
    ];

    await for (var response in client.talkMultiple(commands)) {
      print('Received response for tag: ${response.tag}');
      print('Done: ${response.isDone}, Error: ${response.isError}');
      print('Data count: ${response.data.length}');

      if (response.isError) {
        print('Error: ${response.errorMessage}');
      }
    }

    // Example 4: Long-running command with streaming and cancellation
    print('\n=== Example 4: Streaming with Cancellation ===');
    String streamTag = 'interface-monitor';

    // Start streaming interface changes
    var streamFuture = _monitorInterfaces(client, streamTag);

    // Simulate some activity (wait 5 seconds then cancel)
    await Future.delayed(Duration(seconds: 5));

    print('Cancelling interface monitor...');
    await client.cancelTagged(streamTag);

    // Wait for stream to finish
    await streamFuture;

    // Example 5: Batch operations with different parameters
    print('\n=== Example 5: Batch Operations ===');
    await _performBatchOperations(client);

  } catch (e) {
    print('Error: $e');
  } finally {
    client.close();
    print('Connection closed.');
  }
}

/// Example of monitoring interface changes
Future<void> _monitorInterfaces(RouterOSClient client, String tag) async {
  try {
    print('Starting interface monitoring with tag: $tag');
    await for (var data in client.streamData('/interface/listen', null, tag)) {
      print('Interface change detected: $data');
    }
    print('Interface monitoring stopped.');
  } catch (e) {
    print('Interface monitoring error: $e');
  }
}

/// Example of performing batch operations
Future<void> _performBatchOperations(RouterOSClient client) async {
  var batchCommands = [
    TaggedCommand(
      command: '/system/resource/print',
      params: {'.proplist': 'cpu-load,free-memory,uptime'},
      tag: 'resource-info',
    ),
    TaggedCommand(
      command: '/interface/print',
      params: {'?type': 'ether'},
      tag: 'ethernet-interfaces',
    ),
    TaggedCommand(
      command: '/ip/route/print',
      params: {'?dst-address': '0.0.0.0/0'},
      tag: 'default-routes',
    ),
  ];

  var responseCount = 0;
  var totalCommands = batchCommands.length;

  await for (var response in client.talkMultiple(batchCommands)) {
    responseCount++;

    switch (response.tag) {
      case 'resource-info':
        print('System Resource Info:');
        for (var item in response.data) {
          print('  CPU Load: ${item['cpu-load']}%');
          print('  Free Memory: ${item['free-memory']} bytes');
          print('  Uptime: ${item['uptime']}');
        }
        break;

      case 'ethernet-interfaces':
        print('Ethernet Interfaces:');
        for (var item in response.data) {
          print('  ${item['name']}: ${item['running'] == 'true' ? 'UP' : 'DOWN'}');
        }
        break;

      case 'default-routes':
        print('Default Routes:');
        for (var item in response.data) {
          print('  Gateway: ${item['gateway']}');
        }
        break;
    }

    if (responseCount >= totalCommands) {
      break;
    }
  }
}

/// Example showing error handling with tags
Future<void> _demonstrateErrorHandling(RouterOSClient client) async {
  try {
    // This command should fail
    var response = await client.talkTagged(
        '/invalid/command',
        null,
        'error-test'
    );

    if (response.isError) {
      print('Expected error occurred: ${response.errorMessage}');
    }
  } catch (e) {
    print('Caught exception: $e');
  }
}

/// Example showing how to use tags with parameters
Future<void> _demonstrateParametersWithTags(RouterOSClient client) async {
  // Get specific interface information
  var response = await client.talkTagged(
      '/interface/print',
      {
        '?name': 'ether1',
        '.proplist': 'name,mtu,running,disabled'
      },
      'ether1-info'
  );

  print('Interface ether1 info (tag: ${response.tag}):');
  for (var item in response.data) {
    print('  Name: ${item['name']}');
    print('  MTU: ${item['mtu']}');
    print('  Running: ${item['running']}');
    print('  Disabled: ${item['disabled']}');
  }
}
