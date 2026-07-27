FROM ollama/ollama:latest

# Pull the embedding model at BUILD time (baked into the image).
RUN ollama serve & sp=$! && \
    until ollama list >/dev/null 2>&1; do sleep 1; done && \
    ollama pull nomic-embed-text && \
    kill $sp

# entrypoint.sh lives in THIS model's folder (build context = ./llm-nomic-embed-text)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
