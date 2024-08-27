
# Example: `router_os_client`

This example demonstrates how to use the `router_os_client` package to connect to a RouterOS device, send commands, and handle responses.

## Basic Usage

### 1. Import the Package

First, import the `router_os_client` package in your Dart file.

```dart
import 'package:router_os_client/router_os_client.dart';
```

### 2. Create an Instance of `RouterOSClient`

Instantiate the `RouterOSClient` with the IP address, username, and password of your RouterOS device.

```dart
void main() async {
  final routerOSClient = RouterOSClient(
    host: '192.168.88.1',  // Replace with your RouterOS device IP
    username: 'admin',     // Replace with your username
    password: 'password',  // Replace with your password
  );

  // Attempt to connect to the RouterOS device
  try {
    await routerOSClient.connect();
    print('Connected to RouterOS device');
  } catch (e) {
    print('Failed to connect: $e');
    return;
  }
```

### 3. Send Commands to the RouterOS Device

Use the `sendCommand` method to send commands to the RouterOS device and handle the response.

```dart
  try {
    final response = await routerOSClient.sendCommand('/interface/print');
    print('Response from RouterOS: $response');
  } catch (e) {
    print('Failed to send command: $e');
  }
```

### 4. Handle Exceptions

Ensure you handle any exceptions that may occur during the connection or command execution process.

```dart
  // Close the connection when done
  try {
    await routerOSClient.close();
    print('Connection closed');
  } catch (e) {
    print('Failed to close connection: $e');
  }
}
```

### Full Example

Here is the full example code:

```dart
import 'package:router_os_client/router_os_client.dart';

void main() async {
  final routerOSClient = RouterOSClient(
    host: '192.168.88.1',  // Replace with your RouterOS device IP
    username: 'admin',     // Replace with your username
    password: 'password',  // Replace with your password
  );

  // Attempt to connect to the RouterOS device
  try {
    await routerOSClient.connect();
    print('Connected to RouterOS device');

    // Send a command
    final response = await routerOSClient.sendCommand('/interface/print');
    print('Response from RouterOS: $response');

  } catch (e) {
    print('Error: $e');
  } finally {
    // Close the connection
    try {
      await routerOSClient.close();
      print('Connection closed');
    } catch (e) {
      print('Failed to close connection: $e');
    }
  }
}
```

## More Examples

- **Example 1:** [Managing Multiple Connections](#) - Demonstrates how to manage multiple RouterOS connections.
- **Example 2:** [Handling Streaming Data](#) - Shows how to handle streaming data from RouterOS commands.

Refer to the [API documentation](#) for more details on available methods and features.
