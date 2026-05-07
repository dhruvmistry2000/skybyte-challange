"""Skybyte greeting service."""
import logging
import os
import signal
import sys
import time

from flask import Flask, Response, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = Flask(__name__)
log = logging.getLogger(__name__)

VERSION = "1.0.0"
API_TOKEN = os.environ.get("API_TOKEN", "")

# Label `path` is the matched route rule, not the raw URL, so unknown/dynamic
# paths cannot blow up label cardinality in Prometheus.
http_requests_total = Counter(
    "http_requests_total",
    "Total HTTP requests processed, labeled by method, path, and status.",
    ["method", "path", "status"],
)
http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds, labeled by method and path.",
    ["method", "path"],
)


@app.before_request
def _start_timer():
    request._start_time = time.perf_counter()


@app.after_request
def _record_request_metrics(response):
    if request.path == "/metrics":
        return response
    path = request.url_rule.rule if request.url_rule else "<unmatched>"
    elapsed = time.perf_counter() - getattr(request, "_start_time", time.perf_counter())
    http_request_duration_seconds.labels(request.method, path).observe(elapsed)
    http_requests_total.labels(request.method, path, str(response.status_code)).inc()
    return response


@app.route("/")
def hello():
    return jsonify({"message": "Hello, Candidate", "version": VERSION})


@app.route("/healthz")
def healthz():
    # TODO: actually check something useful
    return "ok", 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), content_type=CONTENT_TYPE_LATEST)


def _handle_sigterm(*_args):
    """Log the SIGTERM and exit cleanly so gunicorn can finish draining."""
    log.info("SIGTERM received – initiating graceful shutdown")
    sys.exit(0)


signal.signal(signal.SIGTERM, _handle_sigterm)
if __name__ == "__main__":
    # Production containers must be started with gunicorn (see below).
    # This block is kept only for quick local iteration.
    app.run(host="0.0.0.0", port=80, debug=False)
