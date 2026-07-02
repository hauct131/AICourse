# OpenRouter Gemini Playground & FastAPI Backend

A modern, containerized FastAPI web application integrating Google Gemini's models via the OpenRouter API. It provides ready-to-use `/health` and `/chat` endpoints, coupled with a premium, sleek Single Page Application (SPA) chat interface built with glassmorphism design and code syntax highlighting.

---

## Features

- ⚡ **FastAPI Backend**: Fully async, lightweight endpoints with structured Request/Response validations using Pydantic.
- 🔗 **OpenRouter Integration**: Uses `httpx` async client to interact with OpenRouter's OpenAI-compatible completions API.
- 🎨 **Premium UI Playground**: Responsive, interactive, dark-themed Chat interface built with vanilla HTML/CSS/JS (including markdown parsing & code syntax highlighting).
- 🔑 **Dynamic Key Override**: Support for providing your OpenRouter API key dynamically via the HTTP Header `X-OpenRouter-API-Key`. Great for testing or sharing without hardcoding sensitive credentials.
- 🐳 **Dockerized Setup**: Ready-to-go `Dockerfile` and `docker-compose.yml` with health check support.

---

## Project Structure

```text
Lab1/
├── app/
│   ├── __init__.py
│   ├── main.py            # FastAPI Application & Routes
│   └── static/
│       └── index.html     # Single Page App Chat Playground
├── Dockerfile             # Multi-stage/lightweight container setup
├── docker-compose.yml     # Compose configuration with healthchecks
├── requirements.txt       # Python dependencies
├── .env                   # Local environment variables
└── .env.example           # Environment template
```

---

## Quick Start

### 1. Get an OpenRouter API Key
Visit [OpenRouter](https://openrouter.ai/) and create an API key.

### 2. Configure Environment
Rename or copy `.env.example` to `.env` and fill in your OpenRouter API Key:
```bash
cp .env.example .env
```
Inside `.env`:
```env
OPENROUTER_API_KEY=your_actual_api_key_here
GEMINI_MODEL=openai/gpt-oss-120b:free
```

### 3. Run with Docker Compose (Recommended)
Build and spin up the container:
```bash
docker-compose up --build -d
```
(Note: Use `docker compose` instead if you are using the newer Docker CLI integration).

The server will start at **`http://localhost:8000`**. You can visit the URL in your browser to access the interactive Chat Playground!

### 4. Run Locally (Without Docker)
Ensure you have Python 3.11+ installed.

1. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```
2. **Start the development server**:
   ```bash
   uvicorn app.main:app --reload --port 8000
   ```
3. Open your browser and navigate to `http://127.0.0.1:8000` or `http://127.0.0.1:8000/docs` (Swagger UI).

---

## API Documentation

### 1. Health Check
Checks if the service is running and verifies if the OpenRouter API Key is configured.

- **URL**: `/health`
- **Method**: `GET`
- **Optional Header**: `X-OpenRouter-API-Key: <api_key>` (if testing dynamic validation)
- **Response**:
  ```json
  {
    "status": "healthy",
    "timestamp": 1690554902.1245,
    "server_key_configured": true,
    "default_model": "openai/gpt-oss-120b:free",
    "details": "API is running. Server-side OPENROUTER_API_KEY environment variable is configured."
  }
  ```

### 2. Chat Endpoint
Interacts with the Gemini models via OpenRouter. Supports conversational history and system instructions.

- **URL**: `/chat`
- **Method**: `POST`
- **Headers**:
  - `Content-Type: application/json`
  - `X-OpenRouter-API-Key: <api_key>` *(Optional. Overrides the server-side environment key)*
- **Request Body**:
  ```json
  {
    "message": "Write a python function to check if a number is prime.",
    "history": [
      {
        "role": "user",
        "content": "Hello!"
      },
      {
        "role": "assistant",
        "content": "Hi there! How can I help you today?"
      }
    ],
    "system_instruction": "You are a professional software engineer who writes clean, commented code.",
    "model": "openai/gpt-oss-120b:free"
  }
  ```
- **Response Body**:
  ```json
  {
    "response": "Here is a Python function to check if a number is prime:\n\n```python\ndef is_prime(n):\n    if n <= 1:\n        return False\n    for i in range(2, int(n**0.5) + 1):\n        if n % i == 0:\n            return False\n    return True\n```",
    "model": "openai/gpt-oss-120b:free",
    "usage": {
      "prompt_token_count": 35,
      "candidates_token_count": 68,
      "total_token_count": 103
    }
  }
  ```

---

## Free Tier Models
OpenRouter offers zero-cost tier access to various models:
- **`openai/gpt-oss-120b:free`** (Highly capable open-weight Mixture of Experts model)
- **`google/gemini-2.5-flash:free`** (Highly optimized for fast, responsive text generation)
# AICourse
