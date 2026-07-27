FROM ollama/ollama:latest

# Pull the model at BUILD time so it is baked into the image (no runtime pull).
RUN ollama serve & sp=$! && \
    until ollama list >/dev/null 2>&1; do sleep 1; done && \
    ollama pull llama3.1:8b && \
    kill $sp

# entrypoint.sh lives in THIS model's folder (build context = ./llm-llama-3-8b)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
