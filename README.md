# Lumina — Backend (FastAPI)

API do Lumina, SaaS de banco de questões para vestibulares.
Stack: FastAPI · Supabase (PostgreSQL + Auth + RLS) · Claude (Anthropic).

## Estrutura

```
app/
  main.py        # criação do app, CORS, routers
  core/          # config (.env), cliente Supabase
  routers/       # endpoints (health por enquanto)
  schemas/       # modelos Pydantic (entrada/saída da API)
  models/        # representações do domínio/tabelas
  services/      # regras de negócio e integrações (Claude, Supabase)
tests/
```

## Rodando localmente

Requisitos: Python 3.11+.

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

cp .env.example .env             # preencha as chaves
uvicorn app.main:app --reload
```

- API: http://localhost:8000
- Health check: http://localhost:8000/health
- Docs (Swagger): http://localhost:8000/docs

## Testes

```bash
pytest
```

## Variáveis de ambiente

| Variável | Descrição |
|---|---|
| `SUPABASE_URL` | URL do projeto Supabase |
| `SUPABASE_ANON_KEY` | Chave pública (anon) |
| `SUPABASE_SERVICE_ROLE_KEY` | Chave de serviço — **só no backend** |
| `ANTHROPIC_API_KEY` | Chave da API do Claude |
| `CORS_ORIGINS` | Origens permitidas, separadas por vírgula |

> Segurança: nunca commite o `.env` nem exponha a `service_role` no app Flutter.
