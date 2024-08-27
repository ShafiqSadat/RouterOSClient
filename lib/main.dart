import 'package:flutter/material.dart';
import 'package:socket_flutter/router_os_client.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RouterOS Connect',
      home: RouterOSWidget(),
    );
  }
}

class RouterOSWidget extends StatefulWidget {
  @override
  _RouterOSWidgetState createState() => _RouterOSWidgetState();
}

class _RouterOSWidgetState extends State<RouterOSWidget> {
  late RouterOSClient client;
  String status = 'Not Connected';
  List<String> connectedDevices = [];
  TextEditingController addressController = TextEditingController();
  TextEditingController userController = TextEditingController();
  TextEditingController passwordController = TextEditingController();
  TextEditingController portController = TextEditingController();
  TextEditingController commandController = TextEditingController();
  String commandOutput = '';
  bool useStream = false;

  @override
  void initState() {
    super.initState();
    addressController.text = '103.215.210.42';  // Default value
    userController.text = 'raha';               // Default value
    passwordController.text = 'raha';           // Default value
    portController.text = '887';                // Default value
  }

  Future<void> _connectToRouter() async {
    try {
      client = RouterOSClient(
        address: addressController.text,
        user: userController.text,
        password: passwordController.text,
        port: int.parse(portController.text),
        useSsl: false,
        timeout: Duration(seconds: 10),
        verbose: true,
      );

      bool loginSuccess = await client.login();
      if (loginSuccess) {
        setState(() {
          status = 'Connected to RouterOS';
        });
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
        setState(() {
          connectedDevices = devices
              .map((device) =>
          'IP: ${device['address']}, MAC: ${device['mac-address']}')
              .toList();
        });
      });
    } catch (e) {
      setState(() {
        connectedDevices = ['Failed to fetch devices: $e'];
      });
    }
  }

  Future<void> _executeCommand() async {
    String command = commandController.text;
    try {
      if (useStream) {
        await startTorchStream(command);
      } else {
        var result = await client.talk([command]);
        setState(() {
          commandOutput = result.toString();
        });
      }
    } catch (e) {
      setState(() {
        commandOutput = 'Failed to execute command: $e';
      });
    }
  }

  Future<void> startTorchStream(String command) async {
    try {
      var stream = client.streamData(command);

      await for (var sentence in stream) {
        setState(() {
          commandOutput = sentence.toString();
        });
      }
    } catch (e) {
      print('Error while streaming data: $e');
      setState(() {
        commandOutput = 'Error while streaming data: $e';
      });
    }
  }

  @override
  void dispose() {
    client.close();
    addressController.dispose();
    userController.dispose();
    passwordController.dispose();
    portController.dispose();
    commandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('RouterOS Connection'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'RouterOS Address',
              ),
            ),
            SizedBox(height: 10),
            TextField(
              controller: userController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Username',
              ),
            ),
            SizedBox(height: 10),
            TextField(
              controller: passwordController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Password',
              ),
            ),
            SizedBox(height: 10),
            TextField(
              controller: portController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Port',
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                await _connectToRouter();
              },
              child: Text('Connect'),
            ),
            SizedBox(height: 20),
            Text('Connection Status: $status'),
            SizedBox(height: 20),
            ListView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(), // Disable internal scrolling
              itemCount: connectedDevices.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(connectedDevices[index]),
                );
              },
            ),
            TextField(
              controller: commandController,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Enter Command',
              ),
            ),
            SizedBox(height: 10),
            CheckboxListTile(
              title: Text('Use Stream'),
              value: useStream,
              onChanged: (bool? value) {
                setState(() {
                  useStream = value ?? false;
                });
              },
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
            SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: Text(commandOutput),
            ),
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
        ),
      ),
    );
  }
}
