create table if not exists cameras (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  location text not null,
  rtsp_url text not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists violations (
  id uuid primary key default gen_random_uuid(),
  plate_number text,
  plate_confidence numeric(5,2),
  camera_id uuid references cameras(id),
  violation_type text not null,
  occurred_at timestamptz not null default now(),
  evidence_url text,
  status text not null default 'new' check (status in ('new','review','resolved','dismissed')),
  fine_amount numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists violations_plate_idx on violations(plate_number);
create index if not exists violations_occurred_at_idx on violations(occurred_at desc);

create table if not exists portal_users (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null unique,
  password_hash text not null,
  role text not null default 'user' check (role in ('user','admin')),
  created_at timestamptz not null default now()
);
create table if not exists portal_vehicles (
  plate text primary key,
  owner_id uuid not null references portal_users(id),
  created_at timestamptz not null default now()
);
create table if not exists portal_sessions (
  token_hash text primary key,
  user_id uuid not null references portal_users(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '14 days'
);
create table if not exists portal_login_attempts (
  key text primary key,
  attempts integer not null,
  started_at timestamptz not null default now()
);
create table if not exists portal_monitors (
  key text primary key,
  observed_at timestamptz not null
);
create table if not exists portal_penalties (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references portal_users(id),
  plate text not null,
  camera_key text not null,
  amount integer not null check (amount between 1 and 99999),
  occurred_at timestamptz not null default now(),
  active boolean not null default true,
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','demo_paid')),
  paid_at timestamptz,
  receipt_id uuid unique,
  seen_at timestamptz
);
create unique index if not exists portal_active_penalty on portal_penalties(camera_key,plate) where active;
create index if not exists portal_owner_penalties on portal_penalties(owner_id,occurred_at desc);
create table if not exists portal_evidence (
  penalty_id uuid primary key references portal_penalties(id) on delete cascade,
  jpeg bytea not null check (octet_length(jpeg) between 1 and 4194304)
);
create table if not exists portal_push_tokens (
  token text primary key,
  user_id uuid not null references portal_users(id) on delete cascade,
  session_hash text not null references portal_sessions(token_hash) on delete cascade,
  updated_at timestamptz not null default now()
);
create table if not exists portal_push_outbox (
  penalty_id uuid primary key references portal_penalties(id) on delete cascade,
  owner_id uuid not null references portal_users(id),
  attempts integer not null default 0,
  next_attempt timestamptz not null default now(),
  sent_at timestamptz
);
