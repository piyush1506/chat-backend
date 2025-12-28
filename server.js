const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
    cors: {
        origin: "*",
        methods: ["GET", "POST"]
    }
});

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// MongoDB connection
const mongoUri = process.env.MONGO_URI;
if (!mongoUri) {
    console.warn('⚠️ MONGO_URI not set. MongoDB features will be disabled.');
} else {
    mongoose.connect(mongoUri, {
        useNewUrlParser: true,
        useUnifiedTopology: true
    })
        .then(() => console.log('✅ Connected to MongoDB'))
        .catch(err => {
            console.error('❌ MongoDB connection error:', err);
        });
}

// Message Schema
const messageSchema = new mongoose.Schema({
    text: String,
    senderId: String,
    timestamp: { type: Date, default: Date.now }
});

const Message = mongoose.model('Message', messageSchema);

// Routes
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.get('/api/messages', async (req, res) => {
    if (mongoose.connection.readyState === 1) {
        try {
            const messages = await Message.find().sort({ timestamp: 1 });
            res.json(messages);
        } catch (err) {
            res.status(500).json({ error: 'Failed to fetch messages' });
        }
    } else {
        res.json([
            { text: 'MongoDB not connected', senderId: 'System' }
        ]);
    }
});

// Socket.IO
io.on('connection', (socket) => {
    console.log('User connected:', socket.id);

    socket.on('chat message', async (msg, callback) => {
        const messageData = {
            text: msg,
            senderId: socket.id,
            timestamp: new Date()
        };

        // Save to DB
        if (mongoose.connection.readyState === 1) {
            const newMessage = new Message(messageData);
            await newMessage.save();
        }

        // Broadcast object instead of just string
        io.emit('chat message', messageData);

        // Acknowledge receipt if callback is provided
        if (callback && typeof callback === 'function') {
            callback({ status: 'ok' });
        }
    });

    socket.on('disconnect', () => {
        console.log('User disconnected:', socket.id);
    });
});

// Start server
const PORT = process.env.PORT || 8000;
server.listen(PORT, () => console.log(`Server running on port ${PORT}`));
