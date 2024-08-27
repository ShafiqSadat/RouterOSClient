import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:router_os_client/router_os_client.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RouterOS Connect',
      home: RouterOSWidget(),
    );
  }
}

class RouterOSWidget extends StatefulWidget {
  const RouterOSWidget({super.key});

  @override
  RouterOSWidgetState createState() => RouterOSWidgetState();
}

class RouterOSWidgetState extends State<RouterOSWidget> {
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
    addressController.text = ''; // Default value
    userController.text = ''; // Default value
    passwordController.text = ''; // Default value
    portController.text = ''; // Default value
  }

  Future<void> _connectToRouter() async {
    try {
      client = RouterOSClient(
        address: addressController.text,
        user: userController.text,
        password: passwordController.text,
        port: int.parse(portController.text),
        useSsl: false,
        timeout: const Duration(seconds: 10),
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
      if (kDebugMode) {
        print('Error while streaming data: $e');
      }
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
        title: const Text('RouterOS Connection'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'RouterOS Address',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: userController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Username',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Password',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: portController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Port',
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                if (addressController.text.isNotEmpty &&
                    userController.text.isNotEmpty &&
                    passwordController.text.isNotEmpty &&
                    portController.text.isNotEmpty) {
                  await _connectToRouter();
                } else {
                  setState(() {
                    status = 'Please fill all fields';
                  });
                }
              },
              child: const Text('Connect'),
            ),
            const SizedBox(height: 20),
            Text('Connection Status: $status'),
            const SizedBox(height: 20),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              // Disable internal scrolling
              itemCount: connectedDevices.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(connectedDevices[index]),
                );
              },
            ),
            TextField(
              controller: commandController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Enter Command',
              ),
            ),
            const SizedBox(height: 10),
            CheckboxListTile(
              title: const Text('Use Stream'),
              value: useStream,
              onChanged: (bool? value) {
                setState(() {
                  useStream = value ?? false;
                });
              },
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () async {
                await _executeCommand();
              },
              child: const Text('Execute Command'),
            ),
            const SizedBox(height: 20),
            const Text('Command Output:'),
            SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: Text(commandOutput),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                client.close();
                setState(() {
                  status = 'Disconnected';
                  connectedDevices.clear();
                });
              },
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }
}
