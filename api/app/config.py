from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── Database ──────────────────────────────────────────────────────────────
    POSTGRES_HOST: str = "postgres"
    POSTGRES_PORT: int = 5432
    POSTGRES_DB: str = "beauty_app"
    APP_DB_USER: str = "app_service_user"
    APP_DB_PASS: str = "App_S3rvice_P@ss!"

    # ── JWT ───────────────────────────────────────────────────────────────────
    JWT_SECRET: str = "change-this-in-production-use-a-long-random-string"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_MINUTES: int = 480  # 8 hours


@lru_cache
def get_settings() -> Settings:
    return Settings()
