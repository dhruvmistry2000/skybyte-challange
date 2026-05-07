"""Minimal tests for the greeting service."""
from prometheus_client import CONTENT_TYPE_LATEST

from app.main import app


def test_hello():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json["message"] == "Hello, Candidate"


def test_healthz():
    client = app.test_client()
    resp = client.get("/healthz")
    assert resp.status_code == 200


def test_metrics_endpoint_exposed():
    client = app.test_client()
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["Content-Type"] == CONTENT_TYPE_LATEST


def test_metrics_counts_requests():
    client = app.test_client()
    client.get("/")
    body = client.get("/metrics").get_data(as_text=True)
    assert "# TYPE http_requests_total counter" in body
    assert 'http_requests_total{method="GET",path="/",status="200"}' in body


def test_metrics_records_duration_histogram():
    client = app.test_client()
    client.get("/healthz")
    body = client.get("/metrics").get_data(as_text=True)
    assert "# TYPE http_request_duration_seconds histogram" in body
    assert 'http_request_duration_seconds_bucket{' in body
    assert 'http_request_duration_seconds_count{method="GET",path="/healthz"}' in body


def test_metrics_endpoint_not_self_counted():
    client = app.test_client()
    body = client.get("/metrics").get_data(as_text=True)
    assert 'path="/metrics"' not in body
