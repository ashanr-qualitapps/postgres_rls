from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import init_pool, close_pool
from app.routers import auth, branches, services, appointments, products, orders, users


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    yield
    await close_pool()


app = FastAPI(
    title="Beauty App API",
    description=(
        "Multi-tenant beauty salon management API.\n\n"
        "All endpoints (except /auth) require a JWT Bearer token obtained from `POST /auth/login`.\n\n"
        "Row Level Security (RLS) is enforced at the PostgreSQL layer – "
        "customers see only their own data, staff see their branch, admins see everything."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],          # Restrict to your frontend domain in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(branches.router)
app.include_router(services.router)
app.include_router(appointments.router)
app.include_router(products.router)
app.include_router(orders.router)
app.include_router(users.router)


@app.get("/health", tags=["health"])
async def health_check():
    return {"status": "ok"}
