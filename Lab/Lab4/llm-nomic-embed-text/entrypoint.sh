#!/bin/bash
set -e

echo "Starting Ollama server with pre-pulled model..."
exec ollama serve
