import os
import time
from typing import List, Optional
from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
import httpx
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

OPENROUTER_API_URL = "https://openrouter.ai/api/v1/chat/completions"

app = FastAPI(
    title="OpenRouter Chat API",
    description="FastAPI service integrated with OpenRouter API calling Google Gemini free tier",
    version="1.0.0"
)

# Enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Pydantic Schemas
class ChatMessage(BaseModel):
    role: str = Field(..., description="Role: 'user', 'assistant' / 'model'")
    content: str = Field(..., description="Content of the message")

class ChatRequest(BaseModel):
    message: str = Field(..., description="The current message to send")
    history: Optional[List[ChatMessage]] = Field(None, description="Optional chat history")
    system_instruction: Optional[str] = Field(None, description="Optional system instruction/prompt")
    model: Optional[str] = Field(None, description="OpenRouter model ID override")

class ChatResponse(BaseModel):
    response: str
    model: str
    usage: Optional[dict] = None

# Helper to retrieve OpenRouter API key from headers or server environment
def get_openrouter_api_key(x_openrouter_api_key: Optional[str] = Header(None, alias="X-OpenRouter-API-Key")):
    api_key = x_openrouter_api_key or os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=401,
            detail="OpenRouter API Key is missing. Provide it via the 'X-OpenRouter-API-Key' header or set OPENROUTER_API_KEY in the server environment."
        )
    return api_key

@app.get("/health")
def health_check(x_openrouter_api_key: Optional[str] = Header(None, alias="X-OpenRouter-API-Key")):
    """
    Health check endpoint to verify API operational status and OpenRouter key configuration.
    """
    env_key_configured = bool(os.getenv("OPENROUTER_API_KEY"))
    header_key_configured = bool(x_openrouter_api_key)
    
    status = "healthy" if (env_key_configured or header_key_configured) else "degraded"
    
    if env_key_configured:
        details = "API is running. Server-side OPENROUTER_API_KEY environment variable is configured."
    elif header_key_configured:
        details = "API is running. API Key provided via request header."
    else:
        details = "API is running but OPENROUTER_API_KEY is not configured (neither env variable nor request header)."

    return {
        "status": status,
        "timestamp": time.time(),
        "server_key_configured": env_key_configured,
        "default_model": os.getenv("GEMINI_MODEL", "openai/gpt-oss-120b:free"),
        "details": details
    }

@app.post("/chat", response_model=ChatResponse)
async def chat(
    request: ChatRequest,
    api_key: str = Depends(get_openrouter_api_key)
):
    """
    Chat endpoint to interact with Google Gemini models via OpenRouter.
    """
    # Decide model (from request -> env variable -> default free tier)
    selected_model = request.model or os.getenv("GEMINI_MODEL", "openai/gpt-oss-120b:free")
    
    messages = []
    
    # 1. Prepend System Instruction if provided
    if request.system_instruction:
        messages.append({
            "role": "system",
            "content": request.system_instruction
        })
        
    # 2. Add history
    if request.history:
        for msg in request.history:
            # Map role: 'model' or 'assistant' is mapped to 'assistant' for OpenAI compatibility
            role = "user" if msg.role.lower() == "user" else "assistant"
            messages.append({
                "role": role,
                "content": msg.content
            })
            
    # 3. Add current message
    messages.append({
        "role": "user",
        "content": request.message
    })

    # Prepare OpenRouter request
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "http://localhost:8000",
        "X-Title": "FastAPI Gemini Playground"
    }
    
    payload = {
        "model": selected_model,
        "messages": messages
    }

    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(
                OPENROUTER_API_URL,
                headers=headers,
                json=payload
            )
            
            # Raise exception if status is not 2xx
            if response.status_code != 200:
                error_detail = response.text
                try:
                    error_json = response.json()
                    if "error" in error_json:
                        error_detail = error_json["error"].get("message", error_detail)
                except Exception:
                    pass
                raise HTTPException(
                    status_code=response.status_code,
                    detail=f"OpenRouter API Error: {error_detail}"
                )
                
            response_data = response.json()
            
            # Parse chat response
            choices = response_data.get("choices", [])
            if not choices:
                raise HTTPException(
                    status_code=502,
                    detail="Invalid response format received from OpenRouter API."
                )
                
            assistant_message = choices[0].get("message", {}).get("content", "")
            returned_model = response_data.get("model", selected_model)
            
            # Map usage metrics
            usage_data = response_data.get("usage", {})
            usage_metadata = {
                "prompt_token_count": usage_data.get("prompt_tokens", 0),
                "candidates_token_count": usage_data.get("completion_tokens", 0),
                "total_token_count": usage_data.get("total_tokens", 0)
            }

            return ChatResponse(
                response=assistant_message,
                model=returned_model,
                usage=usage_metadata
            )
            
    except httpx.RequestError as e:
        raise HTTPException(
            status_code=503,
            detail=f"Network error trying to connect to OpenRouter: {str(e)}"
        )
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(
            status_code=500,
            detail=f"An unexpected error occurred: {str(e)}"
        )

# Serve static files for the UI
try:
    app.mount("/static", StaticFiles(directory="app/static"), name="static")
except Exception:
    pass

@app.get("/")
def read_root():
    """
    Serve the chat playground interface.
    """
    static_index = "app/static/index.html"
    if os.path.exists(static_index):
        return FileResponse(static_index)
    return {
        "message": "Welcome to OpenRouter Gemini API. Frontend UI is not yet created.",
        "docs_url": "/docs",
        "endpoints": {
            "health": "/health",
            "chat": "/chat"
        }
    }
