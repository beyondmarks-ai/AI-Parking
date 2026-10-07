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
