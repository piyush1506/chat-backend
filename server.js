const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');

const app = express();

// Middleware
app.use(cors());
app.use(express.json());

// MongoDB connection
mongoose.connect(process.env.MONGO_URI, {
    useNewUrlParser: true,
    useUnifiedTopology: true
})
.then(() => console.log('✅ Connected to MongoDB'))
.catch(err => console.log('❌ MongoDB connection error:', err));

// Example data (replace with your DB model later)
const messages = [
    { id: 1, text: 'Hello from Render!' },
    { id: 2, text: 'This is your /api/messages route.' }
];

// Routes
app.get('/', (req, res) => {
    res.json({ status: "Backend running on Render 🚀" });
});

app.get('/api/messages', (req, res) => {
    res.json(messages);
});

// Start server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
