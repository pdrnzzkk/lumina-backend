"""Cliente Supabase (lazy). Ainda não usado por nenhuma rota."""
from functools import lru_cache

from supabase import Client, create_client

from app.core.config import get_settings


@lru_cache
def get_supabase() -> Client:
    s = get_settings()
    if not s.supabase_url or not s.supabase_service_role_key:
        raise RuntimeError("Configure SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY no .env")
    return create_client(s.supabase_url, s.supabase_service_role_key)
