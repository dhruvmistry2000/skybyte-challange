FROM python:3.9.23-slim

WORKDIR /app

# Patch OS packages (OpenSSL, etc.) so `trivy image` passes HIGH/CRITICAL gates in CI.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# setuptools/wheel ship with the slim image at vulnerable versions; bump before app deps.
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

RUN addgroup --system --gid 10001 app && \
    adduser --system --uid 10001 --ingroup app app && \
    chown -R 10001:10001 /app

USER 10001:10001

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "main:app"]