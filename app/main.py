"""Skybyte greeting service."""
import logging
import os
import signal
import sys

from flask import Flask, jsonify

app = Flask(__name__)
log = logging.getLogger(__name__)

VERSION = "1.0.0"
API_TOKEN = os.environ.get("API_TOKEN", "")

@app.route("/")
def hello():
    return jsonify({"message": "Hello, Candidate", "version": VERSION})


@app.route("/healthz")
def healthz():
    # TODO: actually check something useful
    return "ok", 200

def _handle_sigterm(*_args):
    """Log the SIGTERM and exit cleanly so gunicorn can finish draining."""
    log.info("SIGTERM received – initiating graceful shutdown")
    sys.exit(0)


signal.signal(signal.SIGTERM, _handle_sigterm)
if __name__ == "__main__":
    # Production containers must be started with gunicorn (see below).
    # This block is kept only for quick local iteration.
    app.run(host="0.0.0.0", port=80, debug=False)