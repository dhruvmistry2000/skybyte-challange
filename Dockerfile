FROM python:3.9.23-slim

WORKDIR /app

COPY app/requirements.txt .

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

RUN addgroup --system --gid 10001 app && \
    adduser --system --uid 10001 --ingroup app app && \
    chown -R 10001:10001 /app

USER 10001:10001

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "main:app"]