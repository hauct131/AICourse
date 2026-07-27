"""Idempotent database migration runner for Lab 4."""
from __future__ import annotations

import hashlib
import logging
import os
from pathlib import Path

import psycopg

LOGGER = logging.getLogger(__name__)
SQL_FILE = Path(__file__).resolve().parent / "sql" / "init_rag_db.sql"
EMBEDDING_DIM = int(os.getenv("EMBEDDING_DIM", "768"))
DATABASE_URL = os.environ["DATABASE_URL"]


def run_migrations() -> None:
    sql = SQL_FILE.read_text(encoding="utf-8")
    sql = sql.replace("{{EMBEDDING_DIM}}", str(EMBEDDING_DIM))
    file_hash = hashlib.sha256(sql.encode("utf-8")).hexdigest()
    migration_name = SQL_FILE.name

    with psycopg.connect(DATABASE_URL) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    name TEXT PRIMARY KEY,
                    file_hash TEXT NOT NULL,
                    applied_at TIMESTAMP DEFAULT NOW()
                )
                """
            )
            cursor.execute(
                "SELECT file_hash FROM schema_migrations WHERE name = %s",
                (migration_name,),
            )
            row = cursor.fetchone()
            if row and row[0] == file_hash:
                LOGGER.info("Migration %s unchanged", migration_name)
                return

            LOGGER.info("Applying %s with embedding dimension %s", migration_name, EMBEDDING_DIM)
            cursor.execute(sql)
            cursor.execute(
                """
                INSERT INTO schema_migrations(name, file_hash)
                VALUES (%s, %s)
                ON CONFLICT(name) DO UPDATE
                SET file_hash = EXCLUDED.file_hash, applied_at = NOW()
                """,
                (migration_name, file_hash),
            )
        connection.commit()
