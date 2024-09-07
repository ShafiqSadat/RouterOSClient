
# RouterOSClient

`RouterOSClient` is a Dart/Flutter package that provides an easy-to-use interface for connecting and interacting with Mikrotik's RouterOS devices via a socket connection. This package supports both standard and secure (SSL/TLS) connections, enabling you to send commands and receive data from RouterOS devices in real-time.

## Features

- **Socket Connection**: Connect to RouterOS devices using either standard TCP or secure SSL/TLS sockets.
- **Command Execution**: Send commands to RouterOS and receive structured replies.
- **Stream Data**: Stream long-running commands to receive continuous updates.
- **Error Handling**: Comprehensive error handling with custom exceptions for various failure scenarios.
- **Verbose Logging**: Optional logging for debugging and monitoring communication.

## Installation

Add the following to your `pubspec.yaml` file:

```yaml
dependencies:
  router_os_client: ^1.0.6
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

### 3. Stream Data from RouterOS

For long-running commands like `/tool/torch`, you can stream the data:

```dart
void streamTorchData() async {
  await for (var data in client.streamData('/tool/torch interface=ether1')) {
    print('Torch Data: $data');
  }
}
```

### 4. Close the Connection

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

## Examples

Here's a full example of connecting, sending a command, and streaming data:

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

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a pull request or file an issue on the GitHub repository.

## Contact

For any issues or feature requests, please contact [@Shafiq](https://t.me/Shafiq) or open an issue on GitHub.

