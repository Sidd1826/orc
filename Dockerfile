FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install deps first for better layer caching.
COPY requirements.txt .
RUN pip install -r requirements.txt

# App code
COPY *.py ./

# Cloud Run sets $PORT — default 8000 for local docker runs.
ENV PORT=8000
EXPOSE 8000

# Run as non-root.
RUN useradd --create-home --shell /bin/bash appuser
USER appuser

CMD exec uvicorn main:app --host 0.0.0.0 --port ${PORT} --workers 1
