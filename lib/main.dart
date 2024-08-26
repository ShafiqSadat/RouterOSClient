import 'package:flutter/material.dart';
import 'package:socket_flutter/router_os_client.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RouterOS Connect',
      home: Scaffold(
        appBar: AppBar(
          title: Text('RouterOS Connection'),
        ),
        body: Center(
          child: RouterOSWidget(),
        ),
      ),
    );
  }
}

class RouterOSWidget extends StatefulWidget {
  @override
  _RouterOSWidgetState createState() => _RouterOSWidgetState();
}

class _RouterOSWidgetState extends State<RouterOSWidget> {
  late Api client;
  String status = 'Not Connected';
  List<String> connectedDevices = [];
  TextEditingController commandController = TextEditingController();
  String commandOutput = '';

  @override
  void initState() {
    super.initState();
    client = Api(
      address: '192.168.0.1',
      user: 'raha',
      password: 'raha',
      port: 887,
      useSsl: false,
      verbose: true,
    );

    _connectToRouter();
  }

  Future<void> _connectToRouter() async {
    try {
      bool loginSuccess = await client.login();
      if (loginSuccess) {
        setState(() {
          status = 'Connected to RouterOS';
        });

        // Fetch and display the list of connected devices
        // await _fetchConnectedDevices();
      } else {
        setState(() {
          status = 'Login failed';
        });
      }
    } catch (e) {
      setState(() {
        status = 'Connection failed: $e';
      });
    }
  }

  Future<void> _fetchConnectedDevices() async {
    try {
      client.talk(['/ip/dhcp-server/lease/print']).then((devices) {
        print("Devices: $devices");
        setState(() {
          connectedDevices = devices
              .map((device) =>
          'IP: ${device['address']}, MAC: ${device['mac-address']}')
              .toList();
        });
      });
    } catch (e) {
      setState(() {
        print('Failed to fetch devices: $e');
        connectedDevices = ['Failed to fetch devices: $e'];
      });
    }
  }

  Future<void> startTorchStream() async {
    try {
      var stream = client.streamData([
        '/tool/torch',
        '=interface=wifi_bridge',
        '=src-address=192.168.0.130'
      ]);

      await for (var sentence in stream) {
        print('Received: $sentence');
        // Process the data as needed
        setState(() {
          commandOutput = sentence.toString();
        });
      }
    } catch (e) {
      print('Error while streaming data: $e');
    }
  }


  Future<void> _executeCommand() async {
    String command = commandController.text;
    try {
      var result;
      if (command == 'torch') {
        startTorchStream();
      } else {
        result = await client.talk([command]);
      }
      setState(() {
        commandOutput = result.toString();
      });
      print("Command Output: $result");
    } catch (e) {
      setState(() {
        commandOutput = 'Failed to execute command: $e';
      });
      print('Failed to execute command: $e');
    }
  }

  @override
  void dispose() {
    client.close();
    commandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(status),
        SizedBox(height: 20),
        ElevatedButton(
          onPressed: () async {
            await _fetchConnectedDevices();
          },
          child: Text('Refresh Devices'),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: connectedDevices.length,
            itemBuilder: (context, index) {
              return ListTile(
                title: Text(connectedDevices[index]),
              );
            },
          ),
        ),
        SizedBox(height: 20),
        TextField(
          controller: commandController,
          decoration: InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Enter Command',
          ),
        ),
        SizedBox(height: 10),
        ElevatedButton(
          onPressed: () async {
            await _executeCommand();
          },
          child: Text('Execute Command'),
        ),
        SizedBox(height: 20),
        Text('Command Output:'),
        Text(commandOutput),
        SizedBox(height: 20),
        ElevatedButton(
          onPressed: () {
            client.close();
            setState(() {
              status = 'Disconnected';
              connectedDevices.clear();
            });
          },
          child: Text('Disconnect'),
        ),
      ],
    );
  }
}
