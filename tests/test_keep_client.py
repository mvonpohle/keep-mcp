from server import keep_api


class DummyKeep:
    def __init__(self):
        self.auth_calls = []

    def authenticate(self, email, token):
        self.auth_calls.append((email, token))


def _no_token_file(monkeypatch, tmp_path):
    """Point the token-file lookup at a path that cannot exist, so tests
    never touch a real secret file on the host."""
    missing = tmp_path / "no-such-token"
    monkeypatch.setattr(keep_api, "_master_token_file", lambda: str(missing))


def test_get_client_authenticates_and_caches(monkeypatch, tmp_path):
    keep_api._keep_client = None
    created = DummyKeep()

    _no_token_file(monkeypatch, tmp_path)
    monkeypatch.setattr(keep_api, "load_dotenv", lambda: None)
    monkeypatch.setattr(keep_api.os, "getenv", lambda key, *default: {
        "GOOGLE_EMAIL": "user@example.com",
        "GOOGLE_MASTER_TOKEN": "token",
    }.get(key))
    monkeypatch.setattr(keep_api.gkeepapi, "Keep", lambda: created)

    first = keep_api.get_client()
    second = keep_api.get_client()

    assert first is created
    assert second is created
    assert created.auth_calls == [("user@example.com", "token")]


def test_get_client_raises_when_missing_credentials(monkeypatch, tmp_path):
    keep_api._keep_client = None
    _no_token_file(monkeypatch, tmp_path)
    monkeypatch.setattr(keep_api, "load_dotenv", lambda: None)
    monkeypatch.setattr(keep_api.os, "getenv", lambda _key, *default: None)

    try:
        keep_api.get_client()
    except ValueError as exc:
        assert "Missing Google Keep credentials" in str(exc)
    else:
        raise AssertionError("Expected ValueError for missing credentials")


def test_get_client_prefers_token_file_over_env_var(monkeypatch, tmp_path):
    keep_api._keep_client = None
    created = DummyKeep()

    token_file = tmp_path / "google_master_token"
    token_file.write_text("token-from-file\n")

    monkeypatch.setattr(keep_api, "load_dotenv", lambda: None)
    monkeypatch.setenv("GOOGLE_EMAIL", "user@example.com")
    monkeypatch.setenv("GOOGLE_MASTER_TOKEN", "token-from-env")
    monkeypatch.setenv("GOOGLE_MASTER_TOKEN_FILE", str(token_file))
    monkeypatch.setattr(keep_api.gkeepapi, "Keep", lambda: created)

    keep_api.get_client()

    assert created.auth_calls == [("user@example.com", "token-from-file")]


def test_get_client_falls_back_to_env_var_when_token_file_missing(
    monkeypatch, tmp_path
):
    keep_api._keep_client = None
    created = DummyKeep()

    monkeypatch.setattr(keep_api, "load_dotenv", lambda: None)
    monkeypatch.setenv("GOOGLE_EMAIL", "user@example.com")
    monkeypatch.setenv("GOOGLE_MASTER_TOKEN", "token-from-env")
    monkeypatch.setenv("GOOGLE_MASTER_TOKEN_FILE", str(tmp_path / "does-not-exist"))
    monkeypatch.setattr(keep_api.gkeepapi, "Keep", lambda: created)

    keep_api.get_client()

    assert created.auth_calls == [("user@example.com", "token-from-env")]


def test_get_client_falls_back_to_env_var_when_token_file_empty(
    monkeypatch, tmp_path
):
    keep_api._keep_client = None
    created = DummyKeep()

    token_file = tmp_path / "google_master_token"
    token_file.write_text("  \n")

    monkeypatch.setattr(keep_api, "load_dotenv", lambda: None)
    monkeypatch.setenv("GOOGLE_EMAIL", "user@example.com")
    monkeypatch.setenv("GOOGLE_MASTER_TOKEN", "token-from-env")
    monkeypatch.setenv("GOOGLE_MASTER_TOKEN_FILE", str(token_file))
    monkeypatch.setattr(keep_api.gkeepapi, "Keep", lambda: created)

    keep_api.get_client()

    assert created.auth_calls == [("user@example.com", "token-from-env")]


def test_master_token_file_defaults_to_docker_secret_path(monkeypatch):
    monkeypatch.delenv("GOOGLE_MASTER_TOKEN_FILE", raising=False)

    assert keep_api._master_token_file() == "/run/secrets/google_master_token"
