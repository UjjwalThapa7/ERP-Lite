do $$ declare r record; begin
  for r in select conname from pg_constraint where conrelid='public.sales'::regclass and contype='c'
    and (pg_get_constraintdef(oid) like '%method%' or pg_get_constraintdef(oid) like '%cash + fonepay%') loop
    execute format('alter table public.sales drop constraint %I', r.conname);
  end loop;
end $$;

create table public.customers (
  id uuid primary key, name text not null, phone text,
  created_at timestamptz not null default now(), created_by uuid default auth.uid()
);
create table public.vendors (
  id uuid primary key, name text not null, phone text,
  created_at timestamptz not null default now(), created_by uuid default auth.uid()
);

alter table public.sales
  add column credit numeric(12,2) not null default 0 check (credit >= 0),
  add column customer_id uuid references public.customers(id);
alter table public.sales add constraint sales_method_check check (method in ('Cash','Fonepay','Split','Credit'));
alter table public.sales add constraint sales_sum_check check (cash + fonepay + credit = total);
alter table public.sales add constraint sales_credit_needs_customer check (credit = 0 or customer_id is not null);
create index sales_customer_idx on public.sales (customer_id);

create table public.customer_payments (
  id uuid primary key,
  customer_id uuid not null references public.customers(id),
  paid_at timestamptz not null,
  cash numeric(12,2) not null default 0 check (cash >= 0),
  fonepay numeric(12,2) not null default 0 check (fonepay >= 0),
  note text, created_at timestamptz not null default now(), created_by uuid default auth.uid(),
  check (cash + fonepay > 0)
);
create table public.vendor_txns (
  id uuid primary key,
  vendor_id uuid not null references public.vendors(id),
  at timestamptz not null,
  kind text not null check (kind in ('purchase','payment')),
  amount numeric(12,2) not null check (amount > 0),
  method text check (method in ('Cash','Fonepay')),
  note text, created_at timestamptz not null default now(), created_by uuid default auth.uid()
);

alter table public.customers enable row level security;
alter table public.vendors enable row level security;
alter table public.customer_payments enable row level security;
alter table public.vendor_txns enable row level security;
create policy members_read on public.customers for select to authenticated using (public.is_member());
create policy members_read on public.vendors for select to authenticated using (public.is_member());
create policy members_read on public.customer_payments for select to authenticated using (public.is_member());
create policy members_read on public.vendor_txns for select to authenticated using (public.is_member());

create or replace function public.save_sale(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid := (p->>'id')::uuid; it jsonb;
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  if exists (select 1 from public.sales where id = sid) then return sid; end if;
  insert into public.sales(id, sold_at, subtotal, discount, total, method, cash, fonepay, credit, customer_id, note)
  values (sid, (p->>'sold_at')::timestamptz, (p->>'subtotal')::numeric, (p->>'discount')::numeric,
          (p->>'total')::numeric, p->>'method', (p->>'cash')::numeric, (p->>'fonepay')::numeric,
          coalesce((p->>'credit')::numeric,0), nullif(p->>'customer_id','')::uuid, nullif(p->>'note',''));
  for it in select * from jsonb_array_elements(p->'items') loop
    insert into public.sale_items(sale_id, name, price, qty) values (sid, it->>'name', (it->>'price')::numeric, (it->>'qty')::int);
  end loop;
  insert into public.sale_events(sale_id, what) values (sid, 'created');
  return sid;
end $$;

create or replace function public.add_customer(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  insert into public.customers(id, name, phone) values ((p->>'id')::uuid, trim(p->>'name'), nullif(trim(p->>'phone'),''))
  on conflict (id) do nothing;
  return (p->>'id')::uuid;
end $$;

create or replace function public.add_vendor(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  insert into public.vendors(id, name, phone) values ((p->>'id')::uuid, trim(p->>'name'), nullif(trim(p->>'phone'),''))
  on conflict (id) do nothing;
  return (p->>'id')::uuid;
end $$;

create or replace function public.add_customer_payment(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  insert into public.customer_payments(id, customer_id, paid_at, cash, fonepay, note)
  values ((p->>'id')::uuid, (p->>'customer_id')::uuid, (p->>'paid_at')::timestamptz,
          coalesce((p->>'cash')::numeric,0), coalesce((p->>'fonepay')::numeric,0), nullif(p->>'note',''))
  on conflict (id) do nothing;
  return (p->>'id')::uuid;
end $$;

create or replace function public.add_vendor_txn(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  insert into public.vendor_txns(id, vendor_id, at, kind, amount, method, note)
  values ((p->>'id')::uuid, (p->>'vendor_id')::uuid, (p->>'at')::timestamptz, p->>'kind',
          (p->>'amount')::numeric, nullif(p->>'method',''), nullif(p->>'note',''))
  on conflict (id) do nothing;
  return (p->>'id')::uuid;
end $$;

revoke all on function public.add_customer(jsonb), public.add_vendor(jsonb), public.add_customer_payment(jsonb), public.add_vendor_txn(jsonb), public.save_sale(jsonb) from public, anon;
grant execute on function public.add_customer(jsonb), public.add_vendor(jsonb), public.add_customer_payment(jsonb), public.add_vendor_txn(jsonb), public.save_sale(jsonb) to authenticated;
