"""Account-scoped demonstration penalties. No real payment is collected."""
import asyncio
import hashlib
import hmac
import re
import secrets
from datetime import datetime, timezone, timedelta
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

router = APIRouter(prefix='/api/v1')
PLATE = re.compile(r'^(?:[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}|[0-9]{2}BH[0-9]{4}[A-Z]{1,2})$')


def hash_password(password: str, salt: str | None = None) -> str:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=16384, r=8, p=1).hex()
    return f'scrypt${salt}${digest}'


def verify_password(password: str, stored: str) -> bool:
    try:
        method, salt, _ = stored.split('$')
        return method == 'scrypt' and hmac.compare_digest(hash_password(password, salt), stored)
    except (ValueError, TypeError):
        return False


class Login(BaseModel):
    model_config = ConfigDict(extra='forbid')
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=8, max_length=128)

    @field_validator('email')
    @classmethod
    def email_format(cls, value):
        value = value.strip().lower()
        if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value):
            raise ValueError('Enter a valid email address')
        return value


class Vehicle(BaseModel):
    model_config = ConfigDict(extra='forbid')
    plate: str = Field(min_length=4, max_length=20)

    @field_validator('plate')
    @classmethod
    def canonical_plate(cls, value):
        value = re.sub(r'[\s-]', '', value.upper())
        if not PLATE.fullmatch(value):
            raise ValueError('Enter a valid vehicle registration number')
        return value


class Signup(Login, Vehicle):
    name: str = Field(min_length=2, max_length=100)

    @field_validator('name')
    @classmethod
    def clean_name(cls, value):
        value = value.strip()
        if len(value) < 2 or any(ord(c) < 32 for c in value):
            raise ValueError('Enter your name')
        return value


async def current_user(request: Request):
    if getattr(request.state, 'user', None) is not None:
        return request.state.user
    auth = request.headers.get('authorization', '')
    if not auth.startswith('Bearer ') or not 32 <= len(auth[7:]) <= 128:
        raise HTTPException(401, 'Please sign in', headers={'WWW-Authenticate': 'Bearer'})
    token_hash = hashlib.sha256(auth[7:].encode()).hexdigest()
    async with request.app.state.db.acquire() as connection:
        row = await connection.fetchrow('''select u.id,u.name,u.email,u.role from portal_users u
            join portal_sessions s on s.user_id=u.id
            where s.token_hash=$1 and s.expires_at>now()''', token_hash)
    if row is None:
        raise HTTPException(401, 'Session expired. Please sign in again')
    request.state.user = dict(row)
    return request.state.user


async def require_admin(request: Request):
    user = await current_user(request)
    if user['role'] != 'admin':
        raise HTTPException(403, 'Administrator access required')
    return user


async def rate_limit(connection, email: str):
    # Stored in PostgreSQL so replicas share the login limit.
    key = hashlib.sha256(email.encode()).hexdigest()
    attempts = await connection.fetchval('''insert into portal_login_attempts(key,attempts) values($1,1)
        on conflict(key) do update set
        attempts=case when portal_login_attempts.started_at<now()-interval '15 minutes'
            then 1 else portal_login_attempts.attempts+1 end,
        started_at=case when portal_login_attempts.started_at<now()-interval '15 minutes'
            then now() else portal_login_attempts.started_at end returning attempts''', key)
    if attempts > 12:
        raise HTTPException(429, 'Too many attempts. Try again in 15 minutes')


async def new_session(connection, user):
    token = secrets.token_urlsafe(32)
    await connection.execute('insert into portal_sessions(token_hash,user_id) values($1,$2)',
                             hashlib.sha256(token.encode()).hexdigest(), user['id'])
    return {'token': token, 'user': {key: user[key] for key in ('id','name','email','role')}}


@router.post('/auth/signup', status_code=201)
async def signup(data: Signup, request: Request):
    async with request.app.state.db.acquire() as connection:
        await rate_limit(connection, data.email)
        password_hash = await asyncio.to_thread(hash_password, data.password)
        try:
            async with connection.transaction():
                user = await connection.fetchrow('''insert into portal_users(name,email,password_hash)
                    values($1,$2,$3) returning id,name,email,role''', data.name, data.email, password_hash)
                await connection.execute('insert into portal_vehicles(plate,owner_id) values($1,$2)', data.plate, user['id'])
                return await new_session(connection, user)
        except asyncpg.UniqueViolationError as error:
            raise HTTPException(409, 'Email or vehicle is already registered. Sign in or contact the administrator') from error


@router.post('/auth/login')
async def login(data: Login, request: Request):
    async with request.app.state.db.acquire() as connection:
        await rate_limit(connection, data.email)
        user = await connection.fetchrow('select * from portal_users where email=$1', data.email)
        # Perform the same expensive hash for unknown email addresses.
        stored = user['password_hash'] if user else 'scrypt$' + '00'*16 + '$' + '00'*64
        valid = await asyncio.to_thread(verify_password, data.password, stored)
        if user is None or not valid:
            raise HTTPException(401, 'Email or password is incorrect')
        await connection.execute('delete from portal_login_attempts where key=$1', hashlib.sha256(data.email.encode()).hexdigest())
        return await new_session(connection, user)


@router.post('/auth/logout')
async def logout(request: Request, user=Depends(current_user)):
    token = request.headers['authorization'][7:]
    async with request.app.state.db.acquire() as connection:
        await connection.execute('delete from portal_sessions where token_hash=$1', hashlib.sha256(token.encode()).hexdigest())
    return {'signed_out': True}


@router.get('/account')
async def account(request: Request, user=Depends(current_user)):
    async with request.app.state.db.acquire() as connection:
        plates = await connection.fetch('select plate from portal_vehicles where owner_id=$1 order by plate', user['id'])
    return {'user': user, 'vehicles': [row['plate'] for row in plates], 'payment_mode': 'demo'}


@router.post('/account/vehicles', status_code=201)
async def add_vehicle(data: Vehicle, request: Request, user=Depends(current_user)):
    try:
        async with request.app.state.db.acquire() as connection:
            await connection.execute('insert into portal_vehicles(plate,owner_id) values($1,$2)', data.plate, user['id'])
    except asyncpg.UniqueViolationError as error:
        raise HTTPException(409, 'Vehicle is already registered') from error
    return {'plate': data.plate}


PENALTY_SELECT = '''select p.id,p.plate,p.amount,p.occurred_at,p.payment_status,p.paid_at,
    p.receipt_id,p.seen_at,p.owner_id,u.name as owner_name,p.camera_key
    from portal_penalties p left join portal_users u on u.id=p.owner_id'''


def penalty_json(row):
    return {**dict(row), 'evidence_path': f'/api/v1/penalties/{row["id"]}/image', 'payment_mode': 'demo'}


@router.get('/penalties')
async def penalties(request: Request, user=Depends(current_user)):
    async with request.app.state.db.acquire() as connection:
        rows = await connection.fetch(PENALTY_SELECT + ' where p.owner_id=$1 order by p.occurred_at desc limit 200', user['id'])
    return [penalty_json(row) for row in rows]


@router.get('/admin/penalties')
async def admin_penalties(request: Request, user=Depends(require_admin)):
    async with request.app.state.db.acquire() as connection:
        rows = await connection.fetch(PENALTY_SELECT + ' order by p.occurred_at desc limit 200')
        summary = await connection.fetchrow('''select count(*) as total,
            count(*) filter(where payment_status='unpaid') as unpaid,
            coalesce(sum(amount) filter(where payment_status='unpaid'),0) as outstanding,
            count(*) filter(where payment_status='demo_paid') as demo_paid from portal_penalties''')
    return {'penalties': [penalty_json(row) for row in rows], 'summary': dict(summary)}


@router.get('/admin/users')
async def admin_users(request: Request, user=Depends(require_admin)):
    async with request.app.state.db.acquire() as connection:
        rows = await connection.fetch('''select u.id,u.name,u.email,u.role,
            coalesce(array_agg(v.plate order by v.plate) filter(where v.plate is not null), '{}') as vehicles
            from portal_users u left join portal_vehicles v on v.owner_id=u.id
            group by u.id order by u.created_at desc limit 200''')
    return [dict(row) for row in rows]


@router.get('/penalties/{penalty_id}/image')
async def evidence(penalty_id: UUID, request: Request, user=Depends(current_user)):
    async with request.app.state.db.acquire() as connection:
        jpeg = await connection.fetchval('''select e.jpeg from portal_evidence e
            join portal_penalties p on p.id=e.penalty_id
            where p.id=$1 and (p.owner_id=$2 or $3)''', penalty_id, user['id'], user['role']=='admin')
    if jpeg is None:
        raise HTTPException(404, 'Penalty image not found')
    return Response(bytes(jpeg), media_type='image/jpeg', headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})


@router.post('/penalties/{penalty_id}/seen')
async def seen(penalty_id: UUID, request: Request, user=Depends(current_user)):
    async with request.app.state.db.acquire() as connection:
        found = await connection.fetchval('''update portal_penalties set seen_at=coalesce(seen_at,now())
            where id=$1 and owner_id=$2 returning id''', penalty_id, user['id'])
    if found is None:
        raise HTTPException(404, 'Penalty not found')
    return {'seen': True}


@router.post('/penalties/{penalty_id}/demo-pay')
async def demo_pay(penalty_id: UUID, request: Request, user=Depends(current_user)):
    # Atomic and idempotent. Amount and ownership are always server controlled.
    async with request.app.state.db.acquire() as connection:
        row = await connection.fetchrow('''update portal_penalties set payment_status='demo_paid',
            paid_at=coalesce(paid_at,now()),receipt_id=coalesce(receipt_id,gen_random_uuid())
            where id=$1 and owner_id=$2 returning id,amount,payment_status,paid_at,receipt_id''', penalty_id, user['id'])
    if row is None:
        raise HTTPException(404, 'Penalty not found')
    return {**dict(row), 'payment_mode': 'demo', 'money_collected': False}


async def record_observation(pool, camera_key: str, observed_at: datetime, result: dict, jpeg: bytes):
    """Persist the server's analysis, never a client-supplied plate or fine."""
    async with pool.acquire() as connection, connection.transaction():
        await connection.execute('select pg_advisory_xact_lock(hashtextextended($1,0))', camera_key)
        previous = await connection.fetchval('select observed_at from portal_monitors where key=$1', camera_key)
        if previous is not None and observed_at <= previous:
            return None
        await connection.execute('''insert into portal_monitors(key,observed_at) values($1,$2)
            on conflict(key) do update set observed_at=excluded.observed_at''', camera_key, observed_at)
        if result['status'] == 'empty':
            await connection.execute('update portal_penalties set active=false where camera_key=$1 and active', camera_key)
            return None
        if result['status'] != 'recognized':
            return None
        plate = result['plate']
        if result['position'] == 'outside':
            await connection.execute('update portal_penalties set active=false where camera_key=$1 and plate=$2 and active', camera_key, plate)
            return None
        if result['position'] != 'inside' or result['fine'] is not True:
            return None
        existing = await connection.fetchval('select id from portal_penalties where camera_key=$1 and plate=$2 and active', camera_key, plate)
        if existing:
            return str(existing)
        owner = await connection.fetchval('select owner_id from portal_vehicles where plate=$1', plate)
        penalty = await connection.fetchval('''insert into portal_penalties(owner_id,plate,camera_key,amount,occurred_at)
            values($1,$2,$3,$4,$5) returning id''', owner, plate, camera_key, result['fine_amount'], observed_at)
        await connection.execute('insert into portal_evidence(penalty_id,jpeg) values($1,$2)', penalty, jpeg)
        if owner is not None:
            await connection.execute('insert into portal_push_outbox(penalty_id,owner_id) values($1,$2)', penalty, owner)
        return str(penalty)


class PushToken(BaseModel):
    model_config = ConfigDict(extra='forbid')
    token: str = Field(min_length=20, max_length=4096)


@router.post('/push/register')
async def register_push(data: PushToken, request: Request, user=Depends(current_user)):
    session_hash = hashlib.sha256(request.headers['authorization'][7:].encode()).hexdigest()
    async with request.app.state.db.acquire() as connection:
        await connection.execute('''insert into portal_push_tokens(token,user_id,session_hash) values($1,$2,$3)
            on conflict(token) do update set user_id=excluded.user_id,session_hash=excluded.session_hash,updated_at=now()''',
            data.token,user['id'],session_hash)
    return {'registered': True}
