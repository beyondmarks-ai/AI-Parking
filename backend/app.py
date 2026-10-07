import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import asyncpg
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

DATABASE_URL = os.environ['DATABASE_URL']
SCHEMA = (Path(__file__).parent / 'schema.sql').read_text(encoding='utf-8')


class CameraInput(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    location: str = Field(min_length=2, max_length=200)
    rtsp_url: str = Field(pattern=r'^rtsps?://')


class ReviewInput(BaseModel):
    status: Literal['review', 'resolved', 'dismissed']
    fine_amount: float = Field(ge=0, default=0)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db = await asyncpg.create_pool(DATABASE_URL, min_size=1, max_size=8)
    async with app.state.db.acquire() as connection:
        await connection.execute('create extension if not exists pgcrypto;')
        await connection.execute(SCHEMA)
    yield
    await app.state.db.close()


app = FastAPI(title='ParkGuard AI API', version='1.0.0', lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=os.getenv('CORS_ORIGINS', '*').split(','), allow_credentials=False, allow_methods=['*'], allow_headers=['*'])


@app.get('/health')
async def health():
    async with app.state.db.acquire() as connection:
        await connection.fetchval('select 1')
    return {'status': 'healthy'}


@app.get('/api/v1/dashboard')
async def dashboard():
    async with app.state.db.acquire() as connection:
        cameras = await connection.fetchval('select count(*) from cameras where enabled')
        today = await connection.fetchval("select count(*) from violations where occurred_at >= date_trunc('day', now())")
        recent = await connection.fetch('select id, plate_number, violation_type, occurred_at, status from violations order by occurred_at desc limit 5')
    return {'live_cameras': cameras, 'violations_today': today, 'recent_violations': [dict(row) for row in recent]}


@app.get('/api/v1/cameras')
async def list_cameras():
    async with app.state.db.acquire() as connection:
        rows = await connection.fetch('select id, name, location, enabled, created_at from cameras order by created_at desc')
    return [dict(row) for row in rows]


@app.post('/api/v1/cameras', status_code=201)
async def add_camera(camera: CameraInput):
    async with app.state.db.acquire() as connection:
        row = await connection.fetchrow('insert into cameras(name, location, rtsp_url) values($1,$2,$3) returning id,name,location,enabled,created_at', camera.name, camera.location, camera.rtsp_url)
    return dict(row)


@app.get('/api/v1/violations')
async def list_violations(query: str = '', status: str = ''):
    sql = '''select v.id, v.plate_number, v.plate_confidence, v.violation_type, v.occurred_at, v.evidence_url, v.status, v.fine_amount, c.name as camera_name
             from violations v left join cameras c on c.id=v.camera_id
             where ($1='' or coalesce(v.plate_number,'') ilike '%' || $1 || '%') and ($2='' or v.status=$2)
             order by v.occurred_at desc limit 200'''
    async with app.state.db.acquire() as connection:
        rows = await connection.fetch(sql, query, status)
    return [dict(row) for row in rows]


@app.post('/api/v1/violations/{violation_id}/review')
async def review_violation(violation_id: str, review: ReviewInput):
    async with app.state.db.acquire() as connection:
        row = await connection.fetchrow('update violations set status=$1, fine_amount=$2 where id=$3::uuid returning id,status,fine_amount', review.status, review.fine_amount, violation_id)
    if row is None:
        raise HTTPException(status_code=404, detail='Violation not found')
    return dict(row)
