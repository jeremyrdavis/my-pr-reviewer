package com.example.registration;

final class Schema {

    static final String DDL = """
            CREATE TABLE IF NOT EXISTS users (
                id         BIGSERIAL PRIMARY KEY,
                email      TEXT NOT NULL UNIQUE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """;

    private Schema() {
    }
}
