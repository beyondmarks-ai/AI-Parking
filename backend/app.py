import os
import re
import asyncio
from contextlib import suppress
from contextlib import asynccontextmanager
from io import BytesIO
from pathlib import Path
from typing import Literal

import asyncpg
import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, Field
from foundry_ocr import router as foundry_router
from capture_archive import router as capture_router
from parking_analyzer import router as parking_router
from account_portal import router as account_router, current_user, require_admin
from push_notifications import initialize_push, push_worker

DATABASE_URL = os.environ['DATABASE_URL']
AZURE_VISION_ENDPOINT = os.getenv('AZURE_VISION_ENDPOINT', '').rstrip('/')
AZURE_VISION_KEY = os.getenv('AZURE_VISION_KEY', '')
MAX_OCR_IMAGE_BYTES = 4 * 1024 * 1024
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
        admin_email = os.getenv('BOOTSTRAP_ADMIN_EMAIL', '').strip().lower()
        admin_hash = os.getenv('BOOTSTRAP_ADMIN_HASH', '')
        if admin_email and admin_hash:
            await connection.execute('''insert into portal_users(name,email,password_hash,role)
                values('Administrator',$1,$2,'admin') on conflict(email) do nothing''', admin_email, admin_hash)
    push = initialize_push()
    worker = asyncio.create_task(push_worker(app.state.db, push)) if push else None
    try:
        yield
    finally:
        if worker:
            worker.cancel()
            with suppress(asyncio.CancelledError):
                await worker
        await app.state.db.close()


app = FastAPI(title='ParkGuard AI API', version='1.0.0', lifespan=lifespan)
app.include_router(foundry_router)
app.include_router(capture_router)
app.include_router(parking_router)
app.include_router(account_router)
app.add_middleware(CORSMiddleware, allow_origins=os.getenv('CORS_ORIGINS', '*').split(','), allow_credentials=False, allow_methods=['*'], allow_headers=['*'])


@app.middleware('http')
async def protect_api(request: Request, call_next):
    path = request.url.path
    try:
        if path.startswith('/api/v1/') and request.method != 'OPTIONS':
            if path in ('/api/v1/auth/signup', '/api/v1/auth/login'):
                if len(await request.body()) > 8192:
                    raise HTTPException(413, 'Account request too large')
            else:
                await current_user(request)
                if not path.startswith(('/api/v1/account', '/api/v1/auth/logout', '/api/v1/penalties', '/api/v1/push')):
                    await require_admin(request)
        response = await call_next(request)
        if path.startswith('/api/v1/'):
            response.headers['Cache-Control'] = 'no-store'
        return response
    except HTTPException as error:
        return JSONResponse({'detail': error.detail}, status_code=error.status_code, headers=error.headers)


def plate_candidates(lines: list[str]) -> list[str]:
    """Extract review candidates without guessing ambiguous characters."""
    pattern = re.compile(r'^(?:[A-Z]{2}\d{1,2}[A-Z]{1,3}\d{4}|\d{2}BH\d{4}[A-Z]{1,2})$')
    normalized = [line.upper().strip() for line in lines if line.strip()]
    matches: list[str] = []
    for index in range(len(normalized)):
        for count in (1, 2):
            value = ''.join(normalized[index:index + count])
            value = re.sub(r'[\s-]', '', value)
            if pattern.fullmatch(value) and value not in matches:
                matches.append(value)
    return matches


def find_red_restricted_zone(image_bytes: bytes) -> dict[str, float] | None:
    """Locate the largest connected red marking, independent of camera pose."""
    try:
        with Image.open(BytesIO(image_bytes)) as source:
            image = source.convert('RGB')
    except (UnidentifiedImageError, OSError):
        return None

    image.thumbnail((360, 360))
    width, height = image.size
    pixels = image.load()
    red = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            if r >= 90 and r - g >= 28 and r - b >= 22 and r >= g * 1.22:
                red[y * width + x] = 1

    visited = bytearray(width * height)
    components: list[tuple[int, int, int, int, int]] = []
    for start in range(width * height):
        if not red[start] or visited[start]:
            continue
        stack = [start]
        visited[start] = 1
        count = 0
        min_x = max_x = start % width
        min_y = max_y = start // width
        while stack:
            current = stack.pop()
            x, y = current % width, current // width
            count += 1
            min_x, max_x = min(min_x, x), max(max_x, x)
            min_y, max_y = min(min_y, y), max(max_y, y)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and 0 <= ny < height:
                        neighbor = ny * width + nx
                        if red[neighbor] and not visited[neighbor]:
                            visited[neighbor] = 1
                            stack.append(neighbor)
        box_width, box_height = max_x - min_x + 1, max_y - min_y + 1
        if (
            count < max(35, width * height // 5000)
            or (box_width < width * .08 and box_height < height * .08)
            # Ignore cables, LEDs, or furniture entering from a frame edge.
            or min_x <= width * .01
            or min_y <= height * .01
            or max_x >= width * .99
            or max_y >= height * .99
        ):
            continue
        candidate = (count, min_x, min_y, max_x, max_y)
        components.append(candidate)

    if not components:
        return None
    _, min_x, min_y, max_x, max_y = max(components, key=lambda item: item[0])
    # A parked vehicle can hide the diagonal that joins the stripes. Merge
    # nearby fragments so the inferred restricted rectangle does not shrink.
    changed = True
    merged: set[int] = set()
    while changed:
        changed = False
        for index, (_, other_left, other_top, other_right, other_bottom) in enumerate(components):
            if index in merged:
                continue
            gap_x = max(other_left - max_x, min_x - other_right, 0)
            gap_y = max(other_top - max_y, min_y - other_bottom, 0)
            if gap_x <= width * .12 and gap_y <= height * .12:
                min_x, min_y = min(min_x, other_left), min(min_y, other_top)
                max_x, max_y = max(max_x, other_right), max(max_y, other_bottom)
                merged.add(index)
                changed = True
    padding_x, padding_y = width * .015, height * .015
    return {
        'left': max(0.0, (min_x - padding_x) / width),
        'top': max(0.0, (min_y - padding_y) / height),
        'right': min(1.0, (max_x + padding_x) / width),
        'bottom': min(1.0, (max_y + padding_y) / height),
    }


def candidate_details(
    azure_lines: list[dict], red_zone: dict[str, float] | None, width: int, height: int
) -> list[dict]:
    texts = [line.get('text', '').upper().strip() for line in azure_lines]
    pattern = re.compile(r'^(?:[A-Z]{2}\d{1,2}[A-Z]{1,3}\d{4}|\d{2}BH\d{4}[A-Z]{1,2})$')
    details: list[dict] = []
    for index in range(len(texts)):
        for count in (1, 2):
            selected = azure_lines[index:index + count]
            value = re.sub(r'[\s-]', '', ''.join(texts[index:index + count]))
            if not pattern.fullmatch(value) or any(item['plate'] == value for item in details):
                continue
            points = [
                point
                for line in selected
                for point in line.get('boundingPolygon', [])
                if 'x' in point and 'y' in point
            ]
            center = None
            restricted = False
            if points and width > 0 and height > 0:
                center = {
                    'x': sum(point['x'] for point in points) / len(points) / width,
                    'y': sum(point['y'] for point in points) / len(points) / height,
                }
                if red_zone is not None:
                    restricted = (
                        red_zone['left'] <= center['x'] <= red_zone['right']
                        and red_zone['top'] <= center['y'] <= red_zone['bottom']
                    )
            details.append({'plate': value, 'center': center, 'restricted': restricted})
    return details


@app.get('/health')
async def health():
    async with app.state.db.acquire() as connection:
        await connection.fetchval('select 1')
    return {'status': 'healthy'}


@app.post('/api/v1/ocr/plate')
async def recognize_plate(request: Request):
    if not AZURE_VISION_ENDPOINT or not AZURE_VISION_KEY:
        raise HTTPException(status_code=503, detail='Azure Vision is not configured')

    content_type = request.headers.get('content-type', '').split(';', 1)[0].lower()
    if content_type not in {'image/jpeg', 'image/png', 'application/octet-stream'}:
        raise HTTPException(status_code=415, detail='Send a JPEG or PNG image')
    content_length = request.headers.get('content-length')
    if content_length and int(content_length) > MAX_OCR_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail='Image exceeds the 4 MB limit')

    image = await request.body()
    is_jpeg = image.startswith(b'\xff\xd8')
    is_png = image.startswith(b'\x89PNG\r\n\x1a\n')
    if not image or len(image) > MAX_OCR_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail='Image is empty or exceeds the 4 MB limit')
    if not (is_jpeg or is_png):
        raise HTTPException(status_code=415, detail='Invalid JPEG or PNG image')

    url = f'{AZURE_VISION_ENDPOINT}/computervision/imageanalysis:analyze'
    try:
        async with httpx.AsyncClient(timeout=25.0) as client:
            response = await client.post(
                url,
                params={'api-version': '2024-02-01', 'features': 'read'},
                headers={
                    'Ocp-Apim-Subscription-Key': AZURE_VISION_KEY,
                    'Content-Type': 'application/octet-stream',
                },
                content=image,
            )
            response.raise_for_status()
    except httpx.HTTPError as error:
        raise HTTPException(status_code=502, detail='Azure Vision OCR failed') from error

    payload = response.json()
    azure_lines = [
        line
        for block in payload.get('readResult', {}).get('blocks', [])
        for line in block.get('lines', [])
        if line.get('text', '').strip()
    ]
    lines = [line.get('text', '').strip() for line in azure_lines]
    metadata = payload.get('metadata', {})
    red_zone = find_red_restricted_zone(image)
    details = candidate_details(
        azure_lines,
        red_zone,
        int(metadata.get('width', 0)),
        int(metadata.get('height', 0)),
    )
    violation = any(item['restricted'] for item in details)
    return {
        'provider': 'azure-ai-vision',
        'text': '\n'.join(lines),
        'lines': lines,
        'candidates': plate_candidates(lines),
        'candidate_details': details,
        'red_zone': red_zone,
        'no_parking_violation': violation,
        'fine_amount': 500 if violation else 0,
    }


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
