import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chat App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({Key? key}) : super(key: key);

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // IMPORTANT: Change this URL to your deployed server URL once deployed!
  // For physical device, use your computer's local IP (e.g. 192.168.x.x) or the Cloud URL.
  // Updated to your current Local IP:
  static const String serverUrl = 'http://10.171.155.13:8000'; 
  
  late IO.Socket socket;
  List<dynamic> messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool isConnected = false;

  @override
  void initState() {
    super.initState();
    _loadLocalMessages();
    _fetchHistory();
    _connectSocket();
  }

  Future<void> _loadLocalMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final String? storedMessages = prefs.getString('chat_messages');
    if (storedMessages != null) {
      setState(() {
        messages = json.decode(storedMessages);
      });
      _scrollToBottom();
    }
  }

  Future<void> _saveMessages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_messages', json.encode(messages));
  }

  Future<void> _fetchHistory() async {
    try {
      final response = await http.get(Uri.parse('$serverUrl/api/messages'));
      if (response.statusCode == 200) {
        final List<dynamic> serverMessages = json.decode(response.body);
        setState(() {
          // You might want to implement a more sophisticated merge strategy here
          messages = serverMessages;
        });
        _saveMessages(); // Cache updated history
        _scrollToBottom();
      }
    } catch (e) {
      print('Error fetching history: $e');
    }
  }

  void _connectSocket() {
    socket = IO.io(serverUrl, IO.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .build());
    
    socket.connect();

    socket.onConnect((_) {
      print('Connected to socket');
      setState(() {
        isConnected = true;
      });
    });

    socket.on('chat message', (data) {
      print('Received message: $data');
      
      // If the message is from me, I already added it optimistically.
      // So ignore it to avoid duplicates.
      if (data is Map && data['senderId'] == socket.id) {
        return;
      }
      
      setState(() {
        if (data is String) {
           messages.add({'text': data, 'senderId': 'unknown'});
        } else {
           messages.add(data);
        }
      });
      _saveMessages(); // Save new message
      _scrollToBottom();
    });

    socket.onDisconnect((_) {
       print('Disconnected');
       setState(() {
         isConnected = false;
       });
    });
  }

  void _sendMessage() {
    if (_controller.text.trim().isNotEmpty) {
      final text = _controller.text;
      
      // Temporary ID for the message to update status later
      final tempId = DateTime.now().millisecondsSinceEpoch.toString();

      setState(() {
        messages.add({
          'id': tempId,
          'text': text, 
          'senderId': socket.id,
          'status': 'sending' // unconfirmed
        });
      });
      _saveMessages();
      _scrollToBottom();
      _controller.clear();

      // Emit with Ack
      socket.emitWithAck('chat message', text, ack: (data) {
        print('Ack received: $data');
        setState(() {
          // Find the message by tempId and update status
          // Need to handle if messages are loaded from JSON (Map) or added strictly (Map)
          final index = messages.indexWhere((m) => m is Map && m['id'] == tempId);
          if (index != -1) {
             messages[index]['status'] = 'sent';
          }
        });
        _saveMessages();
      });
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    socket.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat App'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(isConnected ? Icons.cloud_done : Icons.cloud_off, 
              color: isConnected ? Colors.green : Colors.red),
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[index];
                final text = message['text'] ?? message.toString();
                final isMe = message['senderId'] == socket.id;
                final status = message['status'] ?? 'sent'; 
                
                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isMe ? Colors.blue[100] : Colors.grey[300],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(text),
                        if (isMe) ...[
                          const SizedBox(height: 4),
                          Icon(
                            status == 'sending' ? Icons.access_time : Icons.done, 
                            size: 12, 
                            color: Colors.grey[600]
                          )
                        ]
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: Theme.of(context).primaryColor,
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
