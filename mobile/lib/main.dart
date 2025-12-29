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
  // LIVE SERVER URL:
  static const String serverUrl = 'https://chat-backend-1-w4pk.onrender.com'; 
  
  late IO.Socket socket;
  String? userId;
  List<dynamic> messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool isConnected = false;

  @override
  void initState() {
    super.initState();
    _initUserAndData();
  }

  Future<void> _initUserAndData() async {
    await _loadUser();
    await _loadLocalMessages();
    _fetchHistory();
    _connectSocket();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    String? storedId = prefs.getString('user_id');
    if (storedId == null) {
      storedId = 'user_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString('user_id', storedId);
    }
    setState(() {
      userId = storedId;
    });
  }

  Future<void> _loadLocalMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final String? storedMessages = prefs.getString('chat_messages');
    if (storedMessages != null) {
      setState(() {
        final decoded = json.decode(storedMessages) as List<dynamic>;
        // Migrate old string messages to map format
        messages = decoded.map((m) {
          if (m is Map) return Map<String, dynamic>.from(m);
          return {'text': m.toString(), 'senderId': 'unknown', 'status': 'sent'};
        }).toList();
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
          // Merge strategy: Use a Set of IDs or Timestamps to avoid duplicates
          // For now, let's just combine and deduplicate by text and timestamp if available,
          // or just replace if messages were empty.
          // Better: Only add messages that aren't already there.
          for (var serverMsg in serverMessages) {
            if (serverMsg is! Map) continue;
            // Use unique ID for deduplication
            final String? sId = serverMsg['id']?.toString() ?? serverMsg['_id']?.toString();
            bool exists = messages.any((m) => 
              m is Map && (
                (sId != null && (m['id']?.toString() == sId || m['_id']?.toString() == sId)) ||
                (m['text'] == serverMsg['text'] && m['timestamp'] == serverMsg['timestamp'])
              )
            );
            if (!exists) {
              messages.add(Map<String, dynamic>.from(serverMsg));
            }
          }
          // Sort by timestamp if available
          messages.sort((a, b) {
            if (a is! Map || b is! Map) return 0;
            var tA = a['timestamp']?.toString() ?? '';
            var tB = b['timestamp']?.toString() ?? '';
            return tA.compareTo(tB);
          });
        });
        _saveMessages(); 
        _scrollToBottom();
      }
    } catch (e) {
      print('Error fetching history: $e');
    }
  }

  void _connectSocket() {
    socket = IO.io(serverUrl, IO.OptionBuilder()
        .setTransports(['websocket', 'polling']) // Enable polling as fallback
        .enableAutoConnect()
        .enableReconnection() // Ensure reconnection is on
        .build());
    
    socket.connect();

    socket.onConnect((_) {
      print('Connected to socket: ${socket.id}');
      setState(() {
        isConnected = true;
      });
    });

    socket.on('connect_error', (data) {
      print('Connect Error: $data');
      setState(() {
        isConnected = false;
      });
    });

    socket.on('connect_timeout', (data) {
      print('Connect Timeout: $data');
      setState(() {
        isConnected = false;
      });
    });

    socket.on('error', (data) {
      print('Socket Error: $data');
    });

    socket.on('chat message', (data) {
      print('Received message: $data');
      
      dynamic parsedData;
      if (data is Map) {
        parsedData = data;
      } else if (data is String) {
        if (data.trim().startsWith('{')) {
          try {
            parsedData = json.decode(data);
          } catch (_) {
            parsedData = data;
          }
        } else {
          parsedData = data;
        }
      } else {
        parsedData = data;
      }

      setState(() {
        if (parsedData is Map) {
          // Check if this is my own message coming back
          // Use string comparison to be safe
          final String? msgSenderId = parsedData['senderId']?.toString();
          if (msgSenderId != null && userId != null && msgSenderId == userId) {
            return;
          }
          messages.add(Map<String, dynamic>.from(parsedData));
        } else {
          // If it's a string, try one more time to see if it's a Dart Map string
          String raw = parsedData.toString();
          if (raw.contains('senderId:') && raw.contains(userId ?? '')) {
             return; // Skip my own message even if it arrived as a string
          }
          messages.add({
            'text': raw,
            'senderId': 'unknown',
            'status': 'sent',
            'timestamp': DateTime.now().toIso8601String(),
          });
        }
      });
      _saveMessages();
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
      if (!isConnected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wait for connection...')),
        );
        return;
      }
      final text = _controller.text;
      
      // Temporary ID for the message to update status later
      final tempId = DateTime.now().millisecondsSinceEpoch.toString();

      setState(() {
        messages.add({
          'id': tempId,
          'text': text, 
          'senderId': userId, // Use persistent userId
          'status': 'sending' 
        });
      });
      _saveMessages();
      _scrollToBottom();
      _controller.clear();

      // Emit with Ack
      // Send the userId along with the message
      socket.emitWithAck('chat message', {
        'text': text,
        'senderId': userId,
      }, ack: (data) {
        print('Ack received: $data');
        setState(() {
          // Find the message by tempId and update status
          // Need to handle if messages are loaded from JSON (Map) or added strictly (Map)
          final index = messages.indexWhere((m) => m is Map && m['id'] == tempId);
          if (index != -1) {
             final updatedMsg = Map<String, dynamic>.from(messages[index]);
             updatedMsg['status'] = 'sent';
             messages[index] = updatedMsg;
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
        title: Row(
          children: [
            Image.asset(
              'assets/logo.jpg',
              height: 32,
              errorBuilder: (context, error, stackTrace) => const Icon(Icons.chat),
            ),
            const SizedBox(width: 10),
            const Text('Chat App'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(isConnected ? Icons.cloud_done : Icons.cloud_off, 
              color: isConnected ? Colors.green : Colors.red),
          )
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  String text = '';
                  String? msgSenderId;
                  String status = 'sent';

                  // Helper function to extract text and sender from common formats
                  void parseMessage(dynamic msg) {
                    if (msg == null) return;
                    
                    if (msg is Map) {
                      text = (msg['text'] ?? msg['message'] ?? text).toString();
                      msgSenderId = msg['senderId']?.toString() ?? msgSenderId;
                      status = msg['status']?.toString() ?? status;
                      
                      // Check if the extracted text itself is a JSON string
                      if (text.trim().startsWith('{')) {
                        try {
                          final decoded = json.decode(text);
                          if (decoded is Map) {
                            text = (decoded['text'] ?? decoded['message'] ?? text).toString();
                            msgSenderId = decoded['senderId']?.toString() ?? msgSenderId;
                          }
                        } catch (_) {}
                      }
                    } else {
                      String rawStr = msg.toString().trim();
                      if (rawStr.startsWith('{') && rawStr.endsWith('}')) {
                        try {
                          final decoded = json.decode(rawStr);
                          parseMessage(decoded);
                        } catch (_) {
                          // Handle Dart Map string format: {text: hi, senderId: user_...}
                          String content = rawStr.substring(1, rawStr.length - 1);
                          List<String> parts = content.split(',');
                          for (var part in parts) {
                            if (part.contains(':')) {
                              List<String> kv = part.split(':');
                              if (kv.length >= 2) {
                                String key = kv[0].trim();
                                String value = kv.sublist(1).join(':').trim();
                                if (key == 'text' || key == 'message') text = value;
                                if (key == 'senderId') msgSenderId = value;
                              }
                            }
                          }
                        }
                      } else {
                        text = rawStr;
                      }
                    }
                  }

                  parseMessage(message);
                  
                  // Final fallbacks
                  if (text.isEmpty && message is Map && (message.containsKey('id') || message.containsKey('_id'))) {
                    text = "..."; // Avoid empty bubble
                  }
                  
                  final isMe = msgSenderId == userId;                  
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
      ),
    );
  }
}
