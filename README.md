# RouterOSClient

`RouterOSClient` is a Dart/Flutter package that provides an easy-to-use interface for connecting and communicating with Mikrotik's RouterOS devices via a socket connection. This package supports both standard and secure (SSL/TLS) connections, enabling you to send commands and receive data from RouterOS devices in real-time.

## Features

- **Socket Connection**: Connect to RouterOS devices using either standard TCP or secure SSL/TLS sockets.
- **Command Execution**: Send commands to RouterOS and receive structured replies.
- **Tag Support**: Execute multiple commands simultaneously with tag-based response routing.
- **Concurrent Operations**: Run multiple commands at once without requiring additional socket connections.
- **Stream Data**: Stream long-running commands to receive continuous updates.
- **Error Handling**: Comprehensive error handling with custom exceptions for various failure scenarios.
- **Verbose Logging**: Optional logging for debugging and monitoring communication.

## Installation

Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  router_os_client: ^2.0.0
```

Then run:

```bash
flutter pub get
```

## Usage

### 1. Create an Instance of `RouterOSClient`

```dart
import 'package:router_os_client/router_os_client.dart';

void main() async {
  RouterOSClient client = RouterOSClient(
    address: '192.168.88.1', // Replace with your RouterOS IP address
    user: 'admin',           // Replace with your RouterOS username
    password: 'password',    // Replace with your RouterOS password
    useSsl: false,           // Set to true if you are using SSL/TLS
    verbose: true,           // Set to true for detailed logging
  );

  bool isConnected = await client.login();

  if (isConnected) {
    print('Connected to RouterOS');
  } else {
    print('Failed to connect to RouterOS');
  }
}
```

### 2. Send a Command

To send a command to the RouterOS device and get a response:

```dart
void fetchInterfaces() async {
  List<Map<String, String>> interfaces = await client.talk(['/interface/print']);

  for (var interface in interfaces) {
    print('Interface Name: ${interface['name']}');
  }
}
```

### 3. Using Tags for Concurrent Operations

Tags allow you to execute multiple commands simultaneously and identify their responses:

```dart
void concurrentOperations() async {
  // Execute multiple commands simultaneously
  var commands = [
    TaggedCommand(command: '/interface/print', tag: 'interfaces'),
    TaggedCommand(command: '/ip/address/print', tag: 'addresses'),
    TaggedCommand(command: '/system/resource/print', tag: 'resources'),
  ];

  await for (var response in client.talkMultiple(commands)) {
    print('Response from ${response.tag}: ${response.data.length} items');
    
    if (response.isError) {
      print('Error in ${response.tag}: ${response.errorMessage}');
    }
  }
}
```

### 4. Single Tagged Command

Send a single command with a tag for better control:

```dart
void singleTaggedCommand() async {
  var response = await client.talkTagged('/interface/print', null, 'interface-list');
  
  print('Tag: ${response.tag}');
  print('Completed: ${response.isDone}');
  print('Interfaces found: ${response.data.length}');
}
```

### 5. Cancel Operations by Tag

Cancel specific operations using their tags:

```dart
void cancelOperation() async {
  // Start a long-running operation
  String monitorTag = 'interface-monitor';
  
  // Cancel it after some time
  await Future.delayed(Duration(seconds: 10));
  await client.cancelTagged(monitorTag);
}
```

### 6. Stream Data from RouterOS

For long-running commands like `/tool/torch`, you can stream the data:

```dart
void streamTorchData() async {
  await for (var data in client.streamData('/tool/torch interface=ether1')) {
    print('Torch Data: $data');
  }
}
```

### 7. Close the Connection

After you are done communicating with the RouterOS device, close the connection:

```dart
client.close();
```

## Error Handling

`RouterOSClient` provides several custom exceptions to handle errors gracefully:

- `LoginError`: Thrown when there is an error during the login process.
- `WordTooLong`: Thrown when a command word exceeds the maximum length.
- `CreateSocketError`: Thrown when the socket connection fails.
- `RouterOSTrapError`: Thrown when RouterOS returns a trap error in response to a command.

Example:

```dart
try {
await client.login();
} catch (LoginError e) {
print('Login failed: ${e.message}');
} catch (CreateSocketError e) {
print('Socket creation failed: ${e.message}');
}
```

## API Reference

### New Classes for Tag Support

#### `TaggedResponse`
Represents a response from a tagged command:
```dart
class TaggedResponse {
  final List<Map<String, String>> data;  // Parsed response data
  final String? tag;                     // Command tag
  final bool isDone;                     // Whether command completed
  final bool isError;                    // Whether response is an error
  final String? errorMessage;            // Error message if applicable
}
```

#### `TaggedCommand`
Represents a command for batch operations:
```dart
class TaggedCommand {
  final dynamic command;                 // Command to execute
  final Map<String, String>? params;     // Command parameters
  final String? tag;                     // Command tag
}
```

### Enhanced Methods

#### `talk()` - Now with optional tag support
```dart
// Traditional usage
var result = await client.talk('/interface/print');

// With parameters
var result = await client.talk('/interface/print', {'?type': 'ether'});

// With tag for concurrent operations
var result = await client.talk('/interface/print', {'?type': 'ether'}, 'my-tag');
```

#### `talkTagged()` - New tagged command method
```dart
Future<TaggedResponse> talkTagged(
  dynamic command,
  [Map<String, String>? params, String? tag]
)
```

#### `talkMultiple()` - Execute multiple commands simultaneously
```dart
Stream<TaggedResponse> talkMultiple(List<TaggedCommand> commands)
```

#### `cancelTagged()` - Cancel commands by tag
```dart
Future<void> cancelTagged(String tag)
```

## Examples

Here are comprehensive examples showcasing both traditional and new tag-based functionality:

### Basic Connection and Commands

```dart
import 'package:router_os_client/router_os_client.dart';

void main() async {
  RouterOSClient client = RouterOSClient(
    address: '192.168.88.1',
    user: 'admin',
    password: 'password',
    useSsl: false,
    verbose: true,
  );

  try {
    if (await client.login()) {
      print('Connected to RouterOS');

      // Fetch and print interface list
      List<Map<String, String>> interfaces = await client.talk(['/interface/print']);
      interfaces.forEach((interface) {
        print('Interface: ${interface['name']}');
      });

      // Stream torch data
      await for (var data in client.streamData('/tool/torch interface=ether1')) {
        print('Torch Data: $data');
      }
    } else {
      print('Failed to connect to RouterOS');
    }
  } catch (e) {
    print('Error: $e');
  } finally {
    client.close();
  }
}
```

### Concurrent Operations with Tags

```dart
void demonstrateTaggedOperations() async {
  RouterOSClient client = RouterOSClient(
    address: '192.168.88.1',
    user: 'admin',
    password: 'password',
  );

  await client.login();

  // Execute multiple commands simultaneously
  var commands = [
    TaggedCommand(
      command: '/interface/print',
      params: {'.proplist': 'name,type,running'},
      tag: 'interfaces',
    ),
    TaggedCommand(
      command: '/ip/address/print',
      params: {'.proplist': 'address,interface'},
      tag: 'addresses',
    ),
    TaggedCommand(
      command: '/system/resource/print',
      params: {'.proplist': 'cpu-load,free-memory'},
      tag: 'resources',
    ),
  ];

  var results = <String, List<Map<String, String>>>{};

  await for (var response in client.talkMultiple(commands)) {
    results[response.tag!] = response.data;
    
    if (response.isDone) {
      print('${response.tag} completed with ${response.data.length} items');
    }
    
    if (response.isError) {
      print('${response.tag} failed: ${response.errorMessage}');
    }
  }

  client.close();
}
```

### Long-Running Operations with Cancellation

```dart
void monitorWithCancellation() async {
  RouterOSClient client = RouterOSClient(
    address: '192.168.88.1',
    user: 'admin',
    password: 'password',
  );

  await client.login();

  String monitorTag = 'interface-monitor';
  
  // Start monitoring interfaces
  var monitoring = client.streamData('/interface/listen', null, monitorTag);
  
  // Process changes for 30 seconds
  var subscription = monitoring.listen((data) {
    print('Interface change detected: $data');
  });
  
  // Cancel after 30 seconds
  Future.delayed(Duration(seconds: 30), () async {
    await client.cancelTagged(monitorTag);
    subscription.cancel();
    client.close();
  });
}
```

### Example: Using `talk` with Parameters

The `talk` method can now accept a `Map<String, String>` for sending commands with parameters to the RouterOS device.

#### Example:
```dart
await client.talk('/queue/simple/add', {
'.id': '*1',
'target': '192.168.88.1/32',
'priority': '1',
'max-limit': '10M/10M',
'dynamic': 'false',
'disabled': 'false',
});
```

This allows you to send more complex commands with key-value pairs for configuring the RouterOS device.


## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a pull request or file an issue on the GitHub repository.

## Contact

For any issues or feature requests, please contact [@Shafiq](https://t.me/Shafiq) or open an issue on GitHub.
