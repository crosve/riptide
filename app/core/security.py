"""API-key generation and constant-time verification.

Keys look like ``rpt_<prefix>_<secret>``. Only the prefix (for lookup) and a
keyed hash of the secret are ever stored; the full key is shown to the caller
exactly once at creation time.
"""

import hashlib
import hmac
import secrets

from app.core.config import API_KEY_PEPPER

_PREFIX_BYTES = 6   # -> 12 hex chars, the public lookup handle
_SECRET_BYTES = 24  # -> ~32 url-safe chars of entropy


def hash_secret(secret: str) -> str:
    """Keyed (peppered) SHA-256 of the secret, hex-encoded."""
    return hmac.new(API_KEY_PEPPER.encode(), secret.encode(), hashlib.sha256).hexdigest()


def generate_api_key() -> tuple[str, str, str]:
    """Return (full_key, key_prefix, key_hash). Persist only prefix + hash."""
    prefix = secrets.token_hex(_PREFIX_BYTES)
    secret = secrets.token_urlsafe(_SECRET_BYTES)
    full_key = f"rpt_{prefix}_{secret}"
    return full_key, prefix, hash_secret(secret)


def parse_api_key(full_key: str) -> tuple[str, str] | None:
    """Split ``rpt_<prefix>_<secret>`` into (prefix, secret), or None if malformed."""
    parts = full_key.split("_", 2)
    if len(parts) != 3 or parts[0] != "rpt" or not parts[1] or not parts[2]:
        return None
    return parts[1], parts[2]


def verify_secret(secret: str, key_hash: str) -> bool:
    """Constant-time comparison of a presented secret against a stored hash."""
    return hmac.compare_digest(hash_secret(secret), key_hash)
